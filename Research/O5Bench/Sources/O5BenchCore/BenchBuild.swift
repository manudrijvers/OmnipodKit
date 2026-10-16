import Foundation

enum BenchBuild {
    static var revisions: [String: String] {
        guard let url = Bundle.module.url(forResource: "source-checksums", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revisions = object["revisions"] as? [String: String] else {
            return ["runnerSourceSHA256": "unavailable"]
        }
        return revisions
    }
}
