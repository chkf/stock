import csv
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile
from io import BytesIO

import catalog as c
import sources
from classify import classification
from exchange_files import pcf_headers, bulk_table

RULES = c.read(c.HERE / "rules.json")
U = sources.UNKNOWN


def product(code="000300", name="沪深300指数", manager="甲基金", **extra):
    data = dict(
        index_code=code,
        exchange_index=name,
        profile_index=name,
        profile_type="ETF",
        full_name="沪深300交易型开放式指数证券投资基金",
        short_name="300ETF",
        exchange_type="03",
        listing_date="2012-05-28",
        manager=manager,
        conflicts=[],
    )
    return {**data, **extra}


def snap(rows=None, day="2026-11-18"):
    rows = dict(rows or {})
    rows.setdefault("159919.SZ", product(exchange_type="股票基金", manager="乙基金"))
    rows.setdefault("510300.SH", product())
    m = {}
    for ex in ("SH", "SZ"):
        codes = [s[:6] for s in rows if s.endswith(ex)]
        m[ex] = dict(total=len(codes), codes_sha256=sources._codes_digest(codes))
    return dict(
        observed_at=day,
        markets=m,
        records=rows,
        sources={
            "SSE_FUND_LIST": m["SH"],
            "SZSE_fund_etf": dict(m["SZ"], source_asof=day),
        },
    )


