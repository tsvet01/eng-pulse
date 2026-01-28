import Foundation

struct TextCleaner {
    private static let cleaningRules: [(pattern: String, replacement: String)] = [
        // Remove code blocks (must come before inline code)
        ("```[\\s\\S]*?```", ""),
        // Remove markdown headings
        ("(?m)^#{1,6}\\s*", ""),
        // Remove bold/italic markers
        ("\\*{1,2}([^*]+)\\*{1,2}", "$1"),
        ("_{1,2}([^_]+)_{1,2}", "$1"),
        // Remove inline code
        ("`([^`]+)`", "$1"),
        // Remove images (before links)
        ("!\\[[^\\]]*\\]\\([^)]+\\)", ""),
        // Remove links but keep text
        ("\\[([^\\]]+)\\]\\([^)]+\\)", "$1"),
        // Remove HTML tags
        ("<[^>]+>", ""),
        // Remove horizontal rules
        ("(?m)^[-*_]{3,}\\s*$", ""),
        // Remove list markers
        ("(?m)^\\s*[-*+]\\s+", ""),
        ("(?m)^\\s*\\d+\\.\\s+", ""),
        // Remove blockquote markers
        ("(?m)^\\s*>\\s*", ""),
        // Normalize whitespace
        ("\n{3,}", "\n\n"),
        (" {2,}", " "),
    ]

    static func cleanForSpeech(_ text: String) -> String {
        var cleaned = text
        for rule in cleaningRules {
            cleaned = cleaned.replacingOccurrences(
                of: rule.pattern,
                with: rule.replacement,
                options: .regularExpression
            )
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
