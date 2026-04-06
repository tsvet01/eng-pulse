import Foundation
import AVFoundation
import Combine

// MARK: - Audio Player Service
@MainActor
class AudioPlayerService: NSObject, ObservableObject {
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private var sessionConfigured = false

    @Published var isPlaying: Bool = false
    @Published var progress: Double = 0.0
    @Published var duration: TimeInterval = 0.0

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

    func play(from url: URL) throws {
        stop()
        ensureAudioSession()

        audioPlayer = try AVAudioPlayer(contentsOf: url)
        audioPlayer?.delegate = self
        audioPlayer?.prepareToPlay()

        duration = audioPlayer?.duration ?? 0.0

        audioPlayer?.play()
        isPlaying = true
        startProgressTimer()
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func resume() {
        audioPlayer?.play()
        isPlaying = true
        startProgressTimer()
    }

    func stop() {
        stopProgressTimer()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        progress = 0.0
        duration = 0.0
    }

    var currentTime: TimeInterval {
        audioPlayer?.currentTime ?? 0
    }

    func seek(by seconds: TimeInterval) {
        guard let player = audioPlayer else { return }
        let newTime = max(0, min(player.currentTime + seconds, player.duration))
        player.currentTime = newTime
    }

    // MARK: - Progress Tracking

    private func startProgressTimer() {
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self,
                  let player = self.audioPlayer,
                  player.duration > 0 else { return }

            self.progress = player.currentTime / player.duration
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    deinit {
        progressTimer?.invalidate()
    }
}

// MARK: - AVAudioPlayerDelegate
extension AudioPlayerService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.progress = 1.0  // Show complete
            self.stopProgressTimer()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            print("Audio player decode error: \(error?.localizedDescription ?? "unknown")")
            self.stop()
        }
    }
}
