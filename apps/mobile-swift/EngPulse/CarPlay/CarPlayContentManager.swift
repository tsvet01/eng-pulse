import CarPlay
import Combine
import UIKit

// MARK: - CarPlay Content Manager
/// Builds and updates the CarPlay template hierarchy, bridging article data
/// (AppState) and audio playback (TTSService) to CarPlay's tab/list templates.
///
/// Layout:
/// - "Latest" tab: Play All (playlist) + every article, newest first
/// - "Topics" tab: categories that drill into per-category lists with Play All
/// Tapping an article plays just that article; Play All queues the whole list.
@MainActor
final class CarPlayContentManager {
    private let interfaceController: CPInterfaceController
    private let appState: AppState
    private let ttsService: TTSService
    private var cancellables = Set<AnyCancellable>()

    private let latestTemplate: CPListTemplate
    private let topicsTemplate: CPListTemplate

    /// Category list currently pushed from the Topics tab, refreshed on data changes.
    private weak var pushedCategoryTemplate: CPListTemplate?
    private var pushedCategory: Category?

    /// Leave room for the Play All row within CarPlay's list item limit.
    private var articleLimit: Int {
        max(0, CPListTemplate.maximumItemCount - 1)
    }

    init(interfaceController: CPInterfaceController, appState: AppState, ttsService: TTSService) {
        self.interfaceController = interfaceController
        self.appState = appState
        self.ttsService = ttsService
        latestTemplate = Self.makeTabTemplate(title: "Latest", systemImage: "newspaper.fill")
        topicsTemplate = Self.makeTabTemplate(title: "Topics", systemImage: "square.grid.2x2.fill")
    }

    func connect() {
        let tabBar = CPTabBarTemplate(templates: [latestTemplate, topicsTemplate])
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)

        reloadTemplates()
        observeChanges()

        // CarPlay can launch the app without the phone UI ever appearing,
        // so trigger the article load from here as well.
        Task { await appState.loadSummaries() }
    }

    func disconnect() {
        cancellables.removeAll()
    }

    // MARK: - Observation

    private func observeChanges() {
        appState.$summaries
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadTemplates() }
            .store(in: &cancellables)

        // Keep the per-row playing indicator in sync with playback.
        ttsService.$currentArticleUrl
            .removeDuplicates()
            .combineLatest(
                ttsService.$state
                    .map { $0 == .playing || $0 == .loading }
                    .removeDuplicates()
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.reloadTemplates() }
            .store(in: &cancellables)
    }

    private func reloadTemplates() {
        let summaries = appState.summaries
        latestTemplate.updateSections(latestSections(from: summaries))
        topicsTemplate.updateSections(topicSections(from: summaries))

        if let category = pushedCategory, let template = pushedCategoryTemplate {
            template.updateSections(categorySections(for: category, from: summaries))
        }
    }

    // MARK: - Sections

    private func latestSections(from summaries: [Summary]) -> [CPListSection] {
        let articles = CarPlayContentBuilder.latestArticles(from: summaries, limit: articleLimit)
        guard !articles.isEmpty else { return [] }
        return [
            CPListSection(items: [playAllItem(for: articles)]),
            CPListSection(items: articles.map { articleItem(for: $0) })
        ]
    }

    private func topicSections(from summaries: [Summary]) -> [CPListSection] {
        let groups = CarPlayContentBuilder.categoryGroups(from: summaries, limitPerCategory: articleLimit)
        guard !groups.isEmpty else { return [] }

        let items = groups.map { group in
            let count = group.articles.count
            let item = CPListItem(
                text: group.category.displayName,
                detailText: "\(count) article\(count == 1 ? "" : "s")",
                image: UIImage(systemName: group.category.iconName)
            )
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.showCategory(group.category)
                    completion()
                }
            }
            return item
        }
        return [CPListSection(items: items)]
    }

    private func categorySections(for category: Category, from summaries: [Summary]) -> [CPListSection] {
        let groups = CarPlayContentBuilder.categoryGroups(from: summaries, limitPerCategory: articleLimit)
        guard let group = groups.first(where: { $0.category == category }) else { return [] }
        return [
            CPListSection(items: [playAllItem(for: group.articles)]),
            CPListSection(items: group.articles.map { articleItem(for: $0) })
        ]
    }

    private func showCategory(_ category: Category) {
        let template = CPListTemplate(
            title: category.displayName,
            sections: categorySections(for: category, from: appState.summaries)
        )
        pushedCategoryTemplate = template
        pushedCategory = category
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Items

    private func playAllItem(for articles: [Summary]) -> CPListItem {
        let item = CPListItem(
            text: "Play All (\(articles.count))",
            detailText: "Listen as a playlist",
            image: UIImage(systemName: "play.circle.fill")
        )
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.play(articles)
                completion()
            }
        }
        return item
    }

    private func articleItem(for summary: Summary) -> CPListItem {
        let item = CPListItem(
            text: summary.title,
            detailText: CarPlayContentBuilder.detailText(for: summary)
        )
        item.playingIndicatorLocation = .trailing
        item.isPlaying = ttsService.isPlayingArticle(summary.url)
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.play([summary])
                completion()
            }
        }
        return item
    }

    // MARK: - Playback

    private func play(_ articles: [Summary]) {
        ttsService.playQueue(articles)
        showNowPlaying()
    }

    private func showNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        guard interfaceController.topTemplate !== nowPlaying else { return }
        if interfaceController.templates.contains(where: { $0 === nowPlaying }) {
            interfaceController.pop(to: nowPlaying, animated: true, completion: nil)
        } else {
            interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }

    // MARK: - Template Factory

    private static func makeTabTemplate(title: String, systemImage: String) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.tabImage = UIImage(systemName: systemImage)
        template.emptyViewTitleVariants = ["No Articles"]
        template.emptyViewSubtitleVariants = ["Waiting for the latest digest…"]
        return template
    }
}
