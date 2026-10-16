import Foundation

/// The traced iOS QN/TWI constructor selects signing ID 0 (registration default).
/// This does not import Android's per-attribute IDs into the iOS path.
public struct O5BenchSigningPolicy {
    public enum Mode: UInt8 { case encrypted = 1, secondarySigned = 4 }
    public let mode: Mode
    public let certificateSHA256: String
    public var description: String { "iOS signing ID 0; certificate default; mode \(mode.rawValue); certificate SHA256 \(certificateSHA256)" }
    public enum Failure: String, Error, LocalizedError {
        case missing = "The active controller certificate has no supported commands policy. No experiment command was sent."
        case malformed = "The controller certificate signing policy is malformed. No experiment command was sent."
        case primary = "This certificate requires primary-key signing, which this experiment transport does not support."
        public var errorDescription: String? { rawValue }
    }
    public init(certificate: Data) throws {
        // Parse DER structurally. Never search arbitrary certificate/key bytes for
        // substrings. Only URI/IA5 fields inside an X.509 extension are eligible.
        let outer = try DER.one(Array(certificate))
        guard outer.tag == 0x30 else { throw Failure.malformed }
        let certificateFields = try outer.children()
        guard certificateFields.count == 3, certificateFields[0].tag == 0x30 else { throw Failure.malformed }
        let extensionFields = try certificateFields[0].children().filter { $0.tag == 0xa3 }
        guard extensionFields.count == 1 else { throw Failure.missing }
        let wrapper = try DER.one(extensionFields[0].bytes)
        guard wrapper.tag == 0x30 else { throw Failure.malformed }
        var policies: [String] = []
        for ext in try wrapper.children() {
            guard ext.tag == 0x30 else { throw Failure.malformed }
            let fields = try ext.children()
            guard (2...3).contains(fields.count), fields[0].tag == 6, let value = fields.last, value.tag == 4 else { throw Failure.malformed }
            // Only descend through DER containers, never binary key fields.
            if let inner = try? DER.one(value.bytes) { policies += try inner.policyStrings(depth: 0) }
        }
        guard policies.count == 1 else { throw Failure.missing }
        guard let bytes = Data(base64Encoded: policies[0]), bytes.base64EncodedString() == policies[0] else { throw Failure.malformed }
        mode = try Self.defaultMode(Array(bytes))
        certificateSHA256 = SHA256.hex(certificate)
    }
    static func defaultMode(_ bytes: [UInt8]) throws -> Mode {
        guard let first = bytes.first else { return .encrypted } // Present, explicitly empty field.
        let mode: Mode
        switch first & 3 {
        case 0: mode = .encrypted
        case 2: mode = .secondarySigned
        case 1: throw Failure.primary
        default: throw Failure.malformed
        }
        var offset = 1
        while offset < bytes.count {
            let header = bytes[offset]; offset += 1
            let width = Int(header >> 2)
            guard [1, 2, 4, 8].contains(width), header & 3 != 3, offset + width <= bytes.count else { throw Failure.malformed }
            offset += width // ID 0 uses the default; individual entries do not override it.
        }
        return mode
    }
    private struct DER {
        let tag: UInt8
        let bytes: [UInt8]
        static func one(_ input: [UInt8]) throws -> DER {
            var offset = 0; let node = try read(input, offset: &offset)
            guard offset == input.count else { throw Failure.malformed }; return node
        }
        static func read(_ input: [UInt8], offset: inout Int) throws -> DER {
            guard offset + 2 <= input.count else { throw Failure.malformed }
            let tag = input[offset]; let first = input[offset + 1]; offset += 2
            var count = Int(first)
            if first & 0x80 != 0 {
                let width = Int(first & 0x7f)
                guard (1...4).contains(width), offset + width <= input.count, input[offset] != 0 else { throw Failure.malformed }
                count = 0
                for _ in 0..<width { count = count * 256 + Int(input[offset]); offset += 1 }
                guard count >= 128 else { throw Failure.malformed }
            }
            guard count <= input.count - offset else { throw Failure.malformed }
            let node = DER(tag: tag, bytes: Array(input[offset..<(offset + count)])); offset += count
            return node
        }
        func children() throws -> [DER] {
            var result: [DER] = []; var offset = 0
            while offset < bytes.count { result.append(try Self.read(bytes, offset: &offset)) }
            return result
        }
        func policyStrings(depth: Int) throws -> [String] {
            guard depth < 12 else { throw Failure.malformed }
            if tag == 0x86 || tag == 0x16, let text = String(bytes: bytes, encoding: .ascii), text.hasPrefix("commands:") {
                return [String(text.dropFirst(9))]
            }
            if tag & 0x20 != 0 { return try children().flatMap { try $0.policyStrings(depth: depth + 1) } }
            return []
        }
    }
}
