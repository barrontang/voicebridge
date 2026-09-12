# VoiceBridge

Local, on-device **speech-to-text + text-to-speech** for macOS / Apple Silicon.
STT via **whisper.cpp**, TTS via **Piper** (default) with Kokoro / Edge-TTS /
built-in `AVSpeechSynthesizer` as pluggable backends.

The logic lives in a framework-agnostic, fully-testable core (`VoiceBridgeCore`);
a thin SwiftUI shell (`App/`) sits on top.

```
VoiceBridge ─┬─ STT  whisper.cpp        (Metal-accelerated, large-v3-turbo)
             └─ TTS  Piper (DEFAULT) / Kokoro / edge-tts / built-in
```

## Layout

| Path | What |
|---|---|
| `Sources/VoiceBridgeCore/` | Pure logic: audio, `Stt/`, `Tts/`, models, helpers. No SwiftUI. |
| `Sources/voicebridge-cli/` | Headless CLI that exercises the pipeline (CI / smoke test). |
| `Tests/VoiceBridgeCoreTests/` | Unit tests for the pure-logic parts. |
| `App/` | Reference SwiftUI shell (`VoiceBridgeApp` / `ContentView` / `SettingsView`). |
| `docs/` | [`ARCHITECTURE`](docs/ARCHITECTURE.md), [`RUNBOOK`](docs/RUNBOOK.md). |
| `scripts/` | `build.sh`, `fetch-whisper-turbo.sh`, `install-piper.sh`. |

## Quick start

```bash
# 1. Build + test
swift build -c release
swift test

# 2. (optional) engines
brew install whisper-cpp
scripts/fetch-whisper-turbo.sh       # ggml-large-v3-turbo, ~1.6 GB
scripts/install-piper.sh             # Piper + default en/zh voices

# 3. Run the CLI
.build/release/voicebridge-cli ping
.build/release/voicebridge-cli stt   out.wav en large-v3-turbo
.build/release/voicebridge-cli tts  --text "你好, world" --voice zh_CN-xiaoyi-medium
.build/release/voicebridge-cli tts  --text "hello" --engine system --no-play
```

See [`docs/RUNBOOK.md`](docs/RUNBOOK.md) for the full walkthrough (resample, mic
capture, wiring the GUI target).

## Design highlights

- **Pluggable backends.** `WhisperBackend` and `TTSBackend` are protocols; new
  engines drop in behind the same contract without touching call sites.
- **Graceful fallback.** Chosen TTS engine unavailable → built-in voice (warned
  once), so the pipeline degrades instead of failing.
- **No pipe deadlocks.** `Shell` / `Pipeline` drain stdout **and** stderr on
  background queues before waiting, so large transcripts can't stall the caller;
  non-zero exit throws `VoiceError`.
- **No lost UI state.** The observable config manager is owned once as
  `@StateObject` and injected as `@ObservedObject`.

## Caveats

- `WhisperCliBackend` is **out-of-process** — runs today, but does **not** survive
  the App Sandbox; ship by linking whisper.cpp **in-process** (see
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)).
- Audio target is **16 kHz / mono / 16-bit PCM** (whisper.cpp's input shape).
- Model root defaults to `~/.voicebridge/models/tts`; override with
  `VOICEBRIDGE_MODELS_MAP`.
