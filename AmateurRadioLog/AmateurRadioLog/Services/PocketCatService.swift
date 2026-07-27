import CATBridgeKit
import Foundation
import Observation

// MARK: - Preferences

/// Per-device Pocket Cat preferences.
///
/// UserDefaults-backed for the same reason as the rest of `RigPreferences`:
/// which Bluetooth bridge a device pairs with is machine-local. An iPad and
/// the shack Mac each pair with their own bridge (or the same one at
/// different times) and must not clobber each other through CloudKit.
enum PocketCatPreferences {
    static let bridgeIdKey = "pocketCatBridgeId"
    static let bridgeNameKey = "pocketCatBridgeName"
    static let autoInformationKey = "pocketCatAutoInformation"

    /// The bridge to reconnect to on launch; nil until one is picked.
    static var bridgeId: UUID? {
        get {
            UserDefaults.standard.string(forKey: bridgeIdKey).flatMap(UUID.init(uuidString:))
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: bridgeIdKey)
        }
    }

    /// Remembered advertised name, so Settings can name the paired bridge
    /// without scanning first.
    static var bridgeName: String {
        get { UserDefaults.standard.string(forKey: bridgeNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: bridgeNameKey) }
    }

    /// Yaesu Auto-Information: the radio pushes state changes unsolicited,
    /// so frequency/mode track the dial instantly instead of at the poll
    /// cadence. Off by default — the library documents interleaving quirks
    /// and not every radio supports it.
    static var autoInformation: Bool {
        UserDefaults.standard.bool(forKey: autoInformationKey)
    }

    static var policy: PollingPolicy {
        var policy = PollingPolicy.default
        policy.enableAutoInformation = autoInformation
        return policy
    }
}

// MARK: - Mode Bridging

/// Translates between the app's ADIF `Mode`, the spot feeds' free-text mode
/// strings, and CATBridgeKit's `OperatingMode`.
///
/// The hard part is sideband: ADIF `SSB` and a spot's "SSB" don't say USB or
/// LSB, but the radio needs one. Amateur convention decides it — LSB below
/// 10 MHz, USB above — which is what `sideband(forMHz:)` encodes. Same rule
/// governs the data carriers (`dataUSB`/`dataLSB`) that FT8 and friends ride
/// on, except that 60 m and up are USB by convention regardless.
enum PocketCatModeMapper {

    /// Radio mode → ADIF mode for logging. Data carriers deliberately return
    /// nil: the radio only knows it is passing audio to a modem, not whether
    /// that modem runs FT8, JS8 or PSK31, so the logged mode stays on the
    /// last-used value (same choice as `RigModeMapper`).
    static func loggingMode(from mode: OperatingMode) -> Mode? {
        switch mode {
        case .lsb, .usb: return .ssb
        case .cw, .cwReverse: return .cw
        case .fm, .fmNarrow: return .fm
        case .am, .amNarrow: return .am
        case .rtty, .rttyReverse: return .rtty
        case .c4fm: return .c4fm
        case .dataLSB, .dataUSB, .dataFM, .dataFMNarrow: return nil
        }
    }

    /// ADIF mode → the radio mode to select when tuning, given the dial
    /// frequency (which decides sideband).
    static func operatingMode(for mode: Mode, atMHz mhz: Double) -> OperatingMode? {
        switch mode {
        case .ssb:
            return sideband(forMHz: mhz) == .lower ? .lsb : .usb
        case .cw:
            return .cw
        case .fm:
            return .fm
        case .am:
            return .am
        case .rtty:
            return .rtty
        case .c4fm:
            return .c4fm
        // Everything else is a soundcard mode: put the radio on the data
        // carrier and let the modem do the rest.
        case .ft8, .ft4, .psk31, .psk63, .jt65, .jt9, .js8, .olivia,
             .contestia, .mfsk, .pkt, .sstv, .hell, .ros:
            return sideband(forMHz: mhz) == .lower ? .dataLSB : .dataUSB
        // No unambiguous analog equivalent — leave the radio's mode alone.
        case .digitalVoice, .dstar, .dmr:
            return nil
        }
    }

