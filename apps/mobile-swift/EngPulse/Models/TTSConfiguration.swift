import Foundation

// MARK: - TTS Configuration
struct TTSConfiguration: Hashable, Codable {
    let voiceName: String
    let languageCode: String
    let speakingRate: Double  // 0.5-2.0
    let pitch: Double         // -20.0 to 20.0

    // Default configuration
    static let `default` = TTSConfiguration(
        voiceName: Neural2Voice.maleJ.rawValue,
        languageCode: "en-US",
        speakingRate: 1.1,
        pitch: 0.0
    )

    /// Convert from old AVSpeech settings to Cloud TTS parameters
    /// - Parameters:
    ///   - rate: AVSpeech rate (0.25-0.75)
    ///   - pitch: AVSpeech pitch (0.5-1.5)
    ///   - voice: Selected Neural2 voice
    static func fromAppStorage(rate: Double, pitch: Double, voice: String) -> TTSConfiguration {
        // Map 0.25-0.75 range to 0.75-1.5 range for Cloud TTS
        let cloudRate = 0.75 + (rate - 0.25) * 1.5
        // Map 0.5-1.5 to -5 to +5 semitones
        let cloudPitch = (pitch - 1.0) * 10.0

        return TTSConfiguration(
            voiceName: voice,
            languageCode: "en-US",
            speakingRate: min(max(cloudRate, 0.5), 2.0),
            pitch: min(max(cloudPitch, -20.0), 20.0)
        )
    }

    /// Generate cache key component from configuration
    var cacheKey: String {
        "\(voiceName)_\(Int(speakingRate * 100))_\(Int((pitch + 20) * 10))"
    }
}

// MARK: - Neural2 Voice Options
enum Neural2Voice: String, CaseIterable, Identifiable {
    case maleJ = "en-US-Neural2-J"
    case femaleF = "en-US-Neural2-F"
    case maleD = "en-US-Neural2-D"
    case femaleC = "en-US-Neural2-C"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .maleJ: return "Male (J)"
        case .femaleF: return "Female (F)"
        case .maleD: return "Male (D)"
        case .femaleC: return "Female (C)"
        }
    }
}
