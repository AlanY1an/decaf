// AgentHoldMode — WHEN an agent keeps this Mac awake.
//
// Placement, like `DetectionPrecision`: the detection layer decides with it and
// `AppStateSnapshot` displays it, and AgentDetection depends on CaffeinateCore
// (never the other way round), so the definition lives here and AgentDetection
// re-exports it. Consumers of either module see the same type.
//
// The two answers this app can give to "when should an agent hold?" are
// genuinely different products, and neither is wrong:
//
// - `.whileWorking` is what Caffeinate is FOR. It holds while a turn is in
//   flight and lets go afterwards, so a REPL left open at its prompt overnight
//   does not keep a Mac awake until morning. It is the default and stays the
//   default.
// - `.whileRunning` is the blunt instrument every competitor ships: the agent
//   process exists, therefore never sleep. Three real reasons to want it —
//   being on AC and wanting zero risk; distrusting the inference layer (a
//   coarse mode leans on almost no inference, which makes it a safety net when
//   detection is wrong); and arriving from another tool that behaves this way.
//
// What the mode does NOT change, in either direction:
//
// - every safety gate. Low battery, Low Power Mode, fast user switching and a
//   user-initiated sleep all release exactly as they do today. A mode is a
//   statement about agents, not a licence to outrank the user or the hardware;
// - the stuck downgrade. A `.working` record all four witnesses have
//   contradicted lands in `SessionState.stuck`, which holds in NEITHER mode.
//   Without that, `.whileRunning` would re-open the hole the downgrade closed:
//   "Mac never sleeps, silently, forever".

/// When an agent session keeps this Mac awake (plan 02 §1.2 + today's mode
/// ruling).
public enum AgentHoldMode: String, CaseIterable, Codable, Sendable, Hashable {
    /// Hold only while the agent is actually working — a turn in flight, a
    /// permission prompt on screen, the post-Stop grace window, or a declared
    /// wait. The factory default, and the product's whole point.
    case whileWorking
    /// Hold whenever an agent is present at all, including a session sitting
    /// idle at its prompt. Released when the agent goes away.
    case whileRunning
}

extension AgentHoldMode {

    /// Whether a merely-present agent (idle at its prompt, or a running process
    /// with no session events) holds in this mode.
    public var holdsIdleAgents: Bool { self == .whileRunning }

    /// Menu / Settings label. Single owner, like `DisplayActionCopy` (R17).
    public var displayName: String {
        switch self {
        case .whileWorking: return "While an agent is working"
        case .whileRunning: return "While an agent is running"
        }
    }

    /// The one-line explanation under the picker. Says what it costs, because
    /// the costly one is the one people pick without reading.
    public var explanation: String {
        switch self {
        case .whileWorking:
            return "Keeps this Mac awake while an agent has work in flight, "
                + "and lets it sleep once the agent is done."
        case .whileRunning:
            return "Keeps this Mac awake for as long as an agent is open at all "
                + "— including one sitting idle at its prompt."
        }
    }
}

// MARK: - Coverage

/// How well `.whileRunning` can actually be delivered for one agent.
///
/// "Whenever an agent is running" is a claim about a PROCESS, and the app has
/// three different amounts of evidence for that claim depending on what is
/// installed. Publishing which one is in force is the difference between a mode
/// that means what it says and a mode that quietly means something narrower:
/// with no hooks and no process scan the app only ever sees file writes, and a
/// file write cannot tell a running-but-idle agent from a closed one — so
/// `.whileRunning` would silently behave exactly like `.whileWorking`.
///
/// The UI is expected to say so (see `MenuCopy.holdModeNote`). Reporting this
/// is not optional politeness: a hold mode that silently under-delivers is the
/// same class of quiet lie as a precision indicator that reports the fallback
/// layer for a live hooks install.
public enum RunningModeCoverage: Sendable, Equatable, Hashable {
    /// Hook events name every session, including one sitting idle at its
    /// prompt, so presence is known session by session.
    case sessions
    /// No hooks, but the process table is being scanned for this agent, so
    /// presence is known process by process.
    case processes
    /// Neither. Only file writes are visible, which see activity and never
    /// presence — `.whileRunning` cannot be delivered for this agent and
    /// degrades to `.whileWorking` behaviour.
    case activityOnly
}

extension RunningModeCoverage {

    /// True when `.whileRunning` means what it says for this agent.
    public var deliversRunningMode: Bool { self != .activityOnly }
}
