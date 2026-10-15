#if canImport(SwiftUI)
import SwiftUI

/// The app entry point intentionally accepts no pump manager or live stores.
/// Opening this preview cannot change the active Pod or its communication context.
@MainActor
public struct O5BenchView: View {
    @StateObject private var model = BenchViewModel()
    @State private var confirmed = false
    @State private var phoneOK = true
    @State private var watchOK = true
    @State private var alarmNote = ""

    public init() {}

    public var body: some View {
        Form {
            Section("Removed-Pod experiment") {
                Text("Dry run only — simulated data and virtual time")
                    .font(.headline)
                Text("The intended workflow keeps the removed Pod as Trio’s sole active Pod until you finish and replace it normally.")
                Text("Physical experiments are unavailable: batch framing and signing-policy review are pending. This preview does not put your active Pod into bench mode.")
                    .foregroundStyle(.secondary)
                Button("Physical experiment unavailable") {}.disabled(true)
            }
            Section("Dry-run session") {
                Text(model.message).textSelection(.enabled)
                if let state = model.state {
                    Text("Simulated elapsed time: \(Int(state.virtualElapsed / 60)) minutes")
                    if !state.locks.isEmpty {
                        Text("Further simulated writes are locked: \(state.locks.joined(separator: "; "))")
                    }
                }
                Toggle("Simulate confirmation that the Pod is off-body", isOn: $confirmed)
                Button("Arm dry run") { model.arm() }
                    .disabled(!confirmed || model.busy || model.state?.armed == true)
                Button("Start a new dry-run session") { confirmed = false; model.newSession() }
                    .disabled(model.busy)
            }
            Section("Separate experiment actions") {
                action("Start baseline and export · 10 min", .baseline)
                action("Reconnect without programming · 10 min", .reconnect)
                action("Read target profile", .targetProfile)
                action("Read DIA", .dia)
                action("Enable only · observe 15 min", .enable, mutation: true)
                action("Provision synthetic G7", .provision, mutation: true)
                action("Observe reception · 30 min", .observe)
                action("Reconnect after reception", .reconnectReception)
                action("Diagnostic readback", .diagnostic)
            }
            Section("Independent observations") {
                Toggle("Phone feed continues", isOn: $phoneOK)
                Toggle("Watch feed continues", isOn: $watchOK)
                Button("Record simulated feed observation") { model.feed(phone: phoneOK, watch: watchOK) }
                TextField("Operator alarm note (private)", text: $alarmNote)
                Button("Mark alarm in dry run") { model.alarm(alarmNote) }
            }.disabled(model.busy || model.state == nil)
            Section("Saved results") {
                if let state = model.state {
                    ForEach(state.steps, id: \.id) { step in
                        HStack { Text(step.action.rawValue); Spacer(); Text(step.result).foregroundStyle(.secondary) }
                    }
                }
                Button("Export redacted session") { model.export() }.disabled(model.busy || model.state == nil)
                if !model.exportFiles.isEmpty {
                    ShareLink(items: model.exportFiles) { Text("Share redacted export files") }
                }
            }
        }
        .navigationTitle("Pod Experiment Dry Run")
        .onAppear { model.open() }
    }

    private func action(_ title: String, _ action: BenchAction, mutation: Bool = false) -> some View {
        Button(title) { model.perform(action) }
            .disabled(model.busy || model.state == nil || (mutation &&
                (model.state?.armed != true || model.state?.baselineComplete != true ||
                 model.state?.reconnectComplete != true || model.state?.locks.isEmpty != true)))
    }
}

@MainActor
private final class BenchViewModel: ObservableObject {
    @Published var state: BenchSession?
    @Published var message = "Opening saved dry run…"
    @Published var busy = false
    @Published var exportFiles: [URL] = []
    private var runner: BenchRunner?
    private var directory: URL?
    private let preference = "O5Bench.syntheticSessionDirectory"

    func open() {
        guard runner == nil, !busy else { return }
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("O5Bench")
            let identifier = UserDefaults.standard.string(forKey: preference) ?? UUID().uuidString
            // The saved preference is only a UUID, never an arbitrary path.
            guard UUID(uuidString: identifier) != nil else { throw BenchError.logging }
            let directory = root.appendingPathComponent(identifier)
            let store = try FileBenchStore(directory: directory)
            let saved = try store.load()
            let clock = BenchClock(elapsed: saved?.virtualElapsed ?? 0, id: saved?.clockID ?? UUID().uuidString)
            let runner = try BenchRunner(store: store, transport: FakeBenchTransport(clock: clock), revisions: BenchBuild.revisions.merging([
                "hostBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            ]) { _, current in current })
            self.runner = runner; self.directory = directory; state = runner.session
            UserDefaults.standard.set(identifier, forKey: preference)
            message = "Dry run ready. Each button saves one separate action."
        } catch { message = error.localizedDescription }
    }

    func newSession() {
        guard !busy else { return }
        runner = nil; state = nil; exportFiles = []
        UserDefaults.standard.set(UUID().uuidString, forKey: preference)
        open() // Previous evidence stays on disk, including pending operations.
    }

    private func run(_ work: @escaping (BenchRunner) throws -> Void) {
        guard let runner, !busy else { return }
        busy = true; message = "Running simulated action…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work(runner) }
            let state = runner.session
            DispatchQueue.main.async {
                self.state = state; self.busy = false
                switch result {
                case .success: self.message = "Action saved. Review the result before continuing."
                case .failure(let error): self.message = error.localizedDescription
                }
            }
        }
    }
    func arm() { run { try $0.arm(offBodyConfirmed: true) } }
    func feed(phone: Bool, watch: Bool) { run { try $0.recordFeed(phoneOK: phone, watchOK: watch) } }
    func alarm(_ note: String) { run { try $0.markAlarm(note: note) } }
    func perform(_ action: BenchAction) {
        guard let directory else { return }
        let export = directory.appendingPathComponent("baseline-\(UUID().uuidString)")
        run { runner in
            try runner.perform(action, identity: action == .provision
                ? BenchIdentity(code: "0123", serial: "001234567890") : nil,
                baselineExport: action == .baseline ? export : nil)
        }
    }
    func export() {
        guard let directory else { return }
        let destination = directory.appendingPathComponent("sharing-\(UUID().uuidString)")
        run { runner in
            try runner.export(to: destination)
            let files = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            DispatchQueue.main.async { self.exportFiles = files.sorted { $0.lastPathComponent < $1.lastPathComponent } }
        }
    }
}
#endif
