"""Choose at most one research representative for each named domestic equity sector."""

import argparse
import hashlib
import json
import tempfile
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta
from decimal import Decimal
from pathlib import Path
from statistics import median

import catalog as c

from sources import get

RULES = c.HERE / "sector_rules.json"
QUOTE = "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/newfqkline/get"
TEN = 10


def sector_members(state, rules):
    by_index, result = {}, {}
    for board in rules["boards"]:
        if board["id"] in result or not board["core"]:
            raise ValueError(f"Invalid board {board['id']}")
        result[board["id"]] = {}
        for role in ("core", "variants"):
            for code, name in board[role].items():
                if code in by_index:
                    raise ValueError(f"Index assigned twice: {code}")
                by_index[code] = (name, board["id"], role)
    for symbol, r in state["records"].items():
        entry = by_index.get(r["canonical_code"])
        if (
            entry
            and entry[0] == r["canonical_index"]
            and r["present"]
            and not r["review"]
            and r["asset"] == "股票"
            and r["region"] == "境内"
            and r["product"] == "被动指数"
        ):
            result[entry[1]][symbol] = entry[2]
    return result


def quote_days(symbol, start, through, limit):
    code, market = symbol.split(".")
    key = market.lower() + code
    url = f"{QUOTE}?param={key},day,{start},{through},{limit},"
    reply = get(url, ref="https://gu.qq.com/")
    if reply["code"] != 0 or key not in reply["data"]:
        raise ValueError(f"Unexpected quote response for {symbol}")
    result = {}
    for bar in reply["data"][key]["day"]:
        day = date.fromisoformat(bar[0])
        # The vendor sometimes pads the start to return the requested limit.
        if day < start:
            continue
        if day > through or day in result:
            raise ValueError(f"Unexpected or duplicate session for {symbol}: {day}")
        value = Decimal(bar[8])  # Tencent reports turnover in CNY 10,000.
        if not value.is_finite() or value < 0:
            raise ValueError(f"Invalid turnover for {symbol} on {day}")
        result[day] = str(value)
    return result


def collect_turnover(state, version, rules, through):
    members = sector_members(state, rules)
    symbols = {
        s for group in members.values() for s, role in group.items() if role == "core"
    }
    return collect_symbol_turnover(state, version, rules, through, symbols)


def collect_symbol_turnover(
    state, version, rules, through, symbols, *, latest_only=False
):
    decision_day = date.fromisoformat(state["observed_at"][:10])
    if through >= decision_day:
        raise ValueError("Use a completed session before the catalog observation date")
    calendar_end = decision_day - timedelta(days=1) if latest_only else through
    start = calendar_end - timedelta(days=35)
    calendars = [
        sorted(quote_days(s, start, calendar_end, 28))[-TEN:]
        for s in ("000001.SH", "399001.SZ")
    ]
    days = calendars[0]
    if days != calendars[1] or len(days) != TEN or days[-1] != through:
        raise ValueError("Cannot confirm the same ten sessions for both markets")
    core = sorted(symbols)

    def fetch(symbol):
        listing = state["records"][symbol]["listing_date"]
        if listing != "未知" and date.fromisoformat(listing) > through:
            return [None] * TEN
        bars = quote_days(symbol, days[0], through, TEN)
        if set(bars) - set(days):
            raise ValueError(f"Unexpected trading dates: {symbol}")
        return [bars.get(day) for day in days]

    with ThreadPoolExecutor(max_workers=4) as pool:
        amounts = dict(zip(core, pool.map(fetch, core)))
    return {
        "generation": version,
        "rule_sha256": hashlib.sha256(c.encoded(rules)).hexdigest(),
        "retrieved_at": datetime.now(c.SHANGHAI).isoformat(timespec="seconds"),
        "source": QUOTE,
        "unit": "万元人民币",
        "through": str(through),
        "calendar_symbols": ["000001.SH", "399001.SZ"],
        "sessions": list(map(str, days)),
        "amounts": amounts,
    }


def turnover_scores(state, version, rules, data, core):
    days = [date.fromisoformat(x) for x in data["sessions"]]
    if (
        data["generation"] != version
        or data["rule_sha256"] != hashlib.sha256(c.encoded(rules)).hexdigest()
        or data["unit"] != "万元人民币"
        or data["source"] != QUOTE
        or len(days) != TEN
        or days != sorted(set(days))
        or days[-1] != date.fromisoformat(data["through"])
        or str(days[-1]) >= state["observed_at"][:10]
        or set(data["amounts"]) != core
    ):
        raise ValueError(
            "Turnover evidence differs from catalog, rules, or session window"
        )
    records = state["records"]
    scores, n_traded = {}, {}
    for s, series in data["amounts"].items():
        if len(series) != TEN:
            raise ValueError(f"Invalid observation count for {s}")
        values = []
        listing = records[s]["listing_date"]
        for day, raw in zip(days, series):
            if raw is None:
                continue
            value = Decimal(raw)
            if (
                not value.is_finite()
                or value < 0
                or (listing != "未知" and str(day) < listing)
            ):
                raise ValueError(f"Invalid observed turnover for {s} on {day}")
            if value > 0:
                values.append(value)
        n_traded[s] = len(values)
        if len(values) == TEN:
            scores[s] = median(values)
    return scores, n_traded


