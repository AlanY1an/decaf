// LaunchAtLoginTests — the login-item preference (plan 04 §5 General, §6 step 3).
//
// Two regressions are pinned here, both from onboarding:
//
// 1. Registration failed silently. `try? SMAppService.mainApp.register()` threw
//    away the error and never re-read the status, so a registration parked in
//    `.requiresApproval` — or one that failed outright — left a ticked checkbox
//    and an unprotected Mac.
// 2. Registration was skipped entirely when the window was dismissed with the
//    red button instead of the Done button. Onboarding never reappears, so that
//    user's next overnight run had no login item behind it.
//
// `SMAppService` cannot be driven from a test, so the rule lives in
// CaffeinateCore over an injected registrar and the app keeps only the adapter.

import Foundation
import Testing
@testable import CaffeinateCore

// MARK: - Test double

private struct RegistrarError: LocalizedError {
    var errorDescription: String? { "Operation not permitted (test)" }
}

/// A stand-in for `SMAppService.mainApp`. `outcomeOfRegister` is what the system
/// decides the status becomes once `register()` returns.
private final class FakeRegistrar: LaunchAtLoginRegistering {
    var status: LaunchAtLoginStatus = .notRegistered
    var outcomeOfRegister: LaunchAtLoginStatus = .enabled
    var registerThrows = false
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    func register() throws {
        registerCount += 1
        if registerThrows { throw RegistrarError() }
        status = outcomeOfRegister
    }

    func unregister() throws {
        unregisterCount += 1
        status = .notRegistered
    }
}

// MARK: - The rule

@Suite struct LaunchAtLoginApply {

    @Test func enablingRegistersAndReportsSuccess() {
        let registrar = FakeRegistrar()
        let outcome = LaunchAtLogin.apply(enabled: true, using: registrar)

        #expect(registrar.registerCount == 1)
        #expect(outcome.isEnabled)
        #expect(outcome.message == nil)
        #expect(outcome.didAttempt)
    }

    @Test func aFailedRegistrationIsNeverSwallowed() {
        let registrar = FakeRegistrar()
        registrar.registerThrows = true

        let outcome = LaunchAtLogin.apply(enabled: true, using: registrar)

        #expect(outcome.message != nil, "the user has to be told the login item was not created")
        // …and the toggle goes back to where the system actually is, instead of
        // showing a tick that promises a launch that will not happen.
        #expect(!outcome.isEnabled)
    }

    @Test func aRegistrationParkedForApprovalSaysWhereToApproveIt() {
        let registrar = FakeRegistrar()
        registrar.outcomeOfRegister = .requiresApproval

        let outcome = LaunchAtLogin.apply(enabled: true, using: registrar)

        #expect(outcome.message == LaunchAtLoginCopy.approvalMessage)
        #expect(!outcome.isEnabled, "parked is not enabled")
    }

    @Test func disablingUnregisters() {
        let registrar = FakeRegistrar()
        registrar.status = .enabled

        let outcome = LaunchAtLogin.apply(enabled: false, using: registrar)

        #expect(registrar.unregisterCount == 1)
        #expect(!outcome.isEnabled)
        #expect(outcome.message == nil)
    }

    @Test func agreeingWithTheSystemCallsNothing() {
        let registrar = FakeRegistrar()
        registrar.status = .enabled

        let outcome = LaunchAtLogin.apply(enabled: true, using: registrar)

        #expect(registrar.registerCount == 0)
        #expect(!outcome.didAttempt, "a view mirroring this back must not clear its own message")
        #expect(outcome.isEnabled)
    }
}

// MARK: - Onboarding's one-shot choice

@Suite struct OnboardingLaunchAtLoginChoice {

    @Test func aChoiceNeverTouchedIsStillApplied() {
        // The exact bug: the user closes the onboarding window with the red
        // button while "Launch Caffeinate at login" is ticked (the default).
        // Completion has to register it — the window never comes back.
        let registrar = FakeRegistrar()
        let choice = LaunchAtLoginChoice(registrar: registrar)

        let outcome = choice.applyIfNeeded()

        #expect(registrar.registerCount == 1)
        #expect(outcome?.isEnabled == true)
        #expect(choice.isEnabled)
    }

    @Test func completionDoesNotRegisterASecondTime() {
        let registrar = FakeRegistrar()
        let choice = LaunchAtLoginChoice(registrar: registrar)

        choice.set(true)
        #expect(choice.applyIfNeeded() == nil, "already applied; nothing left to do")
        #expect(registrar.registerCount == 1)
    }

    @Test func aChoiceTurnedOffIsHonouredAtCompletion() {
        let registrar = FakeRegistrar()
        let choice = LaunchAtLoginChoice(registrar: registrar)

        choice.set(false)
        choice.applyIfNeeded()

        #expect(registrar.registerCount == 0)
        #expect(!choice.isEnabled)
    }

    @Test func aFailureAtCompletionIsReportedNotHidden() {
        let registrar = FakeRegistrar()
        registrar.registerThrows = true
        let choice = LaunchAtLoginChoice(registrar: registrar)

        let outcome = choice.applyIfNeeded()

        #expect(outcome?.message != nil)
        #expect(choice.isEnabled == false, "the choice mirrors what the system actually did")
    }

    @Test func flippingItOffAfterItWasAppliedUnregisters() {
        let registrar = FakeRegistrar()
        let choice = LaunchAtLoginChoice(registrar: registrar)

        choice.applyIfNeeded()      // step 3 appeared: default applied
        choice.set(false)           // user unticks it before finishing

        #expect(registrar.registerCount == 1)
        #expect(registrar.unregisterCount == 1)
        #expect(!choice.isEnabled)
    }
}
