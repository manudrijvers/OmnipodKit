import XCTest
@testable import O5BenchCore

final class BenchClockMetadataTests: XCTestCase {
    func testPhysicalExportPreservesDistinctClockEpochsWithoutInventingElapsedGap() throws {
        let transport = FakeBenchTransport(clock: BenchClock(id: "epoch-A"))
        var session = BenchSession(id: "test-session", target: transport.target, revisions: [:],
            activationProvenance: "synthetic fixture", clockID: transport.clock.id)
        session.physical = true
        session.events = [
            BenchEvent(time: BenchStamp(wall: Date(timeIntervalSince1970: 100), monotonic: 20,
                processUptime: 1000, clockID: "epoch-A"), kind: "before-close", fields: [:]),
            BenchEvent(time: BenchStamp(wall: Date(timeIntervalSince1970: 132), monotonic: 24,
                processUptime: 1032, clockID: "epoch-B"), kind: "after-reopen", fields: [:])
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try BenchExport.write(session, to: directory, redacted: true)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("manifest.json"))) as? [String: Any])
        let metadata = try XCTUnwrap(manifest["clockMetadata"] as? [String: String])
        XCTAssertEqual(metadata["epochField"], "clockID")
        XCTAssertEqual(metadata["elapsedScope"], "one BenchClock instance; compare only stamps with the same clockID")
        XCTAssertEqual(metadata["uptimeSource"], "ProcessInfo.processInfo.systemUptime; boot epoch not recorded")
        XCTAssertTrue(metadata["physicalReopen"]?.contains("missing wall interval excluded") == true)
        let lines = try String(contentsOf: directory.appendingPathComponent("events.ndjson"), encoding: .utf8)
            .split(separator: "\n")
        let stamps = try lines.map { line -> [String: Any] in
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try XCTUnwrap(event["time"] as? [String: Any])
        }
        XCTAssertEqual(stamps.count, 2)
        XCTAssertEqual(stamps[0]["clockID"] as? String, "epoch-A")
        XCTAssertEqual(stamps[1]["clockID"] as? String, "epoch-B")
        XCTAssertEqual(stamps[0]["monotonicSeconds"] as? Double, 20)
        XCTAssertEqual(stamps[1]["monotonicSeconds"] as? Double, 24)
        XCTAssertEqual(stamps[0]["processUptimeSeconds"] as? Double, 1000)
        XCTAssertEqual(stamps[1]["processUptimeSeconds"] as? Double, 1032)
        XCTAssertEqual(stamps[0]["wallUTC"] as? String, "1970-01-01T00:01:40Z")
        XCTAssertEqual(stamps[1]["wallUTC"] as? String, "1970-01-01T00:02:12Z")
        XCTAssertFalse(manifest["physicalWritesEnabled"] as? Bool ?? true)
    }

    func testVirtualExportDoesNotClaimMeasuredPhysicalElapsedTime() throws {
        let transport = FakeBenchTransport(clock: BenchClock())
        let session = BenchSession(id: "virtual-fixture", target: transport.target, revisions: [:],
            activationProvenance: "synthetic fixture", clockID: transport.clock.id)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try BenchExport.write(session, to: directory, redacted: true)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("manifest.json"))) as? [String: Any])
        let metadata = try XCTUnwrap(manifest["clockMetadata"] as? [String: String])
        XCTAssertEqual(metadata["elapsedScope"], "virtual clock; not measured physical duration")
        XCTAssertEqual(manifest["synthetic"] as? Bool, true)
    }
}
