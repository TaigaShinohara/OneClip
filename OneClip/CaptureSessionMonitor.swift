import CoreGraphics
import Darwin
import Dispatch
import Foundation
import notify

/// A console-session fence for capture/retained images. It does not inspect screen or clipboard data.
/// notify_check may coalesce events or report false positives; either change safely stops the operation.
/// The final check and a subsequent capture/write are not an atomic transaction with the OS.
@MainActor
final class CaptureSessionMonitor {
    enum Invalidation: Equatable, Sendable {
        case consoleChanged
        case unavailable
    }

    struct SessionSnapshot: Equatable, Sendable {
        let onConsole: Bool
        let loginDone: Bool
        let userID: UInt32
    }

    struct Registration: Sendable {
        let token: Int32?
        let succeeded: Bool
    }

    enum CheckResult: Sendable {
        case unchanged, changed, failed
    }

    /// Separate dispatch/check registrations are intentional: only the check token is polled.
    @MainActor
    struct Backend {
        let registerDispatch: @MainActor (@escaping @MainActor @Sendable () -> Void) -> Registration
        let registerCheck: @MainActor () -> Registration
        let check: @MainActor (Int32) -> CheckResult
        let cancel: @MainActor (Int32) -> Bool
        let session: @MainActor () -> SessionSnapshot?
        let ownUserID: @MainActor () -> UInt32

