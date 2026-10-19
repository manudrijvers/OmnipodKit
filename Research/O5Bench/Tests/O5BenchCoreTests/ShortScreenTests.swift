import XCTest
@testable import O5BenchCore

private final class ScreenStore: BenchStore {
    var saved: BenchSession?
    var fail = false
    func load() throws -> BenchSession? { saved }
    func save(_ session: BenchSession) throws { if fail { throw BenchError.logging }; saved = session }
    func export(_ session: BenchSession, to directory: URL, redacted: Bool) throws {
        if fail { throw BenchError.logging }
        try BenchExport.write(session, to: directory, redacted: redacted)
    }
}

final class ShortScreenTests: XCTestCase {
    private var paths: [URL] = []
    private let identity = try! BenchIdentity(code: "0123", serial: "001234567890")
    private func path() -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths.append(value); return value
    }
    override func tearDown() { paths.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    private func setup(baseline: Bool = true) throws -> (BenchRunner, FakeBenchTransport, ScreenStore) {
        let store = ScreenStore(), fake = FakeBenchTransport(clock: BenchClock())
        fake.suspended = true
        let runner = try BenchRunner(store: store, transport: fake)
        try runner.arm(offBodyConfirmed: true)
        if baseline { try runner.perform(.screenBaseline, baselineExport: path()) }
        return (runner, fake, store)
    }
    private func writes(_ fake: FakeBenchTransport) -> [[BenchRequest]] { fake.sends.filter { $0.contains(where: \.isMutation) } }

    func testOneBatchFixedDeadlineAndNoLongProtocolSuccessFlags() throws {
        let (runner, fake, _) = try setup()
        XCTAssertEqual(fake.clock.elapsed, 120)
        XCTAssertTrue(writes(fake).isEmpty)
        XCTAssertFalse(runner.session.baselineComplete)
        XCTAssertFalse(runner.session.reconnectComplete)
        try runner.perform(.screenG7, identity: identity)
        XCTAssertEqual(writes(fake), [[.enable, .identity(identity)]])
        XCTAssertEqual(fake.reconnectCount, 0)
        XCTAssertEqual(fake.clock.elapsed, 1020)
        XCTAssertTrue(runner.session.configurationConfirmed)
        XCTAssertFalse(runner.session.enableVerified)
        XCTAssertFalse(runner.session.receptionObserved)
        XCTAssertEqual(runner.session.screenResult, "fresh-glucose-observed-in-short-window")
        XCTAssertFalse(runner.session.armed)
        XCTAssertFalse(runner.session.locks.isEmpty)
        let op = try XCTUnwrap(runner.session.operations.first { $0.applicationBatch != nil })
        XCTAssertEqual(op.applicationBatch, try BenchBatchCodec.request([.enable, .identity(identity)]))
        XCTAssertEqual(op.memberResults, ["canonical-success", "canonical-success"])
        try runner.perform(.diagnostic)
        XCTAssertThrowsError(try runner.perform(.screenG7, identity: identity))
        XCTAssertThrowsError(try runner.perform(.provision, identity: identity))
        XCTAssertEqual(writes(fake).count, 1)
    }
    func testOldEnableGuardNotUnlockedByShortBaseline() throws {
        let (runner, fake, _) = try setup()
        XCTAssertThrowsError(try runner.perform(.enable))
        XCTAssertThrowsError(try runner.perform(.provision, identity: identity))
        XCTAssertThrowsError(try runner.perform(.reconnect))
        XCTAssertTrue(writes(fake).isEmpty)
        // The refused protocol mix does not silently run the original baseline.
        XCTAssertFalse(runner.session.baselineComplete)
    }
    func testOldBaselineDoesNotAuthorizeNewScreen() throws {
        let (runner, fake, _) = try setup(baseline: false)
        try runner.perform(.baseline, baselineExport: path())
        try runner.perform(.reconnect)
        XCTAssertThrowsError(try runner.perform(.screenG7, identity: identity))
        XCTAssertTrue(writes(fake).isEmpty)
    }
    func testInvalidStartingStatesAndFaultDominatesReadyBits() throws {
        let changes: [(FakeBenchTransport) -> Void] = [
            { $0.suspended = false }, { $0.control = 0 }, { $0.control = 1 },
            { $0.identity = self.identity }, { $0.manual = false }, { $0.active = false },
            { $0.fault = 0xe2 }, { $0.firmware = "9.0.5" }, { $0.bleVersion = "5.0.3" }
        ]
        for change in changes {
            let (runner, fake, _) = try setup()
            change(fake)
            XCTAssertThrowsError(try runner.perform(.screenG7, identity: identity))
            XCTAssertTrue(writes(fake).isEmpty)
        }
    }
    func testMissingBaselineAndMissingIdentityNeverWrite() throws {
        let (runner, fake, _) = try setup(baseline: false)
        XCTAssertThrowsError(try runner.perform(.screenG7, identity: identity))
        XCTAssertTrue(writes(fake).isEmpty)
        let (other, otherFake, _) = try setup()
        XCTAssertThrowsError(try other.perform(.screenG7))
        XCTAssertTrue(writes(otherFake).isEmpty)
    }
    func testReadbackAndPostSendDelaysDoNotRestartClock() throws {
        let (runner, fake, _) = try setup()
        var delayed = false
        fake.onSend = {
            if !self.writes(fake).isEmpty, !delayed {
                delayed = true; fake.clock.advance(137)
            }
        }
        try runner.perform(.screenG7, identity: identity)
        XCTAssertEqual(fake.clock.elapsed, 1020)
        let event = try XCTUnwrap(runner.session.events.first { $0.kind == "screen-observation-deadline" })
        XCTAssertEqual(event.fields["deadlineMonotonic"], "1020.0")
    }
    func testLateConfigurationCannotClaimCompleteObservation() throws {
        let (runner, fake, _) = try setup()
        var delayed = false
        fake.onSend = {
            if !self.writes(fake).isEmpty, !delayed { delayed = true; fake.clock.advance(901) }
        }
        XCTAssertThrowsError(try runner.perform(.screenG7, identity: identity))
        XCTAssertNil(runner.session.screenResult)
        XCTAssertEqual(writes(fake).count, 1)
    }
    func testBothMemberFailuresAndMalformedBatchStopWithoutRetry() throws {
        for index in [0, 1] {
            let (runner, fake, _) = try setup()
            fake.rejectMember = index
            XCTAssertThrowsError(try runner.perform(.screenG7, identity: identity))
            XCTAssertFalse(runner.session.configurationConfirmed)
            XCTAssertNil(runner.session.screenResult)
            XCTAssertEqual(writes(fake).count, 1)
            XCTAssertThrowsError(try runner.perform(.screenG7, identity: identity))
            XCTAssertEqual(writes(fake).count, 1)
        }
        let (runner, fake, _) = try setup()
        fake.overrideBatchReply = Data("ES4.2=0".utf8)
        XCTAssertThrowsError(try runner.perform(.screenG7, identity: identity))
        XCTAssertFalse(runner.session.configurationConfirmed)
    }
    func testMismatchedIdentityReadbackCannotComplete() throws {
        let (runner, fake, _) = try setup()
        fake.overrideReply = { request, normal in
            if request == .get("4.1"), fake.control == 0 {
                return Data("4.1=".utf8) + keyed([(2, Data("9999".utf8)), (3, Data(self.identity.serial.utf8))])
            }
            return normal
        }
        XCTAssertThrowsError(try runner.perform(.screenG7, identity: identity))
        XCTAssertFalse(runner.session.configurationConfirmed)
        XCTAssertEqual(writes(fake).count, 1)
    }
    func testDelayedE2StopsScreenEvenWithManualAndReadyStatus() throws {
        let (runner, fake, _) = try setup()
        fake.onSend = { if fake.clock.elapsed >= 420 { fake.fault = 0xe2 } }
        XCTAssertThrowsError(try runner.perform(.screenG7, identity: identity))
        XCTAssertEqual(fake.clock.elapsed, 420)
        XCTAssertNil(runner.session.screenResult)
        XCTAssertFalse(runner.session.receptionObserved)
        XCTAssertTrue(runner.session.events.contains { $0.kind == "status" && $0.fields["fault"] == "226" })
        XCTAssertEqual(writes(fake).count, 1)
    }
    func testNoGlucoseEndsAtDeadlineWithoutDeclaringPairingImpossible() throws {
        let (runner, fake, _) = try setup()
        fake.egv = -1
        try runner.perform(.screenG7, identity: identity)
        XCTAssertEqual(fake.clock.elapsed, 1020)
        XCTAssertEqual(runner.session.screenResult, "no-fresh-glucose-observed-in-short-window")
        XCTAssertFalse(runner.session.receptionObserved)
    }
    func testFeedInterruptionStopsObservationAndFutureMutation() throws {
        let (runner, fake, _) = try setup()
        runner.checkpoint = { stage in
            if stage == "observation-sample", fake.clock.elapsed >= 300 {
                try runner.recordFeed(phoneOK: false, watchOK: true)
            }
        }
        XCTAssertThrowsError(try runner.perform(.screenG7, identity: identity))
        XCTAssertNil(runner.session.screenResult)
        XCTAssertEqual(writes(fake).count, 1)
    }
    func testRestartsAtMutationMilestonesNeverReplay() throws {
        for point in ["prepared", "send-start", "transport-complete", "reply-received", "validated", "observation-sample"] {
            let (runner, fake, store) = try setup()
            runner.checkpoint = { stage in
                if stage == point && (runner.session.operations.last?.requests.contains(where: \.isMutation) == true
                    || (stage == "observation-sample" && fake.control == 0)) { throw BenchError.interrupted }
            }
            XCTAssertThrowsError(try runner.perform(.screenG7, identity: identity))
            XCTAssertTrue(store.saved?.screenStarted == true)
            let count = writes(fake).count
            let reopened = try BenchRunner(store: store, transport: fake)
            try reopened.perform(.diagnostic)
            XCTAssertThrowsError(try reopened.perform(.screenG7, identity: identity))
            XCTAssertEqual(writes(fake).count, count)
        }
    }
    func testExportLabelsScreenAndBackwardCompatibleJournalFields() throws {
        let (runner, _, store) = try setup()
        let original = try FileBenchStore.encode(store.saved!)
        var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        for key in ["screenBaselineComplete", "screenStarted", "screenResult"] { object.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(BenchSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.screenBaselineComplete)
        try runner.perform(.screenG7, identity: identity)
        let directory = path(); try runner.export(to: directory)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as! [String: Any]
        XCTAssertEqual(manifest["protocol"] as? String, "short-g7-screen-v1")
        XCTAssertEqual(manifest["physicalWritesEnabled"] as? Bool, false)
        XCTAssertEqual(manifest["screenStarted"] as? Bool, true)
        XCTAssertEqual(manifest["receptionObserved"] as? Bool, false)
    }
}
