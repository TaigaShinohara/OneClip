import Darwin
import Dispatch
import Foundation
import SystemConfiguration

/// Watches only the public primary-console-user key. No name or session dictionary is retained.
/// A pending change is significant even after the primary console returns to the same UID.
/// Neither this fence nor the following capture/write is an atomic transaction with the OS.
@MainActor
final class CaptureConsoleUserMonitor {
    enum Invalidation: Equatable, Sendable { case changed, unavailable }
    enum Delivery: Sendable { case changed, restarted, failed }
    enum CheckResult: Sendable { case unchanged, changed, failed }

    struct Registration: Sendable {
        let token: UUID?
        let succeeded: Bool
    }

    @MainActor
    struct Backend {
        let register: @MainActor (@escaping @MainActor @Sendable (Delivery) -> Void) -> Registration
        let check: @MainActor (UUID) -> CheckResult
        let cancel: @MainActor (UUID) -> Bool
        let consoleUserID: @MainActor () -> UInt32?
        let ownUserID: @MainActor () -> UInt32

        static var live: Backend {
            let live = ConsoleUserStoreBackend()
            return Backend(register: { live.register($0) }, check: { live.check($0) },
                           cancel: { live.cancel($0) }, consoleUserID: {
                var userID = uid_t.max
                // The API returns a name as well. Test only its presence; do not retain or log it.
                guard SCDynamicStoreCopyConsoleUser(nil, &userID, nil) != nil else { return nil }
                return userID
            }, ownUserID: { getuid() })
        }
    }

    private(set) var isReady = false
    private(set) var statusText = "コンソール利用状態の監視は未開始です"
    #if DEBUG
    private(set) var registrationAttempts = 0
    private(set) var deliveries = 0
    private(set) var changedChecks = 0
    private(set) var unchangedChecks = 0
    private(set) var failedChecks = 0
    var diagnosticText: String {
        "SC登録 \(registrationAttempts)・配送 \(deliveries)・check変化 \(changedChecks)/不変 \(unchangedChecks)/失敗 \(failedChecks)"
    }
    #endif
    private let backend: Backend
    private let invalidated: @MainActor (Invalidation) -> Void
    private var token: UUID?
    private var generation: UUID?
    private var unavailabilityReported = false

    init(backend: Backend = .live,
         invalidated: @escaping @MainActor (Invalidation) -> Void) {
        self.backend = backend
        self.invalidated = invalidated
    }

    /// Start before captured material exists. Only this first subscription check is a baseline.
    func start() {
        guard generation == nil else { return }
        isReady = false
        guard cleanUp() else { failSetup(); return }
        unavailabilityReported = false
        let identifier = UUID()
        generation = identifier
        #if DEBUG
        registrationAttempts += 1
        #endif
        let registration = backend.register { [weak self] delivery in
            guard let self, self.generation == identifier, self.token != nil else { return }
            #if DEBUG
            self.deliveries += 1
            #endif
            switch delivery {
            case .changed:
                // The framework already consumed CopyNotifiedKeys before this callback.
                // Do not poll again and mistakenly turn a real callback into "unchanged".
                self.reportChanged()
            case .restarted, .failed:
                // An empty callback means server restart, unlike an ordinary empty sync check.
                self.failSetup()
            }
        }
        token = registration.token
        guard registration.succeeded, let token else { failSetup(); return }
        switch pollCheck(token) {
        case .failed:
            failSetup()
        case .changed, .unchanged:
            if currentConsoleIsAvailable() {
                isReady = true
                statusText = "コンソール利用状態を確認できました"
            } else {
                reportUnavailable()
            }
        }
    }

    /// Check at explicit entry and result-adoption boundaries, without timer polling.
    @discardableResult
    func validate() -> Bool {
        guard generation != nil, let token else { return false }
        switch pollCheck(token) {
        case .failed:
            failSetup()
            return false
        case .changed:
            reportChanged()
            return false
        case .unchanged:
            guard currentConsoleIsAvailable() else { reportUnavailable(); return false }
            isReady = true
            unavailabilityReported = false
            statusText = "コンソール利用状態を確認できました"
            return true
        }
    }

    private func pollCheck(_ token: UUID) -> CheckResult {
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

    func stop() {
        generation = nil
        isReady = false
        unavailabilityReported = false
        statusText = cleanUp()
            ? "コンソール利用状態の監視を停止しました"
            : "コンソール利用状態の監視を停止しました。通知の解除は未完了です"
    }

    private func currentConsoleIsAvailable() -> Bool {
        guard let userID = backend.consoleUserID() else { return false }
        return userID == backend.ownUserID()
    }

    private func reportChanged() {
        isReady = false
        unavailabilityReported = false
        statusText = "コンソール利用状態が変わったため中止しました。新しい操作で確認してください"
        invalidated(.changed)
    }

    private func reportUnavailable() {
        isReady = false
        statusText = "コンソール利用状態を確認できません。復帰後に新しい操作で確認してください"
        guard !unavailabilityReported else { return }
        unavailabilityReported = true
        invalidated(.unavailable)
    }

    private func failSetup() {
        generation = nil
        isReady = false
        _ = cleanUp()
        statusText = "コンソール利用状態の監視を確認できません。撮影を停止しています"
        guard !unavailabilityReported else { return }
        unavailabilityReported = true
        invalidated(.unavailable)
    }

    /// Keep a failed cancellation owned for a later stop/start retry; do not overlap subscriptions.
    @discardableResult
    private func cleanUp() -> Bool {
        guard let token else { return true }
        guard backend.cancel(token) else { return false }
        self.token = nil
        return true
    }
}

/// Retained by the SCDynamicStore CF context, independently of queued notification delivery.
/// The delivered closure captures the monitor weakly and is rejected after its generation stops.
final class ConsoleUserCallbackContext: Sendable {
    let key: String
    let delivered: @MainActor @Sendable (CaptureConsoleUserMonitor.Delivery) -> Void