    /// A spot's free-text mode ("CW", "SSB", "FT8", "USB"…) → radio mode.
    /// Unrecognized text returns nil so tuning still sets the frequency and
    /// leaves the mode untouched.
    static func operatingMode(forSpotMode raw: String, atMHz mhz: Double) -> OperatingMode? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // Explicit sidebands from the feed win over the frequency convention.
        switch normalized {
        case "USB": return .usb
        case "LSB": return .lsb
        case "CW", "CWR": return .cw
        case "AM": return .am
        case "FM": return .fm
        case "RTTY": return .rtty
        case "DATA", "DIGI", "DIGITAL":
            return sideband(forMHz: mhz) == .lower ? .dataLSB : .dataUSB
        default:
            break
        }
        // Otherwise reuse the ADIF table (covers FT8/FT4/PSK/JS8/…).
        guard let mode = Mode(rawValue: normalized) else { return nil }
        return operatingMode(for: mode, atMHz: mhz)
    }

    enum Sideband { case lower, upper }

    /// Amateur sideband convention: LSB on 160/80/40 m, USB from 60 m up.
    static func sideband(forMHz mhz: Double) -> Sideband {
        mhz < 10.0 ? .lower : .upper
    }
}

// MARK: - S-Meter Scaling

/// Converts a radio's raw S-meter reading into S-units 1–9.
///
/// The library reports `snapshot.sMeter` as the radio's own scale with no
/// units attached, and the scales differ: Yaesu answers `SM0nnn;` over
/// 000–255 with S9 at 127, while the TS-480 subset the QMX speaks answers
/// `SM0nnnn;` over 0–30 with S9 at 15. So the conversion has to key off the
/// identified radio, and an unidentified one gets no guess at all — a wrong
/// S-unit stamped on a logged contact is worse than falling back to the
/// conventional default.
///
/// Readings above S9 clamp to 9: RST has no way to express "S9 + 20 dB".
enum SMeterScale {

    /// Raw reading that corresponds to S9 on each radio's meter.
    static func s9Raw(for radio: RadioModel) -> Int? {
        switch radio {
        case .ft891, .ftx1: return 127   // 0–255 scale
        case .qmx: return 15             // TS-480 0–30 scale
        case .generic: return nil        // unknown scale — do not guess
        }
    }

    static func sUnit(raw: Int, radio: RadioModel?) -> Int? {
        guard let radio, let s9 = s9Raw(for: radio), s9 > 0, raw >= 0 else {
            return nil
        }
        let scaled = (Double(raw) / Double(s9) * 9).rounded()
        return min(9, max(1, Int(scaled)))
    }

    /// Builds an RST report from an S-unit, following the same conventions as
    /// `QuickEntryParser.defaultRST`.
    ///
    /// Readability is left at 5 because a meter cannot measure it — only the
    /// S digit is actually observed. Tone is likewise a fixed 9; a genuinely
    /// rough note is rare enough that it belongs to the operator, not to a
    /// derived default.
    static func rst(sUnit: Int, mode: Mode?) -> String? {
        switch mode {
        case .ssb, .fm, .am: return "5\(sUnit)"
        case .cw, .rtty, .psk31: return "5\(sUnit)9"
        default: return nil
        }
    }
}

// MARK: - Service

/// Live view of a Pocket Cat BLE bridge and the transceiver behind it.
///
/// MainActor-isolated on purpose: `TransceiverState` is itself a
/// `@MainActor @Observable`, the settings UI binds straight to this object,
/// and every mutation here originates from either a UI action or a snapshot
/// hop back to the main actor. The radio I/O it drives is all `async` on the
/// library's `TransceiverSession` actor, so nothing blocks the main thread.
@MainActor
@Observable
final class PocketCatService {

    /// Snapshot of everything the app needs from the bridge, in the app's own
    /// vocabulary. CATBridgeKit types deliberately stop here — views and
    /// `AppState` see `Mode` and `String`, never `OperatingMode` or
    /// `RadioModel`, the same way `RigService` hides `NWConnection`.
    struct Reading: Equatable {
        var frequencyMHz: Double?
        /// Rig-panel mode name for display ("DATA-U", "USB").
        var modeName: String?
        /// ADIF mode for logging; nil for data carriers (see
        /// `PocketCatModeMapper.loggingMode`).
        var loggingMode: Mode?
        var powerWatts: Double?
        var radioName: String?
        var firmwareVersion: String = ""
        var isTransmitting = false
    }

