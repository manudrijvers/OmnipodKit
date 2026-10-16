import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

protocol BenchStore: AnyObject {
    func load() throws -> BenchSession?
    func save(_ session: BenchSession) throws
    func export(_ session: BenchSession, to directory: URL, redacted: Bool) throws
}

/// Exclusive process lease + atomic, fsynced snapshots. An in-flight operation
/// stays in the journal even if the process dies before its next milestone.
final class FileBenchStore: BenchStore {
    let directory: URL
    private var lease: Int32 = -1
    init(directory: URL) throws {
        self.directory = directory
        try Self.privateDirectory(directory)
        lease = open(directory.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lease >= 0 else { throw BenchError.logging }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            close(lease); lease = -1; throw BenchError.busy
        }
    }
    deinit { if lease >= 0 { close(lease) } }
    static func privateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let attr = try fm.attributesOfItem(atPath: url.path)
            guard attr[.type] as? FileAttributeType == .typeDirectory else { throw BenchError.logging }
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard chmod(url.path, 0o700) == 0 else { throw BenchError.logging }
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var protectedURL = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
        #endif
    }
    func load() throws -> BenchSession? {
        let url = directory.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw BenchError.logging
        }
        return try JSONDecoder().decode(BenchSession.self, from: Data(contentsOf: url))
    }
    func save(_ session: BenchSession) throws {
        try Self.write(try Self.encode(session), to: directory.appendingPathComponent("session.json"))
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw BenchError.logging }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temporary.path)
        #endif
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw BenchError.logging }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard parent >= 0 else { throw BenchError.logging }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw BenchError.logging }
    }
    func export(_ session: BenchSession, to directory: URL, redacted: Bool) throws {
        try BenchExport.write(session, to: directory, redacted: redacted)
    }
}

