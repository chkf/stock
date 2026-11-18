"""Run the sealed Python accounting code on a copied public-market snapshot."""
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile

IOS = Path(__file__).resolve().parents[1]
ROOT = IOS.parent
SNAPSHOT = "936d5734e7655d73fbee9d0ffb13fcf5c9eeaa17b639e3dbf115a2f321c666d6"


def generate():
    sys.dont_write_bytecode = True
    dest = IOS / ".build/replay-parity"
    dest.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=IOS / ".build") as temporary:
        copy = Path(temporary)
        shutil.copytree(ROOT / "stock_research", copy / "stock_research", ignore=shutil.ignore_patterns("__pycache__"))
        for folder, name in [("sector_selection_20261114", "sector_account"), ("sector_selection_20261114", "sector_history"),
                             ("bank_long_history_20261114", "history_support")]:
            shutil.copy(ROOT / "research" / folder / (name+".py"), copy)
        shutil.copy(ROOT / f"data/advice/market/snapshots/{SNAPSHOT}.json.gz", copy / "market.gz")
        raw = gzip.decompress((copy / "market.gz").read_bytes())
        assert hashlib.sha256(raw).hexdigest() == SNAPSHOT
        market = json.loads(raw)
        sys.path.insert(0, str(copy))
        import pandas as pd
        import sector_account as ledger
        from stock_research.advisor.policies import Panel
        from stock_research.market_rules import Security
        from stock_research.advisor.catalog import BY_ID
        inputs = {}
        for s,x in market["securities"].items():
            df = pd.DataFrame(x["bars"]).T.sort_index()
            df.index = pd.to_datetime(df.index)
            factor = pd.Series(x["signal_close"])
            factor.index = pd.to_datetime(factor.index)
            ratio = factor.reindex(df.index)/df.close
            for p in ["open","close","low","high"]:
                df["raw_"+p] = df[p]
                df[p] *= ratio
            inputs[s] = dict(group=x["group"], df=df, security=Security(**x["security"]), statuses=x["statuses"],
                             events=[{**e, "symbol":s} for e in x["events"]])
        start, end = "2026-01-19", "2026-11-17"
        data = ledger.compile_market(inputs,start,end)
        panel = Panel(market)
        output = dict(snapshot=SNAPSHOT,start=start,end=end,studies={},signals=[])
        # Exercise all four hybrid routes on genuine daily inputs, independent of trading cash.
        seen = set()
        for d in reversed(panel.calendar[panel.calendar <= end]):
            date = str(d.date())
            result = panel.decision("BANK_ELSE_GB",date)
            if result["route"] not in seen:
                seen.add(result["route"])
                output["signals"].append(dict(date=date,route=result["route"],weights=result["weights"],
                                              breadth=result["market_evidence"],state=result["market_state"]))
            if seen >= {"MOM","BANK","GB","MV"}: break
        for strategy in BY_ID:
            policy, previous = {}, {}
            for date in [data["before"], *data["dates"]]:
                if date == data["before"] or panel.is_month_end(date):
                    previous = panel.decision(strategy,date,previous)
                    policy[date] = dict(date=date,information_date=date,weights=previous["weights"],route=previous["route"],reason="scheduled")
            cfg = ledger.PortfolioConfig(mode="scenario",initial_cash=50_000.,state_routing=True,
                trailing_drawdown=.2 if strategy in {"MOM20","BANK_ELSE_GB","SECTOR_M"} else None,
                equity_protection=strategy=="SECTOR_M")
            result = ledger.run_portfolio(data,policy,cfg,start,end)
            output["studies"][strategy] = dict(curve=[[r["date"],r["equity"]] for r in result["curve"]],
                orders=[[o["date"],o["symbol"],o["side"].upper(),o["quantity"],o["price"],o["costs"]["total"]] for o in result["orders"]])
        (dest/"market.json").write_bytes(raw)
        (dest/"expected.json").write_text(json.dumps(output,ensure_ascii=False,allow_nan=False),"utf-8")
        print(start,end,[(s,len(r["orders"])) for s,r in output["studies"].items()], sorted(seen))


if __name__ == "__main__": generate()