class CatalogTests(unittest.TestCase):
    def test_exchange_alias_and_explicit_variant(self):
        state = c.build(
            snap({"159919.SZ": product("399300 沪深300", exchange_type="股票基金")}),
            {},
            RULES,
        )
        self.assertEqual(c.summary(state)["A"], 1)
        localized = product("000300", "沪深300全收益指数")
        other = c.build(snap({"510399.SH": localized}), {}, RULES)
        self.assertTrue(other["records"]["510399.SH"]["review"])
        self.assertNotEqual(
            other["records"]["510399.SH"]["strict"],
            other["records"]["510300.SH"]["strict"],
        )

    def test_ordinary_funds_filtered_and_disputed_etf_retained(self):
        common = dict(
            jjjcurl="基金", glrmc="管理人", ssrq="2026-10-19", tzlb="股票基金"
        )
        funds = {
            "159001": dict(common, jjlb="ETF"),
            "160001": dict(common, jjlb="LOF"),
            "090001": dict(common, jjlb="普通场外指数基金"),
        }
        assembled = sources.assemble(
            {},
            {},
            {},
            {"source_asof": "2026-11-18"},
            funds,
            {"source_asof": "2026-11-18"},
            {"159001.SZ": {}},
            "2026-11-19",
        )
        self.assertEqual(list(assembled["records"]), ["159001.SZ"])
        self.assertTrue(assembled["records"]["159001.SZ"]["conflicts"])
        self.assertTrue(
            classification("159001.SZ", assembled["records"]["159001.SZ"], RULES)[
                "review"
            ]
        )

    def test_cross_manager_and_mapping(self):
        state = c.build(snap(), {}, RULES)
        self.assertEqual((c.summary(state)["products"], c.summary(state)["A"]), (2, 1))
        with tempfile.TemporaryDirectory() as tmp:
            c.export(state, Path(tmp))
            with (Path(tmp) / "members.csv").open(encoding="utf-8-sig") as f:
                rows = list(csv.reader(f))[1:]
            self.assertEqual({r[0] for r in rows}, set(state["records"]))
            self.assertEqual(len({r[-1] for r in rows}), 1)

    def test_direction_proposal_requires_named_pair(self):
        a = product("399975", "中证全指证券公司指数")
        b = product("931412", "中证证券公司30指数")
        d = product("399986", "中证银行指数")
        s = c.build(snap({"512000.SH": a, "512001.SH": b, "512002.SH": d}), {}, RULES)[
            "records"
        ]
        self.assertNotEqual(s["512000.SH"]["strict"], s["512001.SH"]["strict"])
        self.assertEqual(s["512000.SH"]["proposal"], s["512001.SH"]["proposal"])
        self.assertTrue(s["512000.SH"]["proposal_loss"])
        self.assertNotEqual(s["512000.SH"]["proposal"], s["512002.SH"]["proposal"])

    def test_style_maturity_credit_and_region(self):
        pairs = [
            ("红利指数", "红利低波动指数"),
            ("上证5年期国债指数", "上证10年期国债指数"),
            ("中证AAA科技创新公司债指数", "上证10年期国债指数"),
            ("纳斯达克100指数", "标普500指数"),
            ("中证沪深港黄金产业股票指数", "上海金"),
        ]
        for left, right in pairs:
            a = classification("510111.SH", product("000101", left), RULES)
            b = classification("510112.SH", product("000102", right), RULES)
            self.assertNotEqual(a["proposal"], b["proposal"])
        self.assertEqual(
            classification(
                "510002.SH", product("123456", "沪深300非银行金融指数"), RULES
            )["direction"],
            "非银金融",
        )

    def test_product_mechanism_and_missing_fields(self):
        rows = {
            f"51000{i}.SH": r
            for i, r in enumerate(
                [
                    product(),
                    product(full_name="增强策略交易型开放式指数证券投资基金"),
                    product(index_code=U),
                    product(full_name=U),
                    product(full_name="货币对冲交易型开放式指数证券投资基金"),
                ]
            )
        }
        state = c.build(snap(rows), {}, RULES)
        self.assertEqual(len({state["records"][s]["strict"] for s in rows}), 5)
        self.assertTrue(all(state["records"][s]["review"] for s in list(rows)[1:]))
        self.assertEqual(c.summary(state)["products"], len(state["records"]))

    def test_ambiguous_code_segregated(self):
        state = c.build(snap({"510301.SH": product(name="中证银行指数")}), {}, RULES)
        self.assertEqual(c.summary(state)["review"], 3)
        self.assertEqual(c.summary(state)["B"], 3)

    def test_rename_retarget_absent_reappear(self):
        sym = "510301.SH"
        s1 = c.build(snap({sym: product()}), {}, RULES)
        s2 = c.build(snap({sym: product(short_name="新简称")}, "2026-11-19"), s1, RULES)
        r = s2["records"][sym]
        self.assertEqual(r["first_seen"], "2026-11-18")
        self.assertEqual(r["strict"], s1["records"][sym]["strict"])
        self.assertIn("short_name", r["changes"][-1]["fields"])
        s3 = c.build(
            snap({sym: product("399986", "中证银行指数")}, "2026-11-20"), s2, RULES
        )
        self.assertNotEqual(s3["records"][sym]["strict"], r["strict"])
        s4 = c.build(snap(day="2026-11-21"), s3, RULES)
        missing = s4["records"][sym]
        self.assertEqual(missing["last_seen"], "2026-11-20")
        self.assertEqual(missing["listing_date"], "2012-05-28")
        self.assertFalse(missing["present"])
        self.assertEqual(c.summary(s4)["absent_retained"], 1)
        self.assertEqual(c.summary(s4)["A"], 2)
        s5 = c.build(
            snap({sym: product("399986", "中证银行指数")}, "2026-11-22"), s4, RULES
        )
        self.assertEqual(s5["records"][sym]["strict"], s3["records"][sym]["strict"])
        self.assertEqual(s5["records"][sym]["changes"][-1]["reason"], "重新出现")

    def test_all_five_incremental_cases(self):
        base = c.build(
            snap({"512000.SH": product("399975", "中证全指证券公司指数")}), {}, RULES
        )
        s = c.build(
            snap(
                {
                    "512000.SH": product("399975", "中证全指证券公司指数"),
                    "512001.SH": product("931412", "中证证券公司30指数"),
                    "512002.SH": product(),
                    "512003.SH": product("399986", "中证银行指数"),
                    "512004.SH": product(index_code=U),
                },
                "2026-11-19",
            ),
            base,
            RULES,
        )["records"]
        kinds = [s[f"51200{i}.SH"]["first_match"] for i in range(1, 5)]
        self.assertEqual(
            kinds,
            [
                "已有方向中的新指数或新暴露",
                "已有严格重复组的新成员",
                "全新投资方向",
                "信息不足，待核",
            ],
        )
        self.assertEqual(
            c.match(s["512000.SH"], base["records"]["512000.SH"], set(), set()),
            "已有证券的信息更新",
        )

    def test_server_cap_duplicates_short_and_total_change(self):
        def page(n):
            return (
                3,
                2,
                2,
                "day",
                n,
                [{"c": "000001"}, {"c": "000002"}] if n == 1 else [{"c": "000003"}],
            )

        rows, meta = sources.paged(page, "c")
        self.assertEqual(meta["page_lengths"], [2, 1])
        self.assertEqual(len(rows), 3)
        for bad in (
            (3, 2, 2, "day", 2, [{"c": "000001"}]),
            (3, 2, 2, "day", 2, []),
            (4, 2, 2, "day", 2, [{"c": "000003"}]),
            page(1),
        ):
            with self.assertRaises(ValueError):
                sources.paged(lambda n: page(1) if n == 1 else bad, "c")

    def test_bulk_report_rejects_incomplete_and_wrong_sheet(self):
        rows = [
            {"A": "证券代码", "B": "证券简称", "C": "拟合指数", "D": "基金管理人"},
            {"A": "159919", "B": "300ETF", "C": "399300", "D": "嘉实基金"},
        ]
        with patch("exchange_files.xlsx_rows", return_value=rows):
            result, meta = bulk_table(
                b"bytes", "fund_etf", (1, 1, 10, "day", 1, [{"sys_key": "159919"}])
            )
            self.assertEqual(result["159919"]["nhzs"], "399300")
            with self.assertRaises(ValueError):
                bulk_table(
                    b"bytes",
                    "fund_etf",
                    (
                        2,
                        1,
                        10,
                        "day",
                        1,
                        [{"sys_key": "159919"}, {"sys_key": "159920"}],
                    ),
                )

    def test_pcf_requires_internal_code_and_trading_date(self):
        buf = BytesIO()
        with ZipFile(buf, "w") as z:
            z.writestr(
                "SZ/159919.SZ.xml",
                '<PCFFile xmlns="http://ts.szse.cn/Fund"><SecurityID>159919</SecurityID><SecurityIDSource>102</SecurityIDSource><TradingDay>20261118</TradingDay></PCFFile>',
            )
        self.assertIn("159919", pcf_headers(buf.getvalue(), "20261118"))
        with self.assertRaises(ValueError):
            pcf_headers(buf.getvalue(), "20261119")

    def test_atomic_failure_idempotence_and_stability(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = c.publish(snap(), root, RULES)
            self.assertEqual(c.publish(snap(), root, RULES), first)
            new_export = snap()
            new_export["sources"]["SZSE_fund_etf"]["xlsx_sha256"] = (
                "new ZIP container metadata"
            )
            self.assertEqual(c.publish(new_export, root, RULES), first)
            bad = snap()
            del bad["records"]["159919.SZ"]
            with self.assertRaises(ValueError):
                c.publish(bad, root, RULES)
            with (
                patch("catalog.export", side_effect=OSError("disk full")),
                self.assertRaises(OSError),
            ):
                c.publish(snap(day="2026-11-19"), root, RULES)
            self.assertEqual(c.current(root)[1], first.name)
            with self.assertRaises(ValueError):
                c.publish(snap(day="2026-11-17"), root, RULES)
            second = c.publish(snap(day="2026-11-19"), root, RULES)
            before, after = (
                c.read(p / "catalog.json")["records"] for p in (first, second)
            )
            self.assertEqual(
                {s: r["strict"] for s, r in before.items()},
                {s: r["strict"] for s, r in after.items()},
            )


if __name__ == "__main__":
    unittest.main()
