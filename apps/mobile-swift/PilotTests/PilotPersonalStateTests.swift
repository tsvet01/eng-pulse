import XCTest
@testable import PilotCore

@MainActor
final class PilotPersonalStateTests: XCTestCase {
    private let date = "2026-10-18"
    private let prefs = "{\"notify_email\":true,\"notify_push\":false}"

    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func client(_ transport: any PilotTransport, identity: UUID = userA) async throws -> (PilotAPIClient, PilotSession) {
        let credentials = PilotCredentials(accessToken: "access-a", refreshToken: "refresh-a", expiresAt: 4102444800,
            identity: PilotIdentity(id: identity, email: "pilot@example.com"))
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([]),
            storage: MemoryCredentials(data: try JSONEncoder().encode(credentials)))
        let current = try await auth.currentSession()
        let session = try XCTUnwrap(current)
        return (PilotAPIClient(configuration: .test, auth: auth, transport: transport), session)
    }
    private func model(_ transport: any PilotTransport, root: URL? = nil, identity: UUID = userA,
                       user: UUID = userA) async throws -> PilotPersonalState {
        let (api, session) = try await client(transport, identity: identity)
        return PilotPersonalState(api: api, session: session, user: user, root: root ?? self.root())
    }

    func testFeedbackRequestsUseAuthenticatedEngineeringRouteAndAcceptNoContent() async throws {
        let transport = RecordingTransport([.ok("{\"selection\":1,\"brief\":null}"), .response(204, ""), .response(204, "")])
        let (api, session) = try await client(transport)
        let feedback = try await api.feedback(date: date, session: session)
        XCTAssertEqual(feedback, PilotFeedback(selection: 1, brief: nil))
        try await api.setFeedback(date: date, aspect: .brief, value: -1, session: session)
        try await api.setFeedback(date: date, aspect: .brief, value: nil, session: session)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT", "DELETE"])
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/v1/briefs/engineering/2026-10-18/feedback" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-a" })
        XCTAssertEqual(try body(requests[1])["value"] as? Int, -1)
        XCTAssertEqual(try body(requests[1])["aspect"] as? String, "brief")
        XCTAssertEqual(try body(requests[2]).count, 1)
        XCTAssertEqual(try body(requests[2])["aspect"] as? String, "brief")
    }

    func testInvalidValuesAndDatesNeverReachNetworkAndMalformedRatingsAreRejected() async throws {
        let transport = RecordingTransport([])
        let (api, session) = try await client(transport)
        for (date, value) in [(date, 0), ("../me", 1), ("2026-02-30", 1)] {
            do { try await api.setFeedback(date: date, aspect: .brief, value: value, session: session); XCTFail("Invalid input") }
            catch { XCTAssertEqual(error as? PilotError, .invalidResponse) }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        for data in ["{\"brief\":0,\"selection\":null}", "{\"brief\":1}", "{}"] {
            let (api, session) = try await client(RecordingTransport([.ok(data)]))
            do { _ = try await api.feedback(date: date, session: session); XCTFail("Invalid response") }
            catch { XCTAssertEqual(error as? PilotError, .invalidResponse) }
        }
    }

    func testOfflineRatingSurvivesRestartAndRetriesOnlyForOriginalIdentityAndUser() async throws {
        let root = root()
        let first = try await model(RecordingTransport([.failure(URLError(.notConnectedToInternet))]), root: root)
        await first.rate(date: date, aspect: .selection, value: -1)
        XCTAssertEqual(first.feedback[date]?.selection, -1)
        XCTAssertTrue(first.hasPending(date: date))
        first.invalidate()
        for (identity, user) in [(userB, userA), (userA, userB)] {
            let transport = RecordingTransport([])
            let isolated = try await model(transport, root: root, identity: identity, user: user)
            await isolated.flush()
            XCTAssertTrue(isolated.feedback.isEmpty)
            let requests = await transport.requests
            XCTAssertTrue(requests.isEmpty)
        }
        let transport = RecordingTransport([.response(204, "")])
        let resumed = try await model(transport, root: root)
        await resumed.flush()
        XCTAssertFalse(resumed.hasPending(date: date))
        XCTAssertEqual(resumed.feedback[date]?.selection, -1)
        let firstRequest = await transport.firstRequest()
        let request = try XCTUnwrap(firstRequest)
        XCTAssertEqual(try body(request)["value"] as? Int, -1)
        let reopened = try await model(RecordingTransport([]), root: root)
        await reopened.flush()
        XCTAssertFalse(reopened.hasPending(date: date))
        XCTAssertEqual(reopened.feedback[date]?.selection, -1)
    }

    func testNewerEditIsNotRemovedByEarlierAcknowledgement() async throws {
        let transport = PausedTransport()
        let state = try await model(transport)
        let first = Task { await state.rate(date: date, aspect: .brief, value: 1) }
        await transport.waitForRequests(1)
        await state.rate(date: date, aspect: .brief, value: nil)
        XCTAssertNil(state.feedback[date]?.brief)
        await transport.respond(0, status: 204, body: "")
        await transport.waitForRequests(2)
        XCTAssertTrue(state.hasPending(date: date))
        let requests = await transport.requests
        XCTAssertEqual(requests[1].httpMethod, "DELETE")
        await transport.respond(1, status: 204, body: "")
        await first.value
        XCTAssertFalse(state.hasPending(date: date))
        XCTAssertNil(state.feedback[date]?.brief)
    }

    func testLateAcknowledgementAfterLogoutCannotClearPendingWork() async throws {
        let root = root()
        let transport = PausedTransport()
        let state = try await model(transport, root: root)
        let save = Task { await state.rate(date: date, aspect: .brief, value: 1) }
        await transport.waitForRequests(1)
        state.invalidate()
        await transport.respond(0, status: 204, body: "")
        await save.value
        XCTAssertTrue(state.feedback.isEmpty)
        let retry = RecordingTransport([.response(204, "")])
        let resumed = try await model(retry, root: root)
        await resumed.flush()
        let requests = await retry.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testServerReadCannotOverwriteANewerAcknowledgedLocalRating() async throws {
        let transport = PausedTransport()
        let state = try await model(transport)
        let read = Task { await state.refreshFeedback(date: date) }
        await transport.waitForRequests(1)
        let save = Task { await state.rate(date: date, aspect: .brief, value: -1) }
        await transport.waitForRequests(2)
        await transport.respond(1, status: 204, body: "")
        await save.value
        await transport.respond(0, body: "{\"selection\":null,\"brief\":1}")
        await read.value
        XCTAssertEqual(state.feedback[date]?.brief, -1)
        XCTAssertFalse(state.hasPending(date: date))
    }

    func testFailedPersistenceDoesNotDisplayAnUnqueuedRating() async throws {
        let root = root()
        try Data("file occupying directory".utf8).write(to: root)
        let transport = RecordingTransport([])
        let state = try await model(transport, root: root)
        await state.rate(date: date, aspect: .brief, value: 1)
        XCTAssertNil(state.feedback[date]?.brief)
        XCTAssertFalse(state.hasPending(date: date))
        XCTAssertNotNil(state.feedbackErrors[date])
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testReadStartedDuringPendingWriteCannotRestorePreWriteServerValue() async throws {
        let transport = PausedTransport()
        let state = try await model(transport)
        let save = Task { await state.rate(date: date, aspect: .brief, value: -1) }
        await transport.waitForRequests(1)
        let read = Task { await state.refreshFeedback(date: date) }
        await transport.waitForRequests(2)
        await transport.respond(0, status: 204, body: "")
        await save.value
        await transport.respond(1, body: "{\"selection\":null,\"brief\":1}")
        await read.value
        XCTAssertEqual(state.feedback[date]?.brief, -1)
    }

    func testAccessDenialInvalidatesStateAndReportsToAccount() async throws {
        let state = try await model(RecordingTransport([.response(403, "{\"error\":\"forbidden\"}")]))
        var reported: PilotError?
        state.onAccessFailure = { reported = $0 }
        await state.rate(date: date, aspect: .brief, value: 1)
        XCTAssertEqual(reported, .accessDenied)
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.feedback.isEmpty)
    }

    func testPreferencesRequireMembershipAndUseExistingMembershipEndpoint() async throws {
        let transport = RecordingTransport([.ok(verifiedEngineeringFeed), .ok(prefs), .ok(verifiedEngineeringFeed),
            .ok("{\"notify_email\":false,\"notify_push\":true}")])
        let state = try await model(transport)
        await state.loadPreferences()
        XCTAssertEqual(state.preferences, PilotNotificationPreferences(notifyEmail: true, notifyPush: false))
        await state.savePreferences(PilotNotificationPreferences(notifyEmail: false, notifyPush: true))
        XCTAssertEqual(state.preferences, PilotNotificationPreferences(notifyEmail: false, notifyPush: true))
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "PUT"])
        XCTAssertEqual(requests[3].url?.path, "/v1/feeds/33333333-3333-3333-3333-333333333333/preferences")
        XCTAssertEqual(try body(requests[3])["notify_email"] as? Bool, false)
        XCTAssertEqual(try body(requests[3])["notify_push"] as? Bool, true)
        let deniedTransport = RecordingTransport([.ok("[]")])
        let denied = try await model(deniedTransport)
        await denied.savePreferences(PilotNotificationPreferences(notifyEmail: false, notifyPush: false))
        XCTAssertFalse(denied.isActive)
        let calls = await deniedTransport.requests
        XCTAssertEqual(calls.count, 1)
    }

    func testFailedPreferenceSaveKeepsAcknowledgedValuesAndShowsFailure() async throws {
        let transport = RecordingTransport([.ok(verifiedEngineeringFeed), .ok(prefs), .ok(verifiedEngineeringFeed),
            .failure(URLError(.notConnectedToInternet))])
        let state = try await model(transport)
        await state.loadPreferences()
        await state.savePreferences(PilotNotificationPreferences(notifyEmail: false, notifyPush: true))
        XCTAssertEqual(state.preferences, PilotNotificationPreferences(notifyEmail: true, notifyPush: false))
        XCTAssertNotNil(state.preferencesError)
        XCTAssertFalse(state.isSavingPreferences)
    }

    func testLatePreferencesAfterInvalidationDoNotReappear() async throws {
        let transport = PausedTransport()
        let state = try await model(transport)
        let read = Task { await state.loadPreferences() }
        await transport.waitForRequests(1)
        await transport.respond(0, body: verifiedEngineeringFeed)
        await transport.waitForRequests(2)
        state.invalidate()
        await transport.respond(1, body: prefs)
        await read.value
        XCTAssertNil(state.preferences)
    }
}
