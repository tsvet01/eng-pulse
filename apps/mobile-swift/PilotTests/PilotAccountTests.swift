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

}
