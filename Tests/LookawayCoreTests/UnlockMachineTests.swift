import Foundation
import Testing
@testable import LookawayCore

/// Fake clock plus a machine armed for a lookaway-caused lock at t = 0.
private struct Harness {
    static let epoch = Date(timeIntervalSinceReferenceDate: 2_000_000)
    /// Strict match limit used by every test: distance <= 0.5 matches.
    static let limit: Float = 0.5

    var machine: UnlockMachine

    init(config: UnlockConfig? = nil, locked byLookaway: Bool? = true) {
        machine = UnlockMachine(config: config ?? Harness.config())
        if let byLookaway { send(.screenLocked(byLookaway: byLookaway), at: 0) }
    }

    static func config(enabled: Bool = true, maxAge: TimeInterval = 600, tuning: UnlockTuning = UnlockTuning()) -> UnlockConfig {
        UnlockConfig(enabled: enabled, maxLockAge: maxAge, threshold: limit, tuning: tuning)
    }

    static func at(_ t: TimeInterval) -> Date { epoch.addingTimeInterval(t) }

    @discardableResult
    mutating func send(_ event: UnlockEvent, at t: TimeInterval) -> [UnlockAction] {
        machine.handle(event, at: Self.at(t))
    }

    @discardableResult
    mutating func see(_ sample: FaceSample, at t: TimeInterval) -> [UnlockAction] {
        send(.sample(.face(sample)), at: t)
    }

    /// Feeds `sample(i)` every 0.2 s starting at `start`; returns the first non-empty action list.
    @discardableResult
    mutating func feed(from start: TimeInterval, seconds: TimeInterval, _ sample: (Int) -> FaceSample) -> [UnlockAction] {
        let frames = Int(seconds / 0.2)
        for i in 0...frames {
            let actions = see(sample(i), at: start + Double(i) * 0.2)
            if !actions.isEmpty { return actions }
        }
        return []
    }
}

/// An owner looking at the screen, with the small head movement a real person has.
private func moving(_ i: Int) -> FaceSample {
    FaceSample(distance: 0.3, yaw: Double(i % 4) * 3, pitch: 0, roll: 0, centerX: 0.5, centerY: 0.5, height: 0.3)
}

/// The same match held perfectly still, as a photo would be.
private func still(_ i: Int) -> FaceSample {
    FaceSample(distance: 0.3, yaw: 2, pitch: 1, roll: 0, eyeOpenness: 0.30, centerX: 0.5, centerY: 0.5, height: 0.3)
}

@Suite("Auto-unlock decision")
struct UnlockDecisionTests {
    @Test func unlocksWhenOwnerReturnsAndMoves() {
        var h = Harness()
        #expect(h.feed(from: 5, seconds: 3, moving) == [.unlock])
    }

