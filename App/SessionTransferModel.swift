import AppKit
import SwiftUI
import SessionTransfer
import SessionMigration

@MainActor
final class SessionTransferModel: ObservableObject {
    @Published private(set) var inventory: SessionInventory?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var accountLabels: [DesktopAccount: SessionAccountLabel] = [:]
    @Published private(set) var sources: Set<DesktopAccount> = []
    @Published private(set) var destination: DesktopAccount?
    @Published private(set) var excludedRows: Set<String> = []
    @Published var preview: SessionMovePlan?
    @Published private(set) var receipt: SessionMoveReceipt?
    @Published private(set) var receiptIssue: String?
    @Published private(set) var canKeepReceipt = false
    @Published private(set) var keepReceiptIssue: String?
    @Published var showingResult = false
    @Published private(set) var isTransferring = false
    private let catalog: SessionCatalog
    private let labelDefaults: UserDefaults?
    let migrationRoot: URL
    private var didChooseDestination = false
    private var progressID: UUID?
    private var operation: Task<Void, Never>?
    private static let labelKey = "sessionAccountLabels.v1"
    private struct SavedLabel: Codable {
        let account: DesktopAccount
        let label: SessionAccountLabel
    }

    init(catalog: SessionCatalog = SessionCatalog(), inventory: SessionInventory? = nil,
         labelDefaults: UserDefaults? = .standard, migrationRoot: URL? = nil,
         receipt: SessionMoveReceipt? = nil) {
        self.catalog = catalog
        self.inventory = inventory
        self.labelDefaults = labelDefaults
        self.receipt = receipt
        self.showingResult = receipt != nil
        self.migrationRoot = migrationRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Decaf/SessionMoves")
        if let data = labelDefaults?.data(forKey: Self.labelKey), data.count <= 262_144,
           let saved = try? JSONDecoder().decode([SavedLabel].self, from: data), saved.count <= 1_000 {
            for item in saved where UUID(uuidString: item.account.accountID) != nil && UUID(uuidString: item.account.organizationID) != nil {
                accountLabels[item.account] = item.label
            }
        }
        if let inventory { accept(inventory) }
    }

    var selectedRows: [SessionListing] {
        (inventory?.rows ?? []).filter { sources.contains($0.account) && !excludedRows.contains($0.id) }
    }
    var sourceRows: [SessionListing] { (inventory?.rows ?? []).filter { sources.contains($0.account) } }
    var targetConfirmed: Bool { destination != nil && destination == inventory?.currentAccount }
    var canReview: Bool {
        !busy && targetConfirmed && !selectedRows.isEmpty && selectedRows.count <= 500
            && receipt?.needsAttention != true && receiptIssue == nil
    }
    func label(for account: DesktopAccount) -> SessionAccountLabel { accountLabels[account] ?? .init() }
    func displayName(_ account: DesktopAccount) -> String { label(for: account).email ?? account.shortName }

    func saveLabel(for account: DesktopAccount, email: String, organization: String) {
        let label = SessionAccountLabel(email: email, organization: organization)
        guard label.email != nil else { return }
        // An email describes the account across memberships; an organization
        // name describes only this exact account/org pair.
        var fresh = [account: label]
        for store in inventory?.stores ?? [] where store.account.accountID == account.accountID && store.account != account {
            fresh[store.account] = .init(email: label.email)
        }
        rememberLabels(fresh)
    }

    func toggleSource(_ account: DesktopAccount) {
        guard !busy, account != destination, let store = inventory?.stores.first(where: { $0.account == account }),
              !isOlderStore(store) else { return }
        if sources.contains(account) { sources.remove(account) } else { sources.insert(account) }
        preview = nil
    }
    func selectDestination(_ account: DesktopAccount) {
        guard !busy else { return }
        didChooseDestination = true
        destination = account
        sources.remove(account)
        preview = nil
    }
    func include(_ row: SessionListing, _ included: Bool) {
        guard !busy else { return }
        if included { excludedRows.remove(row.id) } else { excludedRows.insert(row.id) }
        preview = nil
    }

