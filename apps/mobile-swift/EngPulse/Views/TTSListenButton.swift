import SwiftUI

struct TTSListenButton: View {
    let isPlaying: Bool
    let isPaused: Bool
    let isLoading: Bool
    let onTap: () -> Void

    private enum Layout {
        static let verticalPadding: CGFloat = 14
        static let cornerRadius: CGFloat = 12
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: isPlaying ? "stop.fill" : (isPaused ? "play.fill" : "headphones"))
                        .font(.title3)
                }

                Text(buttonLabel)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Layout.verticalPadding)
            .background(
                LinearGradient(
                    colors: isPlaying ? [.red, .red.opacity(0.8)] : [.accentColor, .accentColor.opacity(0.8)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.white)
            .cornerRadius(Layout.cornerRadius)
        }
        .disabled(isLoading)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint(accessibilityHintText)
    }

    private var buttonLabel: String {
        if isLoading { return "Generating Audio..." }
        if isPlaying { return "Stop Listening" }
        if isPaused { return "Resume" }
        return "Listen to Summary"
    }

    private var accessibilityLabelText: String {
        if isLoading { return "Generating audio, please wait" }
        if isPlaying { return "Stop listening" }
        if isPaused { return "Resume listening" }
        return "Listen to summary"
    }

    private var accessibilityHintText: String {
        if isPlaying { return "Stops audio playback" }
        if isPaused { return "Continues from where you left off" }
        return "Plays the summary as audio"
    }
}
