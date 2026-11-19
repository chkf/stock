"""Build an equity-index watchlist using catalog evidence, without downloading prices."""

import argparse
import csv
import hashlib
import tempfile
from collections import Counter, defaultdict
from pathlib import Path

import catalog as c
from classify import norm

from sources import UNKNOWN

RULES = c.HERE / "equity_index_rules.json"
BASE_SECTORS = c.DEFAULT / "sector-seats" / "2026-11-19"


def alias_lookup(rules):
    lookup = {}
    for entry in rules["identities"]:
        for code in entry["codes"]:
            for name in entry["names"]:
                pair = code, norm(name)
                if pair in lookup:
                    raise ValueError(f"Duplicate index evidence: {pair}")
                lookup[pair] = entry
    return lookup


def identify(row, lookup):
    if (
        row["conflicts"]
        or row["product"] == "主动"
        or "无跟踪标的" in row["profile_index"]
    ):
        return None
    pair = row["canonical_code"], row["canonical_index"]
    entry = lookup.get(pair)
    if entry:
        names = {
            norm(row[k])
            for k in ("exchange_index", "profile_index")
            if row[k] != UNKNOWN
        }
        if not row["index_identified"] and (
            not names or not all(lookup.get((pair[0], name)) == entry for name in names)
        ):
            return None
        return entry["code"], entry["name"], entry["publisher"], entry["source"]
    if row["index_identified"]:
        return pair[0], pair[1], row["publisher"], ""
    return None


def equity_universe(state, rules):
    lookup = alias_lookup(rules)
    groups = defaultdict(dict)
    pending, excluded = {}, Counter()
    by_name, by_code = defaultdict(set), defaultdict(set)
    for symbol, row in state["records"].items():
        if not row["present"]:
            excluded["本次未见"] += 1
        elif row["asset"] != "股票":
            excluded[row["asset"]] += 1
        else:
            identity = identify(row, lookup)
            if not identity:
                pending[symbol] = "标的身份或跟踪关系待核"
                continue
            code, name = identity[:2]
            groups[(code, name)][symbol] = identity
            by_name[norm(name)].add(code)
            by_code[code].add(norm(name))
    for code, name in list(groups):
        if len(by_name[norm(name)]) > 1 or len(by_code[code]) > 1:
            for symbol in groups.pop((code, name)):
                pending[symbol] = "名称与代码非一一对应，币种或收益版本待核"
    return groups, pending, excluded


def load_sectors(folder):
    # Freeze the benchmark selected in the original sector screen. A new ETF or
    # a fund subsequently changing its benchmark must not silently change a signal.
    with (folder / "members.csv").open(encoding="utf-8-sig", newline="") as f:
        members = {row["证券"]: row for row in csv.DictReader(f)}
    sectors = []
    with (folder / "seats.csv").open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            symbol = row["建议代表"]
            if not symbol:
                sectors.append((row["板块"], "", ""))
                continue
            member = members[symbol]
            if member["分配席位"] != row["席位ID"] or member["指数"] != row["跟踪指数"]:
                raise ValueError(f"Sector benchmark mismatch: {row['板块']}")
            sectors.append((row["板块"], member["指数代码"], member["指数"]))
    if len({s[0] for s in sectors}) != len(sectors):
        raise ValueError("Duplicate sector")
    return sectors


def sector_watchlist(groups, rules, sectors):
    watch = []
    lookup = alias_lookup(rules)
    for sector, raw_code, raw_name in sectors:
        entry = lookup.get((raw_code, norm(raw_name)))
        key = (entry["code"], entry["name"]) if entry else (raw_code, raw_name)
        members = groups.get(key, {})
        watch.append(
            (sector, *key, len(members), "可观察" if members else "当前映射待核")
        )
    return watch


