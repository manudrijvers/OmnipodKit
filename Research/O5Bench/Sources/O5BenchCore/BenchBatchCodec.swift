import Foundation

/// Application-level batch only, not a BLE/TWI packet. Restricted to the two
/// recovered G7 SET members. Binary GET replies require different framing.
enum BenchBatchCodec {
    static func request(_ members: [BenchRequest]) throws -> Data {
        guard members.count == 2, members[0] == .enable,
              members[1].body.starts(with: Data("SE4.1=".utf8)),
              members[1].body.count == 26 else { throw BenchError.reply }
        return members[0].body + Data([0x2c]) + members[1].body
    }
    static func replies(_ envelope: Data) throws -> [Data] {
        // These result bodies are canonical decimal ASCII codes, not binary
        // attribute bodies, so delimiter splitting is safe for this narrow schema.
        let members = Array(envelope).split(separator: UInt8(0x2c), omittingEmptySubsequences: false).map { Data($0) }
        guard members.count == 2, members[0].starts(with: Data("ES4.2=".utf8)),
              members[1].starts(with: Data("ES4.1=".utf8)) else { throw BenchError.reply }
        return members
    }
}
