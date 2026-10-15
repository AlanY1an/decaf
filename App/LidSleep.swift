// LidSleep — the app side of "Keep running with the lid closed" (plan 07).
//
// Three pieces, all thin:
// - LidSleepHelperClient: SMAppService.daemon + privileged XPC to the root
//   helper embedded at Contents/MacOS/decaf-lid-helper. Every decision about
//   WHEN to hold lives in DecafCore's LidSleepController; this only carries the
//   requests.
// - LidSleepGate: the one way the menu and Settings turn the switch on. It owns
//   the heat warning (shown on every switch-on until the user ticks "Don't
//   show this again") and the "allow the helper in Login Items" step.
// - LidSleepSettingsRow: the Settings row, bound through the gate.

import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI
import DecafCore
import LidSleepXPC

// MARK: - Helper client

struct LidSleepHelperError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class LidSleepHelperClient: LidSleepHelperConnecting {
    var onConnectionLost: (@MainActor () -> Void)?

    private let service = SMAppService.daemon(plistName: LidSleepXPC.daemonPlistName)
    /// Read once: the app's signature does not change while it runs.
    private let helperRequirement = LidSleepXPC.requirement(forPeer: LidSleepXPC.helperIdentifier)
    private var connection: NSXPCConnection?
    private var registrationError: String?

