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
        // Shared with the CarPlay scene so both surfaces drive the same
        // article list and audio playback
        let services = AppServices.shared
        _appState = StateObject(wrappedValue: services.appState)
        _ttsService = StateObject(wrappedValue: services.ttsService)
        configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if PilotBuild.allowsLegacyServices {
                    ContentView()
                } else {
                    PilotEntryView()
                }
            }
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
        guard PilotBuild.allowsLegacyServices else { return }
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
        guard PilotBuild.allowsLegacyServices else { return true }
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
        guard PilotBuild.allowsLegacyServices else { return .noData }
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
    private var activeLoad: Task<Void, Never>?
    private let pilotReader: PilotFeedReader?
    private let scope: String?
    private var isActive = true
    private var didLoadPilotCache = false

    init(cacheService: CacheService = CacheService(), pilotReader: PilotFeedReader? = nil, scope: String? = nil) {
        self.cacheService = cacheService
        self.pilotReader = pilotReader
        self.scope = scope
        isLoading = pilotReader != nil
    }

    /// Coalesces concurrent callers (phone UI and the CarPlay scene can both
    /// trigger a load at launch) into a single fetch.
    func loadSummaries() async {
        guard isActive, pilotReader != nil || PilotBuild.allowsLegacyServices else { return }
        if let activeLoad {
            await activeLoad.value
            return
        }
        let task = Task { await performLoadSummaries() }
        activeLoad = task
        await task.value
        activeLoad = nil
    }

    private func performLoadSummaries() async {
        if let pilotReader { await performPilotLoad(pilotReader); return }
        errorMessage = nil
        isOffline = false

        // Always show cached data immediately — never wait for network
        if summaries.isEmpty,
           let cached = try? await cacheService.getCachedSummaries(), !cached.isEmpty {
            summaries = cached.filter(\.isInsightBrief)
        }

        // Refresh in background — never set isLoading if we already have data
        if summaries.isEmpty { isLoading = true }

        do {
            let fresh = try await apiService.fetchSummaries().filter(\.isInsightBrief)
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

    func loadCachedSummaries() async {
        guard let reader = pilotReader, isActive, !didLoadPilotCache else { return }
        didLoadPilotCache = true
        if let cached = try? await reader.cachedSummaries(), isActive, !Task.isCancelled {
            summaries = cached.map(pilotSummary)
        }
        if isActive { isLoading = summaries.isEmpty }
    }

    private func performPilotLoad(_ reader: PilotFeedReader) async {
        errorMessage = nil
        await loadCachedSummaries()
        guard isActive else { return }
        isLoading = summaries.isEmpty
        defer { isLoading = false }
        do {
            let result = try await reader.summaries()
            guard isActive, !Task.isCancelled else { return }
            summaries = result.items.map(pilotSummary)
            isOffline = result.offline
            prefetchArticles(Array(summaries.prefix(5)))
        } catch {
            guard isActive, !Task.isCancelled else { return }
            summaries = []
            isOffline = false
            errorMessage = error.localizedDescription
        }
    }

    private func pilotSummary(_ row: PilotBriefSummary) -> Summary {
        Summary(date: row.date, url: "eng-pulse://\(scope ?? "")/engineering/\(row.date)",
            title: row.title, summarySnippet: row.snippet, originalUrl: row.articleURL,
            model: row.model, evalScore: row.evalScore, format: "insight-brief-v3")
    }

    func invalidate() {
        isActive = false
        activeLoad?.cancel()
        activeLoad = nil
        summaries = []
        isLoading = false
        isOffline = false
        errorMessage = nil
    }

    func refreshSummaries() async {
        await loadSummaries()
    }

    func clearCache() async {
        try? await pilotReader?.clearCache()
        await cacheService.clearAll()
    }

    func formattedCacheSize() async -> String {
        if let pilotReader {
            let bytes = await pilotReader.store.cacheSize()
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return await cacheService.formattedCacheSize()
    }

    private func prefetchArticles(_ articles: [Summary]) {
        for article in articles {
            Task.detached(priority: .utility) { [cacheService] in
                // Loader is cache-first and validates HTTP status, so prefetch
                // can never poison the cache with an error page
                _ = try? await ArticleContentLoader.load(article, cacheService: cacheService)
            }
        }
    }
}
