import Foundation
import Testing
@testable import LookawayCore

private let epoch = Date(timeIntervalSinceReferenceDate: 3_000_000)
private func at(_ t: TimeInterval) -> Date { epoch.addingTimeInterval(t) }

/// Distance 0.3 against a limit of 0.5, facing, head sweeping 10 degrees across the run: live.
private func owner(_ i: Int) -> FaceSample { FaceSample(distance: 0.3, yaw: Double(i * 2), pitch: 0, roll: 0) }
private func stranger(_ i: Int) -> FaceSample { FaceSample(distance: 0.9, yaw: Double(i * 2), pitch: 0, roll: 0) }
private func photo(_ i: Int) -> FaceSample { FaceSample(distance: 0.3, yaw: 0, pitch: 0, roll: 0) }

private struct Harness {
    var machine: CoverMachine

    init(requirePhone: Bool = true, maxCover: TimeInterval = 1800, engaged: Bool = true) {
        machine = CoverMachine(config: CoverConfig(threshold: 0.5, requirePhone: requirePhone, maxCover: maxCover))
        if engaged { send(.engaged, at: 0) }
    }

    @discardableResult
    mutating func send(_ event: CoverEvent, at t: TimeInterval) -> [CoverAction] {
        machine.handle(event, at: at(t))
    }

    /// Feeds a frame every 0.2 s for `seconds`; returns the first non-empty action list.
    @discardableResult
    mutating func feed(from start: TimeInterval, seconds: TimeInterval, _ sample: (Int) -> FaceSample) -> [CoverAction] {
        for i in 0...Int(seconds / 0.2) {
            let actions = send(.sample(.face(sample(i))), at: start + Double(i) * 0.2)
            if !actions.isEmpty { return actions }
        }
        return []
    }
}

@Suite("Screen cover")
struct CoverMachineTests {
    @Test func ownerWithPhoneLiftsTheCover() {
        var h = Harness()
        h.send(.phone(near: true), at: 0.5)
        #expect(h.feed(from: 1, seconds: 2, owner) == [.lift])
        #expect(!h.machine.engaged)
    }

    @Test func ownerWithoutPhoneDoesNotLift() {
        var h = Harness()
        #expect(h.feed(from: 1, seconds: 5, owner).isEmpty)
        #expect(h.machine.engaged)
    }

    @Test func phoneArrivingMidRunDoesNotCountEarlierFrames() {
        var h = Harness()
        h.feed(from: 1, seconds: 2, owner)
        h.send(.phone(near: true), at: 3.1)
        // One more frame would complete a run that started before the phone came.
        #expect(h.send(.sample(.face(owner(20))), at: 3.2).isEmpty)
        #expect(h.feed(from: 3.4, seconds: 2, owner) == [.lift])
    }

    @Test func phoneLeavingBreaksTheRun() {
        var h = Harness()
        h.send(.phone(near: true), at: 0)
        h.feed(from: 1, seconds: 0.6, owner)
        h.send(.phone(near: false), at: 1.7)
        h.send(.phone(near: true), at: 1.8)
        // Only 0.8 s of frames since the phone came back: not a full run yet.
        #expect(h.feed(from: 2.0, seconds: 0.6, owner).isEmpty)
    }

    @Test func withoutAPairedPhoneTheFaceAloneLifts() {
        var h = Harness(requirePhone: false)
        #expect(h.feed(from: 1, seconds: 2, owner) == [.lift])
    }

    @Test func strangerOrStillPhotoNeverLifts() {
        var h = Harness()
        h.send(.phone(near: true), at: 0)
        #expect(h.feed(from: 1, seconds: 5, stranger).isEmpty)
        #expect(h.feed(from: 7, seconds: 5, photo).isEmpty)
        #expect(h.machine.engaged)
    }

    @Test func inputUnderTheCoverLocksForReal() {
        var h = Harness()
        #expect(h.send(.input, at: 2) == [.lockInstead(.input)])
        #expect(!h.machine.engaged)
        #expect(h.send(.input, at: 3).isEmpty)
    }

    @Test func blockInputOnlyDropsKeyPresses() {
        var h = Harness()
        h.machine = CoverMachine(config: CoverConfig(threshold: 0.5, inputLocks: false))
        h.send(.engaged, at: 0)
        #expect(h.send(.input, at: 2).isEmpty)
        #expect(h.machine.engaged)
        #expect(h.feed(from: 3, seconds: 2, owner) == [.lift])
    }

    @Test func lockShortcutAlwaysLocks() {
        var h = Harness()
        h.machine = CoverMachine(config: CoverConfig(threshold: 0.5, inputLocks: false))
        h.send(.engaged, at: 0)
        #expect(h.send(.lockRequested, at: 1) == [.lockInstead(.input)])
        #expect(!h.machine.engaged)
    }

    @Test func blockInputSettingDoesNotLockOnInput() {
        var s = LookawaySettings()
        s.awayAction = .cover
        #expect(s.coverConfig(threshold: 0.5).inputLocks)
        s.awayAction = .blockInput
        #expect(!s.coverConfig(threshold: 0.5).inputLocks)
    }

    @Test func coverLiftLimitSitsBetweenUnlockAndLock() {
        let t = UnlockTuning()
        #expect(t.threshold(baseThreshold: 0.4, lockThreshold: 0.6) == 0.4)
        #expect(abs(t.coverThreshold(baseThreshold: 0.4, lockThreshold: 0.6) - 0.48) < 0.0001)
        #expect(t.coverThreshold(baseThreshold: 0.4, lockThreshold: 0.44) == 0.44)
    }

