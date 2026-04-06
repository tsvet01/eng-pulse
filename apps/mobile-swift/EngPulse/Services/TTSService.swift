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
            onSkipBackward: { [weak self] in self?.skipBackward() }
        )
    }

    private func handlePlaybackStateChange(_ isPlaying: Bool, clearPosition: Bool) {
        if isPlaying {
            state = .playing
        } else if state == .playing {
            if clearPosition, let url = currentArticleUrl { clearSavedPosition(for: url) }
            state = .stopped
            progress = 0
            NowPlayingService.shared.clearNowPlaying()
        }
    }

    private func setupAudioPlayerObservers() {
        audioPlayer.$isPlaying
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.handlePlaybackStateChange($0, clearPosition: true) }
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

        localTTS.$isPlaying
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.handlePlaybackStateChange($0, clearPosition: false) }
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
        currentArticleUrl = articleUrl
        currentArticleTitle = articleTitle
        stopPlayback()

        errorMessage = nil
        NowPlayingService.shared.setTrack(title: articleTitle ?? "Eng Pulse", duration: 0)

        if isUsingLocalTTS, let localTTS = localTTS {
            state = .loading
            let textToClean = text
            Task {
                let cleanedText = await Task.detached(priority: .userInitiated) {
                    TextCleaner.cleanForSpeech(textToClean)
                }.value
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
                if let savedPosition = getSavedPosition(for: expectedUrl ?? "") {
                    audioPlayer.seek(by: savedPosition)
                    clearSavedPosition(for: expectedUrl ?? "")
                }
                state = .playing
                return
            }

            let audioData = try await cloudTTS.synthesize(text: cleanedText, config: config)
            guard currentArticleUrl == expectedUrl, state == .loading else { return }

            try await cacheService.cacheAudio(audioData, for: cacheKey)
            guard currentArticleUrl == expectedUrl, state == .loading else { return }

            if let audioURL = await cacheService.getCachedAudioURL(for: cacheKey) {
                guard currentArticleUrl == expectedUrl, state == .loading else { return }
                try audioPlayer.play(from: audioURL)
                if let savedPosition = getSavedPosition(for: expectedUrl ?? "") {
                    audioPlayer.seek(by: savedPosition)
                    clearSavedPosition(for: expectedUrl ?? "")
                }
                state = .playing

                Task.detached(priority: .background) { [cacheService] in
                    await cacheService.cleanupOldAudio()
                }
            } else {
                throw CloudTTSError.decodingError
            }

        } catch {
            if currentArticleUrl == expectedUrl {
                errorMessage = error.localizedDescription
                state = .stopped
            }
            print("TTS error: \(error)")
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
        guard state == .paused else { return }
        if isUsingLocalTTS {
            localTTS?.resume()
        } else {
            audioPlayer.resume()
        }
        state = .playing
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
    }

    func togglePlayPause(_ text: String, articleUrl: String? = nil, articleTitle: String? = nil) {
        if state == .playing && currentArticleUrl == articleUrl {
            pause()
        } else if state == .paused && currentArticleUrl == articleUrl {
            resume()
        } else {
            startSpeaking(text, articleUrl: articleUrl, articleTitle: articleTitle)
        }
    }

    func isPlayingArticle(_ url: String) -> Bool {
        (state == .playing || state == .loading) && currentArticleUrl == url
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
        guard let url = currentArticleUrl else { return }
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
