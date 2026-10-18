import Combine
import Foundation

enum PilotFeedbackAspect: String, Codable, CaseIterable { case selection, brief }

struct PilotFeedbackValue: Codable, Equatable, Sendable {
    var value: Int?
    var revision: Int64
    var isValid: Bool { revision >= 0 && (value == nil || (revision > 0 && [-1, 1].contains(value!))) }
}

struct PilotFeedbackSnapshot: Codable, Equatable, Sendable {
    var selection = PilotFeedbackValue(value: nil, revision: 0)
    var brief = PilotFeedbackValue(value: nil, revision: 0)
    subscript(_ aspect: PilotFeedbackAspect) -> PilotFeedbackValue {
        get { aspect == .selection ? selection : brief }
        set { if aspect == .selection { selection = newValue } else { brief = newValue } }
    }
}

struct PilotFeedbackIntent: Codable, Equatable {
    let value: Int?
    let expectedRevision: Int64
}

struct PilotFeedbackRecord: Codable, Equatable {
    var snapshot = PilotFeedbackSnapshot()
    var pending: [String: PilotFeedbackIntent] = [:]
    var conflicts: Set<String> = []
    func displayed(_ aspect: PilotFeedbackAspect) -> Int? {
        if let intent = pending[aspect.rawValue] { return intent.value }
        return snapshot[aspect].value
    }
}

struct PilotFeedbackStore {
    let directory: URL
    init(root: URL, identity: UUID, user: UUID) {
        directory = root.appendingPathComponent(identity.uuidString).appendingPathComponent(user.uuidString)
            .appendingPathComponent("engineering-feedback")
    }
    func dates() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }
            .filter(PilotBriefSummary.validDate).sorted()
    }
    func load(date: String) throws -> PilotFeedbackRecord {
        guard PilotBriefSummary.validDate(date) else { throw PilotError.invalidResponse }
        let file = directory.appendingPathComponent("\(date).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return PilotFeedbackRecord() }
        let record = try JSONDecoder().decode(PilotFeedbackRecord.self, from: Data(contentsOf: file))
        guard record.snapshot.selection.isValid, record.snapshot.brief.isValid,
            record.pending.allSatisfy({
                PilotFeedbackAspect(rawValue: $0.key) != nil && $0.value.expectedRevision >= 0
                    && ($0.value.value == nil || [-1, 1].contains($0.value.value!))
            }),
            record.conflicts.allSatisfy({ PilotFeedbackAspect(rawValue: $0) != nil })
        else { throw PilotError.invalidResponse }
        return record
    }
    func save(_ record: PilotFeedbackRecord, date: String) throws {
        guard PilotBriefSummary.validDate(date) else { throw PilotError.invalidResponse }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("\(date).json"), options: .atomic)
    }
}

struct PilotFeedbackClient {
    let api: PilotAPIClient
    let session: PilotSession
    private func path(_ date: String) throws -> String {
        guard PilotBriefSummary.validDate(date) else { throw PilotError.invalidResponse }
        return "briefs/engineering/\(date)/feedback"
    }
    func load(date: String) async throws -> PilotFeedbackSnapshot {
        let data = try await api.request(path: path(date), session: session)
        guard let snapshot = try? JSONDecoder().decode(PilotFeedbackSnapshot.self, from: data),
            snapshot.selection.isValid, snapshot.brief.isValid
        else { throw PilotError.invalidResponse }
        return snapshot
    }
    func set(value: Int?, aspect: PilotFeedbackAspect, date: String, expectedRevision: Int64) async throws -> Int64 {
        guard expectedRevision >= 0, value == nil || [-1, 1].contains(value!) else { throw PilotError.invalidResponse }
        let body = try value.map {
            try JSONSerialization.data(withJSONObject: ["aspect": aspect.rawValue, "value": $0])
        }
        let response = try await api.response(
            path: path(date) + (value == nil ? "/\(aspect.rawValue)" : ""),
            method: value == nil ? "DELETE" : "PUT", body: body,
            headers: ["X-Expected-Revision": String(expectedRevision)], session: session)
        guard response.status == 204, let header = response.headers["x-feedback-revision"],
            !header.isEmpty, header.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let revision = Int64(header), revision > 0, revision >= expectedRevision
        else { throw PilotError.invalidResponse }
        return revision
    }
}

@MainActor
final class PilotFeedbackModel: ObservableObject {
    @Published private(set) var records: [String: PilotFeedbackRecord] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var isSyncing = false
    private(set) var isActive = true
    var onAccessFailure: ((PilotError) async -> Void)?
    private let client: PilotFeedbackClient
    private let store: PilotFeedbackStore
    private var requestedDates: Set<String> = []

