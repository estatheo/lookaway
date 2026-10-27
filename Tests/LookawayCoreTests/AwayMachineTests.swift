import Foundation
import Testing
@testable import LookawayCore

/// Drives the machine with a fake clock: `at(t)` is t seconds after an arbitrary epoch.
private struct Harness {
    static let epoch = Date(timeIntervalSinceReferenceDate: 1_000_000)
    var machine: AwayMachine

    init(config: MachineConfig = MachineConfig(), enabled: Bool = true, locked: Bool = false) {
        machine = AwayMachine(config: config, enabled: enabled, locked: locked, now: Self.epoch)
    }

    static func at(_ t: TimeInterval) -> Date { epoch.addingTimeInterval(t) }

    @discardableResult
    mutating func send(_ event: MachineEvent, at t: TimeInterval) -> [MachineAction] {
        machine.handle(event, at: Self.at(t))
    }

    @discardableResult
    mutating func see(_ observation: Observation, at t: TimeInterval) -> [MachineAction] {
        send(.observation(observation), at: t)
    }

    /// Observations once a second from `from` to `to` inclusive; returns every action.
    @discardableResult
    mutating func feed(_ observation: Observation, from: Int, to: Int) -> [MachineAction] {
        var all: [MachineAction] = []
        for t in from...to { all += see(observation, at: TimeInterval(t)) }
        return all
    }

    func status(at t: TimeInterval) -> MachineStatus { machine.status(at: Self.at(t)) }
}

@Suite("Locking")
struct LockingTests {
    @Test func staysQuietWhileOwnerFacing() {
        var h = Harness()
        #expect(h.feed(.ownerFacing, from: 0, to: 60).isEmpty)
        #expect(h.status(at: 60) == .present)
    }

    @Test func locksExactlyAtGracePeriod() {
        var h = Harness()
        h.feed(.ownerFacing, from: 0, to: 3)
        #expect(h.see(.noOwner, at: 4).isEmpty)
        #expect(h.see(.noOwner, at: 8).isEmpty)       // 4 s away
        #expect(h.see(.noOwner, at: 8.99).isEmpty)
        #expect(h.see(.noOwner, at: 9) == [.lockScreen]) // 5 s away
    }

    @Test func returningInsideGraceResetsTheTimer() {
        var h = Harness()
        h.feed(.ownerFacing, from: 0, to: 1)
        h.feed(.noOwner, from: 2, to: 5)               // 3 s away
        h.see(.ownerFacing, at: 6)
        #expect(h.status(at: 6) == .present)
        // A fresh absence needs a full grace period again.
        #expect(h.feed(.noOwner, from: 7, to: 11).isEmpty)
        #expect(h.see(.noOwner, at: 12) == [.lockScreen])
    }

    @Test func coworkerOnlyStillLocks() {
        // The camera layer reports a non-owner face as `.noOwner`.
        var h = Harness()
        h.feed(.ownerFacing, from: 0, to: 2)
        let actions = h.feed(.noOwner, from: 3, to: 9)
        #expect(actions == [.lockScreen])
    }

    @Test func graceIsConfigurable() {
        var h = Harness(config: MachineConfig(grace: 2))
        h.see(.noOwner, at: 0)
        #expect(h.see(.noOwner, at: 1).isEmpty)
        #expect(h.see(.noOwner, at: 2) == [.lockScreen])
    }

    @Test func tickAloneCanFireTheLock() {
        var h = Harness()
        h.feed(.noOwner, from: 0, to: 4)
        #expect(h.send(.tick, at: 4.5).isEmpty)
        #expect(h.send(.tick, at: 5) == [.lockScreen])
    }

    @Test func statusCountsUpWhileAway() {
        var h = Harness()
        h.see(.noOwner, at: 10)
        let status = h.status(at: 13)
        #expect(status.text(at: Harness.at(13)) == "Away 3s…")
    }
}

@Suite("Trigger modes")
struct ModeTests {
    @Test func attentionModeTreatsTurnedHeadAsAway() {
        var h = Harness(config: MachineConfig(mode: .attention))
        h.see(.ownerTurned, at: 0)
        #expect(h.see(.ownerTurned, at: 5) == [.lockScreen])
    }

