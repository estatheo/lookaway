import CoreImage
import Foundation
import LookawayCore
import Vision

struct DetectedFace {
    /// Normalised, origin bottom-left (Vision's convention).
    let box: CGRect
    /// Degrees; nil when the detector did not report them.
    let yaw: Double?
    let pitch: Double?
}

struct FrameVerdict {
    let observation: Observation
    /// Distance of the closest face to the enrolled prints, and the limit it was held to.
    let bestDistance: Float?
    let threshold: Float?
}

/// All Vision work. Stateless apart from a reusable CIContext; call from one queue.
final class FaceAnalyzer {
    /// Faces smaller than this fraction of the frame height are background people.
    static let minFaceHeight: CGFloat = 0.07
    private static let cropSide: CGFloat = 224
    private static let cropMargin: CGFloat = 0.3

    private let attention: AttentionPolicy
    /// The owner's face from frame to frame, for presence while they look elsewhere.
    private var track = FaceTrack()

    init(attention: AttentionPolicy = AttentionPolicy()) {
        self.attention = attention
    }

    func detectFaces(in pixelBuffer: CVPixelBuffer) -> [DetectedFace] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? [])
            .filter { $0.boundingBox.height >= Self.minFaceHeight }
            .sorted { $0.boundingBox.height > $1.boundingBox.height }
            .prefix(4)
            .map { DetectedFace(box: $0.boundingBox, yaw: $0.yaw?.doubleValue.degrees, pitch: $0.pitch?.doubleValue.degrees) }
    }

    /// Feature print of the face region, squared up with a margin and resampled so
    /// distance reflects the face rather than framing. Roll is not corrected.
    func featurePrint(of face: DetectedFace, in pixelBuffer: CVPixelBuffer, revision: Int? = nil) -> VNFeaturePrintObservation? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let rect = VNImageRectForNormalizedRect(face.box, Int(width), Int(height))
        let side = max(rect.width, rect.height) * (1 + 2 * Self.cropMargin)
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)

        let scale = Self.cropSide / side
        let crop = image
            .clampedToExtent()
            .cropped(to: square)
            .transformed(by: CGAffineTransform(translationX: -square.minX, y: -square.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: Self.cropSide, height: Self.cropSide))

        let request = VNGenerateImageFeaturePrintRequest()
        if let revision { request.revision = revision }
        let handler = VNImageRequestHandler(ciImage: crop, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        return request.results?.first
    }

    /// Reduce one frame to an observation: is the enrolled face here, and facing us?
    func judge(_ pixelBuffer: CVPixelBuffer, against enrollment: Enrollment, leniency: Double) -> FrameVerdict {
        let policy = enrollment.policy(leniency: leniency)
        var best: (distance: Float, face: DetectedFace)?
        let faces = detectFaces(in: pixelBuffer)
        let now = Date()

        for face in faces {
            guard let print = featurePrint(of: face, in: pixelBuffer, revision: enrollment.revision) else { continue }
            let distances = enrollment.prints.compactMap { distance(print, $0) }
            guard let closest = distances.min() else { continue }
            if best == nil || closest < best!.distance { best = (closest, face) }
        }

        guard let best, policy.isOwner(distancesToEnrolled: [best.distance]) else {
            // Not recognised, but if a face carries on where the owner just was, it is the
            // owner looking elsewhere: there, but not facing the screen.
            let followed = track.follow(faces.map(\.box), now: now)
            return FrameVerdict(
                observation: followed ? .ownerTurned : .noOwner,
                bestDistance: best?.distance,
                threshold: policy.threshold
            )
        }
        track.recognised(at: best.face.box, now: now)
        let facing = attention.isFacing(yaw: best.face.yaw, pitch: best.face.pitch)
        return FrameVerdict(
            observation: facing ? .ownerFacing : .ownerTurned,
            bestDistance: best.distance,
            threshold: policy.threshold
        )
    }

    /// Strict single-frame reading for auto-unlock: the face closest to the enrolled
    /// ones with pose, eye openness and position for the liveness check. Uses the
    /// landmarks detector, so call it only while locked and unlock is armed.
    func unlockObservation(_ pixelBuffer: CVPixelBuffer, against enrollment: Enrollment) -> UnlockObservation {
        // Head angles come from the rectangles detector: the landmarks detector reports no
        // pitch at all and yaw only in 45-degree steps, which no strict frame can pass.
        // The landmarks run on the faces it found, for the eyes.
        let rectangles = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do { try handler.perform([rectangles]) } catch { return .noFace }
        let found = (rectangles.results ?? []).filter { $0.boundingBox.height >= Self.minFaceHeight }
        guard !found.isEmpty else { return .noFace }
        let request = VNDetectFaceLandmarksRequest()
        request.inputFaceObservations = found
        do { try handler.perform([request]) } catch { return .noFace }
        func pose(of face: VNFaceObservation) -> VNFaceObservation {
            let c = CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY)
            return found.min { hypot($0.boundingBox.midX - c.x, $0.boundingBox.midY - c.y) < hypot($1.boundingBox.midX - c.x, $1.boundingBox.midY - c.y) } ?? face
        }

        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))
        guard height > 0 else { return .noFace }

        var best: FaceSample?
        let faces = (request.results ?? [])
            .filter { $0.boundingBox.height >= Self.minFaceHeight }
            .sorted { $0.boundingBox.height > $1.boundingBox.height }
            .prefix(4)
        for face in faces {
            let detected = DetectedFace(box: face.boundingBox, yaw: nil, pitch: nil)
            guard let print = featurePrint(of: detected, in: pixelBuffer, revision: enrollment.revision),
                  let closest = enrollment.prints.compactMap({ distance(print, $0) }).min()
            else { continue }
            if let best, best.distance <= closest { continue }
            let angles = pose(of: face)
            best = FaceSample(
                distance: closest,
                yaw: angles.yaw?.doubleValue.degrees,
                pitch: angles.pitch?.doubleValue.degrees,
                roll: angles.roll?.doubleValue.degrees,
                eyeOpenness: Self.eyeOpenness(face),
                centerX: Double(face.boundingBox.midX) * width / height,
                centerY: Double(face.boundingBox.midY),
                height: Double(face.boundingBox.height)
            )
        }
        return best.map(UnlockObservation.face) ?? .noFace
    }

    /// Eye height / eye width averaged over both eyes, from the landmark contours.
    private static func eyeOpenness(_ face: VNFaceObservation) -> Double? {
        guard let landmarks = face.landmarks else { return nil }
        let ratios = [landmarks.leftEye, landmarks.rightEye].compactMap { region -> Double? in
            guard let points = region?.normalizedPoints, points.count >= 4 else { return nil }
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(), maxX > minX else { return nil }
            return Double((maxY - minY) / (maxX - minX))
        }
        guard ratios.count == 2 else { return nil }
        return (ratios[0] + ratios[1]) / 2
    }

    func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var d: Float = 0
        do { try a.computeDistance(&d, to: b) } catch { return nil }
        return d
    }
}

private extension Double {
    var degrees: Double { self * 180 / .pi }
}
