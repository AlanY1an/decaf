// StatusItemBridge — AppKit bridge for left-click toggle (plan 04 §4, option A).
//
// MenuBarExtra has no public API to distinguish left from right clicks; this
// bridge locates the underlying NSStatusItem (keepresso's StatusItemBridge is
// the reference for the technique), takes over the button's target/action, and:
//   left click            -> onToggle() (never opens the menu)
//   right / control click -> forwards to the original target/action (menu)
//
// Graceful degradation is mandatory (plan 04 §4): if the status item cannot be
// located (future system change), the bridge silently does nothing — clicks
// keep opening the menu, nothing crashes, the icon stays.

import AppKit

@MainActor
final class StatusItemBridge: NSObject {
    private let onToggle: () -> Void

    private weak var button: NSStatusBarButton?
    private weak var forwardTarget: AnyObject?
    private var forwardAction: Selector?
    private var attachAttempts = 0
    private static let maxAttachAttempts = 12

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    /// Starts polling for the MenuBarExtra's status item; the scene creates it
    /// asynchronously after launch, hence the short retry loop.
    func start() {
        attemptAttach()
    }

    /// Updates the status button's VoiceOver label with the icon state
    /// (plan 04 §4 accessibility).
    func updateAccessibility(label: String) {
        button?.setAccessibilityLabel(label)
    }

    // MARK: - Attachment

    private func attemptAttach() {
        if attach() { return }
        attachAttempts += 1
        guard attachAttempts < Self.maxAttachAttempts else {
            // Degraded mode: left click opens the menu; all features remain.
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.attemptAttach()
        }
    }

    /// Locates the status-bar window backing our MenuBarExtra and rewires its
    /// button. Relies on non-contract behavior (NSStatusBarWindow + its
    /// `statusItem` accessor) — every access is guarded so failure degrades.
    private func attach() -> Bool {
        for window in NSApp.windows {
            guard window.className.contains("NSStatusBarWindow") else { continue }
            guard window.responds(to: NSSelectorFromString("statusItem")),
                  let statusItem = window.value(forKey: "statusItem") as? NSStatusItem,
                  let button = statusItem.button
            else { continue }

            self.button = button
            forwardTarget = button.target
            forwardAction = button.action
            button.target = self
            button.action = #selector(didClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            return true
        }
        return false
    }

    // MARK: - Click routing

    @objc private func didClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event.map {
            $0.type == .rightMouseUp || $0.modifierFlags.contains(.control)
        } ?? true // unknown event: safest is opening the menu
        if wantsMenu {
            openMenu(from: sender)
        } else {
            onToggle()
        }
    }

    private func openMenu(from sender: NSStatusBarButton) {
        guard let action = forwardAction else { return }
        _ = NSApp.sendAction(action, to: forwardTarget, from: sender)
    }
}
