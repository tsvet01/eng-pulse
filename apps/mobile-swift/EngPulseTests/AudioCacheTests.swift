import AVFoundation
import XCTest
@testable import EngPulse

final class AudioCacheTests: XCTestCase {
    func testCachedWAVCanBeOpenedByAppleDecoder() async throws {
        let cache = CacheService(directory: try temporaryDirectory())
        try await cache.cacheAudio(silentWAV(), for: "long-brief")

        let result = await cache.getCachedAudioURL(for: "long-brief")
        let url = try XCTUnwrap(result)
        let player = try AVAudioPlayer(contentsOf: url)
        XCTAssertEqual(player.duration, 0.1, accuracy: 0.001)
    }

    func testLegacyWAVWithMP3ExtensionIsRepairedWithoutRegeneratingAudio() async throws {
        let directory = try temporaryDirectory()
        let original = directory.appendingPathComponent("audio_saved-brief.mp3")
        let bytes = silentWAV()
        try bytes.write(to: original)
        let cache = CacheService(directory: directory)

        let result = await cache.getCachedAudioURL(for: "saved-brief")
        let url = try XCTUnwrap(result)
        let player = try AVAudioPlayer(contentsOf: url)
        XCTAssertEqual(player.duration, 0.1, accuracy: 0.001)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let secondRead = await cache.getCachedAudioURL(for: "saved-brief")
        XCTAssertEqual(secondRead, url)
    }

    func testMP3CacheKeepsItsExtensionAndBytes() async throws {
        let cache = CacheService(directory: try temporaryDirectory())
        let bytes = Data([0xFF, 0xFB, 0x90, 0x00])
        try await cache.cacheAudio(bytes, for: "short-brief")

        let result = await cache.getCachedAudioURL(for: "short-brief")
        let url = try XCTUnwrap(result)
        XCTAssertEqual(url.pathExtension, "mp3")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testReplacingAudioWithADifferentFormatReturnsTheNewBytes() async throws {
        let directory = try temporaryDirectory()
        let cache = CacheService(directory: directory)
        let mp3 = Data([0xFF, 0xFB, 0x90, 0x00])
        for bytes in [mp3, silentWAV(), mp3] {
            try await cache.cacheAudio(bytes, for: "brief")
            let result = await cache.getCachedAudioURL(for: "brief")
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result)), bytes)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertEqual(files.count, 1, "Only the current audio should remain")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// 0.1 seconds of mono 24 kHz PCM16, matching multi-chunk Cloud TTS output.
    private func silentWAV() -> Data {
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(4836))
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(24000))
        append(UInt32(48000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(Data("data".utf8))
        append(UInt32(4800))
        data.append(Data(repeating: 0, count: 4800))
        return data
    }
}
