import Foundation

/// Deterministic test fixtures for the agent CLI, plus the production guard.
/// `seed` and `reset` only ever run against an explicitly supplied test root:
/// the default (real) root is refused, and `reset` additionally requires the
/// marker file that `seed` plants. Fixture file names, IDs and contents are
/// fixed so repeated runs produce identical state.
public enum TestFixtures {
    public static let markerName = ".oneclip-agent-test-root"

    /// 1x1 transparent PNG.
    public static let pngData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!

    public static let fileNames = [
        "OneClip-2026-01-01-100000-11111111-1111-4111-8111-111111111111.png",
        "OneClip-2026-01-01-100100-22222222-2222-4222-8222-222222222222.png",
        "OneClip-2026-01-01-100200-33333333-3333-4333-8333-333333333333.png",
        "OneClip-2026-01-01-100000-11111111-1111-4111-8111-111111111111-edited-44444444-4444-4444-8444-444444444444.png",
    ]

    public static func guardNotDefaultRoot(_ store: ArchiveStore) throws {
        if store.isDefaultRoot {
            throw AgentError(code: .productionGuard,
                             message: "Refusing to run against the real OneClip data root. Pass --root <test-dir> explicitly.",
                             exitCode: .permission)
        }
    }

    public static func seed(store: ArchiveStore) throws -> (created: [String], skipped: [String]) {
        try guardNotDefaultRoot(store)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: store.capturesDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: store.agentDirectory, withIntermediateDirectories: true)
            let marker = store.root.appendingPathComponent(markerName)
            if !fileManager.fileExists(atPath: marker.path) {
                try "oneclip-agent test root\n".write(to: marker, atomically: true, encoding: .utf8)
            }
        } catch {
            throw AgentError.permission("Cannot prepare the test root: \(error.localizedDescription)")
        }
        var created: [String] = []
        var skipped: [String] = []
        for name in fileNames {
            let url = store.capturesDirectory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                skipped.append(name)
                continue
            }
            do {
                try pngData.write(to: url)
                if let parsed = ArchiveStore.parse(fileName: name),
                   let date = ArchiveStore.timestampFormatter.date(from: parsed.timestamp) {
                    try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
                }
                created.append(name)
            } catch {
                throw AgentError.appFailure("Cannot write fixture \(name): \(error.localizedDescription)")
            }
        }
        return (created, skipped)
    }

    public static func reset(store: ArchiveStore) throws -> Int {
        try guardNotDefaultRoot(store)
        let marker = store.root.appendingPathComponent(markerName)
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw AgentError(code: .productionGuard,
                             message: "Refusing to reset: \(markerName) not found in the given root. Only roots created by `seed` can be reset.",
                             exitCode: .permission)
        }
        var removed = 0
        for directory in [store.capturesDirectory, store.agentDirectory] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                removed += 1
            }
        }
        return removed
    }
}
