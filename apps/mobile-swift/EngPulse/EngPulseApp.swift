import SwiftUI

@main
struct EngPulseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var notificationService = NotificationService.shared
    @StateObject private var ttsService = TTSService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Configure app appearance
        configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(notificationService)
                .environmentObject(ttsService)
                .task {
                    await setupNotifications()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Clear badge when app becomes active
                UNUserNotificationCenter.current().setBadgeCount(0)
            }
        }
    }

    private func configureAppearance() {
        // Configure navigation bar appearance
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }

    private func setupNotifications() async {
        // Note: Delegate is set in AppDelegate.didFinishLaunchingWithOptions (must be early for notification taps)

        // Request authorization
        let granted = await notificationService.requestAuthorization()
        print("Notification permission: \(granted ? "granted" : "denied")")

        // Subscribe to daily briefings topic
        if granted {
            notificationService.subscribeToTopic("daily_briefings")
        }
    }
}

// MARK: - App Delegate for Push Notifications
class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Set notification delegate early - critical for handling notification taps
        UNUserNotificationCenter.current().delegate = NotificationService.shared
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

    // Note: Swift 6 warning about non-Sendable [AnyHashable: Any] is unavoidable
    // until Apple updates UIApplicationDelegate protocol to be Sendable-compatible
    nonisolated func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        // Extract only the Sendable data we need before crossing actor boundary
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
    @Published var pendingArticleUrl: String?

    private let apiService = APIService()
    let cacheService = CacheService()

    func loadSummaries() async {
        errorMessage = nil

        // Phase 1: Show cached data instantly (no spinner)
        if summaries.isEmpty,
           let cached = try? await cacheService.getCachedSummaries(), !cached.isEmpty {
            summaries = cached
            isOffline = true
        }

        // Phase 2: Fetch fresh data from network
        // Only show loading spinner if we have no cached data
        if summaries.isEmpty { isLoading = true }

        do {
            let fresh = try await apiService.fetchSummaries()
            summaries = fresh
            try? await cacheService.cacheSummaries(fresh)
            isOffline = false
            // Phase 3: Prefetch top articles in background
            prefetchArticles(Array(fresh.prefix(5)))
        } catch {
            if summaries.isEmpty {
                errorMessage = error.localizedDescription
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
                // Skip if already cached
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