    /// launchd's background-item database breaks daemon registration for apps
    /// run from anywhere else (including Gatekeeper's translocated copies).
    private static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.path
        return path.hasPrefix("/Applications/") && !path.contains("/AppTranslocation/")
    }

    var availability: LidSleepHelperAvailability {
        guard helperRequirement != nil else { return .unavailable(.unsignedBuild) }
        guard Self.isInApplications else { return .unavailable(.notInApplications) }
        switch service.status {
        case .enabled: return .ready
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound:
            if let registrationError { return .unavailable(.registrationFailed(registrationError)) }
            return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    @discardableResult
    func register() -> LidSleepHelperAvailability {
        do {
            try service.register()
            registrationError = nil
        } catch {
            // A first registration throws "Operation not permitted" and leaves
            // the daemon waiting for approval; that is the normal path.
            if service.status != .requiresApproval && service.status != .enabled {
                registrationError = error.localizedDescription
            }
        }
        return availability
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func acquire() async throws {
        var revision = try await request { helper, done in helper.helperRevision { done($0) } }
        if revision != LidSleepXPC.revision {
            // A helper from another build is still running; launchd starts the
            // bundled one on the next lookup once this one exits.
            if let helper = connection?.remoteObjectProxy as? DecafLidHelperXPC { helper.exitForUpgrade() }
            dropConnection()
            try await Task.sleep(nanoseconds: 500_000_000)
            revision = try await request { helper, done in helper.helperRevision { done($0) } }
            guard revision == LidSleepXPC.revision else {
                throw LidSleepHelperError(message: "the helper is out of date")
            }
        }
        let (ok, message): (Bool, String?) = try await request { helper, done in
            helper.acquire { ok, message in done((ok, message)) }
        }
        guard ok else { throw LidSleepHelperError(message: message ?? "the helper refused") }
    }

    func release() async {
        _ = try? await request { helper, done in helper.release { done(()) } }
        // Nothing held: let the helper go idle and exit.
        dropConnection()
    }

    func heartbeat() {
        (connection?.remoteObjectProxy as? DecafLidHelperXPC)?.heartbeat()
    }

    // MARK: XPC plumbing

    private func makeConnection() throws -> NSXPCConnection {
        if let connection { return connection }
        guard let helperRequirement else { throw LidSleepHelperError(message: "this copy of Decaf isn’t signed") }
        let connection = NSXPCConnection(machServiceName: LidSleepXPC.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: DecafLidHelperXPC.self)
        // Guards against a squatted service name or a swapped helper binary.
        connection.setCodeSigningRequirement(helperRequirement)
        let lost: @Sendable () -> Void = { [weak self, weak connection] in
            Task { @MainActor in self?.connectionEnded(connection) }
        }
        connection.invalidationHandler = lost
        connection.interruptionHandler = lost
        connection.resume()
        self.connection = connection
        return connection
    }

    private func connectionEnded(_ ended: NSXPCConnection?) {
        guard let ended, ended === connection else { return }
        connection = nil
        ended.invalidate()
        onConnectionLost?()
    }

    /// Forgets the connection before invalidating it, so the invalidation is
    /// not reported as a loss.
    private func dropConnection() {
        let old = connection
        connection = nil
        old?.invalidate()
    }

    /// One request with a reply, an XPC error, or a 10 s timeout — whichever
    /// comes first resumes the caller, exactly once.
    private func request<T: Sendable>(
        _ body: @escaping (DecafLidHelperXPC, @escaping @Sendable (T) -> Void) -> Void
    ) async throws -> T {
        let connection = try makeConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(throwing: error)
            }
            guard let helper = proxy as? DecafLidHelperXPC else {
                once.resume(throwing: LidSleepHelperError(message: "the helper could not be reached"))
                return
            }
            body(helper) { once.resume(returning: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                once.resume(throwing: LidSleepHelperError(message: "the helper did not answer"))
            }
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(returning value: T) { take()?.resume(returning: value) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }
}

// MARK: - Gate

/// The menu item and the Settings row both go through here, so the warning
/// cannot be skipped from either.
@MainActor
final class LidSleepGate: ObservableObject {
    @Published private(set) var status: LidSleepStatus

    private let store: AppStateStore
    private let commands: any AppCommands
    private let settings: SettingsStore
    private var sink: AnyCancellable?

    init(store: AppStateStore, commands: any AppCommands, settings: SettingsStore) {
        self.store = store
        self.commands = commands
        self.settings = settings
        self.status = store.snapshot.lidSleep
        sink = store.$snapshot
            .map(\.lidSleep)
            .removeDuplicates()
            .sink { [weak self] in self?.status = $0 }
    }

    func request(_ on: Bool) {
        guard on else {
            commands.setLidSleepEnabled(false)
            return
        }
        if !settings.lidSleepWarningSuppressed {
            let answer = confirm(
                title: LidSleepCopy.consentTitle,
                body: LidSleepCopy.consentBody,
                button: LidSleepCopy.consentConfirm,
                suppression: LidSleepCopy.consentSuppress
            )
            guard answer.confirmed else { return }
            // Only a confirmed switch-on can silence the warning; ticking the
            // box and then cancelling changes nothing.
            if answer.suppress { settings.lidSleepWarningSuppressed = true }
        }
        commands.setLidSleepEnabled(true)
        if store.snapshot.lidSleep == .needsApproval {
            presentApproval()
        }
    }

    func presentApproval() {
        if confirm(title: LidSleepCopy.approvalTitle, body: LidSleepCopy.approvalBody,
                   button: LidSleepCopy.approvalConfirm).confirmed {
            commands.openLidSleepApprovalSettings()
        }
    }

    private func confirm(
        title: String, body: String, button: String, suppression: String? = nil
    ) -> (confirmed: Bool, suppress: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        if let suppression {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = suppression
        }
        NSApp.activate(ignoringOtherApps: true)
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        return (confirmed, alert.suppressionButton?.state == .on)
    }
}

// MARK: - Settings row

struct LidSleepSettingsRow: View {
    @ObservedObject var gate: LidSleepGate

    var body: some View {
        DecafPreferenceRow(title: LidSleepCopy.settingsTitle, detail: LidSleepCopy.statusLine(gate.status)) {
            HStack(spacing: 10) {
                if gate.status == .needsApproval {
                    Button("Open Login Items…") { gate.presentApproval() }.controlSize(.small)
                }
                Toggle(LidSleepCopy.settingsTitle, isOn: Binding(
                    get: { gate.status.isOn },
                    set: { gate.request($0) }
                )).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }
}
