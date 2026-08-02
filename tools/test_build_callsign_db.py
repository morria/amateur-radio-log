#!/usr/bin/env python3
"""Tests for build-callsign-db.py.  Run: python3 tools/test_build_callsign_db.py"""

import importlib.util
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "build_callsign_db", Path(__file__).with_name("build-callsign-db.py"))
build = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(build)


class GridSquareTests(unittest.TestCase):
    """Reference locators taken from published station locations."""

    def test_known_locations(self):
        cases = [
            # ARRL HQ, Newington CT -> FN31 (W1AW's published grid).
            (41.714, -72.727, "FN31"),
            # Princeton NJ -> FN20.
            (40.357, -74.667, "FN20"),
            # San Juan PR -> FK68.
            (18.42, -66.06, "FK68"),
            # Honolulu HI -> BL11.
            (21.31, -157.86, "BL11"),
            # Central London, just west of the prime meridian -> IO91.
            (51.5, -0.13, "IO91"),
        ]
        for lat, lon, expected in cases:
            with self.subTest(grid=expected):
                self.assertEqual(build.grid_square(lat, lon), expected)

    def test_prime_meridian_is_the_field_boundary(self):
        # Longitude 0 is the first column of field J, not the last of I.
        self.assertEqual(build.grid_square(51.5, 0.0), "JO01")
        self.assertEqual(build.grid_square(51.5, -0.001), "IO91")

    def test_extremes_stay_in_range(self):
        self.assertEqual(build.grid_square(-90.0, -180.0), "AA00")
        # The poles/dateline corner must not roll past the 'R' field.
        self.assertEqual(build.grid_square(90.0, 180.0), "RR99")

    def test_rejects_out_of_range(self):
        self.assertIsNone(build.grid_square(91.0, 0.0))
        self.assertIsNone(build.grid_square(0.0, -181.0))


class NameTests(unittest.TestCase):
    def test_uniform_case_is_title_cased(self):
        self.assertEqual(build.normalize_first_name("CURTIS"), "Curtis")
        self.assertEqual(build.normalize_first_name("mary ann"), "Mary Ann")
        self.assertEqual(build.normalize_first_name("MARY-ANN"), "Mary-Ann")
        self.assertEqual(build.normalize_first_name("O'BRIEN"), "O'Brien")

    def test_deliberate_mixed_case_is_preserved(self):
        self.assertEqual(build.normalize_first_name("McDonald"), "McDonald")
        self.assertEqual(build.normalize_first_name("deWitt"), "deWitt")

    def test_whitespace(self):
        self.assertEqual(build.normalize_first_name("  JOHN   PAUL "), "John Paul")
        self.assertIsNone(build.normalize_first_name("   "))
        self.assertIsNone(build.normalize_first_name(""))


class GridForTests(unittest.TestCase):
    CENTROIDS = {"06111": (41.714, -72.727)}

    def test_zip_centroid(self):
        self.assertEqual(build.grid_for("06111", "CT", self.CENTROIDS), "FN31")

    def test_zip_plus_four_is_truncated(self):
        self.assertEqual(build.grid_for("061114321", "CT", self.CENTROIDS), "FN31")

    def test_unknown_zip_falls_back_to_territory(self):
        self.assertEqual(build.grid_for("96910", "GU", self.CENTROIDS), "QK23")

    def test_unknown_zip_in_a_state_has_no_grid(self):
        # A state centroid would span several squares, so no guess is made.
        self.assertIsNone(build.grid_for("99999", "TX", self.CENTROIDS))


HD = "|".join([""] * 59)
EN = "|".join([""] * 30)


def hd_record(usi, callsign, status="A", service="HA", expires="01/01/2099"):
    row = HD.split("|")
    row[0], row[build.HD_USI] = "HD", str(usi)
    row[build.HD_CALLSIGN], row[build.HD_STATUS] = callsign, status
    row[build.HD_SERVICE], row[build.HD_EXPIRED] = service, expires
    return "|".join(row)


def en_record(usi, callsign, first="", zip_code="", state="", entity="L"):
    row = EN.split("|")
    row[0], row[build.EN_USI] = "EN", str(usi)
    row[build.EN_CALLSIGN], row[build.EN_ENTITY_TYPE] = callsign, entity
    row[build.EN_FIRST_NAME] = first
    row[build.EN_STATE], row[build.EN_ZIP] = state, zip_code
    return "|".join(row)


