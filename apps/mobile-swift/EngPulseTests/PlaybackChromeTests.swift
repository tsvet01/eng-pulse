import XCTest
@testable import EngPulse

final class PlaybackChromeTests: XCTestCase {
    func testArticleScreenOwnsTheSessionWithoutASwitchAction() {
        let chrome = PlaybackChrome.forArticle(
            onScreenURL: "a",
            onScreenTitle: "Article A",
            playingURL: "a",
            playingTitle: "Article A",
            state: .playing,
            canStartOnScreenArticle: true
        )

        let expected: PlaybackChrome? = PlaybackChrome(
            title: "Article A",
            nowPlayingLabel: nil,
            secondaryActionTitle: nil,
            secondaryActionHint: nil,
            secondaryActionEnabled: false
        )
        XCTAssertEqual(chrome, expected)
    }

    func testFinishedArticleKeepsAReplayBar() {
        let chrome = PlaybackChrome.forArticle(
            onScreenURL: "a",
            onScreenTitle: "Article A",
            playingURL: "a",
            playingTitle: "Article A",
            state: .stopped,
            canStartOnScreenArticle: true
        )

        XCTAssertEqual(chrome?.title, "Article A")
        XCTAssertNil(chrome?.nowPlayingLabel)
        XCTAssertNil(chrome?.secondaryActionTitle)
    }

    func testOtherArticleNamesWhatIsPlayingAndOffersToStartThisOne() {
        for state in [TTSState.playing, .paused, .loading] {
            let chrome = PlaybackChrome.forArticle(
                onScreenURL: "b",
                onScreenTitle: "Article B",
                playingURL: "a",
                playingTitle: "Article A",
                state: state,
                canStartOnScreenArticle: true
            )

            let expected: PlaybackChrome? = PlaybackChrome(
                title: "Article A",
                nowPlayingLabel: "Now playing",
                secondaryActionTitle: "Play this article",
                secondaryActionHint: "Stops the article that is playing and starts this one",
                secondaryActionEnabled: true
            )
            XCTAssertEqual(chrome, expected, "active state \(state)")
        }
    }

    func testPlayThisArticleStaysVisibleButDisabledUntilContentIsReady() {
        let chrome = PlaybackChrome.forArticle(
            onScreenURL: "b",
            onScreenTitle: "Article B",
            playingURL: "a",
            playingTitle: "Article A",
            state: .playing,
            canStartOnScreenArticle: false
        )

        XCTAssertEqual(chrome?.secondaryActionTitle, "Play this article")
        XCTAssertEqual(chrome?.secondaryActionEnabled, false)
    }

    func testMissingPlayingTitleFallsBackToTheAppName() {
        let chrome = PlaybackChrome.forArticle(
            onScreenURL: "b",
            onScreenTitle: "Article B",
            playingURL: "a",
            playingTitle: nil,
            state: .paused,
            canStartOnScreenArticle: true
        )

        XCTAssertEqual(chrome?.title, "Eng Pulse")
    }

    func testStoppedSessionDoesNotFollowTheUserOntoAnotherArticle() {
        let chrome = PlaybackChrome.forArticle(
            onScreenURL: "b",
            onScreenTitle: "Article B",
            playingURL: "a",
            playingTitle: "Article A",
            state: .stopped,
            canStartOnScreenArticle: true
        )

        XCTAssertNil(chrome)
    }

    func testLibraryShowsTheActiveSessionAndAWayBack() {
        let chrome = PlaybackChrome.forLibrary(
            playingURL: "a",
            playingTitle: "Article A",
            state: .playing,
            canOpenArticle: true
        )

        let expected: PlaybackChrome? = PlaybackChrome(
            title: "Article A",
            nowPlayingLabel: "Now playing",
            secondaryActionTitle: "Open article",
            secondaryActionHint: "Returns to the article that is playing",
            secondaryActionEnabled: true
        )
        XCTAssertEqual(chrome, expected)
    }

    func testLibraryHidesOpenWhenTheArticleIsNotInTheFeed() {
        let chrome = PlaybackChrome.forLibrary(
            playingURL: "a",
            playingTitle: "Article A",
            state: .paused,
            canOpenArticle: false
        )

        XCTAssertEqual(chrome?.nowPlayingLabel, "Now playing")
        XCTAssertNil(chrome?.secondaryActionTitle)
        XCTAssertEqual(chrome?.secondaryActionEnabled, false)
    }

    func testLibraryHidesTheBarWhenNothingIsActive() {
        XCTAssertNil(PlaybackChrome.forLibrary(
            playingURL: "a",
            playingTitle: "Article A",
            state: .stopped,
            canOpenArticle: true
        ))
        XCTAssertNil(PlaybackChrome.forLibrary(
            playingURL: nil,
            playingTitle: nil,
            state: .playing,
            canOpenArticle: false
        ))
    }
}
