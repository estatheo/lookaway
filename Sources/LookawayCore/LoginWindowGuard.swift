import Foundation

/// Typing the password is only safe when the login window will take it for the account
/// that owns it. The login window preselects `lastUserName`; if that is another account
/// (an admin, say), the stored password would be typed into the wrong user's field.
public enum LoginWindowGuard {
    public enum Decision: Equatable, Sendable {
        case proceed
        case skip(String)

        /// Menu text for a skipped attempt; nil when the attempt may go ahead.
        public var menuMessage: String? {
            if case .skip(let why) = self { return "Auto-unlock skipped: \(why)" }
            return nil
        }
    }

    /// Reads `lastUserName` from the login window preferences: nil when the key is
    /// absent, throws when the preferences cannot be read at all.
    public typealias PrefsReader = () throws -> String?

    public static let loginWindowPlist = "/Library/Preferences/com.apple.loginwindow.plist"

    /// Anything short of a confirmed match skips the attempt: guessing wrong types a
    /// password into the wrong account.
    public static func check(currentUser: String, readLastUser: PrefsReader) -> Decision {
        let last: String?
        do {
            last = try readLastUser()
        } catch {
            return .skip("can't read the login window's account")
        }
        guard let last, !last.isEmpty else {
            return .skip("login window has no remembered account")
        }
        guard last == currentUser else {
            return .skip("login window is on \(last)")
        }
        return .proceed
    }

    /// The real reader: the system-wide loginwindow preferences file.
    public static func readLastUserFromDisk(path: String = loginWindowPlist) throws -> String? {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return (plist as? [String: Any])?["lastUserName"] as? String
    }
}
