import Foundation
import SQLite3

/// One row of the bundled FCC callsign database.
struct CallsignRecord: Sendable, Equatable {
    let callsign: String
    let firstName: String?
    let grid: String?
}

/// Offline US callsign lookup backed by `callsigns.sqlite` in Resources —
/// every active FCC amateur license, mapped to the licensee's first name and
/// 4-character Maidenhead square (derived from the ZIP code on file). Built by
/// `tools/build-callsign-db.py`; see `tools/README-callsign-db.md`.
///
/// This is the first stop for a callsign lookup: it answers in microseconds
/// with no network, so the entry screen can fill in a US contact before any
/// callbook request is made. QRZ/HamQTH then enrich that answer with the
/// fields the FCC doesn't publish, and carry the lookup alone for the calls
/// this database doesn't have — non-US stations, and licenses granted since
/// the bundled snapshot.
///
/// The file is opened read-only and lazily on first query, and SQLite reads
/// just the handful of B-tree pages a lookup touches rather than the whole
/// 16 MB.
actor CallsignDatabase {
    static let shared = CallsignDatabase()

    private let url: URL?
    private var open: OpenDatabase?
    private var didAttemptOpen = false

    /// - Parameter url: the SQLite file to read; defaults to the bundled
    ///   database. Tests pass a temporary file.
    init(url: URL? = CallsignDatabase.bundledURL) {
        self.url = url
    }

    /// Location of the bundled database, or nil if it was left out of the
    /// build. Static, so it is reachable without hopping onto the actor.
    static var bundledURL: URL? {
        Bundle.main.url(forResource: "callsigns", withExtension: "sqlite")
    }

    /// Whether a bundled database is present, so callers can tell that offline
    /// lookups are possible without doing any (async) work.
    static let isBundled = bundledURL != nil

    /// The record for a callsign, or nil if it isn't a licensed US call.
    ///
    /// Portable and reciprocal suffixes are tried both ways: "W1AW/4" and
    /// "KH6/W1AW" both resolve to W1AW's record, since the FCC only ever
    /// licenses the bare call.
    func lookup(callsign: String) -> CallsignRecord? {
        guard let database = openIfNeeded() else { return nil }
        let normalized = CallsignFormat.normalized(callsign)
        guard !normalized.isEmpty else { return nil }
        if let record = database.row(for: normalized) { return record }
        let base = CallsignFormat.base(normalized)
        return base == normalized ? nil : database.row(for: base)
    }

    /// The same lookup shaped as a callbook result, so it drops into the
    /// existing lookup path. Only the fields the FCC actually publishes are
    /// filled — coordinates are left to the caller to derive from the grid.
    func lookupResult(callsign: String) -> CallsignLookupResult? {
        guard let record = lookup(callsign: callsign) else { return nil }
        return CallsignLookupResult(callsign: record.callsign,
                                    firstName: record.firstName,
                                    grid: record.grid)
    }

    private func openIfNeeded() -> OpenDatabase? {
        if didAttemptOpen { return open }
        didAttemptOpen = true
        guard let url else { return nil }
        open = OpenDatabase(url: url)
        return open
    }
}

// MARK: - SQLite handle

/// Owns the `sqlite3` handle and its one prepared statement. Kept as a class
/// so the handles are closed in an ordinary `deinit`, and confined to
/// `CallsignDatabase`'s actor isolation so the non-mutex connection is only
/// ever used from one task at a time.
private final class OpenDatabase {
    private let handle: OpaquePointer
    private let query: OpaquePointer

    init?(url: URL) {
        var handle: OpaquePointer?
        // NOMUTEX: the owning actor already serializes every use.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        var query: OpaquePointer?
        let sql = "SELECT callsign, first_name, grid FROM callsigns WHERE callsign = ?"
        guard sqlite3_prepare_v2(handle, sql, -1, &query, nil) == SQLITE_OK,
              let query else {
            sqlite3_close(handle)
            return nil
        }
        self.handle = handle
        self.query = query
    }

    deinit {
        sqlite3_finalize(query)
        sqlite3_close(handle)
    }

    /// Runs the prepared lookup for an already-normalized callsign.
    func row(for callsign: String) -> CallsignRecord? {
        defer { sqlite3_reset(query); sqlite3_clear_bindings(query) }
        // SQLITE_TRANSIENT: SQLite copies the bytes, so the Swift string need
        // not outlive the call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(query, 1, callsign, -1, transient) == SQLITE_OK,
              sqlite3_step(query) == SQLITE_ROW,
              let stored = text(column: 0) else {
            return nil
        }
        return CallsignRecord(callsign: stored,
                              firstName: text(column: 1),
                              grid: text(column: 2))
    }

    /// A column's text, or nil when it is SQL NULL or empty — club stations
    /// have no first name, and a few licensees' ZIP codes yield no grid.
    private func text(column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(query, column) else { return nil }
        let value = String(cString: bytes)
        return value.isEmpty ? nil : value
    }
}
