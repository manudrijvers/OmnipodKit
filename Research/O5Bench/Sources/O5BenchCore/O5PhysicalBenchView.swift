#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

@MainActor
public struct O5PhysicalBenchView: View {
    @StateObject private var model: PhysicalBenchModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var removed = false
    @State private var code = ""
    @State private var serial = ""
    @State private var note = ""
    @State private var phoneOK = true
    @State private var watchOK = true

    public init(open: @escaping () throws -> O5PhysicalBenchConnection) {
        _model = StateObject(wrappedValue: PhysicalBenchModel(open: open))
    }
    public var body: some View {
        Form {
            Section("Real Pod experiment") {
                Text("Keep this Pod active in Trio. After the experiment, deactivate it and install a new Pod normally.")
                Text("Starting reserves the Pod for experiments and blocks ordinary app commands until you replace it. Existing Pod delivery is not changed by starting this session.")
                Toggle("I have removed the Pod from my body; it is no longer supplying therapy", isOn: $removed)
                    .disabled(model.state != nil || model.busy)
                Button("Start session with the active Pod") { model.open() }
                    .disabled(!removed || model.state != nil || model.busy)
                Text(model.message).textSelection(.enabled)
                if model.busy {
                    ProgressView("Recording experiment…")
                    Button("Stop experiment") { model.interrupt("Operator stopped the experiment") }
                }
                if let state = model.state, !state.locks.isEmpty {
                    Text("Further experimental writes are locked. Diagnostic readback and export remain available.")
                        .foregroundStyle(.red)
                }
            }
            Section("Separate actions") {
                action("Capture baseline · 10 minutes", .baseline)
                action("Reconnect and check baseline · 10 minutes", .reconnect)
                action("Enable only · observe 15 minutes", .enable, mutation: true)
                TextField("G7 pairing code (4 characters)", text: $code)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("G7 serial (12 characters)", text: $serial)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                action("Provision G7", .provision, mutation: true)
                action("Observe reception · 30 minutes", .observe)
                action("Reconnect after reception · 10 minutes", .reconnectReception)
                action("Diagnostic readback", .diagnostic)
            }
            Section("Independent observations") {
                Toggle("Phone sensor feed continues", isOn: $phoneOK)
                    .onChange(of: phoneOK) { _ in model.feed(phoneOK, watchOK) }
                Toggle("Watch sensor feed continues", isOn: $watchOK)
                    .onChange(of: watchOK) { _ in model.feed(phoneOK, watchOK) }
                TextField("Observation or alarm note (private)", text: $note)
                Button("Mark audible alarm and stop") { model.interrupt(note.isEmpty ? "Audible alarm" : note, audibleAlarm: true) }
            }.disabled(model.state == nil)
            Section("Recorded results") {
                if let state = model.state {
                    ForEach(state.steps, id: \.id) { step in
                        HStack { Text(step.action.rawValue); Spacer(); Text(step.result) }
                    }
                }
                Button("Export redacted session") { model.export(redacted: true) }
                    .disabled(model.busy || model.state == nil)
                Button("Export private raw capture") { model.export(redacted: false) }
                    .disabled(model.busy || model.state == nil)
                Text("Private capture includes Pod and sensor identifiers. Neither export includes signing or session keys.")
                    .font(.footnote)
                if !model.files.isEmpty { ShareLink(items: model.files) { Text("Share exported files") } }
            }
        }
        .navigationTitle("Removed Pod Experiment")
        .onChange(of: scenePhase) { phase in
            if phase != .active { model.interrupt("Application left the foreground") }
        }
        .onDisappear { model.interrupt("Experiment screen closed"); UIApplication.shared.isIdleTimerDisabled = false }
    }
    private func action(_ title: String, _ action: BenchAction, mutation: Bool = false) -> some View {
        Button(title) { model.perform(action, code: code, serial: serial) }
            .disabled(model.busy || model.state == nil || (action != .diagnostic && model.state?.locks.isEmpty != true) ||
                (mutation && (model.state?.baselineComplete != true || model.state?.reconnectComplete != true)))
    }
}

