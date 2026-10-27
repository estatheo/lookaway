import Foundation
import OpenDirectory
import Security

/// The login password, kept only for the opt-in auto-unlock. Lives in the login
/// Keychain as a device-only item; deleting it is how auto-unlock is switched off.
protocol CredentialStore {
    var exists: Bool { get }
    func save(_ password: String) throws
    /// Raw UTF-8 bytes, so the caller can wipe them after use. nil if absent or unreadable.
    func read() -> Data?
    func delete()
}

struct KeychainCredentialStore: CredentialStore {
    enum Failure: Error, LocalizedError {
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let text = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Keychain: \(text)"
            }
        }
    }

    let service: String
    let account: String

    init(service: String = "local.gizmos.lookaway.login-password", account: String = NSUserName()) {
        self.service = service
        self.account = account
    }

    private func query(_ extra: [String: Any] = [:]) -> CFDictionary {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        q.merge(extra) { $1 }
        return q as CFDictionary
    }

    var exists: Bool {
        SecItemCopyMatching(query([kSecMatchLimit as String: kSecMatchLimitOne]), nil) == errSecSuccess
    }

    func save(_ password: String) throws {
        SecItemDelete(query())
        let status = SecItemAdd(query([
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecAttrLabel as String: "lookaway auto-unlock",
        ]), nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    func read() -> Data? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]), &out)
        return status == errSecSuccess ? out as? Data : nil
    }

    func delete() {
        SecItemDelete(query())
    }
}

/// Checks a password against the local account, so a typo is caught when auto-unlock
/// is enabled and not later at the login window (where it would count as a failed login).
enum PasswordVerifier {
    static func verify(_ password: String, user: String = NSUserName()) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: user, attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            return false
        }
    }
}