def write_tables(state, version, rules, sectors, out):
    groups, pending, excluded = equity_universe(state, rules)
    rows = state["records"]
    eligible = sum(len(g) for g in groups.values())
    details, links = [], []
    for (code, name), group in sorted(groups.items()):
        for symbol, identity in sorted(group.items()):
            r = rows[symbol]
            links.append(
                (
                    symbol,
                    r["short_name"],
                    r["product"],
                    r["canonical_code"],
                    r["index_name"],
                    code,
                    name,
                    "已映射",
                    identity[3],
                )
            )
        publishers = sorted({v[2] for v in group.values()} - {UNKNOWN})
        details.append(
            (
                code,
                name,
                " / ".join(publishers) or UNKNOWN,
                " / ".join(sorted({rows[s]["region"] for s in group})),
                len(group),
                sum(rows[s]["product"] == "被动指数" for s in group),
                sum(rows[s]["product"] == "增强" for s in group),
                " / ".join(sorted({rows[s]["canonical_code"] for s in group})),
                next((v[3] for v in group.values() if v[3]), ""),
            )
        )
    for symbol, why in pending.items():
        r = rows[symbol]
        links.append(
            (
                symbol,
                r["short_name"],
                r["product"],
                r["canonical_code"],
                r["index_name"],
                "",
                "",
                why,
                "",
            )
        )
    watch = sector_watchlist(groups, rules, sectors)
    n = sum(r[-1] == "可观察" for r in watch)
    if len(links) + sum(excluded.values()) != len(rows):
        raise ValueError("Catalog membership does not reconcile")
    c.write_csv(
        out / "watchlist.csv",
        ["板块", "观察指数代码", "观察指数", "已映射产品数", "状态"],
        watch,
    )
    c.write_csv(
        out / "indices.csv",
        [
            "指数代码",
            "指数名称",
            "发布机构",
            "市场",
            "映射产品数",
            "被动指数产品数",
            "增强产品数",
            "目录规范代码",
            "补充核对来源",
        ],
        details,
    )
    c.write_csv(
        out / "fund-map.csv",
        [
            "基金代码",
            "简称",
            "产品属性",
            "目录规范代码",
            "档案标的",
            "观察指数代码",
            "观察指数",
            "状态",
            "补充核对来源",
        ],
        sorted(links),
    )
    lines = [
        "# 股票指数观察表",
        "",
        f"截至 {state['observed_at'][:10]}，境内板块观察表有 **{n} 条可观察指数**。"
        "每个板块沿用已选代表对应的跟踪指数。看板块时直接查指数；选定方向后，再查哪些 ETF 跟踪它。",
        "",
        f"完整股票索引覆盖沪深上市、包括跨境的 {eligible + len(pending):,} 只在列股票 ETF。"
        f"其中 {eligible:,} 只映射到 {len(groups)} 条可辨识的指数记录，"
        f"另有 {len(pending)} 只的标的身份或对应版本待核。"
        "同一指数下的增强产品标明属性。指数代码是标的标识，实际行情接口还需匹配数据商代码、币种及收益口径。",
        "",
        "完整目录中的其他在列资产："
        + "、".join(
            f"{kind} {count} 只"
            for kind, count in sorted(excluded.items())
            if kind != "本次未见"
        )
        + "。这些产品的日常方向见[跨资产筛选](../../README.md)。",
        "",
        "[板块观察表](watchlist.csv) · [全部股票指数](indices.csv) · [指数与基金映射、待核明细](fund-map.csv)",
        "",
        "| 板块 | 观察指数代码 | 观察指数 | 已映射产品数 |",
        "|---|---|---|---:|",
    ]
    for sector, code, name, count, status in watch:
        lines.append(f"| {sector} | {code} | {name or status} | {count} |")
    lines.extend(
        [
            "",
            f"目录版本 `{version}`，指数规则版本 `{rules['version']}`。"
            "板块的指数固定于本次筛选，要更换需明确修订。股票索引保留宽基、风格和境外市场等额外方向。"
            "历史研究需要当时可知的名单、指数版本和发布时点。",
        ]
    )
    (out / "report.md").write_text(
        "\n".join(lines) + "\n", encoding="utf-8", newline="\n"
    )
    return len(groups), eligible, len(pending), n


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--root", type=Path, default=c.DEFAULT)
    args = parser.parse_args()
    state, version = c.current(args.root)
    if not state:
        parser.error("No published catalog")
    if state["observed_at"][:10] < BASE_SECTORS.name:
        parser.error("Catalog predates the frozen sector selection")
    receipt = c.read(args.root / version / "availability.json")
    if hashlib.sha256(c.encoded(state)).hexdigest() != receipt["catalog_sha256"]:
        parser.error("Catalog differs from its availability evidence")
    rules = c.read(RULES)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output.parent) as tmp:
        folder = Path(tmp) / "report"
        folder.mkdir()
        counts = write_tables(state, version, rules, load_sectors(BASE_SECTORS), folder)
        if args.output.exists():
            for file in folder.iterdir():
                saved = args.output / file.name
                if not saved.is_file() or saved.read_text(
                    encoding="utf-8"
                ) != file.read_text(encoding="utf-8"):
                    parser.error(
                        "Output differs; use a new directory for a new snapshot"
                    )
        else:
            folder.rename(args.output)
    print("index_series=%d mapped_etfs=%d pending_etfs=%d sector_indices=%d" % counts)


if __name__ == "__main__":
    main()
