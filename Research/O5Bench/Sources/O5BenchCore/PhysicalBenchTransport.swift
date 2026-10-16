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

/// A single, already-active controller context. The host must acquire the durable
/// interlock before returning this connection. All callbacks run off the UI thread.
public final class O5PhysicalBenchConnection: BenchTransport {
    let sessionID: String
    let target: BenchTarget
    let firmware: String
    let bleVersion: String
    let activationProvenance: String
    let physical = true
    let clock = BenchClock(realTime: true)
    private let validate: () throws -> Void
    private let selectPolicy: ([BenchRequest]) throws -> String
    private let send: ([BenchRequest], @escaping O5BenchWireCapture) throws -> [Data]
    private let reconnectPod: () throws -> Void
    private let stopLock = NSLock()
    private var stopped = false

    public init(sessionID: String, target: BenchTarget, firmware: String, bleVersion: String, activationProvenance: String,
                validate: @escaping () throws -> Void,
                selectPolicy: @escaping ([BenchRequest]) throws -> String,
                exchange: @escaping ([BenchRequest], @escaping O5BenchWireCapture) throws -> [Data],
                reconnect: @escaping () throws -> Void) {
        self.sessionID = sessionID; self.target = target; self.firmware = firmware; self.bleVersion = bleVersion
        self.activationProvenance = activationProvenance; self.validate = validate
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
    func allowDiagnosticReadback() { stopLock.lock(); stopped = false; stopLock.unlock() }
    public func stop() { stopLock.lock(); stopped = true; stopLock.unlock() }
}

/// Persisted separately from the journal so ordinary writers are still blocked
/// when a journal is missing/corrupt or the application has restarted.
public enum O5BenchInterlock {
    private struct Lease: Codable { let id: String; let target: BenchTarget }
    private static let mutex = NSLock()
    private static func path(_ controller: UInt32, create: Bool = false) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: create).appendingPathComponent("O5BenchInterlocks")
        if create {
            try FileBenchStore.privateDirectory(root)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
            #endif
        }
        return root.appendingPathComponent("\(controller).json")
    }
    public static func acquire(controller: UInt32, target: BenchTarget) throws -> String {
        mutex.lock(); defer { mutex.unlock() }
        let url = try path(controller, create: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let lease = try JSONDecoder().decode(Lease.self, from: Data(contentsOf: url))
            guard lease.target == target else { throw BenchError.target }
            return lease.id // Reopening preserves the same journal, including unknown outcomes.
        }
        let lease = Lease(id: UUID().uuidString, target: target)
        try FileBenchStore.write(FileBenchStore.encode(lease), to: url)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        return lease.id
    }
    public static func check(controller: UInt32, permit: String? = nil, target: BenchTarget? = nil,
                             closeout: Bool = false) throws {
        mutex.lock(); defer { mutex.unlock() }
        let url = try path(controller)
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            if permit != nil { throw BenchError.blocked }; return
        }
        // Ordinary commands fail even if the lease cannot be decoded.
        if closeout { return }
        guard let permit, let target else { throw BenchError.blocked }
        let lease = try JSONDecoder().decode(Lease.self, from: data)
        guard lease.id == permit, lease.target == target else { throw BenchError.target }
    }
    public static func forget(controller: UInt32) throws {
        mutex.lock(); defer { mutex.unlock() }
        let url = try path(controller)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    /// Stable opaque reference; never returns the supplied context/key bytes.
    public static func contextReference(_ data: Data) -> String { SHA256.hex(data) }
}
