import AppKit
import AVFoundation
import Foundation
import LookawayCore

/// `lookaway --probe-locked-camera [--out FILE] [--sleep-display]`
///
/// Answers the question auto-unlock rests on: does the camera keep delivering frames
/// while the screen is locked (and, with `--sleep-display`, while the display is off)?
/// It counts frames only; no frame is stored. It LOCKS THE SCREEN, so run it on purpose,
/// then unlock by hand and read FILE (default /tmp/lookaway-probe.txt).
func runLockedCameraProbe(arguments: [String]) -> Int32 {
    let outPath = arguments.firstIndex(of: "--out").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        ?? "/tmp/lookaway-probe.txt"
    let sleepDisplay = arguments.contains("--sleep-display")
    FileManager.default.createFile(atPath: outPath, contents: nil)
    let out = FileHandle(forWritingAtPath: outPath)

    func note(_ line: String) {
        print(line)
        out?.write(Data((line + "\n").utf8))
    }
    func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    let counter = FrameCounter()
    let camera = FaceCamera()
    camera.framesPerSecond = FaceCamera.lockedFramesPerSecond
    camera.onFrame = { _ in counter.bump() }
    camera.onFailure = { note("camera failure: \($0)") }

    var started: Result<Void, CameraError>?
    camera.start { started = $0 }
    let deadline = Date().addingTimeInterval(30)
    while started == nil, Date() < deadline { pump(0.1) }
    guard case .success? = started else {
        note("FAIL camera did not start: \(started.map { "\($0)" } ?? "timed out waiting for permission")")
        return 1
    }

    pump(3)
    note("before lock: \(counter.take()) frames in the last 3 s")

    var locked = screenIsLockedNow()
    let center = DistributedNotificationCenter.default()
    let tokens = [
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in locked = true },
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in locked = false },
    ]
    defer { tokens.forEach(center.removeObserver) }

    note("locking now; unlock by hand after ~40 s and read \(outPath)")
    _ = SystemScreenLocker().lock()

    var framesWhileLocked = 0
    for second in 1...40 {
        if second == 6, sleepDisplay {
            note("t+\(second)s: putting the display to sleep")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["displaysleepnow"]
            try? task.run()
        }
        pump(1)
        let frames = counter.take()
        if locked { framesWhileLocked += frames }
        note("t+\(second)s locked=\(locked) frames=\(frames)")
    }
    camera.stop()
    note(framesWhileLocked > 0
        ? "RESULT frames kept arriving while locked (\(framesWhileLocked) total)"
        : "RESULT NO frames while locked: auto-unlock cannot work on this Mac")
    return framesWhileLocked > 0 ? 0 : 2
}

private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    func take() -> Int { lock.withLock { defer { count = 0 }; return count } }
}

/// `lookaway --probe-face [--seconds N]`
///
/// Prints what the camera makes of each frame, for working out why the owner is or is
/// not recognised: the match distance against the lock and strict limits, the head
/// angles, and whether the cover (and auto-unlock) would lift. Never blocks or locks.
func runFaceProbe(arguments: [String]) -> Int32 {
    let seconds = arguments.firstIndex(of: "--seconds")
        .flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 15
    guard let enrollment = EnrollmentStore().load() else {
        print("FAIL no enrolled face")
        return 1
    }
    let settings: LookawaySettings = UserDefaults.standard.data(forKey: "settings")
        .flatMap { try? JSONDecoder().decode(LookawaySettings.self, from: $0) }?.sanitized() ?? LookawaySettings()
    let tuning = UnlockTuning()
    let lockLimit = enrollment.policy(leniency: settings.leniency).threshold
    let strict = tuning.coverThreshold(baseThreshold: enrollment.baseThreshold, lockThreshold: lockLimit)
    print(String(format: "base %.3f  lock limit %.3f (leniency %.2f)  lift limit %.3f (auto-unlock %.3f)", enrollment.baseThreshold, lockLimit, settings.leniency, strict, tuning.threshold(baseThreshold: enrollment.baseThreshold, lockThreshold: lockLimit)))

    var cover = CoverMachine(config: CoverConfig(threshold: strict, tuning: tuning))
    _ = cover.handle(.engaged, at: Date())
    let analyzer = FaceAnalyzer()
    let samples = SampleBox()
    let camera = FaceCamera()
    camera.framesPerSecond = FaceCamera.lockedFramesPerSecond
    camera.onFrame = { buffer in
        let presence = analyzer.judge(buffer, against: enrollment, leniency: settings.leniency).observation
        samples.put(analyzer.unlockObservation(buffer, against: enrollment), presence)
    }
    camera.onFailure = { print("camera failure: \($0)") }

    var started: Result<Void, CameraError>?
    camera.start { started = $0 }
    let deadline = Date().addingTimeInterval(30)
    while started == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    guard case .success? = started else {
        print("FAIL camera did not start: \(started.map { "\($0)" } ?? "timed out waiting for permission")")
        return 1
    }
    print("look at the screen now")
    let t0 = Date()
    var lifts = 0
    func f(_ v: Double?) -> String { v.map { String(format: "%6.1f", $0) } ?? "   nil" }
    while Date().timeIntervalSince(t0) < seconds {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        for (observation, presence) in samples.take() {
            let here: String
            switch presence {
            case .ownerFacing: here = "[here, facing]"
            case .ownerTurned: here = settings.mode == .presence ? "[here]" : "[here, turned: away in attention mode]"
            case .noOwner: here = "[AWAY]"
            case .cameraError: here = "[camera error]"
            }
            let now = Date()
            let t = String(format: "%5.1f", now.timeIntervalSince(t0))
            switch observation {
            case .noFace:
                print("\(t)  no face  \(here)")
            case .face(let s):
                let verdict = s.distance > strict ? (s.distance > lockLimit ? "NOT YOU" : "you (lock) but not strict")
                    : (s.yaw == nil || s.pitch == nil ? "strict match, angles missing" : "strict match")
                print("\(t)  dist \(String(format: "%.3f", s.distance))  yaw \(f(s.yaw)) pitch \(f(s.pitch)) roll \(f(s.roll))  eyes \(s.eyeOpenness.map { String(format: "%.2f", $0) } ?? "nil")  \(verdict)  \(here)")
            }
            if cover.handle(.sample(observation), at: now) == [.lift] {
                lifts += 1
                print("\(t)  >>> LIFT")
                _ = cover.handle(.engaged, at: now)
            }
        }
    }
    camera.stop()
    print("RESULT \(lifts) lift(s) in \(Int(seconds)) s")
    return 0
}

private final class SampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(UnlockObservation, Observation)] = []
    func put(_ o: UnlockObservation, _ presence: Observation) { lock.withLock { items.append((o, presence)) } }
    func take() -> [(UnlockObservation, Observation)] { lock.withLock { defer { items = [] }; return items } }
}