    struct AccountGroup: Identifiable {
        let id: String
        let stores: [SessionAccountStore]
        var account: DesktopAccount { stores[0].account }
    }
    func isOlderStore(_ store: SessionAccountStore) -> Bool {
        store.rows.isEmpty || store.rows.allSatisfy { $0.issue?.code == .missingTranscript }
    }
    func sourceGroups(older: Bool) -> [AccountGroup] {
        let stores = (inventory?.stores ?? []).filter { $0.account != destination && isOlderStore($0) == older }
        // Email is a display label, not an identity. Separate UUIDs never merge.
        return Dictionary(grouping: stores, by: { $0.account.accountID }).map {
            AccountGroup(id: $0.key, stores: $0.value.sorted { $0.id < $1.id })
        }.sorted { displayName($0.account).localizedStandardCompare(displayName($1.account)) == .orderedAscending }
    }
    var selectedAccountCount: Int { Set(selectedRows.map { $0.account.accountID }).count }
    var destinationStore: SessionAccountStore? { inventory?.stores.first { $0.account == destination } }

    private func accept(_ fresh: SessionInventory) {
        inventory = fresh
        rememberLabels(fresh.accountLabels)
        let accounts = Set(fresh.stores.map(\.account))
        sources.formIntersection(accounts)
        excludedRows.formIntersection(Set(fresh.rows.map(\.id)))
        if !didChooseDestination { destination = fresh.currentAccount }
        else if let destination, !accounts.contains(destination) { self.destination = nil }
        // Explicit choices survive refresh; never silently redirect a review.
        if let destination { sources.remove(destination) }
    }

    private func rememberLabels(_ fresh: [DesktopAccount: SessionAccountLabel]) {
        for (account, label) in fresh {
            let previous = accountLabels[account]
            accountLabels[account] = .init(email: label.email ?? previous?.email,
                                          organization: label.organization ?? previous?.organization)
        }
        let saved = accountLabels.sorted { $0.key.accountID + $0.key.organizationID < $1.key.accountID + $1.key.organizationID }
            .prefix(1_000).map { SavedLabel(account: $0.key, label: $0.value) }
        if let data = try? JSONEncoder().encode(saved), data.count <= 262_144 { labelDefaults?.set(data, forKey: Self.labelKey) }
    }

