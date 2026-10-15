// LidSleepXPC — the contract between Decaf and its root helper (plan 07).
//
// No assertion type can stop a lid-close sleep. The only switch that can is the
// system-wide `SleepDisabled` power setting (what `pmset disablesleep` writes),
// and writing it needs root. So the app asks a root LaunchDaemon, registered
// through `SMAppService.daemon`, over a privileged XPC connection.
//
// Kept to Foundation, IOKit and Security: the helper links this and nothing
// else, and the fewer things a root process links the fewer things can go wrong
// inside it.

import Foundation
import IOKit
import IOKit.ps
import Security

public enum LidSleepXPC {
    /// Bump whenever the helper's behaviour or this protocol changes. An app
    /// that meets a helper of another revision asks it to exit, and launchd
    /// starts the copy bundled with the app on the next lookup.
    public static let revision = "1"

    public static let appIdentifier = "io.github.alany1an.decaf"
    public static let helperIdentifier = "io.github.alany1an.decaf.lid-helper"
    public static let machServiceName = "io.github.alany1an.decaf.lid-helper.xpc"
    /// Under Contents/Library/LaunchDaemons, as `SMAppService.daemon` requires.
    public static let daemonPlistName = "io.github.alany1an.decaf.lid-helper.plist"

    /// Below this, on battery, the helper refuses to hold and reverts a hold it
    /// has. Compiled in rather than configurable: the helper trusts no input it
    /// does not have to.
    public static let batteryFloorPercent = 20
    /// The app heartbeats this often while it holds…
    public static let heartbeatInterval: TimeInterval = 5
    /// …and a hold whose app has been silent this long is reverted.
    public static let heartbeatTimeout: TimeInterval = 30

    /// The peer requirement both ends apply: an exact signing identifier from
    /// the same Developer ID team as the process applying it. A process with no
    /// team (ad-hoc or unsigned) gets nil and must refuse to talk at all —
    /// otherwise any local process could flip a system-wide power setting.
    public static func requirement(forPeer identifier: String) -> String? {
        guard let team = CodeSigningIdentity.currentTeamID() else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}

@objc public protocol DecafLidHelperXPC {
    /// `LidSleepXPC.revision` of the running helper.
    func helperRevision(reply: @escaping (String) -> Void)

    /// Sets SleepDisabled = 1 on behalf of this connection. Fails below the
    /// battery floor or when the setting cannot be written.
    func acquire(reply: @escaping (_ ok: Bool, _ error: String?) -> Void)

    /// Liveness while holding; see `LidSleepXPC.heartbeatTimeout`.
    func heartbeat()

    /// Drops this connection's hold; SleepDisabled returns to 0 once no
    /// connection holds. Idempotent.
    func release(reply: @escaping () -> Void)

    /// Asks an outdated helper to exit so launchd can start the bundled one.
    func exitForUpgrade()
}

public enum CodeSigningIdentity {
    /// The Team ID the running process is signed with, nil when ad-hoc.
    public static func currentTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dictionary = info as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// `SleepDisabled` through IOKit. Both calls are exported by IOKit.framework but
/// declared only in the private IOPMLibPrivate.h, so they are resolved at run
/// time. Writing needs root; reading does not.
public enum SleepDisabledSetting {
    private typealias SetFunction = @convention(c) (CFString, CFTypeRef) -> IOReturn
    private typealias CopyFunction = @convention(c) () -> Unmanaged<CFDictionary>?

    private static let key = "SleepDisabled"
    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    /// nil when the setting cannot be read at all.
    public static func read() -> Bool? {
        guard let symbol = dlsym(iokit, "IOPMCopySystemPowerSettings") else { return nil }
        let copy = unsafeBitCast(symbol, to: CopyFunction.self)
        guard let settings = copy()?.takeRetainedValue() as? [String: Any] else { return nil }
        // Absent until something first writes it.
        return (settings[key] as? NSNumber)?.boolValue ?? false
    }

    /// Writes through IOKit, falling back to `pmset` if the call is missing or
    /// fails, and reports whether the read-back matches.
    @discardableResult
    public static func write(_ disabled: Bool) -> Bool {
        if let symbol = dlsym(iokit, "IOPMSetSystemPowerSetting") {
            let set = unsafeBitCast(symbol, to: SetFunction.self)
            if set(key as CFString, disabled ? kCFBooleanTrue : kCFBooleanFalse) == kIOReturnSuccess,
               read() == disabled {
                return true
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return read() == disabled
    }
}

public enum LidSleepBattery {
    /// True on battery power below `LidSleepXPC.batteryFloorPercent`. A Mac
    /// without a battery is never below the floor.
    public static func isBelowFloor() -> Bool {
        guard
            let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for source in list {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }
            let onBattery = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            return onBattery && percent < LidSleepXPC.batteryFloorPercent
        }
        return false
    }
}
