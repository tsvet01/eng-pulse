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

    private var nowPlayingInfo = [String: Any]()

    func setTrack(title: String, duration: TimeInterval) {
        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        nowPlayingInfo[MPMediaItemPropertyArtist] = "Eng Pulse"
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
    }

    func updateProgress(currentTime: TimeInterval, isPlaying: Bool) {
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func clearNowPlaying() {
        nowPlayingInfo.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
