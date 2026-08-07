// LowPowerModeMonitor — thin ProcessInfo adapter (plan 01 "监视器适配层").
// NSProcessInfoPowerStateDidChange is delivered on an ARBITRARY thread (plan 01
// risk table); this monitor hops to the main thread before calling out. No
// decisions here — the engine's lowPowerMode gate has no override by design
// (the honest path to keep-awake is turning LPM off).

import Foundation

@MainActor
public final class LowPowerModeMonitor {
    /// Fired on the main thread with the current LPM state (initial value on
    /// start(), then on every power-state change).
    public var onChange: ((Bool) -> Void)?

    private var observer: NSObjectProtocol?

    public init() {}

    public var isEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Convenience wiring: forward LPM state into the engine's gate.
    public func bind(to engine: PowerStateEngine) {
        onChange = { [weak engine] enabled in
            engine?.updateGates { gates in
                gates.lowPowerMode = enabled ? .engaged : .open
            }
        }
    }

    /// Subscribes and immediately delivers the initial value (bind/assign
    /// `onChange` before calling start()).
    public func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil // synchronous on the posting thread — hop below
        ) { [weak self] _ in
            let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onChange?(enabled)
                }
            }
        }
        onChange?(isEnabled)
    }

    public func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}
