#!/usr/bin/env python3
"""Build the bundled callsign lookup database from FCC ULS license data.

Produces a small, read-only SQLite file mapping a US amateur callsign to the
licensee's first name and 4-character Maidenhead grid square. Amateur Radio
Log bundles the result and consults it before hitting QRZ/HamQTH, so the
common case (a US callsign) resolves instantly and offline.

Two public-domain sources are joined:

  * FCC ULS "complete" amateur license database (l_amat.zip). Pipe-separated
    fixed-column .dat files; this script reads HD.dat (license status) and
    EN.dat (licensee name and mailing address).
  * Census Bureau ZCTA gazetteer, for a latitude/longitude centroid per ZIP
    code. The FCC publishes a mailing address but no coordinates, so the
    grid square is derived from the ZIP centroid.

A 4-character grid square is 1 degree of latitude by 2 degrees of longitude
(roughly 111 x 150 km in the lower 48), which is one to two orders of
magnitude coarser than the error introduced by collapsing a ZIP code to its
centroid -- so the derived square matches the licensee's own 4-character
grid except for addresses within a few km of a square boundary.

Usage:
    tools/build-callsign-db.py                       # download + build in place
    tools/build-callsign-db.py --out /tmp/calls.sqlite
    tools/build-callsign-db.py --source ./l_amat     # reuse unpacked .dat files

See tools/README-callsign-db.md for the schema and refresh cadence.
"""

from __future__ import annotations

import argparse
import datetime as dt
import sqlite3
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ULS_URL = "https://data.fcc.gov/download/pub/uls/complete/l_amat.zip"
GAZETTEER_URL = (
    "https://www2.census.gov/geo/docs/maps-data/data/gazetteer/"
    "2024_Gazetteer/2024_Gaz_zcta_national.zip"
)

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO_ROOT / "AmateurRadioLog/AmateurRadioLog/Resources/callsigns.sqlite"

SCHEMA_VERSION = "1"

# Amateur radio services in the ULS: HA (amateur) and HV (vanity call sign).
AMATEUR_SERVICE_CODES = {"HA", "HV"}

# Column offsets (0-based) in the ULS pipe-separated records. Documented in
# the ULS public access database definitions; verified against a daily file.
HD_CALLSIGN, HD_STATUS, HD_SERVICE, HD_EXPIRED = 4, 5, 6, 8
HD_USI = 1
EN_USI, EN_CALLSIGN, EN_ENTITY_TYPE = 1, 4, 5
EN_FIRST_NAME, EN_STATE, EN_ZIP = 8, 17, 18

# ZIP centroids for US territories the Census ZCTA file does not cover. Each
# of these is small enough to sit inside a single 4-character grid square, so
# one centroid per territory is exact at this resolution.
TERRITORY_CENTROIDS = {
    "GU": (13.444, 144.794),   # Guam
    "MP": (15.187, 145.749),   # Northern Mariana Islands (Saipan)
    "AS": (-14.276, -170.702),  # American Samoa
    "PW": (7.515, 134.583),    # Palau
    "FM": (6.917, 158.185),    # Micronesia (Pohnpei)
    "MH": (7.089, 171.380),    # Marshall Islands (Majuro)
}


# --------------------------------------------------------------------------
# Maidenhead
# --------------------------------------------------------------------------

def grid_square(latitude: float, longitude: float) -> str | None:
    """4-character Maidenhead locator for a coordinate, or None if invalid."""
    if not (-90.0 <= latitude <= 90.0 and -180.0 <= longitude <= 180.0):
        return None
    lon = min(longitude + 180.0, 359.999999)
    lat = min(latitude + 90.0, 179.999999)
    field = f"{chr(ord('A') + int(lon // 20))}{chr(ord('A') + int(lat // 10))}"
    square = f"{int((lon % 20) // 2)}{int(lat % 10)}"
    return field + square


# --------------------------------------------------------------------------
# Names
# --------------------------------------------------------------------------

def normalize_first_name(raw: str) -> str | None:
    """Clean up a ULS first-name field for display.

    The FCC stores whatever the licensee typed, so casing is inconsistent
    ("CURTIS", "James", "james"). Uniformly-cased names are title-cased;
    anything already mixed-case is left alone so "McDonald" and "deWitt"
    survive. Initials keep their trailing period.
    """
    name = " ".join(raw.split())
    if not name:
        return None
    if name != name.upper() and name != name.lower():
        return name  # already deliberately mixed case
    return " ".join(_title_case_word(word) for word in name.split(" "))


def _title_case_word(word: str) -> str:
    """Capitalize each hyphen/apostrophe-separated part of one word.

    MARY-ANN -> Mary-Ann, O'BRIEN -> O'Brien. The separators are handled in a
    single pass; capitalizing on one separator and then the other would undo
    the first pass's work.
    """
    parts, start = [], 0
    for index, character in enumerate(word):
        if character in "-'":
            parts.append(word[start:index].capitalize())
            parts.append(character)
            start = index + 1
    parts.append(word[start:].capitalize())
    return "".join(parts)


