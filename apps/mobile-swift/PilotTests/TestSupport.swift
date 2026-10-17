import Foundation
import XCTest
@testable import PilotCore

let userA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
let userB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
extension PilotConfiguration {
    static let test = PilotConfiguration(supabaseURL: URL(string: "https://auth.example.com")!,
        publishableKey: "public-test-key", apiURL: URL(string: "https://api.example.com/v1")!)
}
func sessionJSON(access: String = "access-a", refresh: String = "refresh-a", user: UUID = userA) -> String {
    """
    {"access_token":"\(access)","refresh_token":"\(refresh)","token_type":"bearer","expires_in":3600,"expires_at":4102444800,"user":{"id":"\(user.uuidString)","email":"pilot@example.com"}}
    """
}
func testSession(expiresAt: TimeInterval = 4102444800) -> PilotCredentials {
    PilotCredentials(accessToken: "access-a", refreshToken: "refresh-a", expiresAt: expiresAt,
        identity: PilotIdentity(id: userA, email: "pilot@example.com"))
}
func body(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
}
final class MemoryCredentials: PilotCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    init(data: Data? = nil) { self.data = data }
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func write(_ data: Data?) throws { lock.lock(); defer { lock.unlock() }; self.data = data }
}
actor RecordingTransport: PilotTransport {
    enum Reply {
        case response(Int, String)
        case failure(Error)
        static func ok(_ body: String) -> Reply { .response(200, body) }
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func firstRequest() -> URLRequest? { requests.first }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        switch replies.removeFirst() {
        case .response(let status, let body): return (Data(body.utf8), status)
        case .failure(let error): throw error
        }
    }
}

actor PausedTransport: PilotTransport {
    private(set) var requests: [URLRequest] = []
    private var pending: [Int: CheckedContinuation<(Data, Int), Error>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            let ready = observers.filter { requests.count >= $0.0 }
            observers.removeAll { requests.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func respond(_ index: Int, status: Int = 200, body: String = "{}") {
        pending.removeValue(forKey: index)?.resume(returning: (Data(body.utf8), status))
    }
}

let verifiedEngineeringFeed = "[{\"id\":\"33333333-3333-3333-3333-333333333333\",\"slug\":\"engineering\",\"is_active\":true,\"member\":true}]"