    /// A bridge seen while scanning, without exposing the library's
    /// `DiscoveredBridge` (or CoreBluetooth) to the settings UI.
    struct BridgeInfo: Identifiable, Equatable {
        let id: UUID
        let name: String?
        let rssi: Int
    }

    private(set) var reading = Reading()
    /// Localized description of the connection phase, for Settings.
    private(set) var phaseDescription = String(localized: "Not connected")
    /// Bridges seen by the current scan, strongest signal first.
    private(set) var discovered: [BridgeInfo] = []
    private(set) var isScanning = false
    /// Human-readable failure from the last connect attempt, for Settings.
    private(set) var lastError: String?
    private(set) var isConnected = false

    @ObservationIgnored private var phase: ConnectionPhase = .idle {
        didSet {
            phaseDescription = Self.describe(phase)
            if case .ready = phase {
                isConnected = true
            } else {
                isConnected = false
            }
        }
    }

    /// `CATBridgeCentral` builds a `CBCentralManager` in its initializer,
    /// which is what triggers the system Bluetooth permission prompt — so it
    /// is created on first use (enabling Pocket Cat, or opening its settings)
    /// rather than at launch. Apps that never touch Pocket Cat never prompt.
    @ObservationIgnored private var central: CATBridgeCentral?
    @ObservationIgnored private var session: TransceiverSession?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var powerTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?

    /// Identified radio, kept out of `Reading` because the S-meter scale
    /// needs the typed model, not the display name.
    @ObservationIgnored private var radioModel: RadioModel?

    /// Highest S-meter reading seen recently, and when.
    ///
    /// Deliberately not part of `Reading`: the meter moves at the 2 Hz poll
    /// rate, and folding it into an observable value would re-render every
    /// view bound to this service twice a second for a number none of them
    /// display.
    @ObservationIgnored private var sMeterPeak: (value: Int, at: Date)?

    /// How far back a peak still counts. An RST is only meaningful while the
    /// station being worked is actually transmitting, and the meter otherwise
    /// reads the noise floor — so a suggestion is drawn from the loudest
    /// sample in the last few seconds rather than whatever the needle happens
    /// to be sitting on when the form opens, and expires rather than going
    /// stale.
    private static let sMeterPeakWindow: TimeInterval = 10

    /// The library fills `snapshot.power` once per connect and then keeps it
    /// fresh only through its own `setPower` and Yaesu AI pushes — it does
    /// not poll, on the reasoning that power changes rarely and mostly
    /// through the app.
    ///
    /// That is one assumption too many for a logging app: an operator who
    /// turns the power knob mid-session would otherwise keep logging the
    /// value read at connect. So we re-read on a slow cadence — slow enough
    /// (versus the library's 500 ms `IF;` poll) that it costs essentially
    /// nothing, but fast enough that the New QSO screen is honest.
    private static let powerRefreshInterval: Duration = .seconds(30)

    private func makeCentral() -> CATBridgeCentral {
        if let central { return central }
        // No restoration identifier: this app has no `bluetooth-central`
        // background mode, and CoreBluetooth logs a warning when a
        // restoration ID is supplied without one.
        let created = CATBridgeCentral()
        central = created
        return created
    }

    // MARK: Scanning

