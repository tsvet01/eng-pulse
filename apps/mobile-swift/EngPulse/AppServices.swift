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

    private init() {
        let cache = CacheService()
        cacheService = cache
        appState = AppState(cacheService: cache)
        ttsService = TTSService(cacheService: cache)
    }
}
