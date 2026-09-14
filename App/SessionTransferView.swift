import SwiftUI
import SessionTransfer
import SessionMigration

private enum SessionConnection: Hashable { case source(DesktopAccount), destination }
private struct SessionConnectionAnchors: PreferenceKey {
    static var defaultValue: [SessionConnection: Anchor<CGRect>] = [:]
    static func reduce(value: inout [SessionConnection: Anchor<CGRect>], nextValue: () -> [SessionConnection: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SessionAccountLayout: Layout {
    static let columnsMinimumWidth: CGFloat = 540
    private let gap: CGFloat = 58

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 700
        let columns = width >= Self.columnsMinimumWidth
        let childWidth = columns ? (width - gap) / 2 : width
        let sizes = subviews.map { $0.sizeThatFits(.init(width: childWidth, height: nil)) }
        return CGSize(width: width, height: columns ? sizes.map(\.height).max() ?? 0 : sizes.reduce(0) { $0 + $1.height } + 28)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let columns = bounds.width >= Self.columnsMinimumWidth
        let childWidth = columns ? (bounds.width - gap) / 2 : bounds.width
        let childProposal = ProposedViewSize(width: childWidth, height: nil)
        if columns {
            for index in subviews.indices {
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(index) * (childWidth + gap), y: bounds.minY), anchor: .topLeading, proposal: childProposal)
            }
        } else {
            subviews[1].place(at: bounds.origin, anchor: .topLeading, proposal: childProposal)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + subviews[1].sizeThatFits(childProposal).height + 28), anchor: .topLeading, proposal: childProposal)
        }
    }
}

