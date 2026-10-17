import Combine
import Foundation

@MainActor
final class PilotAccountModel: ObservableObject {
    enum Phase: Equatable {
        case signedOut
        case needsInvite(PilotSession)
        case admitted(PilotSession, PilotUser)
        case waiting(PilotSession)
        case blocked(PilotSession)

        var session: PilotSession? {
            switch self {
            case .signedOut: return nil
            case .needsInvite(let session), .admitted(let session, _), .waiting(let session), .blocked(let session):
                return session
            }
        }
    }

    @Published private(set) var phase: Phase = .signedOut
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var codeSentTo: String?
    private let auth: PilotAuthClient
    private let api: PilotAPIClient
    private let admissionStorage: (any PilotCredentialStorage)?
    private var operation = UUID()
    private var appleAttempt: UUID?
    private struct Admission: Codable { let identity: UUID; let user: PilotUser; let feed: String }

    init(auth: PilotAuthClient, api: PilotAPIClient, admissionStorage: (any PilotCredentialStorage)? = nil) {
        self.auth = auth; self.api = api; self.admissionStorage = admissionStorage
    }

    func restore() async {
        await run {
            guard let session = try await self.auth.currentSession() else { return (.signedOut, nil) }
            return try await self.admission(session)
        } apply: { self.apply($0) }
    }

    func sendCode(email: String) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        await run {
            try await self.auth.sendCode(email: email)
            return email
        } apply: { self.codeSentTo = $0 }
    }

    func changeEmail() {
        guard !isBusy else { return }
        codeSentTo = nil
        errorMessage = nil
    }

    func verifyCode(email: String, code: String) async {
        await run {
            _ = try await self.auth.verifyCode(email: email, code: code)
            guard let session = try await self.auth.currentSession() else { throw PilotError.signInRequired }
            return try await self.admission(session)
        } apply: { self.apply($0) }
    }

    func beginAppleSignIn() -> UUID? {
        guard !isBusy, phase == .signedOut else { return nil }
        operation = UUID()
        appleAttempt = operation
        errorMessage = nil
        isBusy = true
        return appleAttempt
    }

    func completeAppleSignIn(idToken: String?, nonce: String?, attempt: UUID, cancelled: Bool = false) async {
        guard appleAttempt == attempt, operation == attempt, phase == .signedOut else { return }
        appleAttempt = nil
        isBusy = false
        if cancelled { return }
        guard let idToken, let nonce else { reportAppleError(); return }
        await signInWithApple(idToken: idToken, nonce: nonce)
    }

    private func signInWithApple(idToken: String, nonce: String) async {
        await run {
            _ = try await self.auth.signInWithApple(idToken: idToken, nonce: nonce)
            guard let session = try await self.auth.currentSession() else { throw PilotError.signInRequired }
            return try await self.admission(session)
        } apply: { self.apply($0) }
    }

    func acceptInvite(_ code: String) async {
        guard case .needsInvite(let session) = phase else { return }
        await run {
            let user = try await self.api.acceptInvite(code, session: session)
            return try await self.admission(session, user: user)
        } apply: { self.apply($0) }
    }

    func signOut() async {
        operation = UUID()
        appleAttempt = nil
        let version = operation
        let previous = phase
        phase = .signedOut
        try? admissionStorage?.write(nil)
        codeSentTo = nil
        errorMessage = nil
        isBusy = true
        do { try await auth.signOut() }
        catch {
            guard operation == version else { return }
            phase = previous
            errorMessage = "Couldn’t remove the saved session. Unlock your device and try again."
        }
        if operation == version { isBusy = false }
    }

    func readerFailed(_ error: PilotError, session: PilotSession) {
        guard phase.session == session,
              [.accessDenied, .inviteRequired, .signInRequired, .sessionChanged].contains(error) else { return }
        operation = UUID()
        appleAttempt = nil
        isBusy = false
        try? admissionStorage?.write(nil)
        switch error {
        case .accessDenied, .inviteRequired: phase = .blocked(session)
        case .signInRequired, .sessionChanged: phase = .signedOut
        default: return
        }
        errorMessage = error.localizedDescription
    }

    func reportAppleError() {
        errorMessage = "Apple sign-in could not finish. Please try again or sign in by email."
    }

    private func admission(_ session: PilotSession, user knownUser: PilotUser? = nil) async throws -> (Phase, String?) {
        do {
            let user: PilotUser
            if let knownUser { user = knownUser }
            else { user = try await api.currentUser(session: session) }
            _ = try await api.engineeringFeedID(session: session)
            return (.admitted(session, user), nil)
        }
        catch PilotError.inviteRequired {
            try? admissionStorage?.write(nil)
            return (.needsInvite(session), nil)
        }
        catch PilotError.accessDenied {
            try? admissionStorage?.write(nil)
            return (.blocked(session), PilotError.accessDenied.localizedDescription)
        }
        catch PilotError.signInRequired { throw PilotError.signInRequired }
        catch PilotError.sessionChanged { throw PilotError.sessionChanged }
        catch {
            if pilotAllowsOffline(error), let data = try? admissionStorage?.read(),
               let saved = try? JSONDecoder().decode(Admission.self, from: data), saved.identity == session.identity.id, saved.feed == "engineering" {
                return (.admitted(session, saved.user), "Offline. You can read your saved briefs.")
            }
            return (.waiting(session), Self.message(for: error))
        }
    }

    private func apply(_ result: (Phase, String?)) {
        if case .admitted(let session, let user) = result.0,
           let data = try? JSONEncoder().encode(Admission(identity: session.identity.id, user: user, feed: "engineering")) {
            try? admissionStorage?.write(data)
        }
        phase = result.0
        errorMessage = result.1
        codeSentTo = nil
    }

    private func run<Value>(_ work: () async throws -> Value, apply: (Value) -> Void) async {
        guard !isBusy else { return }
        let version = operation
        isBusy = true
        errorMessage = nil
        do {
            let value = try await work()
            guard operation == version else { return }
            apply(value)
        } catch {
            guard operation == version else { return }
            if error as? PilotError == .signInRequired || error as? PilotError == .sessionChanged {
                try? admissionStorage?.write(nil)
                phase = .signedOut
                codeSentTo = nil
            } else if error as? PilotError == .accessDenied, let session = phase.session {
                try? admissionStorage?.write(nil)
                phase = .blocked(session)
            }
            errorMessage = Self.message(for: error)
        }
        if operation == version { isBusy = false }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? PilotError { return error.localizedDescription }
        return "Couldn’t connect. Check your connection and try again."
    }
}