# --------------------------------------------------------------------------
# Downloads
# --------------------------------------------------------------------------

def download(url: str, dest: Path) -> str:
    """Fetch `url` to `dest` (skipped if present); returns its Last-Modified."""
    if dest.exists():
        log(f"using cached {dest.name} ({dest.stat().st_size / 1e6:.0f} MB)")
        return ""
    log(f"downloading {url}")
    tmp = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(url) as response:
        last_modified = response.headers.get("Last-Modified", "")
        total = int(response.headers.get("Content-Length") or 0)
        read = 0
        with open(tmp, "wb") as handle:
            while chunk := response.read(1 << 20):
                handle.write(chunk)
                read += len(chunk)
                if total and sys.stderr.isatty():
                    print(f"\r  {read / 1e6:6.0f} / {total / 1e6:.0f} MB",
                          end="", file=sys.stderr)
        if total and sys.stderr.isatty():
            print(file=sys.stderr)
    tmp.rename(dest)
    return last_modified


def unpack(archive: Path, dest: Path, members: list[str] | None = None) -> Path:
    dest.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as zf:
        zf.extractall(dest, members=members)
    return dest


# --------------------------------------------------------------------------
# ULS parsing
# --------------------------------------------------------------------------

def read_records(path: Path, expected_prefix: str, min_columns: int):
    """Yield pipe-split ULS records, skipping malformed/continuation lines.

    ULS .dat files are latin-1 and occasionally contain a stray newline inside
    a free-text field, which shows up as a short line with the wrong record
    type. Those are dropped rather than guessed at.
    """
    with open(path, "r", encoding="latin-1", errors="replace") as handle:
        for line in handle:
            row = line.rstrip("\n").rstrip("\r").split("|")
            if len(row) < min_columns or row[0] != expected_prefix:
                continue
            yield row


def active_license_ids(hd_path: Path, include_expired: bool) -> set[int]:
    """Unique system identifiers of active amateur licenses in HD.dat."""
    today = dt.date.today()
    active: set[int] = set()
    skipped_expired = 0
    for row in read_records(hd_path, "HD", HD_EXPIRED + 1):
        if row[HD_STATUS] != "A" or row[HD_SERVICE] not in AMATEUR_SERVICE_CODES:
            continue
        # The FCC leaves a license "A" through its two-year grace period, so
        # the expiration date is what actually separates current licensees.
        if not include_expired and (expired := parse_uls_date(row[HD_EXPIRED])):
            if expired < today:
                skipped_expired += 1
                continue
        try:
            active.add(int(row[HD_USI]))
        except ValueError:
            continue
    if skipped_expired:
        log(f"skipped {skipped_expired:,} licenses past their expiration date")
    return active


def parse_uls_date(value: str) -> dt.date | None:
    try:
        return dt.datetime.strptime(value.strip(), "%m/%d/%Y").date()
    except ValueError:
        return None


def load_zip_centroids(gazetteer_path: Path) -> dict[str, tuple[float, float]]:
    """ZIP (ZCTA) -> (latitude, longitude) from the Census gazetteer."""
    centroids: dict[str, tuple[float, float]] = {}
    with open(gazetteer_path, "r", encoding="utf-8") as handle:
        header = handle.readline().split("\t")
        columns = {name.strip(): i for i, name in enumerate(header)}
        geoid_col = columns.get("GEOID", 0)
        lat_col = columns["INTPTLAT"]
        lon_col = columns["INTPTLONG"]
        for line in handle:
            fields = line.split("\t")
            if len(fields) <= lon_col:
                continue
            try:
                centroids[fields[geoid_col].strip().zfill(5)] = (
                    float(fields[lat_col]), float(fields[lon_col]))
            except ValueError:
                continue
    return centroids


def entries(en_path: Path, active: set[int],
            centroids: dict[str, tuple[float, float]]):
    """Yield (callsign, first_name, grid) for each active licensee in EN.dat."""
    for row in read_records(en_path, "EN", EN_ZIP + 1):
        try:
            usi = int(row[EN_USI])
        except ValueError:
            continue
        if usi not in active:
            continue
        # "L" is the licensee record; ULS also carries contact ("CL") rows
        # whose name is an agent rather than the operator.
        if row[EN_ENTITY_TYPE] != "L":
            continue
        callsign = row[EN_CALLSIGN].strip().upper()
        if not callsign:
            continue
        first_name = normalize_first_name(row[EN_FIRST_NAME])
        grid = grid_for(row[EN_ZIP], row[EN_STATE], centroids)
        # Club and military-recreation stations have no first name; they are
        # still worth a row when the grid resolves.
        if first_name is None and grid is None:
            continue
        yield callsign, first_name, grid


