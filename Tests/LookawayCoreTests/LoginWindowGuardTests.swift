import Foundation
import Testing
@testable import LookawayCore

struct LoginWindowGuardTests {
    private struct Unreadable: Error {}

    @Test func matchingAccountProceeds() {
        let decision = LoginWindowGuard.check(currentUser: "alex") { "alex" }
        #expect(decision == .proceed)
        #expect(decision.menuMessage == nil)
    }

    @Test func otherAccountSkipsAndNamesIt() {
        let decision = LoginWindowGuard.check(currentUser: "alex") { "alexadmin" }
        #expect(decision == .skip("login window is on alexadmin"))
        #expect(decision.menuMessage == "Auto-unlock skipped: login window is on alexadmin")
    }

    @Test func accountNamesAreCaseSensitive() {
        #expect(LoginWindowGuard.check(currentUser: "alex") { "Alex" } != .proceed)
    }

    @Test func missingKeySkips() {
        #expect(LoginWindowGuard.check(currentUser: "alex") { nil } != .proceed)
    }

    @Test func emptyNameSkips() {
        #expect(LoginWindowGuard.check(currentUser: "alex") { "" } != .proceed)
    }

    @Test func unreadablePrefsSkip() {
        #expect(LoginWindowGuard.check(currentUser: "alex") { throw Unreadable() } != .proceed)
    }

    // The real reader, against files in a temp directory.

    private func tempFile(_ contents: [String: Any]?) throws -> String {
        let path = NSTemporaryDirectory() + "loginwindow-\(UUID().uuidString).plist"
        if let contents {
            try PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0)
                .write(to: URL(fileURLWithPath: path))
        }
        return path
    }

    @Test func diskReaderReturnsLastUserName() throws {
        let path = try tempFile(["lastUserName": "alex"])
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try LoginWindowGuard.readLastUserFromDisk(path: path) == "alex")
    }

    @Test func diskReaderReturnsNilWithoutTheKey() throws {
        let path = try tempFile(["other": 1])
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try LoginWindowGuard.readLastUserFromDisk(path: path) == nil)
    }

    @Test func diskReaderThrowsOnMissingFile() throws {
        let path = try tempFile(nil)
        #expect(throws: (any Error).self) { try LoginWindowGuard.readLastUserFromDisk(path: path) }
    }
}
