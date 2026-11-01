//
//  PodStateTests.swift
//  OmniTests
//
//  From OmniBLE/OmniBLETests/PodStateTests.swift
//  Created by Pete Schwamb on 10/13/17.
//  Copyright © 2017 Pete Schwamb. All rights reserved.
//

import XCTest
@testable import OmnipodKit

class PodStateTests: XCTestCase {
    
    func testEarlyControlMarkerSurvivesRestartAndOldPodsDefaultOff() throws {
        var state = PodState(address: 1, firmwareVersion: "9.0.4", iFirmwareVersion: "5.0.2",
            lotNo: 1, lotSeq: 2, insulinType: .novolog, podType: omnipod5Type)
        XCTAssertNil(try XCTUnwrap(PodState(rawValue: state.rawValue)).earlyControlEnableID)
        state.earlyControlEnableID = UUID().uuidString
        let restored = try XCTUnwrap(PodState(rawValue: state.rawValue))
        XCTAssertEqual(restored.earlyControlEnableID, state.earlyControlEnableID)
        XCTAssertEqual(restored.earlyControlTarget, state.earlyControlTarget)
    }

    func testNextPodSelectionPersistsAndOldManagerStateDefaultsOff() throws {
        var state = OmniPumpManagerState(isOnboarded: true, podState: nil, timeZone: .current,
            basalSchedule: BasalSchedule(entries: [BasalScheduleEntry(rate: 1, startTime: 0, podType: dashType)]),
            maxBasalRateUnitsPerHour: 10, maxBolusUnits: 10, insulinType: .novolog,
            podType: dashType, podKeepAlive: .disabled, controllerId: 1, podId: 2)
        state.earlyControlEnableForNextPod = true
        XCTAssertTrue(try XCTUnwrap(OmniPumpManagerState(rawValue: state.rawValue)).earlyControlEnableForNextPod)
        var older = state.rawValue
        older.removeValue(forKey: "earlyControlEnableForNextPod")
        XCTAssertFalse(try XCTUnwrap(OmniPumpManagerState(rawValue: older)).earlyControlEnableForNextPod)
    }

    func testErrorResponse() {
        do {
            let errorResponse = try ErrorResponse(encodedData: Data(hexadecimalString: "0603070008019a")!)

            switch errorResponse.errorResponseType {
            case .nonretryableError(let errorCode, let faultEventCode, let podProgress):
                XCTAssertEqual(7, errorCode)
                XCTAssertEqual(.noFaults, faultEventCode.faultType)
                XCTAssertEqual(.aboveFiftyUnits, podProgress)
                break
            default:
                XCTFail("Unexpected bad nonce response")
                break
            }
        } catch (let error) {
            XCTFail("message decoding threw error: \(error)")
        }
    }
}

