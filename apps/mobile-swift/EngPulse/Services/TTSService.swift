import Foundation
import AVFoundation
import SwiftUI

// MARK: - TTS State
enum TTSState {
    case stopped
    case playing
    case paused
}

// MARK: - TTS Service
@MainActor
class TTSService: NSObject, ObservableObject {
    static let shared = TTSService()

    private let synthesizer = AVSpeechSynthesizer()

    @Published var state: TTSState = .stopped
    @Published var progress: Double = 0.0
    @Published var currentArticleUrl: String?

    // Settings (0.55 = faster than default for quicker reading)
    @AppStorage("ttsSpeechRate") var speechRate: Double = 0.55
    @AppStorage("ttsPitch") var pitch: Double = 1.0

    private var currentText: String?
    private var currentUtterance: AVSpeechUtterance?

    private override init() {
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session configuration error: \(error)")
        }
    }

    // MARK: - Public Methods

    func speak(_ text: String, articleUrl: String? = nil) {
        stop()

        let cleanedText = cleanTextForSpeech(text)
        currentText = cleanedText
        currentArticleUrl = articleUrl

        let utterance = AVSpeechUtterance(string: cleanedText)
        utterance.rate = Float(speechRate) * AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = Float(pitch)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        currentUtterance = utterance
        state = .playing
        synthesizer.speak(utterance)
    }

    func pause() {
        guard state == .playing else { return }
        synthesizer.pauseSpeaking(at: .immediate)
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        synthesizer.continueSpeaking()
        state = .playing
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        state = .stopped
        progress = 0.0
        currentArticleUrl = nil
        currentText = nil
        currentUtterance = nil
    }

    func togglePlayPause(_ text: String, articleUrl: String? = nil) {
        if state == .playing && currentArticleUrl == articleUrl {
            pause()
        } else if state == .paused && currentArticleUrl == articleUrl {
            resume()
        } else {
            speak(text, articleUrl: articleUrl)
        }
    }

    func isPlayingArticle(_ url: String) -> Bool {
        state == .playing && currentArticleUrl == url
    }

    // MARK: - Text Cleaning

    private func cleanTextForSpeech(_ text: String) -> String {
        var cleaned = text

        // Remove markdown headings
        cleaned = cleaned.replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)

        // Remove bold/italic markers
        cleaned = cleaned.replacingOccurrences(of: "\\*{1,2}([^*]+)\\*{1,2}", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "_{1,2}([^_]+)_{1,2}", with: "$1", options: .regularExpression)

        // Remove inline code
        cleaned = cleaned.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)

        // Remove code blocks
        cleaned = cleaned.replacingOccurrences(of: "```[\\s\\S]*?```", with: "", options: .regularExpression)

        // Remove links but keep text
        cleaned = cleaned.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)

        // Remove images
        cleaned = cleaned.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]+\\)", with: "", options: .regularExpression)

        // Remove HTML tags
        cleaned = cleaned.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Remove horizontal rules
        cleaned = cleaned.replacingOccurrences(of: "(?m)^[-*_]{3,}\\s*$", with: "", options: .regularExpression)

        // Remove list markers
        cleaned = cleaned.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?m)^\\s*\\d+\\.\\s+", with: "", options: .regularExpression)

        // Remove blockquote markers
        cleaned = cleaned.replacingOccurrences(of: "(?m)^\\s*>\\s*", with: "", options: .regularExpression)

        // Normalize whitespace
        cleaned = cleaned.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension TTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.state = .playing
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.state = .stopped
            self.progress = 0.0
            self.currentArticleUrl = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.state = .stopped
            self.progress = 0.0
            self.currentArticleUrl = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.state = .paused
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.state = .playing
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let totalLength = utterance.speechString.count
            if totalLength > 0 {
                self.progress = Double(characterRange.location + characterRange.length) / Double(totalLength)
            }
        }
    }
}
