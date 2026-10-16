import Foundation

/// Narrow recovered post-provision group. Lengths, not delimiter searches,
/// delimit binary replies, which may themselves contain commas or ASCII headers.
public enum O5BenchReadBatchCodec {
    public static func request(legacyMessage: Data) throws -> Data {
        guard legacyMessage.count == 11 else { throw BenchError.reply }
        return Data("G3.12,S0.0=".utf8) + Data([0, 11]) + legacyMessage + Data(",G0.0".utf8)
    }
    public static func replies(_ envelope: Data) throws -> (aid: Data, legacyMessage: Data) {
        let bytes = Array(envelope)
        var offset = 0
        func consume(_ prefix: String) throws {
            let expected = Array(prefix.utf8)
            guard offset + expected.count <= bytes.count,
                  Array(bytes[offset..<(offset + expected.count)]) == expected else { throw BenchError.reply }
            offset += expected.count
        }
        func body() throws -> Data {
            guard offset + 2 <= bytes.count else { throw BenchError.reply }
            let start = offset
            let length = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
            offset += 2
            guard length <= 32767, offset + length <= bytes.count else { throw BenchError.reply }
            offset += length
            return Data(bytes[start..<offset])
        }
        try consume("3.12=")
        let aid = try body()
        _ = try O5UnifiedAidStatus(aid)
        try consume(",0.0=")
        let legacy = try body()
        guard offset == bytes.count else { throw BenchError.reply }
        return (Data("3.12=".utf8) + aid, Data(legacy.dropFirst(2)))
    }
}
