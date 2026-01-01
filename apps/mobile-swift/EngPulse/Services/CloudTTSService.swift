import Foundation

// MARK: - Cloud TTS Service
actor CloudTTSService {
    private let session: URLSession
    private let apiKey: String

    init(apiKey: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - API Request/Response Models

    private struct SynthesizeRequest: Codable {
        let input: Input
        let voice: Voice
        let audioConfig: AudioConfig

        struct Input: Codable {
            let text: String
        }

        struct Voice: Codable {
            let languageCode: String
            let name: String
        }

        struct AudioConfig: Codable {
            let audioEncoding: String
            let speakingRate: Double
            let pitch: Double
        }
    }

    private struct SynthesizeResponse: Codable {
        let audioContent: String  // Base64 encoded
    }

    // MARK: - Text Chunking

    /// Split text into chunks under 5000 bytes for API limit
    private func chunkText(_ text: String, maxBytes: Int = 4500) -> [String] {
        // If text fits in one chunk, return it
        if text.utf8.count <= maxBytes {
            return [text]
        }

        var chunks: [String] = []
        var currentChunk = ""

        // Split by sentences for natural breaks
        let sentenceEnders = CharacterSet(charactersIn: ".!?\n")
        let sentences = text.components(separatedBy: sentenceEnders)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for sentence in sentences {
            let testChunk = currentChunk.isEmpty ? sentence : "\(currentChunk). \(sentence)"

            if testChunk.utf8.count > maxBytes {
                if !currentChunk.isEmpty {
                    chunks.append(currentChunk + ".")
                    currentChunk = sentence
                } else {
                    // Single sentence is too long - split by words
                    let words = sentence.components(separatedBy: " ")
                    for word in words {
                        let testWord = currentChunk.isEmpty ? word : "\(currentChunk) \(word)"
                        if testWord.utf8.count > maxBytes {
                            if !currentChunk.isEmpty {
                                chunks.append(currentChunk)
                            }
                            currentChunk = word
                        } else {
                            currentChunk = testWord
                        }
                    }
                }
            } else {
                currentChunk = testChunk
            }
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks.isEmpty ? [text] : chunks
    }

    // MARK: - Synthesize Speech

    /// Synthesize speech from text using Google Cloud TTS
    func synthesize(text: String, config: TTSConfiguration) async throws -> Data {
        let chunks = chunkText(text)

        if chunks.count == 1 {
            return try await synthesizeChunk(chunks[0], config: config)
        } else {
            // Synthesize chunks and concatenate MP3 data
            var audioData = Data()
            for chunk in chunks {
                let chunkData = try await synthesizeChunk(chunk, config: config)
                audioData.append(chunkData)
            }
            return audioData
        }
    }

    private func synthesizeChunk(_ text: String, config: TTSConfiguration) async throws -> Data {
        guard let url = URL(string: "https://texttospeech.googleapis.com/v1/text:synthesize?key=\(apiKey)") else {
            throw CloudTTSError.invalidURL
        }

        let request = SynthesizeRequest(
            input: SynthesizeRequest.Input(text: text),
            voice: SynthesizeRequest.Voice(
                languageCode: config.languageCode,
                name: config.voiceName
            ),
            audioConfig: SynthesizeRequest.AudioConfig(
                audioEncoding: "MP3",
                speakingRate: config.speakingRate,
                pitch: config.pitch
            )
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTTSError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            // Try to parse error message
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw CloudTTSError.apiError(message: message)
            }
            throw CloudTTSError.httpError(statusCode: httpResponse.statusCode)
        }

        let synthesizeResponse = try JSONDecoder().decode(SynthesizeResponse.self, from: data)

        guard let audioData = Data(base64Encoded: synthesizeResponse.audioContent) else {
            throw CloudTTSError.decodingError
        }

        return audioData
    }
}

// MARK: - Cloud TTS Errors
enum CloudTTSError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case apiError(message: String)
    case decodingError
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from TTS service"
        case .httpError(let statusCode):
            switch statusCode {
            case 400:
                return "Invalid request to TTS service"
            case 401, 403:
                return "TTS API key is invalid or missing"
            case 429:
                return "TTS quota exceeded - try again later"
            case 500...599:
                return "TTS service temporarily unavailable"
            default:
                return "TTS service error (\(statusCode))"
            }
        case .apiError(let message):
            return message
        case .decodingError:
            return "Failed to decode audio"
        case .noAPIKey:
            return "Google Cloud TTS API key not configured"
        }
    }
}