        static var live: Backend {
            Backend(registerDispatch: { delivered in
                var token = Int32(NOTIFY_TOKEN_INVALID)
                let status = notify_register_dispatch(kCGNotifyGUIConsoleSessionChanged, &token, .main) { _ in
                    // notify.h delivers on the supplied main queue. Consume the fence in this
                    // callback, without another Task hop that could run after a queued action.
                    MainActor.assumeIsolated { delivered() }
                }
                return Registration(token: token >= 0 ? token : nil,
                                    succeeded: status == UInt32(NOTIFY_STATUS_OK))
            }, registerCheck: {
                var token = Int32(NOTIFY_TOKEN_INVALID)
                let status = notify_register_check(kCGNotifyGUIConsoleSessionChanged, &token)
                return Registration(token: token >= 0 ? token : nil,
                                    succeeded: status == UInt32(NOTIFY_STATUS_OK))
            }, check: { token in
                var changed: Int32 = 0
                guard notify_check(token, &changed) == UInt32(NOTIFY_STATUS_OK),
                      changed == 0 || changed == 1 else { return .failed }
                return changed == 0 ? .unchanged : .changed
            }, cancel: { token in
                notify_cancel(token) == UInt32(NOTIFY_STATUS_OK)
            }, session: {
                // Extract only the three public eligibility fields; never log the dictionary/name.
                guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any],
                      let onConsole = dictionary[kCGSessionOnConsoleKey as String] as? Bool,
                      let loginDone = dictionary[kCGSessionLoginDoneKey as String] as? Bool,
                      let userID = dictionary[kCGSessionUserIDKey as String] as? UInt32 else { return nil }
                return SessionSnapshot(onConsole: onConsole, loginDone: loginDone, userID: userID)
            }, ownUserID: { getuid() })
        }
    }

    private(set) var isReady = false
    private(set) var statusText = "利用状態の監視は未開始です"
    #if DEBUG
    private(set) var registrationAttempts = 0
    private(set) var dispatchDeliveries = 0
    private(set) var changedChecks = 0
    private(set) var unchangedChecks = 0
    private(set) var failedChecks = 0
    var diagnosticText: String {
        "CG登録 \(registrationAttempts)・配送 \(dispatchDeliveries)・check変化 \(changedChecks)/不変 \(unchangedChecks)/失敗 \(failedChecks)"
    }
    #endif
    private let backend: Backend
    private let invalidated: @MainActor (Invalidation) -> Void
    private var dispatchToken: Int32?
    private var checkToken: Int32?
    private var generation: UUID?
    private var unavailabilityReported = false

    init(backend: Backend = .live,
         invalidated: @escaping @MainActor (Invalidation) -> Void) {
        self.backend = backend
        self.invalidated = invalidated
    }

    /// Call before a new capture session exists. The initial check is a baseline, not an event.
    /// Calling start again while subscribed neither re-primes nor clears a pending change.
    func start() {
        guard generation == nil else { return }
        isReady = false
        guard cleanUpTokens() else {
            failSetup()
            return
        }
        unavailabilityReported = false
        let identifier = UUID()
        generation = identifier
        #if DEBUG
        registrationAttempts += 1
        #endif
        let dispatch = backend.registerDispatch { [weak self] in
            guard let self, self.generation == identifier, let checkToken = self.checkToken else { return }
            #if DEBUG
            self.dispatchDeliveries += 1
            #endif
            // Delivery is itself a safety signal. A separate unchanged poll must not veto it.
            // A late duplicate can stop a new explicit operation; the user can start again.
            switch self.pollCheck(checkToken) {
            case .failed: self.failSetup()
            case .changed, .unchanged: self.reportChanged()
            }
        }
        dispatchToken = validToken(dispatch.token)
        guard dispatch.succeeded, dispatchToken != nil else {
            failSetup()
            return
        }
        let check = backend.registerCheck()
        checkToken = validToken(check.token)
        guard check.succeeded, let checkToken, checkToken != dispatchToken else {
            failSetup()
            return
        }
        // notify.h guarantees the first successful check is true. Discard that initial baseline.
        switch pollCheck(checkToken) {
        case .failed:
            failSetup()
        case .changed, .unchanged:
            if currentSessionIsAvailable() {
                isReady = true
                statusText = "利用状態を確認できました"
            } else {
                reportUnavailable()
            }
        }
    }

    /// A new explicit operation can resume only after this checks both the fence and eligibility.
    @discardableResult
    func validate() -> Bool {
        inspect()
    }

    func stop() {
        generation = nil // Old queued deliveries cannot consume a later generation's check token.
        isReady = false
        unavailabilityReported = false
        statusText = cleanUpTokens()
            ? "利用状態の監視を停止しました"
            : "利用状態の監視を停止しました。通知の解除は未完了です"
    }

    private func inspect() -> Bool {
        guard generation != nil, dispatchToken != nil, let checkToken else { return false }
        switch pollCheck(checkToken) {
        case .failed:
            failSetup()
            return false
        case .changed:
            reportChanged()
            return false
        case .unchanged:
            guard currentSessionIsAvailable() else {
                reportUnavailable()
                return false
            }
            // Merely returning to the console does not auto-resume a stopped operation.
            isReady = true
            unavailabilityReported = false
            statusText = "利用状態を確認できました"
            return isReady
        }
    }

    private func reportChanged() {
        isReady = false
        statusText = "利用状態が変わったため中止しました。新しい操作で確認してください"
        unavailabilityReported = false
        invalidated(.consoleChanged)
    }

    private func pollCheck(_ token: Int32) -> CheckResult {
        let result = backend.check(token)
        #if DEBUG
        switch result {
        case .changed: changedChecks += 1
        case .unchanged: unchangedChecks += 1
        case .failed: failedChecks += 1
        }
        #endif
        return result
    }

    private func currentSessionIsAvailable() -> Bool {
        guard let session = backend.session() else { return false }
        return session.onConsole && session.loginDone && session.userID == backend.ownUserID()
    }

    private func reportUnavailable() {
        isReady = false
        statusText = "利用状態を確認できません。復帰後に新しい操作で確認してください"
        guard !unavailabilityReported else { return }
        unavailabilityReported = true
        invalidated(.unavailable)
    }

    private func failSetup() {
        generation = nil
        isReady = false
        _ = cleanUpTokens()
        statusText = "利用状態の監視を確認できません。撮影を停止しています"
        guard !unavailabilityReported else { return }
        unavailabilityReported = true
        invalidated(.unavailable)
    }

    /// Failed cancellations remain owned and are retried by stop() or a later explicit start().
    @discardableResult
    private func cleanUpTokens() -> Bool {
        if let dispatchToken, dispatchToken == checkToken {
            if backend.cancel(dispatchToken) {
                self.dispatchToken = nil
                checkToken = nil
            }
            return self.dispatchToken == nil && checkToken == nil
        }
        if let dispatchToken, backend.cancel(dispatchToken) { self.dispatchToken = nil }
        if let checkToken, backend.cancel(checkToken) { self.checkToken = nil }
        return dispatchToken == nil && checkToken == nil
    }

    private func validToken(_ token: Int32?) -> Int32? {
        guard let token, token >= 0 else { return nil }
        return token
    }
}
