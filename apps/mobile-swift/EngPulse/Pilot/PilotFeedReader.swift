import Foundation

struct PilotContentIdentity: Codable, Equatable, Hashable, Sendable {
    let articleID: UUID
    let briefID: UUID
    enum CodingKeys: String, CodingKey { case articleID = "article_id", briefID = "brief_id" }
}

struct PilotBriefContent: Codable, Equatable, Sendable {
    let content: String
    var identity: PilotContentIdentity? = nil
    func feedbackContext(date: String) -> PilotFeedbackContext {
        PilotFeedbackContext(date: date, identity: identity, legacyContent: identity == nil ? content : nil)
    }
}

struct PilotFeedbackContext: Hashable, Sendable {
    let date: String
    var identity: PilotContentIdentity? = nil
    var legacyContent: String? = nil
}

struct PilotBriefSummary: Codable, Equatable, Sendable {
    let date: String
    let title: String
    let articleURL: String
    let snippet: String
    let model: String?
    let evalScore: Double?
    enum CodingKeys: String, CodingKey {
        case date, snippet, model
        case title = "article_title", articleURL = "article_url", evalScore = "eval_score"
    }
}

extension PilotBriefSummary {
    static func validDate(_ date: String) -> Bool {
        guard date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: date).map { formatter.string(from: $0) == date } ?? false
    }
}

extension PilotAPIClient {
    func engineeringFeedID(session: PilotSession) async throws -> UUID {
        struct Feed: Decodable { let id: UUID; let slug: String; let member: Bool; let is_active: Bool }
        let data = try await request(path: "feeds", session: session)
        guard let feeds = try? JSONDecoder().decode([Feed].self, from: data) else { throw PilotError.invalidResponse }
        let engineering = feeds.filter { $0.slug == "engineering" && $0.member && $0.is_active }
        guard engineering.count == 1, let feed = engineering.first else { throw PilotError.accessDenied }
        return feed.id
    }

    func engineeringBriefs(session: PilotSession) async throws -> [PilotBriefSummary] {
        let feedID = try await engineeringFeedID(session: session)
        let rows = try await request(path: "feeds/\(feedID.uuidString.lowercased())/briefs",
            query: [URLQueryItem(name: "limit", value: "100")], session: session)
        guard let briefs = try? JSONDecoder().decode([PilotBriefSummary].self, from: rows),
              briefs.count <= 100, briefs.allSatisfy({ PilotBriefSummary.validDate($0.date) }),
              Set(briefs.map(\.date)).count == briefs.count else { throw PilotError.invalidResponse }
        return briefs.sorted { $0.date > $1.date }
    }

    func briefContent(date: String, session: PilotSession) async throws -> String {
        try await briefDocument(date: date, session: session).content
    }

    func briefDocument(date: String, session: PilotSession) async throws -> PilotBriefContent {
        guard PilotBriefSummary.validDate(date) else { throw PilotError.invalidResponse }
        let data = try await request(path: "briefs/engineering/\(date)", session: session)
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["feed_slug"] as? String == "engineering", envelope["date"] as? String == date,
              envelope["format"] as? String == "insight-brief-v3",
              let payload = envelope["payload"] as? [String: Any],
              let json = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let content = String(data: json, encoding: .utf8) else { throw PilotError.invalidResponse }
        var identity: PilotContentIdentity?
        if envelope["article_id"] != nil || envelope["brief_id"] != nil {
            guard let decoded = try? JSONDecoder().decode(PilotContentIdentity.self, from: data) else {
                throw PilotError.invalidResponse
            }
            identity = decoded
        }
        return PilotBriefContent(content: content, identity: identity)
    }
}

