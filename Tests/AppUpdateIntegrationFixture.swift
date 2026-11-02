import AppKit
import Foundation
import Sparkle

/// Standalone, opt-in host for a local Sparkle install/relaunch test. This executable
/// never imports OneClip, captures a screen, accesses a pasteboard, or reads user files.
@main
struct AppUpdateIntegrationFixture {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let delegate = FixtureDelegate()
        application.delegate = delegate
        application.run()
    }
}

@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    private var driver: FixtureDriver?
    private var timeout: Timer?
    private var completed = false
    private var reportDirectory: URL?
    private var updateWasOffered = false
    private var downloadStarted = false
    private let sentinel = Data("OneClip fabricated saved-data fixture\n".utf8)

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let bundle = Bundle.main
            guard bundle.bundleIdentifier == "local.OneClip.UpdateFixture",
                  let testID = bundle.object(forInfoDictionaryKey: "FixtureTestID") as? String,
                  UUID(uuidString: testID) != nil,
                  let expected = bundle.object(forInfoDictionaryKey: "FixtureExpectedVersion") as? String,
                  let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                  let url = URL(string: feed), url.scheme == "http", url.host == "localhost" else {
                throw FixtureError.invalidConfiguration
            }
            let root = URL.applicationSupportDirectory.appendingPathComponent("OneClipUpdateFixture", isDirectory: true)
                .appendingPathComponent(testID, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            reportDirectory = root
            let saved = root.appendingPathComponent("fabricated-saved-data.txt")
            let defaultsKey = "FixtureSetting-" + testID
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            if build == expected {
                guard try Data(contentsOf: saved) == sentinel,
                      UserDefaults.standard.string(forKey: defaultsKey) == "retained" else {
                    throw FixtureError.stateWasNotPreserved
                }
                finish("passed_relaunch_and_state", build: build)
                return
            }
            guard !FileManager.default.fileExists(atPath: saved.path) else { throw FixtureError.reusedFixture }
            try sentinel.write(to: saved, options: .withoutOverwriting)
            UserDefaults.standard.set("retained", forKey: defaultsKey)
            try write("started.json", values: ["status": "started", "build": build, "pid": ProcessInfo.processInfo.processIdentifier])
            let driver = FixtureDriver(owner: self)
            self.driver = driver
            let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
            self.updater = updater
            timeout = Timer.scheduledTimer(withTimeInterval: 70, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish("failed_timeout") }
            }
            try updater.start()
            updater.checkForUpdates()
        } catch { finish("failed_configuration_or_state") }
    }

    func offered(_ item: SUAppcastItem) -> SPUUserUpdateChoice {
        guard !item.isInformationOnlyUpdate else { finish("failed_information_only"); return .skip }
        updateWasOffered = true
        return .install
    }
    func downloading() { downloadStarted = true }
    func ready() -> SPUUserUpdateChoice { .install }
    func failed(_ error: Error) {
        let error = error as NSError
        let codes = failureCodes(error)
        let rejectionExpected = Bundle.main.object(forInfoDictionaryKey: "FixtureMode") as? String == "signature-reject"
        if rejectionExpected, updateWasOffered, downloadStarted,
           codes.contains(where: { $0.domain == "sparkle" && [3001, 3002].contains($0.code) }) {
            finish("passed_invalid_archive_signature", errorCode: error.code, codes: codes)
        } else { finish("failed_update", errorCode: error.code, codes: codes) }
    }

    private struct FailureCode {
        let domain: String
        let code: Int
    }

    /// Sparkle can wrap archive validation failures in installation errors. Keep
    /// only bounded, fixed domain labels and integer codes; never serialize an
    /// NSError, its raw domain, description, userInfo, path, URL or other payload.
    private func failureCodes(_ error: NSError) -> [FailureCode] {
        var codes: [FailureCode] = []
        var seen: Set<ObjectIdentifier> = []
        var next: NSError? = error
        while let current = next, codes.count < 8, seen.insert(ObjectIdentifier(current)).inserted {
            let domain: String
            switch current.domain {
            case SUSparkleErrorDomain: domain = "sparkle"
            case NSCocoaErrorDomain: domain = "cocoa"
            case NSURLErrorDomain: domain = "url"
            case NSPOSIXErrorDomain: domain = "posix"
            case NSOSStatusErrorDomain: domain = "osstatus"
            case NSMachErrorDomain: domain = "mach"
            default: domain = "other"
            }
            codes.append(FailureCode(domain: domain, code: current.code))
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return codes
    }

    private func finish(_ status: String, build: String? = nil, errorCode: Int? = nil, codes: [FailureCode] = []) {
        guard !completed else { return }
        completed = true
        timeout?.invalidate()
        var values: [String: Any] = ["status": status, "offered": updateWasOffered, "download_started": downloadStarted]
        if let build { values["build"] = build }
        if let errorCode { values["error_code"] = errorCode }
        if !codes.isEmpty { values["error_chain"] = codes.map { ["domain": $0.domain, "code": $0.code] as [String: Any] } }
        do { try write("result.json", values: values) }
        catch { FileHandle.standardError.write(Data("FIXTURE_REPORT_WRITE_FAILED\n".utf8)) }
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }
    private func write(_ name: String, values: [String: Any]) throws {
        guard let reportDirectory else { throw FixtureError.invalidConfiguration }
        try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            .write(to: reportDirectory.appendingPathComponent(name), options: .atomic)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
    func applicationWillTerminate(_ notification: Notification) { timeout?.invalidate() }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updates else { throw FixtureError.invalidConfiguration }
    }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }
    private enum FixtureError: Error { case invalidConfiguration, stateWasNotPreserved, reusedFixture }
}

@MainActor
private final class FixtureDriver: NSObject, SPUUserDriver {
    private weak var owner: FixtureDelegate?
    init(owner: FixtureDelegate) { self.owner = owner }
    func show(_ request: SPUUpdatePermissionRequest) async -> SUUpdatePermissionResponse {
        SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false)
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState) async -> SPUUserUpdateChoice {
        owner?.offered(item) ?? .skip
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { owner?.failed(error) }
    func showUpdateNotFoundWithError(_ error: Error) async { owner?.failed(error) }
    func showUpdaterError(_ error: Error) async { owner?.failed(error) }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { owner?.downloading() }
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice { owner?.ready() ?? .skip }
    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {}
    func dismissUpdateInstallation() {}
}
