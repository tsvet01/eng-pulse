import SwiftUI

@main
struct EngPulseApp: App {
    @StateObject private var appState = AppState()

    init() {
        // Configure app appearance
        configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }

    private func configureAppearance() {
        // Configure navigation bar appearance
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
}

// MARK: - App State
@MainActor
class AppState: ObservableObject {
    @Published var summaries: [Summary] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isOffline = false

    private let apiService = APIService()
    private let cacheService = CacheService()

    func loadSummaries() async {
        isLoading = true
        errorMessage = nil

        do {
            summaries = try await apiService.fetchSummaries()
            // Cache the summaries
            try await cacheService.cacheSummaries(summaries)
        } catch {
            // Try loading from cache on error
            if let cached = try? await cacheService.getCachedSummaries() {
                summaries = cached
                isOffline = true
            } else {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    func refreshSummaries() async {
        await loadSummaries()
    }
}
