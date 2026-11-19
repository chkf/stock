import csv
import tempfile
from collections import Counter
from copy import deepcopy
from datetime import date
from pathlib import Path
from unittest import TestCase
from unittest.mock import patch

import catalog as c
import daily_assets as daily


class DailyAssetTests(TestCase):
    @classmethod
    def setUpClass(cls):
        cls.day = "2026-11-19"
        cls.data = c.read(
            c.DEFAULT / "daily-assets" / cls.day / "trading-evidence.json"
        )
        cls.version = cls.data["generation"]
        cls.state = c.read(c.DEFAULT / cls.version / "catalog.json")
        cls.rows = daily.universe(cls.state)
        cls.rules = c.read(daily.RULES)

    def test_preserve_members_and_risk_distinctions(self):
        mapping = daily.classify(self.rows, self.rules, self.day)
        self.assertEqual(set(mapping), set(self.rows))
        self.assertEqual(len(mapping), 97)
        counts = Counter(entry[0] for entry in mapping.values())
        self.assertNotIn("", counts)
        self.assertEqual((counts["credit-scitech"], counts["credit-mm"]), (24, 8))
        self.assertEqual(
            len(
                {
                    mapping[s][0]
                    for s in (
                        "511160.SH",
                        "511260.SH",
                        "511090.SH",
                        "511220.SH",
                        "511270.SH",
                        "511180.SH",
                        "511380.SH",
                    )
                }
            ),
            7,
        )
        self.assertEqual(
            len({mapping[s][0] for s in ("159985.SZ", "159980.SZ", "159981.SZ")}), 3
        )
        self.assertEqual(
            Counter(e[1] for e in mapping.values() if e[0] == "gold"),
            {"AU9999": 7, "SHAU": 7},
        )
        self.assertEqual(counts["money"], 27)
        self.assertEqual({e[1] for e in mapping.values() if e[0] == "money"}, {""})
        self.assertNotIn(
            "517520.SH", mapping
        )  # Gold mining equities have their own stock index.

    def test_hold_changed_or_unverified_product_for_review(self):
        changed = {
            "518880.SH": {"profile_index": "修订后基准"},
            "159934.SZ": {"full_name": "变更后的基金全称"},
            "511090.SH": {"canonical_code": "NEW"},
            "511880.SH": {"exchange_type": "未知"},
            "159985.SZ": {"conflicts": ["指数标的冲突"]},
            "159005.SZ": {"trading_currency": "未知"},
        }
        rows = {s: {**self.rows[s], **diff} for s, diff in changed.items()}
        mapped = daily.classify(rows, self.rules, self.day)
        self.assertEqual(set(mapped), set(changed))
        self.assertTrue(all(not item[0] for item in mapped.values()))
        before = daily.classify(
            {"518880.SH": self.rows["518880.SH"]}, self.rules, "2026-11-18"
        )
        self.assertFalse(before["518880.SH"][0])

    def test_representative_needs_ten_positive_days_and_a_dated_trade(self):
        data = deepcopy(self.data)

        def thirty_year():
            seats, *_ = daily.screen(self.state, self.version, self.rules, data)
            return next(
                (s, rep) for group, s, rep in seats if group["id"] == "treasury-thirty"
            )

        symbols, best = thirty_year()
        self.assertEqual(best, "511090.SH")
        (alternate,) = set(symbols) - {best}
        data["spot"]["quotes"][best]["at"] = "2026-11-18T15:00:00+08:00"
        self.assertEqual(thirty_year(), (symbols, alternate))
        data["amounts"][alternate][0] = "0"
        self.assertEqual(thirty_year(), (symbols, None))
        data["spot"]["quotes"][best].update(at="2026-11-19T11:25:00+08:00", lots=0)
        self.assertEqual(thirty_year(), (symbols, None))

    def test_reject_incomplete_or_mismatched_evidence(self):
        for broken in ("generation", "amounts", "quotes"):
            data = deepcopy(self.data)
            if broken == "generation":
                data[broken] = "other"
            elif broken == "quotes":
                data["spot"]["quotes"].pop("511880.SH")
            else:
                data["amounts"].pop("511880.SH")
            with self.subTest(broken=broken), self.assertRaises(ValueError):
                daily.screen(self.state, self.version, self.rules, data)

    def test_rebuild_combined_list_and_audit_every_trade(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            result = daily.write_reports(
                out, self.state, self.version, self.rules, self.data
            )
            self.assertEqual(
                (result["added"], result["stock"], result["total"]), (25, 84, 109)
            )
            self.assertEqual(
                result["by_asset"], {"债券": 20, "货币": 1, "黄金": 1, "商品期货": 3}
            )
            with (out / "watchlist.csv").open(encoding="utf-8-sig", newline="") as f:
                watch = list(csv.DictReader(f))
            with (out / "members.csv").open(encoding="utf-8-sig", newline="") as f:
                members = list(csv.DictReader(f))
            self.assertCountEqual((r["交易代码"] for r in members), self.rows.keys())
            reps = {r["交易代码"] for r in members if r["本次代表"] == "True"}
            self.assertCountEqual(
                (r["非股票代表ETF"] for r in watch if r["非股票代表ETF"]), reps
            )
            self.assertEqual(len(reps), 25)
            for row in members:
                if row["交易代码"] in reps:
                    self.assertEqual(
                        (row["十日正成交日数"], row["当日已有成交"]), ("10", "True")
                    )
            with (c.DEFAULT / "equity-indices" / self.day / "watchlist.csv").open(
                encoding="utf-8-sig", newline=""
            ) as f:
                self.assertCountEqual(
                    (r["指数或现货代码"] for r in watch if r["类别"] == "股票板块"),
                    (
                        r["观察指数代码"]
                        for r in csv.DictReader(f)
                        if r["状态"] == "可观察"
                    ),
                )

    def test_reject_duplicate_quotes(self):
        fields = [""] * 31
        fields[2], fields[6], fields[30] = "511880", "30", "20261119112400"
        reply = ('v_sh511880="' + "~".join(fields) + '";').encode("gb18030")
        with (
            patch.object(daily, "get", return_value=reply * 2),
            self.assertRaises(ValueError),
        ):
            daily.quote_batch({"511880.SH"})

    def test_collect_rejects_an_old_window_even_if_it_ended_on_a_trading_day(self):
        sessions = {date.fromisoformat(day): "1" for day in self.data["sessions"]}
        with patch("sector_seats.quote_days", return_value=sessions) as calendar:
            with self.assertRaises(ValueError):
                daily.collect_symbol_turnover(
                    self.state, self.version, daily.SCOPE, date(2026, 11, 17), set(), latest_only=True
                )
            self.assertEqual(calendar.call_args.args[2], date(2026, 11, 18))
