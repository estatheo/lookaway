import Foundation

/// What happens when the owner has been away for the grace period.
public enum AwayAction: String, Codable, CaseIterable, Sendable {
    /// Lock the session, as Ctrl+Cmd+Q does. The secure option.
    case lockScreen
    /// Cover every display and swallow keyboard and mouse input until the owner (and,
    /// if one is paired, their phone) is back. Nothing to type to get back in.
    case cover
    /// Leave the screen visible and only swallow keyboard and mouse input until the owner
    /// is back. A key press is dropped, not turned into a lock.
    case blockInput
}

/// How close the paired phone is, from Bluetooth signal strength. Pure, so the
/// smoothing and the freshness rule are testable with fake readings.
public struct PhoneProximity: Equatable, Sendable {
    /// Smoothed RSSI in dBm; nil before the first reading.
    public private(set) var rssi: Double?
    public private(set) var lastSeen: Date?

    /// Weight of a new reading. RSSI from a phone in a pocket jumps by 10 dB from one
    /// advert to the next; a slow average keeps one lucky spike from counting as near.
    public static let smoothing = 0.3

    public init() {}

    public mutating func record(rssi reading: Double, at now: Date) {
        // 127 is CoreBluetooth's "no reading"; anything at or above 0 is not a real value.
        guard reading.isFinite, reading < 0 else { return }
        // After a long silence the old average says nothing about where the phone is now.
        if let last = lastSeen, let current = rssi, now.timeIntervalSince(last) < 30 {
            rssi = current + Self.smoothing * (reading - current)
        } else {
            rssi = reading
        }
        lastSeen = now
    }

    /// Near: heard from within `freshness` seconds, and the smoothed signal is at least `threshold`.
    public func isNear(at now: Date, threshold: Double, freshness: TimeInterval) -> Bool {
        guard let rssi, let lastSeen, now.timeIntervalSince(lastSeen) <= freshness else { return false }
        return rssi >= threshold
    }
}

public struct CoverConfig: Equatable, Sendable {
    /// Strict match limit, the same one auto-unlock uses (see `UnlockTuning.threshold`).
    public var threshold: Float
    public var attention: AttentionPolicy
    public var tuning: UnlockTuning
    /// A phone is paired and must be near for the cover to lift.
    public var requirePhone: Bool
    /// The covered screen turns into a real lock after this many seconds.
    public var maxCover: TimeInterval
    /// A key press or click under the cover locks for real. Off for `blockInput`, where
    /// it is simply dropped.
    public var inputLocks: Bool

    public init(
        threshold: Float = 0,
        attention: AttentionPolicy = AttentionPolicy(),
        tuning: UnlockTuning = UnlockTuning(),
        requirePhone: Bool = false,
        maxCover: TimeInterval = 30 * 60,
        inputLocks: Bool = true
    ) {
        self.threshold = threshold
        self.attention = attention
        self.tuning = tuning
        self.requirePhone = requirePhone
        self.maxCover = maxCover
        self.inputLocks = inputLocks
    }
}

public enum CoverEvent: Equatable, Sendable {
    case configure(CoverConfig)
    /// The cover went up.
    case engaged
    /// The cover went away for another reason (the session locked, the app was turned off).
    case dropped
    case sample(UnlockObservation)
    /// Whether the paired phone counts as near right now.
    case phone(near: Bool)
    /// Someone pressed a key or clicked under the cover.
    case input
    /// Ctrl+Cmd+Q under the cover: always the way out to a real lock, in every mode.
    case lockRequested
    case tick
}

public enum CoverAction: Equatable, Sendable {
    /// The owner is back: take the cover down.
    case lift
    /// Replace the cover with a real lock.
    case lockInstead(CoverEscalation)
}

public enum CoverEscalation: Equatable, Sendable {
    /// A key press or click under the cover. Either a stranger, or the owner choosing
    /// Touch ID or the password over waiting to be recognised.
    case input
    /// The cover was up for `maxCover`.
    case timeout
}

/// Decides when the cover comes down, or turns into a real lock. Pure, like the others.
public struct CoverMachine: Sendable {
    public private(set) var config: CoverConfig
    public private(set) var engaged = false
    public private(set) var phoneNear = false

    private var engagedAt: Date?
    private var run = OwnerRun()

    public init(config: CoverConfig = CoverConfig()) {
        self.config = config
    }

    public mutating func handle(_ event: CoverEvent, at now: Date) -> [CoverAction] {
        switch event {
        case .configure(let new):
            config = new
            run.reset()
            return []

        case .engaged:
            engaged = true
            engagedAt = now
            run.reset()
            return []

        case .dropped:
            disengage()
            return []

        case .phone(let near):
            phoneNear = near
            // A phone walking off breaks the run, so its frames cannot count later.
            if !near { run.reset() }
            return []

        case .input:
            guard engaged, config.inputLocks else { return [] }
            disengage()
            return [.lockInstead(.input)]

        case .lockRequested:
            guard engaged else { return [] }
            disengage()
            return [.lockInstead(.input)]

        case .tick:
            guard engaged, let engagedAt, now.timeIntervalSince(engagedAt) >= config.maxCover else { return [] }
            disengage()
            return [.lockInstead(.timeout)]

        case .sample(let observation):
            guard engaged else { return [] }
            // Without the phone, frames do not even start a run: a photo held up first
            // and a phone brought in later must not add up to a lift.
            guard !config.requirePhone || phoneNear else {
                run.reset()
                return []
            }
            guard run.add(observation, at: now, threshold: config.threshold, attention: config.attention, tuning: config.tuning) else {
                return []
            }
            disengage()
            return [.lift]
        }
    }

    private mutating func disengage() {
        engaged = false
        engagedAt = nil
        run.reset()
    }
}
