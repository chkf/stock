"""Export a dated ETF watchlist for the iPhone workspace's JSON research inputs."""

import argparse
import csv
import json
from datetime import date
from decimal import Decimal
from pathlib import Path
from statistics import median

import catalog as c


def csv_rows(path):
    with path.open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def build(root, day):
    daily = root / "daily-assets" / day
    sectors = root / "sector-seats" / day
    evidence = c.read(daily / "trading-evidence.json")
    equity = c.read(sectors / "turnover.json")
    sessions = evidence["sessions"]
    if (
        not c.GENERATION.fullmatch(evidence["generation"])
        or not evidence["generation"].startswith(day + "-")
        or any(
            equity[k] != evidence[k]
            for k in ("generation", "sessions", "unit", "through")
        )
        or evidence["unit"] != "万元人民币"
        or len(sessions) != 10
        or sessions != sorted(set(sessions))
        or sessions[-1] != evidence["through"]
        or sessions[-1] >= day
    ):
        raise ValueError(
            "Equity and non-equity evidence must use the same catalog and ten completed sessions"
        )
    stock_seats = {r["板块"]: r for r in csv_rows(sectors / "seats.csv")}
    funds = {
        r["基金代码"]: r
        for r in csv_rows(root / "equity-indices" / day / "fund-map.csv")
    }
    other = {
        r["交易代码"]: r
        for r in csv_rows(daily / "members.csv")
        if r["本次代表"] == "True"
    }
    directions = []
    for row in csv_rows(daily / "watchlist.csv"):
        name, asset = row["日常观察方向"], row["类别"]
        benchmark = row["指数或现货代码"], row["代表观察指标"]
        if asset == "股票板块":
            seat = stock_seats[name]
            symbol, short = seat["建议代表"], seat["简称"]
            fund = funds[symbol]
            if (
                fund["状态"] != "已映射"
                or (fund["观察指数代码"], fund["观察指数"]) != benchmark
            ):
                raise ValueError(
                    f"Representative does not track the selected index: {symbol} {name}"
                )
            group_id, detail = seat["席位ID"], seat["关键取舍"]
            raw, expected = equity["amounts"][symbol], seat["10日成交额中位数(万元)"]
        else:
            symbol, short = row["非股票代表ETF"], row["简称"]
            member = other[symbol]
            if (
                member["类别"],
                member["方向"],
                member["原标的代码"],
                member["原标的或观察指标"],
            ) != (asset, name, *benchmark):
                raise ValueError(
                    f"Representative differs from the member map: {symbol} {name}"
                )
            group_id, detail = member["方向ID"], row["口径与取舍"]
            raw, expected = (
                evidence["amounts"][symbol],
                member["十日成交额中位数（万元）"],
            )
        amounts = [Decimal(v) for v in raw if v is not None]
        if (
            len(amounts) != len(sessions)
            or any(not v.is_finite() or v <= 0 for v in amounts)
            or median(amounts) != Decimal(expected)
        ):
            raise ValueError(f"Turnover differs from the published selection: {symbol}")
        directions.append(
            {
                "id": group_id,
                "asset": asset,
                "direction": name,
                "signal_type": {"黄金": "gold_spot", "货币": "cash_income"}.get(
                    asset, "index"
                ),
                "signal_code": benchmark[0] or None,
                "signal_name": benchmark[1],
                "etf": symbol,
                "etf_name": short,
                "selection_note": detail,
                "turnover_10d_wan": list(map(float, amounts)),
                "median_turnover_wan": float(median(amounts)),
            }
        )
    if not directions or any(
        len({r[k] for r in directions}) != len(directions) for k in ("id", "etf")
    ):
        raise ValueError(
            "Watchlist is empty or has duplicate directions or representatives"
        )
    return {
        "schema": 1,
        "as_of": day,
        "catalog_version": evidence["generation"],
        "turnover_dates": sessions,
        "turnover_unit": "万元人民币",
        "directions": directions,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("day", type=date.fromisoformat)
    parser.add_argument("output", type=Path)
    parser.add_argument("--root", type=Path, default=c.DEFAULT)
    args = parser.parse_args()
    payload = build(args.root, args.day.isoformat())
    if args.output.exists():
        if c.read(args.output) != payload:
            parser.error("Existing input differs; choose a new file for this snapshot")
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("x", encoding="utf-8", newline="\n") as stream:
            json.dump(payload, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write("\n")
    print(
        f"{len(payload['directions'])} directions, {len(payload['turnover_dates'])} turnover dates"
    )


if __name__ == "__main__":
    main()
