import Foundation

enum AppUpdateChannel: String, CaseIterable, Sendable {
    case stable, development

    var title: String {
        switch self {
        case .stable: "公開版"
        case .development: "開発版"
        }
    }
}

/// Admission for an SDK callback is separate from the activity gate. In particular,
/// cached installers must still belong to the live explicit request and its channel.
/// The adapter passes its pinned owner/request channel and the verified actual offer.
/// It must separately verify the artifact and re-read installBlockReason before install.
enum AppUpdateAuthorization {
    static func allows(sessionID: UUID?, ownerSessionID: UUID?, requestedChannel: AppUpdateChannel,
                       offeredChannel: AppUpdateChannel?) -> Bool {
        guard let sessionID, let ownerSessionID, sessionID == ownerSessionID,
              let offeredChannel else { return false }
        return requestedChannel == .development || offeredChannel == .stable
    }
}

/// A value snapshot only: deciding whether an update is safe never closes a document,
/// clears a pending image, starts networking, or invokes applicationShouldTerminate.
struct AppUpdateActivity: Sendable, Equatable {
    var captureWorking = false
    var captureSelecting = false
    var capturePermissionOrGuide = false
    var retainedSingleImage = false
    var workerOccupied = false
    var resultSaving = false
    var pendingSave = false
    var annotationWorking = false
    var annotationDirty = false
    var collectionWorking = false
    var collectionNeedsConfirmation = false
    var replacementPending = false
    var confirmationVisible = false
    var recordingShortcut = false
    var installing = false

    /// A check may proceed while an idle document has unsaved content. Its eventual
    /// installation must use a fresh snapshot, because work can change during download.
    var checkBlockReason: String? { activeBlockReason(action: "確認") }

    private func activeBlockReason(action: String) -> String? {
        if installing { return "アップデートの完了を待ってから、もう一度確認してください。" }
        if captureSelecting { return "範囲選択を終えてから、アップデートを\(action)してください。" }
        if capturePermissionOrGuide { return "撮影の案内を閉じてから、アップデートを\(action)してください。" }
        if recordingShortcut { return "ショートカットの設定を確定するか取り消してから、アップデートを\(action)してください。" }
        if confirmationVisible { return "表示中の確認を終えてから、アップデートを\(action)してください。" }
        if captureWorking || workerOccupied || resultSaving || annotationWorking || collectionWorking {
            return "画像の処理が終わってから、アップデートを\(action)してください。"
        }
        return nil
    }

    var installBlockReason: String? {
        if let reason = activeBlockReason(action: "適用") { return reason }
        if pendingSave { return "まだ保存されていない画像があります。保存を再試行するか、保存せずに続けるかを選んでください。" }
        if retainedSingleImage { return "未コピーの画像があります。再コピーするか破棄してから、アップデートしてください。" }
        if annotationDirty { return "コメント・記号の変更を保存するか、編集画面を閉じてから、アップデートしてください。" }
        if replacementPending { return "撮り直しの候補を採用するか、現在の素材を残すかを決めてください。" }
        if collectionNeedsConfirmation { return "集めた画像をコピーするか、まとめ撮りの編集を終了してから、アップデートしてください。" }
        return nil
    }
}

struct CurrentAppVersion: Sendable, Equatable {
    let shortVersion: String
    let build: String
    let channel: AppUpdateChannel

    init(bundle: Bundle = .main) {
        self.init(shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "開発中",
                  build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未設定",
                  channel: (bundle.object(forInfoDictionaryKey: "OneClipUpdateChannel") as? String)
                    .flatMap(AppUpdateChannel.init(rawValue:)) ?? .development)
    }

    init(shortVersion: String, build: String, channel: AppUpdateChannel) {
        self.shortVersion = Self.displayValue(shortVersion, fallback: "開発中")
        self.build = Self.displayValue(build, fallback: "未設定")
        self.channel = channel
    }

    var displayText: String { "\(shortVersion)（build \(build)・\(channel.title)）" }

    private static func displayValue(_ value: String, fallback: String) -> String {
        let value = AppUpdateDisplayText.clean(value, maximumLength: 80)
        return value.isEmpty ? fallback : value
    }
}

enum AppUpdatePhase: String, Sendable {
    case idle, checking, updateAvailable, downloading, ready, installing, failed
}

/// The adapter maps SDK errors to fixed, user-facing messages before constructing this
/// event. It must never pass raw NSError descriptions, request URLs, or credentials.
enum AppUpdateEvent: Sendable, Equatable {
    case updateFound(version: String, channel: AppUpdateChannel)
    case downloadStarted
    case downloadFinished
    case installationStarted
    case noUpdate
    case cancelled
    case failed(message: String)
}

