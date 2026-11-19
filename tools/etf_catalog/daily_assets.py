"""Combine the equity sector signals with deduplicated exchange-traded non-equity exposures."""

import argparse
import hashlib
import json
import re
import tempfile
from collections import Counter
from datetime import date, datetime
from pathlib import Path

import catalog as c
import equity_indices as eq
from sector_seats import collect_symbol_turnover, turnover_scores

from sources import UNKNOWN, get

RULES = c.HERE / "non_equity_rules.json"
SCOPE = {"scope": "listed-non-equity", "version": 1}
TICK = "https://qt.gtimg.cn/q="
GOLD_SIGNALS = {
    "AU9999": "上金所Au99.99现货合约收盘价",
    "SHAU": "上金所上海金午盘定盘价",
}
CASH_SIGNAL = "计入收益分配的份额收益及场内折溢价"


def universe(state):
    return {
        s: r
        for s, r in state["records"].items()
        if r["present"] and r["asset"] != "股票"
    }


def classify(rows, rules, day):
    directions = rules["directions"]
    if len({g["id"] for g in directions}) != len(directions):
        raise ValueError("Duplicate non-equity direction ID")
    by_pair = {}
    for group in directions:
        for code, name in group["indices"].items():
            if (code, name) in by_pair:
                raise ValueError(f"Benchmark assigned twice: {code} {name}")
            by_pair[code, name] = group
    result = {}
    for symbol, row in rows.items():
        code, name = row["canonical_code"], row["canonical_index"]
        label = row["asset"]
        pending = ("", code, name, "资料或产品机制待核，保留独立候选")
        if (
            row["region"] != "境内"
            or row["trading_currency"] != "人民币"
            or row["conflicts"]
        ):
            result[symbol] = pending
            continue
        if (
            label == "货币"
            and row["product"] == "货币管理"
            and row["exchange_type"] in ("05", "货币市场基金")
        ):
            result[symbol] = (
                "money",
                "",
                CASH_SIGNAL,
                "交易所列为货币基金，按场内现金管理用途归组",
            )
            continue
        if label == "商品" and row["product"] == "黄金现货跟踪":
            verified = rules["gold_evidence"]["members"].get(symbol)
            if (
                verified
                and day >= rules["gold_evidence"]["checked_on"]
                and verified[0] == row["full_name"]
                and (
                    (
                        code == UNKNOWN
                        and name == UNKNOWN
                        and row["index_code"] == UNKNOWN
                        and row["exchange_index"] == UNKNOWN
                        and row["profile_index"] == UNKNOWN
                    )
                    or (code == verified[1] and (code, name) in by_pair)
                )
            ):
                key = verified[1]
                result[symbol] = (
                    "gold",
                    key,
                    GOLD_SIGNALS[key],
                    "上金所逐只核对交易代码、基金全称和定价基准",
                )
            else:
                result[symbol] = pending
            continue
        group = by_pair.get((code, name))
        if group and (
            (
                label == group["asset"] == "债券"
                and row["product"] == "被动指数"
                and not row["review"]
            )
            or (
                label == "商品"
                and group["asset"] == row["product"] == "商品期货"
                and row["exchange_index"] in (UNKNOWN, row["index_name"])
                and row["profile_index"] == row["index_name"]
            )
        ):
            result[symbol] = (
                group["id"],
                code,
                row["index_name"],
                "交易所代码与规范标的名称匹配",
            )
        else:
            result[symbol] = pending
    return result


def quote_batch(symbols):
    out = {}
    ordered = sorted(symbols)
    for offset in range(0, len(ordered), 40):
        batch = ordered[offset : offset + 40]
        keymap = {s[-2:].lower() + s[:6]: s for s in batch}
        body = get(TICK + ",".join(keymap), binary=True).decode("gb18030")
        for key, raw in re.findall(r'v_([a-z]{2}\d{6})="([^"]*)";', body):
            fields = raw.split("~")
            if (
                key not in keymap
                or len(fields) <= 30
                or fields[2] != key[2:]
                or keymap[key] in out
            ):
                raise ValueError(f"Invalid secondary-market quote: {key}")
            out[keymap[key]] = {
                "at": datetime.strptime(fields[30], "%Y%m%d%H%M%S")
                .replace(tzinfo=c.SHANGHAI)
                .isoformat(),
                "lots": int(fields[6]),
            }
    if set(out) != set(symbols):
        raise ValueError("Quotes do not cover the complete non-equity directory")
    return out


