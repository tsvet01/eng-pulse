import Foundation

// MARK: - Article Content Loader
/// Loads full article content (cache first, then network) outside of any view,
/// so playlist and CarPlay playback can fetch articles without a visible screen.
struct ArticleContentLoader {
    enum LoadError: LocalizedError {
        case invalidURL
        case decodingFailed
        case httpError(statusCode: Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid article URL"
            case .decodingFailed: return "Could not decode article content"
            case .httpError(let statusCode): return "Could not load article (HTTP \(statusCode))"
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
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            // Don't speak or cache an error page as article content
            throw LoadError.httpError(statusCode: httpResponse.statusCode)
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw LoadError.decodingFailed
        }

        try? await cacheService.cacheContent(content, for: summary.url)
        return content
    }
}
