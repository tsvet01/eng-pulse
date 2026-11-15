import Foundation
import XCTest
@testable import PilotCore

@MainActor
final class PilotPushTests: XCTestCase {
    let token = Data(repeating: 0xab, count: 32)
    let wire = String(repeating: "ab", count: 32)
    let digest = "271a413bd339c5709fdceaec41f14f11e9fbfb5042d72d331c65f32b284cd09a"
    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func fixture(_ transport: any PilotTransport, journal: MemoryCredentials = MemoryCredentials(),
                         granted: Bool = true, authorization: ((Bool) async throws -> Bool)? = nil) async throws -> (PilotPushModel, PilotSession) {
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([]),
            storage: MemoryCredentials(data: try JSONEncoder().encode(testSession())))
        let api = PilotAPIClient(configuration: .test, auth: auth, transport: transport)
        let session = try await auth.currentSession()
        return (PilotPushModel(api: api, journal: journal, receiptDirectory: root, environment: "sandbox", version: "7.1",
            authorization: authorization ?? { _ in granted }, register: {}, unregister: {}), try XCTUnwrap(session))
    }

    func testOnlyExplicitAuthorizedAdmissionRegistersAndWritesFingerprint() async throws {
        let transport = RecordingTransport([.response(204, "")])
        let (model, session) = try await fixture(transport)
        await model.enable()
        await model.received(token)
        model.admit(session, user: userB)
        await model.received(token)
        let early = await transport.requests
        XCTAssertTrue(early.isEmpty)
        XCTAssertFalse(model.canPresent(feed: "pilot-test"))

        await model.enable()
        await model.received(token)
        let sent = await transport.requests
        let request = try XCTUnwrap(sent.first)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/v1/devices")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-a")
        XCTAssertEqual(try body(request) as? [String: String],
                       ["platform":"ios", "environment":"sandbox", "token":wire, "app_version":"7.1"])
        let receipt = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: root.appendingPathComponent("confirmed.json")))
        XCTAssertEqual(receipt, ["user_id":userB.uuidString.lowercased(), "token_sha256":digest, "environment":"sandbox"])
        XCTAssertTrue(model.canPresent(feed: "pilot-test"))
        XCTAssertFalse(model.canPresent(feed: "engineering"))
    }

    func testConfirmedBannerSurvivesForegroundRefreshUntilTokenActuallyChanges() async throws {
        let transport = PausedTransport()
        let checking = expectation(description: "Rechecking system permission")
        var permission: CheckedContinuation<Bool, Never>?
        let (model, session) = try await fixture(transport) { prompt in
            if prompt { return true }
            return await withCheckedContinuation { permission = $0; checking.fulfill() }
        }
        model.admit(session, user: userA)
        await model.enable()
        let initial = Task { await model.received(token) }
        await transport.waitForRequests(1)
        await transport.respond(0, status: 204)
        await initial.value

        model.admit(session, user: userA)
        await fulfillment(of: [checking], timeout: 2)
        XCTAssertTrue(model.canPresent(feed: "pilot-test"))
        permission?.resume(returning: true)
        await model.finishCleanup()
        XCTAssertTrue(model.canPresent(feed: "pilot-test"))
        let same = Task { await model.received(token) }
        await transport.waitForRequests(2)
        XCTAssertTrue(model.canPresent(feed: "pilot-test"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("confirmed.json").path))
        await transport.respond(1, status: 204)
        await same.value

        let rotated = Task { await model.received(Data(repeating: 0xcd, count: 32)) }
        await transport.waitForRequests(3)
        XCTAssertFalse(model.canPresent(feed: "pilot-test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("confirmed.json").path))
        await transport.respond(2, status: 204)
        await transport.waitForRequests(4)
        await transport.respond(3, status: 204)
        await rotated.value
        XCTAssertTrue(model.canPresent(feed: "pilot-test"))
    }

    func testDeniedPermissionCannotBindEvenIfAppleProvidesToken() async throws {
        let transport = RecordingTransport([])
        let (model, session) = try await fixture(transport, granted: false)
        model.admit(session, user: userA)
        await model.enable()
        await model.received(token)
        let sent = await transport.requests
        XCTAssertTrue(sent.isEmpty)
        XCTAssertFalse(model.canPresent(feed: "pilot-test"))
    }

    func testRotationCleansOldBindingBeforeReplacingItAndLogoutRemovesNewToken() async throws {
        let transport = RecordingTransport(Array(repeating: .response(204, ""), count: 4))
        let (model, session) = try await fixture(transport)
        model.admit(session, user: userA)
        await model.enable()
        await model.received(token)
        await model.received(Data(repeating: 0xcd, count: 32))
        model.leave()
        await model.finishCleanup()
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "DELETE", "PUT", "DELETE"])
        XCTAssertEqual(try requests.map { try body($0)["token"] as? String }, [wire, wire, String(repeating:"cd",count:32), String(repeating:"cd",count:32)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("confirmed.json").path))
        XCTAssertFalse(model.canPresent(feed: "pilot-test"))
    }

    func testLostPutResponseAndFailedLogoutCannotTransferBindingToAnotherUser() async throws {
        let journal = MemoryCredentials()
        let transport = RecordingTransport([.failure(URLError(.timedOut)), .failure(URLError(.notConnectedToInternet))])
        let (model, session) = try await fixture(transport, journal: journal)
        model.admit(session, user: userA)
        await model.enable()
        await model.received(token)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("confirmed.json").path))
        model.leave()
        await model.finishCleanup()
        let secondTransport = RecordingTransport([])
        let (other, nextSession) = try await fixture(secondTransport, journal: journal)
        other.admit(nextSession, user: userB)
        await other.enable()
        await other.received(token)
        let wrongOwner = await secondTransport.requests
        XCTAssertTrue(wrongOwner.isEmpty)
        let recoveryTransport = RecordingTransport([.response(204, "")])
        let (restored, newSession) = try await fixture(recoveryTransport, journal: journal)
        restored.admit(newSession, user: userA)
        await restored.finishCleanup()
        let recovery = await recoveryTransport.requests
        XCTAssertEqual(recovery.map(\.httpMethod), ["DELETE"])
        XCTAssertEqual(try recovery.map { try body($0)["token"] as? String }, [wire])
        XCTAssertNil(try journal.read())
    }

    func testSameAdmittedOwnerRestoresConsentButRequiresFreshAppleToken() async throws {
        let journal = MemoryCredentials()
        let first = RecordingTransport([.response(204, "")])
        let (original, session) = try await fixture(first, journal: journal)
        original.admit(session, user: userB)
        await original.enable()
        await original.received(token)
        let transport = RecordingTransport([.response(204, "")])
        let (restarted, restoredSession) = try await fixture(transport, journal: journal)
        restarted.admit(restoredSession, user: userB)
        await restarted.finishCleanup()
        let early = await transport.requests
        XCTAssertTrue(early.isEmpty)
        XCTAssertFalse(restarted.canPresent(feed: "pilot-test"))
        await restarted.received(token)
        let renewed = await transport.requests
        XCTAssertEqual(renewed.map(\.httpMethod), ["PUT"])
        XCTAssertTrue(restarted.canPresent(feed: "pilot-test"))
    }

    func testOfflineCachedAdmissionCannotRegisterUntilMembershipIsVerifiedAndLogoutCleansWhileAuthenticated() async throws {
        let credentials = MemoryCredentials(data: try JSONEncoder().encode(testSession()))
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([.response(200, "")]), storage: credentials)
        let cached = Data("{\"identity\":\"\(userA)\",\"feed\":\"engineering\",\"user\":{\"id\":\"\(userB)\",\"email\":\"pilot@example.com\",\"is_admin\":false}}".utf8)
        let transport = RecordingTransport([.failure(URLError(.notConnectedToInternet)),
            .ok("{\"id\":\"\(userB)\",\"email\":\"pilot@example.com\",\"is_admin\":false}"),
            .ok(verifiedEngineeringFeed), .response(204,""), .response(204,"")])
        let api = PilotAPIClient(configuration: .test, auth: auth, transport: transport)
        let push = PilotPushModel(api: api, journal: MemoryCredentials(), receiptDirectory: root, environment: "sandbox",
            version: "1", authorization: { _ in true }, register: {}, unregister: {})
        let account = PilotAccountModel(auth: auth, api: api, admissionStorage: MemoryCredentials(data: cached), push: push)
        await account.restore()
        guard case .admitted = account.phase else { return XCTFail("Offline reader should remain available") }
        await push.enable()
        await push.received(token)
        XCTAssertEqual(push.status, .unavailable)
        await account.restore()
        await push.enable()
        await push.received(token)
        await account.signOut()
        let requests = await transport.requests.filter { $0.url?.path == "/v1/devices" }
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "DELETE"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer access-a", "Bearer access-a"])
        XCTAssertNil(try credentials.read())
    }

    func testCleanupFailureForOldSessionDoesNotRevokeNewSession() async throws {
        let transport = PausedTransport()
        let (model, first) = try await fixture(transport)
        model.admit(first, user: userA)
        await model.enable()
        let upload = Task { await model.received(token) }
        await transport.waitForRequests(1)
        await transport.respond(0, status: 204)
        await upload.value
        var revoked = [UUID]()
        model.onAccessFailure = { _, session in revoked.append(session.id) }
        let replacement = PilotSession(id: UUID(), identity: PilotIdentity(id: userB, email: "next@example.com"))
        model.admit(replacement, user: userB)
        await transport.waitForRequests(2)
        await transport.respond(1, status: 403)
        await model.finishCleanup()
        XCTAssertTrue(revoked.isEmpty)
        XCTAssertFalse(model.canPresent(feed: "pilot-test"))
    }

    func testRevokedSystemPermissionDisablesSavedBindingWithoutPromptingAgain() async throws {
        let journal = MemoryCredentials()
        let first = RecordingTransport([.response(204, "")])
        let (original, session) = try await fixture(first, journal: journal)
        original.admit(session, user: userB)
        await original.enable()
        await original.received(token)
        let transport = RecordingTransport([.response(204, "")])
        let (restored, newSession) = try await fixture(transport, journal: journal, granted: false)
        restored.admit(newSession, user: userB)
        await restored.finishCleanup()
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["DELETE"])
        XCTAssertEqual(restored.status, .denied)
        XCTAssertNil(try journal.read())
        XCTAssertFalse(restored.canPresent(feed: "pilot-test"))
    }

    func testLogoutWaitsForInFlightPutBeforeDeleteAndSuppressesLateReceipt() async throws {
        let transport = PausedTransport()
        let (model, session) = try await fixture(transport)
        model.admit(session, user: userA)
        await model.enable()
        let uploading = Task { await model.received(token) }
        await transport.waitForRequests(1)
        model.leave()
        XCTAssertFalse(model.canPresent(feed: "pilot-test"))
        await transport.respond(0, status: 204)
        await transport.waitForRequests(2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("confirmed.json").path))
        await transport.respond(1, status: 204)
        await uploading.value
        await model.finishCleanup()
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "DELETE"])
    }

    func testEnvironmentComesFromProvisioningEntitlementAndDoesNotGuessOnMalformedProfiles() throws {
        for (entitlement, expected) in [("development","sandbox"), ("production","production")] {
            let plist = try PropertyListSerialization.data(fromPropertyList: ["Entitlements":["aps-environment":entitlement]],
                format: .xml, options: 0)
            XCTAssertEqual(PilotPushEnvironment.resolve(profile: Data([0xff]) + plist + Data([0xfe]), storeReceipt: false), expected)
        }
        XCTAssertNil(PilotPushEnvironment.resolve(profile: Data("not a profile".utf8), storeReceipt: true))
        XCTAssertNil(PilotPushEnvironment.resolve(profile: nil, storeReceipt: false))
        XCTAssertEqual(PilotPushEnvironment.resolve(profile: nil, storeReceipt: true), "production")
    }
}
