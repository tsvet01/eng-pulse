import Combine
import Foundation

enum PilotFeedbackAspect: String, Codable, CaseIterable, Sendable {
    case selection, brief
}

struct PilotFeedback: Codable, Equatable, Sendable {
    var selection: Int?
    var brief: Int?

    init(selection: Int? = nil, brief: Int? = nil) {
        self.selection = selection; self.brief = brief
    }
    private enum CodingKeys: String, CodingKey { case selection, brief }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.selection), values.contains(.brief) else { throw PilotError.invalidResponse }
        selection = try values.decodeIfPresent(Int.self, forKey: .selection)
        brief = try values.decodeIfPresent(Int.self, forKey: .brief)
        guard [selection, brief].allSatisfy({ $0 == nil || $0 == -1 || $0 == 1 }) else { throw PilotError.invalidResponse }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(selection, forKey: .selection)
        try values.encode(brief, forKey: .brief)
    }
    func value(for aspect: PilotFeedbackAspect) -> Int? { aspect == .selection ? selection : brief }
    mutating func set(_ value: Int?, for aspect: PilotFeedbackAspect) {
        if aspect == .selection { selection = value } else { brief = value }
    }
}

struct PilotNotificationPreferences: Codable, Equatable, Sendable {
    var notifyEmail: Bool
    var notifyPush: Bool
    enum CodingKeys: String, CodingKey {
        case notifyEmail = "notify_email", notifyPush = "notify_push"
    }
}

extension PilotAPIClient {
    func feedback(date: String, session: PilotSession) async throws -> PilotFeedback {
        guard PilotBriefSummary.validDate(date) else { throw PilotError.invalidResponse }
        let data = try await request(path: "briefs/engineering/\(date)/feedback", session: session)
        guard let result = try? JSONDecoder().decode(PilotFeedback.self, from: data) else { throw PilotError.invalidResponse }
        return result
    }

    func setFeedback(date: String, aspect: PilotFeedbackAspect, value: Int?, session: PilotSession) async throws {
        guard PilotBriefSummary.validDate(date), value == nil || value == -1 || value == 1 else { throw PilotError.invalidResponse }
        var body: [String: Any] = ["aspect": aspect.rawValue]
        if let value { body["value"] = value }
        _ = try await request(path: "briefs/engineering/\(date)/feedback", method: value == nil ? "DELETE" : "PUT",
            body: JSONSerialization.data(withJSONObject: body), session: session)
    }

    func notificationPreferences(session: PilotSession) async throws -> PilotNotificationPreferences {
        let feed = try await engineeringFeedID(session: session)
        let data = try await request(path: "feeds/\(feed.uuidString.lowercased())/preferences", session: session)
        guard let result = try? JSONDecoder().decode(PilotNotificationPreferences.self, from: data) else { throw PilotError.invalidResponse }
        return result
    }

    func setNotificationPreferences(_ preferences: PilotNotificationPreferences, session: PilotSession) async throws -> PilotNotificationPreferences {
        let feed = try await engineeringFeedID(session: session)
        let data = try await request(path: "feeds/\(feed.uuidString.lowercased())/preferences", method: "PUT",
            body: JSONEncoder().encode(preferences), session: session)
        guard let result = try? JSONDecoder().decode(PilotNotificationPreferences.self, from: data) else { throw PilotError.invalidResponse }
        return result
    }
}

@MainActor
final class PilotPersonalState: ObservableObject {
    @Published private(set) var feedback: [String: PilotFeedback] = [:]
    @Published private(set) var pendingDates: Set<String> = []
    @Published private(set) var feedbackErrors: [String: String] = [:]
    @Published private(set) var preferences: PilotNotificationPreferences?
    @Published private(set) var preferencesError: String?
    @Published private(set) var isSavingPreferences = false
    @Published private(set) var isFlushing = false
    private(set) var isActive = true
    var onAccessFailure: ((PilotError) async -> Void)?

    private struct Edit: Codable {
        let id: UUID
        let date: String
        let aspect: PilotFeedbackAspect
        let value: Int?
        var key: String { "\(date)/\(aspect.rawValue)" }
    }
    private struct Snapshot: Codable {
        var feedback: [String: PilotFeedback] = [:]
        var pending: [String: Edit] = [:]
    }
    private let api: PilotAPIClient
    private let session: PilotSession
    private let file: URL
    private var snapshot = Snapshot()
    private var loaded = false
    private var revisions: [String: UUID] = [:]
    // Context invalidation cannot recall a request already dispatched to the server.
    private static var writes: [URL: (id: UUID, task: Task<Void, Error>)] = [:]

    init(api: PilotAPIClient, session: PilotSession, user: UUID, root: URL) {
        self.api = api; self.session = session
        file = root.appendingPathComponent(session.identity.id.uuidString)
            .appendingPathComponent(user.uuidString).appendingPathComponent("engineering/feedback.json")
    }

    func hasPending(date: String) -> Bool { pendingDates.contains(date) }

    func invalidate() {
        isActive = false
        feedback = [:]; pendingDates = []; feedbackErrors = [:]
        preferences = nil; preferencesError = nil
        snapshot = Snapshot()
    }