class PipelineTests(unittest.TestCase):
    """End-to-end over synthetic .dat files with the real column layout."""

    CENTROIDS = {"06111": (41.714, -72.727), "08540": (40.357, -74.667)}

    def build(self, hd_rows, en_rows, include_expired=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "HD.dat").write_text("\n".join(hd_rows) + "\n", encoding="latin-1")
            (root / "EN.dat").write_text("\n".join(en_rows) + "\n", encoding="latin-1")
            active = build.active_license_ids(root / "HD.dat", include_expired)
            out = root / "out.sqlite"
            build.write_database(
                out, build.entries(root / "EN.dat", active, self.CENTROIDS), {})
            connection = sqlite3.connect(out)
            rows = dict((c, (n, g)) for c, n, g in
                        connection.execute("SELECT callsign, first_name, grid FROM callsigns"))
            connection.close()
            return rows

    def test_active_licensee_becomes_a_row(self):
        rows = self.build([hd_record(1, "W1AW")],
                          [en_record(1, "W1AW", "HIRAM", "06111", "CT")])
        self.assertEqual(rows, {"W1AW": ("Hiram", "FN31")})

    def test_cancelled_and_expired_licenses_are_dropped(self):
        rows = self.build(
            [hd_record(1, "K1AAA", status="C"),
             hd_record(2, "K1BBB", status="E"),
             hd_record(3, "K1CCC", expires="01/01/2001")],
            [en_record(1, "K1AAA", "ANNE", "06111", "CT"),
             en_record(2, "K1BBB", "BOB", "06111", "CT"),
             en_record(3, "K1CCC", "CARL", "06111", "CT")])
        self.assertEqual(rows, {})

    def test_include_expired_keeps_grace_period_licenses(self):
        rows = self.build([hd_record(3, "K1CCC", expires="01/01/2001")],
                          [en_record(3, "K1CCC", "CARL", "06111", "CT")],
                          include_expired=True)
        self.assertEqual(rows, {"K1CCC": ("Carl", "FN31")})

    def test_vanity_service_is_included(self):
        rows = self.build([hd_record(1, "W1AW", service="HV")],
                          [en_record(1, "W1AW", "HIRAM", "06111", "CT")])
        self.assertIn("W1AW", rows)

    def test_non_amateur_service_is_excluded(self):
        rows = self.build([hd_record(1, "KA12345", service="CB")],
                          [en_record(1, "KA12345", "SAM", "06111", "CT")])
        self.assertEqual(rows, {})

    def test_club_without_a_first_name_keeps_its_grid(self):
        rows = self.build([hd_record(1, "W1AW")],
                          [en_record(1, "W1AW", "", "06111", "CT")])
        self.assertEqual(rows, {"W1AW": (None, "FN31")})

    def test_row_with_neither_name_nor_grid_is_dropped(self):
        rows = self.build([hd_record(1, "W1AW")],
                          [en_record(1, "W1AW", "", "99999", "TX")])
        self.assertEqual(rows, {})

    def test_contact_records_are_ignored(self):
        rows = self.build([hd_record(1, "W1AW")],
                          [en_record(1, "W1AW", "AGENT", "06111", "CT", entity="CL")])
        self.assertEqual(rows, {})

    def test_entity_without_a_matching_license_is_ignored(self):
        rows = self.build([hd_record(1, "W1AW")],
                          [en_record(1, "W1AW", "HIRAM", "06111", "CT"),
                           en_record(2, "K2XYZ", "OTHER", "08540", "NJ")])
        self.assertEqual(rows, {"W1AW": ("Hiram", "FN31")})

    def test_malformed_lines_are_skipped(self):
        rows = self.build([hd_record(1, "W1AW"), "garbage line", ""],
                          [en_record(1, "W1AW", "HIRAM", "06111", "CT"),
                           "EN|truncated|record"])
        self.assertEqual(rows, {"W1AW": ("Hiram", "FN31")})

    def test_duplicate_callsign_keeps_one_row(self):
        # A vanity grant can briefly leave two active records for one call.
        rows = self.build([hd_record(1, "W1AW"), hd_record(2, "W1AW")],
                          [en_record(1, "W1AW", "HIRAM", "06111", "CT"),
                           en_record(2, "W1AW", "HIRAM", "08540", "NJ")])
        self.assertEqual(len(rows), 1)

    def test_metadata_records_the_row_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out.sqlite"
            build.write_database(out, [("W1AW", "Hiram", "FN31")],
                                 {"schema_version": "1"})
            connection = sqlite3.connect(out)
            meta = dict(connection.execute("SELECT key, value FROM metadata"))
            connection.close()
        self.assertEqual(meta["row_count"], "1")
        self.assertEqual(meta["schema_version"], "1")


if __name__ == "__main__":
    unittest.main(verbosity=2)
