import XCTest
@testable import PilotCore

private let feedID = "33333333-3333-3333-3333-333333333333"
private let feedsJSON = "[{\"id\":\"\(feedID)\",\"slug\":\"engineering\",\"member\":true,\"is_active\":true}]"
private let listJSON = "[{\"date\":\"2026-10-17\",\"article_title\":\"Full engineering brief\",\"article_url\":\"https://example.com/article\",\"snippet\":\"Key idea\",\"model\":\"model\",\"eval_score\":0.987654321}]"
private let briefJSON = "{\"feed_slug\":\"engineering\",\"date\":\"2026-10-17\",\"format\":\"insight-brief-v3\",\"payload\":{\"deep_dive\":\"Complete text\",\"future_field\":{\"keep\":null}}}"

@MainActor
final class PilotReaderTests: XCTestCase {
    func api(_ transport: any PilotTransport, identity: UUID = userA) throws -> (PilotAPIClient, PilotSession) {
        let credentials = PilotCredentials(accessToken: "access-a", refreshToken: "refresh-a", expiresAt: 4102444800,
            identity: PilotIdentity(id: identity, email: "pilot@example.com"))
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([]),
            storage: MemoryCredentials(data: try JSONEncoder().encode(credentials)))
        return (PilotAPIClient(configuration: .test, auth: auth, transport: transport),
                PilotSession(id: UUID(), identity: credentials.identity))
    }
    func store(identity: UUID = userA, user: UUID = userA, root: URL? = nil) -> PilotFeedStore {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return PilotFeedStore(root: root, identity: identity, user: user)
    }
    func session(_ api: PilotAPIClient) async throws -> PilotSession {
        let value = try await api.auth.currentSession()
        return try XCTUnwrap(value)
    }

    func testListUsesOnlyActiveEngineeringMembershipAndAuthenticatedBoundedEndpoint() async throws {
        let transport = RecordingTransport([.ok(feedsJSON), .ok(listJSON)])
        let (api, _) = try api(transport)
        let rows = try await api.engineeringBriefs(session: session(api))
        XCTAssertEqual(rows.first?.title, "Full engineering brief")
        XCTAssertEqual(rows.first?.evalScore, 0.987654321)
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/v1/feeds", "/v1/feeds/\(feedID)/briefs"])
        XCTAssertEqual(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.query, "limit=100")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-a" })
    }
    func testMissingMembershipNeverRequestsBriefs() async throws {
        for body in ["[]", feedsJSON.replacingOccurrences(of: "\"member\":true", with: "\"member\":false"), feedsJSON.replacingOccurrences(of: "\"is_active\":true", with: "\"is_active\":false")] {
            let transport = RecordingTransport([.ok(body)])
            let (api, _) = try api(transport)
            do { _ = try await api.engineeringBriefs(session: session(api)); XCTFail("Must deny") }
            catch { XCTAssertEqual(error as? PilotError, .accessDenied) }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1)
        }
    }
    func testBriefValidatesEnvelopeAndExtractsCompletePayload() async throws {
        let transport = RecordingTransport([.ok(briefJSON)])
        let (api, _) = try api(transport)
        let content = try await api.briefContent(date: "2026-10-17", session: session(api))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        XCTAssertEqual(payload["deep_dive"] as? String, "Complete text")
        XCTAssertTrue((payload["future_field"] as? [String: Any])?["keep"] is NSNull)
        let request = await transport.firstRequest()
        XCTAssertEqual(request?.url?.path, "/v1/briefs/engineering/2026-10-17")
        for bad in [briefJSON.replacingOccurrences(of: "engineering", with: "other"), briefJSON.replacingOccurrences(of: "2026-10-17", with: "2026-10-16"), briefJSON.replacingOccurrences(of: "insight-brief-v3", with: "markdown"), "{\"payload\":null}"] {
            let (invalidAPI, _) = try self.api(RecordingTransport([.ok(bad)]))
            do { _ = try await invalidAPI.briefContent(date: "2026-10-17", session: session(invalidAPI)); XCTFail("Reject invalid envelope") }
            catch { XCTAssertEqual(error as? PilotError, .invalidResponse) }
        }
    }
    func testDateCannotEscapeEngineeringRoute() async throws {
        let transport = RecordingTransport([])
        let (api, _) = try api(transport)
        do { _ = try await api.briefContent(date: "../me", session: session(api)); XCTFail("Reject invalid date") }
        catch { XCTAssertEqual(error as? PilotError, .invalidResponse) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testSavedContentWorksOfflineButCannotCrossIdentityOrUserNamespaces() async throws {
        let transport = RecordingTransport([.ok(feedsJSON), .ok(listJSON), .ok(briefJSON), .failure(URLError(.notConnectedToInternet))])
        let (api, _) = try api(transport)
        let cache = store()
        let reader = PilotFeedReader(api: api, session: try await session(api), store: cache)
        let initial = try await reader.summaries()
        XCTAssertFalse(initial.offline)
        let content = try await reader.content(date: "2026-10-17")
        let offline = try await reader.summaries()
        XCTAssertTrue(offline.offline)
        XCTAssertEqual(offline.items, initial.items)
        let cachedContent = try await reader.content(date: "2026-10-17")
        XCTAssertEqual(cachedContent, content)
        let root = cache.directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for isolated in [store(identity: userB, root: root), store(user: userB, root: root)] {
            let rows = try await isolated.summaries()
            let payload = try await isolated.content(date: "2026-10-17")
            XCTAssertNil(rows); XCTAssertNil(payload)
        }
        let reopened = PilotFeedStore(root: root, identity: userA, user: userA)
        let restored = try await reopened.summaries()
        XCTAssertEqual(restored, initial.items)
    }
    func testDefiniteDenialAndMalformedResponsesDoNotFallBackToCache() async throws {
        for failure in [RecordingTransport.Reply.response(403, "{\"error\":\"forbidden\"}"), .ok("not-json"), .response(302, "{}")] {
            let transport = RecordingTransport([.ok(feedsJSON), .ok(listJSON), failure])
            let (api, _) = try api(transport)
            let reader = PilotFeedReader(api: api, session: try await session(api), store: store())
            _ = try await reader.summaries()
            do { _ = try await reader.summaries(); XCTFail("Do not hide a definite denial or malformed response") }
            catch { XCTAssertTrue([PilotError.accessDenied, .invalidResponse].contains(error as? PilotError ?? .unavailable)) }
        }
    }
    func testLateListAfterInvalidationCannotPopulateCacheOrReturnToUI() async throws {
        let transport = PausedTransport()
        let (api, _) = try api(transport)
        let cache = store()
        let reader = PilotFeedReader(api: api, session: try await session(api), store: cache)
        let load = Task { try await reader.summaries() }
        await transport.waitForRequests(1)
        await transport.respond(0, body: feedsJSON)
        await transport.waitForRequests(2)
        reader.invalidate()
        await transport.respond(1, body: listJSON)
        do { _ = try await load.value; XCTFail("Discard old response") }
        catch { XCTAssertEqual(error as? PilotError, .sessionChanged) }
        let cached = try await cache.summaries()
        XCTAssertNil(cached)
    }
    func testRepeatedUnauthorizedRefreshesOnceAndClosesReader() async throws {
        let refresh = RecordingTransport([.ok(sessionJSON(access: "renewed"))])
        let auth = PilotAuthClient(configuration: .test, transport: refresh,
            storage: MemoryCredentials(data: try JSONEncoder().encode(testSession())))
        let requests = RecordingTransport([.response(401, "{}"), .response(401, "{}")])
        let api = PilotAPIClient(configuration: .test, auth: auth, transport: requests)
        let reader = PilotFeedReader(api: api, session: try await session(api), store: store())
        var reported: PilotError?
        reader.onAccessFailure = { reported = $0 }
        do { _ = try await reader.summaries(); XCTFail("Must sign in again") }
        catch { XCTAssertEqual(error as? PilotError, .signInRequired) }
        XCTAssertFalse(reader.isActive)
        XCTAssertEqual(reported, .signInRequired)
        let calls = await requests.requests
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.value(forHTTPHeaderField: "Authorization"), "Bearer renewed")
        let refreshCalls = await refresh.requests
        XCTAssertEqual(refreshCalls.count, 1)
    }

}
