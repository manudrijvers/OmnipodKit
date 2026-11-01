import Foundation

/// One optional post-insertion operation. The caller owns the existing serialized
/// Pod connection and physical activation; this component never repeats setup.
public enum O5EarlyControlEnable {
    private struct Exchange: Codable {
        let request: Data
        let responsePrefix: String
        let started: Date
        let startedUptime: TimeInterval
        var received: Date?
        var receivedUptime: TimeInterval?
        var response: Data?
    }
    private struct Journal: Codable {
        let schema: Int
        let id: String
        let target: String
        let firmware: String
        let bleFirmware: String
        let armed: Date
        let revisions: [String: String]
        var phase: String
        var exchanges: [Exchange] = []
        var reason: String?
    }
    public struct Stopped: LocalizedError {
        let reason: String
        public var errorDescription: String? {
            "Early control enable stopped: \(reason). Cannula insertion may already be complete. The enable command will not be retried automatically. Review the activation record before continuing."
        }
    }
    private static func root(_ override: URL?) throws -> URL {
        if let override { return override }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("O5EarlyControlEnable", isDirectory: true)
    }
    private static func store(_ id: String, _ directory: URL?) throws -> FileBenchStore {
        guard UUID(uuidString: id) != nil else { throw Stopped(reason: "invalid activation record identifier") }
        return try FileBenchStore(directory: root(directory).appendingPathComponent(id, isDirectory: true))
    }
    private static func url(_ store: FileBenchStore) -> URL { store.directory.appendingPathComponent("activation.json") }
    private static func load(_ store: FileBenchStore) throws -> Journal {
        let file = url(store)
        guard try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else {
            throw Stopped(reason: "activation record is missing")
        }
        return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
    }
    private static func save(_ journal: Journal, _ store: FileBenchStore) throws {
        try FileBenchStore.write(FileBenchStore.encode(journal), to: url(store))
    }

    /// Called only when a fresh PodState is created. The returned identifier must
    /// be persisted in that PodState. Missing journals are never recreated later.
    public static func arm(id: String, target: String, firmware: String, bleFirmware: String,
                           directory: URL? = nil) throws {
        let lease = try store(id, directory)
        guard !FileManager.default.fileExists(atPath: url(lease).path), !target.isEmpty else {
            throw Stopped(reason: "activation record already exists or target is empty")
        }
        try save(Journal(schema: 1, id: id, target: target, firmware: firmware,
                         bleFirmware: bleFirmware, armed: Date(), revisions: BenchBuild.revisions, phase: "armed"), lease)
    }

    /// Read-only preflight before priming/insertion. A restored Pod marker with a
    /// missing or interrupted record cannot start the physical activation work.
    public static func check(id: String, target: String, firmware: String, bleFirmware: String,
                             directory: URL? = nil) throws {
        do {
            let lease = try store(id, directory)
            _ = try admitted(lease, id: id, target: target, firmware: firmware, bleFirmware: bleFirmware)
        } catch let error as Stopped { throw error }
        catch { throw Stopped(reason: "activation record unavailable: \(error.localizedDescription)") }
    }

    private static func admitted(_ lease: FileBenchStore, id: String, target: String,
                                 firmware: String, bleFirmware: String) throws -> Journal {
        let journal = try load(lease)
        guard journal.schema == 1, journal.id == id, journal.target == target,
              journal.firmware == firmware, journal.bleFirmware == bleFirmware,
              firmware == "9.0.4", bleFirmware == "5.0.2" else {
            throw Stopped(reason: "Pod or firmware does not match the activation record")
        }
        guard journal.phase == "armed" || journal.phase == "verified" else {
            throw Stopped(reason: journal.reason ?? "previous attempt was interrupted (\(journal.phase))")
        }
        return journal
    }