@MainActor
private final class PhysicalBenchModel: ObservableObject {
    @Published var state: BenchSession?
    @Published var busy = false
    @Published var message = "Logging starts automatically with the session. Keep this screen open during timed observations."
    @Published var files: [URL] = []
    private let opener: () throws -> O5PhysicalBenchConnection
    private var runner: BenchRunner?
    private var connection: O5PhysicalBenchConnection?
    private var directory: URL?
    private var interruption: (note: String, alarm: Bool, time: Date)?
    private var pendingFeed: (phone: Bool, watch: Bool)?
    init(open: @escaping () throws -> O5PhysicalBenchConnection) { opener = open }

    func open() {
        guard !busy, runner == nil else { return }
        busy = true; message = "Reserving the active Pod and opening durable capture…"
        let opener = self.opener
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> (O5PhysicalBenchConnection, BenchRunner, URL) in
                let connection = try opener()
                let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true).appendingPathComponent("O5Bench/Physical/\(connection.sessionID)")
                let runner = try BenchRunner(store: FileBenchStore(directory: root), transport: connection,
                    revisions: BenchBuild.revisions.merging([
                        "hostBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
                    ]) { _, current in current })
                if runner.session.locks.isEmpty { try runner.arm(offBodyConfirmed: true) }
                return (connection, runner, root)
            }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let (connection, runner, root)):
                    self.connection = connection; self.runner = runner; self.directory = root; self.state = runner.session
                    UIApplication.shared.isIdleTimerDisabled = true
                    self.message = "Real Pod session ready. Capture the baseline first."
                    if let note = self.interruption { self.interruption = nil; self.interrupt(note.note, audibleAlarm: note.alarm, observedAt: note.time) }
                case .failure(let error): self.message = error.localizedDescription
                }
            }
        }
    }
    private func run(_ work: @escaping (BenchRunner) throws -> Void) {
        guard let runner, !busy else { return }
        busy = true; message = "Recording real Pod replies. Keep this screen open."
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work(runner) }
            let saved = runner.session
            DispatchQueue.main.async {
                self.state = saved; self.busy = false
                switch result {
                case .success: self.message = "Action saved. Review the result before the next action."
                case .failure(let error): self.message = error.localizedDescription
                }
                let note = self.interruption; let feed = self.pendingFeed
                self.interruption = nil; self.pendingFeed = nil
                if note != nil || feed != nil {
                    self.run { runner in
                        if let note {
                            if note.alarm { try runner.markAlarm(note: note.note, observedAt: note.time) }
                            else { try runner.stop(reason: note.note, observedAt: note.time) }
                        }
                        if let feed { try runner.recordFeed(phoneOK: feed.phone, watchOK: feed.watch) }
                    }
                }
            }
        }
    }
    func perform(_ action: BenchAction, code: String, serial: String) {
        guard let directory else { return }
        if action == .diagnostic { connection?.allowDiagnosticReadback() }
        run { runner in
            let identity = action == .provision ? try BenchIdentity(code: code, serial: serial) : nil
            try runner.perform(action, identity: identity,
                baselineExport: action == .baseline ? directory.appendingPathComponent("baseline-\(UUID().uuidString)") : nil)
        }
    }
    func interrupt(_ note: String, audibleAlarm: Bool = false, observedAt: Date = Date()) {
        guard runner != nil || busy else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        connection?.stop()
        if busy { interruption = (note, audibleAlarm, observedAt); message = "Stopping; preserving any uncertain command outcome…" }
        else { run { if audibleAlarm { try $0.markAlarm(note: note, observedAt: observedAt) } else { try $0.stop(reason: note, observedAt: observedAt) } } }
    }
    func feed(_ phone: Bool, _ watch: Bool) {
        pendingFeed = (phone, watch)
        if !phone || !watch { interrupt("Operator observed phone/watch feed interruption") }
        if !busy { pendingFeed = nil; run { try $0.recordFeed(phoneOK: phone, watchOK: watch) } }
    }
    func export(redacted: Bool) {
        guard let directory else { return }
        let destination = directory.appendingPathComponent("\(redacted ? "sharing" : "private")-\(UUID().uuidString)")
        run { runner in
            try runner.export(to: destination, redacted: redacted)
            let files = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            DispatchQueue.main.async { self.files = files }
        }
    }
}
#endif
