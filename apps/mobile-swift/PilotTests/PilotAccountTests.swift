import XCTest
@testable import PilotCore

@MainActor
final class PilotAccountTests: XCTestCase {
    func testExistingSessionNeedsInviteAndCanRetryAnInvalidCode() async throws {
        let store = MemoryCredentials(data: try JSONEncoder().encode(testSession()))
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([]), storage: store)
        let api = PilotAPIClient(configuration: .test, auth: auth, transport: RecordingTransport([
            .response(403, "{\"error\":\"invite_required\"}"),
            .response(422, "{\"error\":\"bad_request\"}"),
            .response(201, "{\"id\":\"\(userA)\",\"email\":\"pilot@example.com\",\"is_admin\":false}")
        ]))
        let model = PilotAccountModel(auth: auth, api: api)
        await model.restore()
        guard case .needsInvite = model.phase else { return XCTFail("Show invite entry") }
        await model.acceptInvite("bad")
        guard case .needsInvite = model.phase else { return XCTFail("Keep invite entry for retry") }
        XCTAssertEqual(model.errorMessage, PilotError.invalidInvite.localizedDescription)
        await model.acceptInvite("good")
        guard case .admitted(_, let user) = model.phase else { return XCTFail("Valid invite admits account") }
        XCTAssertEqual(user.email, "pilot@example.com")
        XCTAssertNil(model.errorMessage)
    }

    func testAPIOutageAfterSignInDoesNotLookLikeSuccessfulAdmission() async throws {
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([.ok(sessionJSON())]), storage: MemoryCredentials())
        let api = PilotAPIClient(configuration: .test, auth: auth, transport: RecordingTransport([.response(503, "{}")]))
        let model = PilotAccountModel(auth: auth, api: api)
        await model.verifyCode(email: "pilot@example.com", code: "123456")
        guard case .waiting = model.phase else { return XCTFail("Keep authenticated session but do not admit") }
    }

    func testDisabledAccountCannotEnterAnotherInvite() async throws {
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([]),
            storage: MemoryCredentials(data: try JSONEncoder().encode(testSession())))
        let api = PilotAPIClient(configuration: .test, auth: auth, transport: RecordingTransport([.response(403, "{\"error\":\"forbidden\"}")]))
        let model = PilotAccountModel(auth: auth, api: api)
        await model.restore()
        guard case .blocked = model.phase else { return XCTFail("Disabled account must not receive invitation prompt") }
    }

    func testLogoutDuringAdmissionDiscardsLateReplyAndOldAccount() async throws {
        let store = MemoryCredentials(data: try JSONEncoder().encode(testSession()))
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([.failure(URLError(.notConnectedToInternet))]), storage: store)
        let transport = PausedTransport()
        let api = PilotAPIClient(configuration: .test, auth: auth, transport: transport)
        let model = PilotAccountModel(auth: auth, api: api)
        let restore = Task { await model.restore() }
        await transport.waitForRequests(1)
        await model.signOut()
        await transport.respond(0, body: "{\"id\":\"\(userA)\",\"email\":\"pilot@example.com\",\"is_admin\":true}")
        await restore.value
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(try store.read())
        XCTAssertNil(model.codeSentTo)
        XCTAssertFalse(model.isBusy)
    }
    func testAppleCallbackFromBeforeLogoutCannotSignBackIn() async throws {
        let transport = RecordingTransport([.ok(sessionJSON())])
        let store = MemoryCredentials()
        let auth = PilotAuthClient(configuration: .test, transport: transport, storage: store)
        let model = PilotAccountModel(auth: auth, api: PilotAPIClient(configuration: .test, auth: auth, transport: RecordingTransport([])))
        let attempt = try XCTUnwrap(model.beginAppleSignIn())
        XCTAssertTrue(model.isBusy)
        await model.signOut()
        await model.completeAppleSignIn(idToken: "late-apple-token", nonce: "nonce", attempt: attempt)
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(try store.read())
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testApplePromptSerializesAllWindowsUntilCancelled() async throws {
        let transport = RecordingTransport([.ok("{}")])
        let auth = PilotAuthClient(configuration: .test, transport: transport, storage: MemoryCredentials())
        let model = PilotAccountModel(auth: auth, api: PilotAPIClient(configuration: .test, auth: auth, transport: RecordingTransport([])))
        let attempt = try XCTUnwrap(model.beginAppleSignIn())
        XCTAssertNil(model.beginAppleSignIn())
        await model.sendCode(email: "pilot@example.com")
        let requestsDuringPrompt = await transport.requests
        XCTAssertTrue(requestsDuringPrompt.isEmpty)
        await model.completeAppleSignIn(idToken: nil, nonce: nil, attempt: attempt, cancelled: true)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.errorMessage)
        await model.sendCode(email: "pilot@example.com")
        let requestsAfterCancel = await transport.requests
        XCTAssertEqual(requestsAfterCancel.count, 1)
    }

    func testOfflineRestartRequiresPriorAdmissionForTheSameIdentity() async throws {
        let credentials = MemoryCredentials(data: try JSONEncoder().encode(testSession()))
        let admission = MemoryCredentials()
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([]), storage: credentials)
        let userJSON = "{\"id\":\"\(userA)\",\"email\":\"pilot@example.com\",\"is_admin\":true}"
        let first = PilotAccountModel(auth: auth, api: PilotAPIClient(configuration: .test, auth: auth,
            transport: RecordingTransport([.ok(userJSON)])), admissionStorage: admission)
        await first.restore()
        XCTAssertNotNil(try admission.read())
        let offline = PilotAccountModel(auth: auth, api: PilotAPIClient(configuration: .test, auth: auth,
            transport: RecordingTransport([.failure(URLError(.notConnectedToInternet))])), admissionStorage: admission)
        await offline.restore()
        if case .admitted(_, let user) = offline.phase { XCTAssertEqual(user.id, userA) }
        else { XCTFail("Previously admitted identity can read its saved data offline") }
        let b = PilotCredentials(accessToken: "b", refreshToken: "b", expiresAt: 4102444800,
            identity: PilotIdentity(id: userB, email: "b@example.com"))
        let otherAuth = PilotAuthClient(configuration: .test, transport: RecordingTransport([]), storage: MemoryCredentials(data: try JSONEncoder().encode(b)))
        let other = PilotAccountModel(auth: otherAuth, api: PilotAPIClient(configuration: .test, auth: otherAuth,
            transport: RecordingTransport([.failure(URLError(.notConnectedToInternet))])), admissionStorage: admission)
        await other.restore()
        guard case .waiting = other.phase else { return XCTFail("Never reuse another identity's admission") }
    }

    func testServerDenialClearsOfflineAdmission() async throws {
        let receipt = Data("{\"identity\":\"\(userA)\",\"user\":{\"id\":\"\(userA)\",\"email\":\"pilot@example.com\",\"is_admin\":false}}".utf8)
        let admission = MemoryCredentials(data: receipt)
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([]), storage: MemoryCredentials(data: try JSONEncoder().encode(testSession())))
        let model = PilotAccountModel(auth: auth, api: PilotAPIClient(configuration: .test, auth: auth,
            transport: RecordingTransport([.response(403, "{\"error\":\"forbidden\"}")])), admissionStorage: admission)
        await model.restore()
        guard case .blocked = model.phase else { return XCTFail("Block denied account") }
        XCTAssertNil(try admission.read())
    }

    func testExplicitLogoutClearsOfflineAdmissionAsWellAsCredentials() async throws {
        let admission = MemoryCredentials(data: Data("saved admission".utf8))
        let credentials = MemoryCredentials(data: try JSONEncoder().encode(testSession()))
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([.failure(URLError(.notConnectedToInternet))]), storage: credentials)
        let model = PilotAccountModel(auth: auth, api: PilotAPIClient(configuration: .test, auth: auth, transport: RecordingTransport([])), admissionStorage: admission)
        await model.signOut()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(try admission.read())
        XCTAssertNil(try credentials.read())
    }

    func testReaderRevocationCannotBeUndoneByAnInFlightAdmissionRefresh() async throws {
        let admission = MemoryCredentials()
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([]),
            storage: MemoryCredentials(data: try JSONEncoder().encode(testSession())))
        let transport = PausedTransport()
        let model = PilotAccountModel(auth: auth,
            api: PilotAPIClient(configuration: .test, auth: auth, transport: transport), admissionStorage: admission)
        let userJSON = "{\"id\":\"\(userA)\",\"email\":\"pilot@example.com\",\"is_admin\":true}"
        let initial = Task { await model.restore() }
        await transport.waitForRequests(1)
        await transport.respond(0, body: userJSON)
        await initial.value
        let session = try XCTUnwrap(model.phase.session)
        let refresh = Task { await model.restore() }
        await transport.waitForRequests(2)
        model.readerFailed(.accessDenied, session: session)
        await transport.respond(1, body: userJSON)
        await refresh.value
        XCTAssertEqual(model.phase, .blocked(session))
        XCTAssertNil(try admission.read())
        XCTAssertFalse(model.isBusy)
    }

}
