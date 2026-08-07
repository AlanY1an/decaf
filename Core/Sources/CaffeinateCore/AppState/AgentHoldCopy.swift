// AgentHoldCopy — every sentence this app says about `AgentHoldMode`: the
// menu's status line for the mode's own hold, and what Settings › Agents says
// about the mode, including the clause that admits when it cannot be delivered.
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
import HookWire

public enum AgentHoldCopy {

    // MARK: - The menu status line for the mode's own hold

    /// The status line for a hold with no work behind it — an agent that is
    /// merely THERE, which is the only kind of hold `.whileRunning` adds and
    /// the only hold in this app that no turn, prompt or grace window explains
    /// (plan 04 §3, the two `.whileRunning` rows).
    ///
    /// Two sentences, and which one is used is not a matter of taste:
    ///
    /// - **We watched it go idle.** A hook-tracked session sitting at its
    ///   prompt reported its own Stop. "Open, not working" is then a fact, and
    ///   the clause after the dot names the only release condition this hold
    ///   has — the session closing. No instant appears because there is no
    ///   instant to name; plan 04 §3's absolute-time rule forbids counting
    ///   down, it does not license inventing a deadline.
    /// - **We only know a process exists.** The process table sees processes,
    ///   never turns. It cannot tell an agent waiting at its prompt from one
    ///   three minutes into a tool call that has not touched a file — and
    ///   holding through that second case is the whole reason to pick this
    ///   mode. So the sentence claims presence and nothing else, and names the
    ///   release condition in the same terms it actually knows: the process
    ///   going away.
    ///
    /// What is deliberately NOT said here: how well the agent is being watched.
    /// That is the precision row directly below this one, for the same reason
    /// the file-activity line does not repeat it — a status line that qualifies
    /// itself is a headline about our plumbing instead of about the user's Mac.
    ///
    /// - Parameters:
    ///   - agent: the agent the sentence is about (the first of the held set).
    ///   - agentCount: how many agents are held this way; > 1 replaces the
    ///     release clause with a count, exactly as the "working" line does.
    ///   - knownOnlyByProcess: true when nothing but a process match stands
    ///     behind this agent's hold (`AppStateSnapshot.processOnlyRunningAgents`).
    public static func runningIdleStatusLine(
        agent: AgentKind,
        agentCount: Int,
        knownOnlyByProcess: Bool
    ) -> String {
        let name = agent.displayName
        if knownOnlyByProcess {
            return agentCount == 1
                ? "\(name) is running · Sleep blocked until it quits"
                : "\(name) is running · \(agentCount) agents"
        }
        return agentCount == 1
            ? "\(name) open, not working · Sleep blocked until it closes"
            : "\(name) open, not working · \(agentCount) agents"
    }

    // MARK: - The menu's mode toggle

    /// The menu item that switches the hold mode, in the shape `Keep Display On`
    /// established: one checkable line that writes the persisted default.
    ///
    /// Why a Toggle and not the two-value picker Settings uses. In Settings the
    /// popup is right — it shows both behaviours side by side and neither is
    /// "off". In the menu a two-item radio submenu costs a hover plus a scan to
    /// read a binary, and `MenuBarExtra(.menu)` renders a checked Toggle as
    /// exactly the affordance a user already knows. One checkable line says it.
    ///
    /// Why the title is longer than its neighbours. This string is the whole
    /// explanation. Someone opening this menu has not read the Settings footer
    /// and may never, so "While an agent is running" — perfectly clear once you
    /// know the app distinguishes running from working — would land as a
    /// tautology: of course it keeps the Mac awake while the agent runs, that
    /// is the app. The word that carries the meaning is **idle**, and it names
    /// the case the checkmark actually adds: the agent is open and doing
    /// nothing. "Even" makes it read as an addition to the default rather than
    /// a replacement for it.
    ///
    /// It is not left to the tooltip, for R17's reason: a tooltip needs a
    /// two-second hover, and most people never hover.
    public static let menuToggleTitle = "Keep Awake Even When an Agent Is Idle"

    /// The toggle's `.help()` — what the two positions do, and how well this
    /// particular Mac can deliver the checked one.
    ///
    /// The coverage clause is the same one Settings shows, from the same
    /// function, because it is the same admission: with neither hooks nor a
    /// process scan, "even when idle" cannot be delivered — file writes see
    /// activity, never presence — and a control that quietly does less than its
    /// label is the class of small lie this project keeps removing.
    ///
    /// The tooltip is the right place for THAT clause even though it is the
    /// wrong place for the title above. The title has to teach the control to
    /// someone who has not decided anything yet; the caveat only matters to
    /// someone who has already turned it on, whose next stop is Settings ›
    /// Agents, where the same sentence sits in the open under the picker.
    ///
    /// - Parameter coverage: `AppStateSnapshot.summaryRunningModeCoverage`.
    public static func menuToggleHelp(coverage: RunningModeCoverage?) -> String {
        AgentHoldMode.whileRunning.explanation
            + " Unchecked, the hold ends when the agent finishes and the Mac sleeps normally."
            + " " + coverageClause(coverage)
    }

    // MARK: - Settings › Agents

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
