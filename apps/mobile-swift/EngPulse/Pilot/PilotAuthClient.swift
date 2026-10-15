import Foundation

struct PilotIdentity: Codable, Equatable, Sendable {
    let id: UUID
    let email: String?
}

struct PilotCredentials: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval
    let identity: PilotIdentity
}

protocol PilotCredentialStorage: Sendable {
    func read() throws -> Data?
    func write(_ data: Data?) throws
}

actor PilotAuthClient {
    private let configuration: PilotConfiguration
    private let transport: any PilotTransport
    private let storage: any PilotCredentialStorage
    private var credentials: PilotCredentials?
    private var loaded = false
    private var generation = UUID()
    private var refresh: (id: UUID, task: Task<PilotCredentials, Error>)?

    init(configuration: PilotConfiguration, transport: any PilotTransport = PilotURLTransport(),
         storage: any PilotCredentialStorage) {
        self.configuration = configuration
        self.transport = transport
        self.storage = storage
    }

    func currentIdentity() throws -> PilotIdentity? {
        try load()
        return credentials?.identity
    }

    func currentSession() throws -> PilotSession? {
        try load()
        return credentials.map { PilotSession(id: generation, identity: $0.identity) }
    }

    func sendCode(email: String) async throws {
        let request = try authRequest(path: "otp", body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "create_user": true])
        let (_, status) = try await transport.send(request)
        guard (200...299).contains(status) else { throw status == 429 ? PilotError.rateLimited : PilotError.unavailable }
    }

    func verifyCode(email: String, code: String) async throws -> PilotIdentity {
        try await exchange(path: "verify", body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "token": code.trimmingCharacters(in: .whitespacesAndNewlines), "type": "email"])
    }

    func signInWithApple(idToken: String, nonce: String) async throws -> PilotIdentity {
        guard !idToken.isEmpty, !nonce.isEmpty else { throw PilotError.invalidCode }
        return try await exchange(path: "token", query: "grant_type=id_token",
            body: ["provider": "apple", "id_token": idToken, "nonce": nonce])
    }

    func accessToken(for identity: UUID, forceRefresh: Bool = false) async throws -> String {
        try load()
        guard let current = credentials else { throw PilotError.signInRequired }
        guard current.identity.id == identity else { throw PilotError.sessionChanged }
        if !forceRefresh, current.expiresAt > Date().timeIntervalSince1970 + 60 { return current.accessToken }
        let version = generation
        let operation: (id: UUID, task: Task<PilotCredentials, Error>)
        if let refresh { operation = refresh }
        else {
            let request = try authRequest(path: "token", query: "grant_type=refresh_token", body: ["refresh_token": current.refreshToken])
            let transport = transport
            operation = (UUID(), Task {
                let (data, status) = try await transport.send(request)
                if status == 400 || status == 401 { throw PilotError.signInRequired }
                guard status == 200 else { throw status == 429 ? PilotError.rateLimited : PilotError.unavailable }
                return try Self.decodeCredentials(data)
            })
            refresh = operation
        }
        do {
            let renewed = try await operation.task.value
            guard generation == version, credentials?.identity.id == identity else { throw PilotError.sessionChanged }
            guard renewed.identity.id == identity else { throw PilotError.invalidResponse }
            // Every waiter must observe durable credentials, even if another
            // waiter failed to save the rotated refresh token.
            if credentials != renewed { try persist(renewed) }
            if refresh?.id == operation.id { refresh = nil }
            return renewed.accessToken
        } catch {
            guard generation == version else { throw PilotError.sessionChanged }
            if refresh?.id == operation.id {
                refresh = nil
                if error as? PilotError == .signInRequired { try clear() }
            }
            throw error
        }
    }

    func accessToken(for session: PilotSession, forceRefresh: Bool = false) async throws -> String {
        try requireCurrent(session)
        let token = try await accessToken(for: session.identity.id, forceRefresh: forceRefresh)
        try requireCurrent(session)
        return token
    }

    func requireCurrent(_ session: PilotSession) throws {
        guard try currentSession() == session else { throw PilotError.sessionChanged }
    }

    func discard(_ session: PilotSession) throws {
        try requireCurrent(session)
        try clear()
    }

    func signOut() async throws {
        try load()
        let oldToken = credentials?.accessToken
        try clear()
        guard let oldToken else { return }
        var request = try authRequest(path: "logout", query: "scope=local", body: [:])
        request.setValue("Bearer \(oldToken)", forHTTPHeaderField: "Authorization")
        // Local sign-out must work offline; the discarded refresh token is never reused.
        _ = try? await transport.send(request)
    }

    private func exchange(path: String, query: String? = nil, body: [String: Any]) async throws -> PilotIdentity {
        generation = UUID()
        let version = generation
        refresh?.task.cancel()
        refresh = nil
        let request = try authRequest(path: path, query: query, body: body)
        let (data, status) = try await transport.send(request)
        guard generation == version else { throw PilotError.sessionChanged }
        guard (200...299).contains(status) else {
            throw status == 429 ? PilotError.rateLimited : (status >= 500 ? .unavailable : .invalidCode)
        }
        let value = try Self.decodeCredentials(data)
        try persist(value)
        return value.identity
    }

    private func load() throws {
        guard !loaded else { return }
        if let data = try storage.read() {
            do {
                let value = try JSONDecoder().decode(PilotCredentials.self, from: data)
                guard !value.accessToken.isEmpty, !value.refreshToken.isEmpty,
                      value.expiresAt.isFinite, value.expiresAt > 0 else { throw PilotError.invalidResponse }
                credentials = value
            }
            catch { try clear() }
        }
        loaded = true
    }

    private func persist(_ value: PilotCredentials) throws {
        try storage.write(JSONEncoder().encode(value))
        credentials = value
        loaded = true
    }

    private func clear() throws {
        try storage.write(nil)
        generation = UUID()
        refresh?.task.cancel()
        refresh = nil
        credentials = nil
        loaded = true
    }

    private func authRequest(path: String, query: String? = nil, body: [String: Any]) throws -> URLRequest {
        var components = URLComponents(url: configuration.supabaseURL.appendingPathComponent("auth/v1/\(path)"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func decodeCredentials(_ data: Data) throws -> PilotCredentials {
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_at: TimeInterval?
            let expires_in: TimeInterval
            let user: PilotIdentity
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              !response.access_token.isEmpty, !response.refresh_token.isEmpty,
              response.expires_in > 0 else { throw PilotError.invalidResponse }
        let expiresAt = response.expires_at ?? Date().timeIntervalSince1970 + response.expires_in
        guard expiresAt.isFinite, expiresAt > Date().timeIntervalSince1970 else { throw PilotError.invalidResponse }
        return PilotCredentials(accessToken: response.access_token, refreshToken: response.refresh_token,
            expiresAt: expiresAt, identity: response.user)
    }
}