enum BenchExport {
    static func write(_ session: BenchSession, to directory: URL, redacted: Bool) throws {
        // A fresh directory avoids retaining an older private file in a sharing export.
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw BenchError.logging }
        try FileBenchStore.privateDirectory(directory)
        let operations: [[String: Any]] = session.operations.map { op in
            var row: [String: Any] = ["id": op.id, "actionID": op.actionID, "group": op.group,
                "outcome": op.outcome, "signingPolicy": redacted ? op.signingPolicy.components(separatedBy: "; certificate SHA256")[0] : op.signingPolicy, "expected": op.expected,
                "memberResults": op.memberResults,
                "prepared": stamp(op.prepared),
                "requests": op.requests.map { request -> [String: Any] in
                    var entry: [String: Any] = ["kind": request.kind.rawValue,
                        "responsePrefix": request.responsePrefix, "byteCount": request.body.count]
                    entry["applicationHex"] = redacted ? "REDACTED" : request.body.hexadecimalString
                    return entry
                },
                "replies": (op.replies ?? []).map { reply -> [String: Any] in
                    ["byteCount": reply.count, "applicationHex": redacted ? "REDACTED" : reply.hexadecimalString]
                }]
            for (key, value) in [("sendStarted", op.sendStarted), ("transportCompleted", op.transportCompleted),
                                 ("repliesReceived", op.repliesReceived), ("validated", op.validated)] {
                if let value { row[key] = stamp(value) }
            }
            if let batch = op.applicationBatch {
                row["applicationBatchHex"] = redacted ? "REDACTED" : batch.hexadecimalString
            }
            row["wireRecords"] = (op.wireRecords ?? []).map { record -> [String: Any] in
                ["phase": record.phase, "byteCount": record.bytes.count, "time": stamp(record.time),
                 "hex": redacted ? "REDACTED" : record.bytes.hexadecimalString]
            }
            row["lowerLevelRetransmissions"] = session.physical == true ? "0; current BLE packet sender has no retransmission loop" : "0"
            return row
        }
        var manifest: [String: Any] = ["schema": 1, "experimentID": session.id,
            "synthetic": session.physical != true, "transport": session.physical == true ? "BLE" : "fake-only", "clock": session.physical == true ? "process-uptime" : "virtual; not physical elapsed observation",
            "physicalWritesEnabled": session.physical == true && session.armed && session.locks.isEmpty && session.baselineComplete && session.reconnectComplete, "redacted": redacted,
            "revisions": session.revisions, "activationProvenance": session.activationProvenance,
            "target": redacted ? "REDACTED" : "see private-session.json",
            "locks": session.locks, "virtualElapsedSeconds": session.virtualElapsed,
            "baselineComplete": session.baselineComplete, "enableVerified": session.enableVerified,
            "configurationConfirmed": session.configurationConfirmed, "receptionObserved": session.receptionObserved,
            "steps": session.steps.map { step -> [String: Any] in
                var row: [String: Any] = ["id": step.id, "action": step.action.rawValue,
                    "result": step.result, "started": stamp(step.started)]
                if let finished = step.finished { row["finished"] = stamp(finished) }
                return row
            },
            "redaction": "Sharing exports omit all raw payloads, target and sensor identifiers, and operator free text. Checksums cover exported bytes only."]
        if let active = session.activeStep { manifest["interruptedOrActiveStep"] = active }
        var files: [String: Data] = [:]
        files["exchanges.ndjson"] = try lines(operations)
        files["events.ndjson"] = try lines(session.events.map { event in
            var fields = event.fields
            if redacted {
                // Never copy free-text operator observations into a sharing artifact.
                fields.removeValue(forKey: "note")
            }
            return ["time": stamp(event.time), "kind": event.kind, "fields": fields] as [String: Any]
        })
        if !redacted { files["private-session.json"] = try FileBenchStore.encode(session) }
        files["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        for (name, data) in files { try FileBenchStore.write(data, to: directory.appendingPathComponent(name)) }
        let checksums = files.keys.sorted().map { "\(SHA256.hex(files[$0]!))  \($0)" }.joined(separator: "\n") + "\n"
        try FileBenchStore.write(Data(checksums.utf8), to: directory.appendingPathComponent("SHA256SUMS"))
        // Verify the actual exported bytes, not merely the in-memory inputs.
        for (name, data) in files {
            guard SHA256.hex(try Data(contentsOf: directory.appendingPathComponent(name))) == SHA256.hex(data) else {
                throw BenchError.logging
            }
        }
    }
    static func stamp(_ time: BenchStamp) -> [String: Any] {
        ["wallUTC": ISO8601DateFormatter().string(from: time.wall), "monotonicSeconds": time.monotonic,
         "clockID": time.clockID, "processUptimeSeconds": time.processUptime]
    }
    static func lines(_ objects: [[String: Any]]) throws -> Data {
        var result = Data()
        for object in objects {
            result.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])); result.append(UInt8(10))
        }
        return result
    }
}

// Dependency-free SHA-256 for export integrity, not for transport cryptography.
enum SHA256 {
    static func hex(_ data: Data) -> String {
        let k: [UInt32] = [
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
        var h: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        var bytes = Array(data); let bitCount = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for n in (0..<8).reversed() { bytes.append(UInt8((bitCount >> (n * 8)) & 255)) }
        func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for start in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 { w[i] = bytes[(start+i*4)..<(start+i*4+4)].reduce(0) { ($0 << 8) | UInt32($1) } }
            for i in 16..<64 {
                let s0 = rotate(w[i-15],7) ^ rotate(w[i-15],18) ^ (w[i-15] >> 3)
                let s1 = rotate(w[i-2],17) ^ rotate(w[i-2],19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var a=h[0], b=h[1], c=h[2], d=h[3], e=h[4], f=h[5], g=h[6], v=h[7]
            for i in 0..<64 {
                let s1 = rotate(e,6) ^ rotate(e,11) ^ rotate(e,25)
                let t1 = v &+ s1 &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
                let s0 = rotate(a,2) ^ rotate(a,13) ^ rotate(a,22)
                let t2 = s0 &+ ((a & b) ^ (a & c) ^ (b & c))
                v=g; g=f; f=e; e=d &+ t1; d=c; c=b; b=a; a=t1 &+ t2
            }
            for (i, value) in [a,b,c,d,e,f,g,v].enumerated() { h[i] = h[i] &+ value }
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}
