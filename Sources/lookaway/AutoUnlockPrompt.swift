import AppKit

/// The confirmation shown before auto-unlock is switched on: states the risk and asks
/// for the login password, which must verify before it is stored.
@MainActor
enum AutoUnlockPrompt {
    static let risk = """
    A Mac camera has no depth sensing, so a photo or a video of you can fool it. \
    With this on, after lookaway has locked the screen and your face comes back, lookaway \
    types your login password for you. Touch ID and Apple Watch unlock remain the secure options.

    Your password is kept in the login Keychain on this Mac only and is deleted when you \
    turn this off. Typing it needs Accessibility permission.
    """

    /// The verified login password, or nil if the user cancelled.
    static func askForPassword() -> String? {
        var problem: String?
        while true {
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = "Login password"

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Turn on less secure auto-unlock?"
            alert.informativeText = (problem.map { $0 + "\n\n" } ?? "") + risk
            alert.accessoryView = field
            alert.addButton(withTitle: "Turn On")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field

            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }

            let password = field.stringValue
            if !password.isEmpty, PasswordVerifier.verify(password) { return password }
            problem = "That password was not accepted for this account. Nothing was stored."
        }
    }

    static func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not turn on auto-unlock"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
