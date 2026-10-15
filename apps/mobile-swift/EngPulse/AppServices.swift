import Foundation

// MARK: - App Services
/// Shared service container so the SwiftUI app and the CarPlay scene
/// operate on the same state and playback pipeline. CarPlay can launch
/// the app without the phone UI, so services can't live inside the App struct.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let cacheService: CacheService
    let appState: AppState
    let ttsService: TTSService
    let pilotAccountModel: PilotAccountModel?

    private init() {
        let cache = CacheService()
        cacheService = cache
        appState = AppState(cacheService: cache)
        ttsService = TTSService(cacheService: cache)
        if PilotBuild.isEnabled, let config = try? PilotConfiguration.from() {
            let auth = PilotAuthClient(configuration: config, storage: PilotKeychain())
            pilotAccountModel = PilotAccountModel(auth: auth, api: PilotAPIClient(configuration: config, auth: auth))
        } else { pilotAccountModel = nil }
    }
}