    /// Reply bodies exclude their AID prefix; detailedStatus returns the 22-byte
    /// legacy page 2 body. All closures run synchronously on the caller's queue.
    public static func finish(id: String, target: String, firmware: String, bleFirmware: String,
                              directory: URL? = nil,
                              send: (Data, String) throws -> Data,
                              detailedStatus: () throws -> Data) throws {
        do {
            try perform(id: id, target: target, firmware: firmware, bleFirmware: bleFirmware,
                        directory: directory, send: send, detailedStatus: detailedStatus)
        } catch let error as Stopped { throw error }
        catch { throw Stopped(reason: "activation record unavailable: \(error.localizedDescription)") }
    }

    private static func perform(id: String, target: String, firmware: String, bleFirmware: String,
                                directory: URL?, send: (Data, String) throws -> Data,
                                detailedStatus: () throws -> Data) throws {
        let lease = try store(id, directory)
        var journal = try admitted(lease, id: id, target: target, firmware: firmware, bleFirmware: bleFirmware)
        let previouslyVerified = journal.phase == "verified"
        // A crash during any attempt stops subsequent automatic activation work.
        journal.phase = "checking"
        try save(journal, lease)
        func exchange(_ request: Data, _ prefix: String, mutation: Bool = false) throws -> Data {
            if mutation { journal.phase = "writePending" }
            journal.exchanges.append(Exchange(request: request, responsePrefix: prefix, started: Date(),
                startedUptime: ProcessInfo.processInfo.systemUptime))
            // Durable intent precedes every send, especially the sole mutation.
            try save(journal, lease)
            let response = try prefix == "legacy-page-2" ? detailedStatus() : send(request, prefix)
            journal.exchanges[journal.exchanges.count - 1].response = response
            journal.exchanges[journal.exchanges.count - 1].received = Date()
            journal.exchanges[journal.exchanges.count - 1].receivedUptime = ProcessInfo.processInfo.systemUptime
            try save(journal, lease)
            return response
        }
        func status() throws {
            let aid = try O5UnifiedAidStatus(exchange(Data("G3.12".utf8), "3.12="))
            let legacy = try BenchLegacyStatus(exchange(Data([0x0e, 0x01, 0x02]), "legacy-page-2"))
            guard legacy.fault == 0, legacy.active, legacy.deliveryStatus == 1,
                  aid.algorithmReady, aid.podActive, aid.isManual, aid.cgmType == 0 else {
                throw Stopped(reason: "Pod is not ready, active, Manual, sensor-free and fault-free")
            }
        }
        func interface() throws -> O5CgmInterfaceStatus {
            let value = try O5CgmInterfaceStatus(exchange(Data("G4.2".utf8), "4.2="))
            guard value.desiredSensorType == 0, let control = value.control,
                  [UInt8(0), 1, 2, 255].contains(control) else {
                throw Stopped(reason: "unexpected sensor type or interface control")
            }
            return value
        }
        do {
            try status()
            let before = try interface()
            if before.control != 0 {
                guard !previouslyVerified else {
                    throw Stopped(reason: "control changed after verification")
                }
                let reply = try exchange(Data("SE4.2=".utf8) + Data([0, 2, 4, 0]), "ES4.2=", mutation: true)
                try O5AidResponseValidation.extendedSet(reply, command: "ES4.2=")
            }
            guard try interface().control == 0 else { throw Stopped(reason: "control enable readback mismatch") }
            try status()
            journal.phase = "verified"
            try save(journal, lease)
        } catch {
            journal.phase = "stopped"
            let reason = (error as? Stopped)?.reason ?? error.localizedDescription
            journal.reason = reason
            // If this fails, the preceding durable checking/writePending record
            // still forbids another mutation. Never erase an uncertain outcome.
            try? save(journal, lease)
            throw Stopped(reason: reason)
        }
    }

    /// Local evidence only; does not open a BLE session or resume an operation.
    public static func record(id: String, directory: URL? = nil) throws -> String {
        let lease = try store(id, directory)
        let journal = try load(lease)
        return String(decoding: try FileBenchStore.encode(journal), as: UTF8.self)
    }
}
