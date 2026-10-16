import XCTest
@testable import O5BenchCore

/// Exercises the physical controller branch with a deterministic radio double.
/// No real Pod observations are represented by these tests.
private final class PhysicalRadioDouble: BenchTransport {
    let fake = FakeBenchTransport(clock: BenchClock())
    var physical = true
    var clock: BenchClock { fake.clock }
    var target: BenchTarget { fake.target }
    var firmware: String { fake.firmware }
    var bleVersion: String { fake.bleVersion }
    var activationProvenance: String { "TEST DOUBLE" }
    var access = true
    var rejectPolicy = false
    var loseAck = false
    var beforeCapture: (([BenchRequest]) -> Void)?
    var afterCapture: (() throws -> Void)?
    func checkAccess() throws { if !access { throw BenchError.target } }
    func policy(for requests: [BenchRequest]) throws -> String {
        if rejectPolicy { throw O5BenchSigningPolicy.Failure.missing }
        return "iOS signing ID 0; certificate default; mode 4; certificate SHA256 SECRET-FINGERPRINT"
    }
    func reconnect() throws { fake.reconnect() }
    func exchange(_ requests: [BenchRequest], capture: @escaping O5BenchWireCapture) throws -> [Data] {
        try checkAccess()
        beforeCapture?(requests)
        try capture("aid-send-mode-4", requests.reduce(Data()) { $0 + $1.body })
        let replies = try fake.exchange(requests)
        for reply in replies { try capture("raw-response", reply) }
        try afterCapture?()
        if loseAck { throw BenchError.interrupted }
        return replies
    }
}
private final class PhysicalMemoryStore: BenchStore {
    var saved: BenchSession?
    var fail = false
    func load() throws -> BenchSession? { saved }
    func save(_ session: BenchSession) throws { if fail { throw BenchError.logging }; saved = session }
    func export(_ session: BenchSession, to url: URL, redacted: Bool) throws { try BenchExport.write(session, to: url, redacted: redacted) }
}

