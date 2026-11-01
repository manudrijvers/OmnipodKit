import XCTest
@testable import O5BenchCore

final class BenchBuildTests: XCTestCase {
    func testInstalledRevisionsComeFromRealBuildDetailsKeys() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "com-trio-commit-sha": "3a06656", "com-trio-branch": "trio-o5-dex-direct",
            "com-trio-build-date": "Mon Oct 19 12:00:00 UTC 2026",
            "com-trio-submodules": ["OmnipodKit": ["branch": "detached", "commit_sha": "b62fbb1"]]
        ], format: .xml, options: 0)
        let revisions = BenchBuild.revisions(source: ["TrioBase": "80b79cb", "OmnipodKitBase": "363f75a"],
            buildDetails: data, hostBuild: "1")
        XCTAssertEqual(revisions["hostTrioCommitSHA"], "3a06656")
        XCTAssertEqual(revisions["hostTrioBranch"], "trio-o5-dex-direct")
        XCTAssertEqual(revisions["hostOmnipodKitCommitSHA"], "b62fbb1")
        XCTAssertEqual(revisions["hostOmnipodKitBranch"], "detached")
        XCTAssertEqual(revisions["hostBuild"], "1")
        XCTAssertEqual(revisions["TrioBase"], "80b79cb")
        XCTAssertEqual(revisions["OmnipodKitBase"], "363f75a")
    }
    func testMissingOrMalformedMetadataNeverUsesBaselineAsCurrentRevision() throws {
        let malformed = try PropertyListSerialization.data(fromPropertyList: [
            "com-trio-commit-sha": 123, "com-trio-submodules": ["OmnipodKit": "invalid"]
        ], format: .binary, options: 0)
        for data in [nil, Data("bad".utf8), malformed] {
            let revisions = BenchBuild.revisions(source: ["TrioBase": "old", "OmnipodKitBase": "old"],
                buildDetails: data, hostBuild: nil)
            XCTAssertEqual(revisions["hostTrioCommitSHA"], "unknown")
            XCTAssertEqual(revisions["hostOmnipodKitCommitSHA"], "unknown")
            XCTAssertEqual(revisions["hostBuild"], "unknown")
        }
    }
}