    private func requireCurrent() async throws {
        guard isActive else { throw PilotError.sessionChanged }
        try await api.auth.requireCurrent(session)
        guard isActive else { throw PilotError.sessionChanged }
    }

    private func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
            guard saved.feedback.keys.allSatisfy(PilotBriefSummary.validDate),
                  saved.pending.allSatisfy({ key, edit in
                      key == edit.key && PilotBriefSummary.validDate(edit.date) &&
                      (edit.value == nil || edit.value == -1 || edit.value == 1)
                  }) else { throw PilotError.invalidResponse }
            publish(saved)
        }
        loaded = true
    }

    private func publish(_ value: Snapshot) {
        snapshot = value
        feedback = value.feedback
        pendingDates = Set(value.pending.values.map(\.date))
    }

    private func save(_ value: Snapshot) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        publish(value)
    }

    func refreshFeedback(date: String) async {
        let revision = UUID()
        do {
            try await requireCurrent()
            guard PilotBriefSummary.validDate(date) else { throw PilotError.invalidResponse }
            try load()
            revisions[date] = revision
            var result = try await api.feedback(date: date, session: session)
            try await requireCurrent()
            guard revisions[date] == revision else { return }
            for edit in snapshot.pending.values where edit.date == date { result.set(edit.value, for: edit.aspect) }
            var updated = snapshot
            updated.feedback[date] = result
            try save(updated)
            feedbackErrors[date] = nil
        } catch {
            await accessFailed(error)
            guard isActive, revisions[date] == nil || revisions[date] == revision else { return }
            feedbackErrors[date] = "Couldn't refresh your ratings. Saved ratings are shown when available."
        }
    }

    func rate(date: String, aspect: PilotFeedbackAspect, value: Int?) async {
        do {
            try await requireCurrent()
            guard PilotBriefSummary.validDate(date), value == nil || value == -1 || value == 1 else { throw PilotError.invalidResponse }
            try load()
            let edit = Edit(id: UUID(), date: date, aspect: aspect, value: value)
            var updated = snapshot
            updated.feedback[date, default: PilotFeedback()].set(value, for: aspect)
            updated.pending[edit.key] = edit
            try save(updated)
            revisions[date] = UUID()
            feedbackErrors[date] = nil
        } catch {
            await accessFailed(error)
            if isActive { feedbackErrors[date] = "Couldn't save this rating on your device. Please try again." }
            return
        }
        await flush()
    }

    func flush() async {
        guard isActive, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        do {
            try await requireCurrent()
            try load()
            var attempted: Set<UUID> = []
            // Allow one superseding tap per initial edit, without an unbounded drain.
            let budget = snapshot.pending.count * 2
            while attempted.count < budget,
                  let edit = snapshot.pending.values.filter({ !attempted.contains($0.id) })
                    .sorted(by: { $0.key < $1.key }).first {
                attempted.insert(edit.id)
                do {
                    try await send(edit)
                    try await requireCurrent()
                    // A newer tap may have replaced the in-flight edit.
                    if snapshot.pending[edit.key]?.id == edit.id {
                        var updated = snapshot
                        updated.pending[edit.key] = nil
                        try save(updated)
                        revisions[edit.date] = UUID()
                        feedbackErrors[edit.date] = nil
                    }
                } catch {
                    await accessFailed(error)
                    if isActive { feedbackErrors[edit.date] = "Your rating is saved on this device but hasn't synced yet. Please retry when connected." }
                    if !isActive || error as? PilotError != .invalidResponse { return }
                }
            }
        } catch { await accessFailed(error) }
    }

    private func send(_ edit: Edit) async throws {
        let predecessor = Self.writes[file]?.task
        let id = UUID()
        let task = Task { @MainActor in
            if let predecessor { _ = await predecessor.result }
            try await self.requireCurrent()
            try await self.api.setFeedback(date: edit.date, aspect: edit.aspect, value: edit.value, session: self.session)
        }
        Self.writes[file] = (id, task)
        defer { if Self.writes[file]?.id == id { Self.writes[file] = nil } }
        try await task.value
    }

    func loadPreferences() async { await updatePreferences(nil) }
    func savePreferences(_ value: PilotNotificationPreferences) async { await updatePreferences(value) }

    private func updatePreferences(_ value: PilotNotificationPreferences?) async {
        guard isActive, !isSavingPreferences else { return }
        isSavingPreferences = true
        defer { isSavingPreferences = false }
        do {
            try await requireCurrent()
            let result: PilotNotificationPreferences
            if let value { result = try await api.setNotificationPreferences(value, session: session) }
            else { result = try await api.notificationPreferences(session: session) }
            try await requireCurrent()
            preferences = result
            preferencesError = nil
        } catch {
            await accessFailed(error)
            if isActive {
                preferencesError = value == nil ? "Couldn't load your preferences. Connect and retry." :
                    "Your change wasn't confirmed. Connect and reload before trying again."
            }
        }
    }

    private func accessFailed(_ error: Error) async {
        guard isActive, let error = error as? PilotError,
              [.accessDenied, .inviteRequired, .signInRequired, .sessionChanged].contains(error) else { return }
        invalidate()
        await onAccessFailure?(error)
    }
}
