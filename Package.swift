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
            path: "Sources/VoiceBridgeCore"
        ),
        .executableTarget(
            name: "voicebridge-cli",
            dependencies: ["VoiceBridgeCore"],
            path: "Sources/voicebridge-cli"
        ),
        .executableTarget(
            name: "voicebridge-gui",
            dependencies: ["VoiceBridgeCore"],
            path: "App"
        ),
        .testTarget(
            name: "VoiceBridgeCoreTests",
            dependencies: ["VoiceBridgeCore"],
            path: "Tests/VoiceBridgeCoreTests"
        )
    ]
)
