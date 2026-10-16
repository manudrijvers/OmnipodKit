import Foundation

enum BenchError: String, Error, LocalizedError {
    case physicalDisabled = "The dry-run and CLI transport cannot access a physical Pod. Use Removed Pod Experiment in the iOS app."
    case target = "Target does not match the complete bench allowlist entry."
    case busy = "Another action or process owns this session."
    case blocked = "Mutation blocked; inspect the saved session and lock reasons."
    case baseline = "A completed baseline and fresh parsed Manual, active, nonfaulted status are required."
    case identity = "Identity is different, incomplete or invalid; first-add provisioning is blocked."
    case reply = "Missing, malformed or mismatching response."
    case logging = "Evidence persistence failed; further mutations are blocked."
    case interrupted = "Action interrupted; outcome is unknown and will not be replayed."
    case arguments = "Invalid command or arguments. Run o5-bench help."
    var errorDescription: String? { rawValue }
}

public struct BenchTarget: Codable, Equatable {
    public let lot: String
    public let sequence: String
    public let bleAssociation: String
    /// Opaque context reference, never a key or credential.
    public let secureContextReference: String
    public init(lot: String, sequence: String, bleAssociation: String, secureContextReference: String) {
        self.lot = lot; self.sequence = sequence; self.bleAssociation = bleAssociation
        self.secureContextReference = secureContextReference
    }
    static let synthetic = BenchTarget(lot: "SYNTHETIC-LOT", sequence: "SYNTHETIC-SEQ",
        bleAssociation: "SYNTHETIC-BLE", secureContextReference: "SYNTHETIC-CONTEXT")
}

struct BenchIdentity: Codable, Equatable {
    let code: String
    let serial: String
    init(code: String, serial: String) throws {
        // Textual ASCII fields, never integer conversion; preserve leading zeroes.
        guard Self.valid(code, count: 4), Self.valid(serial, count: 12) else { throw BenchError.identity }
        self.code = code; self.serial = serial
    }
    static func valid(_ value: String, count: Int) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == count && bytes.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }
    func matches(_ info: O5G7SensorInfo) -> Bool {
        guard let codeData = info.pairingCodeBytes, let serialData = info.serialNumberBytes,
              let c = String(data: codeData, encoding: .ascii),
              let s = String(data: serialData, encoding: .ascii),
              Self.valid(c, count: 4), Self.valid(s, count: 12) else { return false }
        return c.lowercased() == code.lowercased() && s.lowercased() == serial.lowercased()
    }
}

struct BenchStamp: Codable {
    let wall: Date
    let monotonic: Double
    let processUptime: Double
    let clockID: String
}

/// Live runs use process uptime; dry runs advance a virtual clock.
final class BenchClock {
    private var virtualElapsed: Double
    private var realStart: Double
    let realTime: Bool
    var elapsed: Double {
        get { realTime ? ProcessInfo.processInfo.systemUptime - realStart : virtualElapsed }
        set { virtualElapsed = newValue; realStart = ProcessInfo.processInfo.systemUptime - newValue }
    }
    let id: String
    init(elapsed: Double = 0, id: String = UUID().uuidString, realTime: Bool = false) {
        virtualElapsed = elapsed; self.id = id; self.realTime = realTime
        realStart = ProcessInfo.processInfo.systemUptime - elapsed
    }
    var stamp: BenchStamp { BenchStamp(wall: Date(), monotonic: elapsed, processUptime: ProcessInfo.processInfo.systemUptime, clockID: id) }
    func advance(_ seconds: Double) {
        if realTime { Thread.sleep(forTimeInterval: seconds) } else { elapsed += seconds }
    }
}

enum BenchAction: String, Codable, CaseIterable {
    case baseline, reconnect, targetProfile, dia, enable, provision, observe, reconnectReception, diagnostic
}

