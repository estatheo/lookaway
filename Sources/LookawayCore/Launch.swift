import Foundation

/// Which window to bring up when the app is launched or opened again. lookaway lives in
/// the menu bar, which can be hidden (notch, crowded bar), so opening the app must always
/// show something.
public enum LaunchWindow: Equatable, Sendable {
    case enrollment
    case settings

    /// Not enrolled means the app does nothing yet, so the only useful window is enrollment.
    public static func forOpening(hasEnrollment: Bool) -> LaunchWindow {
        hasEnrollment ? .settings : .enrollment
    }

    /// First launch opens enrollment (which asks for the camera); a normal launch, for
    /// example at login, stays quietly in the menu bar.
    public static func atLaunch(hasEnrollment: Bool) -> LaunchWindow? {
        hasEnrollment ? nil : .enrollment
    }
}
