import CoreVideo
import Foundation
import LookawayCore
import Vision

/// The owner's face as a handful of feature vectors. No images are kept.
struct Enrollment {
    var revision: Int
    var prints: [VNFeaturePrintObservation]
    /// Threshold at leniency 1.0; scaled by the user's leniency setting at match time.
    var baseThreshold: Float
    var createdAt: Date

    func policy(leniency: Double) -> MatchPolicy {
        MatchPolicy(threshold: baseThreshold * Float(leniency))
    }
}

/// ~/Library/Application Support/lookaway/enrollment.json (mode 0600).
struct EnrollmentStore {
    private struct File: Codable {
        var version: Int
        var revision: Int
        var baseThreshold: Float
        var createdAt: Date
        var prints: [Data]
    }

    let url: URL

    init(directory: URL = EnrollmentStore.defaultDirectory) {
        url = directory.appendingPathComponent("enrollment.json")
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lookaway", isDirectory: true)
    }

    func load() -> Enrollment? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == 1
        else { return nil }
        let prints = file.prints.compactMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: $0)
        }
        guard !prints.isEmpty, prints.count == file.prints.count else { return nil }
        return Enrollment(revision: file.revision, prints: prints, baseThreshold: file.baseThreshold, createdAt: file.createdAt)
    }

    func save(_ enrollment: Enrollment) throws {
        let archived = try enrollment.prints.map {
            try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }
        let file = File(
            version: 1,
            revision: enrollment.revision,
            baseThreshold: enrollment.baseThreshold,
            createdAt: enrollment.createdAt,
            prints: archived
        )
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(file).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Collects feature prints from live frames until there are enough varied samples.
final class Enroller {
    enum Progress {
        case collecting(have: Int, need: Int, hint: String)
        case finished(Enrollment)
        case failed(String)
    }

    static let samplesNeeded = 16
    private static let minSpacing: TimeInterval = 0.4

    private let analyzer: FaceAnalyzer
    private var prints: [VNFeaturePrintObservation] = []
    private var revision: Int?
    private var lastSampleAt: Date = .distantPast

    init(analyzer: FaceAnalyzer) {
        self.analyzer = analyzer
    }

    func process(_ pixelBuffer: CVPixelBuffer, at now: Date = Date()) -> Progress {
        let faces = analyzer.detectFaces(in: pixelBuffer)
        let need = Self.samplesNeeded
        guard let face = faces.first else {
            return .collecting(have: prints.count, need: need, hint: "Move into view of the camera")
        }
        if faces.count > 1 {
            return .collecting(have: prints.count, need: need, hint: "Only you should be in view")
        }
        guard now.timeIntervalSince(lastSampleAt) >= Self.minSpacing else {
            return .collecting(have: prints.count, need: need, hint: hint(for: prints.count))
        }
        // Enrolling a sideways profile would make the "facing" judgement meaningless.
        if let yaw = face.yaw, abs(yaw) > 35 {
            return .collecting(have: prints.count, need: need, hint: "Look towards the screen")
        }
        guard let print = analyzer.featurePrint(of: face, in: pixelBuffer) else {
            return .collecting(have: prints.count, need: need, hint: hint(for: prints.count))
        }
        revision = print.requestRevision
        prints.append(print)
        lastSampleAt = now

        guard prints.count >= need else {
            return .collecting(have: prints.count, need: need, hint: hint(for: prints.count))
        }
        return finish()
    }

    private func hint(for count: Int) -> String {
        switch count * 4 / Self.samplesNeeded {
        case 0: return "Look at the screen"
        case 1: return "Slowly turn your head a little to the left"
        case 2: return "Now a little to the right"
        default: return "Tilt slightly up and down"
        }
    }

    private func finish() -> Progress {
        // Distance of each sample to its nearest sibling: how much the owner varies.
        var nearest: [Float] = []
        for (i, a) in prints.enumerated() {
            let others = prints.enumerated().compactMap { j, b in j == i ? nil : analyzer.distance(a, b) }
            if let m = others.min() { nearest.append(m) }
        }
        let policy = MatchPolicy.calibrated(intraDistances: nearest, leniency: 1.0)
        guard policy.threshold > 0, let revision else {
            return .failed("Could not measure your face. Try again in better light.")
        }
        return .finished(Enrollment(revision: revision, prints: prints, baseThreshold: policy.threshold, createdAt: Date()))
    }
}
