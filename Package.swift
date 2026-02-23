// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mac-virtual-mic-bridge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
        .executable(name: "micbridge-daemon", targets: ["MicBridgeDaemon"]),
        .executable(name: "micbridge-menubar", targets: ["MicBridgeMenuBar"]),
        .executable(name: "micbridge-fixture-validate", targets: ["MicBridgeFixtureValidate"]),
        .executable(name: "micbridge-capture-fixture", targets: ["MicBridgeCaptureFixture"]),
        .executable(name: "micbridge-audio-e2e-validate", targets: ["MicBridgeAudioE2EValidate"])
    ],
    targets: [
        .target(
            name: "BridgeCore",
            path: "packages/bridge-core/Sources/BridgeCore"
        ),
        .executableTarget(
            name: "MicBridgeDaemon",
            dependencies: ["BridgeCore"],
            path: "services/bridge-daemon/Sources/MicBridgeDaemon"
        ),
        .executableTarget(
            name: "MicBridgeMenuBar",
            dependencies: ["BridgeCore"],
            path: "apps/menubar/Sources/MicBridgeMenuBar"
        ),
        .executableTarget(
            name: "MicBridgeFixtureValidate",
            dependencies: ["BridgeCore"],
            path: "packages/bridge-core/Validation/FixtureValidator"
        ),
        .executableTarget(
            name: "MicBridgeCaptureFixture",
            dependencies: ["BridgeCore"],
            path: "packages/bridge-core/Tools/CaptureFixture"
        ),
        .executableTarget(
            name: "MicBridgeAudioE2EValidate",
            dependencies: ["BridgeCore"],
            path: "packages/bridge-core/Tools/AudioE2EValidate"
        )
    ]
)
