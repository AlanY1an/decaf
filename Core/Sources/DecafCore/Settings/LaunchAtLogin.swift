// LaunchAtLogin — the login-item preference, as a rule instead of a habit.
//
// "A keep-awake tool that doesn't start with your Mac might as well not be
// installed": this preference is the difference between an overnight agent run
// that survives and one that doesn't, so registering it is not allowed to fail
// quietly, and it is not allowed to be skipped because a window was dismissed
// with the red button instead of the Done button.
//
// The whole decision lives here, over an injected registrar, because
// `SMAppService` cannot be driven from a test and would drag a real login-item
// registration into any suite that touched it. Every rule below (the no-op
// guard, the parked-for-approval case, the failure mirror, and
// apply-exactly-once) is therefore covered from DecafCoreTests, and the
// app keeps only the ServiceManagement adapter — which is also why that adapter
// is one of the App files the app test bundle does NOT compile.

import Foundation

/// The system's view of our login item, narrowed to what the UI needs.
/// Mirrors `SMAppService.Status`.
public enum LaunchAtLoginStatus: Equatable, Sendable {
    case enabled
    case notRegistered
    /// `register()` succeeded but macOS has parked the item pending the user's
    /// approval in System Settings. Nothing in the app can clear this.
    case requiresApproval
    case notFound
}

/// The login-item service (`SMAppService.mainApp` in the app; a fake in tests).
public protocol LaunchAtLoginRegistering: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
}

/// What a UI should show after an attempt: the state to put the toggle in
/// (always re-read from the system, never assumed from what was asked for), and
/// the sentence to show, if any.
public struct LaunchAtLoginOutcome: Equatable, Sendable {
    /// The system's state after the attempt.
    public var isEnabled: Bool
    /// nil when there is nothing to say.
    public var message: String?
    /// False when the system already agreed and nothing was called. A view that
    /// mirrors `isEnabled` back into its own toggle will be asked to apply the
    /// mirrored value a second time; that second pass reports `didAttempt ==
    /// false`, which is how a caller knows to leave the message it is already
    /// showing (typically the approval notice) alone.
    public var didAttempt: Bool

    public init(isEnabled: Bool, message: String? = nil, didAttempt: Bool = true) {
        self.isEnabled = isEnabled
        self.message = message
        self.didAttempt = didAttempt
    }
}

public enum LaunchAtLoginCopy {
    /// `register()` can succeed and still leave the item parked pending the
    /// user's approval. Only System Settings can clear that, so say where.
    public static let approvalMessage =
        "macOS is waiting for your approval. Allow Decaf in System Settings \u{203A} General \u{203A} Login Items."
}

public enum LaunchAtLogin {
    /// Registers or unregisters the login item and reports what actually
    /// happened. Never throws: the caller's job is to show `message`, not to
    /// handle an error.
    ///
    /// The result's `isEnabled` is always re-read from the registrar, so a
    /// registration parked in `.requiresApproval` — or one that threw — puts
    /// the toggle back where the system actually is instead of leaving a
    /// checked box lying about the next overnight run.
    public static func apply(
        enabled: Bool,
        using registrar: any LaunchAtLoginRegistering
    ) -> LaunchAtLoginOutcome {
        // Nothing to do when the system already agrees. This is what keeps a
        // view's "re-read on appear" from re-issuing a registration call, and
        // what keeps a mirrored-back toggle value from looping.
        guard enabled != (registrar.status == .enabled) else {
            return LaunchAtLoginOutcome(
                isEnabled: registrar.status == .enabled,
                didAttempt: false
            )
        }
        do {
            if enabled {
                try registrar.register()
                let status = registrar.status
                return LaunchAtLoginOutcome(
                    isEnabled: status == .enabled,
                    message: status == .requiresApproval ? LaunchAtLoginCopy.approvalMessage : nil
                )
            }
            try registrar.unregister()
            return LaunchAtLoginOutcome(isEnabled: registrar.status == .enabled)
        } catch {
            return LaunchAtLoginOutcome(
                isEnabled: registrar.status == .enabled,
                message: error.localizedDescription
            )
        }
    }
}

/// Onboarding's launch-at-login choice: a value the user can flip, plus the
/// guarantee that it reaches the system exactly once no matter how the flow
/// ends — Done, Skip, or the window's close button.
///
/// The bug this exists to make impossible: onboarding used to apply the choice
/// only on the Done button's path, so closing the window with the checkbox
/// still ticked marked onboarding complete and registered nothing. The window
/// never comes back, so that user's Mac silently stopped being protected on the
/// next reboot.
public final class LaunchAtLoginChoice {
    private let registrar: any LaunchAtLoginRegistering
    /// The user's current answer. Applied by `set(_:)` immediately, or by
    /// `applyIfNeeded()` when the flow ends without them ever touching it.
    public private(set) var isEnabled: Bool
    public private(set) var hasApplied = false

    public init(isEnabled: Bool = true, registrar: any LaunchAtLoginRegistering) {
        self.isEnabled = isEnabled
        self.registrar = registrar
    }

    /// The user flipped the switch: apply it now, so any failure is visible
    /// while they are still looking at the window that caused it.
    @discardableResult
    public func set(_ enabled: Bool) -> LaunchAtLoginOutcome {
        isEnabled = enabled
        let outcome = LaunchAtLogin.apply(enabled: enabled, using: registrar)
        hasApplied = true
        isEnabled = outcome.isEnabled
        return outcome
    }

    /// The flow is ending (or the step is being shown) and the choice has never
    /// been applied: apply it now. Returns nil when there was nothing left to
    /// do, so a caller can tell "already handled" from "just handled it".
    @discardableResult
    public func applyIfNeeded() -> LaunchAtLoginOutcome? {
        guard !hasApplied else { return nil }
        return set(isEnabled)
    }
}
