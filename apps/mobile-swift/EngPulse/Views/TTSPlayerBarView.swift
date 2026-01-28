import SwiftUI

struct TTSPlayerBarView: View {
    let progress: Double
    let isPlaying: Bool
    let isPaused: Bool
    let isLoading: Bool
    let title: String
    let onToggle: () -> Void
    let onStop: () -> Void

    private enum Layout {
        static let progressBarHeight: CGFloat = 2
        static let controlPadding: CGFloat = 10
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * progress)
            }
            .frame(height: Layout.progressBarHeight)

            HStack(spacing: 16) {
                Button(action: onToggle) {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.9)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                }
                .disabled(isLoading)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(isLoading ? "Generating audio..." : (isPlaying ? "Playing..." : "Paused"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(title), \(isLoading ? "generating audio" : (isPlaying ? "playing" : "paused"))")
                .accessibilityValue("\(Int(progress * 100)) percent complete")

                Spacer()

                Button(action: onStop) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .accessibilityLabel("Stop playback")
            }
            .padding(.horizontal)
            .padding(.vertical, Layout.controlPadding)
        }
        .background(.ultraThinMaterial)
    }
}