    private static let desktopURL = URL(fileURLWithPath: "/Applications/Claude.app")
    private func runningDesktop() -> (NSRunningApplication, DesktopRuntime)? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == Self.desktopURL }),
              let launched = app.launchDate else { return nil }
        let version = Bundle(url: Self.desktopURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return (app, DesktopRuntime(pid: app.processIdentifier, launchedAt: launched, version: version))
    }

    // Called repeatedly from the writer, including between each filesystem step.
    // Worker liveness for every selected CLI session is also checked by Core.
    nonisolated private static func assertDesktopStopped() throws {
        let root = "/Applications/Claude.app"
        guard !NSWorkspace.shared.runningApplications.contains(where: { app in
            let path = app.bundleURL?.path ?? app.executableURL?.path ?? ""
            return path == root || path.hasPrefix(root + "/")
        }) else { throw SessionIssue(.workerActive, "Claude is still running. Finish its quit dialog, then review again.") }
    }

    private var engine: SessionMoveEngine {
        .init(paths: catalog.paths, stateRoot: migrationRoot, assertDesktopStopped: { try Self.assertDesktopStopped() })
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        operation = Task {
            await readFreshState()
            busy = false
        }
    }

    private func readFreshState() async {
        let runtime = runningDesktop()?.1, catalog = catalog, engine = engine
        let result = await Task.detached(priority: .userInitiated) {
            let inventory = catalog.scan(runtime: runtime)
            let receipt = Result { try engine.latest() }
            let canKeep: Bool
            var keepIssue: String?
            if case .success(let latest?) = receipt, latest.needsAttention {
                do { canKeep = try engine.canKeepCurrentPlacement(latest.id) }
                catch { canKeep = false; keepIssue = error.localizedDescription }
            } else { canKeep = false }
            return (inventory, receipt, canKeep, keepIssue)
        }.value
        accept(result.0)
        canKeepReceipt = result.2
        keepReceiptIssue = result.3
        switch result.1 {
        case .success(let latest): receipt = latest; receiptIssue = nil
        case .failure(let error): receiptIssue = error.localizedDescription
        }
    }

    func prepare() {
        guard canReview, let destination else { return }
        let runtime = runningDesktop()?.1, planner = SessionMovePlanner(catalog: catalog)
        let rows = Set(selectedRows.map(\.id))
        busy = true; message = "Checking the selected conversations…"
        operation = Task {
            do {
                preview = try await Task.detached(priority: .userInitiated) {
                    try planner.prepare(sources: rows, destination: destination, runtime: runtime)
                }.value
                message = nil
            } catch { message = error.localizedDescription }
            busy = false
        }
    }

    func confirmMove() {
        guard !busy, let plan = preview, !plan.ready.isEmpty else { return }
        preview = nil
        run(move: plan, undo: nil)
    }

    func undoLast(_ id: UUID) {
        guard !busy, receipt?.id == id, receipt?.canUndo == true, receiptIssue == nil else { return }
        run(move: nil, undo: id)
    }

    private func run(move plan: SessionMovePlan?, undo id: UUID?) {
        busy = true
        isTransferring = true
        canKeepReceipt = false
        message = "Waiting for Claude to quit…"
        let engine = engine
        let token = UUID(); progressID = token
        operation = Task {
            var shouldReopen = false
            do {
                if let plan {
                    guard let (_, runtime) = runningDesktop(), runtime == plan.runtime,
                          try catalog.currentAccount(runtime: runtime) == plan.destination else {
                        throw SessionIssue(.identityUnknown, "Claude's account or process changed. Refresh and review again.")
                    }
                }
                if let (app, _) = runningDesktop() {
                    guard app.terminate() else { throw SessionIssue(.workerActive, "Claude did not accept the quit request. No sessions were moved.") }
                    for _ in 0..<50 {
                        if app.isTerminated, (try? Self.assertDesktopStopped()) != nil { break }
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    shouldReopen = app.isTerminated
                }
                try Self.assertDesktopStopped()
                message = id == nil ? "Moving the reviewed conversations…" : "Restoring the last move…"
                let progress: @Sendable (SessionMoveReceipt) -> Void = { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.progressID == token else { return }
                        self.receipt = update
                    }
                }
                let completed = try await Task.detached(priority: .userInitiated) {
                    if let plan { return try engine.move(plan, progress: progress) }
                    return try engine.undo(id!, progress: progress)
                }.value
                progressID = nil
                receipt = completed
                showingResult = true
                if plan != nil { sources.removeAll(); excludedRows.removeAll() }
                message = completed.needsAttention ? "Some entries need attention. See the results below; newer work has been kept." : nil
            } catch {
                progressID = nil
                message = error.localizedDescription
            }
            if shouldReopen {
                do {
                    try await reopenDesktop()
                    // LaunchServices returns before Claude initializes its
                    // account store. Do not briefly show "sign in" as a result
                    // of scanning the newly launched process too early.
                    for _ in 0..<20 {
                        if let runtime = runningDesktop()?.1,
                           (try? catalog.currentAccount(runtime: runtime)) != nil { break }
                        try await Task.sleep(for: .milliseconds(250))
                    }
                }
                catch { message = [message, "Open Claude to see your sessions. It could not be reopened automatically."].compactMap { $0 }.joined(separator: " ") }
            }
            await readFreshState()
            isTransferring = false
            busy = false
        }
    }

    private func reopenDesktop() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: Self.desktopURL, configuration: configuration)
    }

    func openClaude() {
        Task {
            do { try await reopenDesktop() }
            catch { message = "Claude could not be opened. Open it from Applications, then refresh." }
        }
    }

    func keepLastMove() {
        guard !busy, canKeepReceipt, let id = receipt?.id else { return }
        busy = true; message = "Checking where your conversations are saved…"
        let engine = engine
        operation = Task {
            do {
                receipt = try await Task.detached(priority: .userInitiated) {
                    try engine.keepCurrentPlacement(id)
                }.value
                message = "Previous review finished. You can move these conversations again, including back to their original account."
                showingResult = false
            } catch { message = error.localizedDescription }
            await readFreshState()
            busy = false
        }
    }

    func showAccountSelection() {
        guard !busy else { return }
        showingResult = false; message = nil
        sources.removeAll(); excludedRows.removeAll()
    }

    func showSavedRecords() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: migrationRoot.path)
    }
}
