# Architecture

VoiceBridge is a local (on-device) **speech-to-text + text-to-speech** library for
macOS / Apple Silicon, structured so the logic is fully testable and the GUI is a
thin shell on top.

## Why a core / shell split

The original PRD tangled observable UI state with the audio pipeline, which made
the code impossible to unit-test and caused `@Published` state to be lost on every
`SettingsView` re-render. We fixed it by isolating everything framework-agnostic into
`VoiceBridgeCore` and keeping SwiftUI in a separate `App/` shell that only *imports*
the core.

```
VoiceBridgeCore   (SPM library, no SwiftUI, @testable)
   ├── Audio/        AudioFormats, AudioTranscoder, MicrophoneCapture
   ├── Stt/          Shell, WhisperBackend, WhisperCliBackend
   ├── Tts/          TTSBackend + Piper/Kokoro/EdgeTTS/System backends,
   │                 TTSManager (orchestration), TTSConfigManager (state)
   ├── Models.swift  SttModel, Transcription, VoiceError
   └── helpers       ModelPaths, Extensions

voicebridge-cli   (SPM executable, headless smoke test of the pipeline)

App/              (reference SwiftUI shell — NOT in the package)
   └── VoiceBridgeApp / ContentView / SettingsView
```

## Pluggable engine contracts

- **`WhisperBackend`** — `transcribe(audio:language:model:useTimestamps:)`.
  Shipped impl: `WhisperCliBackend` (out-of-process `whisper-cli`). A future
  in-process `InProcessWhisper` implementation drops in behind the same protocol.

- **`TTSBackend`** — `synthesize(text:voice:outputPath:)`, `producesAudioFile`,
  `isAvailable()`, `displayName`. Shipped impls:
  - `PiperBackend`  — local ONNX, offline, DEFAULT.
  - `KokoroBackend` — local high-quality runtime.
  - `EdgeTTSBackend`— online Microsoft Edge voices (not offline).
  - `SystemVoiceBackend` — `AVSpeechSynthesizer`, in-place, always available,
    zero-setup fallback.

`TTSManager.speak(...)` picks the engine, applies **graceful fallback**
(chosen engine unavailable → built-in voice), and (optionally) plays the result.

## Two correctness fixes carried over from the PRD

1. **State ownership.** The manager is owned once as `@StateObject` in
   `VoiceBridgeApp` and injected down as `@ObservedObject` / `@EnvironmentObject`,
   so published selection survives re-renders. See `App/VoiceBridgeApp.swift`.
2. **Process pipes.** `Shell.run` and `Pipeline.runWithStdin` drain *both* stdout
   and stderr on background queues before waiting for termination, so a large
   transcript can't fill a pipe buffer and deadlock the caller; non-zero exit is
   surfaced as a thrown `VoiceError` instead of silent success.

## Packaging caveat (STT)

`WhisperCliBackend` is an **out-of-process** call to `whisper-cli`. That runs today
but does **not survive the App Sandbox**. The shipping path is to link whisper.cpp
**in-process** (a C/C++ target); this scaffold uses the process path so the pipeline
is observable and runnable before the C/C++ link step.

## Audio shape

whisper.cpp wants **16 kHz / mono / 16-bit little-endian PCM**. `AudioFormats.target`
is that exact shape and is used both as the mic-capture settings and the transcode
target, so the live-mic path needs no post-processing tap.

## Transcode (extension point)

`AudioTranscoder.transcodeToWAV` is a *fast path*: it copies files that are already
16 kHz / mono PCM, and **throws** for other shapes (e.g. 48 kHz stereo) with a
"resample required" signal, rather than shipping a half-verified converter. Wire
`AVAudioConverter` here using the pattern in `docs/RUNBOOK.md §transcode`.
