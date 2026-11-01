//
//  InsertCannulaViewModel.swift
//  OmnipodKit
//
//  Based on OmniBLE/PumpManagerUI/ViewModels/InsertCannulaViewModel.swift
//  Created by Pete Schwamb on 3/10/20.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import LoopKit
import O5BenchCore
import LoopKitUI


protocol CannulaInserter {
    func insertCannula(completion: @escaping (Result<TimeInterval,OmniPumpManagerError>) -> ())
    func checkCannulaInsertionFinished(completion: @escaping (OmniPumpManagerError?) -> Void)
    var cannulaInsertionSuccessfullyStarted: Bool { get }
}

extension OmniPumpManager: CannulaInserter {
    var cannulaInsertionSuccessfullyStarted: Bool {
        return state.podState?.setupProgress.cannulaInsertionSuccessfullyStarted == true
    }
}

class InsertCannulaViewModel: ObservableObject, Identifiable {

    enum InsertCannulaViewModelState {
        case ready
        case startingInsertion
        case inserting(finishTime: CFTimeInterval)
        case checkingInsertion
        case error(OmniPumpManagerError)
        case finished
        
        var actionButtonAccessibilityLabel: String {
            switch self {
            case .ready:
                return LocalizedString("Slide Button to insert Cannula", comment: "Insert cannula slider button accessibility label while ready to pair")
            case .inserting, .startingInsertion:
                return LocalizedString("Inserting. Please wait.", comment: "Insert cannula action button accessibility label while pairing")
            case .checkingInsertion:
                return LocalizedString("Checking Insertion", comment: "Insert cannula action button accessibility label checking insertion")
            case .error(let error):
                return String(format: "%@ %@", error.errorDescription ?? "", error.recoverySuggestion ?? "")
            case .finished:
                return LocalizedString("Cannula inserted successfully. Continue.", comment: "Insert cannula action button accessibility label when cannula insertion succeeded")
            }
        }

        var instructionsDisabled: Bool {
            switch self {
            case .ready, .error:
                return false
            default:
                return true
            }
        }
        
        var nextActionButtonDescription: String {
            switch self {
            case .ready:
                return LocalizedString("Slide to Insert Cannula", comment: "Cannula insertion button text while ready to insert")
            case .error:
                return LocalizedString("Retry", comment: "Cannula insertion button text while showing error")
            case .inserting, .startingInsertion:
                return LocalizedString("Inserting...", comment: "Cannula insertion button text while inserting")
            case .checkingInsertion:
                return LocalizedString("Checking...", comment: "Cannula insertion button text while checking insertion")
            case .finished:
                return LocalizedString("Continue", comment: "Cannula insertion button text when inserted")
            }
        }
        
        var nextActionButtonStyle: ActionButton.ButtonType {
            switch self {
            case .error(let error):
                if !error.recoverable {
                    return .destructive
                }
            default:
                break
            }
            return .primary
        }
        
        var progressState: ProgressIndicatorState {
            switch self {
            case .ready, .error:
                return .hidden
            case .startingInsertion, .checkingInsertion:
                return .indeterminantProgress
            case .inserting(let finishTime):
                return .timedProgress(finishTime: finishTime)
            case .finished:
                return .completed
            }
        }
        
        var showProgressDetail: Bool {
            switch self {
            case .ready:
                return false
            default:
                return true
            }
        }
        
        var isProcessing: Bool {
            switch self {
            case .startingInsertion, .inserting:
                return true
            default:
                return false
            }
        }
        
        var isFinished: Bool {
            if case .finished = self {
                return true
            }
            return false
        }
    }
    
    var error: OmniPumpManagerError? {
        if case .error(let error) = self.state {
            return error
        }
        return nil
    }

    @Published var state: InsertCannulaViewModelState = .ready

    var stateNeedsDeliberateUserAcceptance : Bool {
        switch state {
        case .ready:
            true
        default:
            false
        }
    }
    
    var didFinish: (() -> Void)?
    
    var didRequestDeactivation: (() -> Void)?
    
    var cannulaInserter: CannulaInserter

    var autoRetryAttempted: Bool

    init(cannulaInserter: CannulaInserter) {
        self.cannulaInserter = cannulaInserter
        self.autoRetryAttempted = false

        // If resuming, don't wait for the button action
        if cannulaInserter.cannulaInsertionSuccessfullyStarted {
            insertCannula()
        }
    }

    private func checkCannulaInsertionFinished() {
        state = .checkingInsertion
        cannulaInserter.checkCannulaInsertionFinished() { (error) in
            DispatchQueue.main.async {
                if let error = error {
                    self.state = .error(error)
                } else {
                    self.state = .finished
                }
            }
        }
    }
    
    private func insertCannula() {
        state = .startingInsertion

        cannulaInserter.insertCannula { (result) in
            DispatchQueue.main.async {
                switch(result) {
                case .success(let finishTime):
                    self.state = .inserting(finishTime: CACurrentMediaTime() + finishTime)
                    let delay = finishTime
                    if delay > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            self.checkCannulaInsertionFinished() // now check if actually ready
                        }
                    } else {
                        self.state = .finished
                    }
                case .failure(let error):
                    if !error.recoverable || self.autoRetryAttempted {
                        self.autoRetryAttempted = false // allow for an auto retry on the next user attempt
                        self.state = .error(error)
                    } else {
                        self.autoRetryAttempted = true
                        let autoRetryPauseTime = TimeInterval(seconds: 3)
                        print("### insertCannula encountered error \(error.localizedDescription), retrying after \(autoRetryPauseTime) seconds")
                        DispatchQueue.global(qos: .utility).async {
                            Thread.sleep(forTimeInterval: autoRetryPauseTime)

                            self.insertCannula()
                        }
                    }
                }
            }
        }
    }

    func continueButtonTapped() {
        switch state {
        case .finished:
            didFinish?()
        case .error(let error):
            if error.recoverable {
                if cannulaInserter.cannulaInsertionSuccessfullyStarted {
                    print("### InsertCannulaViewModel calling checkCannulaInsertionFinished after error \(error.localizedDescription)")
                    checkCannulaInsertionFinished()
                } else {
                    print("### InsertCannulaViewModel calling insertCannula after error \(error.localizedDescription)")
                    insertCannula()
                }
            } else {
                didRequestDeactivation?()
            }
        default:
            insertCannula()
        }
    }
}

extension OmniPumpManagerError {
    var recoverable: Bool {
        if case .communication(let error) = self, error is O5EarlyControlEnable.Stopped {
            return false
        }
        //TODO
        return true
//        switch self {
//        case .podIsInAlarm:
//            return false
//        case .activationError(let activationErrorCode):
//            switch activationErrorCode {
//            case .podIsLumpOfCoal1Hour, .podIsLumpOfCoal2Hours:
//                return false
//            default:
//                return true
//            }
//        case .internalError(.incompatibleProductId):
//            return false
//        case .systemError:
//            return false
//        default:
//            return true
//        }
    }
}

