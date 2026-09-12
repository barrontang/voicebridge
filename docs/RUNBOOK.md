# Runbook

Step-by-step: install the backends, run the CLI, and wire the GUI target.

## 0. Prerequisites

- macOS 14+, Xcode 15+ command-line tools (`swift`, `swift test`).
- `brew` for the optional engines.

## 1. STT — whisper.cpp

```bash
brew install whisper-cpp             # Metal-accelerated on Apple Silicon
scripts/fetch-whisper-turbo.sh       # downloads ggml-large-v3-turbo (~1.6 GB)
# optional env override:
export WHISPER_CLI=/opt/homebrew/opt/whisper-cpp/bin/whisper-cli
```

Model files land in `~/.voicebridge/models/tts/whisper/ggml-<model>.bin`
(override the root with `VOICEBRIDGE_MODELS_MAP`).

> **Cross-version output.** `WhisperCliBackend` is version-agnostic. It runs
> `whisper-cli` with `-otxt -oj` in an isolated temp CWD and reads the derived
> `<input>.txt` / `<input>.json` files, parsing three known JSON shapes
> (segment arrays, a flat object, and mixed `result`+`transcription`) for
> detected language and duration. Builds without those flags fall back to stdout;
> a non-zero exit caused *only* by an unrecognised flag is retried without it, so
> genuine transcription errors still surface. Audio duration is measured from the
> source file, because a model's `offsets.to` can report its ~30 s context window
> rather than the true clip length.

## 2. TTS — engines

| Engine | Install | Offline | Notes |
|---|---|---|---|
| Built-in (AVSpeech) | — | ✅ | zero-setup fallback, always available |
| Piper (DEFAULT) | `scripts/install-piper.sh` | ✅ | local ONNX, voices under `piper/voice/` |
| Kokoro-82M | install a `kokoro` CLI | ✅ | local, heavy |
| Edge TTS | `pip install edge-tts` | ❌ | online MS voices, best fidelity |

Env overrides: `VOICEBRIDGE_PIPER`, `VOICEBRIDGE_KOKORO`, `VOICEBRIDGE_EDGE_TTS`.

> **Caveat (the built-in engine in a headless CLI).** `SystemVoiceBackend`
> *speaks in place* via `AVSpeechSynthesizer`, which delivers on the main run
> loop. In a long-lived GUI app that loop is already running, so it just plays.
> In a short-lived process it can appear to "hang" because the process exits
> before the utterance drains — that is the engine, not a bug in the pipeline.
> For headless smoke tests, prefer a file-producing engine (`piper`, `edgeTTS`,
> `kokoro`) with `--no-play`, or add a run-loop spin around the call.

## 3. Build and smoke test

```bash
swift build -c release
.build/release/voicebridge-cli ping                        # engine + model availability
.build/release/voicebridge-cli stt  out.wav en large-v3-turbo
.build/release/voicebridge-cli tts --text "你好, world" --voice zh_CN-xiaoyi-medium
.build/release/voicebridge-cli tts --text "hello" --engine piper --no-play
```

`stt` prints a transcript plus a metadata line: `audio=…s  factor=…x` when the
clip length is known, otherwise `wallclock=…s` as a cost proxy.

## 4. Tests

```bash
swift test        # 11 pure-logic tests: models, URL helpers, error formatting,
                  # and cross-version whisper JSON parsing
```

Audio/shell paths are integration-tested by `voicebridge-cli ping`/`stt`/`tts`
(they need a mic and an installed binary), not unit tests.

## 5. transcode — resample extension point (AVAudioConverter)

`AudioTranscoder.transcodeToWAV` handles the 16 kHz/mono fast path and throws for
other shapes. To resample arbitrary sources stream-style (chunked, no whole-file
load):

```swift
let inFmt   = try AVAudioFile(forReading: from).processingFormat
let outFmt  = AudioFormats.targetFormat

// Convert sampleRate and channelCount in one pass; pull/push in frames.
let converter = try AVAudioConverter(from: inFmt, to: outFmt)
converter.requestData { _, inStatus, outStatus in
      // pull from the input file, push to a fresh output file; loop until done.
      _ = (inStatus, outStatus)
    }
```

Key points:
- Convert **sample rate** and **channel count** together — `AVAudioConverter`
  handles resampling and stereo→mono in one object.
- Pull/push in **frames**, not the whole buffer, to keep memory flat for long
  recordings.
- Write with a fresh `AVAudioFile(forWriting: out, settings: AudioFormats.target)`.

## 6. Mic capture

```swift
let cap = try MicrophoneCapture(outputURL: out)    // writes 16 kHz/mono/16-bit PCM
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
