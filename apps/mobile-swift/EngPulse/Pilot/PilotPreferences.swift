import Combine
import Foundation

enum PilotTopicChoice: String, CaseIterable { case neutral, interested, excluded }
enum PilotTechnicalDepth: String, Codable, CaseIterable { case introductory, intermediate, advanced }

struct PilotPreferenceChoices: Codable, Equatable {
    var interests: [String] = []
    var depthByTopic: [String: PilotTechnicalDepth] = [:]
    var excludedTopics: [String] = []
    enum CodingKeys: String, CodingKey {
        case interests, depthByTopic = "depth_by_topic", excludedTopics = "excluded_topics"
    }
}

struct PilotTopic: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
}

struct PilotPreferencesSnapshot: Decodable {
    let preferences: PilotPreferenceChoices
    let revision: Int64
    let learnedResetAt: String?
    let topics: [PilotTopic]
    enum CodingKeys: String, CodingKey {
        case preferences, revision, learnedResetAt = "learned_reset_at", topics
    }
    var isValid: Bool {
        let catalog = Set(topics.map(\.id))
        let interests = Set(preferences.interests)
        let excluded = Set(preferences.excludedTopics)
        return revision >= 0 && !catalog.isEmpty && catalog.count == topics.count
            && interests.count == preferences.interests.count && excluded.count == preferences.excludedTopics.count
            && interests.isSubset(of: catalog) && excluded.isSubset(of: catalog) && interests.isDisjoint(with: excluded)
            && Set(preferences.depthByTopic.keys).isSubset(of: interests)
    }
}

@MainActor
final class PilotPreferencesModel: ObservableObject {
    @Published private(set) var saved: PilotPreferencesSnapshot?
    @Published private(set) var draft = PilotPreferenceChoices()
    @Published private(set) var isBusy = false
    @Published private(set) var needsReload = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var savedMessage: String?
    var onAccessFailure: ((PilotError) async -> Void)?
    private var isActive = true
    private let api: PilotAPIClient
    private let session: PilotSession
    var hasChanges: Bool { saved.map { $0.preferences != draft } ?? false }

    init(api: PilotAPIClient, session: PilotSession) { self.api = api; self.session = session }

    func invalidate() {
        isActive = false
        saved = nil; draft = PilotPreferenceChoices(); errorMessage = nil; savedMessage = nil
    }

    func choice(for topic: String) -> PilotTopicChoice {
        if draft.interests.contains(topic) { return .interested }
        return draft.excludedTopics.contains(topic) ? .excluded : .neutral
    }

    func setChoice(_ choice: PilotTopicChoice, topic: String) {
        guard isActive, !isBusy, saved?.topics.contains(where: { $0.id == topic }) == true else { return }
        guard choice != self.choice(for: topic) else { return }
        draft.interests.removeAll { $0 == topic }
        draft.excludedTopics.removeAll { $0 == topic }
        if choice == .interested { draft.interests.append(topic) }
        else { draft.depthByTopic.removeValue(forKey: topic) }
        if choice == .excluded { draft.excludedTopics.append(topic) }
        savedMessage = nil
    }

    func setDepth(_ depth: PilotTechnicalDepth?, topic: String) {
        guard isActive, !isBusy, draft.interests.contains(topic) else { return }
        draft.depthByTopic[topic] = depth
        savedMessage = nil
    }

    func load(discardDraft: Bool = false) async {
        guard isActive, !isBusy else { return }
        guard discardDraft || (!hasChanges && !needsReload) else { return }
        isBusy = true; errorMessage = nil; savedMessage = nil
        defer { isBusy = false }
        do {
            let response = try await api.response(path: "me/preferences", version: .v2, session: session)
            try apply(response.data)
        } catch { await failed(error) }
    }

    func save(resetLearned: Bool = false) async {
        guard isActive, !isBusy, !needsReload, let saved, hasChanges || resetLearned else { return }
        isBusy = true; errorMessage = nil; savedMessage = nil
        defer { isBusy = false }
        struct Update: Encodable {
            let preferences: PilotPreferenceChoices
            let reset_learned: Bool
        }
        do {
            let body = try JSONEncoder().encode(Update(preferences: draft, reset_learned: resetLearned))
            let response = try await api.response(path: "me/preferences", method: "PUT", body: body,
                headers: ["X-Expected-Revision": String(saved.revision)], version: .v2, session: session)
            try apply(response.data)
            if isActive { savedMessage = "Saved to your account" }
        } catch {
            // A lost response may follow a committed write. Read before another edit can overwrite it.
            if isActive { needsReload = true }
            await failed(error)
        }
    }

    private func apply(_ data: Data) throws {
        guard isActive else { throw PilotError.sessionChanged }
        guard let snapshot = try? JSONDecoder().decode(PilotPreferencesSnapshot.self, from: data), snapshot.isValid
        else { throw PilotError.invalidResponse }
        saved = snapshot; draft = snapshot.preferences; needsReload = false
    }

    private func failed(_ error: Error) async {
        guard isActive else { return }
        errorMessage = error.localizedDescription
        if let error = error as? PilotError,
           [.accessDenied, .inviteRequired, .signInRequired, .sessionChanged].contains(error) {
            await onAccessFailure?(error)
        }
    }
}
