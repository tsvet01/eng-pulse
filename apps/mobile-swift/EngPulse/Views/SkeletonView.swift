import SwiftUI

// MARK: - Shimmer Modifier

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    colors: [.clear, Color.onSurface.opacity(0.08), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase)
                .mask(content)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 800
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - Skeleton Card

struct SkeletonCardView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.containerHigh)
                    .frame(width: 60, height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.containerHigh)
                    .frame(width: 80, height: 12)
            }
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.containerHigh)
                .frame(height: 18)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.containerHigh)
                .frame(width: 220, height: 18)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.containerHigh)
                .frame(height: 14)
        }
        .padding(DesignTokens.cardPadding)
        .background(Color.container)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
        .shimmer()
    }
}

// MARK: - Skeleton Feed

struct SkeletonFeedView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(0..<5, id: \.self) { _ in
                    SkeletonCardView()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color.surface)
    }
}
