import CoreGraphics
import Foundation
import Testing
@testable import LookawayCore

@Suite("Face track")
struct FaceTrackTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 4_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    let seat = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)

    @Test func followsTheOwnerTurningAway() {
        var track = FaceTrack()
        track.recognised(at: seat, now: at(0))
        // Turned to a second screen: the box shifts and narrows a little, frame by frame.
        var box = seat
        for i in 1...20 {
            box = box.offsetBy(dx: 0.01, dy: 0).insetBy(dx: 0.002, dy: 0)
            let followed = track.follow([box], now: at(Double(i) * 0.2))
            #expect(followed)
        }
    }

    @Test func followsSittingBack() {
        var track = FaceTrack()
        track.recognised(at: seat, now: at(0))
        let followed = track.follow([seat.insetBy(dx: 0.03, dy: 0.04)], now: at(0.2))
        #expect(followed)
    }

    @Test func noFaceForTooLongDropsTheTrack() {
        var track = FaceTrack()
        track.recognised(at: seat, now: at(0))
        let empty = track.follow([], now: at(1))
        let late = track.follow([seat], now: at(2.5))
        #expect(!empty)
        #expect(!late)
    }

    @Test func aShortDropoutKeepsTheTrack() {
        var track = FaceTrack()
        track.recognised(at: seat, now: at(0))
        let empty = track.follow([], now: at(0.5))
        let back = track.follow([seat], now: at(1.5))
        #expect(!empty)
        #expect(back)
    }

    @Test func aFaceElsewhereIsNotTheOwner() {
        var track = FaceTrack()
        track.recognised(at: seat, now: at(0))
        let followed = track.follow([CGRect(x: 0.0, y: 0.3, width: 0.15, height: 0.2)], now: at(0.2))
        #expect(!followed)
    }

    @Test func nothingIsFollowedBeforeRecognition() {
        var track = FaceTrack()
        let followed = track.follow([seat], now: at(0))
        #expect(!followed)
    }
}