    @Test func presenceModeIgnoresTurnedHead() {
        var h = Harness(config: MachineConfig(mode: .presence))
        #expect(h.feed(.ownerTurned, from: 0, to: 60).isEmpty)
        #expect(h.status(at: 60) == .present)
    }

    @Test func presenceModeStillLocksWhenOwnerLeaves() {
        var h = Harness(config: MachineConfig(mode: .presence))
        h.feed(.ownerTurned, from: 0, to: 3)
        h.see(.noOwner, at: 4)
        #expect(h.see(.noOwner, at: 9) == [.lockScreen])
    }

    @Test func switchingModeRestartsTheGraceTimer() {
        var h = Harness(config: MachineConfig(mode: .attention))
        h.feed(.ownerTurned, from: 0, to: 3)
        h.send(.configure(MachineConfig(mode: .presence)), at: 4)
        #expect(h.feed(.ownerTurned, from: 5, to: 20).isEmpty)
    }
}

@Suite("Lock state")
struct LockStateTests {
    @Test func doesNotRelockWhileLocked() {
        var h = Harness()
        h.see(.noOwner, at: 0)
        #expect(h.see(.noOwner, at: 5) == [.lockScreen])
        h.send(.lockStateChanged(locked: true), at: 5.2)
        #expect(h.status(at: 6) == .locked)
        #expect(h.feed(.noOwner, from: 6, to: 120).isEmpty)
        #expect(!h.machine.wantsCamera)
    }

    @Test func graceTimerRestartsAfterUnlock() {
        var h = Harness()
        h.send(.lockStateChanged(locked: true), at: 0)
        h.send(.lockStateChanged(locked: false), at: 100)
        #expect(h.machine.wantsCamera)
        // Absent right after unlocking: must not lock before a fresh full grace.
        #expect(h.see(.noOwner, at: 101).isEmpty)
        #expect(h.see(.noOwner, at: 105).isEmpty)
        #expect(h.see(.noOwner, at: 106) == [.lockScreen])
    }

    @Test func startsLockedWithoutLocking() {
        var h = Harness(locked: true)
        #expect(h.feed(.noOwner, from: 0, to: 30).isEmpty)
        #expect(h.status(at: 30) == .locked)
    }

    @Test func retriesOnlyAfterCooldownWhenLockIsNeverConfirmed() {
        var h = Harness(config: MachineConfig(lockRetryAfter: 10))
        h.see(.noOwner, at: 0)
        #expect(h.see(.noOwner, at: 5) == [.lockScreen])
        #expect(h.status(at: 6) == .locking)
        #expect(h.feed(.noOwner, from: 6, to: 14).isEmpty)
        #expect(h.see(.noOwner, at: 15) == [.lockScreen])
    }

    @Test func confirmedLockClearsThePendingLock() {
        var h = Harness()
        h.see(.noOwner, at: 0)
        h.see(.noOwner, at: 5)
        h.send(.lockStateChanged(locked: true), at: 5.5)
        h.send(.lockStateChanged(locked: false), at: 20)
        #expect(h.status(at: 20) == .watching)
    }
}

@Suite("Camera trouble")
struct CameraTests {
    @Test func cameraErrorNeverLocksAndNotifiesOnce() {
        var h = Harness()
        h.feed(.ownerFacing, from: 0, to: 2)
        var actions: [MachineAction] = []
        for t in 3...120 { actions += h.see(.cameraError("No camera"), at: TimeInterval(t)) }
        #expect(actions == [.notifyCameraUnavailable("No camera")])
        #expect(h.status(at: 120) == .cameraUnavailable("No camera"))
        #expect(h.status(at: 120).text(at: Harness.at(120)) == "Camera unavailable")
    }

    @Test func absenceBeforeAnOutageDoesNotCarryOver() {
        var h = Harness()
        h.see(.noOwner, at: 0)
        h.see(.noOwner, at: 3)
        h.see(.cameraError("x"), at: 4)
        // Camera comes back and the owner is gone: a fresh grace begins now.
        #expect(h.see(.noOwner, at: 10).isEmpty)
        #expect(h.see(.noOwner, at: 14).isEmpty)
        #expect(h.see(.noOwner, at: 15) == [.lockScreen])
    }

