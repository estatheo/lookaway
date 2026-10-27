import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// lookaway's own lock screen: an opaque window over every display, kiosk presentation
/// options (no Dock, menu bar, Cmd+Tab or Force Quit), and an event tap that swallows
/// every keyboard and mouse event. Nothing underneath is touched, so it all keeps running.
///
/// A key press or click is reported through `onInput` and the controller turns it into a
/// real lock; the cover never decides anything itself.
@MainActor
final class ScreenCover {
    /// A key press or click; `true` when it was Ctrl+Cmd+Q, the way out to a real lock.
    var onInput: ((_ lockShortcut: Bool) -> Void)?
    private(set) var isUp = false

    private let model: CoverModel
    /// Plays on any input while the cover is up; see `InputVideo`.
    private let video = InputVideo()
    private var windows: [NSWindow] = []
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var savedOptions: NSApplication.PresentationOptions = []
    private var screensObserver: NSObjectProtocol?
    /// Full: opaque windows and kiosk options. Otherwise only the input is blocked and the
    /// screen stays visible.
    private var fullScreen = true

    init(model: CoverModel) {
        self.model = model
    }

    /// Blocking input needs Accessibility; without it the cover would only be a picture.
    static var canBlockInput: Bool { AXIsProcessTrusted() }

    /// Puts the cover up. Returns false, showing nothing, if input cannot be blocked.
    func show(fullScreen: Bool) -> Bool {
        guard !isUp else { return true }
        guard installTap() else { return false }
        isUp = true
        self.fullScreen = fullScreen
        buildWindows()
        screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isUp == true { self?.buildWindows() } }
        }
        // Input-only keeps the menu bar, so the lookaway icon shows that input is blocked.
        guard fullScreen else { return true }
        savedOptions = NSApp.presentationOptions
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [
            .hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
            .disableSessionTermination, .disableHideApplication, .disableAppleMenu,
        ]
        NSCursor.hide()
        return true
    }

    func hide() {
        guard isUp else { return }
        isUp = false
        removeTap()
        video.stop()
        if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
        screensObserver = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        if fullScreen {
            NSApp.presentationOptions = savedOptions
            NSCursor.unhide()
        }
    }

    // MARK: - Windows

    private func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = fullScreen ? NSScreen.screens.map(coverWindow) : []
        windows.first?.makeKey()
    }

    private func coverWindow(on screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        // The shielding level sits above the menu bar, notifications and full-screen apps.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CoverView(model: model))
        window.orderFrontRegardless()
        return window
    }

    // MARK: - Event tap

    private static let blockedTypes: [CGEventType] = [
        .keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
    ]
    /// NX_SYSDEFINED (media and brightness keys) and gestures have no CGEventType case.
    private static let extraBlockedTypes: [UInt32] = [14, 29]

    private static let pressTypes: Set<CGEventType> = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]

    private func installTap() -> Bool {
        guard Self.canBlockInput else { return false }
        var mask: CGEventMask = 0
        for type in Self.blockedTypes { mask |= CGEventMask(1) << CGEventMask(type.rawValue) }
        for raw in Self.extraBlockedTypes { mask |= CGEventMask(1) << CGEventMask(raw) }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let cover = Unmanaged<ScreenCover>.fromOpaque(refcon).takeUnretainedValue()
            // The tap runs on the main run loop, so this is the main thread.
            return MainActor.assumeIsolated { cover.handleTapped(type: type, event: event) }
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
        return true
    }

    private func handleTapped(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches a slow tap off; switch it straight back on while the cover is up.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isUp, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isUp else { return Unmanaged.passUnretained(event) }
        // Any touch at all, a mouse move included, starts the video.
        if !video.isPlaying { DispatchQueue.main.async { [weak self] in if self?.isUp == true { self?.video.play() } } }
        if Self.pressTypes.contains(type) {
            let q: Int64 = 12
            let lockShortcut = type == .keyDown
                && event.getIntegerValueField(.keyboardEventKeycode) == q
                && event.flags.contains([.maskControl, .maskCommand])
            DispatchQueue.main.async { [weak self] in self?.onInput?(lockShortcut) }
        }
        return nil
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
    }
}

/// What the cover says. The controller keeps it current.
@MainActor
final class CoverModel: ObservableObject {
    @Published var phoneLine: String?
}

private struct CoverView: View {
    @ObservedObject var model: CoverModel

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 18) {
                Image(systemName: "eye")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Waiting for you")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)
                if let phone = model.phoneLine {
                    Text(phone).font(.system(size: 16)).foregroundStyle(.white.opacity(0.6))
                }
                Text("Look at the screen to come back. Pressing a key or clicking locks the Mac instead.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 12)
            }
            .multilineTextAlignment(.center)
            .padding(40)
        }
    }
}
