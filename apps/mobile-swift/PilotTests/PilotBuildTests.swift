import XCTest
@testable import PilotCore

final class PilotBuildTests: XCTestCase {
    func testOnlyExplicitLegacyIdentityCanUseLegacyServices() {
        XCTAssertTrue(PilotBuild.allowsLegacyServices(bundleID: "org.tsvetkov.EngPulseSwift", pilotEnabled: false))
        XCTAssertFalse(PilotBuild.allowsLegacyServices(bundleID: "org.tsvetkov.EngPulseSwift", pilotEnabled: true))
        XCTAssertFalse(PilotBuild.allowsLegacyServices(bundleID: "org.tsvetkov.eng-pulse", pilotEnabled: false))
        XCTAssertFalse(PilotBuild.allowsLegacyServices(bundleID: "org.tsvetkov.eng-pulse", pilotEnabled: true))
        XCTAssertFalse(PilotBuild.allowsLegacyServices(bundleID: nil, pilotEnabled: false))
        XCTAssertFalse(PilotBuild.allowsLegacyServices(bundleID: "another.app", pilotEnabled: false))
    }
}
