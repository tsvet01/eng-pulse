import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var notificationService: NotificationService
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            HomeViewContent(navigationPath: $navigationPath)
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
                navigateToArticle(url: url)
            }
        }
        .onChange(of: appState.summaries) { _, _ in
            checkPendingArticle()
        }
    }

    private func checkPendingArticle() {
        if let url = UserDefaults.standard.string(forKey: "pendingArticleUrl") {
            navigateToArticle(url: url)
        }
    }

    private func navigateToArticle(url: String) {
        guard !appState.summaries.isEmpty else { return }
        if let summary = appState.summaries.first(where: { $0.url == url }) {
            UserDefaults.standard.removeObject(forKey: "pendingArticleUrl")
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