/// SDK version comparison stays in the updater backend. This model tracks only a
/// single explicit request and rejects callbacks for an obsolete request token.
struct AppUpdateSessionState: Sendable, Equatable {
    let currentVersion: CurrentAppVersion
    private(set) var sessionID: UUID?
    private(set) var channel = AppUpdateChannel.stable
    private(set) var phase = AppUpdatePhase.idle
    private(set) var status = "ボタンを押すと、アップデートを確認します。"
    private(set) var offeredChannel: AppUpdateChannel?
    private(set) var offeredVersion: String?

    var statusText: String { status }

    init(currentVersion: CurrentAppVersion = .init()) { self.currentVersion = currentVersion }

    @discardableResult
    mutating func begin(channel: AppUpdateChannel) -> UUID? {
        guard sessionID == nil, phase != .installing else { return nil }
        let identifier = UUID()
        sessionID = identifier
        self.channel = channel
        phase = .checking
        status = "\(channel.title)のアップデートを確認しています…"
        offeredChannel = nil
        offeredVersion = nil
        return identifier
    }

    /// Returns true when the active request handled the event. A channel-policy
    /// violation is handled as a terminal failure rather than accepted as an offer.
    @discardableResult
    mutating func receive(_ event: AppUpdateEvent, sessionID identifier: UUID) -> Bool {
        guard sessionID == identifier else { return false }
        switch event {
        case .updateFound(let version, let actualChannel):
            guard phase == .checking else { return false }
            guard channel == .development || actualChannel == .stable else {
                fail("選択した更新先に対応しない版のため、アップデートを中止しました。")
                return true
            }
            let version = AppUpdateDisplayText.clean(version, maximumLength: 80)
            guard !version.isEmpty else {
                fail("アップデートのバージョン情報を確認できませんでした。")
                return true
            }
            offeredVersion = version
            offeredChannel = actualChannel
            phase = .updateAvailable
            status = "\(actualChannel.title) \(version) にアップデートできます。"
        case .downloadStarted:
            guard phase == .updateAvailable else { return false }
            phase = .downloading
            status = "アップデートをダウンロードしています…"
        case .downloadFinished:
            guard phase == .downloading else { return false }
            phase = .ready
            status = "アップデートの準備ができました。再起動して適用できます。"
        case .installationStarted:
            // The SDK may reuse a previously downloaded and verified artifact without
            // delivering this process a fresh pair of download callbacks.
            guard phase == .updateAvailable || phase == .downloading || phase == .ready else { return false }
            phase = .installing
            status = "アップデートを適用しています…"
        case .noUpdate:
            guard phase == .checking else { return false }
            phase = .idle
            if currentVersion.channel == .development, channel == .stable {
                status = "公開版の新しい更新はありません。現在の開発版を維持します。"
            } else {
                status = "\(channel.title)の新しい更新はありません。"
            }
            clearRequest()
        case .cancelled:
            guard phase != .installing else { return false }
            phase = .idle
            status = "アップデートを取り消しました。現在のアプリを使えます。"
            clearRequest()
        case .failed(let message):
            fail(message)
        }
        return true
    }

    @discardableResult
    mutating func finish(sessionID identifier: UUID, status message: String) -> Bool {
        guard sessionID == identifier else { return false }
        phase = .idle
        let message = AppUpdateDisplayText.clean(message, maximumLength: 240)
        status = message.isEmpty ? "アップデートの確認を終了しました。" : message
        clearRequest()
        return true
    }

    @discardableResult
    mutating func updateStatus(_ message: String, sessionID identifier: UUID) -> Bool {
        guard sessionID == identifier else { return false }
        let message = AppUpdateDisplayText.clean(message, maximumLength: 240)
        guard !message.isEmpty else { return false }
        status = message
        return true
    }

    private mutating func fail(_ message: String) {
        phase = .failed
        let message = AppUpdateDisplayText.clean(message, maximumLength: 240)
        status = message.isEmpty ? "アップデートを確認できませんでした。後でもう一度お試しください。" : message
        clearRequest()
    }

    private mutating func clearRequest() {
        sessionID = nil
        offeredChannel = nil
        offeredVersion = nil
    }
}

private enum AppUpdateDisplayText {
    static func clean(_ value: String, maximumLength: Int) -> String {
        let scalars = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String(scalars.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumLength))
    }
}