    init(key: String, delivered: @escaping @MainActor @Sendable (CaptureConsoleUserMonitor.Delivery) -> Void) {
        self.key = key
        self.delivered = delivered
    }
}

/// CF may retain or release this context on any queue, including its dispatch-source finalizer.
/// Named nonisolated C callbacks avoid inheriting the registering method's MainActor isolation.
private nonisolated func retainConsoleUserContext(_ pointer: UnsafeRawPointer) -> UnsafeRawPointer {
    _ = Unmanaged<ConsoleUserCallbackContext>.fromOpaque(pointer).retain()
    return pointer
}

private nonisolated func releaseConsoleUserContext(_ pointer: UnsafeRawPointer) {
    Unmanaged<ConsoleUserCallbackContext>.fromOpaque(pointer).release()
}

/// Production and the CF lifetime regression use the identical retain/release function pointers.
nonisolated func makeConsoleUserStoreContext(_ box: ConsoleUserCallbackContext) -> SCDynamicStoreContext {
    SCDynamicStoreContext(version: 0,
        info: Unmanaged.passUnretained(box).toOpaque(),
        retain: retainConsoleUserContext, release: releaseConsoleUserContext, copyDescription: nil)
}

private nonisolated func consoleUserStoreChanged(_ store: SCDynamicStore, _ changedKeys: CFArray,
                                                _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    let context = Unmanaged<ConsoleUserCallbackContext>.fromOpaque(info).takeUnretainedValue()
    let delivery: CaptureConsoleUserMonitor.Delivery
    if CFArrayGetCount(changedKeys) == 0 {
        // SCDynamicStore.h explicitly identifies an empty callback as server restart.
        delivery = .restarted
    } else if let keys = changedKeys as? [String], keys.allSatisfy({ $0 == context.key }) {
        delivery = .changed
    } else {
        delivery = .failed
    }
    // SetDispatchQueue supplied .main; no extra Task hop before invalidating the capture state.
    MainActor.assumeIsolated { context.delivered(delivery) }
}

/// The only live ownership behind Backend's small fakeable closure surface.
/// Methods run on MainActor. Destruction also detaches retained stores as a best effort.
private final class ConsoleUserStoreBackend {
    private final class Store {
        let value: SCDynamicStore
        let key: String
        var scheduled = false

        init(value: SCDynamicStore, key: String) { self.value = value; self.key = key }

        func detach() -> Bool {
            guard scheduled else { return true }
            guard SCDynamicStoreSetDispatchQueue(value, nil) else { return false }
            scheduled = false
            return true
        }

        deinit {
            if scheduled { _ = SCDynamicStoreSetDispatchQueue(value, nil) }
            // If detaching fails, the framework's active dispatch source retains its store and
            // CF context. It can still call the weak/generation-guarded closure, never a freed box.
        }
    }

    private var stores: [UUID: Store] = [:]

    @MainActor
    func register(_ delivered: @escaping @MainActor @Sendable (CaptureConsoleUserMonitor.Delivery) -> Void)
        -> CaptureConsoleUserMonitor.Registration {
        let key = SCDynamicStoreKeyCreateConsoleUser(nil)
        let box = ConsoleUserCallbackContext(key: key as String, delivered: delivered)
        var context = makeConsoleUserStoreContext(box)
        guard let value = SCDynamicStoreCreate(nil, "OneClip console-user availability" as CFString,
                                               consoleUserStoreChanged, &context) else {
            return .init(token: nil, succeeded: false)
        }
        let token = UUID()
        let store = Store(value: value, key: key as String)
        stores[token] = store
        guard SCDynamicStoreSetNotificationKeys(value, [key] as CFArray, nil),
              SCDynamicStoreSetDispatchQueue(value, .main) else {
            return .init(token: token, succeeded: false)
        }
        store.scheduled = true
        return .init(token: token, succeeded: true)
    }

    @MainActor
    func check(_ token: UUID) -> CaptureConsoleUserMonitor.CheckResult {
        guard let store = stores[token], store.scheduled,
              let result = SCDynamicStoreCopyNotifiedKeys(store.value),
              let keys = result as? [String] else { return .failed }
        guard keys.allSatisfy({ $0 == store.key }) else { return .failed }
        return keys.isEmpty ? .unchanged : .changed
    }

    @MainActor
    func cancel(_ token: UUID) -> Bool {
        guard let store = stores[token] else { return true }
        guard store.detach() else { return false }
        stores.removeValue(forKey: token)
        return true
    }
}
