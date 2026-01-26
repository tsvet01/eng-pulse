import Foundation

// MARK: - Cloud TTS Service
actor CloudTTSService {
    // MARK: - Constants
    private enum Constants {
        /// Standard RIFF WAV header size in bytes (44 bytes for PCM format)
        static let wavHeaderSize = 44

        /// Google Cloud TTS API chunk size limit with safety margin
        /// API limit is 5000 bytes, we use 4500 to account for multi-byte UTF-8 characters
        static let maxChunkBytes = 4500

        /// Network request timeout for TTS synthesis
        static let requestTimeout: TimeInterval = 30

        /// Resource download timeout for audio files
        static let resourceTimeout: TimeInterval = 120
    }

    private let session: URLSession
    private let apiKey: String

    init(apiKey: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = Constants.requestTimeout
            config.timeoutIntervalForResource = Constants.resourceTimeout
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
    private func chunkText(_ text: String, maxBytes: Int = Constants.maxChunkBytes) -> [String] {
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
                        // Truncate extremely long words that exceed limit on their own
                        let safeWord = word.utf8.count > maxBytes
                            ? String(word.prefix(maxBytes / 4))  // Conservative truncation for multi-byte chars
                            : word
                        let testWord = currentChunk.isEmpty ? safeWord : "\(currentChunk) \(safeWord)"
                        if testWord.utf8.count > maxBytes {
                            if !currentChunk.isEmpty {
                                chunks.append(currentChunk)
                            }
                            currentChunk = safeWord
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
            return try await synthesizeChunk(chunks[0], config: config, encoding: "MP3")
        } else {
            // For multi-chunk, use LINEAR16 (WAV) which can be properly concatenated
            // MP3 files cannot be simply appended - they have headers that cause corruption
            var pcmData = Data()
            var wavHeader: Data?

            for (index, chunk) in chunks.enumerated() {
                let chunkData = try await synthesizeChunk(chunk, config: config, encoding: "LINEAR16")

                if index == 0 {
                    // Keep the full WAV file for the first chunk (includes header)
                    wavHeader = chunkData.prefix(Constants.wavHeaderSize)
                    pcmData.append(chunkData.suffix(from: Constants.wavHeaderSize))
                } else {
                    // Strip WAV header from subsequent chunks, keep only PCM data
                    pcmData.append(chunkData.suffix(from: Constants.wavHeaderSize))
                }
            }

            // Rebuild WAV header with correct file size
            guard var header = wavHeader else {
                throw CloudTTSError.decodingError
            }

            // Update file size at bytes 4-7 (little endian): total size - 8 (RIFF header)
            let fileSize = UInt32(pcmData.count + Constants.wavHeaderSize - 8)
            header.replaceSubrange(4..<8, with: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })

            // Update data chunk size at bytes 40-43 (little endian)
            let dataSize = UInt32(pcmData.count)
            header.replaceSubrange(40..<Constants.wavHeaderSize, with: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

            return header + pcmData
        }
    }

    private func synthesizeChunk(_ text: String, config: TTSConfiguration, encoding: String = "MP3") async throws -> Data {
        guard let url = URL(string: "https://texttospeech.googleapis.com/v1/text:synthesize") else {
            throw CloudTTSError.invalidURL
        }

        let request = SynthesizeRequest(
            input: SynthesizeRequest.Input(text: text),
            voice: SynthesizeRequest.Voice(
                languageCode: config.languageCode,
                name: config.voiceName
            ),
            audioConfig: SynthesizeRequest.AudioConfig(
                audioEncoding: encoding,
                speakingRate: config.speakingRate,
                pitch: config.pitch
            )
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
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
            return "Unable to connect to audio service. Please try again."
        case .invalidResponse:
            return "Audio service returned an unexpected response. Please try again."
        case .httpError(let statusCode):
            switch statusCode {
            case 400:
                return "Unable to generate audio. Please try a shorter text."
            case 401, 403:
                return "Audio service is not available. Please check app settings."
            case 429:
                return "Audio service is busy. Please try again in a few moments."
            case 500...599:
                return "Audio service is temporarily unavailable. Please try again later."
            default:
                return "Unable to generate audio. Please try again."
            }
        case .apiError:
            return "Audio generation failed. Please try again."
        case .decodingError:
            return "Unable to process audio. Please try again."
        case .noAPIKey:
            return "Audio playback is not available. Please check app settings."
        }
    }
}