    @Test func needsAFullSecondOfFramesNotJustFive() {
        var h = Harness()
        // 5 frames at 0.1 s: enough frames, too short.
        for i in 0..<5 { #expect(h.see(moving(i), at: 5 + Double(i) * 0.1).isEmpty) }
        // Keep going: the run reaches 1 s and fires.
        #expect(h.feed(from: 5.5, seconds: 1) { moving($0 + 5) } == [.unlock])
    }

    @Test func aSingleFrameNeverUnlocks() {
        var h = Harness()
        #expect(h.see(moving(0), at: 5).isEmpty)
    }

    @Test func offByDefault() {
        var h = Harness(config: Harness.config(enabled: false))
        #expect(h.feed(from: 5, seconds: 10, moving).isEmpty)
    }

    @Test func stillPhotoNeverUnlocks() {
        var h = Harness()
        #expect(h.feed(from: 5, seconds: 60, still).isEmpty)
    }

    @Test func blinkAloneCountsAsLive() {
        var h = Harness()
        let eyes: [Double] = [0.30, 0.31, 0.12, 0.30, 0.30, 0.31, 0.30]
        let actions = h.feed(from: 5, seconds: 1.2) { i in
            var s = still(i)
            s.eyeOpenness = eyes[min(i, eyes.count - 1)]
            return s
        }
        #expect(actions == [.unlock])
    }

    @Test func eyesClosedThroughoutIsNotABlink() {
        var h = Harness()
        let actions = h.feed(from: 5, seconds: 10) { i in
            var s = still(i)
            s.eyeOpenness = 0.05
            return s
        }
        #expect(actions.isEmpty)
    }

    @Test func headTranslationCountsAsLive() {
        var h = Harness()
        let actions = h.feed(from: 5, seconds: 2) { i in
            var s = still(i)
            s.centerX = 0.45 + Double(i) * 0.01 // 0.01 per frame, 0.3 high: 10 frames > 10 %
            return s
        }
        #expect(actions == [.unlock])
    }

    @Test func tinyJitterIsNotLive() {
        var h = Harness()
        let actions = h.feed(from: 5, seconds: 20) { i in
            var s = still(i)
            s.centerX = 0.5 + (i % 2 == 0 ? 0.002 : -0.002)
            s.yaw = 2 + (i % 2 == 0 ? 0.5 : -0.5)
            return s
        }
        #expect(actions.isEmpty)
    }

    @Test func aLooseMatchThatWouldLockModeAcceptDoesNotUnlock() {
        var h = Harness()
        let actions = h.feed(from: 5, seconds: 10) { i in
            var s = moving(i)
            s.distance = 0.55 // inside a lenient lock threshold, outside the strict limit
            return s
        }
        #expect(actions.isEmpty)
    }

    @Test func facingAwayDoesNotUnlock() {
        var h = Harness()
        let actions = h.feed(from: 5, seconds: 10) { i in
            var s = moving(i)
            s.yaw = 50 + Double(i % 4) * 3
            return s
        }
        #expect(actions.isEmpty)
    }

    @Test func unknownPoseDoesNotUnlock() {
        var h = Harness()
        let actions = h.feed(from: 5, seconds: 10) { i in
            var s = moving(i)
            s.yaw = nil
            s.pitch = nil
            return s
        }
        #expect(actions.isEmpty)
    }

    @Test func oneBadFrameRestartsTheRun() {
        var h = Harness()
        for i in 0..<4 { h.see(moving(i), at: 5 + Double(i) * 0.2) }          // 0.6 s so far
        h.send(.sample(.noFace), at: 5.8)
        // 0.4 s more would have crossed 1 s from the first frame; the run restarted instead.
        #expect(h.see(moving(0), at: 6.0).isEmpty)
        #expect(h.see(moving(1), at: 6.2).isEmpty)
        #expect(h.see(moving(2), at: 6.4).isEmpty)
        #expect(h.see(moving(3), at: 6.6).isEmpty)
        #expect(h.see(moving(4), at: 6.8).isEmpty)
        #expect(h.see(moving(5), at: 7.0) == [.unlock])
    }

    @Test func aStrangerFrameBreaksTheRun() {
        var h = Harness()
        for i in 0..<5 { h.see(moving(i), at: 5 + Double(i) * 0.2) }
        var stranger = moving(5)
        stranger.distance = 0.9
        #expect(h.see(stranger, at: 6.0).isEmpty)
        #expect(h.see(moving(6), at: 6.2).isEmpty)
    }

    @Test func aGapBetweenFramesBreaksTheRun() {
        var h = Harness()
        for i in 0..<4 { h.see(moving(i), at: 5 + Double(i) * 0.2) }
        // The camera stalled for 2 s: frames before and after must not be stitched together.
        #expect(h.see(moving(4), at: 7.5).isEmpty)
        #expect(h.see(moving(5), at: 7.7).isEmpty)
    }

    @Test func stricterThresholdThanLockMode() {
        let tuning = UnlockTuning()
        // Lock mode at default leniency 1.5 accepts up to 0.9; unlock holds to the base limit.
        #expect(tuning.threshold(baseThreshold: 0.6, lockThreshold: 0.9) == 0.6)
        // Never looser than lock mode, even if lock mode is set strict.
        #expect(tuning.threshold(baseThreshold: 0.6, lockThreshold: 0.5) == 0.5)
    }
}

@Suite("Auto-unlock: which locks may be undone")
struct UnlockEligibilityTests {
    @Test func manualLockIsNeverAutoUnlocked() {
        var h = Harness(locked: false)
        #expect(h.feed(from: 5, seconds: 20, moving).isEmpty)
    }

