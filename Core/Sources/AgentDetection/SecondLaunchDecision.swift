// SecondLaunchDecision — what the second copy of the app does with each
// outcome of `SingleInstanceControl.requestReopenUI` (plan 04 step 1).
//
// This lives here, next to the mechanism, rather than in the app target for the
// usual reason (plan 06 §4): the app target's test bundle is a logic bundle
// that cannot host AppEnvironment, so anything left in App/ is untested. What
// remains in `AppEnvironment.startCoreOrQuit` after this type exists is a
// switch that runs an NSAlert or calls terminate — no decisions, no strings.
//
// The copy is deliberately blunt about the escape hatch. The user who reaches
// the `.notResponding` branch has already tried the one thing they know how to
// try, so the sentence has to name the next thing precisely enough to act on
// without knowing what a menu bar extra is.

import Foundation

/// A message the second copy shows before leaving.
public struct SecondLaunchMessage: Equatable, Sendable {
    public let title: String
    public let body: String
    public let buttonTitle: String

    public init(title: String, body: String, buttonTitle: String) {
        self.title = title
        self.body = body
        self.buttonTitle = buttonTitle
    }
}

/// What the second copy should do. Every case ends with the second copy gone or
/// promoted; none of them leaves it running alongside the lock holder, and none
/// of them waits on anything.
public enum SecondLaunchAction: Equatable, Sendable {
    /// The running instance is bringing Settings forward. Leave without a word:
    /// the user is about to be looking at the window they wanted.
    case exitSilently
    /// Nothing owns the lock after all. Try to take it — the second copy
    /// becomes the running instance.
    case retryStart
    /// Someone owns the lock and cannot be reached. Say so, then leave.
    case reportAndExit(SecondLaunchMessage)
}

public enum SecondLaunchDecision {
    /// The one message this flow can produce.
    ///
    /// It says what is wrong, and then the two things the user can do, in the
    /// order they should try them — Activity Monitor is named in full because
    /// "force quit" means nothing to someone who has never had to.
    public static let notRespondingMessage = SecondLaunchMessage(
        title: "Caffeinate is already running, but it is not responding.",
        body: """
        The copy that is running did not answer, so it cannot open its window \
        for you.

        Force-quit it — press Option-Command-Escape, or find Caffeinate in \
        Activity Monitor — and then open Caffeinate again.
        """,
        buttonTitle: "OK"
    )

    public static func action(for outcome: SingleInstanceReopenOutcome) -> SecondLaunchAction {
        switch outcome {
        case .acknowledged:
            return .exitSilently
        case .noInstance:
            return .retryStart
        case .notResponding:
            return .reportAndExit(notRespondingMessage)
        }
    }
}
