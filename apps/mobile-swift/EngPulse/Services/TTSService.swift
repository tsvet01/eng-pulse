import Foundation
import AVFoundation
import SwiftUI
import Combine
import MediaPlayer

// MARK: - TTS State
enum TTSState {
    case stopped
    case loading    // Downloading from Cloud TTS
    case playing
    case paused
}

// MARK: - TTS Service
@MainActor
class TTSService: ObservableObject {
    private var cloudTTS: CloudTTSService?
    private var localTTS: LocalTTSService?
    private(set) var isUsingLocalTTS: Bool = false
    private let cacheService: CacheService
    private let audioPlayer: AudioPlayerService

    @Published var state: TTSState = .stopped
    @Published var progress: Double = 0.0
    @Published var currentArticleUrl: String?
    @Published var currentArticleTitle: String?
    @Published var errorMessage: String?

    // Playlist queue (used by CarPlay and "Play All")
    @Published private(set) var queue: [Summary] = []
    @Published private(set) var queueIndex: Int = 0
    private var queueLoadTask: Task<Void, Never>?

    // Settings
    @AppStorage("ttsSpeechRate") var speechRate: Double = 0.55
    @AppStorage("ttsPitch") var pitch: Double = 1.0
    @AppStorage("ttsVoice") var selectedVoice: String = Neural2Voice.maleJ.rawValue

    private var currentText: String?
    private var currentCacheKey: String?
    private var cancellables = Set<AnyCancellable>()

    init(cacheService: CacheService = CacheService(), cloudTTS: CloudTTSService? = nil, audioPlayer: AudioPlayerService? = nil) {
        self.cacheService = cacheService
        self.audioPlayer = audioPlayer ?? AudioPlayerService()

        if let cloudTTS = cloudTTS {
            self.cloudTTS = cloudTTS
        } else if let apiKey = Bundle.main.infoDictionary?["GoogleCloudTTSAPIKey"] as? String,
                  !apiKey.isEmpty,
                  apiKey != "YOUR_API_KEY" {
            self.cloudTTS = CloudTTSService(apiKey: apiKey)
        } else {
            print("Warning: Google Cloud TTS API key not configured — falling back to local TTS")
            self.localTTS = LocalTTSService()
            self.isUsingLocalTTS = true
        }

        setupAudioPlayerObservers()
        if isUsingLocalTTS {
            setupLocalTTSObservers()
        }

        NowPlayingService.shared.configure(
            onPlay: { [weak self] in self?.resume() },
            onPause: { [weak self] in self?.pause() },
            onSkipForward: { [weak self] in self?.skipForward() },
            onSkipBackward: { [weak self] in self?.skipBackward() },
            onNextTrack: { [weak self] in self?.playNext() },
            onPreviousTrack: { [weak self] in self?.playPrevious() }
        )
    }

    private func handlePlaybackStateChange(_ isPlaying: Bool) {
        if isPlaying {
            state = .playing
        } else if state == .playing {
            // Abnormal stop (decode error, external interruption). Natural
            // finishes arrive via the players' finish callbacks, which always
            // move state off .playing before this deferred sink fires; pause
            // and stop set their state synchronously first.
            state = .stopped
            progress = 0
            if queue.isEmpty {
                NowPlayingService.shared.clearNowPlaying()
            } else {
                // Keep the track visible so play can retry the queue item
                NowPlayingService.shared.updateProgress(currentTime: 0, isPlaying: false)
            }
        }
    }

    /// Explicit natural-finish signal from the players — the only path that
    /// clears resume positions and advances the playlist.
    private func handleTrackFinished(clearPosition: Bool) {
        guard state == .playing else { return }
        if clearPosition, let url = currentArticleUrl { clearSavedPosition(for: url) }
        // Discard the finished player so its end position can't be re-saved
        // by the stop that precedes the next queue item.
        audioPlayer.stop()
        if hasNextInQueue {
            playNext()
        } else {
            state = .stopped
            progress = 0
            clearQueue()
            NowPlayingService.shared.clearNowPlaying()
        }
    }

