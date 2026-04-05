import MediaPlayer

@MainActor
class NowPlayingService {
    static let shared = NowPlayingService()

    func configure(onPlay: @escaping () -> Void, onPause: @escaping () -> Void,
                   onSkipForward: @escaping () -> Void, onSkipBackward: @escaping () -> Void) {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { _ in onPlay(); return .success }

        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { _ in onPause(); return .success }

        center.skipForwardCommand.removeTarget(nil)
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { _ in onSkipForward(); return .success }

        center.skipBackwardCommand.removeTarget(nil)
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { _ in onSkipBackward(); return .success }
    }

    func updateNowPlaying(title: String, progress: Double, duration: TimeInterval, currentTime: TimeInterval, isPlaying: Bool) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = "Eng Pulse"
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
