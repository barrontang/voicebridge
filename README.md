# 🎙️ VoiceBridge

> **100% local, on-device speech-to-text + text-to-speech** for macOS / Apple Silicon.
> No cloud, no API keys, no data leaves your machine — unless you explicitly pick
> the one online engine and confirm it.

[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://www.swift.org/)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014%2B-black.svg)](https://developer.apple.com/documentation/swift)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![CI](https://github.com/barrontang/voicebridge/actions/workflows/ci.yml/badge.svg)](https://github.com/barrontang/voicebridge/actions/workflows/ci.yml)

---

## ✨ Why VoiceBridge?

| | VoiceBridge | Cloud STT/TTS APIs |
|---|---|---|
| **Privacy** | ✅ 100% offline | ❌ Audio leaves device |
| **Cost** | ✅ Free after one-time model download | ❌ Per-minute pricing |
| **Latency** | ✅ ~zero network round-trip | ❌ 200–1000 ms+ |
| **Offline** | ✅ Full functionality | ❌ Needs internet |
| **Languages** | ✅ 97+ (whisper.cpp) + 700+ (Piper) | ❌ Limited per provider |

---

## 🎯 Features

- **🎤 Speech-to-Text** — `whisper.cpp` with Metal (GPU) acceleration, `large-v3-turbo` by default.
  - **Live captions**: word-by-word, VAD-segmented utterances, committed once and never re-worded.
  - **Push-to-talk**: record a clip, transcribe it.
  - **Any input format**: mp3, m4a, aiff, wav, … are transcoded to whisper's shape automatically.
  - **Batch mode**: transcribe a whole folder from the CLI.
- **🔊 Text-to-Speech** — pluggable back-end architecture:
  - **Piper** (default) — local ONNX, offline, natural-sounding.
  - **Kokoro** — high-quality local TTS runtime.
  - **Microsoft Edge-TTS** — online premium voices (asks before sending your text).
  - **AVSpeechSynthesizer** — built-in system voice, always-available fallback.
- **⬇️ One-click model install** — download whisper models and Piper voices from the Settings page
  (progress, disk-space check, checksum, crash-safe writes). No terminal required.
- **🗂 A real model folder** — point VoiceBridge at any directory; the choice is remembered.
- **🧪 Fully testable core** — `VoiceBridgeCore` is a pure SwiftPM library (no SwiftUI, no UIKit);
  94 unit tests run in CI in under a second.
- **🖥️ SwiftUI app** — a reference macOS shell that wires the core into a working app.
- **➡️ Headless CLI** — `voicebridge-cli` for scripting, CI pipelines and smoke tests.

```
┌─────────────────────────────────────────────────────┐
│                    VoiceBridge                       │
│                                                      │
│  STT  mic ─▶ one tap ─▶ 16 kHz ─▶ VAD ─▶ whisper.cpp│
│  TTS  Piper ←→ Kokoro ←→ Edge-TTS ←→ System Voice   │
│  ↓                                                   │
│  Output: .wav  .txt  (or live playback)               │
└─────────────────────────────────────────────────────┘
```

---

## 🚀 Quick Start

> **Requirement**: macOS 14+ (Apple Silicon recommended).

```bash
# 1. Build & test
git clone https://github.com/barrontang/voicebridge.git
cd voicebridge
swift build -c release
swift test

# 2. Install the engines
brew install whisper-cpp                 # the STT engine
./scripts/fetch-whisper-turbo.sh         # ~1.6 GB, ggml-large-v3-turbo
./scripts/install-piper.sh               # Piper runtime + en/zh voices
# …or skip both: the app can download the models for you (Settings → Download models)

# 3. Try the CLI
.build/release/voicebridge-cli ping
.build/release/voicebridge-cli stt  recording.m4a en large-v3-turbo
.build/release/voicebridge-cli transcribe --in ./inbox --out ./outbox
.build/release/voicebridge-cli tts  --text "Hello from VoiceBridge!" --voice en_US-amy-medium
```

👉 Full walkthrough: [`docs/RUNBOOK.md`](docs/RUNBOOK.md)

---

## 🖥️ The app

```bash
./scripts/make-app.sh release      # → Build/VoiceBridge.app
open Build/VoiceBridge.app
```

The main page has two cards:

- **Text to Speech** — type, speak, stop, save the `.wav`/`.mp3`.
- **Speech to Text** — *Start Listening* (push-to-talk) or *Live* (streaming captions),
  and save the transcript as `.txt`.

The Settings page (⌘,) holds the engine/voice pickers, the whisper model, the model
folder, and the model downloads.

---

## 📁 Project Layout

| Path | Description |
|---|---|
| `Sources/VoiceBridgeCore/` | The library: `Audio/`, `Stt/`, `Tts/`, `DI/`, models. **No SwiftUI.** |
| `Sources/voicebridge-cli/` | Headless CLI (`stt`, `transcribe`, `tts`, `ping`). |
| `Tests/VoiceBridgeCoreTests/` | 94 unit tests. |
| `App/` | The SwiftUI shell (`.app` via `scripts/make-app.sh`). |
| `docs/` | [`ARCHITECTURE`](docs/ARCHITECTURE.md) · [`RUNBOOK`](docs/RUNBOOK.md) |
| `scripts/` | `build.sh` · `fetch-whisper-turbo.sh` · `install-piper.sh` · `make-app.sh` |
| `skills/voicebridge-tts/` | An agent skill: pipe any text into `voicebridge-cli tts`. |

---

## 🧠 Architecture

The codebase is split into a **framework-agnostic core** and a **thin UI shell**:

```
VoiceBridgeCore (SPM library, @testable, no UI)
    ├── Audio/    AudioInputRouter (one mic tap), AudioResampler, AudioTranscoder,
    │             WAVWriter, WAVStreamWriter, AudioFormats
    ├── Stt/      ProcessRunner, Shell, WhisperBackend + WhisperCliBackend,
    │             StreamingWhisperBackend + WindowedWhisperAdapter,
    │             LiveTranscriptEngine, UtteranceSegmenter, TranscriptReconciler,
    │             AudioRingBuffer, LiveSttSession, PushToTalkSession
    ├── Tts/      TTSBackend + Piper/Kokoro/EdgeTTS/System,
    │             TTSManager (orchestration), TTSConfigManager (state), Playback,
    │             CacheGuardian, Pipeline
    ├── DI/       VoiceBridgeEnvironment, ModelPaths, BinaryLocator, AppPaths,
    │             ModelDownloader + ModelCatalog + ModelDownloadController, VBLog
    └── Models.swift

voicebridge-cli  (SPM executable)
App/             (SwiftUI shell — imports VoiceBridgeCore)
```

**Key design principles:**

- **Pluggable backends** — `WhisperBackend` / `TTSBackend` protocols; a new engine drops in
  without touching the call sites. The TTS engine factory is injectable, so the orchestration
  is unit-tested without Piper/Kokoro/edge-tts installed.
- **One mic tap** — `AudioInputRouter` owns the single `AVAudioEngine` tap and fans frames out
  to subscribers; the live captions and the push-to-talk recorder share it.
- **Graceful fallback** — the chosen TTS engine is unavailable → built-in voice (the UI says so).
- **Honest contracts** — `speak(play: false)` never makes a sound; an in-place engine resolves
  when the utterance *finishes*; the cache slot is named after the engine's real file type.
- **No pipe deadlocks, no orphans** — one hardened process runner: both pipes are drained
  concurrently, stdin is written off the caller's thread, timeouts kill the child, and
  cancellation terminates it.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full design rationale.

---

## 🔒 Privacy

- The microphone audio **never leaves the machine**.
- Piper, Kokoro and the built-in voice run entirely offline.
- **Edge TTS is the one online engine.** The app asks before the first send and shows a
  notice in the status line; the text is passed to the engine through a private temp file
  (never on the command line).
- Settings live in `~/Library/Application Support/VoiceBridge/config.json` — no telemetry,
  no analytics, no network calls of any kind.

---

## 🤝 Contributing

Contributions are welcome!

### Adding a new TTS engine
1. Implement the `TTSBackend` protocol in `Sources/VoiceBridgeCore/Tts/`.
2. Register it in `TTSManager.defaultEngineFactory`.
3. Add a test in `Tests/VoiceBridgeCoreTests/`.
4. Open a PR 👋

### Adding a new STT engine
1. Implement `WhisperBackend` (file-based) or `StreamingWhisperBackend` (streaming).
2. Wire it into `LiveSttSession` / the CLI.
3. Add a test.

### Reporting bugs
- Open an issue with a minimal reproduction.
- Include: macOS version, Swift version, model in use, full error log.

---

## 🗺️ Roadmap

- [x] Live streaming captions with utterance segmentation and de-duplication
- [x] One-click model downloads
- [x] Any-format input + batch transcription
- [x] Hardened process runner (timeouts, cancellation, no deadlocks)
- [ ] **In-process whisper** (`whisper.spm`) — removes the per-window process spawn and
      unblocks the App Sandbox. Interim: a `whisper-server` backend behind the same protocol.
- [ ] Voice cloning (XTTS-v2 / Kokoro) behind `TTSBackend`
- [ ] Localization (the UI strings are centralised, so a String Catalog is mechanical)
- [ ] Notarized release build (the workflow is in `.github/workflows/release.yml`)

---

## 📜 License

Distributed under the [MIT License](LICENSE).

---

<sub>Built with ❤️ on Apple Silicon · whisper.cpp · Piper · Swift</sub>
