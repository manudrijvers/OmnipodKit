// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "O5Bench", platforms: [.macOS(.v13), .iOS(.v16)], products: [
    .library(name: "O5BenchCore", targets: ["O5BenchCore"]),
    .executable(name: "o5-bench", targets: ["o5-bench"])
], targets: [
    .target(name: "O5BenchCore", resources: [.process("Resources")]),
    .executableTarget(name: "o5-bench", dependencies: ["O5BenchCore"]),
    .testTarget(name: "O5BenchCoreTests", dependencies: ["O5BenchCore"])
])
