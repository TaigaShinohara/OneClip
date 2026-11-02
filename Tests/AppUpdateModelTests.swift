import Foundation

/// Pure request-state and admission tests. No updater SDK, networking, application
/// launch, screen access, pasteboard, user preferences, signing keys, or installation.
@main
struct AppUpdateModelTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static let development = CurrentAppVersion(shortVersion: "0.2.0-dev", build: "12", channel: .development)

    static func main() throws {
        let groups: [(String, () throws -> Void)] = [
            ("UPDATE-MODEL-01 current version and explicit channel are displayed without comparison", testVersion),
            ("UPDATE-MODEL-02 checking preserves unsaved work while installation is blocked", testUnsavedWork),
            ("UPDATE-MODEL-03 active UI and workers block checks without changing their state", testActiveWork),
            ("UPDATE-MODEL-04 one request locks its channel and records the offered channel", testChannel),
            ("UPDATE-MODEL-05 transitions require the live token and correct phase", testTransitions),
            ("UPDATE-MODEL-06 failed or unavailable feeds are not reported as latest", testFailuresAndNoUpdate),
            ("UPDATE-MODEL-07 cancellation and completion reject late callbacks", testCompletion),
            ("UPDATE-MODEL-08 bundle metadata has an explicit development fallback", testBundleMetadata),
            ("UPDATE-MODEL-09 cached installation requires the live owner and requested channel", testCachedAuthorization)
        ]
        for (name, body) in groups { try body(); print("PASS \(name)") }
        print("PASS \(groups.count) manual update model groups; value snapshots and temporary metadata only")
    }

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(description: message) }
    }

    static func testVersion() throws {
        try expect(AppUpdateChannel.allCases.map(\.rawValue) == ["stable", "development"], "Unexpected update channel")
        try expect(development.displayText.contains("0.2.0-dev") && development.displayText.contains("12")
                   && development.displayText.contains("開発版"), "Development version is not explicit")
        let stable = CurrentAppVersion(shortVersion: "1.0.0", build: "100", channel: .stable)
        try expect(stable.displayText.contains("公開版"), "Stable version was mislabeled")
        let empty = CurrentAppVersion(shortVersion: "\n", build: "\t", channel: .development)
        try expect(empty.shortVersion == "開発中" && empty.build == "未設定", "Empty build metadata was presented as a real version")
    }

    static func testUnsavedWork() throws {
        let dirtyProperties: [WritableKeyPath<AppUpdateActivity, Bool>] = [
            \.retainedSingleImage, \.pendingSave, \.annotationDirty, \.collectionNeedsConfirmation, \.replacementPending
        ]
        try expect(AppUpdateActivity().checkBlockReason == nil && AppUpdateActivity().installBlockReason == nil,
                   "An idle app cannot check or install")
        for property in dirtyProperties {
            var activity = AppUpdateActivity()
            activity[keyPath: property] = true
            let original = activity
            try expect(activity.checkBlockReason == nil, "Idle unsaved content blocked a read-only check")
            try expect(activity.installBlockReason != nil, "Installation could discard unresolved content")
            try expect(activity == original, "Checking admission changed an unsaved document")
        }
        var beforeDownload = AppUpdateActivity()
        try expect(beforeDownload.installBlockReason == nil, "Idle installation was unexpectedly blocked")
        beforeDownload.annotationDirty = true
        try expect(beforeDownload.installBlockReason != nil, "Install admission did not re-read changes made during download")
    }

    static func testActiveWork() throws {
        let activeProperties: [WritableKeyPath<AppUpdateActivity, Bool>] = [
            \.captureWorking, \.captureSelecting, \.capturePermissionOrGuide, \.workerOccupied, \.resultSaving,
            \.annotationWorking, \.collectionWorking, \.confirmationVisible, \.recordingShortcut, \.installing
        ]
        for property in activeProperties {
            var activity = AppUpdateActivity()
            activity[keyPath: property] = true
            let original = activity
            try expect(activity.checkBlockReason != nil && activity.installBlockReason != nil,
                       "An active operation allowed update UI or replacement")
            try expect(activity == original, "Update admission changed a worker or confirmation")
        }
    }

    static func testChannel() throws {
        var state = AppUpdateSessionState(currentVersion: development)
        guard let token = state.begin(channel: .development) else { throw Failure(description: "Explicit check did not begin") }
        try expect(state.begin(channel: .stable) == nil && state.channel == .development && state.sessionID == token,
                   "A second click changed the live request channel")
        try expect(state.receive(.updateFound(version: "1.0", channel: .stable), sessionID: token), "Stable fallback was rejected for a development request")
        try expect(state.channel == .development && state.offeredChannel == .stable && state.offeredVersion == "1.0"
                   && state.status.contains("公開版"), "Requested channel was confused with the offered channel")
        state = AppUpdateSessionState(currentVersion: development)
        let stableToken = state.begin(channel: .stable)!
        _ = state.receive(.updateFound(version: "2.0-dev", channel: .development), sessionID: stableToken)
        try expect(state.phase == .failed && state.sessionID == nil && state.offeredVersion == nil,
                   "A stable-only request accepted a development release")
    }

    static func testTransitions() throws {
        var state = AppUpdateSessionState(currentVersion: development)
        let token = state.begin(channel: .development)!
        try expect(!state.receive(.installationStarted, sessionID: token) && state.phase == .checking,
                   "An install began before download readiness")
        try expect(!state.receive(.updateFound(version: "9", channel: .development), sessionID: UUID()),
                   "A stale offer mutated the request")
        _ = state.receive(.updateFound(version: "0.3", channel: .development), sessionID: token)
        try expect(!state.receive(.downloadFinished, sessionID: token) && state.phase == .updateAvailable,
                   "A completed download was accepted before it started")
        _ = state.receive(.downloadStarted, sessionID: token)
        _ = state.receive(.downloadFinished, sessionID: token)
        try expect(state.phase == .ready && state.sessionID == token, "Download readiness lost its request identity")
        _ = state.receive(.installationStarted, sessionID: token)
        try expect(state.phase == .installing && !state.receive(.cancelled, sessionID: token),
                   "A replacement was cancelled after installation started")
        var cached = AppUpdateSessionState(currentVersion: development)
        let cachedToken = cached.begin(channel: .stable)!
        _ = cached.receive(.updateFound(version: "1.0", channel: .stable), sessionID: cachedToken)
        try expect(cached.receive(.installationStarted, sessionID: cachedToken) && cached.phase == .installing,
                   "A verified cached artifact required artificial download callbacks")
    }

    static func testFailuresAndNoUpdate() throws {
        var state = AppUpdateSessionState(currentVersion: development)
        let token = state.begin(channel: .stable)!
        _ = state.receive(.noUpdate, sessionID: token)
        try expect(state.phase == .idle && state.sessionID == nil && state.status.contains("現在の開発版を維持"),
                   "Stable no-update implied replacing or downgrading a development build")
        for message in ["更新先が設定されていません。", "更新情報がまだ公開されていません。", "通信できませんでした。", "更新情報の署名を確認できませんでした。"] {
            let next = state.begin(channel: .stable)!
            _ = state.receive(.failed(message: message), sessionID: next)
            try expect(state.phase == .failed && state.sessionID == nil && !state.status.contains("最新版"),
                       "A missing or failed feed was reported as up to date")
        }
        let bad = state.begin(channel: .stable)!
        _ = state.receive(.updateFound(version: "\n", channel: .stable), sessionID: bad)
        try expect(state.phase == .failed, "An empty release version was presented as an update")
    }

    static func testCompletion() throws {
        var state = AppUpdateSessionState(currentVersion: development)
        let first = state.begin(channel: .stable)!
        _ = state.receive(.cancelled, sessionID: first)
        let second = state.begin(channel: .development)!
        try expect(first != second, "A new explicit request reused the previous token")
        let current = state
        try expect(!state.receive(.failed(message: "old"), sessionID: first)
                   && !state.finish(sessionID: first, status: "old")
                   && !state.updateStatus("old", sessionID: first) && state == current,
                   "A late completion changed a newer request")
        try expect(state.updateStatus("画像の保存を待っています。", sessionID: second)
                   && state.statusText == "画像の保存を待っています。" && state.phase == .checking,
                   "A token-bound status update changed the request phase or failed to explain a delay")
        try expect(state.finish(sessionID: second, status: "確認を終了しました。") && state.phase == .idle && state.sessionID == nil,
                   "A valid completion did not close its request")
        try expect(!state.receive(.noUpdate, sessionID: second), "A finished session accepted a late callback")
        let third = state.begin(channel: .stable)!
        _ = state.receive(.failed(message: "\n\t"), sessionID: third)
        try expect(!state.status.isEmpty && !state.status.contains("\n"), "A blank error produced no useful fixed fallback")
    }

    static func testCachedAuthorization() throws {
        let owner = UUID()
        for requested in AppUpdateChannel.allCases {
            for offered in AppUpdateChannel.allCases {
                let permitted = AppUpdateAuthorization.allows(sessionID: owner, ownerSessionID: owner,
                    requestedChannel: requested, offeredChannel: offered)
                try expect(permitted == (requested == .development || offered == .stable),
                           "A cached offer bypassed the selected request channel")
            }
        }
        try expect(!AppUpdateAuthorization.allows(sessionID: owner, ownerSessionID: owner,
                       requestedChannel: .stable, offeredChannel: .development),
                   "A development artifact cached by the SDK escaped a public-only request")
        try expect(AppUpdateAuthorization.allows(sessionID: owner, ownerSessionID: owner,
                       requestedChannel: .development, offeredChannel: .stable),
                   "A development request lost the normal public-release fallback")
        try expect(!AppUpdateAuthorization.allows(sessionID: nil, ownerSessionID: nil,
                       requestedChannel: .stable, offeredChannel: .stable)
                   && !AppUpdateAuthorization.allows(sessionID: owner, ownerSessionID: nil,
                       requestedChannel: .stable, offeredChannel: .stable)
                   && !AppUpdateAuthorization.allows(sessionID: nil, ownerSessionID: owner,
                       requestedChannel: .stable, offeredChannel: .stable)
                   && !AppUpdateAuthorization.allows(sessionID: owner, ownerSessionID: owner,
                       requestedChannel: .development, offeredChannel: nil),
                   "Missing request identity or unknown offer channel authorized an install")
        try expect(!AppUpdateAuthorization.allows(sessionID: owner, ownerSessionID: UUID(),
                       requestedChannel: .stable, offeredChannel: .stable),
                   "A different SDK instance authorized another request")

        for terminal in [AppUpdateEvent.noUpdate, .cancelled, .failed(message: "更新情報を確認できませんでした。")] {
            var ended = AppUpdateSessionState(currentVersion: development)
            let endedOwner = ended.begin(channel: .development)!
            _ = ended.receive(terminal, sessionID: endedOwner)
            try expect(ended.sessionID == nil
                       && !AppUpdateAuthorization.allows(sessionID: ended.sessionID, ownerSessionID: endedOwner,
                           requestedChannel: .development, offeredChannel: .development),
                       "A cached callback revived a terminal model request")
            let replacementOwner = ended.begin(channel: .stable)!
            try expect(replacementOwner != endedOwner
                       && !AppUpdateAuthorization.allows(sessionID: ended.sessionID, ownerSessionID: endedOwner,
                           requestedChannel: .development, offeredChannel: .stable),
                       "An old SDK owner authorized a newly started request")
        }

        // Sparkle can ask shouldRelaunch before shouldPostpone for a cached update.
        // The first hook checks only request identity. The latter re-reads activity;
        // neither hook may consume the request or make dirty work disappear.
        var state = AppUpdateSessionState(currentVersion: development)
        let activeOwner = state.begin(channel: .stable)!
        _ = state.receive(.updateFound(version: "1.0", channel: .stable), sessionID: activeOwner)
        let beforeHooks = state
        let shouldRelaunch = AppUpdateAuthorization.allows(sessionID: state.sessionID, ownerSessionID: activeOwner,
            requestedChannel: .stable, offeredChannel: state.offeredChannel)
        var activity = AppUpdateActivity(annotationDirty: true)
        let shouldPostpone = activity.installBlockReason != nil
        try expect(shouldRelaunch && shouldPostpone && state == beforeHooks,
                   "SDK hook order either discarded the valid owner or bypassed dirty work")
        activity.annotationDirty = false
        try expect(activity.installBlockReason == nil
                   && AppUpdateAuthorization.allows(sessionID: state.sessionID, ownerSessionID: activeOwner,
                       requestedChannel: .stable, offeredChannel: state.offeredChannel),
                   "Resolving dirty work did not preserve the admitted cached update")
        _ = state.receive(.installationStarted, sessionID: activeOwner)
        try expect(state.phase == .installing
                   && AppUpdateAuthorization.allows(sessionID: state.sessionID, ownerSessionID: activeOwner,
                       requestedChannel: .stable, offeredChannel: state.offeredChannel),
                   "A cached install lost its authenticated owner before replacement")
        _ = state.finish(sessionID: activeOwner, status: "更新セッションを終了しました。")
        try expect(!AppUpdateAuthorization.allows(sessionID: state.sessionID, ownerSessionID: activeOwner,
                       requestedChannel: .stable, offeredChannel: .stable),
                   "A finished request still authorized its cached installer")
    }

    static func testBundleMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OneClip-UpdateModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, rawChannel) in [nil, "unexpected", "stable", "development"].enumerated() {
            let directory = root.appendingPathComponent("fixture-\(index).bundle")
            let contents = directory.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var metadata: [String: Any] = ["CFBundleIdentifier": "local.OneClip.UpdateModelFixture\(index)",
                "CFBundlePackageType": "BNDL", "CFBundleShortVersionString": "0.5.0", "CFBundleVersion": "42"]
            if let rawChannel { metadata["OneClipUpdateChannel"] = rawChannel }
            let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            guard let bundle = Bundle(url: directory) else { throw Failure(description: "Test metadata bundle could not be loaded") }
            let version = CurrentAppVersion(bundle: bundle)
            let expected: AppUpdateChannel = rawChannel == "stable" ? .stable : .development
            try expect(version.shortVersion == "0.5.0" && version.build == "42" && version.channel == expected,
                       "Installed build metadata lost its explicit or conservative channel")
        }
    }
}
