//
//  PodCommsSessionTests.swift
//  OmniTests
//
//  From OmniBLE/OmniBLETests/PodCommsSessionTests.swift
//  Created by Pete Schwamb on 3/25/19.
//  Copyright © 2019 Pete Schwamb. All rights reserved.
//

import Foundation

import XCTest
@testable import OmnipodKit

class MockMessageTransport: MessageTransport {
    var delegate: MessageTransportDelegate?

    var messageNumber: Int

    var responseMessageBlocks = [MessageBlock]()
    var sentMessages = [Message]()

    var address: UInt32

    var sentMessageHandler: ((Message) -> Void)?

    init(address: UInt32, messageNumber: Int) {
        self.address = address
        self.messageNumber = messageNumber
    }

    func sendMessage(_ message: Message) throws -> Message {
        sentMessages.append(message)
        if responseMessageBlocks.isEmpty {
            throw PodCommsError.noResponse
        }
        return Message(address: address, messageBlocks: [responseMessageBlocks.removeFirst()], sequenceNum: messageNumber)
    }

    func addResponse(_ messageBlock: MessageBlock) {
        responseMessageBlocks.append(messageBlock)
    }

    func assertOnSessionQueue() {
        // Do nothing in tests
    }
}

class PodCommsSessionTests: XCTestCase, PodCommsSessionDelegate {

    var lastPodStateUpdate: PodState?

    let address: UInt32 = 521580830
    let fakeLtk = Data(hexadecimalString: "fedcba98765432100123456789abcdef")!
    var mockTransport: MockMessageTransport! = nil
    var podState: PodState! = nil

    override func setUp() {
        mockTransport = MockMessageTransport(address: address, messageNumber: 1)
        podState = PodState(address: address, firmwareVersion: "2.7.0", iFirmwareVersion: "2.7.0", lotNo: 43620, lotSeq: 560313, insulinType: .novolog, podType: dashType, ltk: fakeLtk, bleIdentifier: "0000-0000")
    }

    func podCommsSession(_ podCommsSession: PodCommsSession, didChange state: PodState) {
        lastPodStateUpdate = state
    }

    private func insertionSession(marked: Bool, progress: SetupProgress = .cannulaInserting,
                                  responseProgress: PodProgressStatus = .aboveFiftyUnits) -> PodCommsSession {
        podState = PodState(address: address, firmwareVersion: "9.0.4", iFirmwareVersion: "5.0.2",
            lotNo: 1, lotSeq: 2, insulinType: .novolog, podType: omnipod5Type,
            ltk: fakeLtk, bleIdentifier: "test-pod")
        podState.activatedAt = Date()
        podState.setupProgress = progress
        // Invalid ID deliberately rejects before file I/O or any AID send.
        podState.earlyControlEnableID = marked ? "missing-activation-record" : nil
        mockTransport.addResponse(StatusResponse(deliveryStatus: .scheduledBasal,
            podProgressStatus: responseProgress, timeActive: .minutes(10),
            reservoirLevel: Pod.reservoirLevelAboveThresholdMagicNumber,
            insulinDelivered: 3.1, bolusNotDelivered: 0,
            lastProgrammingMessageSeqNum: 1, alerts: AlertSet(slots: [])))
        return PodCommsSession(podState: podState, transport: mockTransport, delegate: self)
    }

    func testUnarmedInsertionCompletionKeepsExistingBehavior() throws {
        try insertionSession(marked: false).checkInsertionCompleted()
        XCTAssertEqual(lastPodStateUpdate?.setupProgress, .completed)
        XCTAssertEqual(mockTransport.sentMessages.count, 1)
    }

    func testUnarmedInsertionRecoveryKeepsExistingBehavior() throws {
        let duration = try insertionSession(marked: false, progress: .startingInsertCannula).insertCannula(silent: false)
        XCTAssertEqual(duration, 0)
        XCTAssertEqual(lastPodStateUpdate?.setupProgress, .completed)
        XCTAssertEqual(mockTransport.sentMessages.count, 1)
    }

    func testMarkedCompletionCannotBypassMissingJournal() {
        let session = insertionSession(marked: true)
        XCTAssertThrowsError(try session.checkInsertionCompleted()) { error in
            XCTAssertFalse(OmniPumpManagerError.communication(error).recoverable)
            XCTAssertFalse(OmniPairingError.pumpManagerError(.communication(error as? LocalizedError)).recoverable)
        }
        XCTAssertNotEqual(lastPodStateUpdate?.setupProgress, .completed)
        XCTAssertEqual(mockTransport.sentMessages.count, 1)
    }

    func testMarkedRecoveryCannotInsertAgainWithMissingJournal() {
        let session = insertionSession(marked: true, progress: .startingInsertCannula)
        XCTAssertThrowsError(try session.insertCannula(silent: false))
        XCTAssertTrue(mockTransport.sentMessages.isEmpty)
    }

    func testMarkedPrimeCannotStartWithMissingJournal() {
        let session = insertionSession(marked: true, progress: .podPaired)
        XCTAssertThrowsError(try session.prime())
        XCTAssertTrue(mockTransport.sentMessages.isEmpty)
    }

    func testMarkedInsertionStillInProgressCannotReportCompletion() {
        let session = insertionSession(marked: true, responseProgress: .insertingCannula)
        XCTAssertThrowsError(try session.checkInsertionCompleted())
        XCTAssertEqual(lastPodStateUpdate?.setupProgress, .cannulaInserting)
        XCTAssertEqual(mockTransport.sentMessages.count, 1)
    }

    func testBolusFinishedEarlyOnPodIsMarkedNonMutable() {
         let mockStart = Date()
         podState.unfinalizedBolus = UnfinalizedDose(bolusAmount: 4.45, startTime: mockStart, scheduledCertainty: .certain, insulinType: .novolog)
         let session = PodCommsSession(podState: podState, transport: mockTransport, delegate: self)

         // Simulate a status request a bit before the bolus is expected to finish
         let statusRequestTime = podState.unfinalizedBolus!.finishTime!.addingTimeInterval(-5)
         session.mockCurrentDate = statusRequestTime

         let statusResponse = StatusResponse(
             deliveryStatus: .scheduledBasal,
             podProgressStatus: .aboveFiftyUnits,
             timeActive: .minutes(10),
             reservoirLevel: Pod.reservoirLevelAboveThresholdMagicNumber,
             insulinDelivered: 25,
             bolusNotDelivered: 0,
             lastProgrammingMessageSeqNum: 5,
             alerts: AlertSet(slots: []))

         mockTransport.addResponse(statusResponse)

         let _ = try! session.getStatus()

         XCTAssertEqual(1, lastPodStateUpdate!.finalizedDoses.count)

         let finalizedBolus = lastPodStateUpdate!.finalizedDoses[0]

         XCTAssertTrue(finalizedBolus.isFinished(at: statusRequestTime))
         XCTAssertFalse(finalizedBolus.isMutable(at: statusRequestTime))
     }

}
