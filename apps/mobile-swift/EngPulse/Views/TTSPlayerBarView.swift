import SwiftUI

/// What the player bar should say when playback and the screen disagree.
struct PlaybackChrome: Equatable {
    var title: String
    var nowPlayingLabel: String?
    var secondaryActionTitle: String?
    var secondaryActionHint: String?
    var secondaryActionEnabled: Bool

    /// Article screen. The bar stays for the article that owns the session
    /// (including after it finishes, so it can be replayed). On any other
    /// article the bar names the active session and offers to start this one.
    static func forArticle(
        onScreenURL: String,
        onScreenTitle: String,
        playingURL: String?,
        playingTitle: String?,
        state: TTSState,
        canStartOnScreenArticle: Bool
    ) -> PlaybackChrome? {
        let ownsSession = playingURL == onScreenURL
        guard state != .stopped || ownsSession else { return nil }
        if ownsSession {
            return PlaybackChrome(
                title: onScreenTitle,
                nowPlayingLabel: nil,
                secondaryActionTitle: nil,
                secondaryActionHint: nil,
                secondaryActionEnabled: false
            )
        }
        return PlaybackChrome(
            title: playingTitle ?? "Eng Pulse",
            nowPlayingLabel: "Now playing",
            secondaryActionTitle: "Play this article",
            secondaryActionHint: "Stops the article that is playing and starts this one",
            secondaryActionEnabled: canStartOnScreenArticle
        )
    }

    /// Feed and other non-article screens. Visible only while a session is
    /// active, so leaving an article does not hide what is playing.
    static func forLibrary(
        playingURL: String?,
        playingTitle: String?,
        state: TTSState,
        canOpenArticle: Bool
    ) -> PlaybackChrome? {
        guard state != .stopped, playingURL != nil else { return nil }
        return PlaybackChrome(
            title: playingTitle ?? "Eng Pulse",
            nowPlayingLabel: "Now playing",
            secondaryActionTitle: canOpenArticle ? "Open article" : nil,
            secondaryActionHint: canOpenArticle ? "Returns to the article that is playing" : nil,
            secondaryActionEnabled: canOpenArticle
        )
    }
}

struct TTSPlayerBarView: View {
    let progress: Double
    let isPlaying: Bool
    let isLoading: Bool
    let title: String
    let currentTime: String
    let duration: String
    let onToggle: () -> Void
    let onStop: () -> Void
    let onSkipBack: () -> Void
    let onSkipForward: () -> Void
    var nowPlayingLabel: String? = nil
    var secondaryActionTitle: String? = nil
    var secondaryActionHint: String? = nil
    var secondaryActionEnabled: Bool = true
    var onSecondaryAction: (() -> Void)? = nil

    var body: some View {
        let hasSeek = !currentTime.isEmpty && !duration.isEmpty

        VStack(spacing: 8) {
            if let nowPlayingLabel {
                nowPlayingHeader(nowPlayingLabel)
            }

            progressBar

            if hasSeek {
                timestamps
            }

            transport(hasSeek: hasSeek)

            if nowPlayingLabel == nil {
                titleRow
            }

            if let secondaryActionTitle, let onSecondaryAction {
                secondaryButton(secondaryActionTitle, hint: secondaryActionHint, action: onSecondaryAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.adaptive(dark: .black.opacity(0.3), light: .black.opacity(0.1)), radius: 16, y: 8)
        .padding(.horizontal, 12)
    }

    private func nowPlayingHeader(_ label: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.accentColor)
                    .textCase(.uppercase)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.onSurface)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label), \(title)")

            stopButton
        }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.onSurfaceVariant.opacity(0.15))
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    private var timestamps: some View {
        HStack {
            Text(currentTime)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.onSurfaceVariant)
            Spacer()
            Text(duration)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.onSurfaceVariant)
        }
    }

    private func transport(hasSeek: Bool) -> some View {
        HStack(spacing: 24) {
            Spacer()

            Button(action: onSkipBack) {
                Image(systemName: "gobackward.15")
                    .font(.title2)
                    .foregroundColor(.onSurface)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(isLoading || !hasSeek)
            .accessibilityLabel("Skip back 15 seconds")

            Button(action: onToggle) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.9)
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.accentColor)
                }
            }
            .disabled(isLoading)
            .accessibilityLabel(transportAccessibilityLabel)

            Button(action: onSkipForward) {
                Image(systemName: "goforward.15")
                    .font(.title2)
                    .foregroundColor(.onSurface)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(isLoading || !hasSeek)
            .accessibilityLabel("Skip forward 15 seconds")

            Spacer()
        }
    }

    private var transportAccessibilityLabel: String {
        if isLoading { return "Loading audio" }
        if isPlaying { return "Pause" }
        if nowPlayingLabel != nil { return "Resume now playing" }
        return "Play"
    }

    private var titleRow: some View {
        HStack {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.onSurface)
                .lineLimit(1)
            Spacer()
            stopButton
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "xmark.circle.fill")
                .font(.body)
                .foregroundColor(.onSurfaceVariant)
        }
        .accessibilityLabel("Stop playback")
    }

    private func secondaryButton(_ title: String, hint: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!secondaryActionEnabled)
        .accessibilityLabel(title)
        .accessibilityHint(hint ?? "")
    }
}

/// Shared wiring from `TTSService` into the bar.
struct ActivePlaybackBar: View {
    @ObservedObject var tts: TTSService
    let chrome: PlaybackChrome
    let onToggle: () -> Void
    var onSecondary: () -> Void = {}

    var body: some View {
        TTSPlayerBarView(
            progress: tts.progress,
            isPlaying: tts.state == .playing,
            isLoading: tts.state == .loading,
            title: chrome.title,
            currentTime: tts.currentTimeFormatted,
            duration: tts.durationFormatted,
            onToggle: onToggle,
            onStop: { tts.stop() },
            onSkipBack: { tts.skipBackward() },
            onSkipForward: { tts.skipForward() },
            nowPlayingLabel: chrome.nowPlayingLabel,
            secondaryActionTitle: chrome.secondaryActionTitle,
            secondaryActionHint: chrome.secondaryActionHint,
            secondaryActionEnabled: chrome.secondaryActionEnabled,
            onSecondaryAction: chrome.secondaryActionTitle == nil ? nil : onSecondary
        )
    }
}
