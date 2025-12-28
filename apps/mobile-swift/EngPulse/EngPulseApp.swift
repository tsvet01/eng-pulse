import SwiftUI

@main
struct EngPulseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var notificationService = NotificationService.shared
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
        // Set up notification delegate
        UNUserNotificationCenter.current().delegate = notificationService

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

    private let apiService = APIService()
    private let cacheService = CacheService()

    func loadSummaries() async {
        isLoading = true
        errorMessage = nil

        do {
            summaries = try await apiService.fetchSummaries()
            // Cache the summaries
            try await cacheService.cacheSummaries(summaries)
            isOffline = false  // Successfully loaded from network
        } catch {
            // Try loading from cache on error
            if let cached = try? await cacheService.getCachedSummaries(), !cached.isEmpty {
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
