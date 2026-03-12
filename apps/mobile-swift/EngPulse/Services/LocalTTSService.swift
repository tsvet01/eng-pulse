import Foundation
import AVFoundation
import SwiftUI
import Combine

// MARK: - Local TTS Service (AVSpeechSynthesizer)
@MainActor
class LocalTTSService: NSObject, ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var currentTextLength: Int = 0
    private var sessionConfigured = false

    @Published var isPlaying: Bool = false
    @Published var progress: Double = 0.0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    private func ensureAudioSession() {
        guard !sessionConfigured else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.allowBluetoothA2DP]
            )
            try AVAudioSession.sharedInstance().setActive(true)
            sessionConfigured = true
        } catch {
            print("Audio session configuration error: \(error)")
        }
    }

    // MARK: - Playback Control

    func speak(text: String, rate: Double, pitch: Double) {
        stop()
        ensureAudioSession()

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(rate)
        utterance.pitchMultiplier = Float(pitch)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        currentTextLength = text.count
        isPlaying = true
        progress = 0.0
        synthesizer.speak(utterance)
    }

    func pause() {
        guard isPlaying else { return }
        synthesizer.pauseSpeaking(at: .immediate)
        isPlaying = false
    }

    func resume() {
        synthesizer.continueSpeaking()
        isPlaying = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        progress = 0.0
        currentTextLength = 0
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension LocalTTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.currentTextLength > 0 else { return }
            self.progress = Double(characterRange.location + characterRange.length) / Double(self.currentTextLength)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = false
            self.progress = 1.0
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = false
            self.progress = 0.0
        }
    }
}
