// SettingsStore — UserDefaults-backed settings, the single source of truth for
// preference keys (plan 04 §5). Runtime values for batteryThreshold / gracePeriod
// are injected from here into the engine and detection layer (review decision R3).
//
// Note on "8 settings" (plan 04 §5): the three MVP settings tabs list 8 items
// total, but only 5 are persisted preferences — "launch at login" reads
// SMAppService directly, the Claude Code row is probe-driven status display, and
// "Remove all integrations" is an action button. SettingsKey below is the
// complete persisted set per plan 04.

import Foundation

/// The UserDefaults keys (plan 04 §5 — the only place keys are defined).
public enum SettingsKey {
    /// Encoded `ManualMode` (JSON). Default: `.infinite`.
    public static let defaultManualMode = "defaultManualMode"
    /// "Until" time as minutes since midnight. Default 1080 (18:00).
    public static let untilTime = "untilTime"
    /// Battery gate threshold percent; 0 = off. Default 20.
    public static let batteryThreshold = "batteryThreshold"
    /// Agent release grace period in minutes. Default 3.
    public static let gracePeriodMinutes = "gracePeriodMinutes"
    /// Whether onboarding has completed. Default false.
    public static let hasCompletedOnboarding = "hasCompletedOnboarding"
    /// `DisplayPolicy.rawValue` applied to new holds. Default "allowSleep".
    public static let defaultDisplayPolicy = "defaultDisplayPolicy"
    /// Latch: has an AI coding agent ever been seen on this Mac. Default false.
    public static let hasEverDetectedAgent = "hasEverDetectedAgent"
    /// Whether agent detection drives the hold at all. Default TRUE — note that
    /// this is the one key whose absence must not read as `false`, so its
    /// accessor cannot use `UserDefaults.bool(forKey:)`.
    public static let agentAutoKeepAwake = "agentAutoKeepAwake"
}

/// Typed access to Caffeinate's persisted settings.
public final class SettingsStore {
    /// Factory defaults (plan 04 §5).
    public enum Defaults {
        public static let defaultManualMode: ManualMode = .infinite
        public static let untilTimeMinutes = 1080 // 18:00
        public static let batteryThreshold = 20
        public static let gracePeriodMinutes = 3
        /// The behaviour most people never touch: keep working, let the screen
        /// sleep normally.
        public static let displayPolicy: DisplayPolicy = .allowSleep
        /// On. The product's whole premise is that this works without being
        /// asked for; the switch exists for the people who do not want it.
        public static let agentAutoKeepAwake = true
    }

    private let defaults: UserDefaults

    /// Pass a dedicated suite in tests; the app uses `.standard`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The manual mode applied by the left-click toggle / main switch.
    public var defaultManualMode: ManualMode {
        get {
            guard
                let data = defaults.data(forKey: SettingsKey.defaultManualMode),
                let mode = try? JSONDecoder().decode(ManualMode.self, from: data)
            else {
                return Defaults.defaultManualMode
            }
            return mode
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: SettingsKey.defaultManualMode)
        }
    }

    /// The "until HH:MM" menu item's time, in minutes since midnight.
    public var untilTimeMinutes: Int {
        get {
            defaults.object(forKey: SettingsKey.untilTime) as? Int
                ?? Defaults.untilTimeMinutes
        }
        set { defaults.set(newValue, forKey: SettingsKey.untilTime) }
    }

    /// Battery gate threshold percent; 0 means the battery gate is off.
    public var batteryThreshold: Int {
        get {
            defaults.object(forKey: SettingsKey.batteryThreshold) as? Int
                ?? Defaults.batteryThreshold
        }
        set { defaults.set(newValue, forKey: SettingsKey.batteryThreshold) }
    }

    /// Agent release grace period, in minutes (UI presets 1/2/3/5/10).
    public var gracePeriodMinutes: Int {
        get {
            defaults.object(forKey: SettingsKey.gracePeriodMinutes) as? Int
                ?? Defaults.gracePeriodMinutes
        }
        set { defaults.set(newValue, forKey: SettingsKey.gracePeriodMinutes) }
    }

    /// Display behaviour applied to every newly created hold: agent holds
    /// always use it, and a manual hold starts from it (the menu can then
    /// change the running manual hold, which also updates this default for the
    /// next one).
    public var defaultDisplayPolicy: DisplayPolicy {
        get {
            guard
                let raw = defaults.string(forKey: SettingsKey.defaultDisplayPolicy),
                let policy = DisplayPolicy(rawValue: raw)
            else {
                return Defaults.displayPolicy
            }
            return policy
        }
        set { defaults.set(newValue.rawValue, forKey: SettingsKey.defaultDisplayPolicy) }
    }

    /// Whether an AI coding agent has EVER been seen on this Mac — a latch, not
    /// a status.
    ///
    /// This app is two products in one bundle: the agent-aware keep-awake tool,
    /// and a plain `caffeinate` replacement for someone who has never installed
    /// a coding agent. The menu adapts to the second case by leaving out the
    /// agent controls, and that adaptation needs a signal that CANNOT flap —
    /// watching a menu row appear and vanish as sessions come and go, or as a
    /// probe times out, would be worse than the row a user does not need.
    ///
    /// Hence a latch, and hence a persisted one:
    ///
    /// - **Monotonic.** Nothing sets it back to false. No session ending, no
    ///   agent being closed, no socket rebuild and no failed probe can take a
    ///   control away from a user who has one.
    /// - **Persisted.** The hooks probe is asynchronous and can take upwards of
    ///   ten seconds (it may end in a login shell). Without persistence, every
    ///   launch would show the agentless menu for that window to a user who
    ///   plainly has an agent — a flap on exactly the surface that must not
    ///   flap.
    ///
    /// The cost is the other direction: a user who removes their agent keeps
    /// the agent control forever. That asymmetry is deliberate. Showing a
    /// control someone no longer needs costs one menu line; hiding a control
    /// someone does need costs them the feature.
    public var hasEverDetectedAgent: Bool {
        get { defaults.bool(forKey: SettingsKey.hasEverDetectedAgent) }
        set { defaults.set(newValue, forKey: SettingsKey.hasEverDetectedAgent) }
    }

    /// Whether agent detection is allowed to keep this Mac awake.
    ///
    /// The product runs on one rule — the Mac stays awake while an agent is
    /// working, and sleeps whenever the agent is waiting on the user — and this
    /// is that rule's on/off switch, not a choice between two rules. There is
    /// nothing to configure about HOW agents are handled; there is only whether
    /// they are handled at all.
    ///
    /// Off means the app is a plain `caffeinate` replacement: manual keep-awake,
    /// durations and "Until" behave exactly as before, and coding agents are
    /// ignored. That is a real user — "some people don't use AI" — and it is
    /// also the escape hatch for anyone who wants the automatic behaviour gone
    /// without quitting the app.
    ///
    /// **Default true, and that is why this accessor is three lines instead of
    /// one.** `UserDefaults.bool(forKey:)` returns `false` for a key that was
    /// never written, which would ship the feature switched off to every
    /// existing install and every fresh one. `object(forKey:) as? Bool` tells
    /// "never set" apart from "set to false".
    public var agentAutoKeepAwake: Bool {
        get {
            defaults.object(forKey: SettingsKey.agentAutoKeepAwake) as? Bool
                ?? Defaults.agentAutoKeepAwake
        }
        set { defaults.set(newValue, forKey: SettingsKey.agentAutoKeepAwake) }
    }

    /// Whether first-run onboarding has been completed.
    public var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: SettingsKey.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: SettingsKey.hasCompletedOnboarding) }
    }
}