    private func setupAudioPlayerObservers() {
        audioPlayer.onPlaybackFinished = { [weak self] in
            self?.handleTrackFinished(clearPosition: true)
        }

        audioPlayer.$isPlaying
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handlePlaybackStateChange($0) }
            .store(in: &cancellables)

        audioPlayer.$progress
            .receive(on: RunLoop.main)
            .sink { [weak self] newProgress in
                guard let self = self else { return }
                guard abs(self.progress - newProgress) > 0.001 else { return }
                self.progress = newProgress
                if self.state == .playing {
                    NowPlayingService.shared.updateProgress(
                        currentTime: self.audioPlayer.currentTime,
                        isPlaying: true
                    )
                }
            }
            .store(in: &cancellables)
    }

    private func setupLocalTTSObservers() {
        guard let localTTS = localTTS else { return }

        localTTS.onSpeechFinished = { [weak self] in
            self?.handleTrackFinished(clearPosition: false)
        }

        localTTS.$isPlaying
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handlePlaybackStateChange($0) }
            .store(in: &cancellables)

        localTTS.$progress
            .receive(on: RunLoop.main)
            .sink { [weak self] newProgress in
                guard let self = self, abs(self.progress - newProgress) > 0.001 else { return }
                self.progress = newProgress
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Methods

    /// Start speaking text, stopping any current playback first
    func startSpeaking(_ text: String, articleUrl: String? = nil, articleTitle: String? = nil) {
        // Stop while currentArticleUrl still points at the previous article, so its
        // resume position is saved under its own URL — not the new article's.
        stopPlayback()
        currentArticleUrl = articleUrl
        currentArticleTitle = articleTitle

        errorMessage = nil
        NowPlayingService.shared.setTrack(title: articleTitle ?? "Eng Pulse", duration: 0)

        if isUsingLocalTTS, let localTTS = localTTS {
            state = .loading
            let textToClean = text
            let expectedUrl = articleUrl
            Task {
                let cleanedText = await Task.detached(priority: .userInitiated) {
                    TextCleaner.cleanForSpeech(textToClean)
                }.value
                // A newer article may have started while this text was cleaning
                guard self.currentArticleUrl == expectedUrl, self.state == .loading else { return }
                self.currentText = cleanedText
                localTTS.speak(text: cleanedText, rate: self.speechRate, pitch: self.pitch)
                // state = .playing is set by the localTTS.$isPlaying observer
            }
        } else {
            guard cloudTTS != nil else {
                errorMessage = "Audio playback is not available. Please check app settings."
                return
            }
            state = .loading
            Task {
                await performSpeak(text)
            }
        }
    }

    private func performSpeak(_ text: String) async {
        guard let cloudTTS = cloudTTS else { return }

        let expectedUrl = currentArticleUrl

        // Clean text off main actor
        let cleanedText = await Task.detached(priority: .userInitiated) {
            TextCleaner.cleanForSpeech(text)
        }.value

        guard currentArticleUrl == expectedUrl, state == .loading else { return }
        currentText = cleanedText

        do {
            let config = TTSConfiguration.fromAppStorage(
                rate: speechRate,
                pitch: pitch,
                voice: selectedVoice
            )

            let cacheKey = await cacheService.generateAudioCacheKey(text: cleanedText, configKey: config.cacheKey)
            guard currentArticleUrl == expectedUrl, state == .loading else { return }
            currentCacheKey = cacheKey

            if let cachedURL = await cacheService.getCachedAudioURL(for: cacheKey) {
                guard currentArticleUrl == expectedUrl, state == .loading else { return }
                try audioPlayer.play(from: cachedURL)
                restoreSavedPosition(for: expectedUrl)
                state = .playing
                publishNowPlayingTrack()
                return
            }

            let audioData = try await cloudTTS.synthesize(text: cleanedText, config: config)
            guard currentArticleUrl == expectedUrl, state == .loading else { return }

            try await cacheService.cacheAudio(audioData, for: cacheKey)
            guard currentArticleUrl == expectedUrl, state == .loading else { return }

            if let audioURL = await cacheService.getCachedAudioURL(for: cacheKey) {
                guard currentArticleUrl == expectedUrl, state == .loading else { return }
                try audioPlayer.play(from: audioURL)
                restoreSavedPosition(for: expectedUrl)
                state = .playing
                publishNowPlayingTrack()

                Task.detached(priority: .background) { [cacheService] in
                    await cacheService.cleanupOldAudio()
                }
            } else {
                throw CloudTTSError.decodingError
            }

        } catch {
            if currentArticleUrl == expectedUrl {
                handleQueueItemFailure(error)
            }
            print("TTS error: \(error)")
        }
    }

    /// Shared failure policy for both queue stages (content fetch and audio
    /// synthesis): skip past one bad article, but stop on errors that would
    /// hit every remaining item too.
    private func handleQueueItemFailure(_ error: Error) {
        if hasNextInQueue && !Self.isSystemicPlaybackError(error) {
            // Skip unplayable articles instead of stalling the playlist
            playNext()
        } else {
            errorMessage = error.localizedDescription
            state = .stopped
            // Keep the queue and track info so play can retry from the car
            NowPlayingService.shared.updateProgress(currentTime: 0, isPlaying: false)
        }
    }

    /// Errors that will affect every queue item alike (offline, server
    /// outage), where skipping ahead would just cascade failures.
    private static func isSystemicPlaybackError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed,
                    .cannotFindHost, .cannotConnectToHost, .timedOut,
                    .dataNotAllowed, .internationalRoamingOff].contains(urlError.code)
        }
        if case ArticleContentLoader.LoadError.httpError(let statusCode) = error {
            return statusCode >= 500 || statusCode == 429
        }
        return false
    }

    /// Seek to a previously saved resume position, if one exists and is sane.
    /// A position at or past the end of the audio would make playback finish
    /// instantly, so it is discarded instead of applied.
    private func restoreSavedPosition(for articleUrl: String?) {
        guard let articleUrl, let savedPosition = getSavedPosition(for: articleUrl) else { return }
        clearSavedPosition(for: articleUrl)
        if savedPosition < audioPlayer.duration - 1 {
            audioPlayer.seek(to: savedPosition)
        }
    }


    func pause() {
        guard state == .playing else { return }
        savePlaybackPosition()
        if isUsingLocalTTS {
            localTTS?.pause()
        } else {
            audioPlayer.pause()
        }
        state = .paused
        NowPlayingService.shared.updateProgress(currentTime: audioPlayer.currentTime, isPlaying: false)
    }

    func resume() {
        if state == .paused {
            if isUsingLocalTTS {
                localTTS?.resume()
            } else {
                audioPlayer.resume()
            }
            state = .playing
        } else if state == .stopped, !queue.isEmpty {
            // Play pressed after a queue item failed — retry the current item
            playCurrentQueueItem()
        }
    }

    /// Stop playback without clearing article identity (used by startSpeaking to avoid bar flash)
    private func stopPlayback() {
        savePlaybackPosition()
        if isUsingLocalTTS {
            localTTS?.stop()
        } else {
            audioPlayer.stop()
        }
        state = .stopped
        progress = 0.0
        currentText = nil
        currentCacheKey = nil
        errorMessage = nil
        NowPlayingService.shared.clearNowPlaying()
    }

    func stop() {
        if let url = currentArticleUrl { clearSavedPosition(for: url) }
        stopPlayback()
        currentArticleUrl = nil
        currentArticleTitle = nil
        clearQueue()
    }

    /// Text is an autoclosure so pause/resume taps don't pay for building the
    /// speech text (insight briefs decode JSON to produce it).
    func togglePlayPause(_ text: @autoclosure () -> String, articleUrl: String? = nil, articleTitle: String? = nil) {
        if currentArticleUrl == articleUrl, state == .playing || state == .paused {
            togglePauseResume()
        } else {
            // Playing a single article directly abandons any playlist
            clearQueue()
            startSpeaking(text(), articleUrl: articleUrl, articleTitle: articleTitle)
        }
    }

    // MARK: - Playlist Queue

    var hasNextInQueue: Bool { queueIndex + 1 < queue.count }
    var hasPreviousInQueue: Bool { !queue.isEmpty && queueIndex > 0 }

    /// Play a list of articles as a playlist. Content is fetched per article
    /// (cache first) and playback auto-advances when an article finishes.
    func playQueue(_ summaries: [Summary]) {
        guard !summaries.isEmpty else { return }
        queue = summaries
        queueIndex = 0
        playCurrentQueueItem()
    }

    func playNext() {
        guard hasNextInQueue else { return }
        queueIndex += 1
        playCurrentQueueItem()
    }

    func playPrevious() {
        guard hasPreviousInQueue else { return }
        queueIndex -= 1
        playCurrentQueueItem()
    }

    private func clearQueue() {
        queueLoadTask?.cancel()
        queueLoadTask = nil
        queue = []
        queueIndex = 0
        updateQueueCommands()
    }

    private func updateQueueCommands() {
        NowPlayingService.shared.updateQueueNavigation(
            hasNext: hasNextInQueue,
            hasPrevious: hasPreviousInQueue
        )
    }

    private func playCurrentQueueItem() {
        let summary = queue[queueIndex]
        updateQueueCommands()
        queueLoadTask?.cancel()

        // Stop first (saving the previous article's position), then take on
        // the new article's identity so UIs show it as loading.
        stopPlayback()
        currentArticleUrl = summary.url
        currentArticleTitle = summary.title
        state = .loading
        NowPlayingService.shared.setTrack(title: summary.title, duration: 0)
        NowPlayingService.shared.updateProgress(currentTime: 0, isPlaying: false)

        queueLoadTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let content = try await ArticleContentLoader.load(summary, cacheService: self.cacheService)
                guard !Task.isCancelled, self.currentArticleUrl == summary.url else { return }
                let text = SpeechTextBuilder.speechText(for: summary, content: content)
                self.startSpeaking(text, articleUrl: summary.url, articleTitle: summary.title)
            } catch {
                guard !Task.isCancelled, self.currentArticleUrl == summary.url else { return }
                self.handleQueueItemFailure(error)
            }
        }
    }

    /// Pause or resume whatever is currently playing, regardless of article.
    func togglePauseResume() {
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .loading, .stopped: break
        }
    }

    func isPlayingArticle(_ url: String) -> Bool {
        (state == .playing || state == .loading) && currentArticleUrl == url
    }

    /// Push the real title/duration to the now-playing info once audio is loaded,
    /// so lock screen and CarPlay show an accurate progress bar.
    private func publishNowPlayingTrack() {
        NowPlayingService.shared.setTrack(
            title: currentArticleTitle ?? "Eng Pulse",
            duration: audioPlayer.duration
        )
        NowPlayingService.shared.updateProgress(
            currentTime: audioPlayer.currentTime,
            isPlaying: true
        )
    }

    func skipForward(seconds: TimeInterval = 15) {
        guard state == .playing || state == .paused else { return }
        guard !isUsingLocalTTS else { return }
        audioPlayer.seek(by: seconds)
    }

    func skipBackward(seconds: TimeInterval = 15) {
        guard state == .playing || state == .paused else { return }
        guard !isUsingLocalTTS else { return }
        audioPlayer.seek(by: -seconds)
    }

    var currentTimeFormatted: String {
        guard !isUsingLocalTTS else { return "" }
        return formatTime(audioPlayer.currentTime)
    }

    var durationFormatted: String {
        guard !isUsingLocalTTS else { return "" }
        return formatTime(audioPlayer.duration)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        seconds.mmss
    }

    // MARK: - Resume Position

    private func savePlaybackPosition() {
        // Only an active session may write a resume position: after a natural
        // finish (state == .stopped) the player can still report a stale
        // currentTime for the article that just ended.
        guard state == .playing || state == .paused, let url = currentArticleUrl else { return }
        let position = audioPlayer.currentTime
        if position > 0 {
            UserDefaults.standard.set(position, forKey: "tts_position_\(url)")
        }
    }

    func getSavedPosition(for articleUrl: String) -> TimeInterval? {
        let pos = UserDefaults.standard.double(forKey: "tts_position_\(articleUrl)")
        return pos > 0 ? pos : nil
    }

    func clearSavedPosition(for articleUrl: String) {
        UserDefaults.standard.removeObject(forKey: "tts_position_\(articleUrl)")
    }
}