def screen(state, version, rules, data):
    rows = universe(state)
    assigned = classify(rows, rules, state["observed_at"][:10])
    scores, days = turnover_scores(state, version, SCOPE, data, set(rows))
    session = data["spot"]
    if session["source"] != TICK or set(session["quotes"]) != set(rows):
        raise ValueError("Secondary-market evidence differs from the catalog")
    active = set()
    observed_day = (
        datetime.fromisoformat(state["observed_at"]).astimezone(c.SHANGHAI).date()
    )
    for symbol, quote in session["quotes"].items():
        stamp = datetime.fromisoformat(quote["at"])
        if stamp.tzinfo is None or type(quote["lots"]) is not int or quote["lots"] < 0:
            raise ValueError(f"Invalid dated trade evidence: {symbol}")
        if stamp.astimezone(c.SHANGHAI).date() == observed_day and quote["lots"] > 0:
            active.add(symbol)
    seats = []
    for group in rules["directions"]:
        symbols = sorted(s for s, (gid, *_) in assigned.items() if gid == group["id"])
        if symbols:
            candidates = [s for s in symbols if s in scores and s in active]
            rep = min(
                candidates,
                key=lambda s: (-scores[s], rows[s]["listing_date"], s),
                default=None,
            )
            seats.append((group, symbols, rep))
    return seats, assigned, scores, days, active


