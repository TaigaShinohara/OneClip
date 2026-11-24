import XCTest
@testable import OneClipAgentCore

final class OneClipAgentCoreTests: XCTestCase {
    private var tempRoot: URL!
    private var store: ArchiveStore!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("oneclip-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = ArchiveStore(root: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private var deadline: AgentDeadline { AgentDeadline(timeoutSeconds: 10) }

    func testParseOriginalName() {
        let parsed = ArchiveStore.parse(fileName: "OneClip-2026-01-01-100000-11111111-1111-4111-8111-111111111111.png")
        XCTAssertEqual(parsed?.id, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(parsed?.kind, "original")
        XCTAssertEqual(parsed?.timestamp, "2026-01-01-100000")
    }

    func testParseEditedName() {
        let parsed = ArchiveStore.parse(fileName: "OneClip-2026-01-01-100000-11111111-1111-4111-8111-111111111111-edited-44444444-4444-4444-8444-444444444444.png")
        XCTAssertEqual(parsed?.id, "44444444-4444-4444-8444-444444444444")
        XCTAssertEqual(parsed?.kind, "edited")
    }

    func testParseRejectsForeignNames() {
        XCTAssertNil(ArchiveStore.parse(fileName: "screenshot.png"))
        XCTAssertNil(ArchiveStore.parse(fileName: "OneClip-notadate-11111111-1111-4111-8111-111111111111.png"))
        XCTAssertNil(ArchiveStore.parse(fileName: "OneClip-2026-01-01-100000-not-a-uuid.png"))
        XCTAssertNil(ArchiveStore.parse(fileName: "OneClip-2026-01-01-100000-11111111-1111-4111-8111-111111111111.jpg"))
    }

    func testSeedScanExportDelete() throws {
        let seeded = try TestFixtures.seed(store: store)
        XCTAssertEqual(seeded.created.count, 4)

        let scan = try store.scan(deadline: deadline)
        XCTAssertEqual(scan.items.count, 4)
        XCTAssertEqual(scan.items.filter { $0.kind == "edited" }.count, 1)
        XCTAssertTrue(scan.nonconformingNames.isEmpty)

        let first = try store.item(id: "11111111-1111-4111-8111-111111111111", deadline: deadline)
        XCTAssertTrue(store.hasValidPNGSignature(first))

        let destination = tempRoot.appendingPathComponent("out", isDirectory: true)
        let exported = try store.export(item: first, toDirectory: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
        XCTAssertThrowsError(try store.export(item: first, toDirectory: destination)) { error in
            XCTAssertEqual((error as? AgentError)?.code, .conflict)
        }

        let trashPath = try store.quarantine(item: first)
        XCTAssertTrue(trashPath.hasPrefix(".trash/"))
        let after = try store.scan(deadline: deadline)
        XCTAssertEqual(after.items.count, 3)
        XCTAssertEqual(store.trashedCount(), 1)
    }

    func testSeedRefusesDefaultRoot() {
        let defaultStore = ArchiveStore(root: nil)
        XCTAssertThrowsError(try TestFixtures.seed(store: defaultStore)) { error in
            XCTAssertEqual((error as? AgentError)?.code, .productionGuard)
        }
    }

    func testSeedRefusesHomeEnvRoot() {
        // When $HOME and the passwd home disagree, both count as the real root.
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else { return }
        let envRoot = URL(fileURLWithPath: home).appendingPathComponent("Library", isDirectory: true)
        let store = ArchiveStore(root: envRoot)
        XCTAssertTrue(store.isDefaultRoot)
        XCTAssertThrowsError(try TestFixtures.seed(store: store)) { error in
            XCTAssertEqual((error as? AgentError)?.code, .productionGuard)
        }
    }

    func testResetRequiresSeedMarker() throws {
        XCTAssertThrowsError(try TestFixtures.reset(store: store)) { error in
            XCTAssertEqual((error as? AgentError)?.code, .productionGuard)
        }
        _ = try TestFixtures.seed(store: store)
        let removed = try TestFixtures.reset(store: store)
        XCTAssertGreaterThan(removed, 0)
        let scan = try store.scan(deadline: deadline)
        XCTAssertEqual(scan.items.count, 0)
    }

    func testHistoryRoundTripAndIdempotencyLookup() {
        let history = HistoryStore(store: store)
        history.append(command: "export", requestID: "req-1", ok: true, errorCode: nil,
                       idempotencyKey: "key-1",
                       summary: .object([("id", .string("abc")), ("destination", .string("/tmp/x.png"))]))
        history.append(command: "delete", requestID: "req-2", ok: false, errorCode: "not_found",
                       idempotencyKey: nil, summary: nil)
        let result = history.entries(limit: 0)
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.skippedLines, 0)
        let hit = history.successfulEntry(idempotencyKey: "key-1", command: "export")
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.summary, .object([("destination", .string("/tmp/x.png")), ("id", .string("abc"))]))
        XCTAssertNil(history.successfulEntry(idempotencyKey: "key-1", command: "delete"))
    }

    func testPreferencesRendering() throws {
        let preferencesDir = tempRoot.appendingPathComponent("Preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: preferencesDir, withIntermediateDirectories: true)
        let domain: [String: Any] = [
            "OneClip.hasSeenWelcome": true,
            "OneClip.singleCaptureHotKey.v1": Data([0x01, 0x02, 0x03]),
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0)
        try data.write(to: preferencesDir.appendingPathComponent("local.OneClip.plist"))

        let reader = PreferencesReader(store: store)
        XCTAssertTrue(reader.domainExists(bundleID: "local.OneClip"))
        let loaded = try reader.loadDomain(bundleID: "local.OneClip")
        XCTAssertEqual(PreferencesReader.render(value: loaded["OneClip.hasSeenWelcome"]!), .bool(true))
        XCTAssertEqual(PreferencesReader.render(value: loaded["OneClip.singleCaptureHotKey.v1"]!),
                       .object([("present", .bool(true)), ("bytes", .int(3)), ("type", .string("data"))]))
        XCTAssertThrowsError(try reader.loadDomain(bundleID: "com.example.missing")) { error in
            XCTAssertEqual((error as? AgentError)?.exitCode, .notFound)
        }
    }

    func testEnvelopeShapes() {
        let success = AgentEnvelope.success(data: .object([("a", .int(1))]), requestID: "req")
        let successObject = try? JSONSerialization.jsonObject(with: success) as? [String: Any]
        XCTAssertEqual(successObject?["ok"] as? Bool, true)
        XCTAssertEqual((successObject?["meta"] as? [String: Any])?["schema_version"] as? Int, 1)

        let failure = AgentEnvelope.failure(error: .notFound("missing"), requestID: "req")
        let failureObject = try? JSONSerialization.jsonObject(with: failure) as? [String: Any]
        XCTAssertEqual(failureObject?["ok"] as? Bool, false)
        XCTAssertEqual((failureObject?["error"] as? [String: Any])?["code"] as? String, "not_found")
    }

    func testItemNotFound() {
        XCTAssertThrowsError(try store.item(id: "99999999-9999-4999-8999-999999999999", deadline: deadline)) { error in
            XCTAssertEqual((error as? AgentError)?.exitCode, .notFound)
        }
    }
}
