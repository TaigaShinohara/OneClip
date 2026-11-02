import AppKit
import Combine
import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

/// Manual update requests are isolated from capture data and from each other.
/// Construction does not create or start Sparkle, perform networking, or alter defaults.
@MainActor
final class AppUpdateController: NSObject, ObservableObject {
    static let shared = AppUpdateController()
    @Published private(set) var state: AppUpdateSessionState
    @Published private(set) var isInstalling = false {
        willSet {
            if newValue != isInstalling { installationLockWillChange() }
        }
    }
    @Published private var statusOverride: String?
    let currentVersion: CurrentAppVersion
    var activityProvider: @MainActor () -> AppUpdateActivity = { AppUpdateActivity() }
    // Drop queued input synchronously on both sides of the install transition.
    var installationLockWillChange: @MainActor () -> Void = {}

    private let bundle: Bundle
    // The SDK owner survives a model terminal event until the SDK reports its own
    // termination. Authorization additionally requires the live model token.
    private var activeSessionID: UUID?
    private var requestedChannel = AppUpdateChannel.stable
    private var hasDownloadedUpdate = false
    private var updateTerminationExpected = false
    private var deferredInstall: (() -> Void)?
    #if canImport(Sparkle)
    private var sdkUpdater: SPUUpdater?
    private var userDriver: AppUpdateAuthorizingUserDriver?
    private var canCheckObservation: NSKeyValueObservation?
    #endif

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        currentVersion = CurrentAppVersion(bundle: bundle)
        state = AppUpdateSessionState(currentVersion: currentVersion)
        super.init()
        #if !canImport(Sparkle)
        statusOverride = "このビルドにはアップデート機能が含まれていません。"
        #endif
    }

    var statusText: String {
        if let statusOverride { return statusOverride }
        #if canImport(Sparkle)
        if !configurationIsValid { return "アップデートの配信設定を確認できませんでした。" }
        #endif
        return state.statusText
    }
    var checkBlockReason: String? { activityProvider().checkBlockReason }
    var installBlockReason: String? { installationActivity().installBlockReason }
    var canCheckForUpdates: Bool {
        #if canImport(Sparkle)
        configurationIsValid && activeSessionID == nil && !isInstalling && checkBlockReason == nil
        #else
        false
        #endif
    }
    var hasPostponedInstallation: Bool { deferredInstall != nil && activeSessionID != nil }
    var isUpdateSessionActive: Bool { activeSessionID != nil }

    var canResumeInstallation: Bool {
        hasDownloadedUpdate && sessionIsAuthorized && !isInstalling && installBlockReason == nil
    }

    func checkForUpdates(channel: AppUpdateChannel = .stable) {
        guard activeSessionID == nil, !isInstalling else { return }
        if let reason = checkBlockReason { statusOverride = reason; return }
        guard let identifier = state.begin(channel: channel) else { return }
        statusOverride = nil
        activeSessionID = identifier
        requestedChannel = channel
        hasDownloadedUpdate = false
        updateTerminationExpected = false
        deferredInstall = nil
        #if canImport(Sparkle)
        guard configurationIsValid else {
            finishFailure("アップデートの配信設定を確認できませんでした。現在のアプリは変更していません。", identifier: identifier)
            return
        }
        // A fresh SDK owner also gives callbacks a distinct updater identity. An old
        // session cannot supply an item or a late completion to a later channel check.
        let driver = AppUpdateAuthorizingUserDriver(hostBundle: bundle) { [weak self] item in
            guard let self, self.activeSessionID == identifier, let updater = self.sdkUpdater else { return false }
            return self.authorizedIdentifier(for: updater, item: item) != nil && self.sessionIsAuthorized
        }
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
        userDriver = driver
        sdkUpdater = updater
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
        do {
            try updater.start()
            updater.checkForUpdates()
        } catch {
            finishFailure("アップデートを開始できませんでした。配信設定を確認してください。", identifier: identifier)
        }
        #else
        finishFailure("このビルドにはアップデート機能が含まれていません。", identifier: identifier)
        #endif
    }

    /// Explicitly continue an SDK-delayed installation after the user resolves work.
    func resumeInstallationIfReady() {
        guard sessionIsAuthorized, hasDownloadedUpdate, !isInstalling else { return }
        if let reason = installBlockReason { statusOverride = reason; return }
        if let install = deferredInstall {
            guard acquireInstallationLock() else { return }
            updateTerminationExpected = true
            deferredInstall = nil
            install()
        } else {
            #if canImport(Sparkle)
            // Some Sparkle paths do not invoke the postponement delegate. Re-open the
            // existing ready-update UI; its final quit still uses the method below.
            sdkUpdater?.checkForUpdates()
            #endif
        }
    }

    /// The app delegate calls this before its existing termination path. It is a pure
    /// snapshot plus an entry lock, never an invocation of applicationShouldTerminate.
    func prepareForApplicationTermination() -> Bool {
        // Downloading an artifact does not turn an ordinary Quit into an update
        // request. Existing save/discard confirmation must remain reachable.
        guard updateTerminationExpected else { return true }
        guard sessionIsAuthorized else {
            statusOverride = "選択した更新先を確認できなかったため、アップデートを中止しました。"
            isInstalling = false
            return false
        }
        return acquireInstallationLock()
    }

    /// A cancelled normal Quit or SDK installation must not strand capture entry.
    func applicationTerminationCancelled() {
        guard updateTerminationExpected || isInstalling else { return }
        isInstalling = false
        updateTerminationExpected = false
        statusOverride = "アップデートを保留しています。作業を保存してから、もう一度適用できます。"
    }

    private var sessionIsAuthorized: Bool {
        state.channel == requestedChannel && AppUpdateAuthorization.allows(
            sessionID: state.sessionID, ownerSessionID: activeSessionID,
            requestedChannel: requestedChannel, offeredChannel: state.offeredChannel)
    }

    private func installationActivity() -> AppUpdateActivity {
        var snapshot = activityProvider()
        // Ignore our own transition lock while rechecking the final termination path.
        snapshot.installing = false
        return snapshot
    }

    private func acquireInstallationLock() -> Bool {
        guard sessionIsAuthorized else {
            isInstalling = false
            statusOverride = "選択した更新先を確認できなかったため、アップデートを中止しました。"
            return false
        }
        if let reason = installationActivity().installBlockReason {
            isInstalling = false
            statusOverride = reason
            return false
        }
        // MainActor does not yield between the final gate and publishing the lock.
        isInstalling = true
        statusOverride = nil
        if let identifier = activeSessionID {
            _ = state.receive(.installationStarted, sessionID: identifier)
            _ = state.updateStatus("アップデートを適用して再起動しています…", sessionID: identifier)
        }
        return true
    }

    private func receive(_ event: AppUpdateEvent, identifier: UUID) {
        guard activeSessionID == identifier else { return }
        if state.receive(event, sessionID: identifier) { statusOverride = nil }
    }

    private func finishFailure(_ message: String, identifier: UUID) {
        guard activeSessionID == identifier else { return }
        recordFailure(message, identifier: identifier)
        clearOwner(identifier: identifier)
    }

    private func recordFailure(_ message: String, identifier: UUID) {
        guard activeSessionID == identifier else { return }
        receive(.failed(message: message), identifier: identifier)
        statusOverride = message
        isInstalling = false
        hasDownloadedUpdate = false
        deferredInstall = nil
    }

    private func clearOwner(identifier: UUID) {
        // A no-update, failure or cancellation may already have cleared the model
        // token. Cleanup is based on the SDK owner, never on that expired token.
        guard activeSessionID == identifier else { return }
        activeSessionID = nil
        hasDownloadedUpdate = false
        updateTerminationExpected = false
        deferredInstall = nil
        isInstalling = false
    }

    #if canImport(Sparkle)
    private var configurationIsValid: Bool {
        let fixedURL = "https://raw.githubusercontent.com/TaigaShinohara/OneClip/main/updates/appcast.xml"
        guard bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String == fixedURL,
              let text = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let key = Data(base64Encoded: text), key.count == 32 else { return false }
        let falseKeys = ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUEnableSystemProfiling", "SUShowReleaseNotes", "SUEnableJavaScript"]
        let trueKeys = ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed", "SUEnableInstallerLauncherService", "SUEnableDownloaderService"]
        return falseKeys.allSatisfy { bundle.object(forInfoDictionaryKey: $0) as? Bool == false }
            && trueKeys.allSatisfy { bundle.object(forInfoDictionaryKey: $0) as? Bool == true }
            && bundle.object(forInfoDictionaryKey: "SUSignedFeedFailureExpirationInterval") as? Int == 0
    }

    private func ownerIdentifier(for updater: SPUUpdater) -> UUID? {
        guard updater === sdkUpdater else { return nil }
        return activeSessionID
    }

    private func liveIdentifier(for updater: SPUUpdater) -> UUID? {
        guard let identifier = ownerIdentifier(for: updater),
              state.sessionID == identifier, state.channel == requestedChannel else { return nil }
        return identifier
    }

    private func authorizedIdentifier(for updater: SPUUpdater, item: SUAppcastItem) -> UUID? {
        guard let identifier = ownerIdentifier(for: updater) else { return nil }
        guard state.channel == requestedChannel,
              AppUpdateAuthorization.allows(sessionID: state.sessionID, ownerSessionID: identifier,
                  requestedChannel: requestedChannel, offeredChannel: channel(for: item)) else {
            recordFailure("選択した更新先に対応しない版のため、アップデートを中止しました。", identifier: identifier)
            return nil
        }
        return identifier
    }

    private func channel(for item: SUAppcastItem) -> AppUpdateChannel? {
        guard let value = item.channel, !value.isEmpty else { return .stable }
        return value == "development" ? .development : nil
    }

    private func handle(_ error: NSError, identifier: UUID) {
        // Fixed SDK classifications only. Never expose raw paths, request diagnostics,
        // authorization details or NSError userInfo through our status or logs.
        if error.domain == SUSparkleErrorDomain {
            switch error.code {
            case 1001:
                receive(.noUpdate, identifier: identifier)
                return
            case 4007:
                receive(.cancelled, identifier: identifier)
                return
            case 3001, 3002:
                recordFailure("更新の署名を確認できなかったため、アップデートを中止しました。", identifier: identifier)
                return
            case 1...7:
                recordFailure("アップデートの配信設定を確認できませんでした。", identifier: identifier)
                return
            default: break
            }
        }
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
            receive(.cancelled, identifier: identifier)
        } else {
            recordFailure("アップデートを取得・適用できませんでした。通信状況を確認して、後でもう一度お試しください。", identifier: identifier)
        }
    }
    #endif
}

