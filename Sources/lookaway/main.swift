import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import IOKit.pwr_mgt
import LookawayCore

/// `lookaway --check`: verifies the pieces that can be checked without a camera or
/// a lock, and exits. Never locks the screen. Touches the Keychain only through a
/// scratch item that it deletes again.
func runSelfCheck() -> Int32 {
    var failures = 0
    func report(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
        if !ok { failures += 1 }
    }

    report("SACLockScreenImmediate resolves", SystemScreenLocker.resolveLockFunction())
    report("screen currently locked", true, "\(screenIsLockedNow())")

    let auth = AVCaptureDevice.authorizationStatus(for: .video)
    print("info camera authorization: \(auth.rawValue) (0 undetermined, 2 denied, 3 authorized)")

    let enrollment = EnrollmentStore().load()
    print("info enrolled: \(enrollment != nil)")

    // Auto-unlock plumbing: none of it needs the real password.
    let scratch = KeychainCredentialStore(service: "local.gizmos.lookaway.selfcheck", account: "selfcheck")
    var roundTrip = false
    do {
        try scratch.save("selfcheck-not-a-password")
        roundTrip = scratch.read().map { String(decoding: $0, as: UTF8.self) == "selfcheck-not-a-password" } ?? false
    } catch {
        print("info keychain: \(error.localizedDescription)")
    }
    scratch.delete()
    report("Keychain store/read/delete round trip", roundTrip && !scratch.exists)
    report("login password item present", true, "\(KeychainCredentialStore().exists)")
    print("info Accessibility (post events) granted: \(CGPreflightPostEventAccess()) (needed only for auto-unlock typing)")
    var assertion: IOPMAssertionID = 0
    report(
        "display wake assertion",
        IOPMAssertionDeclareUserActivity("lookaway --check" as CFString, kIOPMUserActiveLocal, &assertion) == kIOReturnSuccess
    )
    if assertion != 0 { IOPMAssertionRelease(assertion) }

    // Vision pipeline on an empty frame: must run and find nothing.
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA, nil, &buffer)
    if let buffer {
        let faces = FaceAnalyzer().detectFaces(in: buffer)
        report("Vision face detection on blank frame", faces.isEmpty)
    } else {
        report("create test frame", false)
    }
    return failures == 0 ? 0 : 1
}

if CommandLine.arguments.contains("--check") {
    exit(runSelfCheck())
}

if CommandLine.arguments.contains("--probe-face") {
    exit(runFaceProbe(arguments: CommandLine.arguments))
}

if CommandLine.arguments.contains("--probe-locked-camera") {
    exit(runLockedCameraProbe(arguments: CommandLine.arguments))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
