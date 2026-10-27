import AppKit
import AVFoundation
import Combine
import Foundation
import LookawayCore

/// Which decision the camera's frames feed.
enum FrameRoute {
    /// Watching for the owner to leave.
    case watch
    /// The screen is locked by lookaway; watching for the owner to unlock it.
    case unlock
    /// lookaway's cover is up; watching for the owner to lift it.
    case cover
}

/// State the camera queue reads while the main thread writes it.
private final class SharedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _enrollment: Enrollment?
    private var _enroller: Enroller?
    private var _leniency: Double = 1.5
    private var _route = FrameRoute.watch

    var enrollment: Enrollment? {
        get { lock.withLock { _enrollment } }
        set { lock.withLock { _enrollment = newValue } }
    }
    var enroller: Enroller? {
        get { lock.withLock { _enroller } }
        set { lock.withLock { _enroller = newValue } }
    }
    var leniency: Double {
        get { lock.withLock { _leniency } }
        set { lock.withLock { _leniency = newValue } }
    }
    var route: FrameRoute {
        get { lock.withLock { _route } }
        set { lock.withLock { _route = newValue } }
    }
}

/// Glues the pure state machine to the camera, Vision, the lock and the UI.
@MainActor
final class Controller: ObservableObject {
    @Published private(set) var settings: LookawaySettings
    /// Latest match distance vs. threshold, for tuning the strictness slider.
    @Published private(set) var diagnostics = "No frames analysed yet"
    @Published private(set) var cameraDenied = false
    /// A login password is in the Keychain (what the auto-unlock toggle really reflects).
    @Published private(set) var credentialPresent: Bool
    /// Auto-unlock gave up after failed attempts and stays off until the next manual unlock.
    @Published private(set) var autoUnlockPaused = false
    /// Why the last auto-unlock attempt was skipped without typing, for the menu. Cleared
    /// on the next manual unlock.
    @Published private(set) var autoUnlockSkipped: String?
    /// The paired phone's smoothed signal and whether it counts as near, for Settings and the cover.
    @Published private(set) var phoneRSSI: Double?
    @Published private(set) var phoneNear = false

    /// Fired after any state change so the menu bar can refresh.
    var onChange: (() -> Void)?
    var onEnrollmentProgress: ((Enroller.Progress) -> Void)?

    private(set) var machine: AwayMachine
    private(set) var unlock: UnlockMachine
    private(set) var cover: CoverMachine
    let phone = PhoneMonitor()
    private var proximity = PhoneProximity()
    private let coverModel = CoverModel()
    private lazy var screenCover = ScreenCover(model: coverModel)
    /// Seconds without hearing the phone before it no longer counts as near.
    private static let phoneFreshness: TimeInterval = 10
    private let camera = FaceCamera()
    private nonisolated(unsafe) let analyzer = FaceAnalyzer()
    private let locker: ScreenLocker
    private let unlocker: ScreenUnlocker
    private let credentials: CredentialStore
    private let store = EnrollmentStore()
    private let session = SessionMonitor()
    private let shared = SharedState()
    private let defaults = UserDefaults.standard

    private var cameraRunning = false
    private var cameraStarting = false
    private var lastCameraStart = Date.distantPast
    private var enrolling = false
    private var warnedLockFailure = false
    private var warnedAccessibility = false
    private var warnedCoverAccessibility = false
    /// Which frame rate the running camera was started for (locked-and-watching is faster).
    private var cameraStartedForUnlock = false
    private var timer: Timer?

    var hasEnrollment: Bool { shared.enrollment != nil }

    var autoUnlockEnabled: Bool { settings.autoUnlock && credentialPresent }
    var canTypePassword: Bool { unlocker.canType }