struct SessionTransferView: View {
    @ObservedObject var model: SessionTransferModel
    @State private var search = ""
    @State private var showSessions = false
    @State private var showResults = false
    @State private var showOlder = false
    @State private var showMetadataInfo = false
    @State private var undoReceipt: SessionMoveReceipt?
    @State private var editingLabel: DesktopAccount?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var palette: UsageStatisticsPalette { .init(dark: scheme == .dark) }
    private var stores: [SessionAccountStore] { model.inventory?.stores ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    if model.isTransferring {
                        transferProgress.transition(DecafMotion.transition(reduceMotion))
                    } else if model.showingResult, let receipt = model.receipt {
                        result(receipt).transition(DecafMotion.transition(reduceMotion))
                    } else if stores.isEmpty {
                        Text(model.inventory == nil ? "Reading your local accounts…" : "No local Code session accounts found.")
                            .font(.system(size: 13)).foregroundStyle(palette.secondary).padding(.vertical, 32)
                        Button("Open Claude") { model.openClaude() }.disabled(model.busy)
                    } else {
                        accountPicker
                        selectionSummary
                        if !model.sourceRows.isEmpty { sessionDetails }
                        if let receipt = model.receipt, receipt.needsAttention {
                            recoveryNotice(receipt)
                        }
                    }
                    if let message = model.message, !model.isTransferring { notice(message) }
                    if let issue = model.receiptIssue {
                        notice("The saved move could not be read. " + issue)
                        Button("Show saved records…") { model.showSavedRecords() }.buttonStyle(.link)
                    }
                    ForEach(model.inventory?.issues.filter { ![.desktopNotRunning, .identityUnknown].contains($0.code) } ?? [], id: \.message) { issue in
                        notice(issue.message)
                    }
                }.frame(maxWidth: 700).padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .animation(DecafMotion.page(reduceMotion), value: model.showingResult)
                    .animation(DecafMotion.page(reduceMotion), value: model.isTransferring)
            }
            footer.frame(maxWidth: 700).padding(.horizontal, 40).padding(.bottom, 24).padding(.top, 10)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: Binding(get: { model.preview != nil }, set: { if !$0 { model.preview = nil } })) {
                if let plan = model.preview {
                    SessionMoveConfirmation(plan: plan, destinationLabel: model.label(for: plan.destination),
                        cancel: { model.preview = nil }, confirm: { model.confirmMove() })
                }
            }
            .sheet(isPresented: Binding(get: { undoReceipt != nil }, set: { if !$0 { undoReceipt = nil } })) {
                if let receipt = undoReceipt {
                    SessionUndoConfirmation(receipt: receipt, destinationLabel: model.label(for: receipt.destination),
                        cancel: { undoReceipt = nil }, confirm: { undoReceipt = nil; model.undoLast(receipt.id) })
                }
            }
            .sheet(isPresented: Binding(get: { editingLabel != nil }, set: { if !$0 { editingLabel = nil } })) {
                if let account = editingLabel {
                    SessionAccountLabelEditor(account: account, label: model.label(for: account), cancel: { editingLabel = nil }) { email, organization in
                        model.saveLabel(for: account, email: email, organization: organization)
                        editingLabel = nil
                    }
                }
            }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Code").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text("Move sessions").font(.custom("Georgia", size: 31))
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(model.busy).help("Read local sessions again")
                    .accessibilityLabel("Refresh sessions")
            }
            Text("Switch accounts. Keep your conversations.")
                .font(.system(size: 14)).foregroundStyle(palette.secondary)
        }
    }

    private var accountPicker: some View {
        // Account text and selection badges must not change the column breakpoint.
        SessionAccountLayout {
            sourceColumn.frame(maxWidth: .infinity, alignment: .leading)
            destinationColumn.frame(maxWidth: .infinity, alignment: .leading)
        }.overlayPreferenceValue(SessionConnectionAnchors.self) { anchors in
            GeometryReader { geometry in
                if geometry.size.width >= SessionAccountLayout.columnsMinimumWidth, let end = anchors[.destination] {
                    ForEach(Array(model.sources), id: \.self) { account in
                        if let start = anchors[.source(account)] {
                            let from = geometry[start], to = geometry[end]
                            Path { path in
                                path.move(to: CGPoint(x: from.maxX + 5, y: from.midY))
                                path.addCurve(to: CGPoint(x: to.minX - 6, y: to.midY),
                                    control1: CGPoint(x: from.maxX + 29, y: from.midY),
                                    control2: CGPoint(x: to.minX - 29, y: to.midY))
                            }.stroke(palette.codex.opacity(0.45), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                        }
                    }
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }.animation(DecafMotion.selection(reduceMotion), value: model.sources)
            .animation(DecafMotion.selection(reduceMotion), value: model.destination)
            .animation(DecafMotion.page(reduceMotion), value: showOlder)
    }

    private func overline(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).tracking(0.9).foregroundStyle(palette.secondary)
    }

    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            overline("FROM · SELECT ACCOUNTS")
            ForEach(model.sourceGroups(older: false)) { group in sourceGroup(group, older: false) }
            if model.sourceGroups(older: false).isEmpty {
                Text("No other accounts with conversations available to move.")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.vertical, 12)
            }
            let older = model.sourceGroups(older: true)
            if !older.isEmpty {
                DisclosureGroup(isExpanded: $showOlder) {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(older) { group in sourceGroup(group, older: true) }
                    }.padding(.top, 15)
                } label: {
                    Text("Older accounts · \(older.count)").font(.system(size: 11))
                }.tint(palette.secondary).padding(.top, 12)
                    .overlay(alignment: .top) { Rectangle().fill(palette.rule).frame(height: 1) }
            }
        }
    }

    private func sourceGroup(_ group: SessionTransferModel.AccountGroup, older: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.label(for: group.account).email ?? "Unlabeled account")
                    .font(.system(size: 13, weight: .medium)).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 0)
                if model.label(for: group.account).email == nil {
                    Button("Add email") { editingLabel = group.account }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(palette.codex).disabled(model.busy)
                }
            }.padding(.horizontal, 8)
            ForEach(group.stores) { store in sourceRow(store, older: older) }
        }.help("Account: " + group.account.accountID)
            .contextMenu { Button("Edit account label…") { editingLabel = group.account }.disabled(model.busy) }
    }

    private func sourceRow(_ store: SessionAccountStore, older: Bool) -> some View {
        let selected = model.sources.contains(store.account)
        return Group {
            if older { sourceRowContent(store, older: true, selected: false) }
            else {
                Toggle(isOn: Binding(get: { selected }, set: { _ in model.toggleSource(store.account) })) {
                    sourceRowContent(store, older: false, selected: selected)
                }.toggleStyle(.checkbox).disabled(model.busy)
                    .accessibilityLabel("From \(model.displayName(store.account)), \(organizationName(store.account))")
            }
        }.padding(.horizontal, 10).padding(.vertical, 10).frame(minHeight: 58)
            .background(selected ? palette.selection.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .anchorPreference(key: SessionConnectionAnchors.self, value: .bounds) { selected ? [.source(store.account): $0] : [:] }
            .help("Organization: " + store.account.organizationID)
            .contextMenu { Button("Edit account label…") { editingLabel = store.account }.disabled(model.busy) }
    }

    private func sourceRowContent(_ store: SessionAccountStore, older: Bool, selected: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(organizationName(store.account)).font(.system(size: 12)).lineLimit(2)
                Text(sourceSubtitle(store, older: older)).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if older, !store.rows.isEmpty {
                    Text("Conversation files are missing. These listings can’t be moved.")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
            }
            Spacer(minLength: 0)
            if selected { Text("\(model.selectedRows.filter { $0.account == store.account }.count)")
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(palette.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private func organizationName(_ account: DesktopAccount) -> String {
        model.label(for: account).organization ?? "Organization not identified"
    }
    private func sourceSubtitle(_ store: SessionAccountStore, older: Bool) -> String {
        if store.rows.isEmpty { return store.pairConfirmed ? "No sessions" : "No sessions · Unconfirmed membership" }
        let count = "\(store.rows.count) " + (older ? "listings" : (store.rows.count == 1 ? "session" : "sessions"))
        return count + (store.account == model.inventory?.currentAccount ? " · Signed in" : "")
    }

    private var destinationColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            overline("TO · DESTINATION")
            VStack(alignment: .leading, spacing: 14) {
                if let account = model.destination {
                    HStack(spacing: 6) {
                        Circle().frame(width: 5, height: 5)
                        Text(model.targetConfirmed ? "Signed in to Claude" : "Sign-in needed")
                    }.font(.system(size: 11)).foregroundStyle(model.targetConfirmed ? palette.codex : palette.claude)
                    SessionAccountIdentityView(account: account, label: model.label(for: account), fontSize: 14)
                    Text("\(model.destinationStore?.rows.count ?? 0) sessions already here")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                    if model.label(for: account).email == nil {
                        Button("Add email") { editingLabel = account }.buttonStyle(.plain).foregroundStyle(palette.codex).font(.system(size: 12)).disabled(model.busy)
                    }
                } else {
                    Text("Choose a destination").font(.system(size: 14, weight: .medium))
                    Text("Open Claude and sign in to the account you want to use.")
                        .font(.system(size: 12)).foregroundStyle(palette.secondary)
                }
            }.frame(maxWidth: .infinity, minHeight: 104, alignment: .leading).padding(20)
                .background(palette.selection.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.rule.opacity(0.6), lineWidth: 1))
                .anchorPreference(key: SessionConnectionAnchors.self, value: .bounds) { [.destination: $0] }
            Menu {
                ForEach(stores) { store in
                    Button {
                        model.selectDestination(store.account)
                    } label: {
                        Text(model.displayName(store.account) + " · " + organizationName(store.account)
                             + (store.account == model.inventory?.currentAccount ? " · Signed in" : ""))
                        if store.account == model.destination { Image(systemName: "checkmark") }
                    }
                }
            } label: { Text("Change destination").font(.system(size: 12)) }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(palette.codex).disabled(model.busy)
            Text(model.targetConfirmed ? "Selected conversations will appear here when Claude reopens." : "Choose this account in Claude, then check the sign-in here.")
                .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            if !model.targetConfirmed {
                HStack(spacing: 15) {
                    Button("Open Claude") { model.openClaude() }
                    Button("Check sign-in") { model.refresh() }
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.codex).disabled(model.busy)
            }
        }
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(model.selectedRows.isEmpty ? "Choose the accounts to bring sessions from" : "\(model.selectedRows.count) sessions selected")
                    .font(.system(size: 15, weight: .medium))
                Spacer(minLength: 8)
                Button("Review move…") { model.prepare() }
                    .buttonStyle(.borderedProminent).tint(palette.codex).disabled(!model.canReview)
            }
            Text(selectionHint).font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 22).overlay(alignment: .top) { Rectangle().fill(palette.rule).frame(height: 1) }
    }
    private var selectionHint: String {
        if model.receiptIssue != nil { return "Open the saved records below to inspect the previous move." }
        if model.receipt?.needsAttention == true {
            return model.canKeepReceipt ? "Finish the previous review below, then continue with this selection." : "Review the previous move below before starting another."
        }
        if !model.targetConfirmed { return "Sign in to the destination in Claude, then check the sign-in to continue." }
        if model.selectedRows.count > 500 { return "Choose up to 500 sessions at a time. Narrow your selection below." }
        if model.selectedRows.isEmpty { return "Choose one or more accounts. You can pick individual sessions, too." }
        return "From \(model.selectedAccountCount) \(model.selectedAccountCount == 1 ? "account" : "accounts"). You’ll review what can move before anything changes."
    }

    private var sessionDetails: some View {
        DisclosureGroup(isExpanded: $showSessions) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(palette.secondary)
                    TextField("Find a conversation, project or group", text: $search).textFieldStyle(.plain)
                }.font(.system(size: 12)).padding(.vertical, 8)
                ForEach(stores.filter { model.sources.contains($0.account) }) { store in
                    let rows = store.rows.filter(matches)
                    if !rows.isEmpty {
                        SessionAccountIdentityView(account: store.account, label: model.label(for: store.account), fontSize: 12).padding(.top, 8)
                        ForEach(rows) { row in sessionRow(row) }
                    }
                    ForEach(store.issues, id: \.message) { issue in notice(issue.message) }
                }
                if model.sourceRows.filter(matches).isEmpty { notice("No matching conversations.") }
            }.padding(.top, 12)
        } label: { Text("Choose individual sessions").font(.system(size: 12, weight: .medium)) }
            .tint(palette.secondary).animation(DecafMotion.page(reduceMotion), value: showSessions)
    }
    private func sessionRow(_ row: SessionListing) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: Binding(get: { !model.excludedRows.contains(row.id) }, set: { model.include(row, $0) })) { Text(row.title) }
                .labelsHidden().toggleStyle(.checkbox).disabled(model.busy).accessibilityLabel("Include \(row.title)").padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if row.isPinned == true { Image(systemName: "pin.fill").foregroundStyle(palette.codex).help("Pinned in the source account") }
                    Text(row.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                }
                HStack(spacing: 8) {
                    Text(row.projectName.isEmpty ? "Unknown project" : row.projectName).lineLimit(1).help(row.projectPath)
                    if case .named(_, let name) = row.grouping { Label(name, systemImage: "folder").lineLimit(1) }
                    if row.isArchived { Text("Archived") }
                }.foregroundStyle(palette.secondary)
                if let issue = row.issue { Text(issue.message).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true) }
            }.font(.system(size: 11))
            Spacer(minLength: 0)
        }.padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.rule.opacity(0.5)).frame(height: 1) }
    }

    private var transferProgress: some View {
        VStack(alignment: .leading, spacing: 22) {
            ProgressView().controlSize(.small)
            Text(model.message ?? "Checking your conversations…").font(.custom("Georgia", size: 25))
            Text("Original entries are saved for Undo. Conversation files stay on this Mac.")
                .font(.system(size: 12)).foregroundStyle(palette.secondary)
        }.padding(.vertical, 35)
    }

    private func recoveryNotice(_ receipt: SessionMoveReceipt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.canKeepReceipt ? "Your previous move can be closed." : "The previous move needs a review.")
                .font(.system(size: 13, weight: .medium))
            Text(model.canKeepReceipt ? "The conversations are still in the destination. Keep them there to finish this review, then move them again whenever you need." : model.keepReceiptIssue ?? receipt.entries.compactMap(\.problem).first ?? "The saved move has unfinished entries. Review them before another move.")
                .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            Button(model.canKeepReceipt ? "Review & continue…" : "Review last move") { model.showingResult = true }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.codex).disabled(model.busy)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.selection.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
    }

    private func result(_ receipt: SessionMoveReceipt) -> some View {
        let undone = receipt.undoneCount == receipt.entries.count
        return VStack(alignment: .leading, spacing: 20) {
            Image(systemName: receipt.needsAttention ? "exclamationmark.circle" : (undone ? "arrow.uturn.backward.circle" : "checkmark.circle"))
                .font(.system(size: 37, weight: .ultraLight)).foregroundStyle(receipt.needsAttention ? palette.claude : palette.codex)
            Text(receipt.needsAttention ? (model.canKeepReceipt ? "Keep these conversations here?" : "This move needs a review.") : (undone ? "Back where you left them." : "\(receipt.movedCount) \(receipt.movedCount == 1 ? "session moved." : "sessions moved." )"))
                .font(.custom("Georgia", size: 27))
            SessionAccountIdentityView(account: receipt.destination, label: model.label(for: receipt.destination), fontSize: 14)
            if model.canKeepReceipt {
                notice("The conversations are still in this account. Keep them here to finish the previous review. This ends Undo for that move; you can still move them to another account, including back to the original one. Saved records are retained.")
            } else if receipt.needsAttention {
                notice(model.keepReceiptIssue ?? receipt.entries.compactMap(\.problem).first ?? "Some entries did not finish. Inspect the saved records or retry Undo.")
            } else {
                notice(undone ? "Restored to the original accounts. Your conversation history is unchanged." : "Your conversations are ready to continue in Claude.")
            }
            if receipt.heldCount > 0 { notice("\(receipt.heldCount) skipped at review and stayed in their original accounts.") }
            DisclosureGroup(isExpanded: $showResults) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(receipt.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(entry.title).lineLimit(2); Spacer(); Text(entryStatus(entry)).foregroundStyle(palette.secondary) }
                            if let problem = entry.problem { Text(problem).foregroundStyle(palette.secondary) }
                        }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Show saved records…") { model.showSavedRecords() }.buttonStyle(.link).font(.system(size: 11))
                }.padding(.top, 10)
            } label: { Text("Details · \(receipt.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))").font(.system(size: 12)) }.tint(palette.secondary)
            HStack(spacing: 18) {
                if model.canKeepReceipt {
                    Button("Keep here & continue") { model.keepLastMove() }.buttonStyle(.borderedProminent).tint(palette.codex)
                    Button("Open Claude") { model.openClaude() }.buttonStyle(.plain)
                } else {
                    Button("Open Claude") { model.openClaude() }.buttonStyle(.borderedProminent).tint(palette.codex)
                    if receipt.canUndo { Button(receipt.needsAttention ? "Retry Undo…" : "Undo move…") { undoReceipt = receipt }.disabled(model.receiptIssue != nil) }
                }
            }.font(.system(size: 12)).disabled(model.busy)
            if receipt.needsAttention, !model.canKeepReceipt {
                Button("Show saved records…") { model.showSavedRecords() }.buttonStyle(.link).font(.system(size: 12))
            }
            if !receipt.needsAttention {
                if receipt.canUndo { notice("Undo is available while the entries and their history remain unchanged. To move back after continuing a conversation, sign in to its original account and start a new move.") }
                Button(undone ? "Back to accounts" : "Move more sessions") { model.showAccountSelection() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.codex).disabled(model.busy)
            } else {
                Button("Back to accounts") { model.showingResult = false }.buttonStyle(.plain).font(.system(size: 12)).disabled(model.busy)
            }
        }.padding(.vertical, 8)
    }
    private func entryStatus(_ entry: SessionMoveEntry) -> String {
        switch entry.state {
        case .prepared: return "Waiting"
        case .placed: return "Placed"
        case .moved: return "Moved"
        case .undoing: return "Restoring"
        case .undone: return "Undone"
        case .kept: return "Kept in destination"
        case .needsAttention: return "Needs review"
        }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Label("Local Code sessions · History stays on this Mac", systemImage: "lock")
            Button { showMetadataInfo.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain).accessibilityLabel("About session moves")
                .popover(isPresented: $showMetadataInfo, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("A little context").font(.system(size: 14, weight: .medium))
                        Text("Email and organization names come from local profile records. Missing emails can be added with a local display label.")
                        Text("Pins and groups describe the source account. They do not transfer.")
                        Text("Move changes account entries and saves their originals for Undo. Conversation files stay in place. Undo stops if an entry or its history has changed.")
                        Text("You can move a conversation between accounts again later. Sign in to the next destination and start a new move, including when moving back.")
                    }.font(.system(size: 12)).foregroundStyle(palette.ink)
                        .fixedSize(horizontal: false, vertical: true).padding(20).frame(width: 330).background(palette.canvas)
                }
            Spacer(minLength: 0)
            if model.receipt != nil, !model.showingResult, !model.isTransferring {
                Button("Last move") { model.showingResult = true }.buttonStyle(.plain).disabled(model.busy)
            }
        }.font(.system(size: 11)).foregroundStyle(palette.secondary)
    }
    private func notice(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func matches(_ row: SessionListing) -> Bool {
        if search.isEmpty || row.title.localizedCaseInsensitiveContains(search) || row.projectPath.localizedCaseInsensitiveContains(search) { return true }
        if case .named(_, let name) = row.grouping { return name.localizedCaseInsensitiveContains(search) }
        return false
    }
}
struct SessionMoveConfirmation: View {
    let plan: SessionMovePlan
    let destinationLabel: SessionAccountLabel
    let cancel: () -> Void
    let confirm: () -> Void
    @State private var showHeld = false
    @Environment(\.colorScheme) private var scheme
    private var palette: UsageStatisticsPalette { .init(dark: scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(plan.ready.isEmpty ? "These sessions will stay put" : "Move \(plan.ready.count) \(plan.ready.count == 1 ? "session" : "sessions")?")
                .font(.custom("Georgia", size: 24))
            SessionAccountIdentityView(account: plan.destination, label: destinationLabel, fontSize: 15)
            Text(plan.ready.isEmpty ? "These entries stay in their original accounts. Review the reasons below." : "Claude will close, then reopen with your conversations in this account. Original entries are saved for Undo.")
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Text("Pins, groups and Remote Control links stay with the source. Permissions reset to Claude’s defaults. Conversation files stay on this Mac.")
                .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            if !plan.held.isEmpty {
                DisclosureGroup(isExpanded: $showHeld) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(plan.held) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.source.title).fontWeight(.medium)
                                    Text(item.issue.message).foregroundStyle(palette.secondary)
                                }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(.top, 8)
                    }.frame(maxHeight: 150)
                } label: {
                    Text("\(plan.held.count) will be skipped").font(.system(size: 12))
                }
            }
            Text("Undo is available while the entries and their history remain unchanged.")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Quit Claude & Move", action: confirm).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(palette.codex).disabled(plan.ready.isEmpty)
            }
        }.padding(30).frame(width: 490).background(palette.canvas).foregroundStyle(palette.ink)
    }
}

