// AgentAutoKeepAwakeCopy — every user-visible word for the one agent switch.
//
// One switch, two surfaces (the menu and Settings › Agents), one vocabulary:
// both read `title` from here, so the control a user finds in Settings is
// recognizably the control they saw in the menu. This is the same rule
// `DisplayActionCopy` and `DisplayPolicy.menuTitle` / `.settingsTitle` already
// follow — copy for a behaviour lives in DecafCore, next to the behaviour,
// never inline in a view.
//
// On the wording, since it is the whole of what a user has to understand cold:
//
// - **"Auto Keep Awake for Agents"** (chosen). It borrows the app's own verb —
//   the menu right below says "Keep Awake" — and adds the two things that
//   distinguish this row from that one: it happens by itself ("Auto"), and it
//   is about agents. A reader who knows nothing about this app can still tell
//   that unchecking it stops something automatic, and that the manual switch
//   below is a different thing.
// - **"Detect AI Agents Automatically"** (rejected). It names our plumbing
//   instead of the user's outcome: detection is a means, staying awake is the
//   point. Worse, it leaves the actual question unanswered — a user reading it
//   cannot tell whether turning it off also stops the manual hold, or merely
//   stops some status display.
//
// The word "mode" appears nowhere. There is no mode: there is one behaviour,
// and this is its on/off switch.

import Foundation

public enum AgentAutoKeepAwakeCopy {

    /// The menu row and the Settings row. Deliberately the same string — two
    /// labels for one switch drift, and a user who meets the drifted pair has
    /// to work out whether they are looking at one setting or two.
    public static let title = "Auto Keep Awake for Agents"

    /// The menu item's tooltip. Says what the switch does, then what turning it
    /// off leaves you with — because that second half is the actual question a
    /// user hovering here is asking ("will this stop my Mac staying awake at
    /// all?").
    public static let menuHelp = """
        Keeps this Mac awake while a coding agent is working, and lets it sleep \
        as soon as the agent is waiting on you. Turn it off and Decaf \
        ignores agents entirely — the switches below still work.
        """

    /// The Settings › Agents card footer. Same promise, plus the two facts a
    /// settings page owes that a tooltip cannot fit: the default, and that
    /// switching off is immediate rather than "from the next session".
    public static let settingsFooter = """
        On by default. Turn it off and Decaf ignores coding agents \
        completely: any keep-awake an agent had started is released straight \
        away, and from then on the Mac stays awake only while you keep it awake \
        yourself.
        """
}
