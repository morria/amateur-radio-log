import XCTest
@testable import AmateurRadioLog

final class WSJTXMessageTests: XCTestCase {

    // MARK: - Datagram builder (QDataStream wire format)

    /// Builds synthetic WSJT-X datagrams: big-endian fixed-width integers,
    /// u32-length-prefixed UTF-8 strings, 0xFFFFFFFF = null string.
    private struct DatagramBuilder {
        var data = Data()

        mutating func appendUInt8(_ value: UInt8) {
            data.append(value)
        }

        mutating func appendBool(_ value: Bool) {
            data.append(value ? 1 : 0)
        }

        mutating func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }

        mutating func appendUInt64(_ value: UInt64) {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }

        mutating func appendString(_ value: String?) {
            guard let value else {
                appendUInt32(0xFFFF_FFFF)
                return
            }
            let bytes = Array(value.utf8)
            appendUInt32(UInt32(bytes.count))
            data.append(contentsOf: bytes)
        }

        mutating func appendHeader(type: UInt32, magic: UInt32 = 0xadbc_cbda, schema: UInt32 = 2) {
            appendUInt32(magic)
            appendUInt32(schema)
            appendUInt32(type)
        }
    }

    /// Full Status (type 1) frame through the fields the decoder reads.
    private func statusDatagram(dialHz: UInt64 = 14_074_000, mode: String = "FT8") -> Data {
        var builder = DatagramBuilder()
        builder.appendHeader(type: 1)
        builder.appendString("WSJT-X")       // id
        builder.appendUInt64(dialHz)         // dial frequency (Hz)
        builder.appendString(mode)           // mode
        builder.appendString("K1ABC")        // DX call
        builder.appendString("-10")          // report
        builder.appendString(mode)           // Tx mode
        builder.appendBool(false)            // Tx enabled
        builder.appendBool(false)            // transmitting
        builder.appendBool(true)             // decoding
        builder.appendUInt32(1500)           // Rx DF
        builder.appendUInt32(1200)           // Tx DF
        builder.appendString("W2ASM")        // DE call
        builder.appendString("FN31")         // DE grid
        builder.appendString("FN42")         // DX grid
        builder.appendBool(false)            // Tx watchdog (ignored)
        builder.appendString(nil)            // sub-mode (ignored)
        builder.appendBool(false)            // fast mode (ignored)
        return builder.data
    }

    private let sampleADIF = """
    <adif_ver:5>3.1.0
    <programid:6>WSJT-X
    <EOH>
    <call:5>K1ABC <gridsquare:4>FN42 <mode:3>FT8 <rst_sent:3>-08 <rst_rcvd:3>-07 \
    <qso_date:8>20260704 <time_on:6>011230 <qso_date_off:8>20260704 <time_off:6>011330 \
    <band:3>20m <freq:9>14.076000 <station_callsign:5>W2ASM <my_gridsquare:4>FN31 <EOR>
    """

    private func loggedADIFDatagram(adif: String? = nil, id: String? = "WSJT-X") -> Data {
        var builder = DatagramBuilder()
        builder.appendHeader(type: 12)
        builder.appendString(id)
        builder.appendString(adif ?? sampleADIF)
        return builder.data
    }

    // MARK: - Status

    func testDecodeStatus() throws {
        let message = WSJTXMessage.decode(statusDatagram())
        guard case .status(let status)? = message else {
            return XCTFail("Expected .status, got \(String(describing: message))")
        }
        XCTAssertEqual(status.id, "WSJT-X")
        XCTAssertEqual(status.dialFrequencyHz, 14_074_000)
        XCTAssertEqual(status.dialFrequencyMHz, 14.074, accuracy: 0.000_001)
        XCTAssertEqual(status.mode, "FT8")
        XCTAssertEqual(status.dxCall, "K1ABC")
        XCTAssertEqual(status.report, "-10")
        XCTAssertEqual(status.txMode, "FT8")
        XCTAssertEqual(status.txEnabled, false)
        XCTAssertEqual(status.transmitting, false)
        XCTAssertEqual(status.decoding, true)
        XCTAssertEqual(status.rxDF, 1500)
        XCTAssertEqual(status.txDF, 1200)
        XCTAssertEqual(status.deCall, "W2ASM")
        XCTAssertEqual(status.deGrid, "FN31")
        XCTAssertEqual(status.dxGrid, "FN42")
    }

    func testDecodeStatusTruncatedAfterCoreFieldsStillDecodes() throws {
        // Older WSJT-X versions send fewer trailing fields; a frame ending
        // right after `mode` must still decode with nil optionals.
        var builder = DatagramBuilder()
        builder.appendHeader(type: 1)
        builder.appendString("WSJT-X")
        builder.appendUInt64(7_074_000)
        builder.appendString("FT8")
        let message = WSJTXMessage.decode(builder.data)
        guard case .status(let status)? = message else {
            return XCTFail("Expected .status, got \(String(describing: message))")
        }
        XCTAssertEqual(status.dialFrequencyHz, 7_074_000)
        XCTAssertEqual(status.mode, "FT8")
        XCTAssertNil(status.dxCall)
        XCTAssertNil(status.txEnabled)
    }

    func testDecodeStatusTruncatedInsideCoreFieldsFails() {
        // Cut mid-way through the dial frequency u64.
        var builder = DatagramBuilder()
        builder.appendHeader(type: 1)
        builder.appendString("WSJT-X")
        builder.appendUInt32(0)
        XCTAssertNil(WSJTXMessage.decode(builder.data))
    }

    func testDecodeStatusWithNullStringsUsesEmptyRequiredFields() {
        var builder = DatagramBuilder()
        builder.appendHeader(type: 1)
        builder.appendString(nil)            // id: wire null
        builder.appendUInt64(50_313_000)
        builder.appendString(nil)            // mode: wire null
        builder.appendString(nil)            // DX call: wire null
        let message = WSJTXMessage.decode(builder.data)
        guard case .status(let status)? = message else {
            return XCTFail("Expected .status, got \(String(describing: message))")
        }
        XCTAssertEqual(status.id, "")
        XCTAssertEqual(status.mode, "")
        XCTAssertNil(status.dxCall)
    }

    // MARK: - LoggedADIF

    func testDecodeLoggedADIF() throws {
        let message = WSJTXMessage.decode(loggedADIFDatagram())
        guard case .loggedADIF(let id, let adif)? = message else {
            return XCTFail("Expected .loggedADIF, got \(String(describing: message))")
        }
        XCTAssertEqual(id, "WSJT-X")
        XCTAssertTrue(adif.contains("<call:5>K1ABC"))
        XCTAssertTrue(adif.contains("<EOR>"))
    }

    func testDecodeLoggedADIFTruncatedPayloadFails() {
        // Declared string length exceeds the remaining bytes.
        var builder = DatagramBuilder()
        builder.appendHeader(type: 12)
        builder.appendString("WSJT-X")
        builder.appendUInt32(500)
        builder.data.append(contentsOf: Array("short".utf8))
        XCTAssertNil(WSJTXMessage.decode(builder.data))
    }

    /// End-to-end: decode the datagram, then parse the embedded ADIF into a
    /// QSORecord the same way the app's auto-logging path does.
    func testLoggedADIFParsesToQSORecord() throws {
        let message = WSJTXMessage.decode(loggedADIFDatagram())
        guard case .loggedADIF(_, let adif)? = message else {
            return XCTFail("Expected .loggedADIF, got \(String(describing: message))")
        }

        let parser = ADIFParser()
        let file = try parser.parse(string: adif)
        let records = parser.recordsToQSORecords(file.records)
        XCTAssertEqual(records.count, 1)

        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.call, "K1ABC")
        XCTAssertEqual(record.qsoDate, "20260704")
        XCTAssertEqual(record.timeOn, "011230")
        XCTAssertEqual(record.bandRaw, "20m")
        XCTAssertEqual(record.modeRaw, "FT8")
        XCTAssertEqual(record.gridsquare, "FN42")
        XCTAssertEqual(record.rstSent, "-08")
        XCTAssertEqual(record.rstRcvd, "-07")
        XCTAssertEqual(record.stationCallsign, "W2ASM")
        XCTAssertEqual(try XCTUnwrap(record.freq), 14.076, accuracy: 0.000_001)
    }

    // MARK: - Rejection paths

    func testWrongMagicIsRejected() {
        var builder = DatagramBuilder()
        builder.appendHeader(type: 1, magic: 0xdead_beef)
        builder.appendString("WSJT-X")
        builder.appendUInt64(14_074_000)
        builder.appendString("FT8")
        XCTAssertNil(WSJTXMessage.decode(builder.data))
    }

    func testTooOldSchemaIsRejected() {
        var builder = DatagramBuilder()
        builder.appendHeader(type: 1, schema: 1)
        builder.appendString("WSJT-X")
        builder.appendUInt64(14_074_000)
        builder.appendString("FT8")
        XCTAssertNil(WSJTXMessage.decode(builder.data))
    }

    func testEmptyAndTruncatedHeadersAreRejected() {
        XCTAssertNil(WSJTXMessage.decode(Data()))
        // Magic only
        var builder = DatagramBuilder()
        builder.appendUInt32(0xadbc_cbda)
        XCTAssertNil(WSJTXMessage.decode(builder.data))
        // Magic + schema, no type
        builder.appendUInt32(2)
        XCTAssertNil(WSJTXMessage.decode(builder.data))
    }

    func testGarbageIsRejected() {
        let garbage = Data((0..<64).map { _ in UInt8.random(in: 0...255) & 0x7F })
        // First four bytes forced below 0x80 so they can never equal the magic.
        XCTAssertNil(WSJTXMessage.decode(garbage))
    }

    func testUnknownMessageTypesAreIgnored() {
        // Type 2 = Decode: valid frame we deliberately don't parse.
        var builder = DatagramBuilder()
        builder.appendHeader(type: 2)
        builder.appendString("WSJT-X")
        builder.appendBool(true)
        XCTAssertEqual(WSJTXMessage.decode(builder.data), .other(type: 2))
    }

    func testNewerSchemaIsAccepted() {
        var builder = DatagramBuilder()
        builder.appendHeader(type: 1, schema: 3)
        builder.appendString("WSJT-X")
        builder.appendUInt64(21_074_000)
        builder.appendString("FT4")
        let message = WSJTXMessage.decode(builder.data)
        guard case .status(let status)? = message else {
            return XCTFail("Expected .status, got \(String(describing: message))")
        }
        XCTAssertEqual(status.mode, "FT4")
    }
}
