import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var notificationService: NotificationService
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var navigationPath = NavigationPath()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $navigationPath) {
                HomeViewContent(navigationPath: $navigationPath)
            }
            .tabItem {
                Label("Feed", systemImage: "newspaper.fill")
            }
            .tag(0)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(1)
        }
        .task {
            await appState.loadSummaries()
        }
        .onAppear {
            checkPendingArticle()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                checkPendingArticle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveArticleNotification)) { notification in
            if let url = notification.userInfo?["url"] as? String {
                selectedTab = 0
                navigateToArticle(url: url)
            }
        }
        .onChange(of: appState.summaries) { _, summaries in
            // Retry navigation when summaries load
            checkPendingArticle()
        }
    }

    private func checkPendingArticle() {
        if let url = UserDefaults.standard.string(forKey: "pendingArticleUrl") {
            selectedTab = 0
            navigateToArticle(url: url)
        }
    }

    private func navigateToArticle(url: String) {
        guard !appState.summaries.isEmpty else { return }
        if let summary = appState.summaries.first(where: { $0.url == url }) {
            UserDefaults.standard.removeObject(forKey: "pendingArticleUrl")
            // Defer navigation to next run loop to ensure UI is ready
            DispatchQueue.main.async {
                navigationPath.append(summary)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(NotificationService.shared)
}
