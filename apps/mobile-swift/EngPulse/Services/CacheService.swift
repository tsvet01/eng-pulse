import Foundation
import CryptoKit

// MARK: - Cache Service
actor CacheService {
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // Compute directory URLs using nonisolated static helper
    private nonisolated static var baseCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EngPulse", isDirectory: true)
    }

    private var cacheDirectory: URL {
        Self.baseCacheDirectory
    }

    private var summariesFile: URL {
        cacheDirectory.appendingPathComponent("summaries.json")
    }

    private var directoryCreated = false

    init() {
        // Directory creation is deferred to first use
    }

    /// Ensure the cache directory exists
    private func ensureDirectoryExists() {
        guard !directoryCreated else { return }
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        directoryCreated = true
    }

    // MARK: - Summaries Cache

    /// Cache summaries to disk
    func cacheSummaries(_ summaries: [Summary]) async throws {
        ensureDirectoryExists()
        let data = try encoder.encode(summaries)
        try data.write(to: summariesFile)
    }

    /// Get cached summaries from disk
    func getCachedSummaries() async throws -> [Summary] {
        guard fileManager.fileExists(atPath: summariesFile.path) else {
            return []
        }

        let data = try Data(contentsOf: summariesFile)
        return try decoder.decode([Summary].self, from: data)
    }

    /// Check if we have cached summaries
    func hasCachedSummaries() -> Bool {
        fileManager.fileExists(atPath: summariesFile.path)
    }

    // MARK: - Content Cache

    /// Cache markdown content for a summary
    func cacheContent(_ content: String, for summaryId: String) async throws {
        ensureDirectoryExists()
        let safeFilename = sanitizeFilename(summaryId)
        let contentFile = cacheDirectory.appendingPathComponent("content_\(safeFilename).txt")
        try content.write(to: contentFile, atomically: true, encoding: .utf8)
    }

    /// Get cached content for a summary
    func getCachedContent(for summaryId: String) async -> String? {
        let safeFilename = sanitizeFilename(summaryId)
        let contentFile = cacheDirectory.appendingPathComponent("content_\(safeFilename).txt")
        return try? String(contentsOf: contentFile, encoding: .utf8)
    }

    /// Sanitize a string for use as a filename
    private func sanitizeFilename(_ input: String) -> String {
        // Use hashValue for a simple, safe filename
        // Replace unsafe characters and truncate to reasonable length
        let safe = input
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "&", with: "_")
            .replacingOccurrences(of: "=", with: "_")
            .replacingOccurrences(of: "%", with: "_")
        // Use last 50 chars to keep uniqueness while limiting length
        let suffix = String(safe.suffix(50))
        return suffix.isEmpty ? "default" : suffix
    }

    // MARK: - Audio Cache (TTS)

    /// Cache audio data for TTS
    func cacheAudio(_ audioData: Data, for cacheKey: String) async throws {
        ensureDirectoryExists()
        let audioFile = cacheDirectory.appendingPathComponent("audio_\(cacheKey).mp3")
        try audioData.write(to: audioFile)
    }

    /// Get cached audio URL if it exists
    func getCachedAudioURL(for cacheKey: String) async -> URL? {
        let audioFile = cacheDirectory.appendingPathComponent("audio_\(cacheKey).mp3")
        return fileManager.fileExists(atPath: audioFile.path) ? audioFile : nil
    }

    /// Check if audio is cached
    func hasAudio(for cacheKey: String) -> Bool {
        let audioFile = cacheDirectory.appendingPathComponent("audio_\(cacheKey).mp3")
        return fileManager.fileExists(atPath: audioFile.path)
    }

    /// Generate cache key from text and TTS configuration string
    func generateAudioCacheKey(text: String, configKey: String) -> String {
        // Use stable SHA256 hash instead of hashValue which changes per app launch
        let combined = "\(text)_\(configKey)"
        let data = Data(combined.utf8)
        let hash = SHA256.hash(data: data)
        // Take first 8 bytes for compact key
        let hashPrefix = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(hashPrefix)_\(configKey)"
    }

    /// Clean up old audio cache files (keep most recent)
    func cleanupOldAudio(keepCount: Int = 20) async {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let audioFiles = contents.filter { $0.lastPathComponent.hasPrefix("audio_") }

        guard audioFiles.count > keepCount else { return }

        // Sort by creation date (newest first)
        let sortedFiles = audioFiles.sorted { file1, file2 in
            let date1 = (try? file1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
            let date2 = (try? file2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
            return date1 > date2
        }

        // Delete files beyond keepCount
        for file in sortedFiles.dropFirst(keepCount) {
            try? fileManager.removeItem(at: file)
        }
    }

    // MARK: - Cache Management

    /// Clear all cached data
    func clearAll() async {
        try? fileManager.removeItem(at: cacheDirectory)
        directoryCreated = false
        ensureDirectoryExists()
    }

    /// Get cache size in bytes
    func getCacheSize() async -> Int64 {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var totalSize: Int64 = 0
        for fileURL in contents {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(fileSize)
            }
        }

        return totalSize
    }

    /// Format cache size for display
    func formattedCacheSize() async -> String {
        let size = await getCacheSize()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}
