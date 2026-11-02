// Test-only session replay. No production code changes, Bluetooth, or real Pod.
import Foundation
import XCTest
import O5BenchCore
@testable import OmnipodKit

private final class ActivationReplayRadio: MessageTransport {
    weak var delegate: MessageTransportDelegate?
    let queue = DispatchQueue(label: "O5.activation.replay")
    let address: UInt32 = 0x16200001
    var messageNumber = 0
    var progress: PodProgressStatus = .pairingCompleted
    var control: UInt8 = 255
    var fault: UInt8 = 0
    var delivered = 0.0
    var messages: [Message] = []
    var aidRequests: [Data] = []
    var primeWrites = 0
    var basalWrites = 0
    var insertionWrites = 0
    var enableWrites = 0
    var loseInsertionReply = false
    var enableFailure: String?
    var beforeEnable: (() throws -> Void)?

    func assertOnSessionQueue() { dispatchPrecondition(condition: .onQueue(queue)) }
    func sendMessage(_ message: Message) throws -> Message {
        assertOnSessionQueue()
        messages.append(message)
        messageNumber = (messageNumber + 2) & 15
        let reply: MessageBlock
        if let get = message.messageBlocks.first as? GetStatusCommand, get.podInfoType == .detailedStatus {
            var body = Data(repeating: 0, count: 22)
            body[0] = 2; body[1] = progress.rawValue; body[2] = fault == 0 ? 1 : 0
            let pulses = UInt16(delivered * Pod.pulsesPerUnit)
            body[6] = UInt8(pulses >> 8); body[7] = UInt8(pulses & 255)
            body[8] = fault; body[11] = 3; body[12] = 255; body[14] = 10
            reply = try PodInfoResponse(encodedData: Data([2, 22]) + body)
        } else {
            if message.messageBlocks.contains(where: { $0 is BasalScheduleExtraCommand }) {
                basalWrites += 1; progress = .basalInitialized
            }
            if let bolus = message.messageBlocks.compactMap({ $0 as? BolusExtraCommand }).first {
                if bolus.units == Pod.primeUnits {
                    primeWrites += 1; progress = .priming
                } else {
                    XCTAssertEqual(bolus.units, Pod.cannulaInsertionUnits + Pod.cannulaInsertionUnitsExtra)
                    insertionWrites += 1; progress = .insertingCannula
                    if loseInsertionReply {
                        finishInsertion()
                        loseInsertionReply = false
                        throw URLError(.timedOut)
                    }
                }
            }
            let remaining = progress == .priming ? Pod.primeUnits : (progress == .insertingCannula ? 0.5 : 0)
            reply = StatusResponse(deliveryStatus: .scheduledBasal, podProgressStatus: progress,
                timeActive: .minutes(10), reservoirLevel: Pod.reservoirLevelAboveThresholdMagicNumber,
                insulinDelivered: delivered, bolusNotDelivered: remaining,
                lastProgrammingMessageSeqNum: UInt8(message.sequenceNum), alerts: .none)
        }
        return Message(address: address, messageBlocks: [reply], sequenceNum: message.sequenceNum)
    }
    func finishPrime() { progress = .primingCompleted; delivered = Pod.primeUnits }
    func finishInsertion() { progress = .aboveFiftyUnits; delivered = Pod.primeUnits + 0.5 }
    func aid(_ command: (data: Data, responsePrefix: String)) throws -> Data {
        assertOnSessionQueue()
        aidRequests.append(command.data)
        switch String(decoding: command.data, as: UTF8.self) {
        case "G3.12":
            XCTAssertEqual(command.responsePrefix, "3.12=")
            var body = Data(repeating: 0, count: 24)
            body[1] = 22; body[9] = 14; body[10] = 1; body[20] = 3
            return body
        case "G4.2":
            XCTAssertEqual(command.responsePrefix, "4.2=")
            return Data([0, 9, 0, 0, 0, 0, 0x13, 1, 0, 4, control])
        default:
            XCTAssertEqual(command.data, Data("SE4.2=".utf8) + Data([0, 2, 4, 0]))
            XCTAssertEqual(command.responsePrefix, "ES4.2=")
            try beforeEnable?()
            enableWrites += 1
            if enableFailure == "before" { throw URLError(.networkConnectionLost) }
            control = 0
            if enableFailure == "after" { throw URLError(.timedOut) }
            return Data("0".utf8)
        }
    }
}

