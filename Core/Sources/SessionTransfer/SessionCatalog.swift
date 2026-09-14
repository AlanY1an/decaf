import Foundation
import Darwin
import TranscriptSupport

public struct SessionCatalog: Sendable {
    public let paths: SessionPaths
    public init(paths: SessionPaths = .local()) { self.paths = paths }

    public func scan(runtime: DesktopRuntime?, now: Date = Date()) -> SessionInventory {
        let sidebar = SidebarGroups.read(desktop: paths.desktop)
        var issues: [SessionIssue] = []
        var current: DesktopAccount?
        do { current = try currentAccount(runtime: runtime, now: now) }
        catch { issues.append(asIssue(error)) }
        var index: [String: [URL]] = [:]
        var indexIssue: SessionIssue?
        do { index = try transcriptIndex(paths.projects) }
        catch { indexIssue = asIssue(error); issues.append(asIssue(error)) }
        var stores: [SessionAccountStore] = []
        do {
            for accountURL in try children(paths.rows).sorted(by: { $0.path < $1.path }) {
                guard validSessionID(accountURL.lastPathComponent) else { continue }
                let organizations: [URL]
                do {
                    guard try isDirectory(accountURL) else { continue }
                    organizations = try children(accountURL)
                } catch {
                    issues.append(SessionIssue(.unreadable, "Could not inspect account \(accountURL.lastPathComponent.prefix(8)). Other accounts are listed separately."))
                    continue
                }
                for orgURL in organizations.sorted(by: { $0.path < $1.path }) {
                    guard validSessionID(orgURL.lastPathComponent) else { continue }
                    let account = DesktopAccount(accountID: accountURL.lastPathComponent,
                                                 organizationID: orgURL.lastPathComponent)
                    var rows: [SessionListing] = [], localIssues: [SessionIssue] = []
                    do {
                        guard try isDirectory(orgURL) else { continue }
                        for url in try children(orgURL).sorted(by: { $0.path < $1.path }) {
                            guard url.lastPathComponent.hasPrefix("local_"), url.pathExtension == "json" else { continue }
                            rows.append(listing(url, account: account, index: index, indexIssue: indexIssue, sidebar: sidebar))
                        }
                    } catch { localIssues.append(asIssue(error)) }
                    stores.append(SessionAccountStore(account: account,
                        rows: rows.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) },
                        issues: localIssues, pairConfirmed: account == current))
                }
            }
        } catch { issues.append(asIssue(error)) }
        let accounts = Array(Set(stores.map(\.account) + (current.map { [$0] } ?? [])))
        return SessionInventory(stores: stores, currentAccount: current, runtime: runtime, issues: issues,
                                accountLabels: AccountLabels.read(paths: paths, accounts: accounts))
    }

    /// config.json alone is stale-prone. Bind it to a complete initialization
    /// log line emitted during this exact Desktop process lifetime. Bridge state
    /// adds corroboration when present; builds without Remote Control omit it.
    public func currentAccount(runtime: DesktopRuntime?, now: Date = Date()) throws -> DesktopAccount {
        guard let runtime else {
            throw SessionIssue(.desktopNotRunning, "Open Claude Desktop and sign in to the account you want to continue with.")
        }
        let config = try readObject(paths.desktop.appendingPathComponent("config.json"))
        guard let accountID = config["lastKnownAccountUuid"] as? String, validSessionID(accountID) else {
            throw SessionIssue(.identityUnknown, "Claude Desktop's current account could not be confirmed.")
        }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter.isLenient = false
        let pattern = #"^([0-9-]{10} [0-9:]{8}) .*\[LocalSessionManager\] Initialization succeeded.*accountId=([0-9a-fA-F-]{36}), orgId=([0-9a-fA-F-]{36}),"#
        let regex = try NSRegularExpression(pattern: pattern)
        var evidence: [(Date, DesktopAccount)] = []
        for url in try children(paths.logs) where url.lastPathComponent.range(of: #"^main[0-9]*\.log$"#, options: .regularExpression) != nil {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd(), offset = size > 8_388_608 ? size - 8_388_608 : 0
            try handle.seek(toOffset: offset)
            let bytes = try handle.readToEnd() ?? Data()
            var lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n")
            // components has a trailing empty entry for a complete last line.
            // Remove it (or the torn fragment) in either case.
            lines.removeLast()
            if offset > 0, !lines.isEmpty { lines.removeFirst() }
            for line in lines.reversed() {
                let ns = line as NSString
                guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                      let timestamp = dateFormatter.date(from: ns.substring(with: match.range(at: 1))),
                      timestamp >= runtime.launchedAt, timestamp <= now else { continue }
                let a = ns.substring(with: match.range(at: 2)), o = ns.substring(with: match.range(at: 3))
                guard validSessionID(a), validSessionID(o) else { continue }
                evidence.append((timestamp, DesktopAccount(accountID: a, organizationID: o)))
                break
            }
        }
        guard let latest = evidence.sorted(by: { $0.0 > $1.0 }).first,
              latest.1.accountID == accountID else {
            throw SessionIssue(.identityUnknown, "The account evidence is stale or disagrees. Reopen Claude Desktop, then refresh.")
        }
        let bridgeURL = paths.desktop.appendingPathComponent("bridge-state.json")
        // No bridge file is normal on this measured Desktop installation.
        // Bridge state corroborates the organization behind an account; it is not
        // a second opinion on which account is signed in. Claude writes it when
        // Remote Control connects and leaves it alone afterwards, so after an
        // account switch it routinely names only the previous account — silence
        // about the account in hand, not a contradiction of it. Only a bridge that
        // binds this exact account to a different organization disagrees with the
        // log evidence, and only that refuses.
        // This route hands off to Claude's live importer, never to a guessed directory.
        if FileManager.default.fileExists(atPath: bridgeURL.path) {
            let bridge = try readObject(bridgeURL)
            let organizations = bridge.keys.compactMap { key -> String? in
                let parts = key.components(separatedBy: ":")
                guard parts.count == 2, validSessionID(parts[0]), validSessionID(parts[1]),
                      parts[1] == accountID else { return nil }
                return parts[0]
            }
            guard organizations.isEmpty || organizations.contains(latest.1.organizationID) else {
                throw SessionIssue(.identityUnknown, "Claude's account and organization evidence disagree. Refresh after signing in.")
            }
        }
        return latest.1
    }

    private func listing(_ url: URL, account: DesktopAccount,
                         index: [String: [URL]], indexIssue: SessionIssue?, sidebar: SidebarGroups) -> SessionListing {
        var title = "Unreadable session", cwd = "", id: String?, active: Date?, archived = false
        var pinned: Bool?, grouping: SessionGrouping = .unknown
        var issue: SessionIssue?
        do {
            let row = try readObject(url)
            let stem = url.deletingPathExtension().lastPathComponent
            guard let rowID = row["sessionId"] as? String, rowID == stem,
                  validSessionID(bareSessionID(stem)) else {
                throw SessionIssue(.invalidRecord, "The session ID does not match its listing file.")
            }
            title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled session"
            cwd = row["cwd"] as? String ?? ""
            archived = JSON.bool(row["isArchived"]) ?? false
            pinned = JSON.bool(row["isStarred"])
            grouping = sidebar.membership(account: account, rowID: rowID)
            if let millis = JSON.positiveNumber(row["lastActivityAt"]) { active = Date(timeIntervalSince1970: millis / 1000) }
            if let value = row["cliSessionId"], !(value is NSNull), !(value is String) {
                throw SessionIssue(.invalidRecord, "The conversation ID has an unexpected format.")
            }
            id = (row["cliSessionId"] as? String) ?? bareSessionID(rowID)
            guard let id, validSessionID(id) else {
                throw SessionIssue(.invalidRecord, "The conversation ID is not recognized.")
            }
            if let indexIssue { throw indexIssue }
            if JSON.bool(row["transcriptUnavailable"]) == true {
                throw SessionIssue(.missingTranscript, "Claude marks this conversation's transcript as unavailable.")
            }
            try validateRowKind(row)
            let candidates = index[id] ?? []
            guard !candidates.isEmpty else {
                throw SessionIssue(.missingTranscript, "The listing remains, but its conversation is missing from this Mac's current log folder.")
            }
            // The deep link carries only an ID: Decaf cannot pass its own cwd
            // tiebreaker to Claude's importer, so all multi-hit IDs must refuse.
            guard candidates.count == 1 else {
                throw SessionIssue(.ambiguousTranscript, "Several conversation files share this ID. A safe handoff cannot choose between them.")
            }
            _ = try FileWitness(candidates[0])
        } catch { issue = asIssue(error) }
        return SessionListing(id: url.path, account: account, title: title, projectPath: cwd,
                              lastActive: active, sessionID: id, rowURL: url, issue: issue, isArchived: archived,
                              isPinned: pinned, grouping: grouping)
    }

    package func validateRowKind(_ row: [String: Any]) throws {
        if row["scheduledTaskId"] != nil && !(row["scheduledTaskId"] is NSNull) {
            throw SessionIssue(.scheduled, "This session belongs to a scheduled task. Account transfer does not transfer its schedule.")
        }
        if ["sshConfig", "wslConfig", "remoteSessionId"].contains(where: { row[$0] != nil && !(row[$0] is NSNull) }) || JSON.bool(row["violinBow"]) == true {
            throw SessionIssue(.remoteSession, "This is a remote session. Only local Code conversations can be handed off.")
        }
    }

    package func checkWorkers(sessionID: String) throws {
        let root = paths.claude.appendingPathComponent("sessions")
        // Unknown liveness is a refusal, including a missing registry.
        let records: [URL]
        do { records = try children(root) }
        catch { throw SessionIssue(.workerUnknown, "Could not check active Claude workers. No session was opened.") }
        for url in records where url.pathExtension == "json" {
            let row: [String: Any]
            do { row = try readObject(url, limit: 256 * 1024) }
            catch { throw SessionIssue(.workerUnknown, "A Claude worker record could not be read.") }
            guard let pidValue = JSON.positiveNumber(row["pid"]), pidValue.rounded() == pidValue,
                  pidValue <= Double(Int32.max), let id = row["sessionId"] as? String else {
                throw SessionIssue(.workerUnknown, "A Claude worker's identity could not be checked.")
            }
            guard id == sessionID else { continue }
            let pid = Int32(pidValue)
            if kill(pid, 0) != 0 && errno == ESRCH { continue }
            // A reused PID can produce an extra hold, never permission to race
            // a writer. No process is terminated or inferred idle by this tool.
            let entrypoint = row["entrypoint"] as? String ?? "unknown"
            throw SessionIssue(.workerActive, "Claude is still holding this conversation (\(entrypoint), process \(pid)). Close that session before continuing here.")
        }
    }
}

package func asIssue(_ error: Error) -> SessionIssue {
    error as? SessionIssue ?? SessionIssue(.unreadable, "Some local session data could not be inspected.")
}
