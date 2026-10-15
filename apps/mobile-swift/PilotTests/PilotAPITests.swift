import XCTest
@testable import PilotCore

private let registeredUser = "{\"id\":\"33333333-3333-3333-3333-333333333333\",\"email\":\"pilot@example.com\",\"is_admin\":true}"

final class PilotAPITests: XCTestCase {
    func testInviteAdmissionSendsCapturedAccountTokenAndReturnsAPIIdentity() async throws {
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([]),
            storage: MemoryCredentials(data: try JSONEncoder().encode(testSession())))
        let transport = RecordingTransport([.response(403, "{\"error\":\"invite_required\"}"), .response(201, registeredUser)])
        let api = PilotAPIClient(configuration: .test, auth: auth, transport: transport)
        let current = try await auth.currentSession()
        let session = try XCTUnwrap(current)
        do { _ = try await api.currentUser(session: session); XCTFail("New user must need an invite") }
        catch { XCTAssertEqual(error as? PilotError, .inviteRequired) }
        let user = try await api.acceptInvite("  engineering-pilot  ", session: session)
        XCTAssertEqual(user.id.uuidString, "33333333-3333-3333-3333-333333333333")
        XCTAssertTrue(user.isAdmin)
        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.example.com/v1/me")
        XCTAssertEqual(requests[1].url?.path, "/v1/users")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(try body(requests[1])["invite_code"] as? String, "engineering-pilot")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer access-a")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "apikey"))
    }

    func testAdmissionFailuresDoNotGrantAccessOrRequestAnotherInviteForDisabledUsers() async throws {
        let cases: [(Int, String, PilotError)] = [
            (403, "forbidden", .accessDenied), (422, "bad_request", .invalidInvite),
            (409, "conflict", .accountConflict), (429, "rate_limited", .rateLimited),
            (503, "unavailable", .unavailable), (302, "", .unavailable),
            (200, "not_a_user", .invalidResponse)
        ]
        for (status, code, expected) in cases {
            let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([]),
                storage: MemoryCredentials(data: try JSONEncoder().encode(testSession())))
            let api = PilotAPIClient(configuration: .test, auth: auth,
                transport: RecordingTransport([.response(status, "{\"error\":\"\(code)\"}")]))
            let current = try await auth.currentSession()
            do { _ = try await api.acceptInvite("invite", session: XCTUnwrap(current)); XCTFail("Must reject \(status)") }
            catch { XCTAssertEqual(error as? PilotError, expected, "status \(status)") }
        }
    }

    func testUnauthorizedRequestRefreshesOnceAndRetriesWithRotatedToken() async throws {
        let authTransport = RecordingTransport([.ok(sessionJSON(access: "rotated-token"))])
        let auth = PilotAuthClient(configuration: .test, transport: authTransport,
            storage: MemoryCredentials(data: try JSONEncoder().encode(testSession())))
        let transport = RecordingTransport([.response(401, "{}"), .ok(registeredUser)])
        let api = PilotAPIClient(configuration: .test, auth: auth, transport: transport)
        let current = try await auth.currentSession()
        _ = try await api.currentUser(session: XCTUnwrap(current))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer rotated-token")
        let refreshes = await authTransport.requests
        XCTAssertEqual(refreshes.count, 1)
    }

    func testRepeatedUnauthorizedResponseRequiresSignInWithoutRetryLoop() async throws {
        let store = MemoryCredentials(data: try JSONEncoder().encode(testSession()))
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([.ok(sessionJSON())]), storage: store)
        let transport = RecordingTransport([.response(401, "{}"), .response(401, "{}")])
        let api = PilotAPIClient(configuration: .test, auth: auth, transport: transport)
        let current = try await auth.currentSession()
        do { _ = try await api.currentUser(session: XCTUnwrap(current)); XCTFail("Must require a new session") }
        catch { XCTAssertEqual(error as? PilotError, .signInRequired) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(try store.read())
    }

    func testResponseFromPreviousSessionIsDiscardedEvenForSameUser() async throws {
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([.ok("{}"), .ok(sessionJSON())]),
            storage: MemoryCredentials(data: try JSONEncoder().encode(testSession())))
        let transport = PausedTransport()
        let api = PilotAPIClient(configuration: .test, auth: auth, transport: transport)
        let current = try await auth.currentSession()
        let session = try XCTUnwrap(current)
        let request = Task { try await api.currentUser(session: session) }
        await transport.waitForRequests(1)
        try await auth.signOut()
        _ = try await auth.verifyCode(email: "pilot@example.com", code: "123456")
        await transport.respond(0, body: registeredUser)
        do { _ = try await request.value; XCTFail("Must discard previous session's reply") }
        catch { XCTAssertEqual(error as? PilotError, .sessionChanged) }
    }
}
