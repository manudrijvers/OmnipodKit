//
//  O5AidCommandsTests.swift
//  OmniTests
//

import XCTest
@testable import O5BenchCore

class O5AidCommandsTests: XCTestCase {

    func testUtcCommand() {
        let (payload, prefix) = O5AidCommands.UtcCommand.payload(timestamp: O5CommLogFixtures.utcTimestamp)
        XCTAssertEqual(payload, O5CommLogFixtures.utcSend)
        XCTAssertEqual(prefix, "ES255.2=")
        XCTAssertEqual(String(data: O5CommLogFixtures.utcRecvBody, encoding: .utf8), "0")
    }

    func testTdiCommand() {
        let (payload, prefix) = O5AidCommands.TdiCommand.payload()
        XCTAssertEqual(payload, O5CommLogFixtures.tdiSend)
        XCTAssertEqual(prefix, "3.2=")
        XCTAssertEqual(O5CommLogFixtures.tdiRecvBody, O5AidCommands.TdiCommand.defaultBinaryData)
    }

    func testTargetBgProfile() {
        let (payload, prefix) = O5AidCommands.TargetBgProfileCommand.payload()
        XCTAssertEqual(payload, O5CommLogFixtures.targetBgProfileSend)
        XCTAssertEqual(prefix, "3.1=")
        XCTAssertEqual(O5CommLogFixtures.targetBgProfileRecvBody.count, 194)
    }

    func testDiaCommand() {
        let (payload, prefix) = O5AidCommands.DiaCommand.payload()
        XCTAssertEqual(payload, O5CommLogFixtures.diaSend)
        XCTAssertEqual(prefix, "3.9=")
        XCTAssertEqual(String(data: O5CommLogFixtures.diaRecvBody, encoding: .utf8), O5AidCommands.DiaCommand.defaultValue)
    }

    func testEgvCommand() {
        let (payload, prefix) = O5AidCommands.EgvCommand.payload(value: O5CommLogFixtures.egvValue)
        XCTAssertEqual(payload, O5CommLogFixtures.egvSend)
        XCTAssertEqual(prefix, "3.7=")
        XCTAssertEqual(String(data: O5CommLogFixtures.egvRecvBody, encoding: .utf8), O5CommLogFixtures.egvValue)
    }

    func testAlgorithmInsulinHistory() {
        let (payload, prefix) = O5AidCommands.AlgorithmInsulinHistoryCommand.payload()
        XCTAssertEqual(payload, O5CommLogFixtures.algorithmInsulinHistorySend)
        XCTAssertEqual(prefix, "ES2.1=")
        XCTAssertEqual(String(data: O5CommLogFixtures.insulinHistoryRecvBody, encoding: .utf8), "0")
    }

    func testTargetBgProfile_payloadSize() {
        let (payload, _) = O5AidCommands.TargetBgProfileCommand.payload()
        XCTAssertEqual(payload.count, 204)
    }

    func testAlgorithmInsulinHistory_payloadSize() {
        let (payload, _) = O5AidCommands.AlgorithmInsulinHistoryCommand.payload()
        XCTAssertEqual(payload.count, 176)
        let prefix = Data("SE2.1=".utf8)
        XCTAssertTrue(payload.starts(with: prefix))
        XCTAssertEqual(payload[prefix.count], 0x00)
        XCTAssertEqual(payload[prefix.count + 1], 0xA8)
    }

    func testAidPodStatus_getOnly() {
        let (g311, p311) = O5AidCommands.AidPodStatusCommand.payload()
        XCTAssertEqual(g311, Data("G3.11".utf8))
        XCTAssertEqual(p311, "3.11=")

        let (g312, p312) = O5AidCommands.UnifiedAidPodStatusCommand.payload()
        XCTAssertEqual(g312, Data("G3.12".utf8))
        XCTAssertEqual(p312, "3.12=")
    }

    func testResponsePrefixes() {
        XCTAssertEqual(O5AidCommands.responsePrefix(feature: "3", attribute: "9"), "3.9=")
        XCTAssertEqual(O5AidCommands.extendedSetResponsePrefix(feature: "255", attribute: "2"), "ES255.2=")
    }

    // MARK: - Dexcom G7 (dummy values from static analysis of the O5 app, not pod captures)

    func testCgmInterfaceCommand_enableDexcomG7() {
        let (payload, prefix) = O5AidCommands.CgmInterfaceCommand.payload()
        XCTAssertEqual(payload, Data("SE4.2=".utf8) + Data([0x00, 0x04, 0x04, 0x00, 0x01, 0x07]))
        XCTAssertEqual(prefix, "ES4.2=")

        let (get, getPrefix) = O5AidCommands.CgmInterfaceCommand.getPayload()
        XCTAssertEqual(get, Data("G4.2".utf8))
        XCTAssertEqual(getPrefix, "4.2=")
    }

    func testG7SensorInfoCommand() {
        let (payload, prefix) = O5AidCommands.G7SensorInfoCommand.payload(pairingCode: "1234", serialNumber: "123456789012")
        let expectedValue = Data(hexadecimalString: "0012023132333403313233343536373839303132")!
        XCTAssertEqual(payload, Data("SE4.1=".utf8) + expectedValue)
        XCTAssertEqual(prefix, "ES4.1=")

        let (get, getPrefix) = O5AidCommands.G7SensorInfoCommand.getPayload()
        XCTAssertEqual(get, Data("G4.1".utf8))
        XCTAssertEqual(getPrefix, "4.1=")
    }

    func testExtendedSetResultDescription() {
        XCTAssertEqual(O5AidCommands.extendedSetResultDescription(Data("0".utf8)), "0 (success)")
        XCTAssertEqual(O5AidCommands.extendedSetResultDescription(Data("-5".utf8)), "-5 (invalid arguments)")
        XCTAssertEqual(O5AidCommands.extendedSetResultDescription(Data("3".utf8)), "3")
    }

    func testCgmStatus_dexcomG7() {
        // EGV 123 mg/dL read 32 s before the pod time, closed loop, G7 state 6, trend -12 (valid)
        let response = Data(hexadecimalString:
            "0026" + "007b" + "65001000" + "0028" + "02" + "000005dc" + "65001020" + "00" + "03" + "07" + "0010" +
            "65000000" + "000d2f00" + "00001c20" + "06" + "00" + "f4" + "01")!
        // sendO5AidCommand returns the body as a slice after the "3.12=" prefix
        let status = O5AidCgmStatus((Data("3.12=".utf8) + response).suffix(from: 5))
        XCTAssertNotNil(status)
        XCTAssertEqual(status?.egv, 123)
        XCTAssertEqual(status?.egvAge, 32)
        XCTAssertEqual(status?.loopState, 2)
        XCTAssertEqual(status?.cgmType, 7)
        XCTAssertEqual(status?.cgmData.count, 16)
        XCTAssertTrue(status?.description.contains("G7 trend rate: -12") ?? false)
        XCTAssertTrue(status?.description.contains("G7 algorithm state: 6") ?? false)
    }

    func testCgmStatus_rejectsLengthMismatch() {
        XCTAssertNil(O5AidCgmStatus(Data(hexadecimalString: "0030" + String(repeating: "00", count: 22))!))
    }
}
