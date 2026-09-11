import AppKit
import Combine
import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
protocol UpdateDriver: AnyObject {
    var canCheckForUpdates: Bool { get }
    var availability: AnyPublisher<Bool, Never> { get }
    func start() throws
    func checkForUpdates()
}

/// No driver is constructed, and no network request is made, until the user checks.
@MainActor
final class AppUpdater: ObservableObject {
    #if DEBUG
    static let shared = AppUpdater(unavailableReason:
        "Updates are disabled in this local preview. Installed releases can check for updates here.") { SparkleUpdateDriver() }
    #else
    static let shared = AppUpdater { SparkleUpdateDriver() }
    #endif
    @Published private(set) var canCheckForUpdates = true
    @Published private(set) var errorMessage: String?
    let unavailableReason: String?
    private let makeDriver: () -> any UpdateDriver
    private var driver: (any UpdateDriver)?
    private var observation: AnyCancellable?

    init(unavailableReason: String? = nil, makeDriver: @escaping () -> any UpdateDriver) {
        self.unavailableReason = unavailableReason
        self.makeDriver = makeDriver
        self.canCheckForUpdates = unavailableReason == nil
    }

    func dismissError() { errorMessage = nil }

    func checkForUpdates() {
        guard unavailableReason == nil, canCheckForUpdates else { return }
        errorMessage = nil
        do {
            if driver == nil {
                let candidate = makeDriver()
                try candidate.start()
                driver = candidate
                observation = candidate.availability.sink { [weak self] in
                    self?.canCheckForUpdates = $0
                }
            }
            guard let driver, driver.canCheckForUpdates else { return }
            driver.checkForUpdates()
            canCheckForUpdates = driver.canCheckForUpdates
        } catch {
            observation = nil
            driver = nil
            canCheckForUpdates = true
            errorMessage = "The updater could not start. Try again, or use the download and Homebrew options below."
        }
    }
}

#if canImport(Sparkle)
@MainActor
private final class SparkleUpdateDriver: UpdateDriver {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var availability: AnyPublisher<Bool, Never> {
        controller.updater.publisher(for: \.canCheckForUpdates).eraseToAnyPublisher()
    }
    func start() throws { try controller.updater.start() }
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
#else
/// Rendering and logic-test harnesses do not link or run an installer.
@MainActor
private final class SparkleUpdateDriver: UpdateDriver {
    var canCheckForUpdates: Bool { false }
    var availability: AnyPublisher<Bool, Never> { Just(false).eraseToAnyPublisher() }
    func start() throws { throw CocoaError(.featureUnsupported) }
    func checkForUpdates() {}
}
#endif
