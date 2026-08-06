// UserNotifying — the app's one user-notification seam.
//
// Plan 04 §MVP shipped ZERO notifications on purpose: a menu bar utility that
// interrupts you is worse than one you forget about, and every notification the
// MVP could have posted was merely restating something the menu already showed.
//
// That rule is NARROWED here, not discarded (see REVIEW-DECISIONS 2026-08-06).
// Exactly one category is admitted: the app, on its own initiative, RELEASING
// something the user asked it to hold. The stuck-session downgrade is that
// category and, today, its only member — a `.working` record whose `Stop` was
// lost keeps the Mac awake indefinitely, and the fix is to stop holding it. The
// user asked for a hold; if the app decides on its own that the hold was based
// on a record that contradicts itself, staying silent about it means the Mac
// starts sleeping during what the user believes is a protected session, with no
// way to tell that from a bug. Everything else stays silent.
//
// The protocol lives here so pure code can depend on it; the concrete
// `UNUserNotificationCenter` adapter lives in the app target, because
// `UNUserNotificationCenter.current()` traps in a process without an
// application bundle (every `swift test` run is such a process).

import Foundation

/// One notification, already reduced to what a notification center needs.
///
/// `identifier` is stable per subject (currently the session id), so a repost
/// for the same subject replaces rather than stacks.
public struct UserNotice: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let body: String

    public init(identifier: String, title: String, body: String) {
        self.identifier = identifier
        self.title = title
        self.body = body
    }
}

/// The seam. Implementations must:
///
/// - request authorization **lazily**, at the first post and never at launch.
///   A menu bar app that asks for notification permission before it has
///   anything to say is asking the user to decide about a hypothetical;
/// - never throw or block the caller — a notification that cannot be delivered
///   is not allowed to affect the hold decision that produced it.
public protocol UserNotifying: AnyObject, Sendable {
    func post(_ notice: UserNotice)
}

/// Records posts instead of showing them (tests, and any headless assembly).
public final class FakeUserNotifier: UserNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UserNotice] = []

    public init() {}

    public var posted: [UserNotice] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func post(_ notice: UserNotice) {
        lock.lock()
        storage.append(notice)
        lock.unlock()
    }
}
