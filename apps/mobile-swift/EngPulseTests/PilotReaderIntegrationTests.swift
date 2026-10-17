import XCTest
import Combine
@testable import EngPulse

final class PilotReaderIntegrationTests: XCTestCase {
    @MainActor
    func testReturningReaderPublishesSavedArticlesBeforeAnyNetworkResponse() async throws {
        let root = try root()
        let identity = UUID()
        let user = UUID()
        let credentials = PilotCredentials(accessToken: "test", refreshToken: "test", expiresAt: 4102444800,
            identity: PilotIdentity(id: identity, email: "pilot@example.com"))
        let receipt = Data("{\"identity\":\"\(identity)\",\"feed\":\"engineering\",\"user\":{\"id\":\"\(user)\",\"email\":\"pilot@example.com\",\"is_admin\":false}}".utf8)
        let config = PilotConfiguration(supabaseURL: URL(string: "https://auth.invalid")!, publishableKey: "public-test",
            apiURL: URL(string: "https://api.invalid/v1")!)
        let auth = PilotAuthClient(configuration: config, transport: OfflineTransport(),
            storage: ReaderTestCredentials(data: try JSONEncoder().encode(credentials)))
        let transport = StartupTransport()
        let api = PilotAPIClient(configuration: config, auth: auth, transport: transport)
        let model = PilotAccountModel(auth: auth, api: api, admissionStorage: ReaderTestCredentials(data: receipt))
        let store = PilotFeedStore(root: root, identity: identity, user: user)
        try await store.save([PilotBriefSummary(date: "2026-10-17", title: "Saved engineering brief",
            articleURL: "https://example.com/article", snippet: "Ready to read", model: nil, evalScore: nil)])
        let services = AppServices(account: model, api: api, cacheRoot: root)
        let ready = expectation(description: "Cached reader is ready without a network response")
        var firstTitles: [String]?
        let observation = services.$pilotReader.compactMap { $0 }.prefix(1).sink { context in
            firstTitles = context.appState.summaries.map(\.title)
            ready.fulfill()
        }
        let restore = Task { await model.restore() }
        await transport.waitForRequest()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(firstTitles, ["Saved engineering brief"], "The first visible reader must already contain saved articles")
        let reader = services.pilotReader
        await transport.respond(status: 503)
        await restore.value
        XCTAssertTrue(reader === services.pilotReader, "Background verification must preserve the displayed reader during an outage")
        await model.signOut()
        XCTAssertNil(services.pilotReader)
        XCTAssertTrue(reader?.appState.summaries.isEmpty ?? false)
        withExtendedLifetime(observation) {}
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testAccountCacheDirectoriesNeverShareArticlesAudioOrLists() async throws {
        let root = try root()
        let first = CacheService(directory: root.appendingPathComponent("a"))
        let second = CacheService(directory: root.appendingPathComponent("b"))
        let key = UUID().uuidString
        try await first.cacheContent("account-a", for: key)
        try await first.cacheAudio(Data([1, 2, 3]), for: key)
        try await first.cacheSummaries([.preview])
        let content = await second.getCachedContent(for: key)
        let audio = await second.getCachedAudioURL(for: key)
        let list = try await second.getCachedSummaries()
        XCTAssertNil(content)
        XCTAssertNil(audio)
        XCTAssertEqual(list, [])
        await second.clearAll()
        let preserved = await first.getCachedContent(for: key)
        XCTAssertEqual(preserved, "account-a")
    }

    func testScopedContentProviderOverridesLegacyCacheAndURL() async throws {
        let summary = Summary(date: "2026-10-17", url: UUID().uuidString, title: "Pilot")
        let cache = CacheService(directory: try root()) { item in
            XCTAssertEqual(item.date, "2026-10-17")
            return "authenticated payload"
        }
        try await cache.cacheContent("legacy public payload", for: summary.url)
        let content = try await ArticleContentLoader.load(summary, cacheService: cache)
        XCTAssertEqual(content, "authenticated payload")
    }

    func testDeniedScopedProviderCannotFallBackToCachedPublicArticle() async throws {
        let summary = Summary(date: "2026-10-17", url: UUID().uuidString, title: "Pilot")
        let cache = CacheService(directory: try root()) { _ in throw PilotError.accessDenied }
        try await cache.cacheContent("legacy public payload", for: summary.url)
        do {
            _ = try await ArticleContentLoader.load(summary, cacheService: cache)
            XCTFail("Denied pilot content must not use the public cache or network")
        } catch { XCTAssertEqual(error as? PilotError, .accessDenied) }
    }
    @MainActor
    private func context(root: URL, user: UUID = UUID()) async throws -> PilotReaderContext {
        let identity = PilotIdentity(id: UUID(), email: "pilot@example.com")
        let credentials = PilotCredentials(accessToken: "test", refreshToken: "test", expiresAt: 4102444800, identity: identity)
        let config = PilotConfiguration(supabaseURL: URL(string: "https://auth.invalid")!, publishableKey: "public-test",
            apiURL: URL(string: "https://api.invalid/v1")!)
        let auth = PilotAuthClient(configuration: config, transport: OfflineTransport(),
            storage: ReaderTestCredentials(data: try JSONEncoder().encode(credentials)))
        let session = try await auth.currentSession()
        return PilotReaderContext(api: PilotAPIClient(configuration: config, auth: auth, transport: OfflineTransport()),
            session: try XCTUnwrap(session), user: PilotUser(id: user, email: "pilot@example.com", isAdmin: false), root: root)
    }

    @MainActor
    func testPhoneReaderMapsSavedAPIListAndScopesPlaybackIdentity() async throws {
        let root = try root()
        let first = try await context(root: root)
        let second = try await context(root: root)
        let row = PilotBriefSummary(date: "2026-10-17", title: "API brief", articleURL: "https://example.com/article",
            snippet: "Engineering", model: "test-model", evalScore: 0.9)
        try await first.reader.store.save([row])
        try await second.reader.store.save([row])
        await first.appState.loadSummaries()
        await second.appState.loadSummaries()
        let a = try XCTUnwrap(first.appState.summaries.first)
        let b = try XCTUnwrap(second.appState.summaries.first)
        XCTAssertEqual(a.title, row.title)
        XCTAssertEqual(a.originalUrl, row.articleURL)
        XCTAssertTrue(a.isInsightBrief)
        XCTAssertNotEqual(a.url, b.url, "Playback positions must belong to one account")
        XCTAssertTrue(first.appState.isOffline)
        XCTAssertNil(first.appState.errorMessage)
        first.invalidate(); second.invalidate()
    }

    @MainActor
    func testContextInvalidationClearsReaderAndStopsQueuedPlayback() async throws {
        let context = try await context(root: root())
        context.appState.summaries = [.preview]
        context.ttsService.playQueue([.preview])
        XCTAssertEqual(context.ttsService.state, .loading)
        context.invalidate()
        XCTAssertFalse(context.reader.isActive)
        XCTAssertTrue(context.appState.summaries.isEmpty)
        XCTAssertNil(context.ttsService.currentArticleUrl)
        XCTAssertEqual(context.ttsService.state, .stopped)
        XCTAssertTrue(context.ttsService.queue.isEmpty)
        do {
            _ = try await ArticleContentLoader.load(.preview, cacheService: context.appState.cacheService)
            XCTFail("Old screens cannot load content after logout")
        } catch { XCTAssertEqual(error as? PilotError, .sessionChanged) }
        context.ttsService.playQueue([.preview])
        XCTAssertEqual(context.ttsService.state, .stopped, "Stale UI commands cannot restart a signed-out player")
        XCTAssertTrue(context.ttsService.queue.isEmpty)
        context.ttsService.stop()
    }

    @MainActor
    func testSharedServicesOpenReaderOnAdmissionAndCloseItOnLogout() async throws {
        let identity = PilotIdentity(id: UUID(), email: "pilot@example.com")
        let credentials = PilotCredentials(accessToken: "test", refreshToken: "test", expiresAt: 4102444800, identity: identity)
        let config = PilotConfiguration(supabaseURL: URL(string: "https://auth.invalid")!, publishableKey: "public-test",
            apiURL: URL(string: "https://api.invalid/v1")!)
        let auth = PilotAuthClient(configuration: config, transport: OfflineTransport(),
            storage: ReaderTestCredentials(data: try JSONEncoder().encode(credentials)))
        let api = PilotAPIClient(configuration: config, auth: auth, transport: UserTransport())
        let model = PilotAccountModel(auth: auth, api: api)
        let services = AppServices(account: model, api: api, cacheRoot: try root())
        let ready = expectation(description: "Reader preparation completes")
        let observation = services.$pilotReader.compactMap { $0 }.prefix(1).sink { _ in ready.fulfill() }
        XCTAssertNil(services.pilotReader)
        await model.restore()
        await fulfillment(of: [ready], timeout: 2)
        let reader = try XCTUnwrap(services.pilotReader)
        await model.restore()
        XCTAssertTrue(reader === services.pilotReader, "Refreshing the same admission preserves playback")
        reader.appState.summaries = [.preview]
        await model.signOut()
        XCTAssertNil(services.pilotReader)
        XCTAssertFalse(reader.reader.isActive)
        XCTAssertTrue(reader.appState.summaries.isEmpty)
        withExtendedLifetime(observation) {}
    }

}


private struct ReaderTestCredentials: PilotCredentialStorage {
    let data: Data
    func read() throws -> Data? { data }
    func write(_ data: Data?) throws {}
}
private struct OfflineTransport: PilotTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) { throw URLError(.notConnectedToInternet) }
}

private struct UserTransport: PilotTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.lastPathComponent == "feeds" {
            return (Data(#"[{"id":"33333333-3333-3333-3333-333333333333","slug":"engineering","is_active":true,"member":true}]"#.utf8), 200)
        }
        return (Data(#"{"id":"11111111-1111-1111-1111-111111111111","email":"pilot@example.com","is_admin":false}"#.utf8), 200)
    }
}

private actor StartupTransport: PilotTransport {
    private var pending: CheckedContinuation<(Data, Int), Error>?
    private var observer: CheckedContinuation<Void, Never>?
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.lastPathComponent == "me" else { throw PilotError.invalidResponse }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            observer?.resume(); observer = nil
        }
    }
    func waitForRequest() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func respond(status: Int) {
        pending?.resume(returning: (Data("{}".utf8), status)); pending = nil
    }
}
