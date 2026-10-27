import Foundation

/// Tunables the state machine needs. The app maps its persisted settings onto this.
public struct MachineConfig: Equatable, Sendable {
    public var mode: TriggerMode
    /// Seconds without the owner before the screen locks.
    public var grace: TimeInterval
    /// Seconds without any observation before the camera is declared unavailable.
    public var staleAfter: TimeInterval
    /// Minimum seconds between two lock attempts when no "locked" notification follows.
    public var lockRetryAfter: TimeInterval
    /// Without an enrolled face nobody can be recognised, so nothing may lock.
    public var hasEnrollment: Bool
    /// A "locked" notification this soon after we asked for a lock is ours; later
    /// than that it is someone else's (Ctrl+Cmd+Q, hot corner, lid).
    public var lockConfirmWindow: TimeInterval

    public init(
        mode: TriggerMode = .attention,
        grace: TimeInterval = 5,
        staleAfter: TimeInterval = 5,
        lockRetryAfter: TimeInterval = 10,
        hasEnrollment: Bool = true,
        lockConfirmWindow: TimeInterval = 3
    ) {
        self.mode = mode
        self.grace = grace
        self.staleAfter = staleAfter
        self.lockRetryAfter = lockRetryAfter
        self.hasEnrollment = hasEnrollment
        self.lockConfirmWindow = lockConfirmWindow
    }
}

public enum MachineEvent: Equatable, Sendable {
    case observation(Observation)
    /// The session reported the screen locked (`true`) or unlocked (`false`).
    case lockStateChanged(locked: Bool)
    /// Time passed with nothing else happening; drives grace, pause and staleness timers.
    case tick
    case setEnabled(Bool)
    /// `until == nil` means paused until explicitly resumed.
    case pause(until: Date?)
    case resume
    /// Enrollment (or anything else that needs the camera) has taken over.
    case setSuspended(Bool)
    case systemWoke
    case configure(MachineConfig)
    /// lookaway's own cover went up (`true`) or came down (`false`). While covered
    /// nothing locks; the cover decides what happens next.
    case coverChanged(Bool)
}

public enum MachineAction: Equatable, Sendable {
    case lockScreen
    /// Emitted once per outage.
    case notifyCameraUnavailable(String)
}

public enum MachineStatus: Equatable, Sendable {
    case off
    case needsEnrollment
    case enrolling
    case paused(until: Date?)
    case locked
    case cameraUnavailable(String)
    /// Watching, but no frame judged yet.
    case watching
    case present
    case away(since: Date)
    /// A lock was requested but the session has not confirmed it yet.
    case locking
    /// The screen is covered and input blocked until the owner is back.
    case covered

    /// Menu-bar status line.
    public func text(at now: Date, timeFormatter: (Date) -> String = MachineStatus.defaultTime) -> String {
        switch self {
        case .off: return "Off"
        case .needsEnrollment: return "Enroll your face to start"
        case .enrolling: return "Enrolling…"
        case .paused(let until):
            if let until { return "Paused until \(timeFormatter(until))" }
            return "Paused"
        case .locked: return "Screen locked"
        case .cameraUnavailable: return "Camera unavailable"
        case .watching: return "Watching"
        case .present: return "You're here"
        case .away(let since):
            let seconds = max(0, Int(now.timeIntervalSince(since)))
            return "Away \(seconds)s…"
        case .locking: return "Locking…"
        case .covered: return "Screen covered"
        }
    }

    public static func defaultTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }
}

/// Decides when to lock. Pure: every input carries (or is given) a time, and the
/// only output is a list of actions, so fake clocks make it fully testable.
public struct AwayMachine: Sendable {
    public private(set) var config: MachineConfig
    public private(set) var enabled: Bool
    public private(set) var locked: Bool
    /// When the current lock was caused by lookaway itself; nil for a lock the user
    /// (or the system) made, and whenever the screen is unlocked.
    public private(set) var lookawayLockedAt: Date?

    private var pausedUntil: Date?
    private var paused = false
    private var suspended = false
    private var covered = false
    private var present = false
    private var awaySince: Date?
    private var lockIssuedAt: Date?
    private var fault: String?
    private var cameraNotified = false
    /// Last time we heard from the camera (or started waiting for it).
    private var heartbeat: Date

