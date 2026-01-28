import Foundation
import AVFoundation
import SwiftUI
import Combine

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
    @available(*, deprecated, message: "Use dependency injection instead")
    static let shared = TTSService()

    private var cloudTTS: CloudTTSService?
    private let cacheService = CacheService()
    private let audioPlayer: AudioPlayerService

    @Published var state: TTSState = .stopped
    @Published var progress: Double = 0.0
    @Published var currentArticleUrl: String?
    @Published var errorMessage: String?

    // Settings
    @AppStorage("ttsSpeechRate") var speechRate: Double = 0.55
    @AppStorage("ttsPitch") var pitch: Double = 1.0
    @AppStorage("ttsVoice") var selectedVoice: String = Neural2Voice.maleJ.rawValue

    private var currentText: String?
    private var currentCacheKey: String?
    private var cancellables = Set<AnyCancellable>()

    init(cloudTTS: CloudTTSService? = nil, audioPlayer: AudioPlayerService? = nil) {
        self.audioPlayer = audioPlayer ?? AudioPlayerService()

        if let cloudTTS = cloudTTS {
            self.cloudTTS = cloudTTS
        } else if let apiKey = Bundle.main.infoDictionary?["GoogleCloudTTSAPIKey"] as? String,
                  !apiKey.isEmpty,
                  apiKey != "YOUR_API_KEY" {
            self.cloudTTS = CloudTTSService(apiKey: apiKey)
        } else {
            print("Warning: Google Cloud TTS API key not configured in Info.plist")
        }

        setupAudioPlayerObservers()
    }

    private func setupAudioPlayerObservers() {
        // Forward audio player state
        audioPlayer.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] isPlaying in
                guard let self = self else { return }
                if self.state == .playing && !isPlaying {
                    // Playback finished
                    self.state = .stopped
                    self.currentArticleUrl = nil
                } else if self.state == .paused && isPlaying {
                    self.state = .playing
                }
            }
            .store(in: &cancellables)

        // Forward progress
        audioPlayer.$progress
            .receive(on: RunLoop.main)
            .sink { [weak self] progress in
                self?.progress = progress
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Methods

    /// Start speaking text, stopping any current playback first
    func startSpeaking(_ text: String, articleUrl: String? = nil) {
        stop()

        guard cloudTTS != nil else {
            errorMessage = "Audio playback is not available. Please check app settings."
            return
        }

        let cleanedText = TextCleaner.cleanForSpeech(text)
        currentText = cleanedText
        currentArticleUrl = articleUrl
        errorMessage = nil

        Task {
            await performSpeak(cleanedText)
        }
    }

    private func performSpeak(_ text: String) async {
        guard let cloudTTS = cloudTTS else { return }

        state = .loading

        do {
            // Generate configuration from current settings
            let config = TTSConfiguration.fromAppStorage(
                rate: speechRate,
                pitch: pitch,
                voice: selectedVoice
            )

            // Generate cache key
            let cacheKey = await cacheService.generateAudioCacheKey(text: text, configKey: config.cacheKey)
            currentCacheKey = cacheKey

            // Check cache first
            if let cachedURL = await cacheService.getCachedAudioURL(for: cacheKey) {
                try audioPlayer.play(from: cachedURL)
                state = .playing
                return
            }

            // Not cached - call Cloud TTS API
            let audioData = try await cloudTTS.synthesize(text: text, config: config)

            // Cache the audio
            try await cacheService.cacheAudio(audioData, for: cacheKey)

            // Play from cache
            if let audioURL = await cacheService.getCachedAudioURL(for: cacheKey) {
                try audioPlayer.play(from: audioURL)
                state = .playing

                // Cleanup old cache in background
                Task.detached(priority: .background) { [cacheService] in
                    await cacheService.cleanupOldAudio()
                }
            } else {
                throw CloudTTSError.decodingError
            }

        } catch {
            errorMessage = error.localizedDescription
            state = .stopped
            print("TTS error: \(error)")
        }
    }

    func pause() {
        guard state == .playing else { return }
        audioPlayer.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        audioPlayer.resume()
        state = .playing
    }

    func stop() {
        audioPlayer.stop()
        state = .stopped
        progress = 0.0
        currentArticleUrl = nil
        currentText = nil
        currentCacheKey = nil
        errorMessage = nil
    }

    func togglePlayPause(_ text: String, articleUrl: String? = nil) {
        if state == .playing && currentArticleUrl == articleUrl {
            pause()
        } else if state == .paused && currentArticleUrl == articleUrl {
            resume()
        } else {
            startSpeaking(text, articleUrl: articleUrl)
        }
    }

    func isPlayingArticle(_ url: String) -> Bool {
        (state == .playing || state == .loading) && currentArticleUrl == url
    }
}
