from collections import Counter
from unittest import TestCase
from unittest.mock import patch

import catalog as c
import phone_input


class PhoneInputTests(TestCase):
    day = "2026-11-19"

    def test_archived_phone_input_matches_dated_evidence(self):
        payload = phone_input.build(c.DEFAULT, self.day)
        self.assertEqual(
            payload,
            c.read(c.DEFAULT / "phone-workspace" / self.day / "etf-universe.json"),
        )
        rows = payload["directions"]
        self.assertEqual(len({r["etf"] for r in rows}), 109)
        self.assertEqual(
            Counter(r["signal_type"] for r in rows),
            {"index": 107, "gold_spot": 1, "cash_income": 1},
        )
        self.assertTrue(all(len(r["turnover_10d_wan"]) == 10 for r in rows))
        (cash,) = (r for r in rows if r["signal_type"] == "cash_income")
        self.assertIsNone(cash["signal_code"])
        self.assertEqual(cash["etf"], "511880.SH")

    def test_reject_wrong_stock_to_index_mapping(self):
        read = phone_input.csv_rows

        def bad_map(path):
            rows = read(path)
            if path.name == "fund-map.csv":
                mapped = next(r for r in rows if r["基金代码"] == "512480.SH")
                mapped["观察指数代码"] = "wrong"
            return rows

        with patch.object(phone_input, "csv_rows", side_effect=bad_map):
            with self.assertRaisesRegex(ValueError, "does not track"):
                phone_input.build(c.DEFAULT, self.day)
