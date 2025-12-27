import Foundation

// MARK: - API Service
actor APIService {
    private let baseURL = "https://storage.googleapis.com/se-agent-summaries"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetch summaries from the API
    func fetchSummaries() async throws -> [Summary] {
        let url = URL(string: "\(baseURL)/summaries.json")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode([Summary].self, from: data)
    }

    /// Fetch full markdown content for an article
    func fetchMarkdown(for summary: Summary) async throws -> String {
        // Extract filename from URL or use a hashed version
        let filename = summary.url.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? summary.id
        let url = URL(string: "\(baseURL)/markdown/\(filename).md")!

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw APIError.decodingError
        }

        return content
    }
}

// MARK: - API Errors
enum APIError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingError
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let statusCode):
            return "Server returned error: \(statusCode)"
        case .decodingError:
            return "Failed to decode response"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
