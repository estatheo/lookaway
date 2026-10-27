import Foundation

/// Every number that decides whether a face is trustworthy enough to unlock the Mac,
/// in one place. All of them are deliberately stricter than the lock side: locking
/// wrongly is an annoyance, unlocking wrongly is a breach.
public struct UnlockTuning: Equatable, Sendable {
    /// Unlock match limit as a multiple of the enrollment's base threshold. Lock mode
    /// uses base x leniency (1.5 by default), so 1.0 is a visibly tighter match.
    public var matchLeniency: Float = 1.0
    /// The same for lifting lookaway's own cover or input block, which types no password.
    /// Measured on the owner in other light than enrollment: 0.42-0.49 against a base of
    /// 0.42, with turned and other faces from 0.6 up, so 1.2 sits between the two.
    public var coverMatchLeniency: Float = 1.2

    /// The owner must match in this many consecutive frames...
    public var minFrames = 5
    /// ...spanning at least this long.
    public var minRunSeconds: TimeInterval = 1.0
    /// A gap between frames longer than this breaks the run.
    public var maxFrameGap: TimeInterval = 0.75

    /// Liveness: a still photo shows none of the following, a person shows at least one.
    /// Head turn: yaw/pitch/roll range across the run, in degrees.
    public var minPoseRange: Double = 6
    /// Head translation across the run, as a fraction of the face height.
    public var minShift: Double = 0.10
    /// Blink: eye openness dips by this fraction of its open value and comes back.
    public var blinkDrop: Double = 0.35

    /// Failed unlock attempts before auto-unlock switches itself off until a manual unlock.
    public var maxAttempts = 2
    /// After typing the password, how long to wait for the session to report unlocked.
    public var attemptTimeout: TimeInterval = 8
    /// Pause between attempts, so a second try is not made on stale frames.
    public var retryCooldown: TimeInterval = 3

    public init() {}

    /// The unlock match limit: never looser than the lock limit.
    public func threshold(baseThreshold: Float, lockThreshold: Float) -> Float {
        min(lockThreshold, baseThreshold * matchLeniency)
    }

    /// The cover's lift limit: looser than auto-unlock's, never looser than the lock limit.
    public func coverThreshold(baseThreshold: Float, lockThreshold: Float) -> Float {
        min(lockThreshold, baseThreshold * coverMatchLeniency)
    }
}

public struct UnlockConfig: Equatable, Sendable {
    /// Setting on, password stored, face enrolled.
    public var enabled: Bool
    /// Locks older than this (seconds) need a normal unlock.
    public var maxLockAge: TimeInterval
    /// Strict match limit, see `UnlockTuning.threshold`.
    public var threshold: Float
    public var attention: AttentionPolicy
    public var tuning: UnlockTuning

    public init(
        enabled: Bool = false,
        maxLockAge: TimeInterval = 600,
        threshold: Float = 0,
        attention: AttentionPolicy = AttentionPolicy(),
        tuning: UnlockTuning = UnlockTuning()
    ) {
        self.enabled = enabled
        self.maxLockAge = maxLockAge
        self.threshold = threshold
        self.attention = attention
        self.tuning = tuning
    }
}

/// What the camera saw in one frame while the screen was locked: the face closest to
/// the enrolled one, with enough geometry to judge pose and liveness.
public struct FaceSample: Equatable, Sendable {
    /// Distance to the nearest enrolled feature vector (lower is more alike).
    public var distance: Float
    /// Degrees; nil when the detector could not tell.
    public var yaw: Double?
    public var pitch: Double?
    public var roll: Double?
    /// Eye height / eye width averaged over both eyes; nil without landmarks.
    public var eyeOpenness: Double?
    /// Face box centre and height, normalised and both in units of the frame height
    /// (so horizontal and vertical movement are comparable).
    public var centerX: Double
    public var centerY: Double
    public var height: Double

