import XCTest
import AVFoundation
import Combine
@testable import EngPulse

@MainActor
final class AudioPlayerRecoveryTests: XCTestCase {
    private var player: AudioPlayerService!
    private var file: URL!

    override func setUp() async throws {
        player = AudioPlayerService()
        file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Self.tone().write(to: file)
    }

    override func tearDown() async throws {
        player.stop()
        try? FileManager.default.removeItem(at: file)
    }

    func testResumeWithoutLoadedAudioDoesNotClaimToBePlaying() {
        XCTAssertThrowsError(try player.resume())
        XCTAssertFalse(player.isPlaying)
    }

    func testLateFinishFromOldPlayerCannotStopCurrentAudio() async throws {
        try player.play(from: file)
        let unrelatedOldPlayer = try AVAudioPlayer(contentsOf: file)
        let stopped = expectation(description: "Old completion cannot stop new output")
        stopped.isInverted = true
        let observation = player.$isPlaying.dropFirst().filter { !$0 }.sink { _ in stopped.fulfill() }
        defer { observation.cancel() }
        player.audioPlayerDidFinishPlaying(unrelatedOldPlayer, successfully: true)
        await fulfillment(of: [stopped], timeout: 0.2)
        XCTAssertTrue(player.isPlaying)
        XCTAssertLessThan(player.progress, 1)
    }

    func testLateDecodeErrorFromOldPlayerCannotStopCurrentAudio() async throws {
        try player.play(from: file)
        let unrelatedOldPlayer = try AVAudioPlayer(contentsOf: file)
        let stopped = expectation(description: "Old decode error cannot stop new output")
        stopped.isInverted = true
        let observation = player.$isPlaying.dropFirst().filter { !$0 }.sink { _ in stopped.fulfill() }
        defer { observation.cancel() }
        player.audioPlayerDecodeErrorDidOccur(unrelatedOldPlayer, error: URLError(.cannotDecodeContentData))
        await fulfillment(of: [stopped], timeout: 0.2)
        XCTAssertTrue(player.isPlaying)
    }

    func testRealAudioAdvancesAndCanResumeAfterPause() async throws {
        try player.play(from: file)
        let advancing = expectation(description: "Native audio actually advances")
        let observation = player.$progress.filter { $0 > 0 }.prefix(1).sink { _ in advancing.fulfill() }
        defer { observation.cancel() }
        await fulfillment(of: [advancing], timeout: 2)
        player.pause()
        XCTAssertFalse(player.isPlaying)
        try player.resume()
        XCTAssertTrue(player.isPlaying)
    }

    static func tone() -> Data {
        // Three seconds of mono PCM, 8 kHz/16 bit; generated locally without a provider.
        let samples: [Int16] = (0..<24_000).map { Int16(sin(Double($0) * 2 * .pi * 440 / 8_000) * 500) }
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + 48_000); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(8_000); u32(16_000); u16(2); u16(16)
        text("data"); u32(48_000)
        for sample in samples { u16(UInt16(bitPattern: sample)) }
        return data
    }
}
