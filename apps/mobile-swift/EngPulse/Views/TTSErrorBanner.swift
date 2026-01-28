import SwiftUI

struct TTSErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(message)
                    .font(.caption)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
    }
}