#if canImport(Sparkle)
extension AppUpdateController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard liveIdentifier(for: updater) != nil, updateCheck == .updates,
              activityProvider().checkBlockReason == nil else {
            throw NSError(domain: "OneClip.ManualUpdate", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "現在はアップデートを確認できません。"])
        }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        guard liveIdentifier(for: updater) != nil else { return [] }
        return requestedChannel == .development ? ["development"] : []
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard liveIdentifier(for: updater) != nil else { return nil }
        return "https://raw.githubusercontent.com/TaigaShinohara/OneClip/main/updates/appcast.xml"
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updates, authorizedIdentifier(for: updater, item: item) != nil else {
            throw NSError(domain: "OneClip.ManualUpdate", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "選択した更新先に対応しない版のため、アップデートを中止しました。"])
        }
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        // Cached installers skip shouldProceedWithUpdate. Repeat authorization here
        // and in every item callback before accepting its artifact or final relaunch.
        guard let identifier = authorizedIdentifier(for: updater, item: item),
              let kind = channel(for: item) else { return }
        receive(.updateFound(version: item.displayVersionString, channel: kind), identifier: identifier)
        if !sessionIsAuthorized {
            recordFailure("更新情報を確認できなかったため、アップデートを中止しました。", identifier: identifier)
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        guard let identifier = liveIdentifier(for: updater) else { return }
        let reason = ((error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        if reason == 1 || reason == 2 {
            receive(.noUpdate, identifier: identifier)
        } else {
            recordFailure("このMacで利用できる新しい更新を確認できませんでした。", identifier: identifier)
        }
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        guard let identifier = authorizedIdentifier(for: updater, item: item) else { return }
        receive(.downloadStarted, identifier: identifier)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        guard let identifier = authorizedIdentifier(for: updater, item: item) else { return }
        hasDownloadedUpdate = true
        receive(.downloadFinished, identifier: identifier)
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        guard let identifier = ownerIdentifier(for: updater) else { return }
        receive(.cancelled, identifier: identifier)
        hasDownloadedUpdate = false
        deferredInstall = nil
        isInstalling = false
        updateTerminationExpected = false
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        _ = authorizedIdentifier(for: updater, item: item)
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        _ = authorizedIdentifier(for: updater, item: item)
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        guard let identifier = authorizedIdentifier(for: updater, item: item) else { return }
        handle(error as NSError, identifier: identifier)
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard authorizedIdentifier(for: updater, item: item) != nil, sessionIsAuthorized else {
            // Re-enter the SDK's relaunch authorization, which now returns false,
            // so an item rejected after the first relaunch hook is aborted as well.
            Task { @MainActor in installHandler() }
            return true
        }
        hasDownloadedUpdate = true
        if acquireInstallationLock() { return false }
        deferredInstall = installHandler
        // No quit request is being sent while postponed. An ordinary Quit should
        // still reach the app's existing save/discard confirmation.
        updateTerminationExpected = false
        return true
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        guard let identifier = ownerIdentifier(for: updater) else { return false }
        guard sessionIsAuthorized else {
            recordFailure("選択した更新先を確認できなかったため、アップデートを中止しました。", identifier: identifier)
            return false
        }
        // Sparkle invokes this before shouldPostponeRelaunch. Reject only invalid
        // sessions/channels here; active work must reach the postponement callback.
        updateTerminationExpected = true
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        guard let identifier = authorizedIdentifier(for: updater, item: item), sessionIsAuthorized else { return }
        hasDownloadedUpdate = true
        _ = state.updateStatus("アップデートを適用する準備ができました。", sessionID: identifier)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock installHandler: @escaping () -> Void) -> Bool {
        guard let identifier = authorizedIdentifier(for: updater, item: item), sessionIsAuthorized else {
            Task { @MainActor in installHandler() }
            return true
        }
        hasDownloadedUpdate = true
        deferredInstall = installHandler
        updateTerminationExpected = false
        _ = state.updateStatus("アップデートの準備ができました。保存後に「再起動して更新」を押してください。", sessionID: identifier)
        // Background checks are rejected by mayPerformUpdateCheck. If an SDK path
        // reaches this callback, YES only holds its cycle for explicit resume; it
        // does not disable Sparkle's independent install-on-quit behavior.
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        guard let identifier = ownerIdentifier(for: updater) else { return }
        guard sessionIsAuthorized else {
            recordFailure("選択した更新先を確認できなかったため、アップデートを中止しました。", identifier: identifier)
            return
        }
        updateTerminationExpected = true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard let identifier = ownerIdentifier(for: updater) else { return }
        handle(error as NSError, identifier: identifier)
        clearOwner(identifier: identifier)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard let identifier = ownerIdentifier(for: updater) else { return }
        if let error { handle(error as NSError, identifier: identifier) }
        if state.sessionID == identifier {
            _ = state.finish(sessionID: identifier, status: "アップデートの確認を終了しました。")
        }
        clearOwner(identifier: identifier)
    }
}
#endif

#if canImport(Sparkle)
/// Keep Sparkle's standard dialogs while filtering a resumed artifact before the
/// user can install it. Delegate rejection alone does not cancel an installer
/// already waiting for host termination; the driver's skip response does.
@MainActor
private final class AppUpdateAuthorizingUserDriver: NSObject, SPUUserDriver {
    private let standard: SPUStandardUserDriver
    private let authorize: @MainActor (SUAppcastItem) -> Bool
    private var currentItem: SUAppcastItem?

    init(hostBundle: Bundle, authorize: @escaping @MainActor (SUAppcastItem) -> Bool) {
        standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
        self.authorize = authorize
        super.init()
    }

    func show(_ request: SPUUpdatePermissionRequest) async -> SUUpdatePermissionResponse {
        SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false)
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }
    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState) async -> SPUUserUpdateChoice {
        guard authorize(item) else { return .skip }
        currentItem = item
        let choice = await standard.showUpdateFound(with: item, state: state)
        // The model can become terminal while the dialog is open. Rejecting with
        // skip also tells the SDK to cancel a resumed installer at this stage.
        return authorize(item) ? choice : .skip
    }
    func showUpdateReleaseNotes(with data: SPUDownloadData) {
        standard.showUpdateReleaseNotes(with: data)
    }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        standard.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }
    func showUpdateNotFoundWithError(_ error: Error) async {
        await standard.showUpdateNotFoundWithError(error)
    }
    func showUpdaterError(_ error: Error) async { await standard.showUpdaterError(error) }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        standard.showDownloadInitiated(cancellation: cancellation)
    }
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) {
        standard.showDownloadDidReceiveExpectedContentLength(length)
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) { standard.showDownloadDidReceiveData(ofLength: length) }
    func showDownloadDidStartExtractingUpdate() { standard.showDownloadDidStartExtractingUpdate() }
    func showExtractionReceivedProgress(_ progress: Double) { standard.showExtractionReceivedProgress(progress) }
    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        guard let item = currentItem, authorize(item) else { return .skip }
        let choice = await standard.showReadyToInstallAndRelaunch()
        return authorize(item) ? choice : .skip
    }
    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        standard.showInstallingUpdate(withApplicationTerminated: terminated, retryTerminatingApplication: retryTerminatingApplication)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        await standard.showUpdateInstalledAndRelaunched(relaunched)
    }
    func dismissUpdateInstallation() {
        currentItem = nil
        standard.dismissUpdateInstallation()
    }
    func showUpdateInFocus() { standard.showUpdateInFocus() }
}
#endif
