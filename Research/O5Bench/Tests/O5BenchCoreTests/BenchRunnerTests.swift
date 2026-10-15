import XCTest
@testable import O5BenchCore

private final class MemoryBenchStore: BenchStore {
    var saved: BenchSession?
    var fail = false
    func load() throws -> BenchSession? { saved }
    func save(_ session: BenchSession) throws {
        if fail { throw BenchError.logging }
        saved = session
    }
    func export(_ session: BenchSession, to directory: URL, redacted: Bool) throws {
        if fail { throw BenchError.logging }
        try BenchExport.write(session, to: directory, redacted: redacted)
    }
}

final class BenchRunnerTests: XCTestCase {
    private var directories: [URL] = []
    private func path() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(url); return url
    }
    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }
    private func setup(ready: Bool = true, enabled: Bool = false) throws -> (BenchRunner, FakeBenchTransport, MemoryBenchStore) {
        let store = MemoryBenchStore(), fake = FakeBenchTransport(clock: BenchClock())
        if enabled { fake.control = 0 }
        let runner = try BenchRunner(store: store, transport: fake)
        if ready {
            try runner.arm(offBodyConfirmed: true)
            try runner.perform(.baseline, baselineExport: path())
            try runner.perform(.reconnect)
        }
        return (runner, fake, store)
    }
    private func writes(_ fake: FakeBenchTransport) -> [[BenchRequest]] { fake.sends.filter { $0.contains(where: \.isMutation) } }
    private var identity: BenchIdentity { try! BenchIdentity(code: "0123", serial: "001234567890") }

    func testCompleteSeparateActionsAndExactMutationScope() throws {
        let (runner, fake, _) = try setup()
        try runner.perform(.targetProfile); try runner.perform(.dia)
        try runner.perform(.enable)
        XCTAssertTrue(runner.session.enableVerified)
        XCTAssertEqual(writes(fake), [[.enable]])
        XCTAssertEqual(BenchRequest.enable.body.hexadecimalString, "5345342e323d00020400")
        try runner.perform(.provision, identity: identity)
        XCTAssertEqual(writes(fake).last, [.enable, .identity(identity)])
        XCTAssertEqual(BenchRequest.identity(identity).body.hexadecimalString,
            "5345342e313d0012023031323303303031323334353637383930")
        XCTAssertTrue(runner.session.configurationConfirmed)
        XCTAssertFalse(runner.session.receptionObserved)
        try runner.perform(.observe)
        XCTAssertTrue(runner.session.receptionObserved)
        let count = writes(fake).count
        try runner.perform(.reconnectReception)
        XCTAssertEqual(writes(fake).count, count)
        XCTAssertEqual(fake.reconnectCount, 2)
        XCTAssertEqual(runner.session.virtualElapsed, 4500)
        XCTAssertTrue(runner.session.events.contains { $0.kind == "target-profile" && $0.fields["valuesMgdl"]?.split(separator: ",").count == 48 })
        XCTAssertTrue(runner.session.events.contains { $0.kind == "dia" && $0.fields["halfHourCount"] == "8" })
    }

    func testNoPhysicalTransportCanBeSelected() throws {
        let (runner, fake, _) = try setup(ready: false)
        XCTAssertThrowsError(try runner.requirePhysicalAccess())
        XCTAssertTrue(fake.sends.isEmpty)
    }

    func testUnconfirmedOffBodyOrUnarmedCannotMutate() throws {
        let (runner, fake, _) = try setup(ready: false)
        XCTAssertThrowsError(try runner.arm(offBodyConfirmed: false))
        try runner.perform(.baseline, baselineExport: path()); try runner.perform(.reconnect)
        XCTAssertThrowsError(try runner.perform(.enable)); XCTAssertTrue(writes(fake).isEmpty)
    }

    func testMissingBaselineOrReconnectCannotMutate() throws {
        let (runner, fake, _) = try setup(ready: false)
        try runner.arm(offBodyConfirmed: true)
        XCTAssertThrowsError(try runner.perform(.enable)); XCTAssertTrue(writes(fake).isEmpty)
        let (other, otherFake, _) = try setup(ready: false)
        try other.arm(offBodyConfirmed: true); try other.perform(.baseline, baselineExport: path())
        XCTAssertThrowsError(try other.perform(.enable)); XCTAssertTrue(writes(otherFake).isEmpty)
    }

    func testAllPrivateTargetComponentsChecked() throws {
        for target in [
            BenchTarget(lot: "OTHER", sequence: "SYNTHETIC-SEQ", bleAssociation: "SYNTHETIC-BLE", secureContextReference: "SYNTHETIC-CONTEXT"),
            BenchTarget(lot: "SYNTHETIC-LOT", sequence: "OTHER", bleAssociation: "SYNTHETIC-BLE", secureContextReference: "SYNTHETIC-CONTEXT"),
            BenchTarget(lot: "SYNTHETIC-LOT", sequence: "SYNTHETIC-SEQ", bleAssociation: "OTHER", secureContextReference: "SYNTHETIC-CONTEXT"),
            BenchTarget(lot: "SYNTHETIC-LOT", sequence: "SYNTHETIC-SEQ", bleAssociation: "SYNTHETIC-BLE", secureContextReference: "OTHER")
        ] {
            let (runner, fake, _) = try setup()
            fake.target = target
            XCTAssertThrowsError(try runner.perform(.enable)); XCTAssertTrue(writes(fake).isEmpty)
        }
    }

    func testTargetAndFreshnessRecheckedAtDispatch() throws {
        for invalidateTarget in [true, false] {
            let (runner, fake, _) = try setup()
            runner.checkpoint = { stage in
                if stage == "send-start", runner.session.operations.last?.requests.contains(where: \.isMutation) == true {
                    if invalidateTarget {
                        fake.target = BenchTarget(lot: "OTHER", sequence: "x", bleAssociation: "x", secureContextReference: "x")
                    } else { fake.clock.advance(91) }
                }
            }
            XCTAssertThrowsError(try runner.perform(.enable)); XCTAssertTrue(writes(fake).isEmpty)
        }
    }

    func testUnexpectedModeFaultFirmwareAndControlStopMutation() throws {
        let changes: [(FakeBenchTransport) -> Void] = [
            { $0.manual = false }, { $0.active = false }, { $0.fault = 0xe2 },
            { $0.firmware = "9.0.5" }, { $0.bleVersion = "5.0.3" }, { $0.control = 1 }, { $0.control = 99 }
        ]
        for change in changes {
            let (runner, fake, _) = try setup()
            change(fake)
            XCTAssertThrowsError(try runner.perform(.enable)); XCTAssertTrue(writes(fake).isEmpty)
        }
    }

    func testMissingUnknownOrMalformedInterfaceNeverReusesSuccessfulState() throws {
        for body in [keyed([]), keyed([(4, Data([99]))]), Data([0, 0]), Data([0, 2, 4])] {
            let (runner, fake, _) = try setup()
            fake.overrideReply = { request, reply in request == .get("4.2") ? Data("4.2=".utf8) + body : reply }
            XCTAssertThrowsError(try runner.perform(.enable)); XCTAssertTrue(writes(fake).isEmpty)
        }
    }

    func testUnknownOrAbsentDesiredAndAllowedTypesCannotAuthorizeMutation() throws {
        let cases: [[(UInt8, Data)]] = [
            [(4, Data([255]))],
            [(1, Data([99])), (2, Data([1])), (3, Data([1])), (4, Data([255]))],
            [(1, Data([0])), (2, Data([99])), (3, Data([1])), (4, Data([255]))]
        ]
        for fields in cases {
            let (runner, fake, _) = try setup()
            fake.overrideReply = { request, normal in request == .get("4.2") ? Data("4.2=".utf8) + keyed(fields) : normal }
            XCTAssertThrowsError(try runner.perform(.enable)); XCTAssertTrue(writes(fake).isEmpty)
        }
    }

    func testIdentityBytesAndCaseInsensitiveValidatedComparison() throws {
        XCTAssertThrowsError(try BenchIdentity(code: "１２３４", serial: "001234567890"))
        XCTAssertThrowsError(try BenchIdentity(code: "123", serial: "001234567890"))
        XCTAssertThrowsError(try BenchIdentity(code: "0123", serial: "001234567890x"))
        let expected = try BenchIdentity(code: "Ab01", serial: "Ab0012345678")
        let info = try O5G7SensorInfo(keyed([(2, Data("aB01".utf8)), (3, Data("aB0012345678".utf8))]))
        XCTAssertTrue(expected.matches(info))
        XCTAssertFalse(expected.matches(try O5G7SensorInfo(keyed([(2, Data("aB01".utf8))]))))
        XCTAssertFalse(expected.matches(try O5G7SensorInfo(Data([0, 0]))))
    }

    func testMatchingIdentitySkipsProvisionAndDoesNotClaimExercise() throws {
        let (runner, fake, _) = try setup(enabled: true)
        fake.identity = identity
        try runner.perform(.provision, identity: identity)
        XCTAssertTrue(writes(fake).isEmpty)
        XCTAssertTrue(runner.session.configurationConfirmed)
        XCTAssertTrue(runner.session.events.contains { $0.kind == "provision-not-exercised" })
    }

    func testDifferentIncompleteAndMalformedIdentityBlockProvision() throws {
        for body in [
            keyed([(2, Data("9999".utf8)), (3, Data("001234567890".utf8))]),
            keyed([(2, Data("0123".utf8))]), keyed([]), Data(), Data([0, 1, 3])
        ] {
            let (runner, fake, _) = try setup(enabled: true)
            fake.overrideReply = { request, reply in request == .get("4.1") ? Data("4.1=".utf8) + body : reply }
            XCTAssertThrowsError(try runner.perform(.provision, identity: identity)); XCTAssertTrue(writes(fake).isEmpty)
        }
    }

    func testEnableObservationRequiredAndReadbackMismatchStopsChain() throws {
        let (runner, fake, _) = try setup()
        fake.overrideReply = { request, reply in
            if request == .get("4.2"), fake.control == 0 { return Data("4.2=".utf8) + keyed([(4, Data([255]))]) }
            return reply
        }
        XCTAssertThrowsError(try runner.perform(.enable))
        XCTAssertFalse(runner.session.enableVerified)
        XCTAssertThrowsError(try runner.perform(.provision, identity: identity))
        XCTAssertEqual(writes(fake).count, 1)
    }

    func testBothBatchResultsValidatedIncludingFailedSecondMember() throws {
        let (runner, fake, _) = try setup(enabled: true)
        fake.rejectMember = 1
        XCTAssertThrowsError(try runner.perform(.provision, identity: identity))
        let op = try XCTUnwrap(runner.session.operations.first { $0.group == "recovered-active-pod-g7-batch" })
        XCTAssertEqual(op.memberResults, ["canonical-success", "rejected-or-malformed"])
        XCTAssertFalse(runner.session.configurationConfirmed)
        XCTAssertThrowsError(try runner.perform(.observe))
        XCTAssertEqual(writes(fake).count, 1)
    }

    func testEmptyMissingNoncanonicalAndWrongPrefixSETResultsFail() throws {
        for reply in [Data(), Data("ES4.2=".utf8), Data("ES4.2=00".utf8), Data("ES4.2=0junk".utf8), Data("4.2=0".utf8)] {
            let (runner, fake, _) = try setup()
            fake.overrideReply = { request, normal in request.isMutation ? reply : normal }
            XCTAssertThrowsError(try runner.perform(.enable)); XCTAssertFalse(runner.session.enableVerified)
        }
    }

    func testTimeoutAfterMutationNeverReplaysAndDiagnosticRemainsAvailable() throws {
        let (runner, fake, store) = try setup()
        fake.onSend = { if self.writes(fake).count > 0 { fake.failAfterSend = true } }
        XCTAssertThrowsError(try runner.perform(.enable))
        XCTAssertEqual(writes(fake).count, 1)
        let pending = try XCTUnwrap(store.saved?.operations.last)
        XCTAssertEqual(pending.outcome, "pending"); XCTAssertNotNil(pending.sendStarted)
        fake.onSend = nil; fake.failAfterSend = false
        let resumed = try BenchRunner(store: store, transport: fake)
        try resumed.perform(.diagnostic); try resumed.perform(.reconnect)
        XCTAssertEqual(writes(fake).count, 1)
        XCTAssertThrowsError(try resumed.perform(.enable)); XCTAssertEqual(writes(fake).count, 1)
        XCTAssertTrue(resumed.session.operations.contains { $0.id == pending.id && $0.outcome == "pending" })
    }

    func testRestartsAtEverySendMilestonePreserveEvidenceAndNeverAdvance() throws {
        for milestone in ["prepared", "send-start", "transport-complete", "reply-received", "validated", "observation-sample"] {
            let (runner, fake, store) = try setup()
            runner.checkpoint = { stage in
                if stage == milestone,
                   (runner.session.operations.last?.requests.contains(where: \.isMutation) == true ||
                    (stage == "observation-sample" && fake.control == 0)) { throw BenchError.interrupted }
            }
            XCTAssertThrowsError(try runner.perform(.enable))
            let originalIDs = Set(try XCTUnwrap(store.saved).operations.map(\.id))
            let count = writes(fake).count
            let resumed = try BenchRunner(store: store, transport: fake)
            XCTAssertFalse(resumed.session.enableVerified)
            try resumed.perform(.diagnostic)
            XCTAssertTrue(originalIDs.isSubset(of: Set(resumed.session.operations.map(\.id))))
            XCTAssertThrowsError(try resumed.perform(.enable)); XCTAssertEqual(writes(fake).count, count)
        }
    }

    func testPersistenceFailureBeforeAndAfterSendBlocksFurtherMutations() throws {
        for afterSend in [false, true] {
            let (runner, fake, store) = try setup()
            if afterSend {
                fake.onSend = { if !self.writes(fake).isEmpty { store.fail = true } }
            } else {
                runner.checkpoint = { stage in
                    if stage == "prepared", runner.session.operations.last?.requests.contains(where: \.isMutation) == true { store.fail = true }
                }
            }
            XCTAssertThrowsError(try runner.perform(.enable))
            XCTAssertEqual(writes(fake).count, afterSend ? 1 : 0)
            store.fail = false; fake.onSend = nil; runner.checkpoint = nil
            XCTAssertThrowsError(try runner.perform(.enable))
            XCTAssertEqual(writes(fake).count, afterSend ? 1 : 0)
            try runner.export(to: path())
        }
    }

    func testConcurrentReentrantActionDoesNotDispatch() throws {
        let (runner, fake, _) = try setup()
        fake.onSend = { XCTAssertThrowsError(try runner.perform(.enable)) }
        try runner.perform(.enable)
        XCTAssertEqual(writes(fake).count, 1)
    }

    func testFeedInterruptionAndAudibleAlarmAreIndependentLocks() throws {
        for alarm in [true, false] {
            let (runner, fake, _) = try setup()
            if alarm { try runner.markAlarm(note: "heard independently") }
            else { try runner.recordFeed(phoneOK: true, watchOK: false) }
            XCTAssertThrowsError(try runner.perform(.enable)); XCTAssertTrue(writes(fake).isEmpty)
            try runner.export(to: path())
        }
    }

    func testNegativeGlucoseAndRepeatedSensorTimestampsDoNotShowSustainedReception() throws {
        for negative in [true, false] {
            let (runner, fake, _) = try setup(enabled: true)
            fake.identity = identity
            try runner.perform(.provision, identity: identity)
            if negative { fake.egv = -1 } else { fake.freezeSample = true }
            try runner.perform(.observe)
            XCTAssertFalse(runner.session.receptionObserved)
            XCTAssertTrue(writes(fake).isEmpty)
        }
    }

    func testRedactedExportRemovesIdentityTargetsRawBytesAndOperatorNotes() throws {
        let (runner, _, _) = try setup(enabled: true)
        try runner.perform(.provision, identity: identity)
        try runner.recordFeed(phoneOK: true, watchOK: true, note: "PRIVATE-SENSOR-NOTE")
        let directory = path(); try runner.export(to: directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let all = try files.map { try String(contentsOf: $0) }.joined()
        for secret in ["SYNTHETIC-LOT", "SYNTHETIC-SEQ", "SYNTHETIC-BLE", "SYNTHETIC-CONTEXT", identity.serial, "PRIVATE-SENSOR-NOTE", BenchRequest.identity(identity).body.hexadecimalString] {
            XCTAssertFalse(all.contains(secret), secret)
        }
        XCTAssertTrue(all.contains("REDACTED"))
        XCTAssertThrowsError(try runner.export(to: directory)) // Cannot mix private and sharing files.
        let sums = try String(contentsOf: directory.appendingPathComponent("SHA256SUMS"))
        for line in sums.split(separator: "\n") {
            let fields = line.split(separator: " ")
            let data = try Data(contentsOf: directory.appendingPathComponent(String(fields[1])))
            XCTAssertEqual(SHA256.hex(data), String(fields[0]))
        }
    }

    func testBatchFramingRejectsMissingExtraAndWrongOrderedMembers() throws {
        for envelope in ["ES4.2=0", "ES4.2=0,ES4.1=0,ES4.1=0", "ES4.1=0,ES4.2=0", "ES4.2=0,ES4.1=", "ES4.2=0,ES4.1=00"] {
            let (runner, fake, _) = try setup(enabled: true)
            fake.overrideBatchReply = Data(envelope.utf8)
            XCTAssertThrowsError(try runner.perform(.provision, identity: identity))
            XCTAssertFalse(runner.session.configurationConfirmed)
            let op = try XCTUnwrap(runner.session.operations.first { $0.applicationBatch != nil })
            XCTAssertEqual(op.replies, [Data(envelope.utf8)])
            XCTAssertEqual(op.applicationBatch, BenchRequest.enable.body + Data([44]) + BenchRequest.identity(identity).body)
        }
    }

    func testReceptionStoppingAfterTwoSamplesIsNotSustained() throws {
        let (runner, fake, _) = try setup(enabled: true)
        fake.identity = identity
        try runner.perform(.provision, identity: identity)
        let start = fake.clock.elapsed
        fake.onSend = { if fake.clock.elapsed - start > 600 { fake.egv = -1 } }
        try runner.perform(.observe)
        XCTAssertFalse(runner.session.receptionObserved)
    }

    func testLateSamplesDoNotClaimReceptionThroughoutTheWindow() throws {
        let (runner, fake, _) = try setup(enabled: true)
        fake.identity = identity
        try runner.perform(.provision, identity: identity)
        let start = fake.clock.elapsed
        fake.onSend = { fake.egv = fake.clock.elapsed - start < 1200 ? -1 : 123 }
        try runner.perform(.observe)
        XCTAssertFalse(runner.session.receptionObserved)
    }

    func testInterruptedFileSnapshotSurvivesReloadWithoutMutationReplay() throws {
        let directory = path()
        var store: FileBenchStore? = try FileBenchStore(directory: directory)
        let fake = FakeBenchTransport(clock: BenchClock())
        var runner: BenchRunner? = try BenchRunner(store: store!, transport: fake)
        try runner!.arm(offBodyConfirmed: true)
        try runner!.perform(.baseline, baselineExport: path())
        try runner!.perform(.reconnect)
        runner!.checkpoint = { stage in
            if stage == "reply-received", fake.control == 0 { throw BenchError.interrupted }
        }
        XCTAssertThrowsError(try runner!.perform(.enable))
        let id = runner!.session.operations.last!.id
        runner = nil; store = nil
        let reopened = try FileBenchStore(directory: directory)
        let saved = try XCTUnwrap(reopened.load())
        let newFake = FakeBenchTransport(clock: BenchClock(elapsed: saved.virtualElapsed, id: saved.clockID))
        let resumed = try BenchRunner(store: reopened, transport: newFake)
        XCTAssertEqual(resumed.session.operations.last?.id, id)
        XCTAssertNotNil(resumed.session.operations.last?.replies)
        try resumed.perform(.diagnostic)
        XCTAssertThrowsError(try resumed.perform(.enable))
        XCTAssertTrue(writes(newFake).isEmpty)
    }

    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testFileStoreExclusiveLeasePersistenceAndPermissions() throws {
        let directory = path()
        var store: FileBenchStore? = try FileBenchStore(directory: directory)
        XCTAssertThrowsError(try FileBenchStore(directory: directory))
        var runner: BenchRunner? = try BenchRunner(store: store!, transport: FakeBenchTransport(clock: BenchClock()))
        try runner?.arm(offBodyConfirmed: true)
        let id = runner?.session.id
        runner = nil; store = nil
        let reopened = try FileBenchStore(directory: directory)
        XCTAssertEqual(try reopened.load()?.id, id)
        XCTAssertEqual(try reopened.load()?.armed, true)
        let attr = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("session.json").path)
        XCTAssertEqual((attr[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
