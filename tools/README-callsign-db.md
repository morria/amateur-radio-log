# Offline callsign database

`AmateurRadioLog/AmateurRadioLog/Resources/callsigns.sqlite` maps every active
US amateur callsign to the licensee's first name and 4-character Maidenhead
grid square. The app consults it before any callbook, so entering a US
callsign fills in the operator and pins the map with no network and no wait;
QRZ/HamQTH are only consulted for the calls it misses.

It is a build artifact, produced by `tools/build-callsign-db.py` and committed
so a clean checkout builds a complete app.

## Building it

```sh
python3 tools/build-callsign-db.py           # ~200 MB download, a few minutes
python3 tools/test_build_callsign_db.py      # 23 tests, no network
```

Stdlib-only Python 3.8+; no packages to install. Useful flags:

| Flag | Purpose |
| --- | --- |
| `--out PATH` | write somewhere other than `Resources/callsigns.sqlite` |
| `--cache DIR` | keep the downloads between runs (the 200 MB ULS archive) |
| `--source DIR` | build from already-unpacked `.dat` files, no download |
| `--include-expired` | keep licenses inside the FCC's two-year grace period |

## Sources

Both are public-domain US government data.

| Source | Used for |
| --- | --- |
| [FCC ULS `l_amat.zip`](https://data.fcc.gov/download/pub/uls/complete/l_amat.zip) | callsign, license status, licensee first name, ZIP code |
| [Census ZCTA gazetteer](https://www2.census.gov/geo/docs/maps-data/data/gazetteer/2024_Gazetteer/2024_Gaz_zcta_national.zip) | ZIP code → latitude/longitude centroid |

The FCC publishes a mailing address but no coordinates, so the grid square is
derived from the ZIP centroid. That is accurate enough: a 4-character square
is 1° of latitude by 2° of longitude — roughly 111 × 150 km in the lower 48 —
which is one to two orders of magnitude coarser than the error from collapsing
a ZIP code to a point. The derived square matches the licensee's own only
where their address sits within a few km of a square boundary.

A licensee's mailing address is also not necessarily where they transmit from.
The grid is a starting point that the operator can correct, not a fact about
the contact — which is why a lookup only ever fills in blank fields and never
overwrites what is already recorded on a QSO.

### Selection rules

* `HD.dat` license status `A`, radio service `HA` (amateur) or `HV` (vanity).
* Expired licenses are dropped even while the FCC still marks them active
  during the grace period. `--include-expired` keeps them.
* `EN.dat` entity type `L` (the licensee), not `CL` (a contact agent).
* A row is kept when it has a first name **or** a grid. Club and
  military-recreation stations have no first name; about 2% of licensees have a
  ZIP the gazetteer does not cover (PO boxes, recently created ZIPs).
* ZIP codes outside the gazetteer fall back to a per-territory centroid for
  Guam, the Northern Marianas, American Samoa, Palau, Micronesia and the
  Marshall Islands, each of which fits inside a single grid square. No such
  fallback exists for the states — a state centroid would span several squares,
  so those rows simply carry no grid.

## Schema

```sql
CREATE TABLE callsigns (
    callsign   TEXT NOT NULL PRIMARY KEY,   -- upper case, no /P or /4 suffix
    first_name TEXT,                        -- NULL for clubs
    grid       TEXT                         -- 4-character Maidenhead, or NULL
) WITHOUT ROWID;

CREATE TABLE metadata (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
```

`WITHOUT ROWID` makes the callsign index *be* the table: one B-tree instead of
two, smaller on disk and one less lookup per query. `metadata` records the
schema version, the ULS release the file was built from, the build time and
the row count.

The app opens the file read-only and never writes to it, so there is no
journal or WAL sidecar to ship.

As of the July 2026 ULS release: 741,203 callsigns, 16.6 MB.

## Refreshing

The FCC regenerates `l_amat.zip` weekly. Re-run the script and commit the
result whenever the snapshot is stale enough to matter — new licensees are the
main thing that goes missing, and they fall through to QRZ in the meantime, so
per app release is plenty. Each refresh adds ~16 MB to the repository's
history; if that becomes a problem, the alternatives are Git LFS or dropping
the file from the repo and building it in CI.

`Bundle.main` is the only place the app looks for it. A build without the file
still works — `CallsignDatabase` reports `isBundled == false` and every lookup
goes to the callbook, exactly as it did before this database existed.
