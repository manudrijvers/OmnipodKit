import Foundation

public enum BenchConsole {
    public static func run(_ arguments: [String]) throws {
        if arguments.isEmpty || arguments == ["help"] {
            print("""
            Offline removed-Pod experiment runner (fake transport, virtual time).
            Intended physical workflow: remove the current Pod, keep it active in
            Trio, experiment, then deactivate/replace normally. One Pod only.
            Physical commands are disabled pending batch/signing review.

            o5-bench <session.private> <command> [arguments]
              init                         create a synthetic session
              arm --confirm-off-body       arm fake mutations
              baseline <new-export-dir>    verify export and observe 10 virtual minutes
              reconnect                    reconnect, no programming; 10 virtual minutes
              targetProfile | dia          optional diagnostic groups
              enable                       control-only SET; 15 virtual minutes
              provision                    recovered batch with synthetic identity
              observe                      30 virtual minutes
              reconnectReception           reconnect and check fresh samples
              diagnostic                   readback, including after uncertainty
              feed <ok|interrupted> <ok|interrupted>  phone and watch separately
              alarm <note>                 independent operator timestamp
              export <new-dir> [--private]  sharing export by default
              status                       saved steps and locks
              physical                     reports unresolved prerequisites

            Each invocation performs one action. No run-all or retry command.
            provision uses only synthetic 0123 / 001234567890. Do not enter real
            sensor credentials in this offline CLI or shell command history.
            """)
            return
        }
        guard arguments.count >= 2 else { throw BenchError.arguments }
        let store = try FileBenchStore(directory: URL(fileURLWithPath: arguments[0]))
        let saved = try store.load()
        let clock = BenchClock(elapsed: saved?.virtualElapsed ?? 0, id: saved?.clockID ?? UUID().uuidString)
        let runner = try BenchRunner(store: store, transport: FakeBenchTransport(clock: clock), revisions: BenchBuild.revisions)
        let tail = Array(arguments.dropFirst(2))
        switch arguments[1] {
        case "init": guard tail.isEmpty else { throw BenchError.arguments }
        case "arm":
            guard tail == ["--confirm-off-body"] else { throw BenchError.arguments }
            try runner.arm(offBodyConfirmed: true)
        case "baseline":
            guard tail.count == 1 else { throw BenchError.arguments }
            try runner.perform(.baseline, baselineExport: URL(fileURLWithPath: tail[0]))
        case "provision":
            guard tail.isEmpty else { throw BenchError.arguments }
            try runner.perform(.provision, identity: BenchIdentity(code: "0123", serial: "001234567890"))
        case "feed":
            guard tail.count == 2, tail.allSatisfy({ ["ok", "interrupted"].contains($0) }) else { throw BenchError.arguments }
            try runner.recordFeed(phoneOK: tail[0] == "ok", watchOK: tail[1] == "ok")
        case "alarm": try runner.markAlarm(note: tail.joined(separator: " "))
        case "export":
            guard tail.count == 1 || (tail.count == 2 && tail[1] == "--private") else { throw BenchError.arguments }
            try runner.export(to: URL(fileURLWithPath: tail[0]), redacted: tail.count == 1)
        case "physical": try runner.requirePhysicalAccess()
        case "status": break
        default:
            guard tail.isEmpty, let action = BenchAction(rawValue: arguments[1]) else { throw BenchError.arguments }
            try runner.perform(action)
        }
        print("Synthetic session; physical writes disabled; virtual elapsed: \(Int(runner.session.virtualElapsed)) seconds")
        for step in runner.session.steps { print("\(step.action.rawValue): \(step.result)") }
        if !runner.session.locks.isEmpty { print("Mutation locks: \(runner.session.locks.joined(separator: "; "))") }
    }
}
