import AppKit
import Foundation

/// The production environment wiring, with explicit notification centers and public-monitor
/// backends as dependencies. Tests use private centers/fake backends, never post OS notifications.
@MainActor
final class CaptureEnvironmentRouter {
    struct NotificationSources {
        let workspace: NotificationCenter
        let application: NotificationCenter

        static var live: NotificationSources {
            NotificationSources(workspace: NSWorkspace.shared.notificationCenter, application: .default)
        }
    }

    private let sources: NotificationSources
    private let trace: CaptureSecurityTrace
    private let delivered: @MainActor (CaptureEnvironmentEvent) -> Void
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var notificationGeneration: UUID?
    private var sessionMonitor: CaptureSessionMonitor!
    private var consoleUserMonitor: CaptureConsoleUserMonitor!

    init(sources: NotificationSources, sessionBackend: CaptureSessionMonitor.Backend,
         consoleBackend: CaptureConsoleUserMonitor.Backend, securityTrace: CaptureSecurityTrace = .disabled,
         delivered: @escaping @MainActor (CaptureEnvironmentEvent) -> Void) {
        self.sources = sources
        trace = securityTrace
        self.delivered = delivered
        sessionMonitor = CaptureSessionMonitor(backend: Self.tracedSession(sessionBackend, trace: securityTrace)) { [weak self] event in
            self?.receive(event == .consoleChanged ? .consoleSessionChanged : .consoleSessionUnavailable)
        }
        consoleUserMonitor = CaptureConsoleUserMonitor(backend: Self.tracedConsole(consoleBackend, trace: securityTrace)) { [weak self] event in
            self?.receive(event == .changed ? .consoleUserChanged : .consoleUserUnavailable)
        }
    }

    var statusText: String {
        consoleUserMonitor.isReady ? sessionMonitor.statusText : consoleUserMonitor.statusText
    }

    #if DEBUG
    var diagnosticText: String { sessionMonitor.diagnosticText + "\n" + consoleUserMonitor.diagnosticText }
    #endif

    /// Starting an existing subscription never re-primes either monitor's pending fence.
    func start() {
        if notificationGeneration == nil {
            let generation = UUID()
            notificationGeneration = generation
            observe(NSWorkspace.willSleepNotification, on: sources.workspace, event: .systemSleep, generation: generation)
            observe(NSWorkspace.screensDidSleepNotification, on: sources.workspace, event: .displaySleep, generation: generation)
            observe(NSWorkspace.sessionDidResignActiveNotification, on: sources.workspace, event: .sessionResigned, generation: generation)
            observe(NSApplication.didChangeScreenParametersNotification, on: sources.application, event: .displayChanged, generation: generation)
        }
        sessionMonitor.start()
        consoleUserMonitor.start()
    }

    func prepare() -> Bool { start(); return validate() }

    func validate() -> Bool {
        let sessionReady = sessionMonitor.validate()
        let consoleReady = consoleUserMonitor.validate()
        let ready = sessionReady && consoleReady
        trace.record(.environmentValidated, outcome: ready ? .accepted : .rejected)
        return ready
    }

    /// AppKit's protected-data delegate and the notification/monitor sources use this same sink.
    func receive(_ event: CaptureEnvironmentEvent) {
        let code: CaptureSecurityTrace.Code
        switch event {
        case .systemSleep: code = .systemSleep
        case .displaySleep: code = .displaySleep
        case .sessionResigned: code = .sessionResigned
        case .displayChanged: code = .displayChanged
        case .protectedDataUnavailable: code = .protectedDataUnavailable
        case .consoleSessionChanged: code = .consoleSessionChanged
        case .consoleSessionUnavailable: code = .consoleSessionUnavailable
        case .consoleUserChanged: code = .consoleUserChanged
        case .consoleUserUnavailable: code = .consoleUserUnavailable
        }
        trace.record(code, outcome: [.protectedDataUnavailable, .consoleSessionUnavailable, .consoleUserUnavailable].contains(event)
                     ? .unavailable : .changed)
        delivered(event)
    }

    func stop() {
        notificationGeneration = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        sessionMonitor.stop()
        consoleUserMonitor.stop()
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter,
                         event: CaptureEnvironmentEvent, generation: UUID) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // Preserve synchronous invalidation on main delivery, without an extra Task hop.
            MainActor.assumeIsolated {
                guard let self, self.notificationGeneration == generation else { return }
                self.receive(event)
            }
        }
        observers.append((center, observer))
    }

    private static func tracedSession(_ backend: CaptureSessionMonitor.Backend,
                                      trace: CaptureSecurityTrace) -> CaptureSessionMonitor.Backend {
        .init(registerDispatch: { delivered in
            let result = backend.registerDispatch {
                trace.record(.cgDispatch, outcome: .changed)
                delivered()
            }
            trace.record(.cgRegisterDispatch, outcome: result.succeeded ? .success : .failure)
            return result
        }, registerCheck: {
            let result = backend.registerCheck()
            trace.record(.cgRegisterCheck, outcome: result.succeeded ? .success : .failure)
            return result
        }, check: { token in
            let result = backend.check(token)
            let outcome: CaptureSecurityTrace.Outcome
            switch result { case .changed: outcome = .changed; case .unchanged: outcome = .unchanged; case .failed: outcome = .failure }
            trace.record(.cgCheck, outcome: outcome)
            return result
        }, cancel: { token in
            let result = backend.cancel(token)
            trace.record(.cgCancel, outcome: result ? .success : .failure)
            return result
        }, session: backend.session, ownUserID: backend.ownUserID)
    }

    private static func tracedConsole(_ backend: CaptureConsoleUserMonitor.Backend,
                                      trace: CaptureSecurityTrace) -> CaptureConsoleUserMonitor.Backend {
        .init(register: { delivered in
            let result = backend.register { delivery in
                let outcome: CaptureSecurityTrace.Outcome
                switch delivery { case .changed: outcome = .changed; case .restarted: outcome = .restarted; case .failed: outcome = .failure }
                trace.record(.scDelivery, outcome: outcome)
                delivered(delivery)
            }
            trace.record(.scRegister, outcome: result.succeeded ? .success : .failure)
            return result
        }, check: { token in
            let result = backend.check(token)
            let outcome: CaptureSecurityTrace.Outcome
            switch result { case .changed: outcome = .changed; case .unchanged: outcome = .unchanged; case .failed: outcome = .failure }
            trace.record(.scCheck, outcome: outcome)
            return result
        }, cancel: { token in
            let result = backend.cancel(token)
            trace.record(.scCancel, outcome: result ? .success : .failure)
            return result
        }, consoleUserID: backend.consoleUserID, ownUserID: backend.ownUserID)
    }
}