def write_reports(out, state, version, rules, data):
    seats, assigned, scores, days, active = screen(state, version, rules, data)
    rows = state["records"]
    day = state["observed_at"][:10]
    if day < eq.BASE_SECTORS.name:
        raise ValueError("Catalog predates the frozen equity sector selection")
    equity_rules = c.read(eq.RULES)
    groups, _, _ = eq.equity_universe(state, equity_rules)
    stock = [
        r
        for r in eq.sector_watchlist(
            groups, equity_rules, eq.load_sectors(eq.BASE_SECTORS)
        )
        if r[-1] == "可观察"
    ]
    if len({r[1] for r in stock}) != len(stock):
        raise ValueError("Equity signals are not unique")
    watch = [
        (
            "股票板块",
            sector,
            code,
            index,
            "",
            "",
            "按股票指数观察，交易产品见股票映射表",
        )
        for sector, code, index, _, _ in stock
    ]
    members, overview = [], []
    by_asset = Counter(group["asset"] for group, _, rep in seats if rep)
    for group, symbols, rep in seats:
        label = group["name"]
        gid = group["id"]
        for s in symbols:
            _, code, name, basis = assigned[s]
            members.append(
                (
                    s,
                    rows[s]["full_name"],
                    group["asset"],
                    gid,
                    label,
                    code,
                    name,
                    basis,
                    days[s],
                    scores.get(s, ""),
                    data["spot"]["quotes"][s]["at"],
                    s in active,
                    s == rep,
                )
            )
        if rep:
            _, code, name, _ = assigned[rep]
            watch.append(
                (
                    group["asset"],
                    label,
                    code,
                    name,
                    rep,
                    rows[rep]["short_name"],
                    group["difference"],
                )
            )
        overview.append(
            (
                group["asset"],
                label,
                len(symbols),
                rep or "待核",
                rows[rep]["short_name"] if rep else "",
                group["difference"],
            )
        )
    for s, (gid, code, name, basis) in assigned.items():
        if not gid:
            members.append(
                (
                    s,
                    rows[s]["full_name"],
                    rows[s]["asset"],
                    "pending:" + s,
                    "待核",
                    code,
                    name,
                    basis,
                    days[s],
                    scores.get(s, ""),
                    data["spot"]["quotes"][s]["at"],
                    s in active,
                    False,
                )
            )
    if len({r[0] for r in members}) != len(assigned) or len(assigned) != len(members):
        raise ValueError("Non-equity products do not reconcile")
    c.write_csv(
        out / "watchlist.csv",
        [
            "类别",
            "日常观察方向",
            "指数或现货代码",
            "代表观察指标",
            "非股票代表ETF",
            "简称",
            "口径与取舍",
        ],
        watch,
    )
    c.write_csv(
        out / "members.csv",
        [
            "交易代码",
            "基金全称",
            "类别",
            "方向ID",
            "方向",
            "原标的代码",
            "原标的或观察指标",
            "归组依据",
            "十日正成交日数",
            "十日成交额中位数（万元）",
            "盘口时间",
            "当日已有成交",
            "本次代表",
        ],
        sorted(members),
    )
    c.write_json(out / "trading-evidence.json", data)
    pending = sum(not item[0] for item in assigned.values())
    inactive = sum(rep is None for _, _, rep in seats)
    added = sum(by_asset.values())
    lines = [
        "# 跨资产日常观察表",
        "",
        f"目录日 {day}。{len(assigned)} 只在列非股票产品按风险暴露和现金用途分组，"
        f"其中 **{added} 个方向有可核实成交的代表 ETF**。加上 {len(stock)} 个股票板块，"
        f"本次日常观察 **{len(watch)} 个方向**。股票部分沿用板块主表，扩展股票指数另供查阅。",
        "",
        "| 资产 | 交易产品数 | 日常新增方向 |",
        "|---|---:|---:|",
    ]
    for asset in ("债券", "货币", "黄金", "商品期货"):
        lines.append(
            f"| {asset} | {sum(len(s) for g, s, _ in seats if g['asset'] == asset)} | {by_asset[asset]} |"
        )
    coverage = (
        f"{len(assigned)} 只产品均有成员映射，{added} 个非股票方向均有符合成交条件的代表。"
        if not pending and not inactive
        else f"{pending} 只产品暂按独立候选待核，{inactive} 个已归类方向暂缺合格代表，均保留在成员表。"
    )
    if assigned:
        saved = len(assigned) - len(seats) - pending
        coverage += f" 待核产品逐只计数后，相比逐只观察减少 {saved} 项（{saved / len(assigned):.2%}）。"
    lines.extend(
        [
            "",
            coverage,
            "",
            "[合并观察表](watchlist.csv) · [非股票产品逐只映射](members.csv) · [成交证据](trading-evidence.json)",
            "",
            "| 类别 | 观察方向 | 产品数 | 本次代表 | 归并或保留理由 |",
            "|---|---|---:|---|---|",
        ]
    )
    for asset, label, count, rep, short, detail in overview:
        lines.append(f"| {asset} | {label} | {count} | {rep} {short} | {detail} |")
    ranges = sorted(data["spot"]["quotes"][s]["at"] for _, _, s in seats if s)
    lines.extend(
        [
            "",
            "## 交易与观测口径",
            "",
            f"近十个完整交易日取 {data['sessions'][0]} 至 {data['through']}，沪深基准指数共同确认交易日。"
            f"{len(scores)} 只每天都有正成交额，{len(active)} 只在目录日的腾讯盘中快照已发生成交。"
            "每组从同时满足这两个条件的产品中按十日成交额中位数选一只，同额取上市较早者，再按交易代码。"
            "盘中成交只验证该时点有场内交易，委托成交取决于当时的买卖盘。"
            + (
                f"代表行情时间为北京时间 {ranges[0][11:19]} 至 {ranges[-1][11:19]}。"
                if ranges
                else ""
            ),
            "",
            "货币基金用于现金管理。观察代表份额公布的收益、分配和折溢价，直接使用百元附近的场内价格计算动量会漏掉已分配收益。"
            "黄金保留 Au99.99 和 SHAU 两种定价依据，共用一个人民币黄金方向。商品期货 ETF 保留各自标的，期货换月会影响收益。"
            "债券席位按照发行人、期限、信用筛选和可转股性划分，交易所市场和样本差异保留在各基金对应的指数中。"
            "不同收益序列、份额分配方式和期货合约不得直接拼接作历史收益。",
            "",
            f"目录版本 `{version}`，非股票规则 `{rules['version']}`。逐方向资料链接见"
            " [分类规则](../../../../tools/etf_catalog/non_equity_rules.json)。"
            "本次筛选不改变 App 行情、正式策略池或历史回测。",
        ]
    )
    (out / "report.md").write_text(
        "\n".join(lines) + "\n", encoding="utf-8", newline="\n"
    )
    return dict(
        products=len(assigned),
        by_asset=dict(by_asset),
        added=added,
        stock=len(stock),
        total=len(watch),
        pending=pending,
        unrepresented=inactive,
    )


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", type=Path, default=c.DEFAULT)
    commands = p.add_subparsers(dest="cmd", required=True)
    collect = commands.add_parser("collect")
    collect.add_argument("through", type=date.fromisoformat)
    collect.add_argument("output", type=Path)
    report = commands.add_parser("report")
    report.add_argument("evidence", type=Path)
    report.add_argument("output", type=Path)
    args = p.parse_args()
    rules = c.read(RULES)
    if args.cmd == "collect":
        state, version = c.current(args.root)
        symbols = set(universe(state))
        data = collect_symbol_turnover(
            state, version, SCOPE, args.through, symbols, latest_only=True
        )
        data["spot"] = {"source": TICK, "quotes": quote_batch(symbols)}
        with args.output.open("x", encoding="utf-8", newline="\n") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        return
    data = c.read(args.evidence)
    version = data["generation"]
    if not c.GENERATION.fullmatch(version):
        p.error("Invalid catalog version")
    state = c.read(args.root / version / "catalog.json")
    receipt = c.read(args.root / version / "availability.json")
    if hashlib.sha256(c.encoded(state)).hexdigest() != receipt["catalog_sha256"]:
        p.error("Catalog differs from its availability evidence")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output.parent) as tmp:
        out = Path(tmp) / "report"
        out.mkdir()
        result = write_reports(out, state, version, rules, data)
        if args.output.exists():
            for path in out.iterdir():
                saved = args.output / path.name
                if not saved.is_file() or saved.read_text(
                    encoding="utf-8"
                ) != path.read_text(encoding="utf-8"):
                    p.error("Existing report differs; choose a new output directory")
        else:
            out.rename(args.output)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
