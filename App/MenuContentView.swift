// MenuContentView — the `.menu`-style menu content (plan 04 §3).
//
// `.menu` constraints honored here:
// - Standard controls only: Button / Toggle / Divider / Text / Menu.
// - Content is evaluated at open time and is NOT refreshed while the menu stays
//   open — therefore every expiry string uses an ABSOLUTE time ("Until 6:32 PM",
//   Do-Not-Disturb style), never a countdown (plan 04 §3 / review decision R7).
//
// This file is assembly only. Every user-visible string comes from
// MenuTextFormatter (pure, unit-tested next door) or from DecafCore's copy
// owners, never inline here (plan 04 step 3 acceptance) — and the one group
// whose SHAPE varies with state, the rows above the first divider, is decided
// by MenuLayout (also pure, also next door) so the App test bundle can assert
// the exact rows a state produces instead of trusting a view body.

import AppKit
import SwiftUI
import DecafCore
import HookWire

// MARK: - MenuContentView (plan 04 §3 structure, top to bottom)

struct MenuContentView: View {
    @ObservedObject var store: AppStateStore
    let commands: any AppCommands
    @ObservedObject var settings: UISettings
    let toggleGate: ManualToggleGate
    let tabRouter: SettingsTabRouter
    let customHold: CustomHoldPresenter

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Evaluated when the menu opens; absolute-time strings stay correct
        // even if the menu is left open (plan 04 §3 / risk 2).
        let snapshot = store.snapshot
        let now = Date()
        // Both "Until" surfaces resolve against this one `now`, so the label a
        // user reads and the deadline the click commits are the same instant.
        let defaultUntil = UntilOptions.nextOccurrence(
            minutesSinceMidnight: settings.untilTimeMinutes, now: now
        )
        let untilRows = MenuLayout.untilRows(now: now)

        // The top group — status line, session rows, and the
        // detection-precision pair. WHICH of those exist, in what order, is
        // decided by `MenuLayout.topRows` (pure, unit-tested next door) rather
        // than by this body; that is also where the rule lives that a Mac which
        // has never seen a coding agent gets no agent rows at all, so the menu
        // reads as the plain keep-awake utility it also is.
        ForEach(Array(MenuLayout.topRows(
            for: snapshot, now: now
        ).enumerated()), id: \.offset) { _, row in
            switch row {
            case .status(let text),
                 .session(let text),
                 .overflow(let text),
                 .precisionDetail(let text):
                // `Text` in a `.menu` renders as a disabled item (plan 04 §2).
                Text(text)

            case .precisionAction(let title):
                Button(title) {
                    tabRouter.selectedTab = .agents
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }

            case .agentAutoToggle(let title, let isOn):
                // The one agent control. `isOn` comes from the snapshot's
                // stored choice, like "Keep Display On" — a control shows the
                // choice — and the click goes through `AppCommands` so that
                // switching off releases the agent holds in the same step
                // rather than at the next detection sweep.
                Toggle(title, isOn: Binding(
                    get: { isOn },
                    set: { commands.setAgentAutoKeepAwake($0) }
                ))
                .help(AgentAutoKeepAwakeCopy.menuHelp)
            }
        }

        Divider()

        // Main switch — equivalent to a left click on the icon (plan 04 §3/§4).
        Toggle("Keep Awake", isOn: Binding(
            get: { snapshot.manual != nil },
            set: { _ in toggleGate.requestToggle() }
        ))

        // "Keep For…" — every preset item is an action that (re)starts manual
        // mode with that duration; the active preset shows a check mark. The
        // last row is `Custom…`, which opens the panel instead of acting.
        //
        // WHICH rows, in what order, is `MenuLayout.keepForRows` (pure,
        // asserted in the App test bundle) rather than this body, for the same
        // reason the top group is: a submenu's contents are a product decision
        // and should not be able to change without walking past a test.
        Menu("Keep For…") {
            ForEach(Array(MenuLayout.keepForRows().enumerated()), id: \.offset) { _, row in
                switch row {
                case .preset(let title, let mode):
                    Toggle(title, isOn: Binding(
                        get: { snapshot.manual?.mode == mode },
                        set: { _ in commands.startManual(mode) }
                    ))
                case .custom(let title):
                    // A Button, not a Toggle: it never carries a check mark
                    // because it is not a value the hold can equal. The running
                    // hold's own duration, custom or not, is already named by
                    // the status line at the top of the menu.
                    Button(title) { customHold.present(.duration) }
                }
            }
        }

