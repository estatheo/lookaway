import Foundation
import Testing
@testable import LookawayCore

@Suite("Attention policy")
struct AttentionPolicyTests {
    let policy = AttentionPolicy(maxYaw: 30, maxPitch: 30)

    @Test func straightOnIsFacing() {
        #expect(policy.isFacing(yaw: 0, pitch: 0))
        #expect(policy.isFacing(yaw: -29, pitch: 10))
    }

    @Test func turnedEitherWayIsNotFacing() {
        #expect(!policy.isFacing(yaw: 45, pitch: 0))
        #expect(!policy.isFacing(yaw: -45, pitch: 0))
    }

    @Test func lookingFarUpOrDownIsNotFacing() {
        #expect(!policy.isFacing(yaw: 0, pitch: 40))
        #expect(!policy.isFacing(yaw: 0, pitch: -40))
    }

    @Test func unknownAnglesDoNotLockTheOwnerOut() {
        #expect(policy.isFacing(yaw: nil, pitch: nil))
        #expect(!policy.isFacing(yaw: 80, pitch: nil))
    }
}

@Suite("Match policy")
struct MatchPolicyTests {
    @Test func ownerWithinThresholdMatches() {
        let policy = MatchPolicy(threshold: 0.6)
        #expect(policy.isOwner(distancesToEnrolled: [0.9, 0.5, 1.2]))
        #expect(policy.isOwner(distancesToEnrolled: [0.6]))
    }

    @Test func strangerBeyondThresholdDoesNotMatch() {
        let policy = MatchPolicy(threshold: 0.6)
        #expect(!policy.isOwner(distancesToEnrolled: [0.9, 1.1, 1.2]))
    }

    @Test func noDistancesOrNaNNeverMatch() {
        let policy = MatchPolicy(threshold: 0.6)
        #expect(!policy.isOwner(distancesToEnrolled: []))
        #expect(!policy.isOwner(distancesToEnrolled: [.nan]))
    }

    @Test func calibrationScalesWithOwnersOwnSpread() {
        let tight = MatchPolicy.calibrated(intraDistances: [0.2, 0.22, 0.25, 0.21, 0.3], leniency: 1.5)
        let loose = MatchPolicy.calibrated(intraDistances: [0.4, 0.5, 0.55, 0.45, 0.6], leniency: 1.5)
        #expect(loose.threshold > tight.threshold)
    }

    @Test func leniencyWidensTheThreshold() {
        let d: [Float] = [0.2, 0.25, 0.3, 0.22, 0.28]
        let strict = MatchPolicy.calibrated(intraDistances: d, leniency: 1.0)
        let lenient = MatchPolicy.calibrated(intraDistances: d, leniency: 2.0)
        #expect(lenient.threshold > strict.threshold)
    }

    @Test func perfectlyStillOwnerStillGetsHeadroom() {
        let policy = MatchPolicy.calibrated(intraDistances: [0.01, 0.01, 0.01, 0.01], leniency: 1.5)
        #expect(policy.threshold > 0.01)
    }

    @Test func oneStrayPoseDoesNotInflateTheThreshold() {
        let steady: [Float] = Array(repeating: 0.25, count: 19)
        let withOutlier = MatchPolicy.calibrated(intraDistances: steady + [5.0], leniency: 1.0)
        #expect(withOutlier.threshold < 1.0)
    }

    @Test func emptyCalibrationMatchesNobody() {
        let policy = MatchPolicy.calibrated(intraDistances: [], leniency: 1.5)
        #expect(!policy.isOwner(distancesToEnrolled: [0.0001]) || policy.threshold == 0)
    }
}

@Suite("Settings")
struct SettingsTests {
    @Test func defaultsAreAttentionAndFiveSeconds() {
        let s = LookawaySettings()
        #expect(s.mode == .attention)
        #expect(s.graceSeconds == 5)
    }

    @Test func codableRoundTrip() throws {
        var s = LookawaySettings()
        s.mode = .presence
        s.graceSeconds = 12
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(LookawaySettings.self, from: data) == s)
    }

    @Test func sanitizingClampsOutOfRangeValues() {
        var s = LookawaySettings()
        s.graceSeconds = -3
        s.leniency = 99
        let clean = s.sanitized()
        #expect(clean.graceSeconds == LookawaySettings.graceRange.lowerBound)
        #expect(clean.leniency == LookawaySettings.leniencyRange.upperBound)
        s.graceSeconds = .nan
        #expect(s.sanitized().graceSeconds == 5)
    }

    @Test func mapsOntoMachineConfig() {
        var s = LookawaySettings()
        s.mode = .presence
        s.graceSeconds = 8
        let c = s.machineConfig(hasEnrollment: false)
        #expect(c.mode == .presence)
        #expect(c.grace == 8)
        #expect(!c.hasEnrollment)
    }
}

@Suite("Status text")
struct StatusTextTests {
    let now = Date(timeIntervalSinceReferenceDate: 5_000)

    @Test func fixedLabels() {
        #expect(MachineStatus.off.text(at: now) == "Off")
        #expect(MachineStatus.watching.text(at: now) == "Watching")
        #expect(MachineStatus.present.text(at: now) == "You're here")
        #expect(MachineStatus.needsEnrollment.text(at: now) == "Enroll your face to start")
        #expect(MachineStatus.locked.text(at: now) == "Screen locked")
    }

    @Test func pausedUsesTheGivenTimeFormatter() {
        let until = now.addingTimeInterval(900)
        #expect(MachineStatus.paused(until: until).text(at: now, timeFormatter: { _ in "14:30" }) == "Paused until 14:30")
        #expect(MachineStatus.paused(until: nil).text(at: now) == "Paused")
    }
}
