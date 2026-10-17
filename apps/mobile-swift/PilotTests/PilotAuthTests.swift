import XCTest
@testable import PilotCore

final class PilotAuthTests: XCTestCase {
    func testEmailCodeRequestAndVerificationUseOTPNotPassword() async throws {
        let transport = RecordingTransport([.ok("{}"), .ok(sessionJSON())])
        let store = MemoryCredentials()
        let auth = PilotAuthClient(configuration: .test, transport: transport, storage: store)
        try await auth.sendCode(email: "  pilot@example.com  ")
        let identity = try await auth.verifyCode(email: "pilot@example.com", code: "123456")
        XCTAssertEqual(identity.id, userA)
        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.path, "/auth/v1/otp")
        XCTAssertEqual(try body(requests[0])["email"] as? String, "pilot@example.com")
        XCTAssertEqual(try body(requests[0])["create_user"] as? Bool, true)
        XCTAssertEqual(requests[1].url?.path, "/auth/v1/verify")
        XCTAssertEqual(try body(requests[1])["type"] as? String, "email")
        XCTAssertEqual(try body(requests[1])["token"] as? String, "123456")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "apikey"), "public-test-key")
        XCTAssertNotNil(try store.read())
    }

    func testAppleExchangeIncludesOriginalNonce() async throws {
        let transport = RecordingTransport([.ok(sessionJSON())])
        let auth = PilotAuthClient(configuration: .test, transport: transport, storage: MemoryCredentials())
        _ = try await auth.signInWithApple(idToken: "apple-token", nonce: "original-nonce")
        let first = await transport.firstRequest()
        let request = try XCTUnwrap(first)
        XCTAssertEqual(request.url?.query, "grant_type=id_token")
        XCTAssertEqual(try body(request)["provider"] as? String, "apple")
        XCTAssertEqual(try body(request)["nonce"] as? String, "original-nonce")
        XCTAssertEqual(try body(request)["id_token"] as? String, "apple-token")
    }

    func testExpiredSessionRefreshesAndPersistsRotatedToken() async throws {
        let store = MemoryCredentials(data: try JSONEncoder().encode(testSession(expiresAt: 1)))
        let transport = RecordingTransport([.ok(sessionJSON(access: "new-access", refresh: "new-refresh"))])
        let auth = PilotAuthClient(configuration: .test, transport: transport, storage: store)
        let token = try await auth.accessToken(for: userA)
        XCTAssertEqual(token, "new-access")
        let persisted = try JSONDecoder().decode(PilotCredentials.self, from: XCTUnwrap(store.read()))
        XCTAssertEqual(persisted.refreshToken, "new-refresh")
        let first = await transport.firstRequest()
        let request = try XCTUnwrap(first)
        XCTAssertEqual(request.url?.query, "grant_type=refresh_token")
        XCTAssertEqual(try body(request)["refresh_token"] as? String, "refresh-a")
    }

    func testRejectsTokenRequestForAnotherAccount() async throws {
        let store = MemoryCredentials(data: try JSONEncoder().encode(testSession()))
        let transport = RecordingTransport([])
        let auth = PilotAuthClient(configuration: .test, transport: transport, storage: store)
        do { _ = try await auth.accessToken(for: userB); XCTFail("Must not expose account A's token") }
        catch { XCTAssertEqual(error as? PilotError, .sessionChanged) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testOfflineLogoutClearsLocalCredentialsBeforeNetworkCompletes() async throws {
        let store = MemoryCredentials(data: try JSONEncoder().encode(testSession()))
        let transport = RecordingTransport([.failure(URLError(.notConnectedToInternet))])
        let auth = PilotAuthClient(configuration: .test, transport: transport, storage: store)
        try await auth.signOut()
        XCTAssertNil(try store.read())
        let identity = try await auth.currentIdentity()
        XCTAssertNil(identity)
    }

    func testRejectedRefreshClearsSessionButNetworkFailurePreservesIt() async throws {
        for status in [400, 401] {
            let store = MemoryCredentials(data: try JSONEncoder().encode(testSession(expiresAt: 1)))
            let auth = PilotAuthClient(configuration: .test,
                transport: RecordingTransport([.response(status, "{\"error_code\":\"refresh_token_not_found\"}")]), storage: store)
            do { _ = try await auth.accessToken(for: userA); XCTFail("Expired refresh must fail") }
            catch { XCTAssertEqual(error as? PilotError, .signInRequired) }
            XCTAssertNil(try store.read())
        }
        let store = MemoryCredentials(data: try JSONEncoder().encode(testSession(expiresAt: 1)))
        let auth = PilotAuthClient(configuration: .test,
            transport: RecordingTransport([.failure(URLError(.notConnectedToInternet))]), storage: store)
        do { _ = try await auth.accessToken(for: userA); XCTFail("Offline refresh must fail") } catch {}
        XCTAssertNotNil(try store.read())
    }

    func testCorruptSavedSessionCanBeDiscardedAndReplaced() async throws {
        let store = MemoryCredentials(data: Data("bad saved session".utf8))
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([.ok(sessionJSON())]), storage: store)
        let identity = try await auth.currentIdentity()
        XCTAssertNil(identity)
        XCTAssertNil(try store.read())
        let signedIn = try await auth.verifyCode(email: "pilot@example.com", code: "123456")
        XCTAssertEqual(signedIn.id, userA)
    }

    func testServerErrorDoesNotLeakResponseDetails() async throws {
        let transport = RecordingTransport([.response(500, "private credentials and server internals")])
        let auth = PilotAuthClient(configuration: .test, transport: transport, storage: MemoryCredentials())
        do { try await auth.sendCode(email: "pilot@example.com"); XCTFail("Server failure must surface") }
        catch { XCTAssertFalse(error.localizedDescription.contains("private credentials")) }
    }
    func testDelayedLoginCannotRestoreSessionAfterSignOut() async throws {
        let transport = PausedTransport()
        let store = MemoryCredentials()
        let auth = PilotAuthClient(configuration: .test, transport: transport, storage: store)
        let login = Task { try await auth.verifyCode(email: "pilot@example.com", code: "123456") }
        await transport.waitForRequests(1)
        try await auth.signOut()
        await transport.respond(0, body: sessionJSON())
        do { _ = try await login.value; XCTFail("Late login must not restore a signed-out session") }
        catch { XCTAssertEqual(error as? PilotError, .sessionChanged) }
        XCTAssertNil(try store.read())
    }

    func testConcurrentExpiredRequestsShareOneRefresh() async throws {
        let transport = PausedTransport()
        let store = MemoryCredentials(data: try JSONEncoder().encode(testSession(expiresAt: 1)))
        let auth = PilotAuthClient(configuration: .test, transport: transport, storage: store)
        let first = Task { try await auth.accessToken(for: userA) }
        await transport.waitForRequests(1)
        let second = Task { try await auth.accessToken(for: userA) }
        await transport.respond(0, body: sessionJSON(access: "renewed"))
        let firstToken = try await first.value
        let secondToken = try await second.value
        XCTAssertEqual(firstToken, "renewed")
        XCTAssertEqual(secondToken, "renewed")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testDelayedRefreshCannotOverwriteNewAccount() async throws {
        let transport = PausedTransport()
        let store = MemoryCredentials(data: try JSONEncoder().encode(testSession(expiresAt: 1)))
        let auth = PilotAuthClient(configuration: .test, transport: transport, storage: store)
        let refresh = Task { try await auth.accessToken(for: userA) }
        await transport.waitForRequests(1)
        let login = Task { try await auth.verifyCode(email: "b@example.com", code: "654321") }
        await transport.waitForRequests(2)
        await transport.respond(1, body: sessionJSON(access: "access-b", refresh: "refresh-b", user: userB))
        _ = try await login.value
        await transport.respond(0, body: sessionJSON(access: "old-account-refresh"))
        do { _ = try await refresh.value; XCTFail("Old refresh must not overwrite new account") }
        catch { XCTAssertEqual(error as? PilotError, .sessionChanged) }
        let identity = try await auth.currentIdentity()
        XCTAssertEqual(identity?.id, userB)
        let token = try await auth.accessToken(for: userB)
        XCTAssertEqual(token, "access-b")
    }

    func testEmptySavedCredentialsAreDiscarded() async throws {
        let invalid = PilotCredentials(accessToken: "", refreshToken: "", expiresAt: 4102444800,
            identity: PilotIdentity(id: userA, email: "pilot@example.com"))
        let store = MemoryCredentials(data: try JSONEncoder().encode(invalid))
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([]), storage: store)
        let session = try await auth.currentSession()
        XCTAssertNil(session)
        XCTAssertNil(try store.read())
    }

    func testExpiredExchangeIsNotPersistedAsSignedIn() async throws {
        let response = sessionJSON().replacingOccurrences(of: "4102444800", with: "1")
        let store = MemoryCredentials()
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([.ok(response)]), storage: store)
        do { _ = try await auth.verifyCode(email: "pilot@example.com", code: "123456"); XCTFail("Expired exchange must fail") }
        catch { XCTAssertEqual(error as? PilotError, .invalidResponse) }
        XCTAssertNil(try store.read())
    }

}
