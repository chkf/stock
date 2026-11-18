"""Generate fixed Python oracles from disposable copies. Use the original pinned runtime with -B."""
import hashlib
import json
import shutil
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

IOS = Path(__file__).resolve().parents[1]
ROOT = IOS.parent
RESOURCES = IOS / "Sources/ResearchCore/Resources"


def generate():
    sys.dont_write_bytecode = True
    work = IOS / ".build"
    work.mkdir(exist_ok=True)
    RESOURCES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="reference-", dir=work) as temp:
        copy = Path(temp)
        shutil.copytree(ROOT / "stock_research", copy / "stock_research", ignore=shutil.ignore_patterns("__pycache__"))
        frozen = "936d5734e7655d73fbee9d0ffb13fcf5c9eeaa17b639e3dbf115a2f321c666d6"
        market_copy = copy / "data/advice/market"
        (market_copy / "snapshots").mkdir(parents=True)
        name = frozen + ".json.gz"
        shutil.copy2(ROOT / "data/advice/market/snapshots" / name, market_copy / "snapshots" / name)
        (market_copy / "latest.json").write_bytes(json.dumps({"as_of": "2026-11-17", "hash": frozen}).encode())
        sys.path.insert(0, str(copy))
        import stock_research
        assert Path(stock_research.__file__).resolve().is_relative_to(copy)
        from stock_research.advisor.market import MarketStore, session_context, truncate
        from stock_research.advisor.planning import illustrative_account, validate_account
        from stock_research.advisor.service import AdviceService
        from stock_research.storage import Store
        from stock_research.data import SHANGHAI, trading_sessions
        from stock_research.advisor.policies import Panel
        from stock_research.advisor.tracking import begin, advance

        service = AdviceService(Store(copy / "data"))
        market, key = MarketStore(copy / "data").load()
        # Only the fixed public universe, reviewed public event facts and continuity anchors
        # ship with clean setup. There are no price series, paths, accounts, reports or model weights.
        anchor = "2025-01-02"
        rules = dict(anchor=anchor, reviewedThrough=market["as_of"], members={})
        for symbol, x in market["securities"].items():
            kept = ("date", "record_date", "cash_per_share", "share_factor", "supported", "date_needs_reconciliation")
            events = [{k: e.get(k) for k in ("date", "record_date", "cash_per_share", "share_factor", "source", "payment_date", "available_date", "rounding")}
                      for e in x["events"] if e["date"] > anchor]
            rules["members"][symbol] = dict(name=x["name"], group=x["group"], band=x["security"]["fund_band"],
                bandFrom=x["security"]["fund_band_from"],
                anchorClose=x["bars"][anchor]["close"], anchorSignal=x["signal_close"][anchor],
                reviewedClose=x["bars"][market["as_of"]]["close"], events=events,
                provider=[{k: e[k] for k in kept if k in e} for e in x["provider_events"]],
                halts={d: v["source"] for d, v in x["statuses"].items() if d > anchor and v.get("state") == "halted"})
        review = market["securities"]["159936.SZ"]
        assert not any(e.get("share_factor", 1) != 1 and e["date"] in ("2023-02-15", "2023-02-16") for e in review["events"])
        rules["review159936"] = [review["bars"][d]["close"] for d in ("2023-02-15", "2023-02-16")]
        (RESOURCES / "PublicRules.json").write_bytes(json.dumps(rules, sort_keys=True, ensure_ascii=False, indent=2).encode())
        days = trading_sessions(2005, 2026)
        calendar = "".join(str(d.date()) + "\n" for d in days).encode()
        (RESOURCES / "XSHG.txt").write_bytes(calendar)
        end = "2026-11-17"
        if market["as_of"] != end:
            raise ValueError("固定回归输入为 2026-11-17，请从历史原件还原此日指针再生成")
        oracle = dict(snapshot=key, calendarSHA256=hashlib.sha256(calendar).hexdigest(), cases=[], tracking=[])
        # These accounts are fabricated test inputs in the disposable tree. Never load the user's account.
        def actual(date, cash, positions):
            return validate_account(dict(schema="advice-account-v1", as_of=date, confirmed=True, cash=cash, positions=positions))

        scenarios = [("快照收盘", end, end, None, 50000), ("月末", "2026-10-30", "2026-10-30", None, 50000),
                     ("春节前收盘", "2024-02-08", "2024-02-08", None, 50000),
                     ("上市暖机", "2005-01-04", "2005-01-04", None, 50000),
                     ("一手不足", end, end, actual(end, 1.0, []), 50000),
                     ("待卖出到账", end, end, actual(end, 10.0, [dict(symbol="159919.SZ", quantity=10000, available=8300)]), 50000),
                     ("缺持仓报价", end, end, actual(end, 3000., [dict(symbol="600519.SH", quantity=100, available=100)]), 50000),
                     ("账户未确认到本日", end, end, actual("2026-11-16", 50000., []), 50000),
                     ("行情过期", end, "2026-11-18", None, 50000),
                     ("大额分单", end, end, None, 100000000)]
        for name, date, requested, account, capital in scenarios:
            fixed = datetime.fromisoformat(requested + "T18:00:00").replace(tzinfo=SHANGHAI)
            with patch("stock_research.advisor.service.session_context", lambda as_of=None: session_context(as_of, now=fixed)), \
                 patch.object(service, "account", return_value=account):
                report = service.generate(as_of=requested, capital=capital)
            for item in report["strategies"]:
                reference = account or illustrative_account(date, capital)
                dec = item.get("decision")
                expect = dict(status=item["status"], action=item["action"], next=report["signal_next_session"],
                              selected=dec["details"].get("selected", []), route=dec["route"], state=dec["market_state"],
                              breadth=dec["market_evidence"], weights=dec["weights"], scores=dec["details"].get("scores", {}))
                if item.get("plan"):
                    plan = item["plan"]
                    fields = ("equity", "initial_cash", "estimated_costs", "projected_cash", "requested_quantities",
                              "actual_trades_recorded", "projected_cash_conditional_on_sales")
                    expect["plan"] = {k: plan[k] for k in fields}
                    expect["plan"]["orders"] = [{k: v for k, v in order.items() if k not in ("reason", "condition")}
                                               for order in plan["orders"]]
                else:
                    expect["reason"] = item["reason"]
                oracle["cases"].append(dict(name=name, strategy=item["id"], requested=requested, date=date,
                                            account=reference, expected=expect))
        # Real raw prices and recorded corporate actions, including a real split and a real protective exit.
        # Keep quantity fixed between these observations exactly as the advisor does for a confirmed position.
        for label, symbol, start, finish in [
                ("月末跨日", "512800.SH", "2026-10-29", "2026-11-02"),
                ("高点保护与退出锁", "512480.SH", "2020-02-21", "2020-03-23"),
                ("拆分调保护价", "512800.SH", "2025-07-04", "2025-07-07")]:
            def holding(d):
                return actual(d, 5000., [dict(symbol=symbol, quantity=1000, available=400, entry_date=start)])
            prior = begin(Panel(truncate(market, start)), holding(start), "MOM20")
            final = advance(Panel(truncate(market, finish)), holding(finish), prior)
            oracle["tracking"].append(dict(name=label, start=start, finish=finish, startAccount=holding(start),
                                           endAccount=holding(finish), highs=final["highs"], locks=final["risk_locked"],
                                           quantities=final["target_quantities"], selection=final["selection_date"]))
        # Locate an actual cash distribution to test its economic effect without creating a cash posting.
        for symbol, sec in market["securities"].items():
            event = next((e for e in sec["events"] if e.get("cash_per_share", 0) > 0 and
                          "2018" <= e["date"] <= end and e["date"] in sec["bars"]), None)
            if not event:
                continue
            finish = event["date"]
            start = str(days[days.get_loc(finish) - 1].date())
            if start not in sec["bars"]:
                continue
            a = actual(start, 0., [dict(symbol=symbol, quantity=100, available=100)])
            b = {**a, "as_of": finish}
            prior = begin(Panel(truncate(market, start)), a, "MOM20")
            final = advance(Panel(truncate(market, finish)), b, prior)
            oracle["tracking"].append(dict(name="现金分红调保护价", start=start, finish=finish, startAccount=a, endAccount=b,
                                           highs=final["highs"], locks=final["risk_locked"],
                                           quantities=final["target_quantities"], selection=final["selection_date"]))
            break
        (RESOURCES / "Reference.json").write_bytes(json.dumps(oracle, ensure_ascii=False, indent=2,
                                                              sort_keys=True, allow_nan=False).encode())
        print(f"Python 原版 {len(oracle['cases'])} 份策略/份额结果，{len(oracle['tracking'])} 份跟踪结果；快照 {key}")


if __name__ == "__main__":
    generate()
