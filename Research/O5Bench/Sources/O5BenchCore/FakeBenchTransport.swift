import Foundation

/// Deterministic offline transport for the dry-run screen, CLI and tests.
final class FakeBenchTransport: BenchTransport {
    let physical = false
    var activationProvenance: String { "synthetic fixture; no physical activation observed" }
    func checkAccess() throws {}
    func policy(for requests: [BenchRequest]) throws -> String { "simulation-only" }
    func exchange(_ requests: [BenchRequest], capture: @escaping O5BenchWireCapture) throws -> [Data] {
        try exchange(requests)
    }
    var target: BenchTarget = .synthetic
    var firmware = "9.0.4"
    var bleVersion = "5.0.2"
    var control: UInt8 = 255
    var identity: BenchIdentity?
    var manual = true
    var active = true
    var fault: UInt8 = 0
    var egv: Int16 = 123
    var freezeSample = false
    var failAfterSend = false
    var rejectMember: Int?
    var overrideBatchReply: Data?
    var overrideReply: ((BenchRequest, Data) -> Data)?
    var onSend: (() throws -> Void)?
    private(set) var sends: [[BenchRequest]] = []
    private(set) var reconnectCount = 0
    let clock: BenchClock
    init(clock: BenchClock) { self.clock = clock }

    func reconnect() { reconnectCount += 1 } // No setup or identity writes.

    func exchange(_ requests: [BenchRequest]) throws -> [Data] {
        sends.append(requests)
        try onSend?()
        var replies: [Data] = []
        for (index, request) in requests.enumerated() {
            let reply: Data
            if request.isMutation && rejectMember == index {
                reply = Data((request.responsePrefix + "1").utf8)
            } else if request == .enable {
                control = 0
                reply = Data("ES4.2=0".utf8)
            } else if request.body.starts(with: Data("SE4.1=".utf8)) {
                let bytes = Array(request.body.dropFirst(6))
                guard bytes.count == 20, bytes[0...2] == [0, 18, 2], bytes[7] == 3,
                      let code = String(bytes: bytes[3..<7], encoding: .ascii),
                      let serial = String(bytes: bytes[8..<20], encoding: .ascii) else { throw BenchError.reply }
                identity = try BenchIdentity(code: code, serial: serial)
                reply = Data("ES4.1=0".utf8)
            } else {
                reply = try read(request)
            }
            replies.append(overrideReply?(request, reply) ?? reply)
        }
        if failAfterSend { throw BenchError.interrupted }
        if requests.count == 2, requests.allSatisfy(\.isMutation) {
            _ = try BenchBatchCodec.request(requests)
            return [overrideBatchReply ?? (replies[0] + Data([0x2c]) + replies[1])]
        }
        return replies
    }

    private func read(_ request: BenchRequest) throws -> Data {
        if request.kind == .legacyStatus {
            var b = [UInt8](repeating: 0, count: 22)
            b[0] = 2; b[1] = active ? 8 : 15; b[2] = 1; b[8] = fault
            b[11] = 1; b[12] = 244 // 500 synthetic pulses
            let minutes = 120 + Int(clock.elapsed / 60)
            b[13] = UInt8((minutes >> 8) & 255); b[14] = UInt8(minutes & 255)
            return Data(b)
        }
        if request.kind == .legacyPage7 { return Data([7]) } // Opaque synthetic fixture only.
        let payload: Data
        switch String(data: request.body, encoding: .ascii) {
        case "G4.2": payload = keyed([(1, Data([0])), (2, Data([1])), (3, Data([1])), (4, Data([control]))])
        case "G4.1":
            if let identity {
                payload = keyed([(1, Data([7])), (2, Data(identity.code.utf8)), (3, Data(identity.serial.utf8))])
            } else { payload = Data([0, 0]) }
        case "G3.12":
            let hasSensor = identity != nil
            var body = Data()
            body.appendBigEndian(UInt16(bitPattern: hasSensor ? egv : 0))
            let sample = freezeSample ? UInt32(10000) : UInt32(10000 + Int(clock.elapsed / 300) * 300)
            body.appendBigEndian(hasSensor ? sample : UInt32(0))
            body.appendBigEndian(UInt16(14)); body.append(UInt8(manual ? 1 : 2))
            body.appendBigEndian(UInt32(0x80000000)); body.appendBigEndian(UInt32(10000 + clock.elapsed))
            body.append(UInt8(0)); body.append(UInt8(active ? 3 : 1)); body.append(UInt8(hasSensor ? 7 : 0))
            body.appendBigEndian(UInt16(hasSensor ? 16 : 0))
            if hasSensor {
                body.appendBigEndian(UInt32(9000)); body.appendBigEndian(UInt32(864000))
                body.appendBigEndian(sample - 9000); body.append(contentsOf: [0, 0, 0, 1])
            }
            payload = lengthPrefixed(body)
        case "G3.1":
            var body = Data()
            for _ in 0..<48 { body.appendBigEndian(UInt32(110)) }
            payload = lengthPrefixed(body)
        case "G3.9": payload = Data("8".utf8)
        default: throw BenchError.reply
        }
        return Data(request.responsePrefix.utf8) + payload
    }
}

func lengthPrefixed(_ body: Data) -> Data {
    var data = Data(); data.appendBigEndian(UInt16(body.count)); data.append(body); return data
}

func keyed(_ fields: [(UInt8, Data)]) -> Data {
    let mask = fields.reduce(UInt32(1)) { $0 | (UInt32(1) << $1.0) }
    var body = Data([0]); body.appendBigEndian(mask)
    for (key, value) in fields { body.append(key); body.append(value) }
    return lengthPrefixed(body)
}