struct SessionUndoConfirmation: View {
    let receipt: SessionMoveReceipt
    let destinationLabel: SessionAccountLabel
    let cancel: () -> Void
    let confirm: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var palette: UsageStatisticsPalette { .init(dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Undo the last move?").font(.custom("Georgia", size: 24))
            SessionAccountIdentityView(account: receipt.destination, label: destinationLabel, fontSize: 14)
            Text("Restore entries from this move to their original accounts. Claude will quit and reopen. Any entry or conversation that has changed will be left untouched and listed in the results.")
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Text("This uses the saved move from \(receipt.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())), regardless of your current account selection.")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Quit Claude & Undo", action: confirm).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(palette.codex)
            }
        }.padding(30).frame(width: 460).background(palette.canvas).foregroundStyle(palette.ink)
    }
}

private struct SessionAccountIdentityView: View {
    let account: DesktopAccount
    let label: SessionAccountLabel
    let fontSize: CGFloat
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.email ?? "Unlabeled account").font(.system(size: fontSize, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
            Text(label.organization ?? "Organization not identified")
                .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(UsageStatisticsPalette(dark: scheme == .dark).secondary)
        }.help([label.email ?? "Email unavailable", label.organization ?? "Organization name unavailable",
            "Account: " + account.accountID, "Organization: " + account.organizationID].joined(separator: "\n"))
    }
}

