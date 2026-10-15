// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "EngPulsePilot",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "PilotCore", targets: ["PilotCore"])],
    targets: [
        .target(name: "PilotCore", path: "EngPulse/Pilot"),
        .testTarget(name: "PilotCoreTests", dependencies: ["PilotCore"], path: "PilotTests")
    ]
)
