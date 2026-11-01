import Foundation
import XCTest
@testable import PilotCore

private func preferencesJSON(revision: Int = 0, interests: [String] = []) -> String {
    let values = interests.map { "\"\($0)\"" }.joined(separator: ",")
    return """
    {"preferences":{"interests":[\(values)],"depth_by_topic":{},"excluded_topics":[]},"revision":\(revision),"learned_reset_at":null,"topics":[{"id":"platform","name":"Platform","description":"Infrastructure"},{"id":"security","name":"Security","description":"Defence"}]}
    """
}

@MainActor
final class PilotPreferencesTests: XCTestCase {
    private func make(_ transport: any PilotTransport) async throws -> (PilotPreferencesModel, PilotAuthClient) {
        let auth = PilotAuthClient(configuration: .test, transport: RecordingTransport([]),
            storage: MemoryCredentials(data: try JSONEncoder().encode(testSession())))
        let api = PilotAPIClient(configuration: .test, auth: auth, transport: transport)
        let session = try await auth.currentSession()
        return (PilotPreferencesModel(api: api, session: try XCTUnwrap(session)), auth)
    }

    func testLoadsAndSavesOwnPreferencesWithRevisionAtV2Path() async throws {
        let transport = RecordingTransport([.ok(preferencesJSON()), .ok(preferencesJSON(revision: 1, interests: ["platform"]))])
        let (model, _) = try await make(transport)
        await model.load()
        model.setChoice(.interested, topic: "platform")
        await model.save()
        XCTAssertEqual(model.saved?.revision, 1)
        XCTAssertFalse(model.hasChanges)
        XCTAssertNil(model.errorMessage)
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v2/me/preferences", "/v2/me/preferences"])
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-Expected-Revision"), "0")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer access-a")
        let payload = try body(requests[1])
        XCTAssertNil(payload["user_id"])
        XCTAssertEqual((payload["preferences"] as? [String: Any])?["interests"] as? [String], ["platform"])
    }

    func testConflictKeepsDraftAndRequiresReloadBeforeSavingAgain() async throws {
        let transport = RecordingTransport([.ok(preferencesJSON()), .response(409, "{\"error\":\"preference_conflict\"}"), .ok(preferencesJSON(revision: 2, interests: ["security"]))])
        let (model, _) = try await make(transport)
        await model.load()
        model.setChoice(.interested, topic: "platform")
        await model.save()
        XCTAssertEqual(model.draft.interests, ["platform"])
        XCTAssertTrue(model.needsReload)
        XCTAssertEqual(model.errorMessage, PilotError.preferenceConflict.localizedDescription)
        await model.save()
        let beforeReload = await transport.requests
        XCTAssertEqual(beforeReload.count, 2)
        await model.load(discardDraft: true)
        XCTAssertEqual(model.draft.interests, ["security"])
        XCTAssertFalse(model.needsReload)
    }

    func testLateAccountResponseCannotRestoreInvalidatedPreferences() async throws {
        let transport = PausedTransport()
        let (model, auth) = try await make(transport)
        let work = Task { await model.load() }
        await transport.waitForRequests(1)
        model.invalidate()
        try await auth.signOut()
        await transport.respond(0, body: preferencesJSON(revision: 2, interests: ["platform"]))
        await work.value
        XCTAssertNil(model.saved)
        XCTAssertTrue(model.draft.interests.isEmpty)
        await model.save()
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testRevocationIsReportedToAccountOwner() async throws {
        let (model, _) = try await make(RecordingTransport([.response(403, "{\"error\":\"forbidden\"}")]))
        var failure: PilotError?
        model.onAccessFailure = { failure = $0 }
        await model.load()
        XCTAssertEqual(failure, .accessDenied)
        XCTAssertNil(model.saved)
    }

    func testReopeningSettingsDoesNotDiscardUnsavedChoices() async throws {
        let transport = RecordingTransport([.ok(preferencesJSON()), .ok(preferencesJSON())])
        let (model, _) = try await make(transport)
        await model.load()
        model.setChoice(.interested, topic: "platform")
        await model.load()
        XCTAssertEqual(model.draft.interests, ["platform"])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testLostSaveResponseRequiresReadAndRecognisesCommittedChoices() async throws {
        let transport = RecordingTransport([.ok(preferencesJSON()), .failure(URLError(.networkConnectionLost)),
            .ok(preferencesJSON(revision: 1, interests: ["platform"]))])
        let (model, _) = try await make(transport)
        await model.load()
        model.setChoice(.interested, topic: "platform")
        await model.save()
        XCTAssertEqual(model.draft.interests, ["platform"])
        XCTAssertTrue(model.needsReload)
        XCTAssertNil(model.savedMessage)
        await model.save()
        await model.load()
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        await model.load(discardDraft: true)
        XCTAssertEqual(model.saved?.revision, 1)
        XCTAssertEqual(model.draft.interests, ["platform"])
        XCTAssertFalse(model.hasChanges)
        XCTAssertFalse(model.needsReload)
    }

    func testAvoidingTopicRemovesInterestAndDepthAndResetKeepsChoices() async throws {
        let transport = RecordingTransport([.ok(preferencesJSON()), .ok(preferencesJSON(revision: 1))])
        let (model, _) = try await make(transport)
        await model.load()
        model.setChoice(.interested, topic: "platform")
        model.setDepth(.advanced, topic: "platform")
        model.setChoice(.excluded, topic: "platform")
        XCTAssertTrue(model.draft.interests.isEmpty)
        XCTAssertTrue(model.draft.depthByTopic.isEmpty)
        XCTAssertEqual(model.draft.excludedTopics, ["platform"])
        await model.save(resetLearned: true)
        let requests = await transport.requests
        let payload = try body(requests[1])
        XCTAssertEqual(payload["reset_learned"] as? Bool, true)
        XCTAssertEqual((payload["preferences"] as? [String: Any])?["excluded_topics"] as? [String], ["platform"])
    }

    func testGeneratedContractDecodesAndAcceptsOverlappingInterests() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/contracts/preferences.json"))
        let snapshot = try JSONDecoder().decode(PilotPreferencesSnapshot.self, from: data)
        XCTAssertTrue(snapshot.isValid)
        XCTAssertEqual(snapshot.preferences.interests, ["cpu_performance", "platform"])
        XCTAssertEqual(snapshot.preferences.depthByTopic["cpu_performance"], .advanced)
    }
}
