import XCTest
import Security
@testable import EngPulse

final class PilotKeychainTests: XCTestCase {
    @MainActor
    func testEveryAppWindowSharesOneAccountCoordinator() throws {
        let firstWindow = PilotEntryView()
        let secondWindow = PilotEntryView()
        let first = try XCTUnwrap(firstWindow.model)
        let second = try XCTUnwrap(secondWindow.model)
        XCTAssertTrue(first === second, "Sign-out must invalidate every app window")
    }

    func testBuildIncludesPilotConfigurationSettings() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "PilotAuthEnabled") as? String, "YES")
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String)
        XCTAssertFalse(PilotBuild.allowsLegacyServices)
    }

    func testSessionIsUpdatedInDeviceOnlyKeychainAndRemovedOnLogout() throws {
        let service = "org.tsvetkov.eng-pulse.tests.\(UUID().uuidString)"
        let store = PilotKeychain(service: service)
        defer { try? store.write(nil) }
        XCTAssertNil(try store.read())
        try store.write(Data("test-session-one".utf8))
        XCTAssertEqual(try store.read(), Data("test-session-one".utf8))
        try store.write(Data("test-session-two".utf8))
        XCTAssertEqual(try store.read(), Data("test-session-two".utf8))

        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)

        try store.write(nil)
        XCTAssertNil(try store.read())
        try store.write(nil)
    }
}
