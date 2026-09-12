import Foundation

/// Presentation metadata only. A label never proves the signed-in account or
/// grants a handoff; DesktopAccount's identity remains the account/org UUID pair.
public struct SessionAccountLabel: Codable, Equatable, Sendable {
    public let email: String?
    public let organization: String?

    public init(email: String? = nil, organization: String? = nil) {
        self.email = Self.clean(email, limit: 254).flatMap {
            $0.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) == nil ? nil : $0
        }
        self.organization = Self.clean(organization, limit: 200)
    }

    private static func clean(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limit,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return trimmed
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(email: try values.decodeIfPresent(String.self, forKey: .email),
                  organization: try values.decodeIfPresent(String.self, forKey: .organization))
    }
}

/// Read public profile fields from Desktop's live query cache and Claude Code's
/// configuration and standard backups. No token, cookie, Keychain or authenticated API access.
/// Exact UUID matching is essential: CLI and Desktop may use different logins.
struct AccountLabels {
    private struct Candidate {
        let account: DesktopAccount
        let label: SessionAccountLabel
        let priority: Int
    }

    static func read(paths: SessionPaths, accounts: [DesktopAccount]) -> [DesktopAccount: SessionAccountLabel] {
        var files: [(URL, Int)] = [(paths.profile, 2)]
        for directory in [paths.profile.deletingLastPathComponent(), paths.claude.appendingPathComponent("backups")] {
            guard (try? isDirectory(directory)) == true,
                  let entries = try? children(directory) else { continue }
            let backups = entries.filter { url in
                let name = url.lastPathComponent
                return name == ".claude.json.backup" || name.range(of: #"^\.claude\.json\.backup\.[0-9]+$"#, options: .regularExpression) != nil
            }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(32)
            files.append(contentsOf: backups.map { ($0, 1) })
        }
        var candidates = files.compactMap { url, priority -> Candidate? in
            guard let object = try? readObject(url, limit: 4 * 1024 * 1024),
                  let profile = object["oauthAccount"] as? [String: Any],
                  let account = profile["accountUuid"] as? String, validSessionID(account),
                  let organization = profile["organizationUuid"] as? String, validSessionID(organization) else { return nil }
            let label = SessionAccountLabel(email: profile["emailAddress"] as? String,
                                            organization: profile["organizationName"] as? String)
            return Candidate(account: .init(accountID: account.lowercased(), organizationID: organization.lowercased()),
                             label: label, priority: priority)
        }
        if let desktop = try? DesktopProfileCache.read(desktop: paths.desktop) {
            candidates.append(contentsOf: desktop.map { Candidate(account: $0.key, label: $0.value, priority: 3) })
        }
        // Desktop's explicit profile UUID takes precedence over CLI metadata.
        // Current config wins over backups for a changed email/name. Conflicting
        // equally ranked evidence stays unknown instead of choosing arbitrarily.
        func unique(_ matches: [Candidate], value: (Candidate) -> String?) -> String? {
            let available = matches.filter { value($0) != nil }
            guard let rank = available.map(\.priority).max() else { return nil }
            let values = Set(available.filter { $0.priority == rank }.compactMap(value))
            return values.count == 1 ? values.first : nil
        }
        var result: [DesktopAccount: SessionAccountLabel] = [:]
        for account in accounts {
            let matches = candidates.filter { $0.account.accountID == account.accountID.lowercased() }
            let email = unique(matches, value: { $0.label.email })
            let organization = unique(matches.filter { $0.account.organizationID == account.organizationID.lowercased() }, value: { $0.label.organization })
            if email != nil || organization != nil {
                result[account] = SessionAccountLabel(email: email, organization: organization)
            }
        }
        return result
    }
}