    init(api: PilotAPIClient, session: PilotSession, store: PilotFeedbackStore) {
        client = PilotFeedbackClient(api: api, session: session)
        self.store = store
    }
    func record(for date: String) -> PilotFeedbackRecord { records[date] ?? PilotFeedbackRecord() }
    func load(date: String) throws {
        guard isActive else { throw PilotError.sessionChanged }
        if records[date] == nil { records[date] = try store.load(date: date) }
    }
    func set(value: Int?, aspect: PilotFeedbackAspect, date: String) throws {
        guard isActive else { throw PilotError.sessionChanged }
        guard !isSyncing, value == nil || [-1, 1].contains(value!) else { throw PilotError.unavailable }
        try load(date: date)
        var record = record(for: date)
        let expected = record.pending[aspect.rawValue]?.expectedRevision ?? record.snapshot[aspect].revision
        record.pending[aspect.rawValue] = PilotFeedbackIntent(value: value, expectedRevision: expected)
        record.conflicts.remove(aspect.rawValue)
        try persist(record, date: date)
        errors[date] = nil
    }
    func refresh(date: String) async {
        guard isActive else { return }
        do {
            try load(date: date)
            requestedDates.insert(date)
            await synchronize()
        } catch { errors[date] = "Couldn’t read saved feedback. Please try again." }
    }
    func synchronize() async {
        guard isActive, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            for date in try store.dates() {
                do { try load(date: date) } catch {
                    errors[date] = "Couldn’t read saved feedback for this article. Please try again."
                }
            }
            var dates = Set(records.filter { !$0.value.pending.isEmpty }.map(\.key)).union(requestedDates)
            requestedDates.removeAll()
            while let date = dates.sorted().first {
                dates.remove(date)
                guard isActive else { return }
                do {
                    try await synchronize(date: date)
                    errors[date] = nil
                } catch {
                    guard isActive else { return }
                    if let error = error as? PilotError,
                        [.accessDenied, .inviteRequired, .signInRequired, .sessionChanged].contains(error)
                    {
                        invalidate()
                        await onAccessFailure?(error)
                        return
                    }
                    errors[date] =
                        record(for: date).pending.isEmpty
                        ? "Couldn’t refresh feedback. Please try again."
                        : "Saved on this device. Sync will retry when the service is available."
                }
                dates.formUnion(requestedDates)
                requestedDates.removeAll()
            }
        } catch {
            for date in records.keys { errors[date] = "Couldn’t read saved feedback. Please try again." }
        }
    }
    private func requireCurrent() async throws {
        guard isActive else { throw PilotError.sessionChanged }
        try await client.api.auth.requireCurrent(client.session)
        guard isActive else { throw PilotError.sessionChanged }
    }
    private func persist(_ record: PilotFeedbackRecord, date: String) throws {
        guard isActive else { throw PilotError.sessionChanged }
        try store.save(record, date: date)
        records[date] = record
    }
    private func synchronize(date: String) async throws {
        try await requireCurrent()
        var remote = try await client.load(date: date)
        try await requireCurrent()
        var record = record(for: date)
        record.snapshot = remote
        try persist(record, date: date)
        for aspect in PilotFeedbackAspect.allCases {
            guard let intent = record.pending[aspect.rawValue] else { continue }
            if remote[aspect].value == intent.value {
                record.pending.removeValue(forKey: aspect.rawValue)
            } else if remote[aspect].revision != intent.expectedRevision {
                record.pending.removeValue(forKey: aspect.rawValue)
                record.conflicts.insert(aspect.rawValue)
            } else {
                do {
                    let revision = try await client.set(
                        value: intent.value, aspect: aspect, date: date, expectedRevision: intent.expectedRevision)
                    try await requireCurrent()
                    remote[aspect] = PilotFeedbackValue(value: intent.value, revision: revision)
                    record.pending.removeValue(forKey: aspect.rawValue)
                } catch PilotError.feedbackConflict {
                    remote = try await client.load(date: date)
                    try await requireCurrent()
                    record.pending.removeValue(forKey: aspect.rawValue)
                    record.conflicts.insert(aspect.rawValue)
                }
            }
            record.snapshot = remote
            try persist(record, date: date)
        }
    }
    func invalidate() {
        isActive = false
        records = [:]
        errors = [:]
        requestedDates = []
    }
}
