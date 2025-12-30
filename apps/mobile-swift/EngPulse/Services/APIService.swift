import Foundation

// MARK: - API Service
actor APIService {
    private let baseURL = "https://storage.googleapis.com/tsvet01-agent-brain"
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
        } else {
            // Configure session with reasonable timeouts
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: config)
        }
    }

    /// Fetch summaries from the manifest
    func fetchSummaries() async throws -> [Summary] {
        guard let url = URL(string: "\(baseURL)/manifest.json") else {
            throw APIError.invalidURL
        }
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
        // summary.url is already the full GCS URL to the markdown file
        guard let url = URL(string: summary.url) else {
            throw APIError.invalidURL
        }

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
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingError
    case noConnection

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Unable to load content"
        case .invalidResponse:
            return "Server is not responding correctly"
        case .httpError(let statusCode):
            switch statusCode {
            case 404:
                return "Content not found"
            case 500...599:
                return "Server is temporarily unavailable"
            default:
                return "Unable to load content (Error \(statusCode))"
            }
        case .decodingError:
            return "Unable to read content"
        case .noConnection:
            return "No internet connection"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noConnection:
            return "Please check your connection and try again"
        case .httpError(500...599):
            return "Please try again later"
        default:
            return "Pull down to refresh"
        }
    }
}
