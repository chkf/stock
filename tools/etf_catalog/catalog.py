"""Publish validated research snapshots, preserving identities and prior facts."""

import argparse
from collections import Counter, defaultdict
from contextlib import contextmanager
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from datetime import date, datetime, time, timedelta, timezone

from classify import classification, index_identity
from report import render
from sources import collect, UNKNOWN as U, _codes_digest

HERE = Path(__file__).resolve().parent
DEFAULT = HERE.parents[1] / "research" / "etf-catalog"
SHANGHAI = timezone(timedelta(hours=8))
GENERATION = re.compile(r"\d{4}-\d{2}-\d{2}-[a-f0-9]{16}")
FIELDS = {
    "short_name",
    "manager",
    "listing_date",
    "exchange_type",
    "index_code",
    "exchange_index",
    "full_name",
    "profile_index",
    "profile_type",
    "conflicts",
}


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def encoded(x):
    return json.dumps(
        x, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def observation_time(stamp):
    value = datetime.fromisoformat(stamp)
    return value if value.tzinfo else value.replace(tzinfo=SHANGHAI)


def decision_time(value):
    """Date-only decisions mean end of the Shanghai civil day."""
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        return datetime.combine(date.fromisoformat(value), time.max, SHANGHAI)
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    stamp = datetime.fromisoformat(value)
    if stamp.tzinfo is None:
        raise ValueError("An intraday cutoff requires a UTC offset")
    return stamp.astimezone(SHANGHAI)


def write_json(path, obj):
    path.write_text(
        json.dumps(obj, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def validate_input(snapshot):
    datetime.fromisoformat(snapshot["observed_at"])
    records = snapshot["records"]
    for sym, r in records.items():
        if not re.fullmatch(r"\d{6}\.(SH|SZ)", sym) or not FIELDS <= r.keys():
            raise ValueError(f"Invalid security or schema {sym}")
        if not isinstance(r["conflicts"], list) or any(
            not isinstance(r[k], str) or not r[k] for k in FIELDS - {"conflicts"}
        ):
            raise ValueError(f"Invalid metadata {sym}")
    for exchange in ("SH", "SZ"):
        codes = [s[:6] for s in records if s.endswith("." + exchange)]
        receipt = snapshot["markets"][exchange]
        if (
            not codes
            or len(codes) != receipt["total"]
            or _codes_digest(codes) != receipt["codes_sha256"]
        ):
            raise ValueError(f"{exchange} evidence does not match catalog membership")
    sh = snapshot["sources"]["SSE_FUND_LIST"]
    if (
        sh["total"] != snapshot["markets"]["SH"]["total"]
        or sh["codes_sha256"] != snapshot["markets"]["SH"]["codes_sha256"]
    ):
        raise ValueError("SSE source totals/keys differ")
    sz = snapshot["sources"]["SZSE_fund_etf"]
    extra = set(snapshot.get("sz_only_general", []))
    sz_codes = {s[:6] for s in records if s.endswith(".SZ")}
    if len(sz_codes - extra) != sz["total"] or not extra <= sz_codes:
        raise ValueError("SZSE source total differs")
    sz_keys = sz["codes_sha256"]
    if _codes_digest(sz_codes - extra) != sz_keys:
        raise ValueError("SZSE source keys differ")
    return snapshot


def changes_between(old, new):
    changes = {}
    for field in sorted(
        FIELDS
        | {
            "present",
            "strict",
            "proposal",
            "direction_id",
            "rule_version",
            "review",
            "asset",
            "region",
            "industry",
            "direction",
            "product",
        }
    ):
        if old.get(field) != new.get(field):
            changes[field] = [old.get(field), new.get(field)]
    return changes


def match(row, previous, strict, directions):
    if previous:
        return "已有证券的信息更新"
    if row["review"]:
        return "信息不足，待核"
    if row["strict"] in strict:
        return "已有严格重复组的新成员"
    if row["direction_id"] in directions:
        return "已有方向中的新指数或新暴露"
    return "全新投资方向"


def ambiguous_codes(records, rules):
    names = defaultdict(set)
    for row in records.values():
        _, code, name = index_identity(row, rules)
        if code != U and name != U:
            names[code].add(name)
    return {code for code, values in names.items() if len(values) > 1}


def build(snapshot, previous, rules):
    validate_input(snapshot)
    day = snapshot["observed_at"][:10]
    old = previous.get("records", {})

    if previous and observation_time(snapshot["observed_at"]) < observation_time(
        previous["observed_at"]
    ):
        raise ValueError("Snapshot predates current catalog")
    strict = {r["strict"] for r in old.values() if r["present"] and not r["review"]}
    dirs = {
        r["direction_id"] for r in old.values() if r["present"] and r["direction"] != U
    }
    records = {}
    ambiguous = ambiguous_codes(snapshot["records"], rules)
    for sym in sorted(old.keys() | snapshot["records"].keys()):
        prev = old.get(sym)
        present = sym in snapshot["records"]
        raw = snapshot["records"].get(sym) if present else {k: prev[k] for k in FIELDS}
        row = {**raw, **classification(sym, raw, rules, present, ambiguous)}
        row.update(
            exchange=sym[-2:],
            code=sym[:6],
            present=present,
            status="交易所目录在列" if present else "本次未见，状态待核",
            first_seen=prev["first_seen"] if prev else day,
            first_observed_at=prev.get("first_observed_at", prev["first_seen"])
            if prev
            else snapshot["observed_at"],
            last_seen=day if present else prev["last_seen"],
            fields_asof=(
                snapshot["sources"]["SZSE_fund_etf"]["source_asof"]
                if present and sym.endswith(".SZ")
                else day
                if present
                else prev["fields_asof"]
            ),
            profile_observed=day if present else prev["profile_observed"],
        )
        kind = match(row, prev, strict, dirs)
        row["first_match"] = (
            prev["first_match"] if prev else ("初始建档" if not old else kind)
        )
        row["changes"] = list(prev["changes"]) if prev else []
        if prev:
            delta = changes_between(prev, row)
            if delta:
                why = (
                    "接口未见，保留上次观测"
                    if not present
                    else "重新出现"
                    if not prev["present"]
                    else "规则版本更新"
                    if prev["rule_version"] != row["rule_version"]
                    else "字段或分组证据更新"
                )
                row["changes"].append(
                    dict(date=day, kind=kind, reason=why, fields=delta)
                )
        records[sym] = row
    return {
        **{k: v for k, v in snapshot.items() if k != "records"},
        "records": records,
        "rule_version": rules["version"],
        "applied_rules": rules,
        "rule_sha256": hashlib.sha256(encoded(rules)).hexdigest(),
    }


def totals(rows):
    return dict(
        products=len(rows),
        A=len({r["strict"] for r in rows}),
        B=len({r["proposal"] for r in rows}),
        review=sum(bool(r["review"]) for r in rows),
    )


def summary(state):
    rows = list(state["records"].values())
    current = [r for r in rows if r["present"]]
    numbers = totals(rows)
    n = len(rows)
    for tier in ("A", "B"):
        numbers[tier + "_reduction"] = n - numbers[tier]
        numbers[tier + "_reduction_pct"] = round(100 * (n - numbers[tier]) / n, 2)
    valid_index = sum(r["index_identified"] for r in current)
    classified = sum(
        r["asset"] != U and r["region"] != U and r["direction"] != U for r in current
    )
    return {
        **numbers,
        "observed": len(current),
        "absent_retained": n - len(current),
        "markets": dict(Counter(r["exchange"] for r in current)),
        "index_identified": valid_index,
        "classified": classified,
        "index_identified_pct": round(100 * valid_index / len(current), 2),
        "classified_pct": round(100 * classified / len(current), 2),
        "review_observed": sum(bool(r["review"]) for r in current),
    }


def write_csv(path, headers, rows):
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.writer(f, lineterminator="\n")
        writer.writerow(headers)
        writer.writerows(rows)


def export(state, out):
    out.mkdir(parents=True, exist_ok=True)
    rows = state["records"]
    counts = summary(state)
    write_json(out / "summary.json", counts)
    directions = defaultdict(list)
    groups = {"A": defaultdict(list), "B": defaultdict(list)}
    for sym, r in rows.items():
        directions[(r["asset"], r["region"], r["industry"], r["direction"])].append(r)
        groups["A"][r["strict"]].append(sym)
        groups["B"][r["proposal"]].append(sym)
    breakdown = [
        (*path, *totals(members).values())
        for path, members in sorted(directions.items())
    ]
    if any(
        sum(line[i] for line in breakdown) != counts[k]
        for i, k in enumerate(("products", "A", "B", "review"), 4)
    ):
        raise ValueError("Group crosses reporting directions")
    write_csv(
        out / "directions.csv",
        ["资产", "市场", "行业", "主方向", "原ETF", "A", "B", "待核"],
        breakdown,
    )
    write_csv(
        out / "review.csv",
        ["证券", "简称", "标的名称", "交易所指数代码", "原因", "A", "B"],
        (
            (
                s,
                r["short_name"],
                r["index_name"],
                r["index_code"],
                "；".join(r["review"]),
                r["strict"],
                r["proposal"],
            )
            for s, r in rows.items()
            if r["review"]
        ),
    )
    write_csv(
        out / "members.csv",
        [
            "证券",
            "简称",
            "管理人",
            "上市日",
            "资产",
            "地区",
            "行业",
            "方向",
            "标的名称",
            "交易所指数栏原文",
            "规范代码",
            "产品属性",
            "主方向ID",
            "A",
            "B",
        ],
        (
            (
                s,
                r["short_name"],
                r["manager"],
                r["listing_date"],
                r["asset"],
                r["region"],
                r["industry"],
                r["direction"],
                r["index_name"],
                r["index_code"],
                r["canonical_code"],
                r["product"],
                r["direction_id"],
                r["strict"],
                r["proposal"],
            )
            for s, r in rows.items()
        ),
    )

    def group_lines():
        for tier, group in groups.items():
            for gid, syms in sorted(group.items()):
                members = [rows[s] for s in syms]
                r = members[0]
                diff = (
                    r["proposal_loss"]
                    if tier == "B" and len({x["strict"] for x in members}) > 1
                    else ""
                )
                reason = (
                    "同一细分暴露，人工白名单提案"
                    if diff
                    else "；".join(r["review"])
                    if r["review"]
                    else "标的代码和正式名称一致，境内被动产品属性兼容"
                    if len(syms) > 1
                    else "独立标的或产品属性"
                )
                retention = diff or (
                    "证据不足，保留独立候选"
                    if r["review"]
                    else "保留不同管理人、上市时间及交易条件；尚未按流动性或费用选代表"
                )
                dates = sorted(
                    {
                        member["listing_date"]
                        for member in members
                        if member["listing_date"] != U
                    }
                )
                yield (
                    tier,
                    gid,
                    len(syms),
                    " ".join(syms),
                    " | ".join(
                        sorted(
                            {
                                x["canonical_code"] + " " + x["index_name"]
                                for x in members
                            }
                        )
                    ),
                    reason,
                    retention,
                    "、".join(sorted({member["manager"] for member in members})),
                    dates[0] if dates else U,
                    dates[-1] if dates else U,
                    " ".join(sorted({member["strict"] for member in members})),
                )

    write_csv(
        out / "groups.csv",
        [
            "方案",
            "稳定组ID",
            "成员数",
            "全部成员",
            "所含指数",
            "理由",
            "差异及保留理由",
            "组内管理人",
            "组内最早已知上市日",
            "组内最晚已知上市日",
            "所含A组",
        ],
        group_lines(),
    )
    (out / "report.md").write_text(
        render(state, counts, groups), encoding="utf-8", newline="\n"
    )
    return counts


def verify(state, folder):
    live = {s: r for s, r in state["records"].items() if r["present"]}
    validate_input(dict(state, records=live))
    rules = state["applied_rules"]
    if hashlib.sha256(encoded(rules)).hexdigest() != state["rule_sha256"]:
        raise ValueError("Rule digest mismatch")
    ambiguous = ambiguous_codes(live, rules)
    for sym, r in state["records"].items():
        expected = classification(sym, r, rules, r["present"], ambiguous)
        if any(r[k] != v for k, v in expected.items()):
            raise ValueError(f"Classification mismatch {sym}")
    with tempfile.TemporaryDirectory() as tmp:
        generated = Path(tmp)
        counts = export(state, generated)
        for f in generated.iterdir():
            if f.read_text(encoding="utf-8") != (folder / f.name).read_text(
                encoding="utf-8"
            ):
                raise ValueError(f"Export mismatch {f.name}")
    return counts


def verify_pcf(state, receipt, archive):
    from exchange_files import pcf_headers

    if hashlib.sha256(archive).hexdigest() != receipt["archive_sha256"]:
        raise ValueError("PCF archive digest mismatch")
    pcf = pcf_headers(archive, receipt["source_asof"].replace("-", ""))
    for code, fields in receipt["samples"].items():
        if any(pcf[code][k] != value for k, value in fields.items()):
            raise ValueError("ETF table and PCF differ")
    sz = {
        r["code"]: r
        for r in state["records"].values()
        if r["present"] and r["exchange"] == "SZ"
    }
    if len(pcf) != receipt["total"] or set(pcf) != set(sz):
        raise ValueError("PCF membership differs from catalog")
    for code, row in sz.items():
        if row["index_code"].split()[0].upper() != pcf[code]["nhzs"].upper():
            raise ValueError(f"PCF index differs for {code}")
    return {
        "pcf_asof": receipt["source_asof"],
        "catalog_observed": state["observed_at"],
        "matched_symbols_and_index_codes": len(sz),
        "codes_sha256": _codes_digest(sz),
    }


def current_version(root):
    pointer = root / "CURRENT"
    if not pointer.exists():
        return None
    version = pointer.read_text(encoding="ascii").strip()
    if not GENERATION.fullmatch(version):
        raise ValueError("Invalid CURRENT")
    return version


def current(root):
    version = current_version(root)
    return (read(root / version / "catalog.json"), version) if version else ({}, None)


def as_of(root, cutoff, include_members=False):
    decision = decision_time(cutoff)
    result = {"as_of": decision.isoformat(), "status": "no_coverage"}
    version = current_version(root)
    visited = set()
    child_time = None
    while version is not None:
        if not GENERATION.fullmatch(version) or version in visited:
            raise ValueError("Invalid catalog publication chain")
        visited.add(version)
        receipt_file = root / version / "availability.json"
        if not receipt_file.is_file():
            raise ValueError(f"Missing availability evidence for {version}")
        receipt = read(receipt_file)
        stamp = datetime.fromisoformat(receipt["available_at"])
        if (
            receipt["generation"] != version
            or stamp.tzinfo is None
            or (child_time is not None and stamp > child_time)
        ):
            raise ValueError("Invalid generation or availability timestamp")
        if stamp <= decision:
            state = read(root / version / "catalog.json")
            if (
                hashlib.sha256(encoded(state)).hexdigest() != receipt["catalog_sha256"]
                or observation_time(state["observed_at"]) > stamp
            ):
                raise ValueError("Catalog differs from its availability evidence")
            result.update(
                status="available",
                generation=version,
                available_at=stamp.isoformat(),
                availability_basis=receipt["basis"],
                observed_at=state["observed_at"],
                rule_version=state["rule_version"],
                rule_sha256=state["rule_sha256"],
                summary=summary(state),
            )
            if include_members:
                result["members"] = state["records"]
            return result
        child_time, version = stamp, receipt["previous"]
    if child_time is not None:
        result["earliest_available_at"] = child_time.isoformat()
    return result


@contextmanager
def exclusive(root):
    # OS releases the advisory lock if the writer exits unexpectedly.
    with (root / ".refresh.lock").open("a+b") as f:
        if os.name == "nt":
            import msvcrt

            f.seek(0)
            msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl

            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def publish(snapshot, root, rules):
    root.mkdir(parents=True, exist_ok=True)
    with exclusive(root):
        old, version = current(root)
        if (
            old
            and old["rule_version"] == rules["version"]
            and old["rule_sha256"] != hashlib.sha256(encoded(rules)).hexdigest()
        ):
            raise ValueError("Changed rules require a new version")
        state = build(snapshot, old, rules)

        # Multiple reads on the same day with identical facts share the same generation.
        def generation_facts(s):
            return [
                s["observed_at"][:10],
                s["markets"],
                s["rule_sha256"],
                s["records"],
                s.get("field_sources", {}),
                {k: v.get("source_asof") for k, v in s["sources"].items()},
            ]

        comparable = generation_facts(state)
        if old and generation_facts(old) == comparable:
            return root / version
        # Include the parent so a return to an earlier state has its own publication.
        token = (
            state["observed_at"][:10]
            + "-"
            + hashlib.sha256(encoded([version, comparable])).hexdigest()[:16]
        )
        with tempfile.TemporaryDirectory(dir=root) as tmp:
            folder = Path(tmp) / "ready"
            folder.mkdir()
            export(state, folder)
            write_json(folder / "catalog.json", state)
            final = root / token
            if not final.exists():
                folder.rename(final)
            else:
                saved = read(final / "catalog.json")
                if generation_facts(saved) != comparable:
                    raise ValueError("Generation collision")
                # An attempt may have stopped between building a generation and
                # switching CURRENT. Bind the receipt to the bytes actually reused.
                state = saved
            available = datetime.now(SHANGHAI)
            previous_receipt = root / version / "availability.json" if version else None
            if observation_time(state["observed_at"]) > available:
                raise ValueError("Clock precedes observation")
            if previous_receipt and previous_receipt.exists():
                previous_stamp = datetime.fromisoformat(read(previous_receipt)["available_at"])
                if previous_stamp > available:
                    raise ValueError("Clock precedes previous availability")
            receipt = Path(tmp) / "availability.json"
            write_json(
                receipt,
                {
                    "generation": token,
                    "previous": version,
                    "available_at": available.isoformat(),
                    "basis": "local_validated_snapshot",
                    "catalog_sha256": hashlib.sha256(encoded(state)).hexdigest(),
                },
            )
            os.replace(receipt, final / "availability.json")
            pointer = Path(tmp) / "CURRENT"
            pointer.write_text(token + "\n", encoding="ascii", newline="\n")
            os.replace(pointer, root / "CURRENT")
        return final


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=DEFAULT)
    ap.add_argument("--rules", type=Path, default=HERE / "rules.json")
    subs = ap.add_subparsers(dest="cmd", required=True)
    subs.add_parser("refresh").add_argument(
        "--sz-http",
        action="store_true",
        help="Use the exchange's HTTP public reports endpoint",
    )
    subs.add_parser("reclassify")
    subs.add_parser("verify")
    at = subs.add_parser("as-of", help="Research catalog known at the decision time")
    at.add_argument("cutoff", help="Shanghai date (end of day) or timestamp with UTC offset")
    at.add_argument("--members", action="store_true", help="Include all original member records")
    pc = subs.add_parser("verify-pcf")
    pc.add_argument("receipt", type=Path)
    pc.add_argument("archive", type=Path)
    coll = subs.add_parser("collect")
    coll.add_argument("output", type=Path)
    coll.add_argument("--sz-http", action="store_true")
    subs.add_parser("apply").add_argument("snapshot", type=Path)
    subs.add_parser("report").add_argument("output", type=Path)
    subs.add_parser("match").add_argument(
        "product", type=Path, help="JSON with symbol and observed product fields"
    )
    df = subs.add_parser("diff")
    df.add_argument("before", type=Path)
    df.add_argument("after", type=Path)
    args = ap.parse_args()
    if args.cmd == "as-of":
        try:
            result = as_of(args.root, args.cutoff, args.members)
        except (ValueError, KeyError, OSError) as error:
            ap.error(str(error))
        print(json.dumps(result, ensure_ascii=False))
        if result["status"] == "no_coverage":
            raise SystemExit(3)
        return
    rules = read(args.rules)
    if args.cmd in ("refresh", "apply", "reclassify"):
        if args.cmd == "refresh":
            snap = collect(args.sz_http)
        elif args.cmd == "apply":
            snap = read(args.snapshot)
        else:
            snap, _ = current(args.root)
            if not snap:
                raise ValueError("No published catalog")
            snap["records"] = {
                s: {k: r[k] for k in FIELDS}
                for s, r in snap["records"].items()
                if r["present"]
            }
        print(publish(snap, args.root, rules))
    elif args.cmd == "collect":
        snap = validate_input(collect(args.sz_http))
        with args.output.open("x", encoding="utf-8") as f:
            json.dump(snap, f, ensure_ascii=False)
    elif args.cmd == "diff":
        a, b = (read(p)["records"] for p in (args.before, args.after))
        result = {}
        for s in sorted(a.keys() | b.keys()):
            delta = (
                changes_between(a[s], b[s])
                if s in a and s in b
                else {"membership": [s in a, s in b]}
            )
            if delta:
                result[s] = delta
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        state, version = current(args.root)
        if not version:
            raise ValueError("No published catalog")
        if args.cmd == "verify-pcf":
            print(
                json.dumps(
                    verify_pcf(state, read(args.receipt), args.archive.read_bytes()),
                    ensure_ascii=False,
                )
            )
        elif args.cmd == "verify":
            print(json.dumps(verify(state, args.root / version), ensure_ascii=False))
        elif args.cmd == "report":
            print(json.dumps(export(state, args.output), ensure_ascii=False))
        else:
            r = read(args.product)
            sym = r.pop("symbol")
            if not re.fullmatch(r"\d{6}\.(SH|SZ)", sym):
                raise ValueError("Invalid symbol")
            raw = {k: r.get(k, [] if k == "conflicts" else U) for k in FIELDS}
            old = state["records"]
            if hashlib.sha256(encoded(rules)).hexdigest() != state["rule_sha256"]:
                raise ValueError(
                    "Apply the new rule version with reclassify before matching"
                )
            observed = {s: p for s, p in old.items() if p["present"]}
            observed[sym] = raw
            row = classification(
                sym, raw, rules, ambiguous=ambiguous_codes(observed, rules)
            )
            kind = match(
                row,
                old.get(sym),
                {p["strict"] for p in old.values() if p["present"] and not p["review"]},
                {
                    p["direction_id"]
                    for p in old.values()
                    if p["present"] and p["direction"] != U
                },
            )
            print(
                json.dumps(
                    {"symbol": sym, "match": kind, **row}, ensure_ascii=False, indent=2
                )
            )


if __name__ == "__main__":
    main()
