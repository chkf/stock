import csv
import tempfile
from pathlib import Path
from unittest import TestCase

import catalog as c
import equity_indices as eq
from test_catalog import RULES, product, snap


class EquityIndexTests(TestCase):
    def setUp(self):
        self.rules = c.read(eq.RULES)

    def test_equity_only_including_gold_miners(self):
        rows = {
            "517520.SH": product("931238", "中证沪深港黄金产业股票指数"),
            "518880.SH": product(
                "AU9999", "上海黄金交易所黄金现货", exchange_type="38"
            ),
            "511260.SH": product("000000", "上证10年期国债指数", exchange_type="02"),
            "511990.SH": product("000001", "货币市场指数", exchange_type="05"),
        }
        state = c.build(snap(rows), {}, RULES)
        groups, _, excluded = eq.equity_universe(state, self.rules)
        self.assertIn(("931238", "中证沪深港黄金产业股票指数"), groups)
        self.assertEqual(dict(excluded), {"债券": 1, "货币": 1, "商品": 1})
        state["records"]["517520.SH"]["present"] = False
        groups, _, excluded = eq.equity_universe(state, self.rules)
        self.assertNotIn(("931238", "中证沪深港黄金产业股票指数"), groups)
        self.assertEqual(excluded["本次未见"], 1)

    def test_official_aliases_and_distinct_return_series(self):
        rows = {
            "510001.SH": product("000905", "中证小盘500指数"),
            "159001.SZ": product("399905", "中证500指数"),
            "513001.SH": product("SPX", "标普500指数"),
            "513002.SH": product("SPXNTR", "标准普尔500指数"),
        }
        groups, _, _ = eq.equity_universe(c.build(snap(rows), {}, RULES), self.rules)
        self.assertEqual(len(groups["000905", "中证500指数"]), 2)
        self.assertIn(("SPX", "标普500指数（价格）"), groups)
        self.assertIn(("SPXNTR", "标普500指数（净总收益）"), groups)

    def test_unknown_versions_and_unresolved_product_do_not_create_an_index(self):
        rows = {
            "513001.SH": product("A1", "同名股票指数"),
            "513002.SH": product("A2", "同名股票指数"),
            "513003.SH": product("N225", "日经225指数", profile_index="其他指数"),
            "513004.SH": product("A4", "主动参考指数", profile_index="无跟踪标的"),
        }
        groups, pending, _ = eq.equity_universe(
            c.build(snap(rows), {}, RULES), self.rules
        )
        self.assertEqual(set(pending), set(rows))
        self.assertEqual(
            len(groups), 1
        )  # The fixture supplies two ordinary CSI 300 ETFs.

    def test_watchlist_keeps_its_benchmark_when_an_etf_changes_target(self):
        state = c.build(snap(), {}, RULES)
        sectors = [("示例", "000300", "沪深300指数")]
        state["records"]["510300.SH"].update(
            canonical_code="999999", canonical_index="变更后指数"
        )
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            eq.write_tables(state, "fixture", self.rules, sectors, folder)
            with (folder / "watchlist.csv").open(encoding="utf-8-sig") as f:
                watch = list(csv.DictReader(f))
            self.assertEqual(watch[0]["观察指数代码"], "000300")
            self.assertEqual(watch[0]["已映射产品数"], "1")
            self.assertNotIn("基金代码", watch[0])
            state["records"]["159919.SZ"]["present"] = False
            eq.write_tables(state, "fixture", self.rules, sectors, folder)
            with (folder / "watchlist.csv").open(encoding="utf-8-sig") as f:
                self.assertEqual(next(csv.DictReader(f))["状态"], "当前映射待核")
