import Foundation

public struct LookawaySettings: Codable, Equatable, Sendable {
    public static let graceRange: ClosedRange<Double> = 1...120
    public static let leniencyRange: ClosedRange<Double> = 1.0...2.5
    public static let autoUnlockAgeRange: ClosedRange<Double> = 1...120
    public static let coverMaxRange: ClosedRange<Double> = 1...240
    public static let phoneRSSIRange: ClosedRange<Double> = -95 ... -40

    public var mode: TriggerMode = .attention
    /// Seconds without the owner before locking.
    public var graceSeconds: Double = 5
    /// How much variation from the enrolled face still counts as the owner.
    public var leniency: Double = 1.5
    /// Opt-in, less secure: unlock again when the owner's face returns. Off by default.
    /// Only takes effect while a login password is also stored in the Keychain.
    public var autoUnlock: Bool = false
    /// Locks older than this (minutes) need a normal unlock.
    public var autoUnlockMaxAgeMinutes: Double = 10
    /// What happens once you are away. A fresh install blocks the keyboard and mouse (and
    /// plays the video on a touch); settings saved before this key existed locked the screen.
    public var awayAction: AwayAction = .blockInput
    /// After this many minutes a covered screen is locked for real.
    public var coverMaxMinutes: Double = 30
    /// The paired phone's CoreBluetooth identifier; nil when none is paired. A paired
    /// phone must be near for the cover to lift.
    public var phoneID: String?
    public var phoneName: String?
    /// Smoothed signal at or above this (dBm) counts as near. About -65 is arm's length
    /// for an iPhone in a pocket; -80 is the next room.
    public var phoneRSSIThreshold: Double = -70

    public init() {}

    // Settings persisted by an older version lack the newer keys; keep what is there.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LookawaySettings()
        mode = try c.decodeIfPresent(TriggerMode.self, forKey: .mode) ?? d.mode
        graceSeconds = try c.decodeIfPresent(Double.self, forKey: .graceSeconds) ?? d.graceSeconds
        leniency = try c.decodeIfPresent(Double.self, forKey: .leniency) ?? d.leniency
        autoUnlock = try c.decodeIfPresent(Bool.self, forKey: .autoUnlock) ?? d.autoUnlock
        autoUnlockMaxAgeMinutes = try c.decodeIfPresent(Double.self, forKey: .autoUnlockMaxAgeMinutes) ?? d.autoUnlockMaxAgeMinutes
        // An older install locked the screen; upgrading must not quietly stop locking it.
        awayAction = try c.decodeIfPresent(AwayAction.self, forKey: .awayAction) ?? .lockScreen
        coverMaxMinutes = try c.decodeIfPresent(Double.self, forKey: .coverMaxMinutes) ?? d.coverMaxMinutes
        phoneID = try c.decodeIfPresent(String.self, forKey: .phoneID)
        phoneName = try c.decodeIfPresent(String.self, forKey: .phoneName)
        phoneRSSIThreshold = try c.decodeIfPresent(Double.self, forKey: .phoneRSSIThreshold) ?? d.phoneRSSIThreshold
    }

    /// Clamp values read from disk or the UI into sane ranges.
    public func sanitized() -> LookawaySettings {
        var s = self
        s.graceSeconds = min(max(graceSeconds.isFinite ? graceSeconds : 5, Self.graceRange.lowerBound), Self.graceRange.upperBound)
        s.leniency = min(max(leniency.isFinite ? leniency : 1.5, Self.leniencyRange.lowerBound), Self.leniencyRange.upperBound)
        s.autoUnlockMaxAgeMinutes = min(
            max(autoUnlockMaxAgeMinutes.isFinite ? autoUnlockMaxAgeMinutes : 10, Self.autoUnlockAgeRange.lowerBound),
            Self.autoUnlockAgeRange.upperBound
        )
        s.coverMaxMinutes = min(max(coverMaxMinutes.isFinite ? coverMaxMinutes : 30, Self.coverMaxRange.lowerBound), Self.coverMaxRange.upperBound)
        s.phoneRSSIThreshold = min(
            max(phoneRSSIThreshold.isFinite ? phoneRSSIThreshold : -70, Self.phoneRSSIRange.lowerBound),
            Self.phoneRSSIRange.upperBound
        )
        if phoneID?.isEmpty == true { s.phoneID = nil }
        if s.phoneID == nil { s.phoneName = nil }
        return s
    }

    public func machineConfig(hasEnrollment: Bool) -> MachineConfig {
        MachineConfig(mode: mode, grace: graceSeconds, hasEnrollment: hasEnrollment)
    }

    /// `armed` is whether auto-unlock may act at all: the setting is on, a password is
    /// stored and a face is enrolled. `threshold` is the strict unlock match limit.
    public func unlockConfig(armed: Bool, threshold: Float, tuning: UnlockTuning = UnlockTuning()) -> UnlockConfig {
        UnlockConfig(
            enabled: autoUnlock && armed,
            maxLockAge: autoUnlockMaxAgeMinutes * 60,
            threshold: threshold,
            tuning: tuning
        )
    }

    /// `threshold` is the strict match limit, the same as auto-unlock's.
    public func coverConfig(threshold: Float, tuning: UnlockTuning = UnlockTuning()) -> CoverConfig {
        CoverConfig(
            threshold: threshold,
            tuning: tuning,
            requirePhone: phoneID != nil,
            maxCover: coverMaxMinutes * 60,
            inputLocks: awayAction != .blockInput
        )
    }
}
