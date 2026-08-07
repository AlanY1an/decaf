// CustomHoldPanel — the small window behind "Custom…" in both manual submenus.
//
// Why a window at all, when everything else in this app is a menu item:
// `MenuBarExtra(.menu)` renders a real `NSMenu`, and an `NSMenu` hosts standard
// menu items only. There is no text field, no stepper and no `DatePicker` that
// can live in one — SwiftUI silently drops anything else (plan 04 §2). So the
// classic Mac answer is the only answer: a `Custom…` item that opens a small
// panel. Clicking it dismisses the menu, which is ordinary `NSMenu` behaviour
// and exactly what "Settings…" has always done here.
//
// The panel is a THIN VIEW. It owns one input, a preview line and two buttons;
// every judgement it appears to make — whether a typed duration is readable, in
// range, what instant it means, which words to say when it is not — is
// `CaffeinateCore.CustomHoldInput`, unit-tested next to the rest of the "when
// does this hold end" math (plan 04 step 3 acceptance).
//
// Two properties this file is responsible for, both of which are easy to lose:
//
// - **It comes to the front and takes the keyboard.** Caffeinate is
//   `LSUIElement`: it has no Dock icon and is not a foreground app, so a window
//   ordered front from a menu can appear behind whatever the user was doing and
//   never become key. `OnboardingWindow` already solved this — `NSApp.activate`
//   first, then `showWindow`, then `makeKeyAndOrderFront` — and this follows it
//   rather than inventing a second way to do the same thing.
// - **It cannot express an instant in the past.** Not by validating one away:
//   by construction. A duration is a length, and the end-time mode resolves
//   through `CustomHoldInput.endTime`, whose answer is always the NEXT
//   occurrence. Plan 05 D4's rule (`holdUntil` refuses a past deadline and
//   leaves any running hold alone) therefore never fires from here, which is
//   the point — for a user who has just typed a time and pressed Return, a
//   silent refusal is indistinguishable from a broken app.

import AppKit
import SwiftUI
import CaffeinateCore

// MARK: - Presenter

/// Opens the panel, and owns the one window there is.
///
/// Held by `AppEnvironment` and handed to `MenuContentView`, the same shape
/// `SettingsTabRouter` and `ManualToggleGate` already use: the view calls one
/// method and knows nothing about `NSWindow`.
@MainActor
final class CustomHoldPresenter {
    private let commands: any AppCommands
    private var controller: CustomHoldWindowController?

    init(commands: any AppCommands) {
        self.commands = commands
    }

    /// Shows the panel for `kind`, reusing the window if one is already open.
    ///
    /// Reuse rather than a second window: both entry points are rows of the
    /// same menu, so a user asking for one has necessarily finished with the
    /// other, and two small dialogs stacked on each other asking almost the
    /// same question is a state nobody wants to be in.
    func present(_ kind: CustomHoldKind) {
        let controller = self.controller ?? makeController()
        self.controller = controller
        controller.retarget(kind)

        // The activation dance, in the order OnboardingWindow established.
        // `activate` first: without it an LSUIElement app's new window can be
        // ordered front and still never become key, leaving a text field that
        // looks focused and swallows every keystroke.
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func makeController() -> CustomHoldWindowController {
        CustomHoldWindowController(
            commit: { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .duration(let seconds):
                    // `startManual`, like every preset row — a point-of-use
                    // choice that does not touch `defaultManualMode`.
                    self.commands.startManual(.duration(seconds))
                case .deadline(let instant):
                    // `holdUntil`, like every "Until" row — and, per R7-A, this
                    // never rewrites `SettingsStore.untilTime`. What "Until"
                    // means tomorrow is a preference and is changed in Settings;
                    // this is only about this hold.
                    self.commands.holdUntil(instant)
                }
                self.controller?.close()
            },
            didClose: { [weak self] in self?.controller = nil }
        )
    }
}

