import Foundation
import XCTest

@testable import PilotCore

private let day = "2026-10-18"
private func snapshot(_ value: Int? = nil, _ revision: Int = 0) -> String {
    "{\"selection\":{\"value\":\(value.map(String.init) ?? "null"),\"revision\":\(revision)},\"brief\":{\"value\":null,\"revision\":0}}"
}
private func reply(_ body: String, status: Int = 200, revision: String? = nil) -> Result<PilotHTTPResponse, Error> {
    .success(
        PilotHTTPResponse(
            data: Data(body.utf8), status: status,
            headers: revision.map { ["x-feedback-revision": $0] } ?? [:]))
}
private actor FeedbackTransport: PilotTransport {
    var replies: [Result<PilotHTTPResponse, Error>]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Result<PilotHTTPResponse, Error>]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let response = try await sendResponse(request)
        return (response.data, response.status)
    }
    func sendResponse(_ request: URLRequest) async throws -> PilotHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        return try replies.removeFirst().get()
    }
}

@MainActor
final class PilotFeedbackTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func make(_ transport: any PilotTransport, account: UUID = userA) async throws -> (
        PilotFeedbackModel, PilotAuthClient
    ) {
        let auth = PilotAuthClient(
            configuration: .test, transport: RecordingTransport([]),
            storage: MemoryCredentials(data: try JSONEncoder().encode(testSession())))
        let api = PilotAPIClient(configuration: .test, auth: auth, transport: transport)
        let current = try await auth.currentSession()
        let session = try XCTUnwrap(current)
        let store = PilotFeedbackStore(root: root, identity: session.identity.id, user: account)
        return (PilotFeedbackModel(api: api, session: session, store: store), auth)
    }

    func testVoteAndUndoUseConditionalAccountRequestsAndPersistAcknowledgement() async throws {
        let transport = FeedbackTransport([
            reply(snapshot()), reply(snapshot()), reply("", status: 204, revision: "1"), reply(snapshot(1, 1)),
            reply("", status: 204, revision: "2"),
        ])
        let (model, _) = try await make(transport)
        await model.refresh(date: day)
        try model.set(value: 1, aspect: .selection, date: day)
        XCTAssertEqual(model.record(for: day).pending["selection"]?.value, 1)
        await model.synchronize()
        XCTAssertEqual(model.record(for: day).snapshot.selection, PilotFeedbackValue(value: 1, revision: 1))
        XCTAssertTrue(model.record(for: day).pending.isEmpty)
        try model.set(value: nil, aspect: .selection, date: day)
        await model.synchronize()
        XCTAssertEqual(model.record(for: day).snapshot.selection, PilotFeedbackValue(value: nil, revision: 2))
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "PUT", "GET", "DELETE"])
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "X-Expected-Revision"), "0")
        XCTAssertEqual(requests[4].value(forHTTPHeaderField: "X-Expected-Revision"), "1")
        XCTAssertEqual(requests[4].url?.path, "/v1/briefs/engineering/2026-10-18/feedback/selection")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-a" })
        let (restarted, _) = try await make(FeedbackTransport([]))
        try restarted.load(date: day)
        XCTAssertEqual(restarted.record(for: day).snapshot.selection.revision, 2)
    }

    func testOfflineChangesCoalesceAndResumeAfterRestart() async throws {
        let (offline, _) = try await make(FeedbackTransport([.failure(URLError(.notConnectedToInternet))]))
        try offline.set(value: 1, aspect: .selection, date: day)
        try offline.set(value: -1, aspect: .selection, date: day)
        await offline.synchronize()
        XCTAssertNotNil(offline.errors[day])
        let transport = FeedbackTransport([reply(snapshot()), reply("", status: 204, revision: "1")])
        let (restarted, _) = try await make(transport)
        await restarted.synchronize()
        XCTAssertEqual(restarted.record(for: day).snapshot.selection.value, -1)
        XCTAssertTrue(restarted.record(for: day).pending.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try body(requests[1])["value"] as? Int, -1)
    }

    func testLostWriteResponseReloadsAndDoesNotResubmitAlreadySavedVote() async throws {
        let first = FeedbackTransport([reply(snapshot()), .failure(URLError(.networkConnectionLost))])
        let (model, _) = try await make(first)
        try model.set(value: 1, aspect: .selection, date: day)
        await model.synchronize()
        XCTAssertNotNil(model.record(for: day).pending["selection"])
        let afterRestart = FeedbackTransport([reply(snapshot(1, 1))])
        let (restarted, _) = try await make(afterRestart)
        await restarted.synchronize()
        XCTAssertTrue(restarted.record(for: day).pending.isEmpty)
        let requests = await afterRestart.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
    }

    func testAnotherDevicesNewerVoteRequiresFreshUserChoice() async throws {
        let transport = FeedbackTransport([
            reply(snapshot(1, 1)), reply(snapshot(nil, 2)), reply(snapshot(nil, 2)),
            reply("", status: 204, revision: "3"),
        ])
        let (model, _) = try await make(transport)
        await model.refresh(date: day)
        try model.set(value: -1, aspect: .selection, date: day)
        await model.synchronize()
        XCTAssertTrue(model.record(for: day).conflicts.contains("selection"))
        XCTAssertTrue(model.record(for: day).pending.isEmpty)
        XCTAssertEqual(model.record(for: day).snapshot.selection.revision, 2)
        let beforeChoice = await transport.requests
        XCTAssertEqual(beforeChoice.count, 2)
        try model.set(value: -1, aspect: .selection, date: day)
        await model.synchronize()
        XCTAssertEqual(model.record(for: day).snapshot.selection.value, -1)
        XCTAssertTrue(model.record(for: day).conflicts.isEmpty)
    }

    func testServerConflictDuringWriteReloadsWithoutAutomaticOverwrite() async throws {
        let transport = FeedbackTransport([
            reply(snapshot()), reply("{\"error\":\"feedback_conflict\"}", status: 409), reply(snapshot(-1, 1)),
        ])
        let (model, _) = try await make(transport)
        try model.set(value: 1, aspect: .selection, date: day)
        await model.synchronize()
        XCTAssertEqual(model.record(for: day).snapshot.selection.value, -1)
        XCTAssertTrue(model.record(for: day).conflicts.contains("selection"))
        XCTAssertTrue(model.record(for: day).pending.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT", "GET"])
    }

    func testOldAccountQueueCannotBeReadOrSentByAnotherAccount() async throws {
        let (a, _) = try await make(FeedbackTransport([]))
        try a.set(value: 1, aspect: .selection, date: day)
        a.invalidate()
        let bTransport = FeedbackTransport([])
        let (b, _) = try await make(bTransport, account: userB)
        await b.synchronize()
        XCTAssertTrue(b.record(for: day).pending.isEmpty)
        let requests = await bTransport.requests
        XCTAssertTrue(requests.isEmpty)
        let (backToA, _) = try await make(
            FeedbackTransport([reply(snapshot()), reply("", status: 204, revision: "1")]))
        await backToA.synchronize()
        XCTAssertEqual(backToA.record(for: day).snapshot.selection.value, 1)
    }

    func testLogoutAndSignInAsAnotherIdentityCannotSendOldIntentOrApplyLateResponse() async throws {
        let auth = PilotAuthClient(
            configuration: .test,
            transport: RecordingTransport([
                .ok("{}"), .ok(sessionJSON(access: "access-b", user: userB)),
                .ok("{}"), .ok(sessionJSON(access: "access-a-new")),
            ]),
            storage: MemoryCredentials(data: try JSONEncoder().encode(testSession())))
        let aCurrent = try await auth.currentSession()
        let aSession = try XCTUnwrap(aCurrent)
        let aTransport = PausedTransport()
        let a = PilotFeedbackModel(
            api: PilotAPIClient(configuration: .test, auth: auth, transport: aTransport),
            session: aSession, store: PilotFeedbackStore(root: root, identity: userA, user: userA))
        try a.set(value: 1, aspect: .selection, date: day)
        let oldSync = Task { await a.synchronize() }
        await aTransport.waitForRequests(1)
        try await auth.signOut()
        a.invalidate()
        _ = try await auth.verifyCode(email: "b@example.com", code: "123456")
        let bCurrent = try await auth.currentSession()
        let bSession = try XCTUnwrap(bCurrent)
        let bTransport = FeedbackTransport([reply(snapshot()), reply("", status: 204, revision: "1")])
        let b = PilotFeedbackModel(
            api: PilotAPIClient(configuration: .test, auth: auth, transport: bTransport),
            session: bSession, store: PilotFeedbackStore(root: root, identity: userB, user: userB))
        try b.set(value: -1, aspect: .brief, date: day)
        await b.synchronize()
        await aTransport.respond(0, body: snapshot())
        await oldSync.value
        XCTAssertTrue(a.records.isEmpty)
        XCTAssertNil(b.record(for: day).snapshot.selection.value)
        XCTAssertEqual(b.record(for: day).snapshot.brief.value, -1)
        let aRequests = await aTransport.requests
        let bRequests = await bTransport.requests
        XCTAssertEqual(aRequests.count, 1, "The late read must never trigger A's queued write")
        XCTAssertTrue(bRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-b" })
        XCTAssertEqual(try body(bRequests[1])["aspect"] as? String, "brief")

        try await auth.signOut()
        b.invalidate()
        _ = try await auth.verifyCode(email: "pilot@example.com", code: "123456")
        let aNewCurrent = try await auth.currentSession()
        let aNewSession = try XCTUnwrap(aNewCurrent)
        let returnedTransport = FeedbackTransport([reply(snapshot()), reply("", status: 204, revision: "1")])
        let returned = PilotFeedbackModel(
            api: PilotAPIClient(configuration: .test, auth: auth, transport: returnedTransport),
            session: aNewSession, store: PilotFeedbackStore(root: root, identity: userA, user: userA))
        await returned.synchronize()
        XCTAssertEqual(returned.record(for: day).snapshot.selection.value, 1)
        let returnedRequests = await returnedTransport.requests
        XCTAssertEqual(returnedRequests[1].value(forHTTPHeaderField: "Authorization"), "Bearer access-a-new")
    }

    func testConditionalWriteRetainsBodyAndRevisionWhenTokenRefreshes() async throws {
        let auth = PilotAuthClient(
            configuration: .test,
            transport: RecordingTransport([.ok(sessionJSON(access: "rotated-token"))]),
            storage: MemoryCredentials(data: try JSONEncoder().encode(testSession())))
        let transport = FeedbackTransport([reply("{}", status: 401), reply("", status: 204, revision: "3")])
        let current = try await auth.currentSession()
        let client = PilotFeedbackClient(
            api: PilotAPIClient(configuration: .test, auth: auth, transport: transport),
            session: try XCTUnwrap(current))
        let revision = try await client.set(value: 1, aspect: .brief, date: day, expectedRevision: 2)
        XCTAssertEqual(revision, 3)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].httpBody, requests[0].httpBody)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-Expected-Revision"), "2")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer rotated-token")
    }

    func testUnreadableOldFeedbackDoesNotBlockHealthyPendingVotes() async throws {
        let transport = FeedbackTransport([reply(snapshot()), reply("", status: 204, revision: "1")])
        let (model, _) = try await make(transport)
        try model.set(value: 1, aspect: .selection, date: day)
        let store = PilotFeedbackStore(root: root, identity: userA, user: userA)
        let damaged = store.directory.appendingPathComponent("2026-10-17.json")
        try Data("invalid JSON".utf8).write(to: damaged)
        await model.synchronize()
        XCTAssertTrue(model.record(for: day).pending.isEmpty)
        XCTAssertEqual(model.record(for: day).snapshot.selection.value, 1)
        XCTAssertNotNil(model.errors["2026-10-17"])
        XCTAssertEqual(
            try String(contentsOf: damaged, encoding: .utf8), "invalid JSON", "Keep damaged data for recovery")
    }

    func testInvalidationDuringReadDiscardsResponseAndPreventsQueuedWrite() async throws {
        let transport = PausedTransport()
        let (model, _) = try await make(transport)
        try model.set(value: 1, aspect: .selection, date: day)
        let sync = Task { await model.synchronize() }
        await transport.waitForRequests(1)
        model.invalidate()
        await transport.respond(0, body: snapshot())
        await sync.value
        XCTAssertTrue(model.records.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testRevokedAccessStopsSyncAndPreservesOnlyOriginalAccountPendingState() async throws {
        let transport = FeedbackTransport([reply("{\"error\":\"forbidden\"}", status: 403)])
        let (model, _) = try await make(transport)
        var denied = false
        model.onAccessFailure = { error in denied = error == .accessDenied }
        try model.set(value: 1, aspect: .selection, date: day)
        await model.synchronize()
        XCTAssertTrue(denied)
        XCTAssertFalse(model.isActive)
        XCTAssertThrowsError(try model.set(value: -1, aspect: .selection, date: day))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testMalformedSnapshotAndMissingMutationRevisionNeverClaimSaved() async throws {
        let invalid = FeedbackTransport([reply(snapshot(1, 0))])
        let (model, _) = try await make(invalid)
        await model.refresh(date: day)
        XCTAssertNotNil(model.errors[day])
        let missingHeader = FeedbackTransport([reply(snapshot()), reply("", status: 204)])
        let (pending, _) = try await make(missingHeader)
        try pending.set(value: 1, aspect: .selection, date: day)
        await pending.synchronize()
        XCTAssertNotNil(pending.record(for: day).pending["selection"])
        XCTAssertNotNil(pending.errors[day])
    }
}
