import Foundation
import O5BenchCore

do { try BenchConsole.run(Array(CommandLine.arguments.dropFirst())) }
catch {
    // Error descriptions intentionally contain no identifiers or raw payloads.
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
