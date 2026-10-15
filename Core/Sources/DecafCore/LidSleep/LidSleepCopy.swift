// LidSleepCopy — every string the lid-closed switch shows (plan 07). The
// warning is part of the safety design, not decoration: a Mac that keeps
// running with its lid shut gets warm, and the user hears that every time they
// switch it on unless they choose not to.

import Foundation
import LidSleepXPC

public enum LidSleepCopy {
    public static let menuTitle = "Keep Running with Lid Closed"
    public static let settingsTitle = "Keep running with the lid closed"

    /// One line under the menu item and under the settings row.
    public static func statusLine(_ status: LidSleepStatus) -> String {
        switch status {
        case .off:
            return "Off. Closing the lid sleeps your Mac."
        case .unavailable(.unsignedBuild):
            return "Needs a signed copy of Decaf."
        case .unavailable(.notInApplications):
            return "Move Decaf to Applications to use this."
        case .unavailable(.registrationFailed(let message)):
            return "Couldn’t set up the helper: \(message)"
        case .needsApproval:
            return "Allow Decaf in Login Items to finish setup."
        case .standby:
            return "On. Works while Decaf keeps your Mac awake."
        case .starting:
            return "Turning on…"
        case .active:
            return "Active. Your Mac keeps running with the lid shut."
        case .pausedLowBattery:
            return "Paused below \(LidSleepXPC.batteryFloorPercent)% battery."
        case .failed(let message):
            return "Couldn’t turn on: \(message)."
        }
    }

    public static let consentTitle = "Keep running with the lid closed?"
    public static let consentBody = """
    While Decaf is keeping your Mac awake, closing the lid won’t put it to sleep. \
    It stays on and gets warm, so don’t put it in a bag or a sleeve.

    Decaf turns this off when the hold ends, below \(LidSleepXPC.batteryFloorPercent)% battery, \
    or if Decaf quits or stops responding.

    The first time, macOS asks you to allow Decaf’s helper in Login Items.
    """
    public static let consentConfirm = "Turn On"
    public static let consentSuppress = "Don’t show this again"

    public static let approvalTitle = "Allow Decaf’s helper"
    public static let approvalBody = """
    In System Settings, open General › Login Items & Extensions and turn on Decaf \
    under Allow in the Background. The switch starts working as soon as you do.
    """
    public static let approvalConfirm = "Open System Settings"

    public static let lowBatteryNotice = UserNotice(
        identifier: "lid-sleep-low-battery",
        title: "Lid-closed mode paused",
        body: "Battery is below \(LidSleepXPC.batteryFloorPercent)%. Closing the lid will put your Mac to sleep."
    )
}
