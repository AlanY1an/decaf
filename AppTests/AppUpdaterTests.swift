import Combine
import Foundation
import Testing

@Suite("User-initiated updates") @MainActor
struct AppUpdaterTests {
    @Test func developmentBuildDoesNotStartAnUpdaterOrContactTheReleaseFeed() {
        var made = 0
        let updater = AppUpdater(unavailableReason: "Development build") {
            made += 1
            return FakeUpdateDriver()
        }
        updater.checkForUpdates()
        updater.checkForUpdates()
        #expect(made == 0)
        #expect(!updater.canCheckForUpdates)
        #expect(updater.unavailableReason == "Development build")
        #expect(updater.errorMessage == nil)
    }

    @Test func openingTheUIIsInert() {
        var made = 0
        let updater = AppUpdater { made += 1; return FakeUpdateDriver() }
        #expect(updater.canCheckForUpdates)
        #expect(updater.errorMessage == nil)
        #expect(made == 0)
    }

    @Test func startsOnceAndDisablesDuplicateChecksUntilTheDriverFinishes() {
        let driver = FakeUpdateDriver()
        let updater = AppUpdater { driver }
        updater.checkForUpdates()
        updater.checkForUpdates()
        #expect(driver.starts == 1)
        #expect(driver.checks == 1)
        #expect(!updater.canCheckForUpdates)
        driver.ready.send(true)
        updater.checkForUpdates()
        #expect(driver.starts == 1)
        #expect(driver.checks == 2)
    }

    @Test func startupFailureIsVisibleAndRetryConstructsANewDriver() {
        let broken = FakeUpdateDriver(fails: true)
        let working = FakeUpdateDriver()
        var attempt = 0
        let updater = AppUpdater {
            attempt += 1
            return attempt == 1 ? broken : working
        }
        updater.checkForUpdates()
        #expect(updater.errorMessage != nil)
        #expect(updater.canCheckForUpdates)
        #expect(broken.checks == 0)
        updater.dismissError()
        updater.checkForUpdates()
        #expect(updater.errorMessage == nil)
        #expect(working.checks == 1)
    }

    @Test func busyDriverMustBecomeAvailableBeforeChecking() {
        let driver = FakeUpdateDriver(initiallyReady: false)
        let updater = AppUpdater { driver }
        updater.checkForUpdates()
        #expect(driver.checks == 0)
        #expect(!updater.canCheckForUpdates)
        driver.ready.send(true)
        updater.checkForUpdates()
        #expect(driver.starts == 1)
        #expect(driver.checks == 1)
    }
}

@MainActor private final class FakeUpdateDriver: UpdateDriver {
    let ready: CurrentValueSubject<Bool, Never>
    let fails: Bool
    var starts = 0
    var checks = 0
    init(fails: Bool = false, initiallyReady: Bool = true) {
        self.fails = fails
        ready = .init(initiallyReady)
    }
    var canCheckForUpdates: Bool { ready.value }
    var availability: AnyPublisher<Bool, Never> { ready.eraseToAnyPublisher() }
    func start() throws {
        starts += 1
        if fails { throw CocoaError(.featureUnsupported) }
    }
    func checkForUpdates() { checks += 1; ready.send(false) }
}