private struct SessionAccountLabelEditor: View {
    let account: DesktopAccount
    let cancel: () -> Void
    let save: (String, String) -> Void
    @State private var email: String
    @State private var organization: String
    @Environment(\.colorScheme) private var scheme
    private var palette: UsageStatisticsPalette { .init(dark: scheme == .dark) }
    init(account: DesktopAccount, label: SessionAccountLabel, cancel: @escaping () -> Void, save: @escaping (String, String) -> Void) {
        self.account = account; self.cancel = cancel; self.save = save
        _email = State(initialValue: label.email ?? "")
        _organization = State(initialValue: label.organization ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Name this account").font(.custom("Georgia", size: 24))
            Text("Older accounts may no longer have a saved profile on this Mac. Add an email so you can recognize this account next time.")
                .font(.system(size: 12)).foregroundStyle(palette.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Email").font(.system(size: 12, weight: .medium))
                TextField("you@example.com", text: $email)
                Text("Organization (optional)").font(.system(size: 12, weight: .medium)).padding(.top, 8)
                TextField("Personal or team name", text: $organization)
            }.textFieldStyle(.roundedBorder)
            Text("Saved only in Decaf. This label does not sign you in or change the destination account.")
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
            HStack {
                Text(account.shortName).font(.system(size: 10)).foregroundStyle(palette.secondary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") { save(email, organization) }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(palette.codex)
                    .disabled(SessionAccountLabel(email: email).email == nil)
            }
        }.padding(28).frame(width: 410).background(palette.canvas).foregroundStyle(palette.ink)
    }
}
