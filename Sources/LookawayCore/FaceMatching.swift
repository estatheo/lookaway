import Foundation

/// Turns feature-print distances into an "is this the owner" verdict.
///
/// Distances are in whatever unit the feature extractor uses; only their ratios
/// matter. The threshold is calibrated at enrollment time from how far the
/// owner's own samples sit from each other, so it adapts to the camera and lighting.
public struct MatchPolicy: Codable, Equatable, Sendable {
    public var threshold: Float

    public init(threshold: Float) {
        self.threshold = threshold
    }

    /// `intraDistances`: for each enrollment sample, its distance to the nearest
    /// other sample (so a single stray pose cannot inflate the threshold).
    /// `leniency` scales the headroom over the owner's own spread: 1 is tight,
    /// larger accepts more variation (and more look-alikes).
    public static func calibrated(intraDistances: [Float], leniency: Double) -> MatchPolicy {
        let sorted = intraDistances.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sorted.isEmpty else { return MatchPolicy(threshold: 0) }
        let median = sorted[sorted.count / 2]
        let high = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        // A user who held perfectly still yields near-zero spread; keep a floor
        // relative to the median so ordinary frame-to-frame jitter still matches.
        let base = max(high, median * 1.5)
        return MatchPolicy(threshold: base * Float(leniency))
    }

    /// The owner is present when any enrolled sample is within the threshold.
    public func isOwner(distancesToEnrolled distances: [Float]) -> Bool {
        guard let best = distances.filter({ !$0.isNaN }).min() else { return false }
        return best <= threshold
    }
}
