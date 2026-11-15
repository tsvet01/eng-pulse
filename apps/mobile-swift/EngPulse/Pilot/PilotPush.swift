import Combine
import CryptoKit
import Foundation

enum PilotPushEnvironment {
    static func resolve(profile: Data?, storeReceipt: Bool) -> String? {
        // Xcode may development-sign a Release build; the provisioning entitlement decides.
        guard let profile else { return storeReceipt ? "production" : nil }
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: profile[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        switch entitlements["aps-environment"] as? String {
        case "development": return "sandbox"
        case "production": return "production"
        default: return nil
        }
    }
}

@MainActor
final class PilotPushModel: ObservableObject {
    enum Status: Equatable {
        case unavailable, off, connecting, ready, disconnecting, denied, failed(String)
    }
    @Published private(set) var status = Status.unavailable
    private struct Scope: Equatable { let session: PilotSession; let user: UUID }
    private struct Binding: Codable {
        let identity: UUID
        let user: UUID
        var enabled: Bool
        var token: String?
        func belongs(to scope: Scope) -> Bool { identity == scope.session.identity.id && user == scope.user }
    }

    private let api: PilotAPIClient
    private let journal: any PilotCredentialStorage
    private let receiptDirectory: URL
    private let environment: String?
    private let version: String
    private let authorization: (Bool) async throws -> Bool
    private let register: () -> Void
    private let unregister: () -> Void
    private var scope: Scope?
    private var acceptingTokens = false
    private var latestToken: String?
    var onAccessFailure: ((PilotError, PilotSession) -> Void)?
    private var generation = UUID()
    private var work: Task<Void, Never>?

    init(api: PilotAPIClient, journal: any PilotCredentialStorage, receiptDirectory: URL,
         environment: String?, version: String, authorization: @escaping (Bool) async throws -> Bool,
         register: @escaping () -> Void, unregister: @escaping () -> Void) {
        self.api = api; self.journal = journal; self.receiptDirectory = receiptDirectory
        self.environment = environment; self.version = version; self.authorization = authorization
        self.register = register; self.unregister = unregister
        try? clearReceipt()
    }

    func admit(_ session: PilotSession, user: UUID) {
        let next = Scope(session: session, user: user)
        if scope != next {
            if scope != nil { leave() }
            scope = next
            status = .off
        }
        enqueue { [self] in
            guard scope == next, let binding = try read() else { return }
            guard binding.belongs(to: next) else {
                stopLocally()
                var abandoned = binding
                abandoned.enabled = false
                try save(abandoned)
                status = .failed(PushError.previousAccount.localizedDescription)
                return
            }
            if binding.enabled { try await connect(next, prompt: false) }
            else { try await disconnect(next) }
        }
    }

    func enable() async {
        guard let scope else { return }
        let start = generation
        await enqueue { [self] in
            guard self.scope == scope, generation == start else { return }
            try await connect(scope, prompt: true)
        }.value
    }

    private func connect(_ target: Scope, prompt: Bool) async throws {
        let start = generation
        let previous = try read()
        guard previous?.belongs(to: target) != false else { throw PushError.previousAccount }
        if previous?.enabled == false { try await disconnect(target) }
        guard scope == target, generation == start else { return }
        guard environment != nil else { throw PushError.signing }
        if status != .ready { status = .connecting }
        let granted = try await authorization(prompt)
        guard scope == target, generation == start else { return }
        guard granted else {
            stopLocally()
            status = .denied
            try await disconnect(target)
            if scope == target { status = .denied }
            return
        }
        var binding = try read() ?? Binding(identity: target.session.identity.id, user: target.user, enabled: true)
        binding.enabled = true
        try save(binding)
        acceptingTokens = true
        register()
    }

    // Always obtain a fresh token from Apple; the journal token is used only for cleanup.
    func received(_ data: Data) async {
        guard let target = scope, acceptingTokens, let environment else { return }
        guard (32...100).contains(data.count) else { registrationFailed(); return }
        let token = data.map { String(format: "%02x", $0) }.joined()
        let start = generation
        let reconfirming = status == .ready && latestToken == token
        latestToken = token
        if !reconfirming {
            status = .connecting
            try? clearReceipt()
        }
        await enqueue { [self] in
            guard scope == target, generation == start, acceptingTokens,
                  var binding = try read(), binding.enabled, binding.belongs(to: target) else { return }
            if !reconfirming { try clearReceipt() }
            if let old = binding.token, old != token {
                try await remove(old, session: target.session)
                guard scope == target, generation == start else { return }
            }
            // A timeout does not prove the PUT failed. Record its owner before sending it.
            binding.token = token
            try save(binding)
            let body = try JSONSerialization.data(withJSONObject: ["platform":"ios", "environment": environment,
                "app_version": version, "token": token])
            _ = try await api.request(path: "devices", method: "PUT", body: body, session: target.session)
            guard scope == target, generation == start, acceptingTokens, latestToken == token else { return }
            try confirm(token: token, environment: environment, user: target.user)
            status = .ready
        }.value
    }

