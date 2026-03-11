import Foundation
import SwiftUI

@MainActor
class DetailViewModel: ObservableObject {
    let summary: Summary

    @Published var fullContent: String?
    @Published var isLoadingContent = false
    @Published var loadingError: String?

    private let ttsService: TTSService
    private let cacheService: CacheService?

    var isPlaying: Bool {
        ttsService.state == .playing && ttsService.currentArticleUrl == summary.url
    }

    var isPaused: Bool {
        ttsService.state == .paused && ttsService.currentArticleUrl == summary.url
    }

    var isLoadingTTS: Bool {
        ttsService.state == .loading && ttsService.currentArticleUrl == summary.url
    }

    init(summary: Summary, ttsService: TTSService, cacheService: CacheService? = nil) {
        self.summary = summary
        self.ttsService = ttsService
        self.cacheService = cacheService
    }

    func loadFullContent() async {
        loadingError = nil

        // Phase 1: Show cached content instantly (no spinner)
        if let cacheService = cacheService,
           let cached = await cacheService.getCachedContent(for: summary.url) {
            fullContent = cached
        }

        // Phase 2: Fetch fresh from network
        if fullContent == nil { isLoadingContent = true }
        defer { isLoadingContent = false }

        guard let url = URL(string: summary.url) else {
            if fullContent == nil { loadingError = "Invalid URL" }
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, _) = try await URLSession.shared.data(for: request)
            if let content = String(data: data, encoding: .utf8) {
                fullContent = content
                if let cacheService = cacheService {
                    try? await cacheService.cacheContent(content, for: summary.url)
                }
            } else if fullContent == nil {
                loadingError = "Could not decode content"
            }
        } catch {
            if fullContent == nil {
                if let error = error as? URLError, error.code == .timedOut {
                    loadingError = "Request timed out. Please try again."
                } else {
                    loadingError = "Unable to load content. Check your connection."
                }
            }
        }
    }

    func toggleTTS() {
        guard let content = fullContent else { return }
        ttsService.togglePlayPause(content, articleUrl: summary.url)
    }
}
