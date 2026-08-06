// MenuPresentation — snapshot → menu bar icon state and status line (plan 04
// §2 and the §3 status-line table), as pure functions.
//
// These two functions answer the only question the menu bar exists to answer:
// "is this Mac being kept awake right now, and why". That answer must be
// covered by tests, and the app target has no test bundle — so the decision
// lives here, next to the snapshot it reads, and the app target keeps only the
// drawing (IconRenderer) and the menu assembly (MenuContentView).
//
// Absolute times only, never a countdown: a `.menu` evaluates its content when
// it opens and does not refresh while it stays open (plan 04 §3 / R7).
//
// The one rule that outranks every table below: while something is holding an
// assertion, no surface may say the Mac is idle. A silent hold is one of the
// two failures this product cannot have, and the status line is the only place
// a user would ever notice it.

import Foundation
import HookWire

// MARK: - Icon state

/// The four visual states of the menu bar icon (plan 04 §2).
public enum MenuBarIconState: Equatable, Hashable, Sendable {
    case idle
    case manualHold
    /// `sessionCount` >= 1.
    case agentHold(sessionCount: Int)
    case pausedBySafety
}

/// Pure snapshot → icon-state mapping (plan 04 §2).
///
/// Priority (high → low): pausedBySafety > agentHold > manualHold > idle.
public func iconState(for s: AppStateSnapshot) -> MenuBarIconState {
    if s.safetyPause != nil && s.wantsHold { return .pausedBySafety }

    let active = s.agentSessions.filter { $0.phase.holdsAssertion }
    if !active.isEmpty { return .agentHold(sessionCount: active.count) }

    // The zero-config default (no hooks installed): the hold is real — an
    // `.agentFallback` source is registered with the engine and an IOPMAssertion
    // is held — but file-activity detection sees an agent, not its sessions, so
    // there is no row to count. The cup is full because the Mac is awake; the
    // badge stays the single dot because "one agent is busy" is the whole of
    // what we know. Drawing the empty cup here was the bug: the icon said
    // "asleep when you close the lid" while the assertion was held.
    if !s.fallbackAgents.isEmpty { return .agentHold(sessionCount: 1) }

    if s.manual != nil { return .manualHold }

    // Belt and braces. Some source is holding that produced neither a session
    // row nor a manual state (a source the UI does not model yet, or a session
    // that dropped out of the registry between two publishes). The full cup is
    // the honest answer: whatever it is, sleep is blocked.
    if s.wantsHold { return .manualHold }

    return .idle
}

// MARK: - Copy

/// Every user-visible string derived from the snapshot's hold state. One owner,
/// like `DisplayActionCopy` and `AgentKind.displayName`: the menu, the status
/// item's accessibility label and the icon's own description all read from here
/// so they cannot drift into disagreeing about the same instant.
public enum MenuCopy {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// Locale-aware short time, e.g. "6:32 PM".
    public static func timeString(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    // MARK: Status line (plan 04 §3 table; priority mirrors the icon)

    /// The status line, plus the display clause when — and only when — the
    /// display is actually being held on.
    ///
    /// `effectiveDisplayPolicy` is what is in force this instant, not what was
    /// asked for: a hold suspended by a safety gate holds no display assertion,
    /// so the clause correctly disappears while the line reads "Paused" (and the
    /// "Keep Display On" check mark stays on, because that is the choice, not
    /// the reality). Nothing is appended for `.allowSleep`, which is the default
    /// and the norm — a menu that narrates its own default is noise.
    public static func statusLine(for s: AppStateSnapshot, now: Date = Date()) -> String {
        let base = baseStatusLine(for: s, now: now)
        return s.effectiveDisplayPolicy == .keepOn ? "\(base) · Display on" : base
    }

    static func baseStatusLine(for s: AppStateSnapshot, now: Date) -> String {
        if let pause = s.safetyPause, s.wantsHold {
            switch pause {
            case .lowBattery(let percent, let threshold):
                return "Paused · Battery \(percent)% below \(threshold)% threshold"
            case .lowPowerMode:
                return "Paused · Low Power Mode is on"
            case .userSwitchedOut:
                // No dedicated copy (plan 04 §3 / R13): the user has switched
                // away and cannot see this menu; fall through to the normal
                // computation for the instant they switch back.
                break
            }
        }

        let active = s.agentSessions.filter { $0.phase.holdsAssertion }
        if !active.isEmpty {
            let graceEnds = active.compactMap { session -> Date? in
                if case .graceIdle(let until) = session.phase { return until }
                return nil
            }
            if graceEnds.count == active.count, let latest = graceEnds.max() {
                return "Just finished · Sleep allowed after \(timeString(latest))"
            }
            let name = active[0].agent.displayName
            return active.count == 1
                ? "\(name) working"
                : "\(name) working · \(active.count) sessions"
        }

        // File-activity detection, the zero-config default. Same sentence as a
        // single hooks-tracked session, because it states the same fact — an
        // agent is busy and sleep is blocked. How well we know it is the job of
        // the precision line directly below this one ("Detection: file activity
        // (approximate)"), which is shown in exactly this mode; saying it twice
        // in the status line would make the headline about our plumbing instead
        // of about the user's Mac.
        if let agent = s.fallbackAgents.first {
            let name = agent.displayName
            return s.fallbackAgents.count == 1
                ? "\(name) working"
                : "\(name) working · \(s.fallbackAgents.count) agents"
        }

        if let manual = s.manual {
            if let expiry = manual.expiry {
                return "Manual hold · Until \(timeString(expiry))"
            }
            return "Manual hold · Indefinite"
        }

        // A hold with nothing above it to explain it (see `iconState`). The
        // inverse of the idle line, in the same shape: whatever is holding, the
        // user is told the truth about their Mac.
        if s.wantsHold { return "Keeping awake — sleep is blocked" }

        return "Idle — not preventing sleep"
    }

    // MARK: Accessibility

    /// Status item / icon accessibility label (plan 04 §4).
    public static func accessibilityLabel(for s: AppStateSnapshot) -> String {
        accessibilityLabel(for: iconState(for: s))
    }

    public static func accessibilityLabel(for state: MenuBarIconState) -> String {
        switch state {
        case .idle:
            return "Caffeinate, idle"
        case .manualHold:
            // Not "manual hold active": this state also carries a hold whose
            // source the UI cannot name (see `iconState`). "Keeping awake" is
            // true of both, and it is the fact a VoiceOver user needs.
            return "Caffeinate, keeping the Mac awake"
        case .agentHold(let n):
            return n == 1
                ? "Caffeinate, agent working"
                : "Caffeinate, agents working, \(n) sessions"
        case .pausedBySafety:
            return "Caffeinate, paused by a safety protection"
        }
    }
}