    @Test func lockAlreadyInForceAtLaunchIsNotOurs() {
        var h = Harness(locked: nil)
        h.machine = UnlockMachine(config: Harness.config(), screenLocked: true)
        #expect(h.feed(from: 5, seconds: 20, moving).isEmpty)
    }

    @Test func notWhileUnlocked() {
        var h = Harness(locked: nil)
        #expect(h.feed(from: 5, seconds: 5, moving).isEmpty)
    }

    @Test func oldLockNeedsNormalUnlock() {
        var h = Harness(config: Harness.config(maxAge: 600))
        #expect(h.feed(from: 601, seconds: 5, moving).isEmpty)
        #expect(!h.machine.isEligible(at: Harness.at(601)))
    }

    @Test func justInsideMaxAgeStillUnlocks() {
        var h = Harness(config: Harness.config(maxAge: 600))
        #expect(h.machine.isEligible(at: Harness.at(599)))
        #expect(h.feed(from: 590, seconds: 5, moving) == [.unlock])
    }

    @Test func maxAgeIsConfigurable() {
        var h = Harness(config: Harness.config(maxAge: 60))
        #expect(h.feed(from: 61, seconds: 5, moving).isEmpty)
    }

    @Test func sleepOrLidCloseInvalidatesTheLock() {
        var h = Harness()
        h.send(.systemWillSleep, at: 30)
        #expect(!h.machine.isEligible(at: Harness.at(31)))
        #expect(h.feed(from: 60, seconds: 10, moving).isEmpty)
    }

    @Test func aLockAfterWakeCaughtByLookawayIsEligibleAgain() {
        var h = Harness()
        h.send(.systemWillSleep, at: 30)
        h.send(.screenUnlocked, at: 40)
        h.send(.screenLocked(byLookaway: true), at: 100)
        #expect(h.feed(from: 105, seconds: 3, moving) == [.unlock])
    }

    @Test func manualUnlockEndsIt() {
        var h = Harness()
        h.send(.screenUnlocked, at: 3)
        #expect(h.feed(from: 5, seconds: 5, moving).isEmpty)
        #expect(!h.machine.wantsCamera(at: Harness.at(5)))
    }

    @Test func wantsCameraOnlyWhileArmed() {
        var h = Harness()
        #expect(h.machine.wantsCamera(at: Harness.at(1)))
        #expect(!h.machine.wantsCamera(at: Harness.at(601)))
        h.send(.configure(Harness.config(enabled: false)), at: 2)
        #expect(!h.machine.wantsCamera(at: Harness.at(3)))
    }
}

@Suite("Auto-unlock: attempts and rate limit")
struct UnlockAttemptTests {
    private func unlockOnce(_ h: inout Harness, from start: TimeInterval) -> [UnlockAction] {
        h.feed(from: start, seconds: 3, moving)
    }

    @Test func noSecondAttemptWhileOneIsInFlight() {
        var h = Harness()
        #expect(unlockOnce(&h, from: 5) == [.unlock])
        #expect(h.feed(from: 6.5, seconds: 5, moving).isEmpty)
    }

    @Test func successfulUnlockClearsFailures() {
        var h = Harness()
        _ = unlockOnce(&h, from: 5)
        h.send(.attemptFailed("typed wrong"), at: 9)           // failure 1
        h.send(.screenUnlocked, at: 10)                        // user unlocked
        h.send(.screenLocked(byLookaway: true), at: 20)
        _ = unlockOnce(&h, from: 25)
        h.send(.attemptFailed("typed wrong"), at: 29)          // failure 1 again, not 2
        #expect(!h.machine.lockedOut)
    }

