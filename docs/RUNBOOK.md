# Runbook

Step-by-step: install the backends, run the CLI, and wire the GUI target.

## 0. Prerequisites

- macOS 14+, Xcode 15+ command-line tools (`swift`, `swift test`).
- `brew` for the optional engines.

## 1. STT — whisper.cpp

```bash
brew install whisper-cpp            # Metal-accelerated on Apple Silicon
scripts/fetch-whisper-turbo.sh      # downloads ggml-large-v3-turbo (~1.6 GB)
# optional env overrides:
export WHISPER_CLI=/opt/homebrew/opt/whisper-cpp/bin/whisper-cli
```

Model files land in `~/.voicebridge/models/tts/whisper/ggml-<model>.bin`
(override the root with `VOICEBRIDGE_MODELS_MAP`).

> **Flag note:** newer `whisper-cli` writes transcripts via `-oj`/`-otxt`; older
> builds print to stdout. `WhisperCliBackend` currently reads stdout — tune the
> flags to your binary version.

## 2. TTS — engines

| Engine | Install | Offline | Notes |
|---|---|---|---|
| Built-in (AVSpeech) | — | ✅ | zero-setup fallback, always available |
| Piper (DEFAULT) | `scripts/install-piper.sh` | ✅ | local ONNX, voices under `piper/voice/` |
| Kokoro-82M | install a `kokoro` CLI | ✅ | local, heavy |
| Edge TTS | `pip install edge-tts` | ❌ | online MS voices, best fidelity |

Env overrides: `VOICEBRIDGE_PIPER`, `VOICEBRIDGE_KOKORO`, `VOICEBRIDGE_EDGE_TTS`.

## 3. Build & smoke test

```bash
swift build -c release
.build/release/voicebridge-cli ping                 # engine + model availability
.build/release/voicebridge-cli stt  out.wav en large-v3-turbo
.build/release/voicebridge-cli tts --text "你好, world" --voice zh_CN-xiaoyi-medium
.build/release/voicebridge-cli tts --text "hello" --engine system --no-play
```

## 4. Tests

```bash
swift test        # smoke tests for the pure-logic parts of the core
```

Audio/shell paths are covered by `voicebridge-cli ping`/`stt`/`tts`, not unit
tests (they need a mic and an installed binary).

## 5. transcode — resample extension point (AVAudioConverter)

`AudioTranscoder.transcodeToWAV` handles the 16 kHz/mono fast path and throws for
other shapes. To resample arbitrary sources stream-style (chunked, no whole-file
load):

```swift
let inFmt  = try AVAudioFile(forReading: from).processingFormat
let outFmt = AudioFormats.targetFormat

// Convert 1:1 sampleRate and channelCount in one pass.
let converter = try AVAudioConverter(from: inFmt, to: outFmt)
converter.requestData { _, inStatus, outStatus in
     // pull from the input file, push to the output file; loop until done.
     _ = inStatus; _ = outStatus
}
```

Key points:
- Convert **sample rate** and **channel count** both — `AVAudioConverter` handles
  resampling and stereo→mono in a single object.
- Pull/push in **frames**, not the whole buffer, to keep memory flat for long
  recordings.
- Request `outFmt` as the output format; write with a fresh
  `AVAudioFile(forWriting:out, settings: AudioFormats.target)`.

## 6. Mic capture

```swift
let cap = try MicrophoneCapture(outputURL: out)   // writes 16 kHz/mono/16-bit PCM
await MicrophoneCapture.requestInputPermission { granted in /* ... */ }
try cap.start(); /* ... */ cap.stop()
```
`AVAudioRecorder` writes the exact whisper shape, so no post-processing tap is
needed for batch capture. For word-partial streaming, `installTap` on the input
node instead (documented extension point in `MicrophoneCapture.swift`).

## 7. GUI target

`App/` holds three **reference** SwiftUI files (not part of the package). To ship
the GUI:

1. New macOS App target (Minimum = macOS 14).
2. Copy `App/VoiceBridgeApp.swift`, `App/ContentView.swift`, `App/SettingsView.swift`.
3. Add `VoiceBridgeCore` as an SPM dependency.
