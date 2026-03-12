import SwiftUI

struct TTSErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .accessibilityLabel("Dismiss error")
        }
        .padding()
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .combine)
    }
}
