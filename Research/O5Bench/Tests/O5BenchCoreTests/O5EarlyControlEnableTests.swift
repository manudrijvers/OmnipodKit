import XCTest
@testable import O5BenchCore

final class O5EarlyControlEnableTests: XCTestCase {
    private var root: URL!
    private var id: String!
    private var requests: [Data] = []
    private var control: UInt8 = 255
    private var desired: UInt8 = 0
    private var ready = true
    private var active = true
    private var mode: UInt8 = 1
    private var cgm: UInt8 = 0
    private var fault: UInt8 = 0
    private var delivery: UInt8 = 1
    private var progress: UInt8 = 8
    private var reject: String?
    private var failureIndex: Int?
    private var mutationHook: (() throws -> Void)?
    private var interfaceHook: (() throws -> Void)?
    private var ignoreWrite = false
    private var afterWrite: (() -> Void)?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        id = UUID().uuidString
        try O5EarlyControlEnable.arm(id: id, target: "pod-A", firmware: "9.0.4", bleFirmware: "5.0.2", directory: root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private var file: URL { root.appendingPathComponent(id).appendingPathComponent("activation.json") }
    private func snapshot() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    }
    private func setPhase(_ phase: String) throws {
        var value = try snapshot(); value["phase"] = phase
        try JSONSerialization.data(withJSONObject: value).write(to: file)
    }
    private func aidStatus() -> Data {
        var bytes = Data(repeating: 0, count: 24)
        bytes[1] = 22; bytes[10] = mode; bytes[20] = (ready ? 1 : 0) | (active ? 2 : 0); bytes[21] = cgm
        return bytes
    }
    private func interface() -> Data { Data([0, 9, 0, 0, 0, 0, 0x13, 1, desired, 4, control]) }
    private func send(_ request: Data, _ prefix: String) throws -> Data {
        requests.append(request)
        if failureIndex == requests.count { throw URLError(.timedOut) }
        switch String(decoding: request, as: UTF8.self) {
        case "G3.12": return aidStatus()
        case "G4.2":
            try interfaceHook?()
            return interface()
        default:
            XCTAssertEqual(request, Data("SE4.2=".utf8) + Data([0, 2, 4, 0]))
            XCTAssertEqual(prefix, "ES4.2=")
            XCTAssertEqual(try snapshot()["phase"] as? String, "writePending")
            let entries = try XCTUnwrap(snapshot()["exchanges"] as? [[String: Any]])
            XCTAssertNil(entries.last?["response"])
            try mutationHook?()
            if !ignoreWrite { control = 0 }
            afterWrite?()
            return Data((reject ?? "0").utf8)
        }
    }
    private func detailed() throws -> Data {
        var bytes = Data(repeating: 0, count: 22)
        bytes[0] = 2; bytes[1] = progress; bytes[2] = delivery; bytes[8] = fault
        return bytes
    }
    private func finish(target: String = "pod-A", firmware: String = "9.0.4") throws {
        try O5EarlyControlEnable.finish(id: id, target: target, firmware: firmware, bleFirmware: "5.0.2",
            directory: root, send: send, detailedStatus: detailed)
    }
    private var writes: [Data] { requests.filter { $0.starts(with: Data("S".utf8)) } }

