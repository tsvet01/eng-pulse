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
    private var cloudTTS: CloudTTSService?
    private var localTTS: LocalTTSService?
    private(set) var isUsingLocalTTS: Bool = false
    private let cacheService: CacheService
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
    }

    private func setupAudioPlayerObservers() {
        // Forward audio player state
        audioPlayer.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] isPlaying in
                guard let self = self else { return }
                if self.state == .playing && !isPlaying {
                    self.state = .stopped
                    self.currentArticleUrl = nil
                } else if self.state == .paused && isPlaying {
                    self.state = .playing
                }
            }
            .store(in: &cancellables)

        audioPlayer.$progress
            .receive(on: RunLoop.main)
            .sink { [weak self] progress in
                self?.progress = progress
            }
            .store(in: &cancellables)
    }

    private func setupLocalTTSObservers() {
        guard let localTTS = localTTS else { return }

        localTTS.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] isPlaying in
                guard let self = self else { return }
                if self.state == .playing && !isPlaying {
                    self.state = .stopped
                    self.currentArticleUrl = nil
                } else if self.state == .paused && isPlaying {
                    self.state = .playing
                }
            }
            .store(in: &cancellables)

        localTTS.$progress
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

        currentArticleUrl = articleUrl
        errorMessage = nil

        if isUsingLocalTTS, let localTTS = localTTS {
            // Clean text off main thread for local TTS
            let textToClean = text
            Task {
                let cleanedText = await Task.detached(priority: .userInitiated) {
                    TextCleaner.cleanForSpeech(textToClean)
                }.value
                self.currentText = cleanedText
                localTTS.speak(text: cleanedText, rate: self.speechRate, pitch: self.pitch)
                self.state = .playing
            }
        } else {
            guard cloudTTS != nil else {
                errorMessage = "Audio playback is not available. Please check app settings."
                return
            }
            Task {
                await performSpeak(text)
            }
        }
    }

    private func performSpeak(_ text: String) async {
        guard let cloudTTS = cloudTTS else { return }

        state = .loading

        // Clean text off main actor
        let cleanedText = await Task.detached(priority: .userInitiated) {
            TextCleaner.cleanForSpeech(text)
        }.value
        currentText = cleanedText

        do {
            let config = TTSConfiguration.fromAppStorage(
                rate: speechRate,
                pitch: pitch,
                voice: selectedVoice
            )

            let cacheKey = await cacheService.generateAudioCacheKey(text: cleanedText, configKey: config.cacheKey)
            currentCacheKey = cacheKey

            if let cachedURL = await cacheService.getCachedAudioURL(for: cacheKey) {
                try audioPlayer.play(from: cachedURL)
                state = .playing
                return
            }

            let audioData = try await cloudTTS.synthesize(text: cleanedText, config: config)

            try await cacheService.cacheAudio(audioData, for: cacheKey)

            if let audioURL = await cacheService.getCachedAudioURL(for: cacheKey) {
                try audioPlayer.play(from: audioURL)
                state = .playing

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
        if isUsingLocalTTS {
            localTTS?.pause()
        } else {
            audioPlayer.pause()
        }
        state = .paused
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

    func stop() {
        if isUsingLocalTTS {
            localTTS?.stop()
        } else {
            audioPlayer.stop()
        }
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
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