def grid_for(zip_code: str, state: str,
             centroids: dict[str, tuple[float, float]]) -> str | None:
    zip5 = "".join(ch for ch in zip_code if ch.isdigit())[:5]
    coordinate = centroids.get(zip5.zfill(5)) if zip5 else None
    if coordinate is None:
        coordinate = TERRITORY_CENTROIDS.get(state.strip().upper())
    if coordinate is None:
        return None
    return grid_square(*coordinate)


# --------------------------------------------------------------------------
# SQLite output
# --------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE callsigns (
    callsign   TEXT NOT NULL PRIMARY KEY,
    first_name TEXT,
    grid       TEXT
) WITHOUT ROWID;

CREATE TABLE metadata (
    key   TEXT NOT NULL PRIMARY KEY,
    value TEXT NOT NULL
);
"""


def write_database(out_path: Path, rows, meta: dict[str, str]) -> int:
    """Write the callsign table to a fresh SQLite file; returns the row count.

    The table is WITHOUT ROWID so the callsign index *is* the table -- one
    B-tree instead of two, which is both smaller on disk and one less lookup
    per query.
    """
    tmp_path = out_path.with_suffix(out_path.suffix + ".building")
    tmp_path.unlink(missing_ok=True)
    connection = sqlite3.connect(tmp_path)
    try:
        connection.execute("PRAGMA page_size = 4096")
        connection.execute("PRAGMA journal_mode = OFF")
        connection.executescript(SCHEMA)
        # Last write wins on a duplicate callsign: ULS can briefly carry two
        # active records for one call across a vanity grant.
        connection.executemany(
            "INSERT OR REPLACE INTO callsigns (callsign, first_name, grid) "
            "VALUES (?, ?, ?)", rows)
        count = connection.execute("SELECT count(*) FROM callsigns").fetchone()[0]
        connection.executemany(
            "INSERT INTO metadata (key, value) VALUES (?, ?)",
            sorted({**meta, "row_count": str(count)}.items()))
        connection.commit()
        connection.execute("VACUUM")
        connection.close()
    except BaseException:
        connection.close()
        tmp_path.unlink(missing_ok=True)
        raise
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path.replace(out_path)
    return count


# --------------------------------------------------------------------------

def log(message: str) -> None:
    print(f"[callsign-db] {message}", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT,
                        help=f"output SQLite path (default: {DEFAULT_OUT})")
    parser.add_argument("--cache", type=Path, default=None,
                        help="directory for downloaded archives (default: a temp dir)")
    parser.add_argument("--source", type=Path, default=None,
                        help="directory of already-unpacked ULS .dat files; "
                             "skips the l_amat.zip download")
    parser.add_argument("--uls-url", default=ULS_URL)
    parser.add_argument("--gazetteer-url", default=GAZETTEER_URL)
    parser.add_argument("--include-expired", action="store_true",
                        help="keep licenses that are still 'A' but past their "
                             "expiration date (inside the FCC grace period)")
    args = parser.parse_args(argv)

    with tempfile.TemporaryDirectory(prefix="callsign-db-") as scratch:
        cache = args.cache or Path(scratch)
        cache.mkdir(parents=True, exist_ok=True)
        work = Path(scratch)

        if args.source:
            uls_dir, uls_stamp = args.source, ""
        else:
            uls_zip = cache / "l_amat.zip"
            uls_stamp = download(args.uls_url, uls_zip)
            log("unpacking ULS data")
            uls_dir = unpack(uls_zip, work / "uls", members=["HD.dat", "EN.dat"])

        gazetteer_zip = cache / "gazetteer_zcta.zip"
        download(args.gazetteer_url, gazetteer_zip)
        gazetteer_dir = unpack(gazetteer_zip, work / "gazetteer")
        gazetteer_txt = next(gazetteer_dir.glob("*.txt"))

        log("loading ZIP centroids")
        centroids = load_zip_centroids(gazetteer_txt)
        log(f"{len(centroids):,} ZIP centroids")

        log("scanning active licenses")
        active = active_license_ids(uls_dir / "HD.dat", args.include_expired)
        log(f"{len(active):,} active amateur licenses")
        if not active:
            log("error: no active licenses found -- is the ULS data intact?")
            return 1

        log("building database")
        meta = {
            "schema_version": SCHEMA_VERSION,
            "generated_at": dt.datetime.now(dt.timezone.utc)
                              .strftime("%Y-%m-%dT%H:%M:%SZ"),
            "source": "FCC ULS l_amat + Census ZCTA gazetteer",
            "uls_release": uls_stamp or "unknown",
        }
        count = write_database(
            args.out, entries(uls_dir / "EN.dat", active, centroids), meta)

    size_mb = args.out.stat().st_size / 1e6
    log(f"wrote {args.out} -- {count:,} callsigns, {size_mb:.1f} MB")
    if count < len(active) // 2:
        log("warning: fewer than half the active licenses produced a row")
    return 0


if __name__ == "__main__":
    sys.exit(main())
