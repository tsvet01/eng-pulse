import Foundation
import XCTest

@testable import PilotCore

private let day = "2026-10-18"
private let identity = PilotContentIdentity(articleID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, briefID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!)
private let shown = PilotFeedbackContext(date: day, identity: identity)
private let otherDate = PilotFeedbackContext(date: "2026-10-19", identity: identity)
private let secondVersion = PilotFeedbackContext(date: day, identity: PilotContentIdentity(articleID: identity.articleID, briefID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!))
private let mapping = "{\"article_id\":\"44444444-4444-4444-4444-444444444444\",\"brief_id\":\"55555555-5555-5555-5555-555555555555\"}"
private func snapshot(_ value: Int? = nil, _ revision: Int = 0) -> String {
    "{\"value\":\(value.map(String.init) ?? "null"),\"reason\":null,\"revision\":\(revision)}"
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

    func testLegacyQueueResolvesOnlyConservativeMappingBeforeStableWrite() async throws {
        let transport = FeedbackTransport([
            reply("{\"article_id\":\"44444444-4444-4444-4444-444444444444\",\"brief_id\":\"55555555-5555-5555-5555-555555555555\"}"),
            reply("{\"value\":null,\"reason\":null,\"revision\":0}"), reply("", status: 204, revision: "1")
        ])
        let store = PilotFeedbackStore(root: root, identity: userA, user: userA)
        var legacy = PilotFeedbackRecord()
        legacy.pending["selection"] = PilotFeedbackIntent(value: 1, expectedRevision: 0)
        try store.save(legacy, date: day)
        let (model, _) = try await make(transport)
        await model.synchronize()
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.url?.path, "/v2/briefs/engineering/2026-10-18/feedback-identity")
        XCTAssertEqual(requests.last?.httpMethod, "PUT")
        XCTAssertEqual(requests.last?.url?.path, "/v2/articles/44444444-4444-4444-4444-444444444444/feedback/relevance")
    }

    private func legacy(_ value: Int?, date: String = day, revision: Int64 = 0) throws {
        var saved = PilotFeedbackRecord()
        saved.pending["selection"] = PilotFeedbackIntent(value: value, expectedRevision: revision)
        try PilotFeedbackStore(root: root, identity: userA, user: userA).save(saved, date: date)
    }

    func testSameArticleAcrossDatesSharesOfflineIntentAndRemoteState() async throws {
        let (model, _) = try await make(FeedbackTransport([]))
        try model.set(value: 1, aspect: .selection, context: shown)
        XCTAssertEqual(model.record(for: otherDate).displayed(.selection), 1)
        try model.set(value: -1, aspect: .selection, context: otherDate)
        XCTAssertEqual(model.record(for: shown).displayed(.selection), -1)
        let transport = FeedbackTransport([reply(snapshot()), reply("", status: 204, revision: "1"), reply(snapshot()), reply(snapshot(-1, 1))])
        let (restarted, _) = try await make(transport)
        await restarted.synchronize()
        await restarted.refresh(context: otherDate)
        XCTAssertEqual(restarted.record(for: shown).snapshot.selection.value, -1)
        XCTAssertEqual(restarted.record(for: otherDate).snapshot.selection.value, -1)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "PUT" }.count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.url!.path.contains("/v2/articles/44444444-4444-4444-4444-444444444444/") })
    }

    func testTwoBriefVersionsKeepIndependentVotesThroughRestart() async throws {
        let (model, _) = try await make(FeedbackTransport([]))
        try model.set(value: 1, aspect: .brief, context: shown)
        try model.set(value: -1, aspect: .brief, context: secondVersion)
        let transport = FeedbackTransport([reply(snapshot()), reply("", status: 204, revision: "1"), reply(snapshot()), reply("", status: 204, revision: "1")])
        let (restarted, _) = try await make(transport)
        await restarted.synchronize()
        XCTAssertEqual(restarted.record(for: shown).displayed(.brief), 1)
        XCTAssertEqual(restarted.record(for: secondVersion).displayed(.brief), -1)
        let writes = await transport.requests.filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(writes.map { $0.url?.query }, ["brief_id=55555555-5555-5555-5555-555555555555", "brief_id=66666666-6666-6666-6666-666666666666"])
    }

    func testReasonSurvivesReadButGenericThumbAndUndoClearIt() async throws {
        let negative = "{\"value\":-1,\"reason\":\"not_relevant\",\"revision\":2}"
        let transport = FeedbackTransport([reply(snapshot()), reply(negative), reply(negative), reply("", status: 204, revision: "3"), reply(snapshot(-1, 3)), reply("", status: 204, revision: "4")])
        let (model, _) = try await make(transport)
        await model.refresh(context: shown)
        XCTAssertEqual(model.record(for: shown).snapshot.selection.reason, "not_relevant")
        try model.set(value: -1, aspect: .selection, context: shown)
        await model.synchronize()
        XCTAssertNil(model.record(for: shown).snapshot.selection.reason)
        try model.set(value: nil, aspect: .selection, context: shown)
        await model.synchronize()
        let requests = await transport.requests
        let put = try XCTUnwrap(requests.first { $0.httpMethod == "PUT" })
        XCTAssertTrue(try body(put)["reason"] is NSNull)
        XCTAssertEqual(requests.last?.httpMethod, "DELETE")
        XCTAssertNil(model.record(for: shown).snapshot.selection.reason)
    }

    func testNoOpClearDoesNotMutateServer() async throws {
        let transport = FeedbackTransport([reply(snapshot())])
        let (model, _) = try await make(transport)
        try model.set(value: nil, aspect: .selection, context: shown)
        await model.synchronize()
        XCTAssertTrue(model.record(for: shown).pending.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
    }

    func testMigratedUncertainWriteThenRestartUndoNeverReplaysLegacyVote() async throws {
        try legacy(1)
        let first = FeedbackTransport([reply(mapping), reply(snapshot()), .failure(URLError(.networkConnectionLost))])
        let (model, _) = try await make(first)
        await model.synchronize()
        XCTAssertEqual(model.record(for: shown).pending["selection"]?.value, 1)
        let second = FeedbackTransport([reply(snapshot(1, 1)), reply(snapshot(1, 1)), reply("", status: 204, revision: "2")])
        let (restarted, _) = try await make(second)
        await restarted.synchronize()
        try restarted.set(value: nil, aspect: .selection, context: shown)
        await restarted.synchronize()
        let third = FeedbackTransport([])
        let (again, _) = try await make(third)
        await again.synchronize()
        XCTAssertEqual(again.record(for: shown).snapshot.selection.revision, 2)
        XCTAssertNil(again.record(for: shown).displayed(.selection))
        let requests = await third.requests
        XCTAssertTrue(requests.isEmpty, "Acknowledged legacy sources must not be mapped or resent")
        let retained = try PilotFeedbackStore(root: root, identity: userA, user: userA).load(date: day)
        XCTAssertEqual(retained.pending["selection"]?.value, 1, "Original evidence stays intact")
    }

    func testMissingChangedAndMalformedMappingsPreservePendingAndExposeError() async throws {
        try legacy(1)
        for response in [reply("{}", status: 404), reply("{\"error\":\"mapping_unavailable\"}", status: 422), reply("{\"article_id\":\"invalid\",\"brief_id\":null}")] {
            let transport = FeedbackTransport([response])
            let (model, _) = try await make(transport)
            await model.synchronize()
            XCTAssertNotNil(model.error(for: shown))
            let retained = try PilotFeedbackStore(root: root, identity: userA, user: userA).load(date: day)
            XCTAssertEqual(retained.pending["selection"]?.value, 1)
            let requests = await transport.requests
            XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
            XCTAssertEqual(requests.first?.url?.path, "/v2/briefs/engineering/2026-10-18/feedback-identity")
        }
    }

    func testIncompatibleLegacyDatesRemainVisibleUntilExplicitChoice() async throws {
        try legacy(1)
        try legacy(-1, date: "2026-10-19")
        let transport = FeedbackTransport([reply(mapping), reply(mapping)])
        let (model, _) = try await make(transport)
        await model.synchronize()
        XCTAssertNotNil(model.error(for: shown))
        XCTAssertTrue(model.record(for: shown).conflicts.contains("selection"))
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"])
        let next = FeedbackTransport([reply(snapshot()), reply("", status: 204, revision: "1")])
        let (restarted, _) = try await make(next)
        await restarted.synchronize()
        XCTAssertNotNil(restarted.error(for: shown))
        try restarted.set(value: 1, aspect: .selection, context: shown)
        await restarted.synchronize()
        XCTAssertNil(restarted.error(for: shown))
        XCTAssertTrue(restarted.record(for: shown).conflicts.isEmpty)
    }

    func testNewerStableIntentWinsWhileLegacyConflictIsPreserved() async throws {
        let transport = FeedbackTransport([reply(mapping), reply(snapshot()), reply("", status: 204, revision: "1")])
        let (model, _) = try await make(transport)
        try model.set(value: -1, aspect: .selection, context: shown)
        try legacy(1)
        await model.synchronize()
        XCTAssertEqual(model.record(for: shown).displayed(.selection), -1)
        XCTAssertNotNil(model.error(for: shown))
        let requests = await transport.requests
        XCTAssertEqual(try body(requests.last!)["value"] as? Int, -1)
        let retained = try PilotFeedbackStore(root: root, identity: userA, user: userA).load(date: day)
        XCTAssertEqual(retained.pending["selection"]?.value, 1)
    }

    func testAccountChangeDuringMappingCannotImportOrWrite() async throws {
        try legacy(1)
        let transport = PausedTransport()
        let (model, auth) = try await make(transport)
        let task = Task { await model.synchronize() }
        await transport.waitForRequests(1)
        let current = try await auth.currentSession()
        try await auth.discard(try XCTUnwrap(current))
        await transport.respond(0, body: mapping)
        await task.value
        XCTAssertFalse(model.isActive)
        XCTAssertTrue(model.records.isEmpty)
        let files = try PilotFeedbackStore(root: root, identity: userA, user: userA).stableFiles()
        XCTAssertTrue(files.isEmpty)
    }

    func testBackgroundSyncSkipsCompletedAndEmptyLegacyDatesUntilViewed() async throws {
        let store = PilotFeedbackStore(root: root, identity: userA, user: userA)
        try store.save(PilotFeedbackRecord(), date: "2026-10-16")
        var complete = PilotFeedbackRecord()
        complete.snapshot.selection = PilotFeedbackValue(value: 1, revision: 1)
        try store.save(complete, date: day)
        let transport = FeedbackTransport([reply(mapping), reply(snapshot()), reply(snapshot(1, 1))])
        let (model, _) = try await make(transport)
        await model.synchronize()
        let background = await transport.requests
        XCTAssertTrue(background.isEmpty, "Visited dates without pending work cannot delay feedback startup")
        await model.refresh(context: shown)
        XCTAssertEqual(model.record(for: shown).displayed(.selection), 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.url?.path, "/v2/briefs/engineering/2026-10-18/feedback-identity")
    }

    func testCorruptMigrationTargetDoesNotBlockHealthyQueuedWork() async throws {
        let store = PilotFeedbackStore(root: root, identity: userA, user: userA)
        let broken = PilotFeedbackTarget(identity: identity, aspect: .selection)
        try FileManager.default.createDirectory(at: store.stableDirectory, withIntermediateDirectories: true)
        let file = store.stableDirectory.appendingPathComponent(broken.key + ".json")
        try Data("damaged".utf8).write(to: file)
        try legacy(1)
        let transport = FeedbackTransport([reply(mapping), reply(snapshot()), reply("", status: 204, revision: "1")])
        let (model, _) = try await make(transport)
        try model.set(value: -1, aspect: .brief, context: secondVersion)
        await model.synchronize()
        XCTAssertEqual(model.record(for: secondVersion).snapshot.brief.value, -1)
        XCTAssertTrue(model.record(for: secondVersion).pending.isEmpty)
        XCTAssertNotNil(model.error(for: shown))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "damaged")
    }

    func testLateMutationAfterAccountChangeCannotPersistAcknowledgement() async throws {
        let transport = PausedTransport()
        let (model, auth) = try await make(transport)
        try model.set(value: 1, aspect: .selection, context: shown)
        let task = Task { await model.synchronize() }
        await transport.waitForRequests(1)
        await transport.respond(0, body: snapshot())
        await transport.waitForRequests(2)
        let current = try await auth.currentSession()
        try await auth.discard(try XCTUnwrap(current))
        await transport.respond(1, status: 204, body: "")
        await task.value
        XCTAssertFalse(model.isActive)
        let saved = try PilotFeedbackStore(root: root, identity: userA, user: userA).load(target: PilotFeedbackTarget(identity: identity, aspect: .selection))
        XCTAssertEqual(saved?.pending?.value, 1)
        XCTAssertEqual(saved?.snapshot.revision, 0)
    }

    func testOnlyMatchingLegacyPayloadCanUseResolvedDisplayIdentity() async throws {
        let old = PilotFeedbackContext(date: day, legacyContent: "{\"deep_dive\":\"different older payload\"}")
        let matching = PilotFeedbackContext(date: day, legacyContent: "{ \"deep_dive\": \"original payload\", \"future\": [1,true,null] }")
        let envelope = "{\"feed_slug\":\"engineering\",\"date\":\"2026-10-18\",\"format\":\"insight-brief-v3\",\"article_id\":\"44444444-4444-4444-4444-444444444444\",\"brief_id\":\"55555555-5555-5555-5555-555555555555\",\"payload\":{\"deep_dive\":\"original payload\",\"future\":[1,true,null]}}"
        let transport = FeedbackTransport([reply(mapping), reply(envelope), reply(mapping), reply(envelope), reply(snapshot()), reply(snapshot())])
        let (model, _) = try await make(transport)
        await model.refresh(context: old)
        XCTAssertNotNil(model.error(for: old))
        XCTAssertThrowsError(try model.set(value: 1, aspect: .brief, context: old))
        await model.refresh(context: matching)
        XCTAssertNil(model.error(for: matching))
        try model.set(value: -1, aspect: .brief, context: matching)
        XCTAssertEqual(model.record(for: shown).displayed(.brief), -1)
        XCTAssertNil(model.record(for: old).displayed(.brief))
        XCTAssertNotNil(model.error(for: old), "A second payload's resolution cannot hide the first payload's mismatch")
        XCTAssertThrowsError(try model.set(value: 1, aspect: .brief, context: old))
        let requests = await transport.requests
        XCTAssertEqual(requests.prefix(4).map { $0.url?.path }, [
            "/v2/briefs/engineering/2026-10-18/feedback-identity", "/v1/briefs/engineering/2026-10-18",
            "/v2/briefs/engineering/2026-10-18/feedback-identity", "/v1/briefs/engineering/2026-10-18"
        ])
    }

    func testLegacyMappingAndAtomicPayloadIDsMustAgree() async throws {
        let context = PilotFeedbackContext(date: day, legacyContent: "{\"deep_dive\":\"same text\"}")
        let envelope = "{\"feed_slug\":\"engineering\",\"date\":\"2026-10-18\",\"format\":\"insight-brief-v3\",\"article_id\":\"44444444-4444-4444-4444-444444444444\",\"brief_id\":\"66666666-6666-6666-6666-666666666666\",\"payload\":{\"deep_dive\":\"same text\"}}"
        let transport = FeedbackTransport([reply(mapping), reply(envelope)])
        let (model, _) = try await make(transport)
        await model.refresh(context: context)
        XCTAssertNotNil(model.error(for: context))
        XCTAssertThrowsError(try model.set(value: 1, aspect: .selection, context: context))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testVerifiedLegacyPayloadKeepsIdentityAfterOfflineRestart() async throws {
        let raw = PilotBriefContent(content: "{\"deep_dive\":\"proven old cache\"}")
        let context = raw.feedbackContext(date: day)
        let envelope = "{\"feed_slug\":\"engineering\",\"date\":\"2026-10-18\",\"format\":\"insight-brief-v3\",\"article_id\":\"44444444-4444-4444-4444-444444444444\",\"brief_id\":\"55555555-5555-5555-5555-555555555555\",\"payload\":{\"deep_dive\":\"proven old cache\"}}"
        let transport = FeedbackTransport([reply(mapping), reply(envelope), reply(snapshot()), reply(snapshot())])
        let (model, _) = try await make(transport)
        await model.refresh(context: context)
        XCTAssertNil(model.error(for: context))
        let offline = FeedbackTransport([])
        let (restarted, _) = try await make(offline)
        try restarted.set(value: 1, aspect: .brief, context: raw.feedbackContext(date: day))
        XCTAssertEqual(restarted.record(for: shown).displayed(.brief), 1)
        let requests = await offline.requests
        XCTAssertTrue(requests.isEmpty, "The same exact raw payload reuses its durable proof offline")
        let changed = PilotBriefContent(content: "{\"deep_dive\":\"unproven replacement\"}")
        XCTAssertThrowsError(try restarted.set(value: -1, aspect: .brief, context: changed.feedbackContext(date: day)))
        let (otherAccount, _) = try await make(FeedbackTransport([]), account: userB)
        XCTAssertThrowsError(try otherAccount.set(value: -1, aspect: .brief, context: context))
    }

    func testPartialMigrationCommitSurvivesRestartAndChangedMapping() async throws {
        let store = PilotFeedbackStore(root: root, identity: userA, user: userA)
        var legacy = PilotFeedbackRecord()
        legacy.pending["selection"] = PilotFeedbackIntent(value: 1, expectedRevision: 0)
        legacy.pending["brief"] = PilotFeedbackIntent(value: -1, expectedRevision: 0)
        try store.save(legacy, date: day)
        let blocked = store.stableDirectory.appendingPathComponent(PilotFeedbackTarget(identity: identity, aspect: .selection).key + ".json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let first = FeedbackTransport([reply(mapping), reply(snapshot()), reply("", status: 204, revision: "1")])
        let (partial, _) = try await make(first)
        await partial.synchronize()
        XCTAssertEqual(partial.record(for: shown).snapshot.brief.value, -1)
        XCTAssertNotNil(partial.error(for: shown))
        try FileManager.default.removeItem(at: blocked)
        let changed = FeedbackTransport([reply("{\"error\":\"mapping_unavailable\"}", status: 422)])
        let (restarted, _) = try await make(changed)
        await restarted.synchronize()
        XCTAssertEqual(restarted.record(for: shown).snapshot.brief.value, -1)
        XCTAssertNotNil(restarted.error(for: shown))
        let changedRequests = await changed.requests
        XCTAssertEqual(changedRequests.map(\.httpMethod), ["GET"], "An incomplete import cannot retarget or replay the acknowledged aspect")
        let recovered = FeedbackTransport([reply(mapping), reply(snapshot()), reply("", status: 204, revision: "1"), reply(snapshot(-1, 1)), reply("", status: 204, revision: "2")])
        let (healthy, _) = try await make(recovered)
        await healthy.synchronize()
        XCTAssertEqual(healthy.record(for: shown).snapshot.selection.value, 1)
        try healthy.set(value: nil, aspect: .brief, context: shown)
        await healthy.synchronize()
        XCTAssertNil(healthy.record(for: shown).snapshot.brief.value)
        let retained = try store.load(date: day)
        XCTAssertEqual(retained, legacy)
        let requests = await recovered.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "PUT", "GET", "DELETE"])
        XCTAssertEqual(requests.last?.url?.query, "brief_id=55555555-5555-5555-5555-555555555555")
    }

    func testMatchingLegacyValuesWithDifferentRevisionsStillConflict() async throws {
        try legacy(1)
        try legacy(1, date: "2026-10-19", revision: 4)
        let transport = FeedbackTransport([reply(mapping), reply(mapping)])
        let (model, _) = try await make(transport)
        await model.synchronize()
        XCTAssertTrue(model.record(for: shown).conflicts.contains("selection"))
        XCTAssertNotNil(model.error(for: shown))
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"])
    }

    func testNewlyDiscoveredLegacyIntentCannotResurrectStableClear() async throws {
        let transport = FeedbackTransport([reply(snapshot()), reply(mapping)])
        let (model, _) = try await make(transport)
        try model.set(value: nil, aspect: .selection, context: shown)
        await model.synchronize()
        try legacy(1)
        await model.synchronize()
        XCTAssertNil(model.record(for: shown).displayed(.selection))
        XCTAssertTrue(model.record(for: shown).pending.isEmpty)
        XCTAssertNotNil(model.error(for: shown))
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"])
    }

    func testConcurrentSynchronizationSerializesAccountWrites() async throws {
        let transport = PausedTransport()
        let (model, _) = try await make(transport)
        try model.set(value: 1, aspect: .selection, context: shown)
        let first = Task { await model.synchronize() }
        await transport.waitForRequests(1)
        await model.synchronize()
        XCTAssertThrowsError(try model.set(value: -1, aspect: .selection, context: shown))
        await transport.respond(0, body: snapshot(1, 1))
        await first.value
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(model.record(for: shown).displayed(.selection), 1)
    }

    func testVoteAndUndoUseConditionalAccountRequestsAndPersistAcknowledgement() async throws {
        let transport = FeedbackTransport([
            reply(snapshot()), reply(snapshot()), reply(snapshot()), reply("", status: 204, revision: "1"), reply(snapshot(1, 1)),
            reply("", status: 204, revision: "2"),
        ])
        let (model, _) = try await make(transport)
        await model.refresh(context: shown)
        try model.set(value: 1, aspect: .selection, context: shown)
        XCTAssertEqual(model.record(for: shown).pending["selection"]?.value, 1)
        await model.synchronize()
        XCTAssertEqual(model.record(for: shown).snapshot.selection, PilotFeedbackValue(value: 1, revision: 1))
        XCTAssertTrue(model.record(for: shown).pending.isEmpty)
        try model.set(value: nil, aspect: .selection, context: shown)
        await model.synchronize()
        XCTAssertEqual(model.record(for: shown).snapshot.selection, PilotFeedbackValue(value: nil, revision: 2))
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "PUT", "GET", "DELETE"])
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "X-Expected-Revision"), "0")
        XCTAssertEqual(requests[5].value(forHTTPHeaderField: "X-Expected-Revision"), "1")
        XCTAssertEqual(requests[5].url?.path, "/v2/articles/44444444-4444-4444-4444-444444444444/feedback/relevance")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-a" })
        let (restarted, _) = try await make(FeedbackTransport([]))
        try restarted.load(context: shown)
        XCTAssertEqual(restarted.record(for: shown).snapshot.selection.revision, 2)
    }

    func testOfflineChangesCoalesceAndResumeAfterRestart() async throws {
        let (offline, _) = try await make(FeedbackTransport([.failure(URLError(.notConnectedToInternet))]))
        try offline.set(value: 1, aspect: .selection, context: shown)
        try offline.set(value: -1, aspect: .selection, context: shown)
        await offline.synchronize()
        XCTAssertNotNil(offline.error(for: shown))
        let transport = FeedbackTransport([reply(snapshot()), reply("", status: 204, revision: "1")])
        let (restarted, _) = try await make(transport)
        await restarted.synchronize()
        XCTAssertEqual(restarted.record(for: shown).snapshot.selection.value, -1)
        XCTAssertTrue(restarted.record(for: shown).pending.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try body(requests[1])["value"] as? Int, -1)
    }

    func testLostWriteResponseReloadsAndDoesNotResubmitAlreadySavedVote() async throws {
        let first = FeedbackTransport([reply(snapshot()), .failure(URLError(.networkConnectionLost))])
        let (model, _) = try await make(first)
        try model.set(value: 1, aspect: .selection, context: shown)
        await model.synchronize()
        XCTAssertNotNil(model.record(for: shown).pending["selection"])
        let afterRestart = FeedbackTransport([reply(snapshot(1, 1))])
        let (restarted, _) = try await make(afterRestart)
        await restarted.synchronize()
        XCTAssertTrue(restarted.record(for: shown).pending.isEmpty)
        let requests = await afterRestart.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
    }

    func testAnotherDevicesNewerVoteRequiresFreshUserChoice() async throws {
        let transport = FeedbackTransport([
            reply(snapshot()), reply(snapshot(1, 1)), reply(snapshot(nil, 2)), reply(snapshot(nil, 2)),
            reply("", status: 204, revision: "3"),
        ])
        let (model, _) = try await make(transport)
        await model.refresh(context: shown)
        try model.set(value: -1, aspect: .selection, context: shown)
        await model.synchronize()
        XCTAssertTrue(model.record(for: shown).conflicts.contains("selection"))
        XCTAssertTrue(model.record(for: shown).pending.isEmpty)
        XCTAssertEqual(model.record(for: shown).snapshot.selection.revision, 2)
        let beforeChoice = await transport.requests
        XCTAssertEqual(beforeChoice.count, 3)
        try model.set(value: -1, aspect: .selection, context: shown)
        await model.synchronize()
        XCTAssertEqual(model.record(for: shown).snapshot.selection.value, -1)
        XCTAssertTrue(model.record(for: shown).conflicts.isEmpty)
    }

    func testServerConflictDuringWriteReloadsWithoutAutomaticOverwrite() async throws {
        let transport = FeedbackTransport([
            reply(snapshot()), reply("{\"error\":\"feedback_conflict\"}", status: 409), reply(snapshot(-1, 1)),
        ])
        let (model, _) = try await make(transport)
        try model.set(value: 1, aspect: .selection, context: shown)
        await model.synchronize()
        XCTAssertEqual(model.record(for: shown).snapshot.selection.value, -1)
        XCTAssertTrue(model.record(for: shown).conflicts.contains("selection"))
        XCTAssertTrue(model.record(for: shown).pending.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT", "GET"])
    }

    func testOldAccountQueueCannotBeReadOrSentByAnotherAccount() async throws {
        let (a, _) = try await make(FeedbackTransport([]))
        try a.set(value: 1, aspect: .selection, context: shown)
        a.invalidate()
        let bTransport = FeedbackTransport([])
        let (b, _) = try await make(bTransport, account: userB)
        await b.synchronize()
        XCTAssertTrue(b.record(for: shown).pending.isEmpty)
        let requests = await bTransport.requests
        XCTAssertTrue(requests.isEmpty)
        let (backToA, _) = try await make(
            FeedbackTransport([reply(snapshot()), reply("", status: 204, revision: "1")]))
        await backToA.synchronize()
        XCTAssertEqual(backToA.record(for: shown).snapshot.selection.value, 1)
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
        try a.set(value: 1, aspect: .selection, context: shown)
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
        try b.set(value: -1, aspect: .brief, context: shown)
        await b.synchronize()
        await aTransport.respond(0, body: snapshot())
        await oldSync.value
        XCTAssertTrue(a.records.isEmpty)
        XCTAssertNil(b.record(for: shown).snapshot.selection.value)
        XCTAssertEqual(b.record(for: shown).snapshot.brief.value, -1)
        let aRequests = await aTransport.requests
        let bRequests = await bTransport.requests
        XCTAssertEqual(aRequests.count, 1, "The late read must never trigger A's queued write")
        XCTAssertTrue(bRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-b" })
        XCTAssertEqual(bRequests[1].url?.query, "brief_id=55555555-5555-5555-5555-555555555555")

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
        XCTAssertEqual(returned.record(for: shown).snapshot.selection.value, 1)
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
        let revision = try await client.set(value: 1, target: PilotFeedbackTarget(identity: identity, aspect: .brief), expectedRevision: 2)
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
        try model.set(value: 1, aspect: .selection, context: shown)
        let store = PilotFeedbackStore(root: root, identity: userA, user: userA)
        let damaged = store.directory.appendingPathComponent("2026-10-17.json")
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("invalid JSON".utf8).write(to: damaged)
        await model.synchronize()
        XCTAssertTrue(model.record(for: shown).pending.isEmpty)
        XCTAssertEqual(model.record(for: shown).snapshot.selection.value, 1)
        XCTAssertNotNil(model.errors["2026-10-17"])
        XCTAssertEqual(
            try String(contentsOf: damaged, encoding: .utf8), "invalid JSON", "Keep damaged data for recovery")
    }

    func testInvalidationDuringReadDiscardsResponseAndPreventsQueuedWrite() async throws {
        let transport = PausedTransport()
        let (model, _) = try await make(transport)
        try model.set(value: 1, aspect: .selection, context: shown)
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
        try model.set(value: 1, aspect: .selection, context: shown)
        await model.synchronize()
        XCTAssertTrue(denied)
        XCTAssertFalse(model.isActive)
        XCTAssertThrowsError(try model.set(value: -1, aspect: .selection, context: shown))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testMalformedSnapshotAndMissingMutationRevisionNeverClaimSaved() async throws {
        let invalid = FeedbackTransport([reply(snapshot()), reply(snapshot(1, 0))])
        let (model, _) = try await make(invalid)
        await model.refresh(context: shown)
        XCTAssertNotNil(model.error(for: shown))
        let missingHeader = FeedbackTransport([reply(snapshot()), reply("", status: 204)])
        let (pending, _) = try await make(missingHeader)
        try pending.set(value: 1, aspect: .selection, context: shown)
        await pending.synchronize()
        XCTAssertNotNil(pending.record(for: shown).pending["selection"])
        XCTAssertNotNil(pending.error(for: shown))
    }
}
