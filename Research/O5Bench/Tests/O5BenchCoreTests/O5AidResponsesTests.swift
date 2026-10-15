import XCTest
@testable import O5BenchCore

final class O5AidResponsesTests: XCTestCase {
    private func hex(_ text: String) -> Data { Data(hexadecimalString: text)! }
    private func framed(_ body: Data) -> Data {
        Data([UInt8(body.count >> 8), UInt8(body.count & 255)]) + body
    }
    private func fields(_ entries: [(UInt8, Data)], mask: UInt32? = nil) -> Data {
        let actual = entries.reduce(UInt32(1)) { $0 | (1 << $1.0) }
        var body = Data([0]); body.appendBigEndian(mask ?? actual)
        for (key, value) in entries { body.append(key); body.append(value) }
        return framed(body)
    }
    private var g7Fields: [(UInt8, Data)] {
        [(1, hex("07")), (2, Data("1234".utf8)), (3, Data("123456789012".utf8)),
         (4, hex("ffff")), (5, hex("010203040506")), (6, hex("ffffffff")),
         (7, hex("ffffffff")), (8, hex("ff")), (9, hex("01"))]
    }
    // Synthetic G7 example from the RE notes; not a successful device capture.
    private var g7Status: Data {
        hex("0026007b650010000028028000000065001020000307001065000000000d2f0000001c200600f401")
    }

