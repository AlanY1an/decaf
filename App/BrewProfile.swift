import Combine
import Foundation

enum BrewAvatar: String, CaseIterable, Identifiable {
    case cup, moon, spark
    var id: String { rawValue }
    var title: String {
        switch self { case .cup: return "House blend"; case .moon: return "After hours"; case .spark: return "Little spark" }
    }
    var symbol: String {
        switch self { case .cup: return "cup.and.saucer"; case .moon: return "moon.stars"; case .spark: return "sparkles" }
    }
}

struct BrewProfile: Equatable {
    var nickname: String
    var avatar: BrewAvatar
    var showsTokenTotals: Bool

    init(nickname: String = "", avatar: BrewAvatar = .cup, showsTokenTotals: Bool = false) {
        self.nickname = Self.cleanNickname(nickname)
        self.avatar = avatar
        self.showsTokenTotals = showsTokenTotals
    }

    var title: String { nickname.isEmpty ? "Your brew" : nickname + "’s brew" }
    var shareTitle: String { nickname.isEmpty ? "My brew" : title }

    static func cleanNickname(_ value: String) -> String {
        let words = value.components(separatedBy: .whitespacesAndNewlines)
            .map { removeControls($0) }.filter { !$0.isEmpty }
        return String(words.joined(separator: " ").prefix(32))
    }

    static func editingNickname(_ value: String) -> String {
        String(removeControls(value.components(separatedBy: .newlines).joined(separator: " ")).prefix(32))
    }

    private static func removeControls(_ value: String) -> String {
        // Keep joiners used by emoji and scripts. CharacterSet.controlCharacters
        // includes those formatting scalars as well as actual control codes.
        String(String.UnicodeScalarView(value.unicodeScalars.filter {
            $0.value >= 0x20 && !(0x7f...0x9f).contains($0.value)
        }))
    }
}

/// A local preference only. No system account name is read and no login is
/// required. Callers inject the suite so renderers/tests never touch real prefs.
@MainActor
final class BrewProfileStore: ObservableObject {
    private let defaults: UserDefaults
    @Published var nickname: String {
        didSet {
            // Keep a trailing space while editing so two-word names can be
            // typed. The saved/displayed value is normalized separately.
            let cleaned = BrewProfile.editingNickname(nickname)
            if nickname != cleaned { nickname = cleaned; return }
            defaults.set(BrewProfile.cleanNickname(nickname), forKey: "brewProfile.nickname")
        }
    }
    @Published var avatar: BrewAvatar {
        didSet { defaults.set(avatar.rawValue, forKey: "brewProfile.avatar") }
    }
    @Published var showsTokenTotals: Bool {
        didSet { defaults.set(showsTokenTotals, forKey: "brewProfile.showsTokenTotals") }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        nickname = BrewProfile.cleanNickname(defaults.string(forKey: "brewProfile.nickname") ?? "")
        avatar = BrewAvatar(rawValue: defaults.string(forKey: "brewProfile.avatar") ?? "") ?? .cup
        showsTokenTotals = defaults.bool(forKey: "brewProfile.showsTokenTotals")
    }

    var value: BrewProfile { BrewProfile(nickname: nickname, avatar: avatar, showsTokenTotals: showsTokenTotals) }
}