final class PhysicalBenchTests: XCTestCase {
    private var paths: [URL] = []
    private func temporary() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths.append(url); return url
    }
    override func tearDown() { paths.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    private func ready() throws -> (BenchRunner, PhysicalRadioDouble, PhysicalMemoryStore) {
        let radio = PhysicalRadioDouble(), store = PhysicalMemoryStore()
        let runner = try BenchRunner(store: store, transport: radio)
        try runner.arm(offBodyConfirmed: true)
        try runner.perform(.baseline, baselineExport: temporary()); try runner.perform(.reconnect)
        return (runner, radio, store)
    }
    func testPhysicalBatchAndAutomaticRawCapture() throws {
        let (runner, radio, store) = try ready()
        try runner.perform(.enable)
        try runner.perform(.provision, identity: BenchIdentity(code: "0123", serial: "001234567890"))
        let writes = radio.fake.sends.filter { $0.contains(where: \.isMutation) }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0], [.enable]); XCTAssertEqual(writes[1].count, 2)
        XCTAssertTrue(runner.session.configurationConfirmed)
        XCTAssertEqual(store.saved?.physical, true)
        XCTAssertTrue(store.saved!.operations.allSatisfy { !($0.wireRecords ?? []).isEmpty })
        XCTAssertTrue(store.saved!.operations.allSatisfy { $0.signingPolicy.contains("mode 4") })
    }
    func testRawReplySurvivesLostAckAndRestartNeverReplays() throws {
        let (runner, radio, store) = try ready()
        radio.loseAck = true
        // Fail the enable's prerequisite read: exact reply still survives the lost ACK.
        XCTAssertThrowsError(try runner.perform(.enable))
        XCTAssertFalse(store.saved!.operations.last!.wireRecords!.filter { $0.phase == "raw-response" }.isEmpty)
        XCTAssertEqual(store.saved!.operations.last!.outcome, "pending")
        let count = radio.fake.sends.count
        radio.loseAck = false
        let reopened = try BenchRunner(store: store, transport: radio)
        XCTAssertFalse(reopened.session.armed)
        XCTAssertFalse(reopened.session.locks.isEmpty)
        XCTAssertEqual(radio.fake.sends.count, count)
        try reopened.perform(.diagnostic)
        XCTAssertThrowsError(try reopened.perform(.enable))
        XCTAssertTrue(radio.fake.sends.allSatisfy { !$0.contains(where: \.isMutation) })
    }
    func testPersistenceFailureBeforeDispatchStopsRadio() throws {
        let (runner, radio, store) = try ready()
        let count = radio.fake.sends.count; store.fail = true
        XCTAssertThrowsError(try runner.perform(.enable))
        XCTAssertEqual(radio.fake.sends.count, count)
    }
    func testBaselineExpiresWhileQueuedBeforeActualMutationSend() throws {
        let (runner, radio, _) = try ready()
        radio.beforeCapture = { requests in
            if requests.contains(where: \.isMutation) { radio.clock.advance(91) }
        }
        XCTAssertThrowsError(try runner.perform(.enable))
        XCTAssertTrue(radio.fake.sends.allSatisfy { !$0.contains(where: \.isMutation) })
        XCTAssertFalse(runner.session.locks.isEmpty)
    }

    func testUnresolvedPolicyAndWrongTargetNeverDispatch() throws {
        let (runner, radio, _) = try ready()
        let count = radio.fake.sends.count; radio.rejectPolicy = true
        XCTAssertThrowsError(try runner.perform(.enable))
        XCTAssertEqual(radio.fake.sends.count, count)
        radio.rejectPolicy = false; radio.access = false
        XCTAssertThrowsError(try runner.perform(.diagnostic))
        XCTAssertEqual(radio.fake.sends.count, count)
    }
    func testCaptureFailureAfterReplyLocksFurtherWrites() throws {
        let (runner, radio, store) = try ready()
        radio.afterCapture = { store.fail = true }
        XCTAssertThrowsError(try runner.perform(.enable))
        XCTAssertFalse(runner.session.locks.isEmpty)
        let count = radio.fake.sends.count
        XCTAssertThrowsError(try runner.perform(.provision, identity: BenchIdentity(code: "0123", serial: "001234567890")))
        XCTAssertEqual(count, radio.fake.sends.count)
    }
    func testRedactedPhysicalExportOmitsRawBytesAndCertificateIdentifier() throws {
        let (runner, _, _) = try ready()
        let root = temporary(); try runner.export(to: root)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
        XCTAssertEqual(manifest["synthetic"] as? Bool, false)
        XCTAssertEqual(manifest["transport"] as? String, "BLE")
        let text = try String(contentsOf: root.appendingPathComponent("exchanges.ndjson"))
        XCTAssertFalse(text.contains("SECRET-FINGERPRINT"))
        XCTAssertTrue(text.contains("REDACTED"))
        for line in text.split(separator: "\n") {
            let op = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            for record in op["wireRecords"] as! [[String: Any]] { XCTAssertEqual(record["hex"] as? String, "REDACTED") }
        }
    }
    func testPhysicalCancellationAndDiagnosticReset() throws {
        var sends = 0
        let connection = O5PhysicalBenchConnection(sessionID: UUID().uuidString, target: .synthetic,
            firmware: "9.0.4", bleVersion: "5.0.2", activationProvenance: "TEST DOUBLE", validate: {},
            selectPolicy: { _ in "test" }, exchange: { _, _ in sends += 1; return [] }, reconnect: {})
        connection.stop()
        XCTAssertThrowsError(try connection.exchange([.enable], capture: { _, _ in }))
        XCTAssertEqual(sends, 0)
        try connection.allowDiagnosticReadback()
        XCTAssertNoThrow(try connection.checkAccess())
        XCTAssertTrue(connection.clock.realTime)
    }
    func testBackgroundPauseEndsOnStopAndReacquiresForDiagnostics() throws {
        let pause = O5BenchBackgroundPause()
        let token = UUID()
        var automaticDosing = false
        let activate = {
            guard !automaticDosing else { throw BenchError.blocked }
            try pause.begin(token)
        }
        try activate()
        var connection: O5PhysicalBenchConnection? = O5PhysicalBenchConnection(
            sessionID: UUID().uuidString, target: .synthetic, firmware: "9.0.4", bleVersion: "5.0.2",
            activationProvenance: "TEST", validate: { if automaticDosing { throw BenchError.blocked } },
            activate: activate, release: { pause.end(token) }, selectPolicy: { _ in "test" },
            exchange: { _, _ in [] }, reconnect: {})
        XCTAssertTrue(pause.isActive)
        connection?.stop()
        XCTAssertFalse(pause.isActive)
        automaticDosing = true
        XCTAssertThrowsError(try connection?.allowDiagnosticReadback())
        XCTAssertFalse(pause.isActive)
        automaticDosing = false
        try connection?.allowDiagnosticReadback()
        XCTAssertTrue(pause.isActive)
        automaticDosing = true
        XCTAssertThrowsError(try connection?.checkAccess())
        connection = nil
        XCTAssertFalse(pause.isActive)
    }
    func testOldSessionCleanupCannotReleaseAnotherSessionPause() throws {
        let pause = O5BenchBackgroundPause()
        let first = UUID(), second = UUID()
        try pause.begin(first)
        XCTAssertThrowsError(try pause.begin(second))
        pause.end(first)
        try pause.begin(second)
        pause.end(first)
        XCTAssertTrue(pause.isActive)
        pause.end(second)
        XCTAssertFalse(pause.isActive)
    }
    func testStableJournalIdentityDoesNotReservePod() throws {
        let controller = UInt32.random(in: 1...UInt32.max)
        let id = try O5BenchJournal.sessionID(controller: controller, target: .synthetic)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(try O5BenchJournal.sessionID(controller: controller, target: .synthetic), id)
        var target = BenchTarget.synthetic
        target = BenchTarget(lot: target.lot, sequence: target.sequence, bleAssociation: target.bleAssociation,
                             secureContextReference: "different-context")
        XCTAssertNotEqual(try O5BenchJournal.sessionID(controller: controller, target: target), id)
    }

    func testPreviousJournalLocatorSurvivesRemovalOfInterlock() throws {
        let controller = UInt32.random(in: 1...UInt32.max)
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("O5BenchInterlocks")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("\(controller).json")
        defer { try? FileManager.default.removeItem(at: file) }
        struct OldLease: Encodable { let id: String; let target: BenchTarget }
        let id = UUID().uuidString
        try JSONEncoder().encode(OldLease(id: id, target: .synthetic)).write(to: file)
        XCTAssertEqual(try O5BenchJournal.sessionID(controller: controller, target: .synthetic), id)
        try Data("unreadable old journal locator".utf8).write(to: file)
        XCTAssertThrowsError(try O5BenchJournal.sessionID(controller: controller, target: .synthetic))
        XCTAssertFalse(O5BenchBackgroundPause().isActive)
    }

    // Minimal DER fixtures exercise structural extraction, not certificate trust.
    private func der(_ tag: UInt8, _ bytes: [UInt8]) -> [UInt8] {
        precondition(bytes.count < 128); return [tag, UInt8(bytes.count)] + bytes
    }
    private func certificate(_ policies: [String]) -> Data {
        let names = policies.flatMap { der(0x86, Array(("commands:" + $0).utf8)) }
        let ext = der(0x30, der(6, [0x55, 0x1d, 0x11]) + der(4, der(0x30, names)))
        return Data(der(0x30, der(0x30, der(0xa3, der(0x30, ext))) + der(0x30, []) + der(3, [0])))
    }
    func testProvisionedDefaultSelectsModeWithoutGuessing() throws {
        XCTAssertEqual(try O5BenchSigningPolicy(certificate: certificate([""])).mode, .encrypted)
        XCTAssertEqual(try O5BenchSigningPolicy(certificate: certificate(["AA=="])).mode, .encrypted)
        XCTAssertEqual(try O5BenchSigningPolicy(certificate: certificate(["Ag=="])).mode, .secondarySigned)
        XCTAssertThrowsError(try O5BenchSigningPolicy(certificate: certificate(["AQ=="])))
        XCTAssertThrowsError(try O5BenchSigningPolicy(certificate: certificate([])))
        XCTAssertThrowsError(try O5BenchSigningPolicy(certificate: certificate(["AA==", "Ag=="])))
        XCTAssertThrowsError(try O5BenchSigningPolicy(certificate: certificate(["invalid!"])))
        // A per-command exception does not override iOS signing ID 0's default.
        XCTAssertEqual(try O5BenchSigningPolicy.defaultMode([2, 8, 4, 0x65]), .secondarySigned)
        XCTAssertThrowsError(try O5BenchSigningPolicy.defaultMode([2, 8, 4]))
        XCTAssertThrowsError(try O5BenchSigningPolicy.defaultMode([3]))
    }
    func testStatusReadBatchUsesLengthDelimitedBinaryAndRejectsExtraParts() throws {
        let fake = FakeBenchTransport(clock: BenchClock())
        let aid = try XCTUnwrap(fake.exchange([.get("3.12")]).first)
        let legacy = Data([1, 2, 0x2c, 3, 4])
        let envelope = aid + Data(",0.0=".utf8) + Data([0, UInt8(legacy.count)]) + legacy
        let parts = try O5BenchReadBatchCodec.replies(envelope)
        XCTAssertEqual(parts.aid, aid); XCTAssertEqual(parts.legacyMessage, legacy)
        for count in 0..<envelope.count {
            XCTAssertThrowsError(try O5BenchReadBatchCodec.replies(Data(envelope.prefix(count))))
        }
        XCTAssertThrowsError(try O5BenchReadBatchCodec.replies(envelope + Data(",0.0=00".utf8)))
        let message = Data(repeating: 0x2c, count: 11)
        XCTAssertEqual(try O5BenchReadBatchCodec.request(legacyMessage: message),
            Data("G3.12,S0.0=".utf8) + Data([0, 11]) + message + Data(",G0.0".utf8))
        XCTAssertThrowsError(try O5BenchReadBatchCodec.request(legacyMessage: Data()))
    }

    func testEveryCertificateTruncationRejected() throws {
        let data = certificate(["Ag=="])
        for count in 0..<data.count { XCTAssertThrowsError(try O5BenchSigningPolicy(certificate: Data(data.prefix(count)))) }
        XCTAssertThrowsError(try O5BenchSigningPolicy(certificate: data + Data([0])))
    }
}