actor PilotFeedStore {
    nonisolated let directory: URL
    init(root: URL, identity: UUID, user: UUID) {
        directory = root.appendingPathComponent(identity.uuidString).appendingPathComponent(user.uuidString).appendingPathComponent("engineering")
    }
    private func write(_ data: Data, file: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(file), options: .atomic)
    }
    func save(_ items: [PilotBriefSummary]) throws { try write(JSONEncoder().encode(items), file: "briefs.json") }
    func summaries() throws -> [PilotBriefSummary]? {
        let file = directory.appendingPathComponent("briefs.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode([PilotBriefSummary].self, from: Data(contentsOf: file))
    }
    func save(_ content: String, date: String) throws {
        guard PilotBriefSummary.validDate(date) else { throw PilotError.invalidResponse }
        try write(Data(content.utf8), file: "\(date).json")
    }
    private struct CachedDocument: Codable {
        let version: Int
        let document: PilotBriefContent
        enum CodingKeys: String, CodingKey { case version = "_pilot_cache_version", document }
    }
    func save(_ document: PilotBriefContent, date: String) throws {
        guard PilotBriefSummary.validDate(date) else { throw PilotError.invalidResponse }
        try write(JSONEncoder().encode(CachedDocument(version: 1, document: document)), file: "\(date).json")
    }
    func content(date: String) throws -> String? { try document(date: date)?.content }
    func document(date: String) throws -> PilotBriefContent? {
        guard PilotBriefSummary.validDate(date) else { throw PilotError.invalidResponse }
        let file = directory.appendingPathComponent("\(date).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["_pilot_cache_version"] != nil {
            let cached = try JSONDecoder().decode(CachedDocument.self, from: data)
            guard cached.version == 1 else { throw PilotError.invalidResponse }
            return cached.document
        }
        guard let raw = String(data: data, encoding: .utf8) else { throw PilotError.invalidResponse }
        return PilotBriefContent(content: raw)
    }
    func cacheSize() -> Int64 {
        guard let files = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        return files.reduce(Int64(0)) { total, file in
            guard let file = file as? URL,
                  let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return total }
            return total + Int64(values.fileSize ?? 0)
        }
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}

func pilotAllowsOffline(_ error: Error) -> Bool {
    if error as? PilotError == .unavailable || error as? PilotError == .rateLimited { return true }
    guard let error = error as? URLError else { return false }
    return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
}

@MainActor
final class PilotFeedReader {
    let session: PilotSession
    let store: PilotFeedStore
    private let api: PilotAPIClient
    private(set) var isActive = true
    var onAccessFailure: ((PilotError) async -> Void)?
    init(api: PilotAPIClient, session: PilotSession, store: PilotFeedStore) {
        self.api = api; self.session = session; self.store = store
    }
    func invalidate() { isActive = false }
    private func requireCurrent() async throws {
        guard isActive else { throw PilotError.sessionChanged }
        try await api.auth.requireCurrent(session)
        guard isActive else { throw PilotError.sessionChanged }
    }
    func cachedSummaries() async throws -> [PilotBriefSummary]? {
        try await requireCurrent()
        let items = try await store.summaries()
        try await requireCurrent()
        return items
    }
    func summaries() async throws -> (items: [PilotBriefSummary], offline: Bool) {
        try await requireCurrent()
        do {
            let items = try await api.engineeringBriefs(session: session)
            try await requireCurrent()
            try? await store.save(items)
            try await requireCurrent()
            return (items, false)
        } catch {
            await accessFailed(error)
            if pilotAllowsOffline(error), let cached = try await cachedSummaries() { return (cached, true) }
            throw error
        }
    }
    func content(date: String) async throws -> String { try await document(date: date).content }
    func document(date: String) async throws -> PilotBriefContent {
        try await requireCurrent()
        if let cached = try await store.document(date: date) {
            try await requireCurrent()
            return cached
        }
        do {
            let content = try await api.briefDocument(date: date, session: session)
            try await requireCurrent()
            try? await store.save(content, date: date)
            try await requireCurrent()
            return content
        } catch {
            await accessFailed(error)
            throw error
        }
    }
    private func accessFailed(_ error: Error) async {
        if let error = error as? PilotError, [.accessDenied, .inviteRequired, .signInRequired, .sessionChanged].contains(error) {
            invalidate()
            await onAccessFailure?(error)
        }
    }
    func clearCache() async throws { try await store.clear() }
}
