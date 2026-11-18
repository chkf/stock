"""Build a reproducible, limited no-action review from an actual sealed market and raw HTTP responses.
Reads public-market only. The account directory is never opened. Outputs go to the chosen test folder.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import time
from urllib.parse import urlencode
from urllib.request import Request, urlopen

FIRST, ANCHOR = "2024-10-08", "2025-01-02"
BASE = "936d5734e7655d73fbee9d0ffb13fcf5c9eeaa17b639e3dbf115a2f321c666d6"
IOS = Path(__file__).resolve().parents[1]


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True).encode()


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def prepare(market_path, phone, output):
    raw = market_path.read_bytes()
    if sha(raw) != BASE:
        raise ValueError("示例仅适用于已冻结的桌面行情")
    desktop = json.loads(raw)
    phone = phone / "public-market"
    ref = json.loads((phone / "current.json").read_bytes())
    data = (phone / "snapshots" / (ref["id"] + ".json")).read_bytes()
    if sha(data) != ref["id"]:
        raise ValueError("手机基准副本损坏")
    live = json.loads(data)
    days = [d for d in (IOS / "Sources/ResearchCore/Resources/XSHG.txt").read_text().split() if FIRST <= d <= ANCHOR]
    output.mkdir(parents=True, exist_ok=True)
    review_dir = output / "历史核验"
    sources, symbols, downloads = {}, {}, {}

    def source(raw, name):
        digest = sha(raw)
        key = f"review/{digest}/{name}"
        path = review_dir / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        sources[key] = digest
        return key

    for symbol, sec in sorted(desktop["securities"].items()):
        ticker = symbol[-2:].lower() + symbol[:6]
        url = "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/newfqkline/get?" + urlencode(
            {"param": f"{ticker},day,{FIRST},{ANCHOR},640,"})
        page, meta = output / (symbol + ".json"), output / (symbol + ".capture.json")
        if not page.exists() or not meta.exists():
            for attempt in range(3):
                try:
                    with urlopen(Request(url, headers={"User-Agent": "Mozilla/5.0", "Referer": "https://gu.qq.com/"}), timeout=25) as response:
                        if response.status != 200:
                            raise ValueError("HTTP " + str(response.status))
                        body = response.read()
                    json.loads(body)["data"][ticker]["day"]
                    page.write_bytes(body)
                    meta.write_bytes(encoded({"url": url, "utc": datetime.now(timezone.utc).isoformat(), "sha256": sha(body)}))
                    break
                except (OSError, ValueError, KeyError):
                    if attempt == 2:
                        raise
                    time.sleep(attempt+1)
            time.sleep(0.2)
        body = page.read_bytes()
        receipt = json.loads(meta.read_bytes())
        if receipt["url"] != url or receipt["sha256"] != sha(body):
            raise ValueError("缓存来源或摘要不符 " + symbol)
        rows = [r for r in json.loads(body)["data"][ticker]["day"] if FIRST <= r[0] <= ANCHOR]
        if [r[0] for r in rows] != days:
            raise ValueError("真实日期不连续 " + symbol)
        for row in rows:
            old = sec["bars"][row[0]]
            if any(float(v) != old[k] for k, v in zip(("open","close","high","low","volume"), row[1:6])):
                raise ValueError("两批 OHLC 或成交量不同 " + symbol + " " + row[0])
        for stock in [sec, live["securities"][symbol]]:
            if any(FIRST <= e["date"] < ANCHOR for e in stock["events"] + stock["provider_events"]):
                raise ValueError("该无事件示例发现公司行动 " + symbol)
        html_key = next(k for k in live["sources"] if symbol+".actions-" in k)
        html = (phone / html_key).read_bytes()
        if sha(html) != live["sources"][html_key]:
            raise ValueError("行动原件损坏 " + symbol)
        html_ref = source(html, "actions.html")
        series_ref = source(body, "quotes.json")
        span = {"from": FIRST, "through": days[-2]}
        audit = dict(schema="etf-action-audit-1", symbol=symbol, **span, events=[], sources=[html_ref, series_ref],
                     desktopSnapshot=BASE, description="已核封存事件、原行动 HTML 及逐日原价；本样例限所列窗口")
        symbols[symbol] = dict(spans=[dict(**span, evidence=source(encoded(audit), "audit.json"))], gaps={}, events=[], issues=[])
        downloads[symbol] = dict(**receipt, matched=len(days))
    review = dict(schema="etf-history-review-1", **{"from":FIRST, "through":live["as_of"]}, symbols=symbols)
    (review_dir / "审核.json").write_bytes(encoded(dict(review=review, sources=sources)))
    (output / "records.json").write_bytes(encoded(dict(source=BASE, legacy=ref["id"], downloads=downloads)))
    print(f"{len(symbols)} 只 × {len(days)} 个交易日，逐证券与原价、成交量和行动原件核对。")


if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    for key in ("market","phone","output"):
        parser.add_argument("--"+key,type=Path,required=True)
    args=parser.parse_args()
    prepare(args.market,args.phone,args.output)
