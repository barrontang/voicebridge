// swift-tools-version:5.9
import PackageDescription

// VoiceBridge — local STT (whisper-cpp) + local TTS (Piper default).
//
// Targets:
//    * VoiceBridgeCore : framework-agnostic logic + SwiftUI config manager.
//    * voicebridge-cli : headless demo that exercises the core.
//    * voicebridge-gui : the SwiftUI shell in ./App, wrapped into a .app bundle
//                       by scripts/make-app.sh so it can actually launch.

let package = Package(
    name: "VoiceBridge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "VoiceBridgeCore", targets: ["VoiceBridgeCore"]),
        .executable(name: "voicebridge-cli", targets: ["voicebridge-cli"]),
        .executable(name: "voicebridge-gui", targets: ["voicebridge-gui"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "VoiceBridgeCore",
            path: "Sources/VoiceBridgeCore",
            // Strict concurrency: the core is a library, so its data-race
            // safety is part of its contract (and it is what a future Swift 6
            // language mode will require).
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "voicebridge-cli",
            dependencies: ["VoiceBridgeCore"],
            path: "Sources/voicebridge-cli",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "voicebridge-gui",
            dependencies: ["VoiceBridgeCore"],
            path: "App",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "VoiceBridgeCoreTests",
            dependencies: ["VoiceBridgeCore"],
            path: "Tests/VoiceBridgeCoreTests"
        )
    ]
)
