import CoreGraphics
import Foundation

/// Keeps hold of the owner's face between frames once it has been recognised, so turning
/// to a second screen, leaning or sitting back (when the face no longer matches the
/// enrollment) does not count as leaving. Only a face that continues the owner's box,
/// frame to frame with no gap, is followed: stepping out of view breaks the track, and a
/// stranger sitting down later starts with none.
public struct FaceTrack: Sendable {
    /// Seconds without a matching face before the track is dropped.
    public var maxGap: TimeInterval
    /// Overlap (intersection over union) a face must have with the last box to continue it.
    public var minOverlap: Double

    private var box: CGRect?
    private var seenAt: Date?

    public init(maxGap: TimeInterval = 2, minOverlap: Double = 0.3) {
        self.maxGap = maxGap
        self.minOverlap = minOverlap
    }

    /// The owner was recognised at `box`: (re)start the track there.
    public mutating func recognised(at box: CGRect, now: Date) {
        self.box = box
        seenAt = now
    }

    /// Among faces that were not recognised, whether one continues the owner's track. If
    /// so the track moves to it; if not, the track stays put until `maxGap` runs out.
    public mutating func follow(_ boxes: [CGRect], now: Date) -> Bool {
        guard let last = box, let seenAt, now.timeIntervalSince(seenAt) <= maxGap else {
            reset()
            return false
        }
        guard let next = boxes.max(by: { Self.overlap($0, last) < Self.overlap($1, last) }),
              Self.overlap(next, last) >= minOverlap
        else { return false }
        box = next
        self.seenAt = now
        return true
    }

    public mutating func reset() {
        box = nil
        seenAt = nil
    }

    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = Double(i.width * i.height)
        return inter / (Double(a.width * a.height) + Double(b.width * b.height) - inter)
    }
}