    init(
        locker: ScreenLocker = SystemScreenLocker(),
        credentials: CredentialStore = KeychainCredentialStore()
    ) {
        self.locker = locker
        self.credentials = credentials
        unlocker = KeystrokeUnlocker(credentials: credentials)
        let loaded = Self.loadSettings(from: defaults)
        settings = loaded
        let enrollment = store.load()
        shared.enrollment = enrollment
        shared.leniency = loaded.leniency
        let enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        let lockedNow = screenIsLockedNow()
        machine = AwayMachine(
            config: loaded.machineConfig(hasEnrollment: enrollment != nil),
            enabled: enabled,
            locked: lockedNow,
            now: Date()
        )
        let hasCredential = credentials.exists
        credentialPresent = hasCredential
        // A lock already in force at launch was not made by us, so it is never auto-unlocked.
        unlock = UnlockMachine(
            config: Self.unlockConfig(loaded, enrollment: enrollment, credentialPresent: hasCredential),
            screenLocked: lockedNow
        )
        cover = CoverMachine(config: Self.coverConfig(loaded, enrollment: enrollment))

        camera.onFrame = { [weak self] buffer in self?.handleFrame(buffer) }
        camera.onFailure = { [weak self] message in
            DispatchQueue.main.async { self?.cameraDied(message) }
        }
        session.onLockChanged = { [weak self] locked in self?.apply(.lockStateChanged(locked: locked)) }
        session.onWake = { [weak self] in self?.systemWoke() }
        session.onWillSleep = { [weak self] in self?.applyUnlock(.systemWillSleep) }
        phone.onReading = { [weak self] rssi in self?.phoneReading(rssi) }
        phone.target = loaded.phoneID.flatMap(UUID.init(uuidString:))
    }

