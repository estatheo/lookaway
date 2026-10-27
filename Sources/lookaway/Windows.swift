import AppKit
import ApplicationServices
import AVFoundation
import LookawayCore
import SwiftUI

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var controller: Controller
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var pairing = false

    var body: some View {
        let settings = controller.settings
        Form {
            Text("lookaway lives in the menu bar (the eye icon, top right). On a Mac with a notch it can be hidden behind the notch when the bar is full; check System Settings › Menu Bar to allow it, or quit a few other menu-bar apps. Opening lookaway again from Finder or Spotlight shows this window.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Lock when", selection: binding(\.mode)) {
                Text("I look away from the screen").tag(TriggerMode.attention)
                Text("I leave the camera's view").tag(TriggerMode.presence)
            }
            .pickerStyle(.radioGroup)

            LabeledContent("Grace period") {
                HStack {
                    Slider(value: binding(\.graceSeconds), in: LookawaySettings.graceRange, step: 1)
                    Text("\(Int(settings.graceSeconds)) s").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }

            LabeledContent("Face match") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Strict")
                        Slider(value: binding(\.leniency), in: LookawaySettings.leniencyRange)
                        Text("Lenient")
                    }
                    Text(controller.diagnostics).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text("If it locks while you are there, move towards Lenient. If a coworker keeps it unlocked, move towards Strict.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("When I'm away") {
                Picker("When I'm away", selection: binding(\.awayAction)) {
                    Text("Lock the screen (secure)").tag(AwayAction.lockScreen)
                    Text("Cover the screen and block the keyboard and mouse").tag(AwayAction.cover)
                    Text("Block the keyboard and mouse only (screen stays visible)").tag(AwayAction.blockInput)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if settings.awayAction == .blockInput {
                    Text("The screen stays as it is; lookaway swallows every key press and click until it sees your face\(settings.phoneID == nil ? "" : " and your phone is nearby"). Typing while it is blocked does nothing, except Ctrl+Cmd+Q, which locks the Mac for real so you can use Touch ID or your password. Anyone walking past can read your screen. A Mac camera can be fooled by a photo: pair your phone below so a picture alone is not enough.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.awayAction == .cover {
                    Text("lookaway covers every display and blocks input; everything underneath keeps running. It lifts when it sees your face\(settings.phoneID == nil ? "" : " and your phone is nearby"). A key press or click under the cover locks the Mac for real, so you can always use Touch ID or your password instead. A Mac camera can be fooled by a photo: pair your phone below so a picture alone is not enough.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.awayAction != .lockScreen {
                    if !ScreenCover.canBlockInput {
                        Text("Accessibility access is needed to block input. Until it is granted, lookaway locks instead.")
                            .font(.caption).foregroundStyle(.red)
                        Button("Open Accessibility Settings…") { openAccessibilityPrivacy() }
                    }
                    LabeledContent("Lock for real after") {
                        HStack {
                            Slider(value: binding(\.coverMaxMinutes), in: LookawaySettings.coverMaxRange, step: 1)
                            Text("\(Int(settings.coverMaxMinutes)) min").monospacedDigit().frame(width: 56, alignment: .trailing)
                        }
                    }
                }
            }

            Section("My phone") {
                PhoneSection(controller: controller, phone: controller.phone, pairing: $pairing)
            }

            Section("Auto-unlock") {
                Toggle("Auto-unlock when I look back (less secure)", isOn: Binding(
                    get: { controller.autoUnlockEnabled },
                    set: { on in
                        if on { enableAutoUnlock() } else { controller.disableAutoUnlock() }
                        controller.objectWillChange.send()
                    }
                ))
                Text("A photo or video of you can fool a Mac camera. Touch ID and Apple Watch stay the secure ways to unlock. Only screens lookaway locked are unlocked, never after sleep or a lid close.")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.autoUnlockEnabled {
                    LabeledContent("Newest lock to undo") {
                        HStack {
                            Slider(value: binding(\.autoUnlockMaxAgeMinutes), in: LookawaySettings.autoUnlockAgeRange, step: 1)
                            Text("\(Int(settings.autoUnlockMaxAgeMinutes)) min").monospacedDigit().frame(width: 56, alignment: .trailing)
                        }
                    }
                    if !controller.canTypePassword {
                        Text("Accessibility access is needed to type the password.").font(.caption).foregroundStyle(.red)
                        Button("Open Accessibility Settings…") { openAccessibilityPrivacy() }
                    }
                    if controller.autoUnlockPaused {
                        Text("Paused after failed attempts. Unlock manually to turn it back on.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            Toggle("Start at login", isOn: Binding(
                get: { launchAtLogin },
                set: { on in
                    do {
                        try LoginItem.set(on)
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                    launchAtLogin = LoginItem.isEnabled
                }
            ))
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }

            Button("Delete enrolled face", role: .destructive) { controller.deleteEnrollment() }
                .disabled(!controller.hasEnrollment)
        }
        .formStyle(.grouped)
        .padding(8)
        // A grouped Form scrolls, so it has no height of its own; without a minimum the
        // hosting window collapses to its title bar.
        .frame(minWidth: 480, idealWidth: 480, minHeight: 420, idealHeight: 680)
    }

    private func enableAutoUnlock() {
        guard let password = AutoUnlockPrompt.askForPassword() else { return }
        do {
            try controller.enableAutoUnlock(password: password)
        } catch {
            AutoUnlockPrompt.showError(error.localizedDescription)
            return
        }
        if !controller.canTypePassword { _ = CGRequestPostEventAccess() }
    }

    private func openAccessibilityPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<LookawaySettings, T>) -> Binding<T> {
        Binding(
            get: { controller.settings[keyPath: keyPath] },
            set: { value in
                var s = controller.settings
                s[keyPath: keyPath] = value
                controller.updateSettings(s)
            }
        )
    }
}

/// Picks the owner's phone out of several: the strong one whose signal fell the most.
enum PhoneFinder {
    enum Stage: Equatable {
        case idle
        case close(Int)
        case far(Int)
        case done(String)
    }

    /// Devices heard in the last 3 s. A phone that went quiet is left out, so it counts as gone.
    static func snapshot(_ candidates: [PhoneMonitor.Candidate], now: Date = Date()) -> [UUID: Double] {
        Dictionary(uniqueKeysWithValues: candidates
            .filter { now.timeIntervalSince($0.lastSeen) <= 3 }
            .map { ($0.id, $0.average) })
    }

    /// Only devices strong while held close count; one that vanished counts as -100 dBm.
    /// The winner must drop by 15 dB and beat the runner-up by 8, or nothing is picked.
    static func pick(close: [UUID: Double], far: [UUID: Double]) -> UUID? {
        let drops = close.filter { $0.value >= -60 }
            .map { (id: $0.key, drop: $0.value - (far[$0.key] ?? -100)) }
            .sorted { $0.drop > $1.drop }
        guard let best = drops.first, best.drop >= 15 else { return nil }
        if drops.count > 1, best.drop - drops[1].drop < 8 { return nil }
        return best.id
    }
}

/// Pairing and the live signal of the owner's phone.
private struct PhoneSection: View {
    @ObservedObject var controller: Controller
    @ObservedObject var phone: PhoneMonitor
    @Binding var pairing: Bool
    @State private var search = ""
    @State private var showUnnamed = false
    @State private var finder = PhoneFinder.Stage.idle
    @State private var closeSignal: [UUID: Double] = [:]
    @State private var found: UUID?

    var body: some View {
        Group { content }
            .onChange(of: pairing) { _, on in phone.discovering = on }
            .onDisappear { phone.discovering = false }
    }

    @ViewBuilder private var content: some View {
        let settings = controller.settings
        if let problem = phone.problem {
            Text(problem).font(.caption).foregroundStyle(.red)
        }
        if let name = settings.phoneName, settings.phoneID != nil {
            LabeledContent("Paired") {
                HStack {
                    Text(name)
                    Spacer()
                    Button("Forget") { controller.pairPhone(nil) }
                }
            }
            LabeledContent("Signal") {
                Text(signalText).monospacedDigit().foregroundStyle(controller.phoneNear ? .green : .secondary)
            }
            LabeledContent("Nearby means") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Far")
                        Slider(value: Binding(
                            get: { controller.settings.phoneRSSIThreshold },
                            set: { v in var s = controller.settings; s.phoneRSSIThreshold = v.rounded(); controller.updateSettings(s) }
                        ), in: LookawaySettings.phoneRSSIRange)
                        Text("Close")
                    }
                    Text("Stronger than \(Int(settings.phoneRSSIThreshold)) dBm. Put the phone where it usually is while you work and set this a little below its signal.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if pairing {
            Text("Unlock your iPhone and keep it next to the Mac. It must be signed in to the same Apple ID as this Mac, or its Bluetooth address cannot be recognised for long.")
                .font(.caption).foregroundStyle(.secondary)
            Text("An iPhone does not broadcast its name. Hold it right next to the Mac: lookaway reads its model (yours looks like \"iPhone · iPhone18,3\") and the strongest signal is at the top.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search", text: $search, prompt: Text("Search, e.g. iPhone"))
                .textFieldStyle(.roundedBorder)
            Toggle("Show unnamed devices", isOn: $showUnnamed)
            finderRow
            if shown.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Listening…").foregroundStyle(.secondary) }
            }
            ForEach(shown) { candidate in
                HStack {
                    if candidate.id == found {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(candidate.label).fontWeight(candidate.id == found ? .semibold : .regular)
                    Spacer()
                    Text("\(candidate.rssi) dBm").monospacedDigit().foregroundStyle(.secondary)
                    Button("Use") {
                        controller.pairPhone(candidate)
                        search = ""
                        pairing = false
                    }
                }
            }
            Button("Cancel") {
                pairing = false
                search = ""
            }
        } else {
            Text("Optional, and recommended with the cover: it only lifts while your phone is nearby, so a photo of you is not enough.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Pair my phone…") { pairing = true }
        }
    }

    /// Several iPhones in range (or one phone under more than one address): yours is the
    /// one whose signal falls when you move it away.
    @ViewBuilder private var finderRow: some View {
        switch finder {
        case .idle:
            HStack {
                Button("Find mine") { startFinder() }
                Text("Several iPhones? This tells yours apart.").font(.caption).foregroundStyle(.secondary)
            }
        case .close(let left):
            Text("Hold your phone against the Mac… \(left)").foregroundStyle(.orange).monospacedDigit()
        case .far(let left):
            Text("Now take it across the room, or put it in a drawer… \(left)").foregroundStyle(.orange).monospacedDigit()
        case .done(let message):
            HStack {
                Text(message).font(.caption)
                Spacer()
                Button("Try again") { startFinder() }
            }
        }
    }

    private func startFinder() {
        found = nil
        countdown(from: 5, stage: PhoneFinder.Stage.close) {
            closeSignal = PhoneFinder.snapshot(phone.candidates)
            countdown(from: 8, stage: PhoneFinder.Stage.far) {
                let pick = PhoneFinder.pick(close: closeSignal, far: PhoneFinder.snapshot(phone.candidates))
                found = pick
                if let pick, let c = phone.candidates.first(where: { $0.id == pick }) {
                    showUnnamed = showUnnamed || !c.isNamed
                    finder = .done("Yours is \(c.label), marked with a tick. Bring the phone back and press Use.")
                } else if let pick {
                    found = pick
                    finder = .done("Found it, but it went quiet. Bring the phone back; it is marked with a tick.")
                } else {
                    finder = .done("No device dropped clearly. Hold the phone right against the Mac, then take it further away.")
                }
            }
        }
    }

    private func countdown(from seconds: Int, stage: @escaping (Int) -> PhoneFinder.Stage, then: @escaping () -> Void) {
        finder = stage(seconds)
        guard seconds > 0 else { then(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard pairing else { finder = .idle; return }
            countdown(from: seconds - 1, stage: stage, then: then)
        }
    }

    private var shown: [PhoneMonitor.Candidate] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return phone.candidates.filter { c in
            (showUnnamed || c.isNamed) && (q.isEmpty || c.label.localizedCaseInsensitiveContains(q))
        }
    }

    private var signalText: String {
        guard let rssi = controller.phoneRSSI else { return "Not heard in the last 10 s" }
        return "\(Int(rssi.rounded())) dBm, \(controller.phoneNear ? "nearby" : "too far")"
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(controller: Controller) {
        let host = NSHostingController(rootView: SettingsView(controller: controller))
        let window = NSWindow(contentViewController: host)
        window.title = "lookaway Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 480, height: 680))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }
}

// MARK: - Enrollment

private final class PreviewView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
        // Mirror like a mirror: it is only a viewfinder, never recorded.
        previewLayer.connection?.automaticallyAdjustsVideoMirroring = false
        previewLayer.connection?.isVideoMirrored = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

@MainActor
final class EnrollmentWindowController: NSWindowController, NSWindowDelegate {
    private let controller: Controller
    private let onClose: () -> Void
    private let hint = NSTextField(labelWithString: "Starting the camera…")
    private let progress = NSProgressIndicator()
    private var finished = false

    init(controller: Controller, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose

        let preview = PreviewView(session: controller.previewSession)
        preview.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .systemFont(ofSize: 15, weight: .medium)
        hint.alignment = .center
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = Double(Enroller.samplesNeeded)
        let note = NSTextField(wrappingLabelWithString: "Only a numeric face signature is stored on this Mac. No pictures are saved. Make sure you are alone in view.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [preview, hint, progress, note])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: 400),
            preview.heightAnchor.constraint(equalToConstant: 300),
            progress.widthAnchor.constraint(equalToConstant: 400),
            note.widthAnchor.constraint(equalToConstant: 400),
        ])

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Enroll my face"
        window.contentView = stack
        super.init(window: window)
        window.delegate = self

        controller.onEnrollmentProgress = { [weak self] in self?.handle($0) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        controller.beginEnrollment()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }

    private func handle(_ update: Enroller.Progress) {
        switch update {
        case .collecting(let have, _, let text):
            hint.stringValue = text
            progress.doubleValue = Double(have)
        case .finished:
            finished = true
            progress.doubleValue = progress.maxValue
            hint.stringValue = "Done. lookaway now knows your face."
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.window?.close() }
        case .failed(let message):
            hint.stringValue = message
        }
    }

    func windowWillClose(_ notification: Notification) {
        controller.onEnrollmentProgress = nil
        controller.endEnrollment()
        onClose()
    }
}