        // "Until 6:00 PM" — one click for the time set in Settings > General,
        // the hour you knock off on a normal day.
        //
        // It stays a top-level item now that the submenu below exists, and
        // that is not redundancy. The usual time is the common case, and
        // burying it inside a list of six hours would make the everyday action
        // cost a hover plus a scan — a regression paid every day to tidy up a
        // row. The pair reads the way "Keep Awake" / "Keep For…" already does:
        // the default, then the way to choose something else.
        Toggle(MenuTextFormatter.untilItemTitle(defaultUntil), isOn: Binding(
            get: { snapshot.manual?.expiry == defaultUntil.deadline },
            set: { _ in commands.holdUntil(defaultUntil.deadline) }
        ))

        // "Until…" — the same decision, made HERE instead of two windows away.
        //
        // The entries are the next whole hours after the moment the menu
        // opened, so they roll with the day and across midnight on their own
        // (UntilOptions, unit-tested in Core). Apple's Focus menu is the
        // precedent: absolute clock times you point at, not a duration to do
        // arithmetic on.
        //
        // Picking one here does NOT rewrite the stored default above — see
        // AppCommands.holdUntil. Choosing when THIS hold should end is a
        // different act from changing what "Until" means tomorrow. That holds
        // for the `Custom…` row too: it is a point-of-use pick like the rest.
        //
        // `Custom…` is what six generated hours could never cover: a time
        // between the hours, and any time more than six hours out.
        Menu(MenuTextFormatter.untilSubmenuTitle) {
            ForEach(Array(untilRows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .hour(let title, let deadline):
                    // Toggle, like the "Keep For…" items: each is an action, and
                    // the one matching the running hold's deadline carries the
                    // check mark, so the submenu also answers "when does this end?"
                    Toggle(title, isOn: Binding(
                        get: { snapshot.manual?.expiry == deadline },
                        set: { _ in commands.holdUntil(deadline) }
                    ))
                case .custom(let title):
                    Button(title) { customHold.present(.endTime) }
                }
            }
        }

        Divider()

        // The display, in its own group. "Keep Display On" modifies the hold
        // above it, but "Turn Off Display Now" is an immediate action with
        // nothing to do with duration, and filing it under the hold controls
        // would read as though it ended the hold.
        //
        // The toggle is a point-of-use override, so it appears whenever there is
        // a hold to override. That means ANY hold, not just a manual one:
        // `setDisplayPolicy` reaches live agent holds too, and the headline case
        // for this whole feature — kick off a long agent run, then darken the
        // screen — happens while the only live hold is an agent's.
        //
        // The second clause keeps the control on screen whenever the choice is
        // "on", which guarantees the item that re-enables "Turn Off Display Now"
        // always sits directly above the disabled one, never a trip to Settings
        // away. (Disabled requires the display assertion to be held, which
        // requires a live hold AND the choice being `.keepOn`, so either clause
        // alone already covers it — the pair is belt and braces.)
        if snapshot.wantsHold || snapshot.selectedDisplayPolicy == .keepOn {
            // Checked from `selectedDisplayPolicy`, not the effective one: this
            // is a control, and a control shows the choice. (The status line
            // above shows the reality — the two differ while a safety gate has
            // the hold suspended.)
            Toggle(DisplayPolicy.keepOn.menuTitle, isOn: Binding(
                get: { snapshot.selectedDisplayPolicy == .keepOn },
                set: { commands.setDisplayPolicy($0 ? .keepOn : .allowSleep) }
            ))
            .help(DisplayActionCopy.keepDisplayOnHelp)
        }

        // Holding the display awake and then blanking it fight each other — the
        // screen lights straight back up. The engine refuses the command in that
        // state (`canTurnOffDisplayNow`); the menu says so up front by disabling
        // the item rather than silently changing a policy the user chose. The
        // cure is the line directly above.
        Button(DisplayActionCopy.turnOffDisplayNow) {
            commands.turnOffDisplayNow()
        }
        .disabled(!snapshot.canTurnOffDisplayNow)
        // Available: say what it does NOT do. Unavailable: say why, and name
        // the cure. An NSMenuItem has one tooltip, so the reason wins when
        // there is one.
        .help(snapshot.turnOffDisplayUnavailableReason ?? DisplayActionCopy.turnOffDisplayNowHelp)

        // The footer of this group, in the shape the settings pane uses for its
        // cards: one quiet line explaining the two rows above it.
        //
        // Not left to the tooltips alone. "Turn Off Display Now" sits one line
        // from "Quit Decaf" and reads like an off switch — the fear it
        // raises is that darkening the screen also stops the agent that is
        // mid-run, which is the exact opposite of what this app does. A
        // reassurance that only appears after a two-second hover is a
        // reassurance most people never receive, and the cost here is one short
        // line no wider than the rows it explains.
        Text(DisplayActionCopy.screenOnlyNote)

        Divider()

        // openSettings (macOS 14+) + explicit activation so the window fronts
        // (plan 04 §3 / risk 4).
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Quit Decaf") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