/// What a confirmed panel produces. Two cases because the two modes commit
/// through two different commands, and collapsing them would mean turning a
/// duration into a deadline here — re-deriving in the view layer exactly the
/// thing plan 05 D4 says only the controller may fold.
enum CustomHoldOutcome: Equatable {
    case duration(TimeInterval)
    case deadline(Date)
}

// MARK: - Window controller

@MainActor
final class CustomHoldWindowController: NSWindowController, NSWindowDelegate {

    /// Indirection so the view can reach the controller's callbacks before
    /// `self` exists (the same relay trick `OnboardingWindowController` uses).
    @MainActor
    private final class Relay {
        var kind: CustomHoldKind = .duration
        var commit: (CustomHoldOutcome) -> Void = { _ in }
        var cancel: () -> Void = {}
    }

    private let relay = Relay()
    private let model = CustomHoldModel()
    private let didClose: () -> Void

    init(
        commit: @escaping (CustomHoldOutcome) -> Void,
        didClose: @escaping () -> Void
    ) {
        self.didClose = didClose
        let relay = self.relay
        relay.commit = commit

        let hosting = NSHostingController(
            rootView: CustomHoldView(
                model: model,
                commit: { outcome in relay.commit(outcome) },
                cancel: { relay.cancel() }
            )
        )
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.collectionBehavior = [.fullScreenNone]
        window.isRestorable = false
        window.center()
        super.init(window: window)
        window.delegate = self
        relay.cancel = { [weak self] in self?.close() }
    }

    /// Point the open window at the other question. Resets the input, because
    /// carrying "90" over into a time picker would be nonsense, and re-titles
    /// the window so it always names the menu path that opened it.
    func retarget(_ kind: CustomHoldKind) {
        relay.kind = kind
        model.reset(to: kind)
        window?.title = CustomHoldCopy.windowTitle(kind)
        // Sized to its content, then pinned: this is a dialog, not something to
        // drag out. Two rows and two buttons need no more.
        window?.setContentSize(NSSize(width: 380, height: 168))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Closing by any route — the red button, Escape, a confirm — drops the
    /// controller, so the next `Custom…` starts from a clean field rather than
    /// whatever was left in it half an hour ago.
    func windowWillClose(_ notification: Notification) {
        didClose()
    }
}

// MARK: - Model

/// The panel's editable state, plus the one derived value the view renders.
///
/// An `ObservableObject` rather than `@State` so the window controller can reset
/// it when the window is retargeted, and so `now` can tick. The class holds no
/// rules: every `parse`/`endTime` call below is a Core function.
@MainActor
private final class CustomHoldModel: ObservableObject {
    @Published var kind: CustomHoldKind = .duration
    @Published var durationText = ""
    @Published var endTime = Date()
    /// Re-read on a timer so the preview line cannot go stale in an open
    /// window. The menu gets to freeze its strings because it is torn down
    /// within seconds; a panel can sit on screen through a whole hour boundary,
    /// and a preview that says "6:00 PM today" while the commit would produce
    /// tomorrow's would be the panel lying about the one thing it exists to
    /// show.
    @Published var now = Date()

    func reset(to kind: CustomHoldKind) {
        self.kind = kind
        durationText = ""
        now = Date()
        // The picker starts at the next whole hour — the same instant the top
        // of the "Until…" submenu offers, so opening `Custom…` from that list
        // starts where the list left off rather than at some unrelated time.
        endTime = UntilOptions.upcomingWholeHours(count: 1, now: now).first?.deadline ?? now
    }

