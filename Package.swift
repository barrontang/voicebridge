// swift-tools-version:5.9
import PackageDescription

// VoiceBridge — local STT (whisper-cpp) + local TTS (Piper default).
//
// Targets:
//   * VoiceBridgeCore  : framework-agnostic logic. No SwiftUI, fully testable.
//   * voicebridge-cli  : runnable demo that exercises the core (no GUI, headless).
//
// The SwiftUI shell lives in ./App and is intentionally NOT part of this package:
// an in-process GUI app needs an Xcode .xcodeproj with an app bundle. Copy the
// three files in ./App into a new macOS App target, add the `VoiceBridgeCore`
// product as an SPM dependency, and the same logic runs inside the GUI.

let package = Package(
    name: "VoiceBridge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "VoiceBridgeCore", targets: ["VoiceBridgeCore"]),
        .executable(name: "voicebridge-cli", targets: ["voicebridge-cli"])
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
        .testTarget(
            name: "VoiceBridgeCoreTests",
            dependencies: ["VoiceBridgeCore"],
            path: "Tests/VoiceBridgeCoreTests"
        )
    ]
)
