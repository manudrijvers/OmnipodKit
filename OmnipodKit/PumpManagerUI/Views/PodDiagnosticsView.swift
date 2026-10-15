//
//  PodDiagnosticsView.swift
//  OmnipodKit
//
//  From OmniBLE/PumpManageUI/Views/PodDiagnosticsView.swift
//  Created by Joseph Moran on 11/25/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI
import HealthKit


protocol DiagnosticCommands {
    func playTestBeeps() async throws
    func readPulseLog() async throws -> String
    func readPulseLogPlus() async throws -> String
    func readActivationTime() async throws -> String
    func readTriggeredAlerts() async throws -> String
    func getDetailedStatus() async throws -> DetailedStatus
    func pumpManagerDetails() -> String
    var podType: PodType { get }
    func connectDexcomG7(pairingCode: String, serialNumber: String) async throws -> String
    func readDexcomG7Status() async throws -> String
}

struct PodDiagnosticsView: View  {

    var title: String

    var diagnosticCommands: DiagnosticCommands
    var podOk: Bool
    var noPod: Bool

    var body: some View {
        List {
            NavigationLink(destination: ReadPodStatusView(getDetailedStatus: diagnosticCommands.getDetailedStatus)) {
                FrameworkLocalText("Read Pod Status", comment: "Text for read pod status navigation link")
                    .foregroundColor(Color.primary)
            }
            .disabled(noPod)

            NavigationLink(destination: PlayTestBeepsView(playTestBeeps: {
                try await diagnosticCommands.playTestBeeps()
            })) {
                FrameworkLocalText("Play Test Beeps", comment: "Text for play test beeps navigation link")
                    .foregroundColor(Color.primary)
            }
            .disabled(!podOk)

            NavigationLink(destination: ReadPodInfoView(
                title: LocalizedString("Read Pulse Log", comment: "Text for read pulse log title"),
                actionString: LocalizedString("Reading Pulse Log...", comment: "Text for read pulse log action"),
                failedString: LocalizedString("Failed to read pulse log", comment: "Alert title for error when reading pulse log"),
                action: { try await diagnosticCommands.readPulseLog() }))
            {
                FrameworkLocalText("Read Pulse Log", comment: "Text for read pulse log navigation link")
                    .foregroundColor(Color.primary)
            }
            .disabled(noPod)

            NavigationLink(destination: ReadPodInfoView(
                title: LocalizedString("Read Pulse Log Plus", comment: "Text for read pulse log plus title"),
                actionString: LocalizedString("Reading Pulse Log Plus...", comment: "Text for read pulse log plus action"),
                failedString: LocalizedString("Failed to read pulse log plus", comment: "Alert title for error when reading pulse log plus"),
                action: { try await diagnosticCommands.readPulseLogPlus() }))
            {
                FrameworkLocalText("Read Pulse Log Plus", comment: "Text for read pulse log plus navigation link")
                    .foregroundColor(Color.primary)
            }
            .disabled(noPod)

            NavigationLink(destination: ReadPodInfoView(
                title: LocalizedString("Read Activation Time", comment: "Text for read activation time title"),
                actionString: LocalizedString("Reading Activation Time...", comment: "Text for read activation time action"),
                failedString: LocalizedString("Failed to read activation time", comment: "Alert title for error when reading activation time"),
                action: { try await diagnosticCommands.readActivationTime() }))
            {
                FrameworkLocalText("Read Activation Time", comment: "Text for read activation time navigation link")
                    .foregroundColor(Color.primary)
            }
            .disabled(noPod)

            NavigationLink(destination: ReadPodInfoView(
                title: LocalizedString("Read Triggered Alerts", comment: "Text for read triggered alerts title"),
                actionString: LocalizedString("Reading Triggered Alerts...", comment: "Text for read triggered alerts action"),
                failedString: LocalizedString("Failed to read triggered alerts", comment: "Alert title for error when reading triggered alerts"),
                action: { try await diagnosticCommands.readTriggeredAlerts() }))
            {
                FrameworkLocalText("Read Triggered Alerts", comment: "Text for read triggered alerts navigation link")
                    .foregroundColor(Color.primary)
            }
            .disabled(noPod)

            if diagnosticCommands.podType.isO5 {
                NavigationLink(destination: ConnectDexcomG7View(connect: { pairingCode, serialNumber in
                    try await diagnosticCommands.connectDexcomG7(pairingCode: pairingCode, serialNumber: serialNumber)
                })) {
                    FrameworkLocalText("Connect Dexcom G7", comment: "Text for connect Dexcom G7 navigation link")
                        .foregroundColor(Color.primary)
                }
                .disabled(!podOk)

                NavigationLink(destination: ReadPodInfoView(
                    title: LocalizedString("Read Dexcom G7 Status", comment: "Text for read Dexcom G7 status title"),
                    actionString: LocalizedString("Reading Dexcom G7 Status...", comment: "Text for read Dexcom G7 status action"),
                    failedString: LocalizedString("Failed to read Dexcom G7 status", comment: "Alert title for error when reading Dexcom G7 status"),
                    action: { try await diagnosticCommands.readDexcomG7Status() }))
                {
                    FrameworkLocalText("Read Dexcom G7 Status", comment: "Text for read Dexcom G7 status navigation link")
                        .foregroundColor(Color.primary)
                }
                .disabled(!podOk)
            }

            NavigationLink(destination: PumpManagerDetailsView() { diagnosticCommands.pumpManagerDetails() })
            {
                FrameworkLocalText("Pump Manager Details", comment: "Text for pump manager details navigation link")
                    .foregroundColor(Color.primary)
            }

        }
        .insetGroupedListStyle()
        .navigationTitle(title)
    }
}

/// Proof of concept: sends a Dexcom G7 pairing code and serial number to the active O5 pod,
/// which then connects to the sensor itself.
struct ConnectDexcomG7View: View {
    var connect: (_ pairingCode: String, _ serialNumber: String) async throws -> String

    @State private var pairingCode: String = ""
    @State private var serialNumber: String = ""
    @State private var result: String = ""
    @State private var executing: Bool = false

    private var inputIsValid: Bool {
        pairingCode.count == 4 && serialNumber.count == 12 && (pairingCode + serialNumber).allSatisfy { $0.isASCII && $0.isNumber }
    }

    var body: some View {
        List {
            Section {
                TextField(LocalizedString("Pairing code (4 digits)", comment: "Placeholder for the Dexcom G7 pairing code"), text: $pairingCode)
                    .keyboardType(.numberPad)
                TextField(LocalizedString("Serial number (12 digits)", comment: "Placeholder for the Dexcom G7 serial number"), text: $serialNumber)
                    .keyboardType(.numberPad)
            }
            Section {
                Button(action: {
                    Task { @MainActor in
                        executing = true
                        do {
                            result = try await connect(pairingCode, serialNumber)
                        } catch {
                            result = error.localizedDescription
                        }
                        executing = false
                    }
                }) {
                    Text(executing ? LocalizedString("Connecting...", comment: "Text while connecting Dexcom G7") : LocalizedString("Connect", comment: "Button to connect Dexcom G7"))
                }
                .disabled(!inputIsValid || executing)
            }
            if !result.isEmpty {
                Section {
                    Text(result)
                        .font(Font.system(size: 12).monospaced())
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(LocalizedString("Connect Dexcom G7", comment: "Title for connect Dexcom G7 page"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
