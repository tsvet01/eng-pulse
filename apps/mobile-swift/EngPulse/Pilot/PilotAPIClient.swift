import Foundation

struct PilotUser: Decodable, Equatable, Sendable {
    let id: UUID
    let email: String
    let isAdmin: Bool
    enum CodingKeys: String, CodingKey {
        case id, email
        case isAdmin = "is_admin"
    }
}

struct PilotSession: Equatable, Sendable {
    let id: UUID
    let identity: PilotIdentity
}

struct PilotAPIClient: Sendable {
    let configuration: PilotConfiguration
    let auth: PilotAuthClient
    var transport: any PilotTransport = PilotURLTransport()

    func currentUser(session: PilotSession) async throws -> PilotUser {
        try await userRequest(path: "me", method: "GET", body: nil, session: session)
    }

    func acceptInvite(_ code: String, session: PilotSession) async throws -> PilotUser {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw PilotError.invalidInvite }
        let data = try JSONSerialization.data(withJSONObject: ["invite_code": code])
        return try await userRequest(path: "users", method: "POST", body: data, session: session)
    }

    private func userRequest(path: String, method: String, body: Data?, session: PilotSession) async throws -> PilotUser {
        for attempt in 0...1 {
            let token = try await auth.accessToken(for: session, forceRefresh: attempt == 1)
            var request = URLRequest(url: configuration.apiURL.appendingPathComponent(path))
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, status) = try await transport.send(request)
            try await auth.requireCurrent(session)
            if status == 401 {
                if attempt == 0 { continue }
                try await auth.discard(session)
                throw PilotError.signInRequired
            }
            if status == 200 || status == 201 {
                guard let user = try? JSONDecoder().decode(PilotUser.self, from: data) else {
                    throw PilotError.invalidResponse
                }
                return user
            }
            struct Failure: Decodable { let error: String }
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            switch status {
            case 403: throw code == "invite_required" ? PilotError.inviteRequired : .accessDenied
            case 409: throw PilotError.accountConflict
            case 422: throw method == "POST" ? PilotError.invalidInvite : .invalidResponse
            case 429: throw PilotError.rateLimited
            default: throw PilotError.unavailable
            }
        }
        throw PilotError.signInRequired
    }
}