    @Test func coverTimesOutIntoALock() {
        var h = Harness(maxCover: 60)
        #expect(h.send(.tick, at: 59).isEmpty)
        #expect(h.send(.tick, at: 60) == [.lockInstead(.timeout)])
        #expect(h.send(.tick, at: 61).isEmpty)
    }

    @Test func nothingHappensWhileNotEngaged() {
        var h = Harness(engaged: false)
        h.send(.phone(near: true), at: 0)
        #expect(h.feed(from: 1, seconds: 2, owner).isEmpty)
        #expect(h.send(.input, at: 4).isEmpty)
        #expect(h.send(.tick, at: 9999).isEmpty)
    }

    @Test func droppedCoverForgetsTheRun() {
        var h = Harness()
        h.send(.phone(near: true), at: 0)
        h.feed(from: 1, seconds: 0.8, owner)
        h.send(.dropped, at: 2)
        h.send(.engaged, at: 2.1)
        #expect(h.feed(from: 2.2, seconds: 0.6, owner).isEmpty)
    }
}

@Suite("Phone proximity")
struct PhoneProximityTests {
    @Test func noReadingIsNotNear() {
        #expect(!PhoneProximity().isNear(at: epoch, threshold: -70, freshness: 10))
    }

    @Test func strongRecentReadingIsNear() {
        var p = PhoneProximity()
        p.record(rssi: -55, at: at(0))
        #expect(p.isNear(at: at(5), threshold: -70, freshness: 10))
    }

    @Test func staleReadingIsNotNear() {
        var p = PhoneProximity()
        p.record(rssi: -55, at: at(0))
        #expect(!p.isNear(at: at(11), threshold: -70, freshness: 10))
    }

    @Test func oneSpikeDoesNotMakeAFarPhoneNear() {
        var p = PhoneProximity()
        for i in 0..<10 { p.record(rssi: -85, at: at(Double(i))) }
        p.record(rssi: -50, at: at(10))
        #expect(!p.isNear(at: at(10), threshold: -70, freshness: 10))
    }

    @Test func invalidReadingsAreIgnored() {
        var p = PhoneProximity()
        p.record(rssi: 127, at: at(0))
        p.record(rssi: 0, at: at(1))
        #expect(p.rssi == nil)
    }

    @Test func afterALongSilenceTheNewReadingStandsAlone() {
        var p = PhoneProximity()
        p.record(rssi: -90, at: at(0))
        p.record(rssi: -55, at: at(60))
        #expect(p.rssi == -55)
    }
}

@Suite("Away machine with the cover")
struct AwayMachineCoverTests {
    @Test func coveredStopsLockingAndReportsCovered() {
        var m = AwayMachine(config: MachineConfig(grace: 5), now: at(0))
        for t in 0...4 { _ = m.handle(.observation(.noOwner), at: at(Double(t))) }
        #expect(m.handle(.tick, at: at(5)) == [.lockScreen])
        _ = m.handle(.coverChanged(true), at: at(5.1))
        #expect(m.status(at: at(6)) == .covered)
        _ = m.handle(.observation(.noOwner), at: at(6))
        #expect(m.handle(.tick, at: at(20)).isEmpty)
        #expect(!m.wantsCamera)
    }

    @Test func coverDownStartsWatchingAfresh() {
        var m = AwayMachine(config: MachineConfig(grace: 5), now: at(0))
        _ = m.handle(.coverChanged(true), at: at(0))
        _ = m.handle(.coverChanged(false), at: at(10))
        #expect(m.status(at: at(10)) == .watching)
        for t in 10...14 { _ = m.handle(.observation(.noOwner), at: at(Double(t))) }
        #expect(m.handle(.tick, at: at(14)).isEmpty)
        #expect(m.handle(.tick, at: at(15)) == [.lockScreen])
    }

    @Test func aRealLockClearsTheCover() {
        var m = AwayMachine(now: at(0))
        _ = m.handle(.coverChanged(true), at: at(0))
        _ = m.handle(.lockStateChanged(locked: true), at: at(1))
        _ = m.handle(.lockStateChanged(locked: false), at: at(2))
        #expect(m.status(at: at(2)) == .watching)
    }
}

@Suite("Cover settings")
struct CoverSettingsTests {
    @Test func aFreshInstallBlocksInput() {
        #expect(LookawaySettings().awayAction == .blockInput)
    }

    @Test func olderSettingsDecodeWithLockAsDefault() throws {
        let old = #"{"mode":"attention","graceSeconds":5,"leniency":1.5}"#
        let s = try JSONDecoder().decode(LookawaySettings.self, from: Data(old.utf8))
        #expect(s.awayAction == .lockScreen)
        #expect(s.phoneID == nil)
    }

    @Test func aPairedPhoneIsRequired() {
        var s = LookawaySettings()
        #expect(!s.coverConfig(threshold: 0.5).requirePhone)
        s.phoneID = "ABC"
        #expect(s.coverConfig(threshold: 0.5).requirePhone)
    }

    @Test func sanitizeClampsAndDropsEmptyPhone() {
        var s = LookawaySettings()
        s.coverMaxMinutes = 10_000
        s.phoneRSSIThreshold = 5
        s.phoneID = ""
        s.phoneName = "x"
        let c = s.sanitized()
        #expect(c.coverMaxMinutes == 240)
        #expect(c.phoneRSSIThreshold == -40)
        #expect(c.phoneID == nil && c.phoneName == nil)
    }
}