    @Test func twoFailedAttemptsSwitchAutoUnlockOffUntilManualUnlock() {
        var h = Harness()
        #expect(unlockOnce(&h, from: 5) == [.unlock])
        #expect(h.send(.attemptFailed("wrong password"), at: 9).isEmpty)
        #expect(!h.machine.lockedOut)

        #expect(h.feed(from: 13, seconds: 3, moving) == [.unlock])            // second attempt
        let actions = h.send(.attemptFailed("wrong password"), at: 17)
        #expect(actions.count == 1)
        guard case .notifyAutoUnlockDisabled = actions.first else { Issue.record("expected a notice"); return }
        #expect(h.machine.lockedOut)

        #expect(h.feed(from: 20, seconds: 30, moving).isEmpty)               // nothing more
        #expect(!h.machine.wantsCamera(at: Harness.at(21)))

        // Even a fresh lookaway lock stays off until the user unlocks by hand.
        h.send(.screenLocked(byLookaway: true), at: 60)
        #expect(h.feed(from: 62, seconds: 5, moving).isEmpty)

        h.send(.screenUnlocked, at: 70)
        h.send(.screenLocked(byLookaway: true), at: 80)
        #expect(h.feed(from: 82, seconds: 3, moving) == [.unlock])
    }

    @Test func typedButStillLockedCountsAsFailureAfterTimeout() {
        var h = Harness()
        #expect(unlockOnce(&h, from: 5) == [.unlock])
        let started = 6.0  // the attempt began once the run completed, about 1 s in
        #expect(h.send(.tick, at: started + 3).isEmpty)
        #expect(!h.machine.lockedOut)
        _ = h.send(.tick, at: started + 9)                      // past the 8 s timeout: failure 1
        #expect(!h.machine.attemptInFlight)
        #expect(h.feed(from: started + 14, seconds: 3, moving) == [.unlock])
        _ = h.send(.tick, at: started + 14 + 12)                // failure 2
        #expect(h.machine.lockedOut)
    }

    @Test func coolDownBetweenAttempts() {
        var h = Harness()
        _ = unlockOnce(&h, from: 5)
        h.send(.attemptFailed("x"), at: 7)
        #expect(h.feed(from: 7.2, seconds: 2.5, moving).isEmpty)  // still cooling down (3 s)
        #expect(h.feed(from: 10.2, seconds: 3, moving) == [.unlock])
    }

    @Test func failureWithoutAnAttemptIsIgnored() {
        var h = Harness()
        h.send(.attemptFailed("stray"), at: 3)
        h.send(.attemptFailed("stray"), at: 4)
        #expect(!h.machine.lockedOut)
    }

    @Test func disablingResetsTheLimit() {
        var h = Harness()
        _ = unlockOnce(&h, from: 5)
        h.send(.attemptFailed("x"), at: 7)
        _ = h.feed(from: 11, seconds: 3, moving)
        h.send(.attemptFailed("x"), at: 15)
        #expect(h.machine.lockedOut)
        h.send(.configure(Harness.config(enabled: false)), at: 16)
        h.send(.configure(Harness.config(enabled: true)), at: 17)
        #expect(!h.machine.lockedOut)
    }
}

@Suite("Lookaway-caused locks")
struct LockOriginTests {
    private static let epoch = Date(timeIntervalSinceReferenceDate: 3_000_000)
    private func at(_ t: TimeInterval) -> Date { Self.epoch.addingTimeInterval(t) }

    @Test func aLockWeRequestedIsOurs() {
        var m = AwayMachine(config: MachineConfig(), now: Self.epoch)
        _ = m.handle(.observation(.noOwner), at: at(0))
        let actions = m.handle(.observation(.noOwner), at: at(5))
        #expect(actions == [.lockScreen])
        _ = m.handle(.lockStateChanged(locked: true), at: at(5.4))
        #expect(m.lookawayLockedAt == at(5.4))
    }