    @Test func silentCameraBecomesUnavailableNotLockLoop() {
        var h = Harness(config: MachineConfig(staleAfter: 5))
        h.see(.ownerFacing, at: 0)
        var actions: [MachineAction] = []
        for t in 1...60 { actions += h.send(.tick, at: TimeInterval(t)) }
        #expect(actions == [.notifyCameraUnavailable("No camera frames")])
        #expect(h.status(at: 60) == .cameraUnavailable("No camera frames"))
    }

    @Test func recoveryAllowsANewNotification() {
        var h = Harness()
        #expect(h.see(.cameraError("a"), at: 0) == [.notifyCameraUnavailable("a")])
        h.see(.ownerFacing, at: 1)
        #expect(h.status(at: 1) == .present)
        #expect(h.see(.cameraError("b"), at: 2) == [.notifyCameraUnavailable("b")])
    }

    @Test func wakeFromSleepForgivesTheGap() {
        var h = Harness(config: MachineConfig(staleAfter: 5))
        h.see(.ownerFacing, at: 0)
        // Laptop sleeps for an hour, then wakes: no stale-camera alarm.
        let actions = h.send(.systemWoke, at: 3600)
        #expect(actions.isEmpty)
        #expect(h.send(.tick, at: 3602).isEmpty)
        #expect(h.status(at: 3602) == .watching)
    }
}

@Suite("Off, pause and enrollment")
struct SwitchTests {
    @Test func disabledNeverLocks() {
        var h = Harness(enabled: false)
        #expect(h.feed(.noOwner, from: 0, to: 60).isEmpty)
        #expect(h.status(at: 60) == .off)
        #expect(!h.machine.wantsCamera)
    }

    @Test func togglingOnStartsFresh() {
        var h = Harness(enabled: false)
        h.send(.setEnabled(true), at: 100)
        #expect(h.machine.wantsCamera)
        #expect(h.see(.noOwner, at: 101).isEmpty)
        #expect(h.see(.noOwner, at: 106) == [.lockScreen])
    }

    @Test func noEnrollmentNeverLocks() {
        var h = Harness(config: MachineConfig(hasEnrollment: false))
        #expect(h.feed(.noOwner, from: 0, to: 60).isEmpty)
        #expect(h.status(at: 60) == .needsEnrollment)
        #expect(!h.machine.wantsCamera)
    }

    @Test func timedPauseSuppressesThenResumesWithFreshGrace() {
        var h = Harness()
        h.send(.pause(until: Harness.at(900)), at: 0)
        #expect(!h.machine.wantsCamera)
        #expect(h.feed(.noOwner, from: 1, to: 899).isEmpty)
        #expect(h.status(at: 899) == .paused(until: Harness.at(900)))
        // Pause expires on the tick at 900; the grace period starts over.
        #expect(h.send(.tick, at: 900).isEmpty)
        #expect(h.machine.wantsCamera)
        #expect(h.see(.noOwner, at: 901).isEmpty)
        #expect(h.see(.noOwner, at: 906) == [.lockScreen])
    }

    @Test func untilResumedPauseNeverExpires() {
        var h = Harness()
        h.send(.pause(until: nil), at: 0)
        #expect(h.send(.tick, at: 100_000).isEmpty)
        #expect(h.status(at: 100_000) == .paused(until: nil))
        #expect(h.status(at: 100_000).text(at: Harness.at(100_000)) == "Paused")
        h.send(.resume, at: 100_001)
        #expect(h.machine.wantsCamera)
        #expect(h.status(at: 100_001) == .watching)
    }

    @Test func enrollmentSuspendsWatching() {
        var h = Harness()
        h.send(.setSuspended(true), at: 0)
        #expect(h.feed(.noOwner, from: 1, to: 60).isEmpty)
        #expect(h.status(at: 60) == .enrolling)
        h.send(.setSuspended(false), at: 61)
        #expect(h.status(at: 61) == .watching)
    }

    @Test func finishingEnrollmentStartsWatching() {
        var h = Harness(config: MachineConfig(hasEnrollment: false))
        h.send(.configure(MachineConfig(hasEnrollment: true)), at: 10)
        #expect(h.machine.wantsCamera)
        #expect(h.status(at: 10) == .watching)
    }
}