    public init(config: MachineConfig = MachineConfig(), enabled: Bool = true, locked: Bool = false, now: Date) {
        self.config = config
        self.enabled = enabled
        self.locked = locked
        self.heartbeat = now
    }

    /// True when the owner can currently be judged and may be locked out.
    private var active: Bool {
        enabled && !paused && !suspended && !locked && !covered && config.hasEnrollment
    }

    /// Whether the camera should be running for watching. Enrollment drives the
    /// camera itself, and it is released while the screen is locked.
    public var wantsCamera: Bool { active }

    public func status(at now: Date) -> MachineStatus {
        if !enabled { return .off }
        if !config.hasEnrollment { return .needsEnrollment }
        if suspended { return .enrolling }
        if paused { return .paused(until: pausedUntil) }
        if locked { return .locked }
        if covered { return .covered }
        if lockIssuedAt != nil { return .locking }
        if let fault { return .cameraUnavailable(fault) }
        if let awaySince { return .away(since: awaySince) }
        return present ? .present : .watching
    }

    /// Feed an event at time `now`; returns what the app should do.
    public mutating func handle(_ event: MachineEvent, at now: Date) -> [MachineAction] {
        var actions: [MachineAction] = []

        switch event {
        case .observation(let observation):
            if active { actions += absorb(observation, at: now) }

        case .lockStateChanged(let isLocked):
            if isLocked && !locked {
                let ours = lockIssuedAt.map { now.timeIntervalSince($0) <= config.lockConfirmWindow } ?? false
                lookawayLockedAt = ours ? now : nil
            } else if !isLocked {
                lookawayLockedAt = nil
            }
            locked = isLocked
            if isLocked { covered = false }
            lockIssuedAt = nil
            if !isLocked { restartWatch(at: now) } else { awaySince = nil; present = false }

        case .tick:
            break

        case .setEnabled(let on):
            enabled = on
            restartWatch(at: now)

        case .pause(let until):
            paused = true
            pausedUntil = until
            restartWatch(at: now)

        case .resume:
            paused = false
            pausedUntil = nil
            restartWatch(at: now)

        case .setSuspended(let on):
            suspended = on
            restartWatch(at: now)

        case .systemWoke:
            restartWatch(at: now)

        case .configure(let newConfig):
            config = newConfig
            restartWatch(at: now)

        case .coverChanged(let on):
            covered = on
            restartWatch(at: now)
        }

        actions += evaluateTimers(at: now)
        return actions
    }

    // MARK: - Internals

    private mutating func absorb(_ observation: Observation, at now: Date) -> [MachineAction] {
        heartbeat = now
        switch observation {
        case .cameraError(let message):
            return enterFault(message)
        case .ownerFacing:
            cameraRecovered()
            markPresent()
        case .ownerTurned:
            cameraRecovered()
            if config.mode == .presence { markPresent() } else { markAbsent(at: now) }
        case .noOwner:
            cameraRecovered()
            markAbsent(at: now)
        }
        return []
    }

    private mutating func enterFault(_ message: String) -> [MachineAction] {
        fault = message
        awaySince = nil
        present = false
        guard !cameraNotified else { return [] }
        cameraNotified = true
        return [.notifyCameraUnavailable(message)]
    }

    private mutating func cameraRecovered() {
        fault = nil
        cameraNotified = false
    }

    private mutating func markPresent() {
        present = true
        awaySince = nil
    }

    private mutating func markAbsent(at now: Date) {
        present = false
        if awaySince == nil { awaySince = now }
    }

    private mutating func restartWatch(at now: Date) {
        awaySince = nil
        present = false
        lockIssuedAt = nil
        fault = nil
        heartbeat = now
    }

    private mutating func evaluateTimers(at now: Date) -> [MachineAction] {
        var actions: [MachineAction] = []

        if paused, let until = pausedUntil, now >= until {
            paused = false
            pausedUntil = nil
            restartWatch(at: now)
        }

        guard active else { return actions }

        if fault == nil, now.timeIntervalSince(heartbeat) >= config.staleAfter {
            actions += enterFault("No camera frames")
        }

        if fault == nil, let since = awaySince, now.timeIntervalSince(since) >= config.grace {
            let cooledDown = lockIssuedAt.map { now.timeIntervalSince($0) >= config.lockRetryAfter } ?? true
            if cooledDown {
                lockIssuedAt = now
                actions.append(.lockScreen)
            }
        }
        return actions
    }
}
