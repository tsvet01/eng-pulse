import SwiftUI
import UIKit

// MARK: - Hex initializer
extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

// MARK: - Adaptive color helper
extension Color {
    static func adaptive(dark: Color, light: Color) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
    }
}

// MARK: - Dark palette ("Digital Curator" design system)
extension Color {
    enum Dark {
        static let surface = Color(hex: 0x0B1326)
        static let surfaceContainerLow = Color(hex: 0x131B2E)
        static let surfaceContainer = Color(hex: 0x171F33)
        static let surfaceContainerHigh = Color(hex: 0x222A3D)
        static let surfaceContainerHighest = Color(hex: 0x2D3548)
        static let primary = Color(hex: 0xBDC2FF)
        static let primaryContainer = Color(hex: 0x818CF8)
        static let onPrimary = Color(hex: 0x0B1326)
        static let onSurface = Color(hex: 0xDAE2FD)
        static let onSurfaceVariant = Color(hex: 0x8B92A8)
        static let outlineVariant = Color(hex: 0x2D3548)
        static let tertiary = Color(hex: 0xFFB783)
    }
}

// MARK: - Light palette (derived from design system + SwiftUI conventions)
extension Color {
    enum Light {
        static let surface = Color(hex: 0xF5F6FA)
        static let surfaceContainerLow = Color(hex: 0xFFFFFF)
        static let surfaceContainer = Color(hex: 0xF0F1F7)
        static let surfaceContainerHigh = Color(hex: 0xE6E7F0)
        static let surfaceContainerHighest = Color(hex: 0xDCDDE8)
        static let primary = Color(hex: 0x4F52D4)
        static let primaryContainer = Color(hex: 0x818CF8)
        static let onPrimary = Color(hex: 0xFFFFFF)
        static let onSurface = Color(hex: 0x1A1C2E)
        static let onSurfaceVariant = Color(hex: 0x5C607A)
        static let outlineVariant = Color(hex: 0xDCDDE8)
        static let tertiary = Color(hex: 0xD97721)
    }
}

// MARK: - Resolved adaptive tokens (use these in views)
extension Color {
    static var surface: Color { adaptive(dark: Dark.surface, light: Light.surface) }
    static var containerLow: Color { adaptive(dark: Dark.surfaceContainerLow, light: Light.surfaceContainerLow) }
    static var container: Color { adaptive(dark: Dark.surfaceContainer, light: Light.surfaceContainer) }
    static var containerHigh: Color { adaptive(dark: Dark.surfaceContainerHigh, light: Light.surfaceContainerHigh) }
    static var containerHighest: Color { adaptive(dark: Dark.surfaceContainerHighest, light: Light.surfaceContainerHighest) }
    static var onSurface: Color { adaptive(dark: Dark.onSurface, light: Light.onSurface) }
    static var onSurfaceVariant: Color { adaptive(dark: Dark.onSurfaceVariant, light: Light.onSurfaceVariant) }
    static var outlineVariant: Color { adaptive(dark: Dark.outlineVariant, light: Light.outlineVariant) }
    static var tertiaryAccent: Color { adaptive(dark: Dark.tertiary, light: Light.tertiary) }
}

// MARK: - Layout constants
enum DesignTokens {
    static let cardRadius: CGFloat = 16
    static let pillRadius: CGFloat = 20
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 24
}

// MARK: - Time formatting
extension TimeInterval {
    /// Format as "M:SS" (e.g. "1:30", "12:05")
    var mmss: String {
        let mins = Int(self) / 60
        let secs = Int(self) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
