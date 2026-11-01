import Combine
import CryptoKit
import Foundation

enum PilotFeedbackAspect: String, Codable, CaseIterable { case selection, brief }

struct PilotFeedbackValue: Codable, Equatable, Sendable {
    var value: Int?
    var revision: Int64
    var reason: String? = nil
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

struct PilotFeedbackTarget: Codable, Hashable, Sendable {
    let articleID: UUID
    let briefID: UUID?
    init(identity: PilotContentIdentity, aspect: PilotFeedbackAspect) {
        articleID = identity.articleID
        briefID = aspect == .brief ? identity.briefID : nil
    }
    var aspect: PilotFeedbackAspect { briefID == nil ? .selection : .brief }
    var key: String { articleID.uuidString.lowercased() + (briefID.map { ".brief.\($0.uuidString.lowercased())" } ?? ".relevance") }
    var path: String { "articles/\(articleID.uuidString.lowercased())/feedback/\(briefID == nil ? "relevance" : "brief_quality")" }
    var query: [URLQueryItem] { briefID.map { [URLQueryItem(name: "brief_id", value: $0.uuidString.lowercased())] } ?? [] }
}

struct PilotLegacyFeedback: Codable, Equatable {
    let snapshot: PilotFeedbackValue
    let pending: PilotFeedbackIntent?
    let conflict: Bool
    var isUntouched: Bool {
        snapshot == PilotFeedbackValue(value: nil, revision: 0) && pending == nil && !conflict
    }
    init(_ record: PilotFeedbackRecord, aspect: PilotFeedbackAspect) {
        snapshot = record.snapshot[aspect]
        pending = record.pending[aspect.rawValue]
        conflict = record.conflicts.contains(aspect.rawValue)
    }
}

struct PilotStableFeedbackRecord: Codable {
    let target: PilotFeedbackTarget
    var snapshot = PilotFeedbackValue(value: nil, revision: 0)
    var pending: PilotFeedbackIntent?
    var conflict = false
    var locallyEdited = false
    // Source evidence and acknowledgement commit with the vote, never in a separate file.
    var imported: [String: PilotLegacyFeedback] = [:]
    var migrationConflicts: Set<String> = []
    var isUntouched: Bool {
        snapshot == PilotFeedbackValue(value: nil, revision: 0) && pending == nil && !conflict
            && !locallyEdited && migrationConflicts.isEmpty && imported.values.allSatisfy(\.isUntouched)
    }
}

extension PilotFeedbackStore {
    var stableDirectory: URL { directory.deletingLastPathComponent().appendingPathComponent("stable-feedback") }
    func stableFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: stableDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: stableDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }
    func load(target: PilotFeedbackTarget) throws -> PilotStableFeedbackRecord? {
        let file = stableDirectory.appendingPathComponent(target.key + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try loadStable(file: file)
    }
    func loadStable(file: URL) throws -> PilotStableFeedbackRecord {
        let record = try JSONDecoder().decode(PilotStableFeedbackRecord.self, from: Data(contentsOf: file))
        func valid(_ intent: PilotFeedbackIntent?) -> Bool {
            intent.map { $0.expectedRevision >= 0 && ($0.value == nil || [-1, 1].contains($0.value!)) } ?? true
        }
        guard file.lastPathComponent == record.target.key + ".json", record.snapshot.isValid,
            valid(record.pending), record.imported.allSatisfy({
                PilotBriefSummary.validDate($0.key) && $0.value.snapshot.isValid && valid($0.value.pending)
            }), record.migrationConflicts.isSubset(of: Set(record.imported.keys))
        else { throw PilotError.invalidResponse }
        return record
    }
    func save(_ record: PilotStableFeedbackRecord) throws {
        try FileManager.default.createDirectory(at: stableDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(
            to: stableDirectory.appendingPathComponent(record.target.key + ".json"), options: .atomic)
    }
}

extension PilotFeedbackStore {
    private struct DisplayBinding: Codable {
        let date: String
        let contentHash: String
        let identity: PilotContentIdentity
    }
    private var bindingsDirectory: URL { directory.deletingLastPathComponent().appendingPathComponent("feedback-content-identities") }
    private func contentHash(_ context: PilotFeedbackContext) throws -> String {
        guard PilotBriefSummary.validDate(context.date), let content = context.legacyContent else {
            throw PilotError.mappingUnavailable
        }
        return SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func boundIdentity(for context: PilotFeedbackContext) throws -> PilotContentIdentity? {
        guard context.legacyContent != nil else { return nil }
        let hash = try contentHash(context)
        let file = bindingsDirectory.appendingPathComponent("\(context.date)-\(hash).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let binding = try JSONDecoder().decode(DisplayBinding.self, from: Data(contentsOf: file))
        guard binding.date == context.date, binding.contentHash == hash else { throw PilotError.invalidResponse }
        return binding.identity
    }
    func bind(_ identity: PilotContentIdentity, to context: PilotFeedbackContext) throws {
        let hash = try contentHash(context)
        let binding = DisplayBinding(date: context.date, contentHash: hash, identity: identity)
        try FileManager.default.createDirectory(at: bindingsDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(binding).write(
            to: bindingsDirectory.appendingPathComponent("\(context.date)-\(hash).json"), options: .atomic)
    }
}

struct PilotFeedbackClient {
    let api: PilotAPIClient
    let session: PilotSession
    func identity(date: String) async throws -> PilotContentIdentity {
        guard PilotBriefSummary.validDate(date) else { throw PilotError.invalidResponse }
        let response = try await api.response(path: "briefs/engineering/\(date)/feedback-identity", version: .v2, session: session)
        guard let identity = try? JSONDecoder().decode(PilotContentIdentity.self, from: response.data) else {
            throw PilotError.invalidResponse
        }
        return identity
    }
    func load(target: PilotFeedbackTarget) async throws -> PilotFeedbackValue {
        let response = try await api.response(path: target.path, query: target.query, version: .v2, session: session)
        guard let snapshot = try? JSONDecoder().decode(PilotFeedbackValue.self, from: response.data), snapshot.isValid else {
            throw PilotError.invalidResponse
        }
        let reasons = target.aspect == .selection ? ["more_like_this", "not_relevant"] : ["inaccurate_summary", "unclear_summary"]
        if let reason = snapshot.reason {
            guard reasons.contains(reason), snapshot.value == (reason == "more_like_this" ? 1 : -1) else {
                throw PilotError.invalidResponse
            }
        }
        return snapshot
    }
    func set(value: Int?, target: PilotFeedbackTarget, expectedRevision: Int64) async throws -> Int64 {
        guard expectedRevision >= 0, value == nil || [-1, 1].contains(value!) else { throw PilotError.invalidResponse }
        let body = try value.map { try JSONSerialization.data(withJSONObject: ["value": $0, "reason": NSNull()]) }
        let response = try await api.response(
            path: target.path, method: value == nil ? "DELETE" : "PUT", body: body, query: target.query,
            headers: ["X-Expected-Revision": String(expectedRevision)], version: .v2, session: session)
        guard response.status == 204, let header = response.headers["x-feedback-revision"],
            !header.isEmpty, header.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let revision = Int64(header), revision > 0, revision >= expectedRevision
        else { throw PilotError.invalidResponse }
        return revision
    }
}

@MainActor
final class PilotFeedbackModel: ObservableObject {
    @Published private(set) var records: [String: PilotStableFeedbackRecord] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private var legacyIdentities: [PilotFeedbackContext: PilotContentIdentity] = [:]
    @Published private var contextErrors: [PilotFeedbackContext: String] = [:]
    @Published private(set) var isSyncing = false
    private(set) var isActive = true
    var onAccessFailure: ((PilotError) async -> Void)?
    private let client: PilotFeedbackClient
    private let store: PilotFeedbackStore
    private var requested: Set<PilotFeedbackContext> = []

    init(api: PilotAPIClient, session: PilotSession, store: PilotFeedbackStore) {
        client = PilotFeedbackClient(api: api, session: session)
        self.store = store
    }
    private func identity(for context: PilotFeedbackContext) -> PilotContentIdentity? {
        context.identity ?? legacyIdentities[context]
    }
    func record(for context: PilotFeedbackContext) -> PilotFeedbackRecord {
        var result = PilotFeedbackRecord()
        guard let identity = identity(for: context) else { return result }
        for aspect in PilotFeedbackAspect.allCases {
            let target = PilotFeedbackTarget(identity: identity, aspect: aspect)
            guard let record = records[target.key] else { continue }
            result.snapshot[aspect] = record.snapshot
            result.pending[aspect.rawValue] = record.pending
            if record.conflict || !record.migrationConflicts.isEmpty { result.conflicts.insert(aspect.rawValue) }
        }
        return result
    }
    func error(for context: PilotFeedbackContext) -> String? {
        if let error = contextErrors[context] { return error }
        if let error = errors[context.date] { return error }
        if let identity = identity(for: context) {
            for aspect in PilotFeedbackAspect.allCases {
                let target = PilotFeedbackTarget(identity: identity, aspect: aspect)
                if let error = errors[target.key] { return error }
                if records[target.key]?.migrationConflicts.isEmpty == false {
                    return "Older ratings disagree. They are kept on this device. Choose a rating to resolve them."
                }
            }
        }
        // Surface stranded legacy work even when its date has fallen out of the feed.
        if let date = errors.keys.filter(PilotBriefSummary.validDate).sorted().first {
            return "\(date): \(errors[date]!)"
        }
        let conflictDates = Set(records.values.flatMap(\.migrationConflicts)).sorted()
        if !conflictDates.isEmpty {
            return "Older ratings for \(conflictDates.joined(separator: ", ")) disagree. They are kept on this device. Choose a rating on the affected article to resolve them."
        }
        return errors["storage"]
    }
    private func loadBinding(context: PilotFeedbackContext) throws {
        guard isActive else { throw PilotError.sessionChanged }
        if identity(for: context) == nil { legacyIdentities[context] = try store.boundIdentity(for: context) }
    }
    func load(context: PilotFeedbackContext) throws {
        try loadBinding(context: context)
        guard let identity = identity(for: context) else { return }
        for aspect in PilotFeedbackAspect.allCases {
            let target = PilotFeedbackTarget(identity: identity, aspect: aspect)
            if records[target.key] == nil, let saved = try store.load(target: target) { records[target.key] = saved }
        }
    }
    func set(value: Int?, aspect: PilotFeedbackAspect, context: PilotFeedbackContext) throws {
        guard isActive else { throw PilotError.sessionChanged }
        guard !isSyncing, value == nil || [-1, 1].contains(value!) else { throw PilotError.unavailable }
        try loadBinding(context: context)
        guard let identity = identity(for: context) else { throw PilotError.mappingUnavailable }
        let target = PilotFeedbackTarget(identity: identity, aspect: aspect)
        var record = try records[target.key] ?? store.load(target: target) ?? PilotStableFeedbackRecord(target: target)
        let expected = record.pending?.expectedRevision ?? record.snapshot.revision
        record.pending = PilotFeedbackIntent(value: value, expectedRevision: expected)
        record.conflict = false
        record.locallyEdited = true
        record.migrationConflicts = []
        try persist(record)
        errors[target.key] = nil
    }
    func refresh(context: PilotFeedbackContext) async {
        guard isActive else { return }
        requested.insert(context)
        await synchronize()
    }
    private func persist(_ record: PilotStableFeedbackRecord) throws {
        guard isActive else { throw PilotError.sessionChanged }
        try store.save(record)
        records[record.target.key] = record
    }
    private func requireCurrent() async throws {
        guard isActive else { throw PilotError.sessionChanged }
        try await client.api.auth.requireCurrent(client.session)
        guard isActive else { throw PilotError.sessionChanged }
    }
    private func accessFailed(_ error: Error) async -> Bool {
        guard isActive else { return true }
        if let error = error as? PilotError,
            [.accessDenied, .inviteRequired, .signInRequired, .sessionChanged].contains(error) {
            invalidate()
            await onAccessFailure?(error)
            return true
        }
        return false
    }
    func synchronize() async {
        guard isActive, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await requireCurrent()
            for file in try store.stableFiles() {
                do {
                    let record = try store.loadStable(file: file)
                    records[record.target.key] = record
                } catch { errors[file.deletingPathExtension().lastPathComponent] = "Couldn’t read saved feedback. It is kept on this device." }
            }
            // Finish collecting migrations before any write; two dates can identify the same target.
            let mapping = try await migrateLegacy()
            var targets = Set(records.values.filter { $0.pending != nil }.map(\.target))
            repeat {
                let contexts = requested
                requested.removeAll()
                for context in contexts.sorted(by: { $0.date < $1.date }) {
                    do {
                        try loadBinding(context: context)
                        if identity(for: context) == nil {
                            if mapping.attempted.contains(context.date), mapping.identities[context.date] == nil {
                                throw PilotError.mappingUnavailable
                            }
                            let mapped = try await resolveDisplay(context, mapped: mapping.identities[context.date])
                            try store.bind(mapped, to: context)
                            legacyIdentities[context] = mapped
                        }
                        contextErrors[context] = nil
                        try load(context: context)
                        if let identity = identity(for: context) {
                            targets.formUnion(PilotFeedbackAspect.allCases.map { PilotFeedbackTarget(identity: identity, aspect: $0) })
                        }
                    } catch {
                        if await accessFailed(error) { return }
                        contextErrors[context] = "This older summary could not be matched. You can keep reading; retry feedback when available."
                    }
                }
                while let target = targets.sorted(by: { $0.key < $1.key }).first {
                    targets.remove(target)
                    do {
                        try await synchronize(target: target)
                        errors[target.key] = nil
                    } catch {
                        if await accessFailed(error) { return }
                        errors[target.key] = records[target.key]?.pending == nil
                            ? "Couldn’t refresh feedback. Please try again."
                            : "Saved on this device. Sync will retry when the service is available."
                    }
                }
            } while !requested.isEmpty && isActive
        } catch {
            if await accessFailed(error) { return }
            errors["storage"] = "Couldn’t read saved feedback. It is kept on this device."
        }
    }
    private func resolveDisplay(_ context: PilotFeedbackContext, mapped: PilotContentIdentity?) async throws -> PilotContentIdentity {
        guard let content = context.legacyContent,
            let payload = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
            let normalized = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { throw PilotError.mappingUnavailable }
        let identity: PilotContentIdentity
        if let mapped { identity = mapped } else { identity = try await client.identity(date: context.date) }
        try await requireCurrent()
        let document = try await client.api.briefDocument(date: context.date, session: client.session)
        try await requireCurrent()
        guard document.identity == identity, normalized == Data(document.content.utf8) else {
            throw PilotError.mappingUnavailable
        }
        return identity
    }
    private func migrateLegacy() async throws -> (attempted: Set<String>, identities: [String: PilotContentIdentity]) {
        var mappedDates: Set<String> = []
        var identities: [String: PilotContentIdentity] = [:]
        var additions: [PilotFeedbackTarget: [String: PilotLegacyFeedback]] = [:]
        for date in try store.dates() {
            do {
                let legacy = try store.load(date: date)
                guard !legacy.pending.isEmpty || !legacy.conflicts.isEmpty || requested.contains(where: { $0.date == date }) else { continue }
                var acknowledged: [PilotFeedbackAspect: PilotFeedbackTarget] = [:]
                for record in records.values where record.imported[date] != nil {
                    guard record.imported[date] == PilotLegacyFeedback(legacy, aspect: record.target.aspect) else {
                        throw PilotError.mappingUnavailable
                    }
                    guard acknowledged[record.target.aspect] == nil else { throw PilotError.mappingUnavailable }
                    acknowledged[record.target.aspect] = record.target
                }
                if let article = acknowledged[.selection], let brief = acknowledged[.brief],
                    article.articleID == brief.articleID, brief.briefID != nil {
                    errors[date] = nil
                    continue
                }
                mappedDates.insert(date)
                let identity = try await client.identity(date: date)
                try await requireCurrent()
                for aspect in PilotFeedbackAspect.allCases {
                    let target = PilotFeedbackTarget(identity: identity, aspect: aspect)
                    if let previous = acknowledged[aspect], previous != target { throw PilotError.mappingUnavailable }
                }
                for aspect in PilotFeedbackAspect.allCases where acknowledged[aspect] == nil {
                    additions[PilotFeedbackTarget(identity: identity, aspect: aspect), default: [:]][date] = PilotLegacyFeedback(legacy, aspect: aspect)
                }
                identities[date] = identity
                errors[date] = nil
            } catch {
                if await accessFailed(error) { throw error }
                errors[date] = "An older rating could not be matched to this article. It is kept on this device. Retry when available."
            }
        }
        for target in additions.keys.sorted(by: { $0.key < $1.key }) {
            let sources = additions[target]!
            do {
                let existing = try records[target.key] ?? store.load(target: target)
                var record = existing ?? PilotStableFeedbackRecord(target: target)
                let meaningful = sources.filter { !$0.value.isUntouched }
                if let first = meaningful.values.first {
                    let compatible = meaningful.values.allSatisfy { $0 == first }
                    if record.isUntouched, compatible {
                        record.snapshot = first.snapshot
                        record.pending = first.pending
                        record.conflict = first.conflict
                    } else if !compatible || meaningful.values.contains(where: { $0.pending != nil || $0.conflict }) {
                        record.migrationConflicts.formUnion(meaningful.keys)
                        if !record.locallyEdited {
                            record.pending = nil
                            record.migrationConflicts.formUnion(record.imported.filter { !$0.value.isUntouched }.keys)
                        }
                    }
                }
                record.imported.merge(sources) { old, _ in old }
                try persist(record)
            } catch {
                for date in sources.keys { errors[date] = "Couldn’t read saved feedback. It is kept on this device." }
            }
        }
        return (mappedDates, identities)
    }
    private func synchronize(target: PilotFeedbackTarget) async throws {
        try await requireCurrent()
        var remote = try await client.load(target: target)
        try await requireCurrent()
        var record = records[target.key] ?? PilotStableFeedbackRecord(target: target)
        record.snapshot = remote
        try persist(record)
        guard let intent = record.pending else { return }
        // Initial Undo needs a tombstone to block another device's stale revision-zero vote.
        if remote.value == intent.value && remote.reason == nil && (intent.value != nil || remote.revision > 0) {
            record.pending = nil
        } else if remote.revision != intent.expectedRevision {
            record.pending = nil
            record.conflict = true
        } else {
            do {
                let revision = try await client.set(value: intent.value, target: target, expectedRevision: intent.expectedRevision)
                try await requireCurrent()
                remote = PilotFeedbackValue(value: intent.value, revision: revision)
                record.pending = nil
            } catch PilotError.feedbackConflict {
                remote = try await client.load(target: target)
                try await requireCurrent()
                record.pending = nil
                record.conflict = true
            }
        }
        record.snapshot = remote
        try persist(record)
    }
    func invalidate() {
        isActive = false
        records = [:]
        errors = [:]
        legacyIdentities = [:]
        contextErrors = [:]
        requested = []
    }
}
