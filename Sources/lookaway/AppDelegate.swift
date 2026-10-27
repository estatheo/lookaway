import AppKit
import LookawayCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = Controller()
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem?
    private var settingsWindow: SettingsWindowController?
    private var enrollmentWindow: EnrollmentWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy would fight over the camera and lock twice. Hand over to the
        // running one, which shows its window, instead of quitting without a trace.
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(
                Self.showWindowNotification, object: nil, userInfo: nil, deliverImmediately: true
            )
            other.activate()
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showWindow), name: Self.showWindowNotification, object: nil
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.onChange = { [weak self] in self?.refresh() }
        controller.start()
        refresh()

        // First run: nothing to see in the menu bar yet, so ask for enrollment (and with
        // it the camera permission) right away.
        if LaunchWindow.atLaunch(hasEnrollment: controller.hasEnrollment) != nil { enroll() }
    }

    /// Opening lookaway.app again (Finder, Spotlight, Dock) while it runs.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    private static let showWindowNotification = Notification.Name("local.gizmos.lookaway.showWindow")

    @objc private func showWindow() {
        switch LaunchWindow.forOpening(hasEnrollment: controller.hasEnrollment) {
        case .enrollment: enroll()
        case .settings: openSettings()
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusLine = status
        if controller.autoUnlockEnabled {
            let unlock = NSMenuItem(
                title: controller.autoUnlockPaused ? "Auto-unlock paused until you unlock" : "Auto-unlock on (less secure)",
                action: nil, keyEquivalent: ""
            )
            unlock.isEnabled = false
            menu.addItem(unlock)
            if let skipped = controller.autoUnlockSkipped {
                let note = NSMenuItem(title: skipped, action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(note)
            }
        }
        menu.addItem(.separator())

        let toggle = item("Lock when I look away", #selector(toggleEnabled))
        toggle.state = controller.machine.enabled ? .on : .off
        menu.addItem(toggle)

        if case .paused = controller.status {
            menu.addItem(item("Resume", #selector(resumeWatching)))
        } else {
            let pause = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (title, minutes) in [("For 15 minutes", 15.0), ("For 1 hour", 60.0)] {
                let i = item(title, #selector(pauseFor(_:)))
                i.representedObject = minutes
                sub.addItem(i)
            }
            sub.addItem(item("Until resumed", #selector(pauseUntilResumed)))
            pause.submenu = sub
            menu.addItem(pause)
        }
        menu.addItem(.separator())

        menu.addItem(item(controller.hasEnrollment ? "Re-enroll my face…" : "Enroll my face…", #selector(enroll)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        if controller.cameraDenied {
            menu.addItem(item("Open Camera Privacy Settings…", #selector(openCameraPrivacy)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit lookaway", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private var statusText: String {
        let status = controller.status
        var text = status.text(at: Date())
        if case .covered = status, controller.settings.awayAction == .blockInput { text = "Keyboard and mouse blocked" }
        if case .cameraUnavailable(let why) = status, why != "No camera frames" { text += " (\(why))" }
        return text
    }

    /// Updates the icon, and the status line if the menu is open.
    private func refresh() {
        let status = controller.status
        let symbol: String
        switch status {
        case .off: symbol = "eye.slash"
        case .needsEnrollment: symbol = "person.crop.circle.badge.questionmark"
        case .enrolling: symbol = "faceid"
        case .paused: symbol = "pause.circle"
        case .locked, .locking: symbol = "lock"
        case .covered: symbol = "hand.raised.fill"
        case .cameraUnavailable: symbol = "exclamationmark.triangle"
        case .watching, .present: symbol = "eye"
        case .away: symbol = "hourglass"
        }
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "lookaway")
            button.image?.isTemplate = true
            button.toolTip = "lookaway: \(statusText)"
        }
        statusLine?.title = statusText
    }

    // MARK: - Actions

    @objc private func toggleEnabled() { controller.setEnabled(!controller.machine.enabled) }
    @objc private func resumeWatching() { controller.resume() }
    @objc private func pauseUntilResumed() { controller.pause(minutes: nil) }
    @objc private func pauseFor(_ sender: NSMenuItem) {
        controller.pause(minutes: sender.representedObject as? Double)
    }

    @objc private func enroll() {
        if enrollmentWindow == nil {
            enrollmentWindow = EnrollmentWindowController(controller: controller) { [weak self] in
                self?.enrollmentWindow = nil
            }
        }
        // Already on screen (a re-open while enrolling): bring it forward, do not restart it.
        if enrollmentWindow?.window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            enrollmentWindow?.window?.makeKeyAndOrderFront(nil)
        } else {
            enrollmentWindow?.present()
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(controller: controller) }
        settingsWindow?.present()
    }

    @objc private func openCameraPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
