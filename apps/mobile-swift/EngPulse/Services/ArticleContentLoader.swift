import Foundation

// MARK: - Article Content Loader
/// Loads full article content (cache first, then network) outside of any view,
/// so playlist and CarPlay playback can fetch articles without a visible screen.
struct ArticleContentLoader {
    enum LoadError: LocalizedError {
        case invalidURL
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid article URL"
            case .decodingFailed: return "Could not decode article content"
            }
        }
    }

    static func load(_ summary: Summary, cacheService: CacheService) async throws -> String {
        if let cached = await cacheService.getCachedContent(for: summary.url) {
            return cached
        }

        guard let url = URL(string: summary.url) else {
            throw LoadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let content = String(data: data, encoding: .utf8) else {
            throw LoadError.decodingFailed
        }

        try? await cacheService.cacheContent(content, for: summary.url)
        return content
    }
}