/// Overrides only the radio boundary. Every activation method and the actual
/// early-enable call site, detailed-status parsing and persistence run unchanged.
private final class ActivationReplaySession: PodCommsSession {
    let radio: ActivationReplayRadio
    init(state: PodState, radio: ActivationReplayRadio, delegate: PodCommsSessionDelegate) {
        self.radio = radio
        super.init(podState: state, transport: radio, delegate: delegate)
    }
    override func sendO5AidCommand(_ command: (data: Data, responsePrefix: String)) throws -> Data {
        try radio.aid(command)
    }
}

final class EarlyControlActivationReplayTests: XCTestCase, PodCommsSessionDelegate {
    private var snapshot: PodState!
    private var session: ActivationReplaySession!
    private var radio: ActivationReplayRadio!
    private var journals: [String] = []
    private var beforeCompleted: PodState.RawValue?
    private var captureCompletion = false
    private let schedule = BasalSchedule(entries: [BasalScheduleEntry(rate: 1, startTime: 0, podType: omnipod5Type)])

    func podCommsSession(_ session: PodCommsSession, didChange state: PodState) {
        if captureCompletion && state.setupProgress == .completed && snapshot.setupProgress != .completed {
            beforeCompleted = snapshot.rawValue
        }
        snapshot = state
    }
    private func directory(_ id: String) throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("O5EarlyControlEnable").appendingPathComponent(id)
    }
    private func file(_ id: String) throws -> URL { try directory(id).appendingPathComponent("activation.json") }
    override func tearDownWithError() throws {
        for id in journals { try? FileManager.default.removeItem(at: directory(id)) }
    }
    private func start(armed: Bool = true, sequence: UInt32 = 1) throws {
        radio = ActivationReplayRadio()
        var state = PodState(address: radio.address, firmwareVersion: "9.0.4", iFirmwareVersion: "5.0.2",
            lotNo: 1, lotSeq: sequence, insulinType: .novolog, podType: omnipod5Type,
            ltk: Data(repeating: 0, count: 16), bleIdentifier: UUID().uuidString,
            signingKey: Data(repeating: 0, count: 32))
        state.setupProgress = .podPaired; state.activatedAt = Date().addingTimeInterval(-600)
        if armed {
            let id = UUID().uuidString; state.earlyControlEnableID = id; journals.append(id)
            try O5EarlyControlEnable.arm(id: id, target: state.earlyControlTarget,
                firmware: state.firmwareVersion, bleFirmware: state.iFirmwareVersion)
        }
        snapshot = state
        session = ActivationReplaySession(state: state, radio: radio, delegate: self)
    }
    private func prepareInsertion() throws {
        try radio.queue.sync {
            _ = try session.prime()
            radio.finishPrime()
            session.mockCurrentDate = Date().addingTimeInterval(180)
            try session.programInitialBasalSchedule(schedule, scheduleOffset: 0)
            XCTAssertEqual(snapshot.setupProgress, .initialBasalScheduleSet)
        }
    }
    private func beginInsertion() throws {
        try radio.queue.sync { _ = try session.insertCannula(silent: false) }
    }
    private func complete() throws {
        try radio.queue.sync { radio.finishInsertion(); try session.checkInsertionCompleted() }
    }
    private func restart(_ raw: PodState.RawValue? = nil) throws {
        let state = try XCTUnwrap(PodState(rawValue: raw ?? snapshot.rawValue))
        snapshot = state
        session = ActivationReplaySession(state: state, radio: radio, delegate: self)
    }
    private func counts() -> [Int] { [radio.primeWrites, radio.basalWrites, radio.insertionWrites, radio.enableWrites] }
    private func journal() throws -> [String: Any] {
        let id = try XCTUnwrap(snapshot.earlyControlEnableID)
        return try JSONSerialization.jsonObject(with: Data(contentsOf: file(id))) as! [String: Any]
    }
    private func assertOneControlOnlyEnable(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(counts(), [1, 1, 1, 1], file: file, line: line)
        XCTAssertEqual(radio.aidRequests.filter { $0.first == 83 },
            [Data("SE4.2=".utf8) + Data([0, 2, 4, 0])], file: file, line: line)
        XCTAssertEqual(snapshot.setupProgress, .completed, file: file, line: line)
    }

    func testSuccessfulPrimeBasalInsertionAndEnableOnSerializedSession() throws {
        try start(); try prepareInsertion(); try beginInsertion(); try complete()
        assertOneControlOnlyEnable()
        XCTAssertEqual(try journal()["phase"] as? String, "verified")
        let blockTypes = radio.messages.flatMap { $0.messageBlocks.map { $0.blockType } }
        XCTAssertFalse(blockTypes.contains(.cancelDelivery))
    }
    func testUnarmedActivationHasNoExperimentalTraffic() throws {
        try start(armed: false); try prepareInsertion(); try beginInsertion(); try complete()
        XCTAssertEqual(counts(), [1, 1, 1, 0]); XCTAssertTrue(radio.aidRequests.isEmpty)
        XCTAssertEqual(snapshot.setupProgress, .completed)
    }
    func testInterruptedInsertionRestartsWithStatusAndNoSecondInsertion() throws {
        try start(); try prepareInsertion()
        radio.loseInsertionReply = true
        XCTAssertThrowsError(try beginInsertion())
        XCTAssertEqual(snapshot.setupProgress, .startingInsertCannula)
        try restart()
        try radio.queue.sync { XCTAssertEqual(try session.insertCannula(silent: false), 0) }
        assertOneControlOnlyEnable()
    }
    func testRestartWhileInsertingWaitsForCompletionBeforeEnable() throws {
        try start(); try prepareInsertion(); try beginInsertion(); try restart()
        XCTAssertThrowsError(try radio.queue.sync { try session.checkInsertionCompleted() })
        XCTAssertEqual(radio.enableWrites, 0)
        try complete(); assertOneControlOnlyEnable()
    }
    func testAlreadyEnabledCompletesWithoutAnEnableWrite() throws {
        try start(); radio.control = 0
        try prepareInsertion(); try beginInsertion(); try complete()
        XCTAssertEqual(counts(), [1, 1, 1, 0]); XCTAssertEqual(snapshot.setupProgress, .completed)
        XCTAssertEqual(try journal()["phase"] as? String, "verified")
    }
    func testDisconnectBeforeEnableReplyCannotBeRetriedAfterRestart() throws {
        try checkDisconnect("before", expectedControl: 255)
    }
    func testAppliedEnableWithLostReplyCannotBeRetriedAfterRestart() throws {
        try checkDisconnect("after", expectedControl: 0)
    }
    private func checkDisconnect(_ point: String, expectedControl: UInt8) throws {
        try start(); try prepareInsertion(); try beginInsertion()
        radio.enableFailure = point
        XCTAssertThrowsError(try complete())
        XCTAssertEqual(radio.control, expectedControl)
        XCTAssertEqual(try journal()["phase"] as? String, "stopped")
        let before = counts(); try restart(); radio.enableFailure = nil
        XCTAssertThrowsError(try radio.queue.sync { _ = try session.insertCannula(silent: false) })
        XCTAssertThrowsError(try radio.queue.sync { try session.checkInsertionCompleted() })
        XCTAssertEqual(counts(), before)
        XCTAssertNotEqual(snapshot.setupProgress, .completed)
    }
    func testCrashImageWithDurableWritePendingCannotSendAgain() throws {
        try start(); try prepareInsertion(); try beginInsertion()
        let id = try XCTUnwrap(snapshot.earlyControlEnableID)
        var crashImage: Data?
        radio.beforeEnable = {
            crashImage = try Data(contentsOf: self.file(id))
            XCTAssertEqual(try self.journal()["phase"] as? String, "writePending")
        }
        radio.enableFailure = "after"
        XCTAssertThrowsError(try complete())
        // Restore the exact disk image captured before the simulated send,
        // representing process death before the normal error handler could run.
        try XCTUnwrap(crashImage).write(to: file(id), options: .atomic)
        try restart(); radio.enableFailure = nil; radio.beforeEnable = nil
        XCTAssertThrowsError(try radio.queue.sync { try session.checkInsertionCompleted() })
        XCTAssertEqual(counts(), [1, 1, 1, 1])
        XCTAssertEqual(try journal()["phase"] as? String, "writePending")
    }
    func testVerifiedJournalWithStaleCompletionStateRecoversWithReadsOnly() throws {
        try start(); try prepareInsertion(); try beginInsertion()
        captureCompletion = true; try complete()
        let stale = try XCTUnwrap(beforeCompleted)
        try restart(stale)
        try radio.queue.sync { XCTAssertEqual(try session.insertCannula(silent: false), 0) }
        assertOneControlOnlyEnable()
        XCTAssertEqual(try journal()["phase"] as? String, "verified")
    }
    func testVerifiedJournalRejectsRolledBackPhysicalSetup() throws {
        try start(); try prepareInsertion(); try beginInsertion(); try complete()
        var stale = snapshot.rawValue; stale["setupProgress"] = SetupProgress.podPaired.rawValue
        try restart(stale)
        let before = counts()
        XCTAssertThrowsError(try radio.queue.sync { _ = try session.prime() })
        XCTAssertThrowsError(try radio.queue.sync { try session.programInitialBasalSchedule(schedule, scheduleOffset: 0) })
        XCTAssertThrowsError(try radio.queue.sync { _ = try session.insertCannula(silent: false) })
        XCTAssertEqual(counts(), before)
    }
    func testReplacementDefaultsOffAndCannotBorrowPreviousJournal() throws {
        try start(); try prepareInsertion(); try beginInsertion(); try complete()
        let oldID = try XCTUnwrap(snapshot.earlyControlEnableID)
        try start(armed: false, sequence: 2)
        XCTAssertNil(snapshot.earlyControlEnableID)
        try prepareInsertion(); try beginInsertion(); try complete()
        XCTAssertEqual(counts(), [1, 1, 1, 0]); XCTAssertTrue(radio.aidRequests.isEmpty)
        var borrowed = snapshot.rawValue
        borrowed["setupProgress"] = SetupProgress.podPaired.rawValue; borrowed["earlyControlEnableID"] = oldID
        try restart(borrowed)
        let before = counts()
        XCTAssertThrowsError(try radio.queue.sync { _ = try session.prime() })
        XCTAssertEqual(counts(), before)
    }
    func testDelayedFaultIsObservedWithoutRepeatingEnableOrChangingVerifiedHistory() throws {
        try start(); try prepareInsertion(); try beginInsertion(); try complete()
        radio.fault = 226; radio.progress = .faultEventOccurred
        try radio.queue.sync { XCTAssertTrue(try session.getDetailedStatus().isFaulted) }
        XCTAssertTrue(snapshot.isFaulted); XCTAssertFalse(snapshot.isActive)
        XCTAssertEqual(counts(), [1, 1, 1, 1])
        XCTAssertEqual(try journal()["phase"] as? String, "verified")
    }
}
