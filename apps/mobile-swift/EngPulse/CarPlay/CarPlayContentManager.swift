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
///
/// Templates are rebuilt only when the article data changes; playback changes
/// just toggle the playing indicator on the existing rows.
@MainActor
final class CarPlayContentManager {
    private let interfaceController: CPInterfaceController
    private let appState: AppState
    private let ttsService: TTSService
    private var cancellables = Set<AnyCancellable>()

    private let latestTemplate: CPListTemplate
    private let topicsTemplate: CPListTemplate

    /// Category list currently pushed from the Topics tab (its Category rides
    /// in `userInfo`), refreshed on data changes until it is popped.
    private weak var pushedCategoryTemplate: CPListTemplate?

    /// Live article rows keyed by article URL, so playback changes can flip
    /// the playing indicator without rebuilding the lists.
    private var articleItemsByUrl: [String: [CPListItem]] = [:]

    private var isPresentingNowPlaying = false

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

        rebuildTemplates()
        observeChanges()

        // CarPlay can launch the app without the phone UI ever appearing,
        // so trigger the article load from here as well.
        Task { await appState.loadSummaries() }
    }

    func disconnect() {
        cancellables.removeAll()
        articleItemsByUrl.removeAll()
    }

    // MARK: - Observation

    private func observeChanges() {
        // dropFirst: @Published replays its current value on subscription and
        // connect() already did an initial build.
        appState.$summaries
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildTemplates() }
            .store(in: &cancellables)

        ttsService.$currentArticleUrl
            .combineLatest(ttsService.$state.map { $0 == .playing || $0 == .loading })
            .dropFirst()
            .removeDuplicates(by: { $0 == $1 })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.updatePlayingIndicators() }
            .store(in: &cancellables)
    }

    private func rebuildTemplates() {
        articleItemsByUrl.removeAll()
        let summaries = appState.summaries
        let latest = CarPlayContentBuilder.latestArticles(from: summaries, limit: articleLimit)
        let groups = CarPlayContentBuilder.categoryGroups(from: summaries, limitPerCategory: articleLimit)

        latestTemplate.updateSections(playableSections(for: latest))
        topicsTemplate.updateSections(topicSections(from: groups))

        if let template = pushedCategoryTemplate,
           let category = template.userInfo as? Category {
            let articles = groups.first(where: { $0.category == category })?.articles ?? []
            template.updateSections(playableSections(for: articles))
        }

        updatePlayingIndicators()
    }

    private func updatePlayingIndicators() {
        let activeUrl = (ttsService.state == .playing || ttsService.state == .loading)
            ? ttsService.currentArticleUrl : nil
        for (url, items) in articleItemsByUrl {
            let isPlaying = url == activeUrl
            for item in items where item.isPlaying != isPlaying {
                item.isPlaying = isPlaying
            }
        }
    }

    // MARK: - Sections

    /// The shared playable-list shape: a Play All row, then the article rows.
    private func playableSections(for articles: [Summary]) -> [CPListSection] {
        guard !articles.isEmpty else { return [] }
        return [
            CPListSection(items: [playAllItem(for: articles)]),
            CPListSection(items: articles.map { articleItem(for: $0) })
        ]
    }

    private func topicSections(from groups: [CarPlayContentBuilder.CategoryGroup]) -> [CPListSection] {
        guard !groups.isEmpty else { return [] }
        let items = groups.map { group in
            let item = CPListItem(
                text: group.category.displayName,
                detailText: "\(group.totalCount) article\(group.totalCount == 1 ? "" : "s")",
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

    private func showCategory(_ category: Category) {
        let groups = CarPlayContentBuilder.categoryGroups(from: appState.summaries, limitPerCategory: articleLimit)
        let articles = groups.first(where: { $0.category == category })?.articles ?? []
        let template = CPListTemplate(title: category.displayName, sections: playableSections(for: articles))
        template.userInfo = category
        pushedCategoryTemplate = template
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
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.play([summary])
                completion()
            }
        }
        articleItemsByUrl[summary.url, default: []].append(item)
        return item
    }

    // MARK: - Playback

    private func play(_ articles: [Summary]) {
        ttsService.playQueue(articles)
        showNowPlaying()
    }

    private func showNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        guard !isPresentingNowPlaying, interfaceController.topTemplate !== nowPlaying else { return }
        isPresentingNowPlaying = true
        let completion: (Bool, Error?) -> Void = { [weak self] _, _ in
            Task { @MainActor in self?.isPresentingNowPlaying = false }
        }
        if interfaceController.templates.contains(where: { $0 === nowPlaying }) {
            interfaceController.pop(to: nowPlaying, animated: true, completion: completion)
        } else {
            interfaceController.pushTemplate(nowPlaying, animated: true, completion: completion)
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
