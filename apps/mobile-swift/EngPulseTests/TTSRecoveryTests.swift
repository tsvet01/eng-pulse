import XCTest
import Combine
@testable import EngPulse

/// Faults are injected below the real cloud HTTP client, never into the recovery logic.
@MainActor
final class TTSRecoveryTests: XCTestCase {
    private var service: TTSService!
    private var cache: CacheService!
    private var player: PlaybackSpy!
    private var transport: PlaybackTransport!
    private var directory: URL!
    private var observations = Set<AnyCancellable>()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cache = CacheService(directory: directory)
        player = PlaybackSpy()
        transport = PlaybackTransport()
        service = TTSService(cacheService: cache,
                             cloudTTS: CloudTTSService(apiKey: "fixture-key", session: transport.session),
                             audioPlayer: player)
    }

    override func tearDown() async throws {
        service.stop()
        observations.removeAll()
        transport.close()
        service = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testRemotePlayRetriesFailedSingleArticleWithoutRestart() async {
        let first = expectRequest()
        service.startSpeaking("Article A", articleUrl: "fixture:A", articleTitle: "A")
        await fulfillment(of: [first], timeout: 2)
        let failed = expectError()
        transport.request(0).fail(URLError(.networkConnectionLost))
        await fulfillment(of: [failed], timeout: 2)

        let retry = expectRequest()
        service.resume() // The same entry point used by lock-screen Play.
        XCTAssertEqual(service.state, .loading)
        await fulfillment(of: [retry], timeout: 2)
        guard transport.count == 2 else { return }
        let playing = expectPlaying()
        transport.request(1).succeed()
        await fulfillment(of: [playing], timeout: 2)
        XCTAssertNil(service.errorMessage)
        XCTAssertEqual(service.currentArticleUrl, "fixture:A")
        XCTAssertEqual(player.playCount, 1)
    }

    func testPlayerBarRetriesFailedSingleArticle() async {
        let request = expectRequest()
        service.startSpeaking("Article A", articleUrl: "fixture:A")
        await fulfillment(of: [request], timeout: 2)
        let failed = expectError()
        transport.request(0).fail(URLError(.notConnectedToInternet))
        await fulfillment(of: [failed], timeout: 2)
        service.togglePauseResume()
        XCTAssertEqual(service.state, .loading, "The shared player button must retry a stopped item")
    }

    func testOldSameArticleFailureCannotStopNewAttempt() async {
        let first = expectRequest()
        service.startSpeaking("Article A", articleUrl: "fixture:A")
        await fulfillment(of: [first], timeout: 2)
        let staleError = expectation(description: "No error from superseded attempt")
        staleError.isInverted = true
        service.$errorMessage.compactMap { $0 }.sink { _ in staleError.fulfill() }.store(in: &observations)
        // Queue the transport failure BEFORE replacement cancels the old request.
        // The main actor cannot consume it until this test yields below.
        transport.request(0).fail(URLError(.networkConnectionLost))
        let second = expectRequest()
        service.startSpeaking("Article A", articleUrl: "fixture:A")
        await fulfillment(of: [second], timeout: 2)
        await fulfillment(of: [staleError], timeout: 0.2)
        let playing = expectPlaying()
        transport.request(1).succeed()
        await fulfillment(of: [playing], timeout: 2)
        XCTAssertEqual(player.playCount, 1)
        XCTAssertNil(service.errorMessage)
    }

    func testSwitchingArticlesCancelsOldDownloadAndPlaysNewArticle() async {
        let first = expectRequest()
        service.startSpeaking("Article A", articleUrl: "fixture:A")
        await fulfillment(of: [first], timeout: 2)
        let cancelled = expectation(description: "Old network request cancelled")
        transport.request(0).onStop = { cancelled.fulfill() }
        let second = expectRequest()
        service.togglePlayPause("Article B", articleUrl: "fixture:B")
        await fulfillment(of: [second, cancelled], timeout: 2)
        let playing = expectPlaying()
        transport.request(1).succeed()
        await fulfillment(of: [playing], timeout: 2)
        XCTAssertEqual(service.currentArticleUrl, "fixture:B")
        XCTAssertEqual(player.playCount, 1)
    }

    func testStopCancelsDownloadAndDoesNotPublishLateError() async {
        let first = expectRequest()
        service.startSpeaking("Article without URL")
        await fulfillment(of: [first], timeout: 2)
        let cancelled = expectation(description: "Stop cancels network request")
        transport.request(0).onStop = { cancelled.fulfill() }
        service.stop()
        await fulfillment(of: [cancelled], timeout: 2)
        transport.request(0).fail(URLError(.timedOut))
        let staleError = expectation(description: "Stopped playback has no late error")
        staleError.isInverted = true
        service.$errorMessage.compactMap { $0 }.sink { _ in staleError.fulfill() }.store(in: &observations)
        await fulfillment(of: [staleError], timeout: 0.2)
        XCTAssertEqual(service.state, .stopped)
        XCTAssertEqual(player.playCount, 0)
    }

    func testCloudOutageKeepsQueueOnCurrentArticle() async throws {
        let a = Summary(date: "2026-11-01", url: "fixture:A", title: "A")
        let b = Summary(date: "2026-11-01", url: "fixture:B", title: "B")
        try await cache.cacheContent("Article A", for: a.url)
        try await cache.cacheContent("Article B", for: b.url)
        let request = expectRequest()
        service.playQueue([a, b])
        await fulfillment(of: [request], timeout: 2)
        let failed = expectError()
        transport.request(0).respond(status: 503, body: Data(#"{"error":{"message":"Unavailable"}}"#.utf8))
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(service.queueIndex, 0, "An outage must not skip every queued article")
        XCTAssertEqual(service.state, .stopped)
        XCTAssertEqual(transport.count, 1)
    }

    func testHungDownloadTimesOutAndManualRetryRecovers() async {
        service.stop()
        service = TTSService(cacheService: cache,
                             cloudTTS: CloudTTSService(apiKey: "fixture-key", session: transport.session),
                             audioPlayer: player, startupTimeout: .milliseconds(150))
        let request = expectRequest()
        service.startSpeaking("Article A", articleUrl: "fixture:A")
        await fulfillment(of: [request], timeout: 2)
        // No headers, no bytes, no completion: a connected but unusable link.
        let failed = expectError()
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(service.state, .stopped)
        let retry = expectRequest()
        service.resume()
        await fulfillment(of: [retry], timeout: 2)
        guard transport.count == 2 else { return }
        let playing = expectPlaying()
        transport.request(1).succeed()
        await fulfillment(of: [playing], timeout: 2)
        XCTAssertNil(service.errorMessage)
    }

    func testCachedAudioPlaysWithoutAnotherNetworkRequest() async {
        let request = expectRequest()
        service.startSpeaking("Cached article", articleUrl: "fixture:cached")
        await fulfillment(of: [request], timeout: 2)
        let playing = expectPlaying()
        transport.request(0).succeed()
        await fulfillment(of: [playing], timeout: 2)
        service.stop()
        let unexpectedRequest = expectation(description: "Offline cached playback makes no request")
        unexpectedRequest.isInverted = true
        transport.onRequest = { unexpectedRequest.fulfill() }
        service.startSpeaking("Cached article", articleUrl: "fixture:cached")
        let cachedPlaying = expectPlaying()
        await fulfillment(of: [cachedPlaying], timeout: 2)
        await fulfillment(of: [unexpectedRequest], timeout: 0.2)
        XCTAssertEqual(player.playCount, 2)
        XCTAssertNil(service.errorMessage)
    }

    func testDelayedResponseStillPlaysWhenConnectionRecovers() async {
        let request = expectRequest()
        service.startSpeaking("Slow article", articleUrl: "fixture:slow")
        await fulfillment(of: [request], timeout: 2)
        XCTAssertEqual(service.state, .loading)
        XCTAssertEqual(player.playCount, 0)
        let playing = expectPlaying()
        transport.request(0).succeed()
        await fulfillment(of: [playing], timeout: 2)
        XCTAssertEqual(service.state, .playing)
        XCTAssertNil(service.errorMessage)
    }

    func testDeferredOldPlayerEventsCannotCancelNewStartup() async {
        // A native player update is queued for delivery on the main queue just
        // before the user switches articles. Its source is stopped synchronously.
        player.isPlaying = true
        let request = expectRequest()
        service.startSpeaking("New article", articleUrl: "fixture:new")
        await fulfillment(of: [request], timeout: 2)
        XCTAssertEqual(service.state, .loading)
        guard transport.count == 1 else { return }
        let playing = expectPlaying()
        transport.request(0).succeed()
        await fulfillment(of: [playing], timeout: 2)
        XCTAssertNil(service.errorMessage)
    }

    func testStopCannotBeUndoneByQueuedPlayingEvent() async {
        player.isPlaying = true
        service.stop()
        let resurrected = expectation(description: "Stop cannot be undone by an old player event")
        resurrected.isInverted = true
        service.$state.filter { $0 == .playing }.sink { _ in resurrected.fulfill() }.store(in: &observations)
        await fulfillment(of: [resurrected], timeout: 0.2)
        XCTAssertEqual(service.state, .stopped)
    }

    func testInvalidAudioSkipsOnlyThatArticleAndPlaysNext() async throws {
        service.stop()
        service = TTSService(cacheService: cache,
                             cloudTTS: CloudTTSService(apiKey: "fixture-key", session: transport.session),
                             audioPlayer: AudioPlayerService())
        let a = Summary(date: "2026-11-01", url: "fixture:bad", title: "Bad audio")
        let b = Summary(date: "2026-11-01", url: "fixture:good", title: "Good audio")
        try await cache.cacheContent("First article", for: a.url)
        try await cache.cacheContent("Second article", for: b.url)
        let first = expectRequest()
        service.playQueue([a, b])
        await fulfillment(of: [first], timeout: 2)
        let second = expectRequest()
        transport.request(0).succeed() // Valid JSON/base64, invalid audio file.
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(service.queueIndex, 1)
        guard transport.count == 2 else { return }
        let playing = expectPlaying()
        let body = try JSONSerialization.data(withJSONObject: ["audioContent": AudioPlayerRecoveryTests.tone().base64EncodedString()])
        transport.request(1).respond(status: 200, body: body)
        await fulfillment(of: [playing], timeout: 2)
        XCTAssertEqual(service.currentArticleUrl, b.url)
        XCTAssertNil(service.errorMessage)
    }

    private func expectRequest() -> XCTestExpectation {
        let result = expectation(description: "HTTP request starts")
        transport.onRequest = { result.fulfill() }
        return result
    }

    private func expectError() -> XCTestExpectation {
        let result = expectation(description: "Recoverable error")
        service.$errorMessage.compactMap { $0 }.prefix(1).sink { _ in result.fulfill() }.store(in: &observations)
        return result
    }

    private func expectPlaying() -> XCTestExpectation {
        let result = expectation(description: "Playback starts")
        service.$state.filter { $0 == .playing }.prefix(1).sink { _ in result.fulfill() }.store(in: &observations)
        return result
    }
}

@MainActor
private final class PlaybackSpy: AudioPlayerService {
    private(set) var playCount = 0
    override func play(from url: URL) throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        playCount += 1
        duration = 30
        isPlaying = true
    }
}

/// Each session has its own registry entry; unmatched requests never reach the network.
final class PlaybackTransport: @unchecked Sendable {
    private let id = UUID().uuidString
    private let lock = NSLock()
    private var requests: [PlaybackURLProtocol] = []
    private var callback: (@Sendable () -> Void)?
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlaybackURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Playback-Test": id]
        return URLSession(configuration: config)
    }()

    init() { PlaybackURLProtocol.register(self, id: id) }
    var onRequest: (@Sendable () -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }
    var count: Int { lock.withLock { requests.count } }
    func request(_ index: Int) -> PlaybackURLProtocol { lock.withLock { requests[index] } }
    func receive(_ request: PlaybackURLProtocol) {
        let action = lock.withLock {
            requests.append(request)
            let action = callback
            callback = nil
            return action
        }
        action?()
    }
    func close() {
        session.invalidateAndCancel()
        PlaybackURLProtocol.unregister(id: id)
    }
}

final class PlaybackURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var transports: [String: PlaybackTransport] = [:]
    private let lock = NSRecursiveLock()
    private var stopped = false
    private var stopCallback: (@Sendable () -> Void)?
    var onStop: (@Sendable () -> Void)? {
        get { lock.withLock { stopCallback } }
        set { lock.withLock { stopCallback = newValue } }
    }
    static func register(_ transport: PlaybackTransport, id: String) {
        registryLock.withLock { transports[id] = transport }
    }
    static func unregister(id: String) { _ = registryLock.withLock { transports.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let transport = Self.registryLock.withLock { Self.transports[request.value(forHTTPHeaderField: "X-Playback-Test") ?? ""] }
        guard let transport else { fail(URLError(.unsupportedURL)); return }
        transport.receive(self)
    }
    override func stopLoading() {
        lock.withLock {
            stopped = true
            stopCallback?()
            stopCallback = nil
        }
    }
    func fail(_ error: Error) {
        lock.withLock {
            guard !stopped else { return }
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    func succeed() {
        respond(status: 200, body: Data(#"{"audioContent":"AQIDBA=="}"#.utf8))
    }
    func respond(status: Int, body: Data) {
        lock.withLock {
            guard !stopped else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
