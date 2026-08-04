// WorkspaceMonitors — thin NSWorkspace/notification adapters (plan 01
// "监视器适配层"): fast user switching (sessionDidResign/BecomeActive),
// willSleep/didWake, and NSSystemClockDidChange. Pure event → main thread →
// callback plumbing; ALL decisions (gate composition, willSleep's
// "drop manual, keep agent" semantics, wall-clock re-confirmation on wake)
// live in PowerStateEngine.

import AppKit
import Foundation

@MainActor
public final class WorkspaceMonitors {
    /// Fast user switching: false when our login session resigns active,
    /// true when it becomes active again.
    public var onUserSessionActiveChange: ((Bool) -> Void)?
    /// User-initiated or forced sleep is imminent (never fight it).
    public var onWillSleep: (() -> Void)?
    /// System woke up — the engine re-confirms deadlines here.
    public var onDidWake: (() -> Void)?
    /// Wall clock jumped (timezone change / NTP correction).
    public var onClockChange: (() -> Void)?

    private var workspaceTokens: [NSObjectProtocol] = []
    private var clockToken: NSObjectProtocol?

    public init() {}

    /// Convenience wiring straight into the engine (composition root may also
    /// wire the callbacks by hand).
    public func bind(to engine: PowerStateEngine) {
        onUserSessionActiveChange = { [weak engine] active in
            engine?.updateGates { gates in
                gates.userSessionActive = active
            }
        }
        onWillSleep = { [weak engine] in
            engine?.systemWillSleep()
        }
        onDidWake = { [weak engine] in
            engine?.systemDidWake()
        }
        onClockChange = { [weak engine] in
            engine?.reconcile()
        }
    }

    public func start() {
        guard workspaceTokens.isEmpty, clockToken == nil else { return }
        let center = NSWorkspace.shared.notificationCenter

        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onUserSessionActiveChange?(false) }
        })
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onUserSessionActiveChange?(true) }
        })
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWillSleep?() }
        })
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDidWake?() }
        })

        // NSSystemClockDidChange may post on any thread; queue .main hops.
        clockToken = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClockChange?() }
        }
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens {
            center.removeObserver(token)
        }
        workspaceTokens.removeAll()
        if let clockToken {
            NotificationCenter.default.removeObserver(clockToken)
            self.clockToken = nil
        }
    }
}