    func start() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        syncCamera()
        onChange?()
    }

    var status: MachineStatus { machine.status(at: Date()) }

    // MARK: - Commands from the UI

    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: "enabled")
        apply(.setEnabled(on))
    }

    func pause(minutes: Double?) {
        apply(.pause(until: minutes.map { Date().addingTimeInterval($0 * 60) }))
    }

    func resume() { apply(.resume) }

    func updateSettings(_ new: LookawaySettings) {
        let clean = new.sanitized()
        settings = clean
        shared.leniency = clean.leniency
        if let data = try? JSONEncoder().encode(clean) { defaults.set(data, forKey: "settings") }
        dispatchUnlock(.configure(currentUnlockConfig()))
        dispatchCover(.configure(currentCoverConfig()))
        let target = clean.phoneID.flatMap(UUID.init(uuidString:))
        if target != phone.target {
            proximity = PhoneProximity()
            phone.target = target
            refreshPhone()
        }
        apply(.configure(clean.machineConfig(hasEnrollment: hasEnrollment)))
    }

    /// Pairs the phone picked in Settings (nil forgets it).
    func pairPhone(_ candidate: PhoneMonitor.Candidate?) {
        var s = settings
        s.phoneID = candidate?.id.uuidString
        s.phoneName = candidate?.label
        updateSettings(s)
    }

    func deleteEnrollment() {
        // Without a face to match, auto-unlock has nothing to go on; drop the password too.
        if credentialPresent { disableAutoUnlock() }
        store.delete()
        shared.enrollment = nil
        diagnostics = "No enrolled face"
        dispatchUnlock(.configure(currentUnlockConfig()))
        dispatchCover(.configure(currentCoverConfig()))
        apply(.configure(settings.machineConfig(hasEnrollment: false)))
    }

    /// Stores the (already verified) login password and turns auto-unlock on.
    func enableAutoUnlock(password: String) throws {
        try credentials.save(password)
        credentialPresent = true
        var s = settings
        s.autoUnlock = true
        updateSettings(s)
    }

    /// Turns auto-unlock off and deletes the password from the Keychain.
    func disableAutoUnlock() {
        credentials.delete()
        credentialPresent = false
        var s = settings
        s.autoUnlock = false
        updateSettings(s)
    }

    func beginEnrollment() {
        guard !enrolling else { return }
        enrolling = true
        shared.enroller = Enroller(analyzer: analyzer)
        apply(.setSuspended(true))
        syncCamera()
    }

    func endEnrollment() {
        guard enrolling else { return }
        enrolling = false
        shared.enroller = nil
        apply(.setSuspended(false))
    }

    var previewSession: AVCaptureSession { camera.session }

    // MARK: - Machine plumbing

    func apply(_ event: MachineEvent) {
        let actions = machine.handle(event, at: Date())
        for action in actions {
            switch action {
            case .lockScreen:
                if settings.awayAction == .lockScreen { performLock() } else { engageCover() }
            case .notifyCameraUnavailable(let message):
                Notifier.post(title: "lookaway can't see", body: "\(message). Locking is paused until the camera is back.")
            }
        }
        switch event {
        case .lockStateChanged(let isLocked):
            // Any real lock (ours, a hot corner, the lid) replaces the cover.
            if isLocked && cover.engaged { dropCover() }
            if !isLocked { autoUnlockSkipped = nil }
            dispatchUnlock(isLocked ? .screenLocked(byLookaway: machine.lookawayLockedAt != nil) : .screenUnlocked)
        case .tick:
            dispatchUnlock(.tick)
            refreshPhone()
            dispatchCover(.tick)
        case .setEnabled(false), .pause:
            if cover.engaged { dropCover() }
        default:
            break
        }
        syncCamera()
        onChange?()
    }

    func applyUnlock(_ event: UnlockEvent) {
        dispatchUnlock(event)
        syncCamera()
        onChange?()
    }

    private func dispatchUnlock(_ event: UnlockEvent) {
        let actions = unlock.handle(event, at: Date())
        if autoUnlockPaused != unlock.lockedOut { autoUnlockPaused = unlock.lockedOut }
        for action in actions {
            switch action {
            case .unlock:
                performUnlock()
            case .notifyAutoUnlockDisabled(let message):
                Notifier.post(title: "lookaway auto-unlock is off", body: message)
            }
        }
    }

    // MARK: - Cover

    func applyCover(_ event: CoverEvent) {
        dispatchCover(event)
        syncCamera()
        onChange?()
    }

    private func dispatchCover(_ event: CoverEvent) {
        for action in cover.handle(event, at: Date()) {
            switch action {
            case .lift:
                log.notice("cover lifted: owner back")
                takeCoverDown()
            case .lockInstead(let why):
                log.notice("cover replaced by a lock: \(String(describing: why), privacy: .public)")
                takeCoverDown()
                performLock()
            }
        }
    }

    private func engageCover() {
        guard !cover.engaged else { return }
        refreshPhone()
        screenCover.onInput = { [weak self] lockShortcut in self?.applyCover(lockShortcut ? .lockRequested : .input) }
        guard screenCover.show(fullScreen: settings.awayAction == .cover) else {
            // Without Accessibility the input cannot be blocked; a real lock is the safe fallback.
            log.notice("cover unavailable (no Accessibility); locking instead")
            if !warnedCoverAccessibility {
                warnedCoverAccessibility = true
                Notifier.post(
                    title: "lookaway locked instead of covering",
                    body: "Covering the screen needs Accessibility access in System Settings > Privacy & Security."
                )
            }
            performLock()
            return
        }
        log.notice("screen covered")
        dispatchCover(.engaged)
        dispatchCover(.phone(near: phoneNear))
        apply(.coverChanged(true))
    }

    /// The cover goes away without the owner lifting it (a real lock, turned off, paused).
    private func dropCover() {
        dispatchCover(.dropped)
        takeCoverDown()
    }

    private func takeCoverDown() {
        screenCover.hide()
        if case .covered = machine.status(at: Date()) { apply(.coverChanged(false)) }
    }

    private func phoneReading(_ rssi: Double) {
        proximity.record(rssi: rssi, at: Date())
        refreshPhone()
    }

    private func refreshPhone() {
        let now = Date()
        let fresh = proximity.lastSeen.map { now.timeIntervalSince($0) <= Self.phoneFreshness } ?? false
        let rssi = fresh ? proximity.rssi : nil
        let near = proximity.isNear(at: now, threshold: settings.phoneRSSIThreshold, freshness: Self.phoneFreshness)
        if rssi != phoneRSSI { phoneRSSI = rssi }
        if near != phoneNear {
            phoneNear = near
            dispatchCover(.phone(near: near))
        }
        coverModel.phoneLine = settings.phoneID == nil
            ? nil
            : (near ? "\(settings.phoneName ?? "Your phone") is nearby" : "Waiting for \(settings.phoneName ?? "your phone")")
    }

    private func currentCoverConfig() -> CoverConfig {
        Self.coverConfig(settings, enrollment: shared.enrollment)
    }

    private static func coverConfig(_ settings: LookawaySettings, enrollment: Enrollment?) -> CoverConfig {
        let tuning = UnlockTuning()
        let threshold = enrollment.map {
            tuning.coverThreshold(baseThreshold: $0.baseThreshold, lockThreshold: $0.policy(leniency: settings.leniency).threshold)
        } ?? 0
        return settings.coverConfig(threshold: threshold, tuning: tuning)
    }

    private func currentUnlockConfig() -> UnlockConfig {
        Self.unlockConfig(settings, enrollment: shared.enrollment, credentialPresent: credentialPresent)
    }

    private static func unlockConfig(_ settings: LookawaySettings, enrollment: Enrollment?, credentialPresent: Bool) -> UnlockConfig {
        let tuning = UnlockTuning()
        let threshold = enrollment.map {
            tuning.threshold(baseThreshold: $0.baseThreshold, lockThreshold: $0.policy(leniency: settings.leniency).threshold)
        } ?? 0
        return settings.unlockConfig(armed: credentialPresent && enrollment != nil, threshold: threshold, tuning: tuning)
    }

    private func performUnlock() {
        let guardDecision = LoginWindowGuard.check(currentUser: NSUserName(), readLastUser: { try LoginWindowGuard.readLastUserFromDisk() })
        if case .skip(let why) = guardDecision {
            log.notice("auto-unlock skipped: \(why, privacy: .public)")
            autoUnlockSkipped = guardDecision.menuMessage
            applyUnlock(.attemptFailed(why))
            return
        }
        autoUnlockSkipped = nil
        log.notice("auto-unlock attempt")
        unlocker.unlock { [weak self] result in
            guard let self, case .failure(let error) = result else { return }
            log.notice("auto-unlock could not run: \(error.localizedDescription, privacy: .public)")
            if case .noAccessibility = error, !self.warnedAccessibility {
                self.warnedAccessibility = true
                Notifier.post(
                    title: "lookaway can't type your password",
                    body: "Grant Accessibility access in System Settings > Privacy & Security to use auto-unlock."
                )
            }
            self.applyUnlock(.attemptFailed(error.localizedDescription))
        }
    }

    /// After sleep the capture session is usually dead; restart it right away
    /// instead of waiting for the staleness watchdog to complain.
    private func systemWoke() {
        if cameraRunning { camera.stop(); cameraRunning = false }
        lastCameraStart = .distantPast
        apply(.systemWoke)
    }

    private func performLock() {
        log.notice("locking screen")
        if !locker.lock(), !warnedLockFailure {
            warnedLockFailure = true
            Notifier.post(
                title: "lookaway couldn't lock the screen",
                body: "Grant Accessibility access in System Settings > Privacy & Security so the Ctrl+Cmd+Q fallback works."
            )
        }
    }

    private func tick() {
        apply(.tick)
        // Retry a dead or silent camera, but not in a tight loop.
        if wantsCameraNow, Date().timeIntervalSince(lastCameraStart) >= 10 {
            if !cameraRunning && !cameraStarting {
                startCamera()
            } else if case .cameraUnavailable = status, !cameraStarting {
                camera.stop()
                cameraRunning = false
                startCamera()
            }
        }
    }

    private var wantsCameraNow: Bool {
        machine.wantsCamera || enrolling || cover.engaged || unlock.wantsCamera(at: Date())
    }

    private func syncCamera() {
        let route: FrameRoute
        if enrolling || machine.wantsCamera {
            route = .watch
        } else if cover.engaged {
            route = .cover
        } else if unlock.wantsCamera(at: Date()) {
            route = .unlock
        } else {
            route = .watch
        }
        shared.route = route
        // Lifting the cover and unlocking judge a run of frames, so both want the faster rate.
        let unlockWatch = route != .watch
        // The frame rate is fixed when capture starts, so restart when the purpose changes.
        if cameraRunning, cameraStartedForUnlock != unlockWatch, wantsCameraNow {
            camera.stop()
            cameraRunning = false
        }
        if wantsCameraNow {
            if !cameraRunning && !cameraStarting && Date().timeIntervalSince(lastCameraStart) >= 1 { startCamera() }
        } else if cameraRunning {
            camera.stop()
            cameraRunning = false
        }
    }

    private func startCamera() {
        cameraStarting = true
        lastCameraStart = Date()
        cameraStartedForUnlock = shared.route != .watch
        camera.framesPerSecond = cameraStartedForUnlock ? FaceCamera.lockedFramesPerSecond : FaceCamera.framesPerSecond
        camera.start { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cameraStarting = false
                switch result {
                case .success:
                    self.cameraRunning = true
                    self.cameraDenied = false
                case .failure(let error):
                    self.cameraRunning = false
                    self.cameraDenied = (error == .denied || error == .restricted)
                    self.cameraFailed(error.localizedDescription)
                }
            }
        }
    }

    private func cameraDied(_ message: String) {
        camera.stop()
        cameraRunning = false
        cameraFailed(message)
    }

    private func cameraFailed(_ message: String) {
        if enrolling {
            onEnrollmentProgress?(.failed(message))
        } else {
            apply(.observation(.cameraError(message)))
        }
    }

    // MARK: - Frames (camera queue)

    private nonisolated func handleFrame(_ buffer: CVPixelBuffer) {
        if let enroller = shared.enroller {
            let progress = enroller.process(buffer)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.enrollmentProgress(progress) } }
            return
        }
        guard let enrollment = shared.enrollment else { return }
        switch shared.route {
        case .unlock:
            let observation = analyzer.unlockObservation(buffer, against: enrollment)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.applyUnlock(.sample(observation)) }
            }
            return
        case .cover:
            let observation = analyzer.unlockObservation(buffer, against: enrollment)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.applyCover(.sample(observation)) }
            }
            return
        case .watch:
            break
        }
        let verdict = analyzer.judge(buffer, against: enrollment, leniency: shared.leniency)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.diagnostics = Self.describe(verdict)
                self.apply(.observation(verdict.observation))
            }
        }
    }

    private func enrollmentProgress(_ progress: Enroller.Progress) {
        guard enrolling else { return }
        if case .finished(let enrollment) = progress {
            do {
                try store.save(enrollment)
            } catch {
                onEnrollmentProgress?(.failed("Could not save: \(error.localizedDescription)"))
                return
            }
            shared.enrollment = enrollment
            shared.enroller = nil
            dispatchUnlock(.configure(currentUnlockConfig()))
            dispatchCover(.configure(currentCoverConfig()))
            apply(.configure(settings.machineConfig(hasEnrollment: true)))
        }
        onEnrollmentProgress?(progress)
    }

    private nonisolated static func describe(_ verdict: FrameVerdict) -> String {
        guard let threshold = verdict.threshold else { return "No frames analysed yet" }
        guard let distance = verdict.bestDistance else { return "No face in view (match limit \(format(threshold)))" }
        let result = distance <= threshold ? "you" : "not you"
        return "Closest face: distance \(format(distance)) vs limit \(format(threshold)) (\(result))"
    }

    private nonisolated static func format(_ value: Float) -> String { String(format: "%.2f", value) }

    private static func loadSettings(from defaults: UserDefaults) -> LookawaySettings {
        guard let data = defaults.data(forKey: "settings"),
              let settings = try? JSONDecoder().decode(LookawaySettings.self, from: data)
        else { return LookawaySettings() }
        return settings.sanitized()
    }
}