public struct BenchRequest: Codable, Equatable {
    public enum Kind: String, Codable { case aid, legacyStatus, legacyPage7 }
    public let kind: Kind
    public let body: Data
    public let responsePrefix: String
    var isMutation: Bool { kind == .aid && body.starts(with: Data("SE".utf8)) }
    static func get(_ attribute: String) -> Self {
        Self(kind: .aid, body: Data("G\(attribute)".utf8), responsePrefix: "\(attribute)=")
    }
    static let legacy = Self(kind: .legacyStatus, body: Data(), responsePrefix: "")
    static let page7 = Self(kind: .legacyPage7, body: Data(), responsePrefix: "")
    static let enable = Self(kind: .aid, body: Data("SE4.2=".utf8) + Data([0, 2, 4, 0]), responsePrefix: "ES4.2=")
    static func identity(_ identity: BenchIdentity) -> Self {
        Self(kind: .aid, body: Data("SE4.1=".utf8) + Data([0, 18, 2]) + Data(identity.code.utf8)
            + Data([3]) + Data(identity.serial.utf8), responsePrefix: "ES4.1=")
    }
}

struct BenchOperation: Codable {
    let id: String
    let experimentID: String
    let actionID: String
    let target: BenchTarget
    let requests: [BenchRequest]
    let group: String
    let applicationBatch: Data?
    let expected: String
    let signingPolicy: String
    let prepared: BenchStamp
    var sendStarted: BenchStamp?
    var transportCompleted: BenchStamp?
    var repliesReceived: BenchStamp?
    var validated: BenchStamp?
    var replies: [Data]?
    var wireRecords: [BenchWireRecord]?
    var memberResults: [String] = []
    var outcome: String = "pending"
}

struct BenchStep: Codable {
    let id: String
    let action: BenchAction
    let started: BenchStamp
    var finished: BenchStamp?
    var result: String = "in-progress"
}

struct BenchEvent: Codable {
    let time: BenchStamp
    let kind: String
    let fields: [String: String]
}

struct BenchSession: Codable {
    var physical: Bool?
    var schema = 1
    let id: String
    let target: BenchTarget
    let revisions: [String: String]
    let activationProvenance: String
    let clockID: String
    var virtualElapsed: Double = 0
    var offBodyConfirmed = false
    var armed = false
    var baselineComplete = false
    var reconnectComplete = false
    var enableVerified = false
    var configurationConfirmed = false
    var receptionObserved = false
    var locks: [String] = []
    var activeStep: String?
    var steps: [BenchStep] = []
    var operations: [BenchOperation] = []
    var events: [BenchEvent] = []
    var identity: BenchIdentity?
    var lastSensorTimestamp: Int32?
    var phoneFeedOK = true
    var watchFeedOK = true
    var fakeControl: UInt8 = 255
    var fakeIdentity: BenchIdentity?
}

struct BenchSnapshot {
    let interface: O5CgmInterfaceStatus
    let identity: O5G7SensorInfo
    let status: O5UnifiedAidStatus
    let legacy: BenchLegacyStatus
    let received: Double
}

/// Narrow decoding of the established 22-byte detailed status body. Page 7 is
/// preserved separately as opaque evidence; no page-7 semantics are invented.
struct BenchLegacyStatus {
    let progress: UInt8
    let fault: UInt8
    let ageMinutes: Int
    let reservoirPulses: Int
    let alerts: UInt8
    init(_ data: Data) throws {
        let b = Array(data)
        guard b.count == 22, b[0] == 2 else { throw BenchError.reply }
        progress = b[1]; fault = b[8]
        ageMinutes = Int(b[13]) * 256 + Int(b[14])
        reservoirPulses = Int(b[11] & 3) * 256 + Int(b[12])
        alerts = b[15]
    }
    var active: Bool { progress == 8 || progress == 9 }
}

struct BenchWireRecord: Codable {
    let phase: String
    let bytes: Data
    let time: BenchStamp
}
