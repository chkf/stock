import hashlib
from copy import deepcopy
from unittest import TestCase

import catalog as c
import sector_seats as ss
from test_catalog import RULES, product, snap


class SectorSeatTests(TestCase):
    def setUp(self):
        self.rules = {
            "version": "test",
            "boards": [
                {
                    "id": "broker",
                    "name": "证券公司",
                    "core": {"399975": "中证全指证券公司指数"},
                    "variants": {"931412": "中证证券公司30指数"},
                    "difference": "样本数量不同。",
                }
            ],
        }
        self.rows = {
            "512001.SH": product("399975", "中证全指证券公司指数"),
            "512002.SH": product("399975", "中证全指证券公司指数"),
            "512003.SH": product("931412", "中证证券公司30指数"),
            "512004.SH": product("399975", "中证全指证券公司指数", conflicts=["待核"]),
        }
        self.state = c.build(snap(self.rows, day="2026-11-19"), {}, RULES)
        self.data = {
            "generation": "demo",
            "rule_sha256": hashlib.sha256(c.encoded(self.rules)).hexdigest(),
            "source": ss.QUOTE,
            "unit": "万元人民币",
            "sessions": [
                f"2026-11-{d:02d}" for d in (5, 6, 9, 10, 11, 12, 13, 16, 17, 18)
            ],
            "through": "2026-11-18",
            "amounts": {
                "512001.SH": ["10"] * 9 + ["99999"],
                "512002.SH": ["12"] * 10,
            },
        }

    def test_one_liquid_core_and_all_members_traced(self):
        members, slots, _, _, ranks, chosen, counts = ss.screen(
            self.state, "demo", self.rules, self.data
        )
        self.assertEqual(chosen, {"broker": "512002.SH"})
        self.assertEqual(ranks, {"512002.SH": 1, "512001.SH": 2})
        self.assertEqual(members["broker"]["512003.SH"], "variants")
        self.assertNotEqual(slots["512004.SH"], "sector:broker")
        self.assertEqual(set(slots), set(self.state["records"]))
        self.assertEqual(counts["total_seats"], counts["sectors"] + counts["outside"])

    def test_no_complete_window_and_stable_ties(self):
        oldest = self.state["records"]["512002.SH"]
        oldest["listing_date"] = "2010-05-04"
        self.data["amounts"]["512002.SH"] = ["10"] * 10
        self.assertEqual(
            ss.screen(self.state, "demo", self.rules, self.data)[5]["broker"],
            "512002.SH",
        )
        self.data["amounts"]["512002.SH"][-1] = "0"
        self.data["amounts"]["512001.SH"][0] = None
        *_, chosen, counts = ss.screen(self.state, "demo", self.rules, self.data)
        self.assertEqual(chosen, {})
        self.assertEqual((counts["sectors"], counts["represented"]), (1, 0))

    def test_changed_index_title_and_foreign_exposure_do_not_match(self):
        self.state["records"]["512002.SH"]["canonical_index"] = "不同指数"
        self.state["records"]["512001.SH"]["region"] = "香港"
        board = ss.sector_members(self.state, self.rules)["broker"]
        self.assertEqual(board, {"512003.SH": "variants"})
        duplicate = deepcopy(self.rules["boards"][0])
        duplicate["id"] = "other"
        self.rules["boards"].append(duplicate)
        with self.assertRaisesRegex(ValueError, "assigned twice"):
            ss.sector_members(self.state, self.rules)

    def test_missing_quotes_future_data_or_split_B_are_rejected(self):
        for change in ("missing", "session", "future", "negative", "rules"):
            data = deepcopy(self.data)
            if change == "missing":
                del data["amounts"]["512002.SH"]
            elif change == "session":
                data["sessions"][0] = data["sessions"][1]
            elif change == "future":
                data["through"] = data["sessions"][-1] = "2026-11-19"
            elif change == "negative":
                data["amounts"]["512002.SH"][0] = "-1"
            else:
                data["rule_sha256"] = "incorrect"
            with self.subTest(change=change), self.assertRaises(ValueError):
                ss.screen(self.state, "demo", self.rules, data)
        self.state["records"]["510300.SH"]["proposal"] = self.state["records"][
            "512001.SH"
        ]["proposal"]
        with self.assertRaisesRegex(ValueError, "spans multiple"):
            ss.screen(self.state, "demo", self.rules, self.data)
