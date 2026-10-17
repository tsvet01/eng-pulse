import Combine
import Foundation

/// One current reader is shared by every phone window and CarPlay scene.
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()
    let cacheService: CacheService
    let appState: AppState
    let ttsService: TTSService
    let pilotAccountModel: PilotAccountModel?
    @Published private(set) var pilotReader: PilotReaderContext?
    private var accountObservation: AnyCancellable?

    private convenience init() {
        if PilotBuild.isEnabled, let config = try? PilotConfiguration.from() {
            let auth = PilotAuthClient(configuration: config, storage: PilotKeychain())
            let api = PilotAPIClient(configuration: config, auth: auth)
            let model = PilotAccountModel(auth: auth, api: api,
                admissionStorage: PilotKeychain(service: "org.tsvetkov.eng-pulse.admitted-account"))
            self.init(account: model, api: api)
        } else { self.init(account: nil, api: nil) }
    }

    init(account: PilotAccountModel?, api: PilotAPIClient?, cacheRoot: URL? = nil) {
        let cache = CacheService()
        cacheService = cache
        appState = AppState(cacheService: cache)
        ttsService = TTSService(cacheService: cache)
        pilotAccountModel = account
        guard let account, let api else { return }
        let root = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EngPulsePilot", isDirectory: true)
        accountObservation = account.$phase.removeDuplicates().sink { [weak self] phase in
            self?.updateReader(phase, api: api, root: root)
        }
    }

    private func updateReader(_ phase: PilotAccountModel.Phase, api: PilotAPIClient, root: URL) {
        if case .admitted(let session, let user) = phase,
           let current = pilotReader, current.session == session, current.user.id == user.id, current.reader.isActive {
            return
        }
        pilotReader?.invalidate()
        pilotReader = nil
        guard case .admitted(let session, let user) = phase else { return }
        let context = PilotReaderContext(api: api, session: session, user: user, root: root)
        context.reader.onAccessFailure = { [weak self, weak context] error in
            guard let self, let context, self.pilotReader === context else { return }
            self.pilotAccountModel?.readerFailed(error, session: session)
        }
        pilotReader = context
    }
}

@MainActor
final class PilotReaderContext {
    let session: PilotSession
    let user: PilotUser
    let reader: PilotFeedReader
    let appState: AppState
    let ttsService: TTSService
    var id: UUID { session.id }

    init(api: PilotAPIClient, session: PilotSession, user: PilotUser, root: URL) {
        self.session = session; self.user = user
        let store = PilotFeedStore(root: root, identity: session.identity.id, user: user.id)
        let reader = PilotFeedReader(api: api, session: session, store: store)
        self.reader = reader
        let cache = CacheService(directory: store.directory.appendingPathComponent("media")) { summary in
            try await reader.content(date: summary.date)
        }
        appState = AppState(cacheService: cache, pilotReader: reader, scope: "\(session.identity.id)/\(user.id)")
        ttsService = TTSService(cacheService: cache)
    }

    func invalidate() {
        reader.invalidate()
        appState.invalidate()
        ttsService.invalidate()
    }
}
