import SwiftUI

@main
struct EngPulseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var notificationService = NotificationService.shared

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

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Clear badge when app becomes active
        application.applicationIconBadgeNumber = 0
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

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        Task { @MainActor in
            NotificationService.shared.handleNotification(userInfo)
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
