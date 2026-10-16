import Foundation

public typealias O5BenchWireCapture = (_ phase: String, _ bytes: Data) throws -> Void

protocol BenchTransport: AnyObject {
    var target: BenchTarget { get }
    var firmware: String { get }
    var bleVersion: String { get }
    var clock: BenchClock { get }
    var physical: Bool { get }
    var activationProvenance: String { get }
    func checkAccess() throws
    func policy(for requests: [BenchRequest]) throws -> String
    func exchange(_ requests: [BenchRequest], capture: @escaping O5BenchWireCapture) throws -> [Data]
    func reconnect() throws
}

/// A single, already-active controller context. All exchanges use the existing
/// serialized BLE session queue; only background maintenance is paused.
public final class O5PhysicalBenchConnection: BenchTransport {
    let sessionID: String
    let target: BenchTarget
    let firmware: String
    let bleVersion: String
    let activationProvenance: String
    let physical = true
    let clock = BenchClock(realTime: true)
    private let validate: () throws -> Void
    private let activate: () throws -> Void
    private let release: () -> Void
    private let selectPolicy: ([BenchRequest]) throws -> String
    private let send: ([BenchRequest], @escaping O5BenchWireCapture) throws -> [Data]
    private let reconnectPod: () throws -> Void
    private let stopLock = NSLock()
    private var stopped = false

    public init(sessionID: String, target: BenchTarget, firmware: String, bleVersion: String, activationProvenance: String,
                validate: @escaping () throws -> Void,
                activate: @escaping () throws -> Void = {}, release: @escaping () -> Void = {},
                selectPolicy: @escaping ([BenchRequest]) throws -> String,
                exchange: @escaping ([BenchRequest], @escaping O5BenchWireCapture) throws -> [Data],
                reconnect: @escaping () throws -> Void) {
        self.sessionID = sessionID; self.target = target; self.firmware = firmware; self.bleVersion = bleVersion
        self.activationProvenance = activationProvenance; self.validate = validate
        self.activate = activate; self.release = release
        self.selectPolicy = selectPolicy; self.send = exchange; self.reconnectPod = reconnect
    }
    public func validateAccess() throws { try checkAccess() }
    func checkAccess() throws {
        stopLock.lock(); let stop = stopped; stopLock.unlock()
        guard !stop else { throw BenchError.interrupted }
        try validate()
    }
    func policy(for requests: [BenchRequest]) throws -> String { try selectPolicy(requests) }
    func exchange(_ requests: [BenchRequest], capture: @escaping O5BenchWireCapture) throws -> [Data] {
        try checkAccess()
        return try send(requests, capture)
    }
    func reconnect() throws { try checkAccess(); try reconnectPod() }
    func allowDiagnosticReadback() throws {
        stopLock.lock(); defer { stopLock.unlock() }
        try activate()
        stopped = false
    }
    public func stop() {
        stopLock.lock(); defer { stopLock.unlock() }
        stopped = true
        release()
    }
    deinit { release() }
}

/// A process-local pause for automatic status/alert maintenance, never a send lock.
/// Tokens prevent cleanup of an old session from ending a newer session's pause.
public final class O5BenchBackgroundPause {
    private let mutex = NSLock()
    private var owner: UUID?
    public init() {}
    public var isActive: Bool {
        mutex.lock(); defer { mutex.unlock() }
        return owner != nil
    }
    public func begin(_ token: UUID) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard owner == nil || owner == token else { throw BenchError.busy }
        owner = token
    }
    public func end(_ token: UUID) {
        mutex.lock(); defer { mutex.unlock() }
        if owner == token { owner = nil }
    }
}

/// Stable experiment journal identity. Normal commands never consult this metadata.
public enum O5BenchJournal {
    public static func sessionID(controller: UInt32, target: BenchTarget) throws -> String {
        // Preserve captures made by the earlier interlock implementation. The old
        // file is only a journal locator now; it cannot block any ordinary command.
        struct OldLease: Decodable { let id: String; let target: BenchTarget }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        let old = root.appendingPathComponent("O5BenchInterlocks/\(controller).json")
        do {
            let lease = try JSONDecoder().decode(OldLease.self, from: Data(contentsOf: old))
            if lease.target == target {
                guard UUID(uuidString: lease.id) != nil else { throw BenchError.logging }
                return lease.id
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
        let bytes = Data("\(controller):\(target.lot):\(target.sequence):\(target.bleAssociation):\(target.secureContextReference)".utf8)
        let h = Array(SHA256.hex(bytes).prefix(32))
        return String(h[0..<8]) + "-" + String(h[8..<12]) + "-" + String(h[12..<16]) + "-" + String(h[16..<20]) + "-" + String(h[20..<32])
    }
    public static func contextReference(_ data: Data) -> String { SHA256.hex(data) }
}