    public init(
        distance: Float,
        yaw: Double? = 0,
        pitch: Double? = 0,
        roll: Double? = 0,
        eyeOpenness: Double? = nil,
        centerX: Double = 0.5,
        centerY: Double = 0.5,
        height: Double = 0.3
    ) {
        self.distance = distance
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.eyeOpenness = eyeOpenness
        self.centerX = centerX
        self.centerY = centerY
        self.height = height
    }
}

public enum UnlockObservation: Equatable, Sendable {
    case noFace
    case face(FaceSample)
}

public enum UnlockEvent: Equatable, Sendable {
    case configure(UnlockConfig)
    /// The session reported locked. `byLookaway` is true only for a lock lookaway caused.
    case screenLocked(byLookaway: Bool)
    case screenUnlocked
    /// Sleep (and so lid close): any lock in force then needs a normal unlock.
    case systemWillSleep
    case sample(UnlockObservation)
    /// Typing the password did not get as far as the login window (no permission,
    /// no password, ...).
    case attemptFailed(String)
    case tick
}

public enum UnlockAction: Equatable, Sendable {
    /// Wake the display and type the stored password.
    case unlock
    /// Emitted once, when the attempt limit is reached.
    case notifyAutoUnlockDisabled(String)
}

/// Decides when the owner's returning face is good enough to unlock. Pure, like
/// `AwayMachine`: timestamped events in, actions out.
public struct UnlockMachine: Sendable {
    public private(set) var config: UnlockConfig
    /// True after too many failed attempts, until the next manual unlock.
    public private(set) var lockedOut = false

    private var screenLocked = false
    private var lockedAt: Date?
    private var failures = 0
    private var attemptStartedAt: Date?
    private var cooldownUntil = Date.distantPast
    private var run = OwnerRun()

    public init(config: UnlockConfig = UnlockConfig(), screenLocked: Bool = false) {
        self.config = config
        self.screenLocked = screenLocked
    }

    /// Whether an unlock may be attempted at all right now, regardless of what the camera sees.
    public func isEligible(at now: Date) -> Bool {
        guard config.enabled, screenLocked, !lockedOut, let lockedAt else { return false }
        return now.timeIntervalSince(lockedAt) <= config.maxLockAge
    }

    /// Whether the camera should run to watch for the owner coming back.
    public func wantsCamera(at now: Date) -> Bool { isEligible(at: now) }

    public var attemptInFlight: Bool { attemptStartedAt != nil }

    public mutating func handle(_ event: UnlockEvent, at now: Date) -> [UnlockAction] {
        switch event {
        case .configure(let new):
            let wasEnabled = config.enabled
            config = new
            run.reset()
            if !new.enabled && wasEnabled {
                failures = 0
                lockedOut = false
                attemptStartedAt = nil
            }
            return []

        case .screenLocked(let byLookaway):
            screenLocked = true
            lockedAt = byLookaway ? now : nil
            run.reset()
            attemptStartedAt = nil
            return []

        case .screenUnlocked:
            screenLocked = false
            lockedAt = nil
            run.reset()
            attemptStartedAt = nil
            failures = 0
            lockedOut = false
            return []

        case .systemWillSleep:
            lockedAt = nil
            run.reset()
            attemptStartedAt = nil
            return []

        case .attemptFailed:
            guard attemptStartedAt != nil else { return [] }
            return recordFailure(at: now)

        case .tick:
            if let started = attemptStartedAt, now.timeIntervalSince(started) >= config.tuning.attemptTimeout {
                return recordFailure(at: now)
            }
            return []

        case .sample(let observation):
            return absorb(observation, at: now)
        }
    }

    // MARK: - Internals

    private mutating func recordFailure(at now: Date) -> [UnlockAction] {
        attemptStartedAt = nil
        run.reset()
        failures += 1
        cooldownUntil = now.addingTimeInterval(config.tuning.retryCooldown)
        guard failures >= config.tuning.maxAttempts, !lockedOut else { return [] }
        lockedOut = true
        return [.notifyAutoUnlockDisabled("Auto-unlock failed \(failures) times and is off until you unlock manually.")]
    }