    func testOnlyOneExactControlWriteAndDurableEvidence() throws {
        try finish()
        XCTAssertEqual(writes, [Data("SE4.2=".utf8) + Data([0, 2, 4, 0])])
        XCTAssertEqual(requests.filter { $0.first != 83 }.map { String(decoding: $0, as: UTF8.self) },
            ["G3.12", "G4.2", "G4.2", "G3.12"])
        XCTAssertEqual(try snapshot()["phase"] as? String, "verified")
        XCTAssertTrue(try O5EarlyControlEnable.record(id: id, directory: root).contains("verified"))
        XCTAssertEqual(desired, 0)
    }
    func testAlreadyEnabledSkipsMutation() throws {
        control = 0; try finish(); XCTAssertTrue(writes.isEmpty)
    }
    func testConfirmedResultCanBeRecheckedAfterRestartWithoutWrite() throws {
        try finish(); requests.removeAll(); try finish(); XCTAssertTrue(writes.isEmpty)
    }
    func testChangedControlAfterVerifiedNeverReenabled() throws {
        try finish(); control = 255; requests.removeAll()
        XCTAssertThrowsError(try finish()); XCTAssertTrue(writes.isEmpty)
    }
    func testEveryInterruptedPhaseStopsBeforeTransport() throws {
        for phase in ["checking", "writePending", "stopped", "unknown"] {
            try setPhase(phase); requests.removeAll()
            XCTAssertThrowsError(try finish()); XCTAssertTrue(requests.isEmpty)
        }
    }
    func testMissingRecordNeverRecreatedForMarkedPod() throws {
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try finish()); XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testCorruptRecordNeverSends() throws {
        try Data("invalid".utf8).write(to: file)
        XCTAssertThrowsError(try finish()); XCTAssertTrue(requests.isEmpty)
    }
    func testWrongPodAndFirmwareNeverSend() throws {
        XCTAssertThrowsError(try finish(target: "pod-B"))
        XCTAssertThrowsError(try finish(firmware: "12.0.0"))
        XCTAssertTrue(requests.isEmpty)
    }
    func testCannotRearmOrOverwriteAttempt() throws {
        let data = try Data(contentsOf: file)
        XCTAssertThrowsError(try O5EarlyControlEnable.arm(id: id, target: "pod-B", firmware: "9.0.4", bleFirmware: "5.0.2", directory: root))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testNonManualAndUnreadyStatusesStopBeforeWrite() throws {
        for field in 0..<5 {
            ready = true; active = true; mode = 1; delivery = 1; fault = 0
            if field == 0 { ready = false }
            if field == 1 { active = false }
            if field == 2 { mode = 2 }
            if field == 3 { delivery = 0 }
            if field == 4 { fault = 226 }
            try setPhase("armed"); requests.removeAll()
            XCTAssertThrowsError(try finish()); XCTAssertTrue(writes.isEmpty)
        }
    }
    func testWrongProgressStopsBeforeWrite() throws {
        progress = 7; XCTAssertThrowsError(try finish()); XCTAssertTrue(writes.isEmpty)
    }
    func testUnexpectedSensorOrControlStopsBeforeWrite() throws {
        for (type, value): (UInt8, UInt8) in [(7, 255), (0, 3), (0, 254)] {
            desired = type; control = value; try setPhase("armed"); requests.removeAll()
            XCTAssertThrowsError(try finish()); XCTAssertTrue(writes.isEmpty)
        }
    }
    func testRejectionStopsAndCannotRetryMutation() throws {
        reject = "-18"; XCTAssertThrowsError(try finish()); XCTAssertEqual(writes.count, 1)
        XCTAssertThrowsError(try finish()); XCTAssertEqual(writes.count, 1)
    }
    func testEveryTransportTimeoutStopsAndNoRetry() throws {
        for index in 1...5 {
            control = 255; failureIndex = index; try setPhase("armed"); requests.removeAll()
            XCTAssertThrowsError(try finish())
            let count = requests.count
            XCTAssertThrowsError(try finish()); XCTAssertEqual(requests.count, count)
        }
    }
    func testLostResponseAfterAppliedWriteCannotBeResent() throws {
        mutationHook = { self.control = 0; throw URLError(.timedOut) }
        XCTAssertThrowsError(try finish()); XCTAssertEqual(control, 0); XCTAssertEqual(writes.count, 1)
        mutationHook = nil
        XCTAssertThrowsError(try finish()); XCTAssertEqual(writes.count, 1)
    }
    func testVerificationFailureStopsWithoutRetry() throws {
        ignoreWrite = true
        XCTAssertThrowsError(try finish()); XCTAssertEqual(writes.count, 1)
        XCTAssertThrowsError(try finish()); XCTAssertEqual(writes.count, 1)
    }
    func testPostWriteFaultAndModeChangeStop() throws {
        afterWrite = { self.fault = 226 }
        XCTAssertThrowsError(try finish()); XCTAssertEqual(writes.count, 1)
        fault = 0; control = 255; try setPhase("armed"); requests.removeAll()
        afterWrite = { self.mode = 2 }
        XCTAssertThrowsError(try finish()); XCTAssertEqual(writes.count, 1)
    }
    func testConcurrentAttemptCannotAcquireLeaseOrSend() throws {
        mutationHook = {
            XCTAssertThrowsError(try self.finish())
        }
        try finish(); XCTAssertEqual(writes.count, 1)
    }
    func testJournalFailureBeforeSendPreventsWrite() throws {
        // Turn the destination into a directory before the write-intent save.
        // Loading the required journal must fail before any transport call.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try finish()); XCTAssertTrue(requests.isEmpty)
    }
    func testPersistenceFailureAfterPrereadNeverReleasesWrite() throws {
        let directory = file.deletingLastPathComponent()
        interfaceHook = {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try finish())
        XCTAssertTrue(writes.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(try snapshot()["phase"] as? String, "checking")
        interfaceHook = nil
        XCTAssertThrowsError(try finish()); XCTAssertTrue(writes.isEmpty)
    }

    func testPersistenceFailureAfterAppliedWriteRetainsDurableIntent() throws {
        let directory = file.deletingLastPathComponent()
        mutationHook = {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try finish())
        XCTAssertEqual(control, 0); XCTAssertEqual(writes.count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(try snapshot()["phase"] as? String, "writePending")
        mutationHook = nil
        XCTAssertThrowsError(try finish()); XCTAssertEqual(writes.count, 1)
    }

}