def screen(state, version, rules, data):
    records = state["records"]
    members = sector_members(state, rules)
    slots = {s: board for board, items in members.items() for s in items}
    core = {
        s for items in members.values() for s, role in items.items() if role == "core"
    }
    scores, n_traded = turnover_scores(state, version, rules, data, core)
    ranks, chosen = {}, {}
    for board, items in members.items():
        ranked = sorted(
            (s for s in items if s in scores),
            key=lambda s: (-scores[s], records[s]["listing_date"], s),
        )
        ranks.update({s: i for i, s in enumerate(ranked, 1)})
        if ranked:
            chosen[board] = ranked[0]
    assignments = {
        s: "sector:" + slots[s] if s in slots else r["proposal"]
        for s, r in records.items()
    }
    original = defaultdict(set)
    for s, r in records.items():
        original[r["proposal"]].add(assignments[s])
    if any(len(groups) != 1 for groups in original.values()):
        raise ValueError("A B group spans multiple sector assignments; review the rule")
    counts = {
        "all": len(records),
        "assigned": len(slots),
        "A": len({records[s]["strict"] for s in slots}),
        "B": len({records[s]["proposal"] for s in slots}),
        "sectors": sum(bool(items) for items in members.values()),
        "represented": len(chosen),
        "core": len(core),
        "scored": len(scores),
        "outside": len({group for s, group in assignments.items() if s not in slots}),
        "review": sum(bool(r["review"]) for r in records.values()),
        "total_seats": len(set(assignments.values())),
    }
    return members, assignments, scores, n_traded, ranks, chosen, counts