    private mutating func absorb(_ observation: UnlockObservation, at now: Date) -> [UnlockAction] {
        guard isEligible(at: now), attemptStartedAt == nil, now >= cooldownUntil else {
            run.reset()
            return []
        }
        guard run.add(observation, at: now, threshold: config.threshold, attention: config.attention, tuning: config.tuning) else {
            return []
        }
        attemptStartedAt = now
        return [.unlock]
    }
}

/// A run of consecutive frames of the owner, strictly matched and facing the screen,
/// that ends in a liveness check. Shared by auto-unlock and the screen cover.
struct OwnerRun: Sendable {
    private var frames: [(at: Date, sample: FaceSample)] = []

    mutating func reset() { frames = [] }

    /// Adds one frame; true once the run is long enough and live. A passing run resets.
    mutating func add(
        _ observation: UnlockObservation, at now: Date,
        threshold: Float, attention: AttentionPolicy, tuning t: UnlockTuning
    ) -> Bool {
        guard case .face(let sample) = observation, Self.qualifies(sample, threshold: threshold, attention: attention) else {
            frames = []
            return false
        }
        if let last = frames.last, now.timeIntervalSince(last.at) > t.maxFrameGap { frames = [] }
        frames.append((now, sample))

        guard frames.count >= t.minFrames, now.timeIntervalSince(frames[0].at) >= t.minRunSeconds else { return false }
        guard Liveness.isLive(frames.map(\.sample), tuning: t) else { return false }
        frames = []
        return true
    }

    /// The strict single-frame test: a close match, and a head turned to the screen.
    /// Unlike lock mode, unknown angles do not pass: nothing can be vouched for.
    static func qualifies(_ s: FaceSample, threshold: Float, attention: AttentionPolicy) -> Bool {
        guard s.distance.isFinite, s.distance <= threshold else { return false }
        guard let yaw = s.yaw, let pitch = s.pitch else { return false }
        return attention.isFacing(yaw: yaw, pitch: pitch)
    }
}

/// Basic liveness over the frames of a run. This rejects a photo propped up still;
/// it does not stop a video of the owner or a photo waved about by hand.
enum Liveness {
    static func isLive(_ samples: [FaceSample], tuning t: UnlockTuning) -> Bool {
        headMoved(samples, tuning: t) || blinked(samples, tuning: t)
    }

    private static func range(_ values: [Double]) -> Double {
        guard let lo = values.min(), let hi = values.max() else { return 0 }
        return hi - lo
    }

    static func headMoved(_ samples: [FaceSample], tuning t: UnlockTuning) -> Bool {
        let angles: [[Double]] = [
            samples.compactMap(\.yaw), samples.compactMap(\.pitch), samples.compactMap(\.roll),
        ]
        if angles.contains(where: { range($0) >= t.minPoseRange }) { return true }
        let height = samples.map(\.height).reduce(0, +) / Double(max(samples.count, 1))
        guard height > 0 else { return false }
        return range(samples.map(\.centerX)) >= t.minShift * height
            || range(samples.map(\.centerY)) >= t.minShift * height
    }

    /// The eyes open, close, and open again within the run.
    static func blinked(_ samples: [FaceSample], tuning t: UnlockTuning) -> Bool {
        let open = samples.map(\.eyeOpenness)
        let values = open.compactMap { $0 }
        guard values.count == samples.count, values.count >= 3, let hi = values.max(), hi > 0 else { return false }
        let closed = hi * (1 - t.blinkDrop)
        let reopened = hi * (1 - t.blinkDrop / 2)
        for i in 1..<(values.count - 1) where values[i] <= closed {
            if values[..<i].contains(where: { $0 >= reopened }), values[(i + 1)...].contains(where: { $0 >= reopened }) {
                return true
            }
        }
        return false
    }
}
