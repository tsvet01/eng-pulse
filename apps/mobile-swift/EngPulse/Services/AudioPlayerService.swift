import Foundation
import AVFoundation
import Combine

// MARK: - Audio Player Service
@MainActor
class AudioPlayerService: NSObject, ObservableObject {
    enum PlaybackError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "Audio could not start. Check your audio output and try again."
        }
    }
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private var sessionConfigured = false

    @Published var isPlaying: Bool = false
    @Published var progress: Double = 0.0
    @Published var duration: TimeInterval = 0.0

    /// Called when a track plays through to its natural end (not on stop/pause
    /// or decode errors), so callers can distinguish completion from
    /// interruption without inferring it from `isPlaying` flips.
    var onPlaybackFinished: (() -> Void)?
    var onPlaybackFailed: (() -> Void)?

    private func ensureAudioSession() throws {
        if !sessionConfigured {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.allowBluetoothA2DP]
            )
            sessionConfigured = true
        }
        // Interruptions can deactivate an already configured session.
        try AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - Playback Control

    func play(from url: URL) throws {
        stop()
        do {
            try ensureAudioSession()
        } catch {
            throw PlaybackError.unavailable
        }
        // Keep file/decoder errors distinct from unavailable audio output so a
        // playlist can skip an invalid article instead of stopping every item.
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        guard player.prepareToPlay(), player.play() else { throw PlaybackError.unavailable }
        audioPlayer = player
        duration = player.duration
        isPlaying = true
        startProgressTimer()
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func resume() throws {
        do {
            try ensureAudioSession()
            guard let audioPlayer, audioPlayer.play() else { throw PlaybackError.unavailable }
            isPlaying = true
            startProgressTimer()
        } catch {
            stop()
            throw PlaybackError.unavailable
        }
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

    func seek(to time: TimeInterval) {
        guard let player = audioPlayer else { return }
        player.currentTime = max(0, min(time, player.duration))
    }

    func seek(by seconds: TimeInterval) {
        guard let player = audioPlayer else { return }
        seek(to: player.currentTime + seconds)
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
            guard self.audioPlayer === player else { return }
            guard flag else {
                self.stop()
                self.onPlaybackFailed?()
                return
            }
            self.isPlaying = false
            self.progress = 1.0  // Show complete
            self.stopProgressTimer()
            self.onPlaybackFinished?()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.audioPlayer === player else { return }
            print("Audio player decode error: \(error?.localizedDescription ?? "unknown")")
            self.stop()
            self.onPlaybackFailed?()
        }
    }
}