    func registrationFailed() {
        guard acceptingTokens else { return }
        latestToken = nil
        try? clearReceipt()
        status = .failed("Couldn’t register with Apple. Try again.")
    }

    func disable() async {
        guard let scope else { return }
        stopLocally()
        try? markDisabled(for: scope)
        status = .disconnecting
        await enqueue { [self] in try await disconnect(scope) }.value
    }

    func leave(session: PilotSession? = nil) {
        // Revocation or logout can arrive during startup, before a verified admission.
        let binding = try? read()
        let old = scope ?? session.flatMap { session in
            binding.flatMap { $0.identity == session.identity.id ? Scope(session: session, user: $0.user) : nil }
        }
        guard old != nil || binding != nil else { return }
        scope = nil
        stopLocally()
        status = .unavailable
        if let old {
            try? markDisabled(for: old)
            enqueue { [self] in try await disconnect(old) }
        } else if var binding {
            binding.enabled = false
            try? save(binding)
        }
    }

    // Sign-out keeps its original credentials alive until any in-flight PUT and DELETE finish.
    func finishCleanup() async { await work?.value }

    func canPresent(feed: String?) -> Bool { scope != nil && status == .ready && feed == "pilot-test" }

    private func stopLocally() {
        generation = UUID()
        acceptingTokens = false
        latestToken = nil
        unregister()
        try? clearReceipt()
    }

    private func markDisabled(for target: Scope) throws {
        guard var binding = try read(), binding.belongs(to: target) else { return }
        binding.enabled = false
        try save(binding)
    }

    private func disconnect(_ target: Scope) async throws {
        guard var binding = try read() else {
            if scope == target { status = .off }
            return
        }
        guard binding.belongs(to: target) else { throw PushError.previousAccount }
        binding.enabled = false
        try save(binding)
        if let token = binding.token { try await remove(token, session: target.session) }
        try journal.write(nil)
        if scope == target { status = .off }
    }

    private func remove(_ token: String, session: PilotSession) async throws {
        let body = try JSONEncoder().encode(["token": token])
        _ = try await api.request(path: "devices", method: "DELETE", body: body, session: session)
    }

    @discardableResult
    private func enqueue(_ action: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        let previous = work
        let owner = scope
        let start = generation
        let task = Task {
            await previous?.value
            do { try await action() }
            catch {
                guard let owner, scope == owner, generation == start else { return }
                if let error = error as? PilotError, [.accessDenied, .inviteRequired, .sessionChanged, .signInRequired].contains(error) {
                    onAccessFailure?(error, owner.session)
                }
                if generation == start {
                    try? clearReceipt()
                    status = .failed((error as? PushError)?.localizedDescription ?? "Couldn’t update this iPhone. Check your connection and retry.")
                }
            }
        }
        work = task
        return task
    }

    private func read() throws -> Binding? {
        try journal.read().map { try JSONDecoder().decode(Binding.self, from: $0) }
    }
    private func save(_ binding: Binding) throws { try journal.write(JSONEncoder().encode(binding)) }

    private var receiptURL: URL { receiptDirectory.appendingPathComponent("confirmed.json") }
    private func clearReceipt() throws {
        do { try FileManager.default.removeItem(at: receiptURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }
    private func confirm(token: String, environment: String, user: UUID) throws {
        var directory = receiptDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let fingerprint = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        let receipt = try JSONEncoder().encode(["user_id": user.uuidString.lowercased(), "token_sha256": fingerprint, "environment": environment])
        #if os(iOS)
        try receipt.write(to: receiptURL, options: [.atomic, .completeFileProtection])
        #else
        try receipt.write(to: receiptURL, options: .atomic)
        #endif
    }

    private enum PushError: LocalizedError {
        case previousAccount, signing
        var errorDescription: String? {
            switch self {
            case .previousAccount: return "Sign in to the previously registered account to disconnect this iPhone first."
            case .signing: return "Push notifications are unavailable in this build."
            }
        }
    }
}
