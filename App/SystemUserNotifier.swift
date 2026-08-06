// SystemUserNotifier — the `UserNotifying` adapter over UNUserNotificationCenter.
//
// It lives in the app target, not in the Core package, for one hard reason:
// `UNUserNotificationCenter.current()` raises when the running process has no
// application bundle, and the package is also linked into `swift test` and into
// `caff-smoke`. The package therefore ships the protocol and a fake, defaults to
// silence, and only `AppEnvironment` — which by definition runs inside the app
// bundle — supplies this class.
//
// Authorization is requested LAZILY, at the first post and never at launch.
// Caffeinate posts one kind of notification (a stuck session's hold being
// released, see REVIEW-DECISIONS 2026-08-06) and most installs will never post
// one at all, so asking at launch would make every user decide about something
// that has not happened. The ask arrives attached to the event that justifies
// it — which is also the only moment at which the user has enough information
// to answer.
//
// A refusal is final and silent: `requestAuthorization` returning false leaves
// the app exactly as it was before this file existed. A notification that
// cannot be delivered must never affect the hold decision that produced it, so
// nothing here reports an error upwards, and every path is fire-and-forget.

import Foundation
import UserNotifications

import CaffeinateCore

final class SystemUserNotifier: UserNotifying, @unchecked Sendable {

    private let center: UNUserNotificationCenter
    private let lock = NSLock()
    /// nil = never asked. Set once the system has answered, so a user who
    /// declined is not re-prompted on every later downgrade.
    private var authorized: Bool?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func post(_ notice: UserNotice) {
        lock.lock()
        let known = authorized
        lock.unlock()

        switch known {
        case .some(true):
            deliver(notice)
        case .some(false):
            // Declined earlier. Do not ask again, do not queue.
            return
        case .none:
            center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
                guard let self else { return }
                self.lock.lock()
                self.authorized = granted
                self.lock.unlock()
                guard granted else { return }
                self.deliver(notice)
            }
        }
    }

    private func deliver(_ notice: UserNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        // No sound: this reports something the app stopped doing, not something
        // that needs the user right now.
        let request = UNNotificationRequest(
            identifier: notice.identifier,
            content: content,
            // nil trigger = deliver immediately.
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }
}