    func testIncidentInterfaceAndEmptyIdentity() throws {
        let status = try O5CgmInterfaceStatus(hex("000d00ffffffff01000201030104ff"))
        XCTAssertEqual(status.attributeMask, UInt32.max)
        XCTAssertEqual(status.desiredSensorType, 0)
        XCTAssertEqual(status.allowedSensorType, 1)
        XCTAssertEqual(status.managerVersion, 1)
        XCTAssertEqual(status.control, 255)
        let empty = try O5G7SensorInfo(hex("0000"))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.attributeMask)
        XCTAssertEqual(empty.compare(pairingCode: "1234", serialNumber: "123456789012"), .indeterminate)
        XCTAssertThrowsError(try O5CgmInterfaceStatus(hex("0000")))
    }

    func testMaskOnlyAndUnknownEnumDoNotBecomeZero() throws {
        let absent = try O5CgmInterfaceStatus(fields([]))
        XCTAssertNil(absent.control)
        XCTAssertNil(absent.desiredSensorType)
        let unknown = try O5CgmInterfaceStatus(fields([(4, hex("ee"))]))
        XCTAssertEqual(unknown.control, 238)
    }

    func testUnsortedFieldsAndSlicedData() throws {
        let value = fields([(4, hex("00")), (1, hex("07"))])
        let sliced = (hex("9999") + value).dropFirst(2)
        XCTAssertNotEqual(sliced.startIndex, 0)
        let status = try O5CgmInterfaceStatus(sliced)
        XCTAssertEqual(status.control, 0)
        XCTAssertEqual(status.desiredSensorType, 7)
        XCTAssertEqual(status.attributeMask, 0x13)
    }

    func testEveryPrefixTruncationFails() {
        let interface = fields([(4, hex("00")), (1, hex("07"))])
        let sensor = fields(g7Fields)
        for length in 0..<interface.count { XCTAssertThrowsError(try O5CgmInterfaceStatus(interface.prefix(length))) }
        for length in 0..<sensor.count { XCTAssertThrowsError(try O5G7SensorInfo(sensor.prefix(length))) }
        for length in 0..<g7Status.count { XCTAssertThrowsError(try O5UnifiedAidStatus(g7Status.prefix(length))) }
    }

    func testKeyAndMaskErrorsEvenWithWildcard() {
        for mask: UInt32 in [0x11, .max] {
            XCTAssertThrowsError(try O5CgmInterfaceStatus(fields([(4, hex("00")), (4, hex("00"))], mask: mask)))
            XCTAssertThrowsError(try O5CgmInterfaceStatus(fields([(9, hex("00"))], mask: mask)))
            XCTAssertThrowsError(try O5CgmInterfaceStatus(fields([(4, Data())], mask: mask)))
        }
        XCTAssertThrowsError(try O5CgmInterfaceStatus(fields([(4, hex("00"))], mask: 0x10)))
        XCTAssertThrowsError(try O5CgmInterfaceStatus(framed(hex("0400"))))
        XCTAssertThrowsError(try O5G7SensorInfo(fields([(2, Data("123".utf8))])))
        XCTAssertThrowsError(try O5G7SensorInfo(fields([(10, hex("00"))], mask: .max)))
        XCTAssertThrowsError(try O5G7SensorInfo(fields([(1, hex("04"))])))
    }

    func testLengthsAndTrailingBytes() {
        XCTAssertThrowsError(try O5CgmInterfaceStatus(hex("00050000000001ff")))
        XCTAssertThrowsError(try O5G7SensorInfo(hex("000000")))
        var status = g7Status; status[23] = 15
        XCTAssertThrowsError(try O5UnifiedAidStatus(status))
        status = g7Status; status[21] = 4
        XCTAssertThrowsError(try O5UnifiedAidStatus(status))
        status = g7Status; status[20] = 0x80
        XCTAssertThrowsError(try O5UnifiedAidStatus(status))
    }

    func testEveryG7FieldRejectsTruncationWithCorrectOuterLength() {
        for (key, value) in g7Fields {
            XCTAssertThrowsError(try O5G7SensorInfo(fields([(key, value.dropLast())])))
        }
        XCTAssertThrowsError(try O5G7SensorInfo(framed(hex("00ffffff"))))
        XCTAssertThrowsError(try O5G7SensorInfo(fields([(0, hex("ffffffff"))], mask: .max)))
    }

    func testG6SignedFieldsAndUnavailableEgv() throws {
        var value = Data(g7Status.prefix(24)); value[1] = 31; value[21] = 4; value[23] = 9
        value.append(hex("65000000f40600ffff"))
        let status = try O5UnifiedAidStatus(value)
        XCTAssertEqual(status.g6?.trendRate, -12)
        XCTAssertEqual(status.g6?.lifetime, -1)
        XCTAssertNil(status.g7)
        XCTAssertFalse(status.hasRecentG7Reading(maxAge: 300))
        var negative = g7Status; negative[2] = 255; negative[3] = 254
        XCTAssertEqual(try O5UnifiedAidStatus(negative).egvRaw, -2)
        XCTAssertFalse(try O5UnifiedAidStatus(negative).hasRecentG7Reading(maxAge: 300))
    }

    func testAllG7FieldsPreserveRawBitsAndIdentity() throws {
        let sensor = try O5G7SensorInfo(fields(g7Fields.reversed()))
        XCTAssertEqual(sensor.operatingInterval, UInt16.max)
        XCTAssertEqual(sensor.advertisingReferenceTime, UInt32.max)
        XCTAssertEqual(sensor.lifetime, UInt32.max)
        XCTAssertEqual(sensor.driverVersion, 255)
        XCTAssertEqual(sensor.addressType, 1)
        XCTAssertEqual(sensor.bluetoothAddress, "06:05:04:03:02:01")
        XCTAssertEqual(sensor.compare(pairingCode: "1234", serialNumber: "123456789012"), .same)
        XCTAssertEqual(sensor.compare(pairingCode: "4321", serialNumber: "123456789012"), .different)
        XCTAssertFalse(sensor.description.contains("123456789012"))
        XCTAssertEqual(sensor.compare(pairingCode: "１２３４", serialNumber: "123456789012"), .indeterminate)
        let partial = try O5G7SensorInfo(fields([(2, Data("1234".utf8))]))
        XCTAssertEqual(partial.compare(pairingCode: "1234", serialNumber: "123456789012"), .indeterminate)
        let nonDigits = try O5G7SensorInfo(fields([(2, hex("ff000000")), (3, Data("123456789012".utf8))]))
        XCTAssertEqual(nonDigits.pairingCodeBytes, hex("ff000000"))
        XCTAssertEqual(nonDigits.compare(pairingCode: "1234", serialNumber: "123456789012"), .indeterminate)
    }

    func testIncidentUnifiedStatusDoesNotImplyConnection() throws {
        let status = try O5UnifiedAidStatus(hex("0016000000000000000e01800000006ace5f340003000000"))
        XCTAssertTrue(status.algorithmReady)
        XCTAssertTrue(status.podActive)
        XCTAssertTrue(status.isManual)
        XCTAssertFalse(status.activityMode)
        XCTAssertFalse(status.limitedMode)
        XCTAssertNil(status.egv)
        XCTAssertNil(status.egvAge)
        XCTAssertNil(status.iobMicroUnits)
        XCTAssertNil(status.g7)
        XCTAssertFalse(status.hasRecentG7Reading(maxAge: 300))
    }

    func testFullStatusAndFreshnessAreSeparateFromMode() throws {
        let status = try O5UnifiedAidStatus((hex("ffff") + g7Status).dropFirst(2))
        XCTAssertEqual(status.egv, 123)
        XCTAssertEqual(status.egvAge, 32)
        XCTAssertEqual(status.totalDailyInsulin, 40)
        XCTAssertNil(status.iobMicroUnits)
        XCTAssertFalse(status.isManual)
        XCTAssertTrue(status.hasRecentG7Reading(maxAge: 32))
        XCTAssertFalse(status.hasRecentG7Reading(maxAge: 31))
        XCTAssertFalse(status.hasRecentG7Reading(maxAge: .nan))
        XCTAssertEqual(status.g7?.trendRate, -12)
        XCTAssertEqual(status.g7?.sessionDuration, 864000)
        XCTAssertEqual(status.g7?.sensorTimestamp, 7200)
        var changed = g7Status; changed[39] = 2
        XCTAssertNil(try O5UnifiedAidStatus(changed).g7?.trendRate)
        changed = g7Status; changed[18] = 0
        // Timestamp now equals reference time; subtract using a wider/safe type.
        XCTAssertEqual(try O5UnifiedAidStatus(changed).egvAge, 0)
        changed[17] = 0
        XCTAssertNil(try O5UnifiedAidStatus(changed).egvAge)
        XCTAssertFalse(try O5UnifiedAidStatus(changed).hasRecentG7Reading(maxAge: 300))
        XCTAssertNoThrow(O5AidCgmStatus(changed)?.description)
    }

    func testFlagsAndUnknownStatusRemainVisible() throws {
        var value = g7Status; value[19] = 0xff; value[20] = 0x0f; value[10] = 255
        let status = try O5UnifiedAidStatus(value)
        XCTAssertTrue(status.historyWrittenOnAlarm)
        XCTAssertTrue(status.lastHistoryRecordRequested)
        XCTAssertTrue(status.activityMode)
        XCTAssertTrue(status.limitedMode)
        XCTAssertEqual(status.unknownStatusBits, 0xf0)
        XCTAssertFalse(status.isManual)
        value[21] = 254
        let future = try O5UnifiedAidStatus(value)
        XCTAssertNil(future.g7)
        XCTAssertEqual(future.cgmData.count, 16)
        XCTAssertFalse(future.hasRecentG7Reading(maxAge: 300))
    }

    func testExtendedSetRequiresCanonicalZero() throws {
        try O5AidResponseValidation.extendedSet(Data("0".utf8), command: "ES4.1=")
        for code in ["-5", "-14", "-19", "1", "99"] {
            XCTAssertThrowsError(try O5AidResponseValidation.extendedSet(Data(code.utf8), command: "ES4.1=")) { error in
                guard case O5AidResponseError.rejected(_, let actual) = error else { return XCTFail("Wrong error: \(error)") }
                XCTAssertEqual(actual, Int(code))
            }
        }
        for malformed in ["", "00", "-0", "+0", "0\n", " 0", "0,ES4.1=0", "999999999999999999999999999999"] {
            XCTAssertThrowsError(try O5AidResponseValidation.extendedSet(Data(malformed.utf8), command: "ES4.1="))
        }
        XCTAssertThrowsError(try O5AidResponseValidation.extendedSet(hex("ff"), command: "ES4.1="))
    }

    func testSetGetComparesActualSentValue() throws {
        for (request, prefix, response) in [
            (O5CommLogFixtures.tdiSend, "3.2=", O5CommLogFixtures.tdiRecvBody),
            (O5CommLogFixtures.diaSend, "3.9=", O5CommLogFixtures.diaRecvBody),
            (O5CommLogFixtures.egvSend, "3.7=", O5CommLogFixtures.egvRecvBody),
            (O5CommLogFixtures.targetBgProfileSend, "3.1=", O5CommLogFixtures.targetBgProfileRecvBody)] {
            try O5AidResponseValidation.setGet(response, request: request, responsePrefix: prefix)
            XCTAssertThrowsError(try O5AidResponseValidation.setGet(response + hex("00"), request: request, responsePrefix: prefix))
        }
        let value = hex("002c47332e31ff") // Embedded comma/GET-like bytes stay binary data.
        let request = O5AidCommands.setGetPayload(feature: "3", attribute: "1", binaryData: value)
        try O5AidResponseValidation.setGet(value, request: request, responsePrefix: "3.1=")
        XCTAssertThrowsError(try O5AidResponseValidation.setGet(value, request: request, responsePrefix: "3.2="))
    }

    func testRejectedFirstWriteStopsSequence() {
        var calls = 0
        let send: (Data, String) throws -> Data = { _, _ in calls += 1; return Data("-5".utf8) }
        XCTAssertThrowsError(try {
            _ = try O5AidResponseValidation.extendedSet(command: O5AidCommands.CgmInterfaceCommand.payload(), send: send)
            _ = try O5AidResponseValidation.extendedSet(command: O5AidCommands.G7SensorInfoCommand.payload(pairingCode: "1234", serialNumber: "123456789012"), send: send)
        }())
        XCTAssertEqual(calls, 1)
    }

    func testSecondWriteRejectionIsNotSuccess() {
        var calls = 0
        let send: (Data, String) throws -> Data = { _, _ in calls += 1; return Data((calls == 1 ? "0" : "-19").utf8) }
        XCTAssertThrowsError(try {
            _ = try O5AidResponseValidation.extendedSet(command: O5AidCommands.CgmInterfaceCommand.payload(), send: send)
            _ = try O5AidResponseValidation.extendedSet(command: O5AidCommands.G7SensorInfoCommand.payload(pairingCode: "1234", serialNumber: "123456789012"), send: send)
        }())
        XCTAssertEqual(calls, 2)
    }

    func testTransportFailureRemainsUnconfirmedAndIsNotRetried() {
        var calls = 0, validated = false
        XCTAssertThrowsError(try O5AidResponseValidation.exchange(command: "ES4.1=", send: {
            calls += 1
            throw NSError(domain: "test-ack-lost", code: 1)
        }, validate: { _ in validated = true })) { error in
            guard case O5AidResponseError.unconfirmed(let command, let underlying) = error else { return XCTFail("Wrong error") }
            XCTAssertEqual(command, "ES4.1=")
            XCTAssertEqual((underlying as NSError).domain, "test-ack-lost")
        }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(validated)
    }
}