    func startScan() {
        guard scanTask == nil else { return }
        isScanning = true
        discovered = []
        let central = makeCentral()
        scanTask = Task { [weak self] in
            for await bridge in central.bridges() {
                guard let self else { return }
                self.noteDiscovered(bridge)
            }
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private func noteDiscovered(_ bridge: DiscoveredBridge) {
        let info = BridgeInfo(id: bridge.id, name: bridge.name, rssi: bridge.rssi)
        if let index = discovered.firstIndex(where: { $0.id == info.id }) {
            discovered[index] = info
        } else {
            discovered.append(info)
        }
        discovered.sort { $0.rssi > $1.rssi }
    }

    // MARK: Connection

    /// Connect to the remembered bridge. No-op when none has been picked.
    func connectToSavedBridge() {
        guard let id = PocketCatPreferences.bridgeId else { return }
        connect(bridgeId: id)
    }

    func connect(bridgeId: UUID) {
        guard connectTask == nil, session == nil else { return }
        lastError = nil
        phase = .connecting
        let central = makeCentral()
        let policy = PocketCatPreferences.policy
        connectTask = Task { [weak self] in
            defer { self?.connectTask = nil }
            do {
                let session = try await central.connect(id: bridgeId, policy: policy)
                guard let self, !Task.isCancelled else {
                    await session.disconnect()
                    return
                }
                self.adopt(session)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.lastError = Self.describe(error)
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    private func adopt(_ session: TransceiverSession) {
        self.session = session
        // Scanning and an open connection compete for the radio; once
        // connected there is nothing left to discover.
        stopScan()
        snapshotTask = Task { [weak self] in
            for await snapshot in await session.snapshots() {
                guard let self, !Task.isCancelled else { return }
                self.apply(snapshot)
            }
        }
        startPowerPolling()
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        powerTask?.cancel()
        powerTask = nil
        let session = self.session
        self.session = nil
        phase = .idle
        reading = Reading()
        radioModel = nil
        sMeterPeak = nil
        if let session {
            Task { await session.disconnect() }
        }
    }

    private func apply(_ snapshot: TransceiverSnapshot) {
        phase = snapshot.connection
        radioModel = snapshot.radio
        noteSMeter(snapshot.sMeter)
        var next = reading
        next.frequencyMHz = snapshot.frequency?.megahertzValue
        next.modeName = snapshot.mode?.rigDisplayName
        next.loggingMode = snapshot.mode.flatMap(PocketCatModeMapper.loggingMode(from:))
        next.radioName = snapshot.radio?.displayName
        next.firmwareVersion = snapshot.bridge.firmwareVersion
        next.isTransmitting = snapshot.isTransmitting
        // The snapshot is the single source of truth for power: the library
        // fills it at connect and republishes on every `readPower`, so the
        // refresh task only has to ask — it never writes here itself.
        next.powerWatts = snapshot.power.map(Double.init)
        guard next != reading else { return }
        reading = next
    }

    // MARK: S-Meter

    /// Records a new peak, or restarts the window when the old peak has aged
    /// out. The library stops polling the meter while transmitting, so no
    /// filtering for our own transmissions is needed here.
    private func noteSMeter(_ raw: Int?) {
        guard let raw else { return }
        let now = Date()
        if let peak = sMeterPeak,
           now.timeIntervalSince(peak.at) < Self.sMeterPeakWindow,
           peak.value >= raw {
            return
        }
        sMeterPeak = (raw, now)
    }

    /// Suggested RST received for `mode`, from the recent S-meter peak.
    /// nil when disconnected, when nothing was heard recently, when the radio
    /// model is unknown, or for modes that don't use RST-style reports.
    func suggestedRSTReceived(for mode: Mode?) -> String? {
        guard isConnected, let peak = sMeterPeak,
              Date().timeIntervalSince(peak.at) < Self.sMeterPeakWindow,
              let sUnit = SMeterScale.sUnit(raw: peak.value, radio: radioModel)
        else { return nil }
        return SMeterScale.rst(sUnit: sUnit, mode: mode)
    }

    // MARK: Power

    private func startPowerPolling() {
        powerTask?.cancel()
        powerTask = Task { [weak self] in
            // The connect-time read already populated the snapshot; wait a
            // full interval before spending a round trip re-reading it.
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.powerRefreshInterval)
                guard !Task.isCancelled else { return }
                await self?.refreshPower()
            }
        }
    }

    /// Asks the library to re-read RF power; the resulting snapshot carries
    /// the value into `reading`. `readPower()` throws `.unsupportedCapability`
    /// on radios without power control (the QMX's supported subset) — that is
    /// a signal to stop asking, not an error worth surfacing.
    private func refreshPower() async {
        guard let session, isConnected else { return }
        do {
            _ = try await session.readPower()
        } catch CATBridgeError.unsupportedCapability {
            powerTask?.cancel()
            powerTask = nil
        } catch {
            // Transient (timeout, mid-reconnect): leave the last known value
            // and try again next interval.
        }
    }

    // MARK: Tuning

    /// Tune the radio to a spot's frequency and its free-text mode.
    func tune(toMHz mhz: Double, spotMode: String?) {
        let mode = spotMode.flatMap {
            PocketCatModeMapper.operatingMode(forSpotMode: $0, atMHz: mhz)
        }
        tune(toMHz: mhz, operatingMode: mode)
    }

    /// Tune the radio to a frequency and (when it maps to something the rig
    /// understands) a mode. Frequency is set first so the sideband the mode
    /// mapper picked matches where the dial actually ends up.
    ///
    /// Errors are surfaced through `lastError` rather than thrown: callers
    /// are UI taps, and a failed tune must not block logging the contact.
    private func tune(toMHz mhz: Double, operatingMode mode: OperatingMode?) {
        guard let session, isConnected, mhz > 0 else { return }
        Task { [weak self] in
            do {
                try await session.setFrequency(.megahertz(mhz))
                if let mode {
                    try await session.setMode(mode)
                }
                self?.lastError = nil
            } catch {
                self?.lastError = Self.describe(error)
            }
        }
    }

    // MARK: Errors

    /// `CATBridgeError` is `Error`, not `LocalizedError`, so
    /// `localizedDescription` yields the useless default text. Map the cases
    /// the user can act on.
    static func describe(_ error: Error) -> String {
        guard let error = error as? CATBridgeError else {
            return error.localizedDescription
        }
        switch error {
        case .bluetoothUnavailable(let reason):
            return String(localized: "Bluetooth unavailable (\(reason))")
        case .bridgeNotFound:
            return String(localized: "Bridge not found — is it powered on and in range?")
        case .connectionFailed(let reason):
            return String(localized: "Connection failed: \(reason)")
        case .connectionLost:
            return String(localized: "Connection lost")
        case .pairingRequired:
            return String(localized: "Pairing required — accept the Bluetooth pairing request")
        case .bondInvalidated:
            return String(localized: "Pairing was invalidated — forget the device in Bluetooth settings and retry")
        case .usbRadioDisconnected:
            return String(localized: "No radio attached to the bridge")
        case .radioNotResponding:
            return String(localized: "Radio not responding — check the CAT cable and the radio's CAT baud rate")
        case .radioRejected(let command):
            return String(localized: "The radio rejected \(command)")
        case .timedOut(let command):
            return String(localized: "Timed out waiting for \(command)")
        case .unsupportedMode(let mode):
            return String(localized: "This radio does not support \(String(describing: mode))")
        case .unsupportedCapability:
            return String(localized: "This radio does not support that operation")
        case .notReady:
            return String(localized: "Not connected")
        default:
            return String(describing: error)
        }
    }

    /// Short label for the connection state, shown in Settings.
    static func describe(_ phase: ConnectionPhase) -> String {
        switch phase {
        case .idle: return String(localized: "Not connected")
        case .connecting: return String(localized: "Connecting…")
        case .bridgeReady: return String(localized: "Bridge connected — no radio detected")
        case .identifyingRadio: return String(localized: "Identifying radio…")
        case .ready: return String(localized: "Connected")
        case .reconnecting(let attempt): return String(localized: "Reconnecting (attempt \(attempt))…")
        case .failed(let reason): return String(localized: "Failed: \(reason)")
        }
    }
}

// MARK: - Display Helpers

extension RadioModel {
    var displayName: String {
        switch self {
        case .ft891: return "Yaesu FT-891"
        case .ftx1: return "Yaesu FTX-1"
        case .qmx: return "QRP Labs QMX"
        case .generic(let id): return id
        }
    }
}

extension OperatingMode {
    /// Conventional rig-panel name, so the toolbar chip reads the way the
    /// radio's own display does ("DATA-U", not "dataUSB").
    var rigDisplayName: String {
        switch self {
        case .lsb: return "LSB"
        case .usb: return "USB"
        case .cw: return "CW"
        case .cwReverse: return "CWR"
        case .fm: return "FM"
        case .fmNarrow: return "FMN"
        case .am: return "AM"
        case .amNarrow: return "AMN"
        case .rtty: return "RTTY"
        case .rttyReverse: return "RTTYR"
        case .dataLSB: return "DATA-L"
        case .dataUSB: return "DATA-U"
        case .dataFM: return "PKTFM"
        case .dataFMNarrow: return "PKTFMN"
        case .c4fm: return "C4FM"
        }
    }
}
