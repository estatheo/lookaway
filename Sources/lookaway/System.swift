import AppKit
import Foundation
import ServiceManagement
import UserNotifications
import os

let log = Logger(subsystem: "local.gizmos.lookaway", category: "app")

/// One-off user notifications. Only works from the .app bundle.
enum Notifier {
    static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else {
            log.notice("notification (not in bundle): \(title, privacy: .public)")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// Start at login via SMAppService.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Session lock / unlock and wake notifications.
final class SessionMonitor {
    var onLockChanged: ((Bool) -> Void)?
    var onWake: (() -> Void)?
    var onWillSleep: (() -> Void)?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let distributed = DistributedNotificationCenter.default()
        add(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.onLockChanged?(true) }
        add(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.onLockChanged?(false) }
        let workspace = NSWorkspace.shared.notificationCenter
        add(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.onWillSleep?() }
        add(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.onWake?() }
        add(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.onWake?() }
    }

    private func add(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in body() }
        tokens.append((center, token))
    }

    deinit {
        tokens.forEach { $0.0.removeObserver($0.1) }
    }
}