    @Test func aLockWeDidNotRequestIsNot() {
        var m = AwayMachine(config: MachineConfig(), now: Self.epoch)
        _ = m.handle(.observation(.ownerFacing), at: at(0))
        _ = m.handle(.lockStateChanged(locked: true), at: at(10))
        #expect(m.lookawayLockedAt == nil)
    }

    @Test func aLateNotificationIsNotOurs() {
        // The lock call failed silently; the user locked by hand 8 s later.
        var m = AwayMachine(config: MachineConfig(), now: Self.epoch)
        _ = m.handle(.observation(.noOwner), at: at(0))
        _ = m.handle(.observation(.noOwner), at: at(5))
        _ = m.handle(.lockStateChanged(locked: true), at: at(13))
        #expect(m.lookawayLockedAt == nil)
    }

    @Test func clearedWhenTheScreenUnlocks() {
        var m = AwayMachine(config: MachineConfig(), now: Self.epoch)
        _ = m.handle(.observation(.noOwner), at: at(0))
        _ = m.handle(.observation(.noOwner), at: at(5))
        _ = m.handle(.lockStateChanged(locked: true), at: at(5.2))
        _ = m.handle(.lockStateChanged(locked: false), at: at(60))
        #expect(m.lookawayLockedAt == nil)
    }

    @Test func aDuplicateLockedNotificationKeepsOwnership() {
        var m = AwayMachine(config: MachineConfig(), now: Self.epoch)
        _ = m.handle(.observation(.noOwner), at: at(0))
        _ = m.handle(.observation(.noOwner), at: at(5))
        _ = m.handle(.lockStateChanged(locked: true), at: at(5.2))
        _ = m.handle(.lockStateChanged(locked: true), at: at(5.9))
        #expect(m.lookawayLockedAt == at(5.2))
    }

    @Test func aManualLockWhileAlreadyLockedStaysManual() {
        var m = AwayMachine(config: MachineConfig(), locked: true, now: Self.epoch)
        _ = m.handle(.lockStateChanged(locked: true), at: at(1))
        #expect(m.lookawayLockedAt == nil)
    }
}

@Suite("Auto-unlock settings")
struct UnlockSettingsTests {
    @Test func offByDefaultWithTenMinuteLimit() {
        let s = LookawaySettings()
        #expect(!s.autoUnlock)
        #expect(s.autoUnlockMaxAgeMinutes == 10)
        #expect(!s.unlockConfig(armed: true, threshold: 0.5).enabled)
    }

    @Test func enabledNeedsTheSettingAndTheArmedConditions() {
        var s = LookawaySettings()
        s.autoUnlock = true
        #expect(s.unlockConfig(armed: true, threshold: 0.5).enabled)
        #expect(!s.unlockConfig(armed: false, threshold: 0.5).enabled)
    }

    @Test func maxAgeFlowsIntoSecondsAndIsClamped() {
        var s = LookawaySettings()
        s.autoUnlockMaxAgeMinutes = 3
        #expect(s.unlockConfig(armed: true, threshold: 0.5).maxLockAge == 180)
        s.autoUnlockMaxAgeMinutes = 100_000
        #expect(s.sanitized().autoUnlockMaxAgeMinutes == 120)
        s.autoUnlockMaxAgeMinutes = 0
        #expect(s.sanitized().autoUnlockMaxAgeMinutes == 1)
    }

    @Test func settingsSavedByTheLockOnlyVersionStillLoad() throws {
        let old = #"{"mode":"presence","graceSeconds":12,"leniency":1.8}"#
        let s = try JSONDecoder().decode(LookawaySettings.self, from: Data(old.utf8))
        #expect(s.mode == .presence)
        #expect(s.graceSeconds == 12)
        #expect(s.leniency == 1.8)
        #expect(!s.autoUnlock)
        #expect(s.autoUnlockMaxAgeMinutes == 10)
    }

    @Test func roundTrips() throws {
        var s = LookawaySettings()
        s.autoUnlock = true
        s.autoUnlockMaxAgeMinutes = 25
        let back = try JSONDecoder().decode(LookawaySettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}
