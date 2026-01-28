import Foundation
import SwiftUI

@MainActor
class DetailViewModel: ObservableObject {
    let summary: Summary

    @Published var fullContent: String?
    @Published var isLoadingContent = false
    @Published var loadingError: String?

    private let ttsService: TTSService

    var isPlaying: Bool {
        ttsService.state == .playing && ttsService.currentArticleUrl == summary.url
    }

    var isPaused: Bool {
        ttsService.state == .paused && ttsService.currentArticleUrl == summary.url
    }

    var isLoadingTTS: Bool {
        ttsService.state == .loading && ttsService.currentArticleUrl == summary.url
    }

    init(summary: Summary, ttsService: TTSService) {
        self.summary = summary
        self.ttsService = ttsService
    }

    func loadFullContent() async {
        isLoadingContent = true
        loadingError = nil
        defer { isLoadingContent = false }

        guard let url = URL(string: summary.url) else {
            loadingError = "Invalid URL"
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, _) = try await URLSession.shared.data(for: request)
            if let content = String(data: data, encoding: .utf8) {
                fullContent = content
            } else {
                loadingError = "Could not decode content"
            }
        } catch let error as URLError where error.code == .timedOut {
            loadingError = "Request timed out. Please try again."
        } catch {
            loadingError = "Unable to load content. Check your connection."
        }
    }

    func toggleTTS() {
        guard let content = fullContent else { return }
        if isPlaying {
            ttsService.stop()
        } else {
            ttsService.togglePlayPause(content, articleUrl: summary.url)
        }
    }
}