    /// What Return would commit right now, or why it is unavailable.
    ///
    /// One computed property for both modes, because the view's preview line,
    /// its error line and its confirm button all need the same answer and
    /// deriving it three times is how they drift apart.
    var resolution: Resolution {
        switch kind {
        case .duration:
            switch CustomHoldInput.parseDuration(durationText) {
            case .success(let seconds):
                return .ready(
                    outcome: .duration(seconds),
                    option: UntilOptions.deadline(after: seconds, now: now)
                )
            case .failure(let problem):
                return .blocked(problem)
            }
        case .endTime:
            // Always resolvable: `endTime` returns the next occurrence, so
            // there is no input a picker can produce that this refuses.
            let option = CustomHoldInput.endTime(forTimeOfDay: endTime, now: now)
            return .ready(outcome: .deadline(option.deadline), option: option)
        }
    }

    enum Resolution {
        case ready(outcome: CustomHoldOutcome, option: UntilOption)
        case blocked(CustomHoldInput.DurationProblem)
    }
}

// MARK: - View

/// Assembly only. Two rows — one input, one resolved line — and two buttons.
private struct CustomHoldView: View {
    @ObservedObject fileprivate var model: CustomHoldModel
    let commit: (CustomHoldOutcome) -> Void
    let cancel: () -> Void

    /// Focus lands in the input when the window opens, so the panel is usable
    /// from the keyboard from the first keystroke: type, Return. That is the
    /// whole interaction, and it is the reason this is a panel and not a
    /// settings page.
    @FocusState private var inputFocused: Bool

    /// One tick a second, only while this window is on screen. Cheap, and it is
    /// what keeps the resolved line honest across an hour boundary.
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            input

            Text(CustomHoldCopy.hint(model.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            resolvedLine

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(CustomHoldCopy.cancelTitle) { cancel() }
                    // Escape. Also what the red button does, so there is no
                    // route out of this window that commits something.
                    .keyboardShortcut(.cancelAction)
                Button(CustomHoldCopy.confirmTitle) { confirm() }
                    // Return, and the blue default button that says so.
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isReady)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { inputFocused = true }
        .onReceive(clock) { model.now = $0 }
    }

    @ViewBuilder
    private var input: some View {
        switch model.kind {
        case .duration:
            // A single free-text field rather than two number steppers: with
            // one field there is nothing to tab between, so "type it and press
            // Return" is literally the whole gesture. The cost is a grammar,
            // and the grammar is parsed and tested in Core.
            TextField(
                CustomHoldCopy.fieldLabel(.duration),
                text: $model.durationText,
                prompt: Text(CustomHoldCopy.durationPrompt)
            )
            .textFieldStyle(.roundedBorder)
            .focused($inputFocused)
            // Return inside the field commits too, rather than only the default
            // button doing it — a field that swallows Return feels broken.
            .onSubmit { confirm() }

        case .endTime:
            // `.stepperField` is the typeable one: the hour and minute fields
            // accept digits and arrow keys, which is what "keyboard-first"
            // means for a time. A graphical clock would be mouse-only.
            DatePicker(
                CustomHoldCopy.fieldLabel(.endTime),
                selection: $model.endTime,
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.stepperField)
            .labelsHidden()
            .focused($inputFocused)
        }
    }

    /// The line that says what Return is about to do, or what is wrong.
    ///
    /// It occupies the same slot in both cases so the buttons never move under
    /// the pointer as the user types.
    @ViewBuilder
    private var resolvedLine: some View {
        switch model.resolution {
        case .ready(_, let option):
            Text(CustomHoldCopy.resolvedLine(option, now: model.now))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case .blocked(let problem):
            Text(problem.message)
                .font(.callout)
                // `.empty` is the state of a field nobody has typed in yet, not
                // a mistake — colouring it red would greet every user with an
                // error they have not made.
                .foregroundStyle(problem == .empty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isReady: Bool {
        if case .ready = model.resolution { return true }
        return false
    }

    /// Re-resolves at the instant of the click rather than trusting whatever
    /// the preview last rendered. Belt and braces next to the ticking clock:
    /// this is the value that actually becomes a hold.
    private func confirm() {
        model.now = Date()
        guard case .ready(let outcome, _) = model.resolution else { return }
        commit(outcome)
    }
}
