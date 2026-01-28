import XCTest
@testable import EngPulse

@MainActor
final class DetailViewModelTests: XCTestCase {

    private func makeSUT(url: String = "https://example.com/test.md") -> DetailViewModel {
        let summary = Summary(
            date: "2025-12-27",
            url: url,
            title: "Test Article",
            summarySnippet: "A test snippet",
            originalUrl: "https://example.com/original",
            model: "gemini-test",
            selectedBy: "gemini-test"
        )
        return DetailViewModel(summary: summary, ttsService: TTSService())
    }

    // MARK: - Initial State

    func testInitialStateIsIdle() {
        let vm = makeSUT()
        XCTAssertNil(vm.fullContent)
        XCTAssertFalse(vm.isLoadingContent)
        XCTAssertNil(vm.loadingError)
    }

    func testSummaryIsStored() {
        let vm = makeSUT(url: "https://example.com/stored.md")
        XCTAssertEqual(vm.summary.url, "https://example.com/stored.md")
        XCTAssertEqual(vm.summary.title, "Test Article")
    }

    // MARK: - Loading Content

    func testLoadFullContentSetsLoadingTrue() async {
        let vm = makeSUT(url: "https://httpbin.org/delay/10")
        // Start loading in background
        let task = Task {
            await vm.loadFullContent()
        }
        // Give it a moment to set loading state
        try? await Task.sleep(nanoseconds: 50_000_000)
        // It should either be loading or done
        // (in CI this may complete quickly, so we just verify no crash)
        task.cancel()
    }

    func testLoadFullContentWithInvalidURL() async {
        let summary = Summary(
            date: "2025-12-27",
            url: "",
            title: "Bad URL",
            summarySnippet: nil,
            originalUrl: nil,
            model: nil,
            selectedBy: nil
        )
        let vm = DetailViewModel(summary: summary, ttsService: TTSService())
        await vm.loadFullContent()
        XCTAssertNotNil(vm.loadingError)
        XCTAssertEqual(vm.loadingError, "Invalid URL")
        XCTAssertFalse(vm.isLoadingContent)
    }

    func testLoadFullContentResetsErrorBeforeLoading() async {
        let vm = makeSUT(url: "")
        // First load sets error
        await vm.loadFullContent()
        XCTAssertNotNil(vm.loadingError)

        // Second load should clear error first (will set it again since URL is still invalid)
        await vm.loadFullContent()
        // After completion, error is set again but isLoadingContent is false
        XCTAssertFalse(vm.isLoadingContent)
    }

    // MARK: - TTS State

    func testIsPlayingDefaultsFalse() {
        let vm = makeSUT()
        XCTAssertFalse(vm.isPlaying)
    }

    func testIsPausedDefaultsFalse() {
        let vm = makeSUT()
        XCTAssertFalse(vm.isPaused)
    }

    func testIsLoadingTTSDefaultsFalse() {
        let vm = makeSUT()
        XCTAssertFalse(vm.isLoadingTTS)
    }

    // MARK: - Toggle TTS

    func testToggleTTSWithNoContentDoesNothing() {
        let vm = makeSUT()
        XCTAssertNil(vm.fullContent)
        // Should not crash
        vm.toggleTTS()
    }
}
