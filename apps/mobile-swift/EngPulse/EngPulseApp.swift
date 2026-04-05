import SwiftUI
import FirebaseCore
import FirebaseAuth

@main
struct EngPulseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState: AppState
    @StateObject private var ttsService: TTSService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let cache = CacheService()
        _appState = StateObject(wrappedValue: AppState(cacheService: cache))
        _ttsService = StateObject(wrappedValue: TTSService(cacheService: cache))
        configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(ttsService)
                .task {
                    await setupNotifications()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                UNUserNotificationCenter.current().setBadgeCount(0)
            }
        }
    }

    private func configureAppearance() {
        let dark = Color.Dark.surface
        let light = Color.Light.surface
        let navBg = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = navBg
        appearance.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }

    private func setupNotifications() async {
        let granted = await NotificationService.shared.requestAuthorization()
        print("Notification permission: \(granted ? "granted" : "denied")")
        if granted {
            NotificationService.shared.subscribeToTopic("daily_briefings")
        }
    }
}

// MARK: - App Delegate for Push Notifications
class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        UNUserNotificationCenter.current().delegate = NotificationService.shared

        // Sign in anonymously (fire-and-forget, retries on next launch if fails)
        if Auth.auth().currentUser == nil {
            Auth.auth().signInAnonymously { _, error in
                if let error {
                    print("Anonymous auth failed: \(error.localizedDescription)")
                }
            }
        }

        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            NotificationService.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("Failed to register for remote notifications: \(error)")
    }

    nonisolated func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let articleUrl = userInfo["article_url"] as? String
        await MainActor.run {
            if let url = articleUrl {
                NotificationCenter.default.post(
                    name: .didReceiveArticleNotification,
                    object: nil,
                    userInfo: ["url": url]
                )
            }
        }
        return .newData
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
    let cacheService: CacheService

    init(cacheService: CacheService = CacheService()) {
        self.cacheService = cacheService
    }

    func loadSummaries() async {
        errorMessage = nil
        isOffline = false

        // Always show cached data immediately — never wait for network
        if summaries.isEmpty,
           let cached = try? await cacheService.getCachedSummaries(), !cached.isEmpty {
            summaries = cached
        }

        // Refresh in background — never set isLoading if we already have data
        if summaries.isEmpty { isLoading = true }

        do {
            let fresh = try await apiService.fetchSummaries()
            summaries = fresh
            try? await cacheService.cacheSummaries(fresh)
            isOffline = false
            prefetchArticles(Array(fresh.prefix(5)))
        } catch {
            if summaries.isEmpty {
                errorMessage = error.localizedDescription
            } else {
                isOffline = true
            }
        }

        isLoading = false
    }

    func refreshSummaries() async {
        await loadSummaries()
    }

    func clearCache() async {
        await cacheService.clearAll()
    }

    private func prefetchArticles(_ articles: [Summary]) {
        for article in articles {
            Task.detached(priority: .utility) { [cacheService] in
                if await cacheService.getCachedContent(for: article.url) != nil { return }
                guard let url = URL(string: article.url) else { return }
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let content = String(data: data, encoding: .utf8) {
                        try? await cacheService.cacheContent(content, for: article.url)
                    }
                } catch {}
            }
        }
    }
}
