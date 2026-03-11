import XCTest
@testable import EngPulse

@MainActor
final class LocalTTSServiceTests: XCTestCase {

    func testInitialStateIsNotPlaying() {
        let service = LocalTTSService()
        XCTAssertFalse(service.isPlaying)
    }

    func testInitialProgressIsZero() {
        let service = LocalTTSService()
        XCTAssertEqual(service.progress, 0.0)
    }

    func testStopResetsState() {
        let service = LocalTTSService()
        service.stop()
        XCTAssertFalse(service.isPlaying)
        XCTAssertEqual(service.progress, 0.0)
    }
}
