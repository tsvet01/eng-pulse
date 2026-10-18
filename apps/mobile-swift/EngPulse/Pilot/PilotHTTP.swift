import Foundation

struct PilotConfiguration: Sendable {
    let supabaseURL: URL
    let publishableKey: String
    let apiURL: URL

    static func from(bundle: Bundle = .main) throws -> Self {
        guard let key = bundle.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
              !key.isEmpty, !key.contains("$("), key != "YOUR_PUBLISHABLE_KEY" else {
            throw PilotError.configuration
        }
        return Self(supabaseURL: URL(string: "https://zimjnykjqsxwsidwmemd.supabase.co")!,
                    publishableKey: key, apiURL: URL(string: "https://api.eng-pulse.tsvetkov.org/v1")!)
    }
}

enum PilotError: Error, Equatable, LocalizedError {
    case secureStorage, configuration, signInRequired, sessionChanged, inviteRequired, accessDenied
    case invalidCode, invalidInvite, accountConflict, feedbackConflict, rateLimited, unavailable, invalidResponse

    var errorDescription: String? {
        switch self {
        case .secureStorage: return "Unlock your device and try again. Your session could not be saved securely."
        case .configuration: return "Sign-in is not configured in this build."
        case .signInRequired: return "Please sign in again."
        case .sessionChanged: return "Your account changed. Please try again."
        case .inviteRequired: return "Enter your pilot invitation code to continue."
        case .accessDenied: return "This account does not have pilot access."
        case .invalidCode: return "The code is invalid or expired. Request a new code and try again."
        case .invalidInvite: return "That invitation is invalid, expired, or already used."
        case .accountConflict: return "This email already has an account. Use your original sign-in method."
        case .feedbackConflict: return "This rating changed on another device. Review it before choosing again."
        case .rateLimited: return "Please wait a moment before trying again."
        case .unavailable: return "The service is temporarily unavailable. Please try again."
        case .invalidResponse: return "The service returned an unreadable response."
        }
    }
}

struct PilotHTTPResponse: Sendable {
    let data: Data
    let status: Int
    var headers: [String: String] = [:]
}

protocol PilotTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
    func sendResponse(_ request: URLRequest) async throws -> PilotHTTPResponse
}

extension PilotTransport {
    func sendResponse(_ request: URLRequest) async throws -> PilotHTTPResponse {
        let (data, status) = try await send(request)
        return PilotHTTPResponse(data: data, status: status)
    }
}

final class PilotURLTransport: PilotTransport, @unchecked Sendable {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let response = try await sendResponse(request)
        return (response.data, response.status)
    }

    func sendResponse(_ request: URLRequest) async throws -> PilotHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PilotError.invalidResponse }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { values, entry in
            if let name = entry.key as? String { values[name.lowercased()] = String(describing: entry.value) }
        }
        return PilotHTTPResponse(data: data, status: http.statusCode, headers: headers)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
