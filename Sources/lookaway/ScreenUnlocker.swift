import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

enum UnlockFailure: Error, LocalizedError {
    case noPassword
    case noAccessibility

    var errorDescription: String? {
        switch self {
        case .noPassword: return "No login password stored"
        case .noAccessibility: return "Accessibility permission is needed to type the password"
        }
    }
}

protocol ScreenUnlocker {
    /// Whether typing at the login window is permitted right now.
    var canType: Bool { get }
    /// Wakes the display and types the stored password into the login window. It does
    /// not know whether the password was right: the session reports the unlock itself.
    /// `completion` runs on the main queue.
    func unlock(completion: @escaping (Result<Void, UnlockFailure>) -> Void)
}

/// Wakes the display and types the login password with synthetic key events, the
/// approach used by tools such as BLEUnlock. Needs Accessibility (post-event) permission.
/// The password is read from the Keychain per attempt, held as raw UTF-16 units, and
/// zeroed afterwards; it is never logged.
final class KeystrokeUnlocker: ScreenUnlocker {
    private let credentials: CredentialStore
    private let queue = DispatchQueue(label: "lookaway.unlock")

    init(credentials: CredentialStore) {
        self.credentials = credentials
    }

    var canType: Bool { CGPreflightPostEventAccess() }

    func unlock(completion: @escaping (Result<Void, UnlockFailure>) -> Void) {
        guard canType else {
            completion(.failure(.noAccessibility))
            return
        }
        queue.async { [credentials] in
            guard var data = credentials.read(), !data.isEmpty else {
                DispatchQueue.main.async { completion(.failure(.noPassword)) }
                return
            }
            var units = Array(String(decoding: data, as: UTF8.self).utf16)
            defer {
                for i in units.indices { units[i] = 0 }
                data.resetBytes(in: data.startIndex..<data.endIndex)
            }
            Self.wakeDisplay()
            Thread.sleep(forTimeInterval: 0.8)
            Self.tap(keyCode: 56)              // Shift: shows the password field, dismisses a screen saver
            Thread.sleep(forTimeInterval: 0.6)
            for unit in units {
                Self.type(unit)
                Thread.sleep(forTimeInterval: 0.012)
            }
            Thread.sleep(forTimeInterval: 0.15)
            Self.tap(keyCode: 36)              // Return
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    // MARK: - Events

    private static let source = CGEventSource(stateID: .hidSystemState)

    private static func wakeDisplay() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("lookaway auto-unlock" as CFString, kIOPMUserActiveLocal, &id)
    }

    private static func tap(keyCode: CGKeyCode) {
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    private static func type(_ unit: UInt16) {
        var u = unit
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            event.post(tap: .cghidEventTap)
        }
    }
}
