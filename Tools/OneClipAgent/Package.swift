// swift-tools-version: 5.9
import PackageDescription

// OneClipAgent is a standalone companion CLI for OneClip's saved-data store.
// It is intentionally NOT part of the Xcode project: the app and the Store
// build are unaffected. The CLI shares the app's on-disk contract (archive
// location, filename grammar, stable IDs) — see docs/AGENT_OPERATIONS.md.
let package = Package(
    name: "OneClipAgent",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OneClipAgentCore", targets: ["OneClipAgentCore"]),
        .executable(name: "oneclip-agent", targets: ["OneClipAgentCLI"]),
    ],
    targets: [
        .target(name: "OneClipAgentCore"),
        .executableTarget(name: "OneClipAgentCLI", dependencies: ["OneClipAgentCore"]),
        .testTarget(name: "OneClipAgentCoreTests", dependencies: ["OneClipAgentCore"]),
    ]
)