def write_report(state, version, rules, data, output):
    members, assignments, scores, n_traded, ranks, chosen, n = screen(
        state, version, rules, data
    )
    rows = state["records"]
    boards = {b["id"]: b for b in rules["boards"]}
    seats, mapping = [], []
    for board in sorted(boards, key=lambda k: (-len(members[k]), k)):
        group = members[board]
        if not group:
            continue
        b = boards[board]
        s = chosen.get(board)
        seats.append(
            (
                b["name"],
                "sector:" + board,
                len(group),
                len({rows[t]["strict"] for t in group}),
                len({rows[t]["proposal"] for t in group}),
                sum(t in scores for t in group),
                s or "",
                rows[s]["short_name"] if s else "暂缺合格代表",
                rows[s]["canonical_index"] if s else "",
                scores.get(s, ""),
                b["difference"],
            )
        )
    for s, r in sorted(rows.items()):
        slot = assignments[s]
        bid = slot.removeprefix("sector:") if slot.startswith("sector:") else None
        role = members[bid][s] if bid else None
        if role == "variants":
            status = "板块内专项备选"
        elif role == "core":
            status = (
                ("本次代表" if chosen.get(bid) == s else "同板块备选")
                if s in scores
                else "成交窗口不足"
            )
        else:
            status = "待核独立保留" if r["review"] else "沿用B组"
        mapping.append(
            (
                s,
                r["short_name"],
                slot,
                boards[bid]["name"] if bid else "",
                status,
                ranks.get(s, ""),
                n_traded.get(s, ""),
                scores.get(s, ""),
                r["canonical_code"],
                r["canonical_index"],
                r["strict"],
                r["proposal"],
            )
        )
    lines = [
        "# 每个板块选一只 ETF",
        "",
        (
            f"目录观测日 {state['observed_at'][:10]}。在 {n['all']:,} 只沪深 ETF 中，"
            f"本轮有 **{n['assigned']} 只**境内被动股票 ETF 匹配已列名的板块指数。"
            f"严格归组 A 有 {n['A']} 组，方向提案 B 有 {n['B']} 组。"
            f"按板块各占一席后有 **{n['sectors']} 个板块，{n['represented']} 只建议代表**。"
        ),
        "",
        (
            f"其余产品继续占 {n['outside']} 个研究候选，其中 {n['review']} 只待核逐只计数。"
            f"全目录口径合计 {n['total_seats']} 个候选，比原 B 方案再少 {n['B'] - n['sectors']} 个。"
            "板块清单用于挑选希望配置的方向，每个已选板块最多取一只。不同板块仍可能持有相同个股。"
        ),
        "",
        (
            f"先按指数正式名称和代码匹配主方向，设备材料、龙头、单一上市板等专项版本逐只保留。"
            f"在 {n['core']} 只可作代表的产品中，有 {n['scored']} 只在 {data['sessions'][0]} 至 "
            f"{data['through']} 的十个完整交易日每天都有正成交额。以日成交额中位数从高到低排序，"
            "并列时先选上市较早者，再按证券代码。没有合格产品时该板块保留空席。"
            "该排序衡量近期成交活跃度。费率、实时买卖价差和折溢价须在实际决策时核对。"
        ),
        "",
        "[板块代表表](seats.csv) · [全部证券与备选映射](members.csv) · [逐日成交额及来源](turnover.json)",
        "",
        "| 板块 | ETF 数 | A → B | 本次代表 | 日成交额中位数（亿元） | 一席取舍 |",
        "|---|---:|---:|---|---:|---|",
    ]
    for label, _, count, a, b, _, sym, name, _, score, difference in seats:
        amount = f"{score / 10000:.2f}" if sym else "—"
        lines.append(
            f"| {label} | {count} | {a} → {b} | {sym} {name} | {amount} | {difference} |"
        )
    lines.extend(
        [
            "",
            (
                f"目录版本 `{version}`，板块规则 `{rules['version']}`。"
                f"腾讯行情提取时间 {data['retrieved_at']}，成交额原始单位为万元。"
                "表中保留全部主方向和专项备选，仅在当前研究视图中给出代表。"
                "上市状态、历史规则、指数权重和交易条件会变化，历史回测须使用当时可得的证据。"
            ),
            "",
            (
                "[指数规则及名单](../../../../tools/etf_catalog/sector_rules.json) · "
                "[国证机器人编制方案](https://www.cnindex.com.cn/docs/gz_980022.pdf) · "
                "[中证半导体产品与设备](https://oss-ch.csindex.com.cn/static/html/csindex/public/uploads/indices/detail/files/zh_CN/H30184_Index_Methodology_cn.pdf) · "
                "[科创板半导体材料设备](https://oss-ch.csindex.com.cn/static/html/csindex/public/uploads/indices/detail/files/zh_CN/950125_Index_Methodology_cn.pdf)"
            ),
        ]
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as tmp:
        folder = Path(tmp) / "report"
        folder.mkdir()
        c.write_csv(
            folder / "seats.csv",
            [
                "板块",
                "席位ID",
                "ETF数",
                "A组",
                "B组",
                "可排序数",
                "建议代表",
                "简称",
                "跟踪指数",
                "10日成交额中位数(万元)",
                "关键取舍",
            ],
            seats,
        )
        c.write_csv(
            folder / "members.csv",
            [
                "证券",
                "简称",
                "分配席位",
                "板块",
                "处理",
                "组内顺位",
                "正成交日数",
                "10日成交额中位数(万元)",
                "指数代码",
                "指数",
                "原A组",
                "原B组",
            ],
            mapping,
        )
        c.write_json(folder / "turnover.json", data)
        (folder / "report.md").write_text(
            "\n".join(lines) + "\n", encoding="utf-8", newline="\n"
        )
        if output.exists():
            if any(
                not (output / f.name).is_file()
                or f.read_text(encoding="utf-8")
                != (output / f.name).read_text(encoding="utf-8")
                for f in folder.iterdir()
            ):
                raise ValueError("Output differs; use a new directory for a new screen")
        else:
            folder.rename(output)
    print(json.dumps(n, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=c.DEFAULT)
    subs = parser.add_subparsers(dest="cmd", required=True)
    fetch = subs.add_parser("collect")
    fetch.add_argument("through", type=date.fromisoformat)
    fetch.add_argument("output", type=Path)
    report = subs.add_parser("report")
    report.add_argument("amounts", type=Path)
    report.add_argument("output", type=Path)
    args = parser.parse_args()
    rules = c.read(RULES)
    if args.cmd == "collect":
        state, version = c.current(args.root)
        if not version:
            parser.error("No published catalog")
        data = collect_turnover(state, version, rules, args.through)
        with args.output.open("x", encoding="utf-8", newline="\n") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        print(f"{len(data['amounts'])} securities, {TEN} sessions")
    else:
        data = c.read(args.amounts)
        version = data["generation"]
        if not c.GENERATION.fullmatch(version):
            parser.error("Invalid catalog generation")
        state = c.read(args.root / version / "catalog.json")
        receipt = c.read(args.root / version / "availability.json")
        if hashlib.sha256(c.encoded(state)).hexdigest() != receipt["catalog_sha256"]:
            parser.error("Catalog differs from its availability evidence")
        write_report(state, version, rules, data, args.output)


if __name__ == "__main__":
    main()
