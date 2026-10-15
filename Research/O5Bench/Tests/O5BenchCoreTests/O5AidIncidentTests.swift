import XCTest
@testable import O5BenchCore

/// Optional replay of the owner's private exported log. Nothing is sent, and
/// identifiers/response bodies are not printed or copied into test fixtures.
final class O5AidIncidentTests: XCTestCase {
    func testProvidedIncidentExport() throws {
        guard let path = ProcessInfo.processInfo.environment["O5_INCIDENT_LOG"] else {
            throw XCTSkip("Set O5_INCIDENT_LOG to replay the private Trio NDJSON export")
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var checked = 0
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["eventMessage"] as? String,
                  message.hasPrefix("O5 AID RawResp:"),
                  let range = message.range(of: "hex="),
                  let hex = message[range.upperBound...].split(separator: " ").first,
                  let packet = Data(hexadecimalString: String(hex)),
                  let prefixRange = message.range(of: "expectPrefix=") else { continue }
            let prefix = String(message[prefixRange.upperBound...])
            guard packet.starts(with: Data(prefix.utf8)) else { return XCTFail("Unexpected response framing") }
            let body = packet.dropFirst(prefix.utf8.count)
            switch prefix {
            case "4.2=":
                let status = try O5CgmInterfaceStatus(body)
                XCTAssertEqual(status.control, 255); XCTAssertEqual(status.desiredSensorType, 0)
            case "4.1=": XCTAssertTrue(try O5G7SensorInfo(body).isEmpty)
            case "3.12=":
                let status = try O5UnifiedAidStatus(body)
                XCTAssertTrue(status.isManual); XCTAssertTrue(status.algorithmReady)
                XCTAssertNil(status.egv); XCTAssertNil(status.iobMicroUnits)
            case "ES4.2=", "ES4.1=": try O5AidResponseValidation.extendedSet(body, command: prefix)
            default: continue
            }
            checked += 1
        }
        XCTAssertEqual(checked, 5, "Expected three reads and two SET acknowledgements")
    }
}
