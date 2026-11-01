import Foundation

enum BenchBuild {
    static var revisions: [String: String] {
        let source: [String: String]
        if let url = Bundle.module.url(forResource: "source-checksums", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let revisions = object["revisions"] as? [String: String] {
            source = revisions
        } else { source = ["runnerSourceSHA256": "unavailable"] }
        let details = Bundle.main.url(forResource: "BuildDetails", withExtension: "plist")
            .flatMap { try? Data(contentsOf: $0) }
        return revisions(source: source, buildDetails: details, hostBuild:
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    /// Historical source baselines are not the installed app/submodule revisions.
    /// Preserve the build-generated values verbatim (currently abbreviated SHAs).
    static func revisions(source: [String: String], buildDetails: Data?, hostBuild: String?) -> [String: String] {
        var result = source
        let details = buildDetails.flatMap {
            (try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)) as? [String: Any]
        } ?? [:]
        let modules = details["com-trio-submodules"] as? [String: [String: Any]]
        result["hostBuild"] = hostBuild ?? "unknown"
        result["hostTrioCommitSHA"] = details["com-trio-commit-sha"] as? String ?? "unknown"
        result["hostTrioBranch"] = details["com-trio-branch"] as? String ?? "unknown"
        result["hostBuildDate"] = details["com-trio-build-date"] as? String ?? "unknown"
        result["hostOmnipodKitCommitSHA"] = modules?["OmnipodKit"]?["commit_sha"] as? String ?? "unknown"
        result["hostOmnipodKitBranch"] = modules?["OmnipodKit"]?["branch"] as? String ?? "unknown"
        result["hostRevisionSource"] = "BuildDetails.plist; unknown means missing, not inferred from source baselines"
        return result
    }
}
