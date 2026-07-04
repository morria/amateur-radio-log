#if os(macOS)
import AppKit

/// Locates and launches TQSL (TrustedQSL) to sign and upload an ADI file to
/// LoTW. LoTW only accepts digitally signed logs, so the app hands the
/// un-uploaded slice to TQSL instead of uploading directly.
///
/// TQSL is launched through LaunchServices (`NSWorkspace.openApplication`),
/// NOT `Process`: a child process spawned from a sandboxed app inherits the
/// sandbox and the container HOME, so it cannot see the user's `~/.tqsl`
/// certificate store. LaunchServices starts TQSL unsandboxed in the user's
/// real session, where its certificates and station locations work normally.
enum TQSLLauncher {

    /// TQSL's bundle identifier (verified against the shipping tqsl.app),
    /// plus a legacy spelling, tried in order.
    static let bundleIdentifiers = ["org.arrl.tqsl", "org.arrl.trustedqsl"]

    /// Install locations tried when LaunchServices doesn't know the bundle
    /// ID (e.g. TQSL was copied but never launched/registered).
    static let fallbackPaths = [
        "/Applications/TrustedQSL/tqsl.app",
        "/Applications/tqsl.app",
    ]

    /// Command-line arguments for a sign-and-upload run:
    /// -d  suppress the date-range dialog
    /// -u  upload the signed log to LoTW after signing
    /// -x  exit when the upload finishes
    /// -a compliant  sign new/changed QSOs, silently skipping already-uploaded
    ///    duplicates
    /// -q and -l are deliberately omitted so TQSL's GUI prompts for the
    /// station location and surfaces signing/upload errors itself — the exit
    /// status of a LaunchServices-launched app is unobservable, so the GUI is
    /// the only reliable error channel.
    nonisolated static func arguments(forADIFileAt path: String) -> [String] {
        ["-d", "-u", "-x", "-a", "compliant", path]
    }

    /// Finds tqsl.app via LaunchServices, falling back to well-known install
    /// paths. Returns nil when TQSL is not installed.
    @MainActor
    static func locate() -> URL? {
        for identifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        for path in fallbackPaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Launches TQSL with the sign-and-upload arguments for `adiFile`.
    /// The launch itself is all we can observe — TQSL's GUI takes it from
    /// there, so callers must never mark QSOs as uploaded on success here.
    @MainActor
    static func launchUpload(appURL: URL, adiFile: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments(forADIFileAt: adiFile.path)
        // Arguments are only delivered to a freshly launched instance; if
        // TQSL is already running they would otherwise be dropped silently.
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    // MARK: - Upload file management

    static let uploadFilePrefix = "lotw-upload-"
    static let maxUploadFiles = 3

    /// `Application Support/LoTW` inside the app container. Unsandboxed TQSL
    /// can read container paths, so the handoff file lives here rather than
    /// in a location that would need a save panel.
    nonisolated static func uploadDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("LoTW", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `lotw-upload-<ISO8601 basic>.adi` — lexicographic order matches
    /// chronological order, and a fresh name per run means a TQSL instance
    /// still holding an older file never races a rewrite.
    nonisolated static func uploadFileName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return uploadFilePrefix + formatter.string(from: date) + ".adi"
    }

    /// Writes `records` as an ADI file for TQSL and prunes older handoff
    /// files, keeping the newest `maxUploadFiles`.
    nonisolated static func writeUploadFile(records: [QSORecord],
                                            directory: URL? = nil) throws -> URL {
        let dir = try directory ?? uploadDirectory()
        let url = dir.appendingPathComponent(uploadFileName())
        let content = ADIFWriter().write(records: records)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try prune(directory: dir)
        return url
    }

    /// Deletes all but the newest `keeping` handoff files in `directory`.
    nonisolated static func prune(directory: URL, keeping: Int = maxUploadFiles) throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(uploadFilePrefix) && $0.pathExtension == "adi" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count > keeping else { return }
        for url in files.dropLast(keeping) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
#endif
