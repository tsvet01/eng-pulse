import Foundation

// MARK: - Cache Service
actor CacheService {
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var cacheDirectory: URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EngPulse", isDirectory: true)
    }

    private var summariesFile: URL {
        cacheDirectory.appendingPathComponent("summaries.json")
    }

    init() {
        // Ensure cache directory exists
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Summaries Cache

    /// Cache summaries to disk
    func cacheSummaries(_ summaries: [Summary]) async throws {
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
        let contentFile = cacheDirectory.appendingPathComponent("content_\(summaryId).txt")
        try content.write(to: contentFile, atomically: true, encoding: .utf8)
    }

    /// Get cached content for a summary
    func getCachedContent(for summaryId: String) async -> String? {
        let contentFile = cacheDirectory.appendingPathComponent("content_\(summaryId).txt")
        return try? String(contentsOf: contentFile, encoding: .utf8)
    }

    // MARK: - Cache Management

    /// Clear all cached data
    func clearAll() async {
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Get cache size in bytes
    func getCacheSize() async -> Int64 {
        guard let enumerator = fileManager.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                continue
            }
            totalSize += Int64(fileSize)
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
