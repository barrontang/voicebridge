# 🎙️ VoiceBridge

> **100% local, on-device speech-to-text + text-to-speech** for macOS / Apple Silicon.
> No cloud, no API keys, no data leaves your machine.

[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://www.swift.org/)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014%2B-black.svg)](https://developer.apple.com/documentation/swift)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Build](https://img.shields.io/github/actions/workflow/status/barrontang/voicebridge/ci.yml?branch=main)](https://github.com/barrontang/voicebridge/actions)

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

- **🎤 Speech-to-Text (STT)** — `whisper.cpp` with Metal (GPU) acceleration, `large-v3-turbo` model, live streaming transcripts.
- **🔊 Text-to-Speech (TTS)** — Pluggable back-end architecture:
  - **Piper** (default) — local ONNX, offline, natural-sounding
  - **Kokoro** — high-quality local TTS runtime
  - **Microsoft Edge-TTS** — online premium voices
  - **AVSpeechSynthesizer** — built-in system voice, always-available fallback
- **⚡ Live streaming STT** — Real-time word-by-word transcript as you speak.
- **💾 Persist & Export** — Save transcriptions to `.wav` + `.txt`, remember your settings.
- **🧪 Fully testable core** — `VoiceBridgeCore` is a pure SwiftPM library with no SwiftUI dependency; CI-friendly.
- **🖥️ Reference SwiftUI shell** — A minimal `App/` that wires up the core into a working macOS app.
- **➡️ Headless CLI** — `voicebridge-cli` for scripting, CI pipelines, and smoke tests.

```
┌─────────────────────────────────────────────────────┐
│                    VoiceBridge                        │
│                                                       │
│  STT  whisper.cpp  (Metal GPU · large-v3-turbo)      │
│   ↓                                                   │
│  TTS  Piper ←→ Kokoro ←→ Edge-TTS ←→ System Voice   │
│   ↓                                                   │
│  Output: .wav  .txt  (or live playback)               │
└─────────────────────────────────────────────────────┘
```

---

## 🚀 Quick Start

> **Requirement**: macOS 14+ on Apple Silicon (M1 / M2 / M3 / M4…).

```bash
# 1. Clone & build
git clone https://github.com/barrontang/voicebridge.git
cd voicebridge
swift build -c release
swift test

# 2. (Optional) Install engines
brew install whisper-cpp
./scripts/fetch-whisper-turbo.sh      # ~1.6 GB, ggml-large-v3-turbo
./scripts/install-piper.sh            # Piper ONNX + en/zh voices

# 3. Try the CLI
.build/release/voicebridge-cli ping
.build/release/voicebridge-cli stt  sample.wav en large-v3-turbo
.build/release/voicebridge-cli tts  --text "Hello from VoiceBridge!" --voice en_US-amy-medium
```

👉 Full walkthrough (audio resampling, mic capture, GUI wiring): [`docs/RUNBOOK.md`](docs/RUNBOOK.md)

---

## 📁 Project Layout

| Path | Description |
|---|---|
| `Sources/VoiceBridgeCore/` | Pure logic: `Audio/`, `Stt/`, `Tts/`, models, helpers. **No SwiftUI.** |
| `Sources/voicebridge-cli/` | Headless CLI executable (CI / scripting). |
| `Tests/VoiceBridgeCoreTests/` | Unit tests for the core library. |
| `App/` | Reference SwiftUI shell (`.app` via `scripts/make-app.sh`). |
| `docs/` | [`ARCHITECTURE`](docs/ARCHITECTURE.md) · [`RUNBOOK`](docs/RUNBOOK.md) |
| `scripts/` | `build.sh` · `fetch-whisper-turbo.sh` · `install-piper.sh` · `make-app.sh` |

---

## 🧠 Architecture

The codebase is split into a **framework-agnostic core** and a **thin UI shell**:

```
VoiceBridgeCore (SPM library, @testable, no UI)
    ├── Audio/          AudioFormats, Transcoder, MicrophoneCapture
    ├── Stt/            Shell, WhisperBackend, WhisperCliBackend, StreamingController
    ├── Tts/            TTSBackend protocol + Piper/Kokoro/EdgeTTS/System impls
    │                   TTSManager (orchestration), TTSConfigManager (state)
    └── Models.swift    SttModel, Transcription, VoiceError

voicebridge-cli  (SPM executable, CI smoke test)

App/             (reference SwiftUI shell — imports VoiceBridgeCore)
```

**Key design principles:**

- **Pluggable backends** — `WhisperBackend` / `TTSBackend` protocols; new engines drop in without touching call sites.
- **Graceful fallback** — Chosen TTS engine unavailable → built-in voice (warned once), pipeline never hard-fails.
- **No pipe deadlocks** — stdout *and* stderr drain on background queues; large transcripts can't stall the caller.
- **No lost UI state** — `@StateObject` owned once, injected down as `@ObservedObject`.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full design rationale.

---

## 🤝 Contributing

Contributions are welcome! Here's how to get involved:

### Adding a new TTS engine
1. Implement the `TTSBackend` protocol in `Sources/VoiceBridgeCore/Tts/`.
2. Register it in `TTSManager`.
3. Add a test in `Tests/VoiceBridgeCoreTests/`.
4. Open a PR 👋

### Reporting bugs
- Open an issue with a minimal reproduction.
- Include: macOS version, Swift version, model in use, full error log.

### Other ideas
- In-process whisper.cpp linking (removes App Sandbox limitation).
- Batch transcription CLI.
- Web audio / HTTP server mode.

---

## ⚠️ Caveats

- **`WhisperCliBackend` is out-of-process** — works today, but does **not survive the App Sandbox**. Shipping path: link whisper.cpp **in-process** (see [ARCHITECTURE](docs/ARCHITECTURE.md)).
- Audio target: **16 kHz / mono / 16-bit PCM** (whisper.cpp input shape).
- Model root defaults to `~/.voicebridge/models/tts`; override with `VOICEBRIDGE_MODELS_MAP` env var.

---

## 📜 License

Distributed under the [MIT License](LICENSE).

---

## 💬 Star History

If VoiceBridge saves you time or sparks an idea, a ⭐ star helps others discover it!

<a href="https://github.com/barrontang/voicebridge"><img src="https://api.star-history.com/svg?repos=barrontang/voicebridge&type=Date" alt="Star History" width="600"/></a>

---

## 🙋 Need Help?

- **Issues**: [GitHub Issues](https://github.com/barrontang/voicebridge/issues)
- **Discussions**: [GitHub Discussions](https://github.com/barrontang/voicebridge/discussions)

---

<sub>Built with ❤️ on Apple Silicon · whisper.cpp · Piper · Swift</sub>
