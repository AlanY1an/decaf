// StuckDowngrade — the record `SessionRegistry.reconcile` emits when the stuck
// predicate fires, and the single owner of the copy that tells the user about it.
//
// Three properties of this type are the whole of Part 3 ("being wrong must be
// cheap and visible"):
//
// 1. It reports a DOWNGRADE, never a deletion. The session stays in the
//    registry as `.idle` carrying `stuckDowngradedAt`, and any later heartbeat,
//    hook event or transcript write puts it straight back to `.working`. Being
//    wrong therefore costs one released hold and one notification, both undone
//    by the next sign of life.
// 2. It is an EVENT, not state. `DetectionOutput` is distinct-until-changed, so
//    a downgrade cannot ride on it: two downgrades of the same session,
//    separated by a revival, must both be visible, and a value stream would
//    collapse them. Hence a return value from `reconcile`.
// 3. It carries everything the notification needs and nothing else — no
//    transcript content, no prompt, no reason (plan 08 hard limit 3 applies
//    here too). `cwd` is a path the user chose and the menu already displays.

import Foundation
import CaffeinateCore
import HookWire

/// One `.working` session that the stuck predicate found self-contradictory.
public struct StuckDowngrade: Equatable, Sendable {
    public let sessionID: String
    public let agent: AgentKind
    /// The session's working directory, when known; the project name shown to
    /// the user is its last path component.
    public let cwd: String?
    /// How long the session had been silent on every channel when it was
    /// downgraded (`now - livenessAt`). Reported rather than assumed equal to
    /// the threshold: the check runs on a 30 s tick, so the real figure is
    /// always a little past it, and after a wake from sleep it can be far past.
    public let silentFor: TimeInterval
    /// When the downgrade happened.
    public let at: Date

    public init(
        sessionID: String,
        agent: AgentKind,
        cwd: String?,
        silentFor: TimeInterval,
        at: Date
    ) {
        self.sessionID = sessionID
        self.agent = agent
        self.cwd = cwd
        self.silentFor = silentFor
        self.at = at
    }

    /// The project name the menu would show for this session.
    public var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

// MARK: - Copy

extension StuckDowngrade {

    /// The user-facing notice. Single owner of this copy (review decision R17's
    /// rule, applied to the app's first notification): the app target renders
    /// this value and adds no words of its own.
    ///
    /// What the copy has to do, in order:
    ///
    /// - say what STOPPED, in the user's terms — the Mac is no longer being
    ///   kept awake. That is the fact the user can act on;
    /// - name WHICH session, so a user running several agents knows whether it
    ///   was the one they care about;
    /// - name the silence, because "2 hours of nothing" is the entire
    ///   justification and a user who disagrees with it should be able to say
    ///   so from the notification alone;
    /// - promise the reversal, so the notification does not read as "your
    ///   session was killed". Nothing was killed; a hold was released.
    public func notice() -> UserNotice {
        let subject: String
        if let projectName {
            subject = "\(agent.displayName) · \(projectName)"
        } else {
            subject = "The \(agent.displayName) session"
        }
        return UserNotice(
            identifier: "stuck-session.\(sessionID)",
            title: "Stopped keeping this Mac awake",
            body: "\(subject) has been silent for \(StuckDowngrade.durationPhrase(silentFor)) "
                + "— no tool calls, no transcript writes, no CPU. Caffeinate released its hold, "
                + "so this Mac can sleep again. It resumes on its own if the session comes back."
        )
    }

    /// "2 hours", "2 hours 5 minutes", "45 minutes". Deliberately not
    /// `DateComponentsFormatter`: this string is asserted in tests and must not
    /// change with the user's locale settings while the rest of the copy is
    /// English (localization is a whole-app decision, not a per-string one).
    static func durationPhrase(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        func plural(_ value: Int, _ unit: String) -> String {
            "\(value) \(unit)\(value == 1 ? "" : "s")"
        }
        switch (hours, minutes) {
        case (0, 0):
            return "less than a minute"
        case (0, _):
            return plural(minutes, "minute")
        case (_, 0):
            return plural(hours, "hour")
        default:
            return "\(plural(hours, "hour")) \(plural(minutes, "minute"))"
        }
    }
}
