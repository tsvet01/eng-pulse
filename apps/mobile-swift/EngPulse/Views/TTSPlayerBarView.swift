import SwiftUI

struct TTSPlayerBarView: View {
    let progress: Double
    let isPlaying: Bool
    let isPaused: Bool
    let isLoading: Bool
    let title: String
    let currentTime: String
    let duration: String
    let onToggle: () -> Void
    let onStop: () -> Void
    let onSkipBack: () -> Void
    let onSkipForward: () -> Void

    var body: some View {
        let hasSeek = !currentTime.isEmpty && !duration.isEmpty

        VStack(spacing: 8) {
            // Progress bar
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

            // Timestamps — only shown for Cloud TTS
            if hasSeek {
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

            // Controls: skip back, play/pause, skip forward
            HStack(spacing: 24) {
                Spacer()

                if hasSeek {
                    Button(action: onSkipBack) {
                        Image(systemName: "gobackward.15")
                            .font(.title2)
                            .foregroundColor(.onSurface)
                    }
                    .disabled(isLoading)
                    .accessibilityLabel("Skip back 15 seconds")
                }

                Button(action: onToggle) {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.9)
                    } else {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.accentColor)
                    }
                }
                .disabled(isLoading)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                if hasSeek {
                    Button(action: onSkipForward) {
                        Image(systemName: "goforward.15")
                            .font(.title2)
                            .foregroundColor(.onSurface)
                    }
                    .disabled(isLoading)
                    .accessibilityLabel("Skip forward 15 seconds")
                }

                Spacer()
            }

            // Title + stop
            HStack {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.onSurface)
                    .lineLimit(1)
                Spacer()
                Button(action: onStop) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundColor(.onSurfaceVariant)
                }
                .accessibilityLabel("Stop playback")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        .padding(.horizontal, 12)
    }
}
