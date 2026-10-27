import Foundation

/// What counts as "here".
public enum TriggerMode: String, Codable, CaseIterable, Sendable {
    /// The owner's face must be turned towards the screen.
    case attention
    /// The owner's face anywhere in frame is enough.
    case presence
}

/// One camera-side verdict about a single frame, already reduced to what the
/// state machine cares about. The Vision code produces these; tests fabricate them.
public enum Observation: Equatable, Sendable {
    /// The enrolled face is visible and turned towards the screen.
    case ownerFacing
    /// The enrolled face is visible but turned away.
    case ownerTurned
    /// No face, or only faces that are not the enrolled one.
    case noOwner
    /// The camera could not deliver frames.
    case cameraError(String)
}

/// Decides whether a detected head pose counts as "turned to the screen".
/// Angles are in degrees, as reported by Vision (yaw: left/right, pitch: up/down).
public struct AttentionPolicy: Equatable, Sendable {
    public var maxYaw: Double
    public var maxPitch: Double

    public init(maxYaw: Double = 30, maxPitch: Double = 30) {
        self.maxYaw = maxYaw
        self.maxPitch = maxPitch
    }

    /// Missing angles mean the detector could not tell; err towards "facing" so a
    /// detector limitation never locks the owner out.
    public func isFacing(yaw: Double?, pitch: Double?) -> Bool {
        if let yaw, abs(yaw) > maxYaw { return false }
        if let pitch, abs(pitch) > maxPitch { return false }
        return true
    }
}
