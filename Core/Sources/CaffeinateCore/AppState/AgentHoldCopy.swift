// AgentHoldCopy — what Settings › Agents says about `AgentHoldMode`, including
// the sentence that admits when the mode cannot be delivered.
//
// `AgentHoldMode` owns the two labels and the two one-line explanations, the
// way `DisplayPolicy` owns `menuTitle` / `settingsTitle`. What lives here is
// the part that is not a property of the mode alone: the footer, which is a
// function of the mode AND of what this particular Mac can currently see.
//
// Why that second input matters enough to have its own file. "Keep this Mac
// awake whenever an agent is running" is a claim about a PROCESS. With hooks
// installed we know sessions, idle ones included, so the claim holds as
// written. With the L3 process scan we can see the process itself, so it holds
// too. With neither, the only signal is file writes — and a file write cannot
// tell an agent sitting idle at its prompt from one closed an hour ago, so the
// setting silently delivers `.whileWorking` behaviour instead.
//
// A control that quietly does something narrower than its own label is the
// exact class of small lie this project has spent the day removing. It is not
// worth an alert or a modal — nothing is broken, and the user has not made a
// mistake — but it is worth the footer already sitting under the control,
// written in live state so it corrects itself the moment hooks are installed.

import Foundation

public enum AgentHoldCopy {

    /// The Settings row label. Reads as the first half of a sentence the popup
    /// completes: "Keep this Mac awake · While an agent is running".
    public static let settingsRowLabel = "Keep this Mac awake"

    /// The footer under the mode popup.
    ///
    /// - Parameter coverage: the best `RunningModeCoverage` among the agents
    ///   this Mac knows about, or nil when no agent has been found at all.
    ///   Ignored in `.whileWorking`, which promises nothing about presence and
    ///   therefore cannot under-deliver on it.
    public static func settingsFooter(
        mode: AgentHoldMode,
        coverage: RunningModeCoverage?
    ) -> String {
        switch mode {
        case .whileWorking:
            // The default's cost, stated plainly, because it is the thing a
            // user arriving from another keep-awake app will be surprised by —
            // and because it is also the reason to keep it: the sleep that
            // happens here is the battery that is still there in the morning.
            return mode.explanation
                + " A session left sitting at its prompt lets the Mac sleep normally,"
                + " which is what keeps it from staying awake all night on battery."
        case .whileRunning:
            // Explanation, then how well we can honour it here, then the limit
            // that outranks it. The gates clause is not boilerplate: a mode
            // whose label reads "whenever" invites the reading that it beats
            // everything, and it does not.
            return mode.explanation
                + " " + coverageClause(coverage)
                + " Low battery, Low Power Mode and fast user switching still release the hold."
        }
    }

    /// Appended to the release-grace footer while `.whileRunning` is in force,
    /// and nil otherwise.
    ///
    /// In that mode the grace period is very nearly inert: a session that stays
    /// open goes on holding whatever number is chosen, and the window only
    /// decides anything for a session that actually closes during it. A control
    /// that silently stops mattering is the same class of small lie as a mode
    /// that silently does less than its label.
    public static func gracePeriodCaveat(mode: AgentHoldMode) -> String? {
        guard mode.holdsIdleAgents else { return nil }
        return "With \u{201C}\(AgentHoldMode.whileRunning.displayName)\u{201D} selected this only decides anything for a session that closes \u{2014} one left open keeps holding either way."
    }

    /// The honesty clause, in the present tense: it changes the moment hooks are
    /// installed or the agent is found, so a user who fixes the gap sees the
    /// footer stop warning them.
    static func coverageClause(_ coverage: RunningModeCoverage?) -> String {
        guard let coverage else {
            return "No AI coding tool has been found on this Mac yet, so there is nothing for this to hold onto."
        }
        switch coverage {
        case .sessions:
            return "Hooks are installed, so Caffeinate sees each session open and close \u{2014} this does what it says."
        case .processes:
            return "With no hooks installed, Caffeinate watches for the agent's own process, which is enough to tell a session that is open from one that is closed."
        case .activityOnly:
            // Name the limit, name what the setting actually does meanwhile,
            // and name the cure. In that order: the user's question is "so
            // what am I getting?", not "what did I do wrong?".
            return "With no hooks and no process scan, Caffeinate only ever sees file writes, which cannot tell an agent idling at its prompt from one you have closed"
                + " \u{2014} so until hooks are installed this behaves like \u{201C}\(AgentHoldMode.whileWorking.displayName)\u{201D}."
        }
    }
}

// MARK: - Summarising per-agent coverage

extension RunningModeCoverage {

    /// Best-first ordering, so a summary over several agents can be taken
    /// without an exhaustive switch at every call site (the same reason
    /// `DetectionPrecision` carries `rank`).
    public var rank: Int {
        switch self {
        case .sessions: return 2
        case .processes: return 1
        case .activityOnly: return 0
        }
    }

    /// The coverage a UI should speak for, given every agent's own.
    ///
    /// Best, not worst: the question the footer answers is "can this Mac
    /// deliver the mode", and one agent it can see is enough for the answer to
    /// be yes for that agent. Agents with no coverage at all are absent from
    /// the map, which is why nil is a real answer here and means "nothing to
    /// hold onto yet" rather than "badly covered".
    public static func summary(
        of coverages: some Collection<RunningModeCoverage>
    ) -> RunningModeCoverage? {
        coverages.max { $0.rank < $1.rank }
    }
}
