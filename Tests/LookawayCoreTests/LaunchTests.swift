import Testing
@testable import LookawayCore

@Suite("Launch window")
struct LaunchWindowTests {
    @Test func firstLaunchOpensEnrollment() {
        #expect(LaunchWindow.atLaunch(hasEnrollment: false) == .enrollment)
    }

    @Test func enrolledLaunchStaysInTheMenuBar() {
        #expect(LaunchWindow.atLaunch(hasEnrollment: true) == nil)
    }

    @Test func reopeningShowsSettingsOnceEnrolled() {
        #expect(LaunchWindow.forOpening(hasEnrollment: true) == .settings)
    }

    @Test func reopeningBeforeEnrollmentShowsEnrollment() {
        #expect(LaunchWindow.forOpening(hasEnrollment: false) == .enrollment)
    }
}
