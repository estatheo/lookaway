import ApplicationServices
import CoreGraphics
import Foundation

protocol ScreenLocker {
    /// Returns false if no mechanism worked.
    func lock() -> Bool
}

/// Locks the session the way Ctrl+Cmd+Q does. Never logs out and never sleeps the
/// system, so tmux sessions and agents keep running.
struct SystemScreenLocker: ScreenLocker {
    private typealias LockFunction = @convention(c) () -> Int32

    private static let loginFramework = "/System/Library/PrivateFrameworks/login.framework/login"

    /// Resolved lazily; nil when the private symbol is missing on this macOS.
    static func resolveLockFunction() -> Bool {
        lockFunction != nil
    }

    private static let lockFunction: LockFunction? = {
        guard let handle = dlopen(loginFramework, RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate")
        else { return nil }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    func lock() -> Bool {
        if let fn = Self.lockFunction {
            _ = fn()
            return true
        }
        return postLockShortcut()
    }

    /// Fallback: synthesise Ctrl+Cmd+Q. Needs Accessibility (post-event) permission.
    private func postLockShortcut() -> Bool {
        guard CGPreflightPostEventAccess() else {
            _ = CGRequestPostEventAccess()
            return false
        }
        let qKey: CGKeyCode = 12
        let flags: CGEventFlags = [.maskControl, .maskCommand]
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: qKey, keyDown: down) else { return false }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}

/// Reads whether the session is locked right now (used at launch and after wake).
func screenIsLockedNow() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
}
