# Runbook

Step-by-step: install the backends, run the CLI, and ship the app.

## 0. Prerequisites

- macOS 14+, Xcode 15+ command-line tools (`swift`, `swift test`).
- `brew` for the optional engines (or use the in-app downloader).

## 1. STT — whisper.cpp

```bash
brew install whisper-cpp             # Metal-accelerated on Apple Silicon
scripts/fetch-whisper-turbo.sh       # downloads ggml-large-v3-turbo (~1.6 GB)
# optional env override:
export WHISPER_CLI=/opt/homebrew/opt/whisper-cpp/bin/whisper-cli
```

Model files land in `~/.voicebridge/models/tts/whisper/ggml-<model>.bin`
(override the root with `VOICEBRIDGE_MODELS_MAP`, or pick a folder in
**Settings → Model folder**).

> **Cross-version output.** `WhisperCliBackend` is version-agnostic. It runs
> `whisper-cli` with `-otxt -oj` in an isolated temp CWD and reads the derived
> `<input>.txt` / `<input>.json` files, parsing three known JSON shapes
> (segment arrays, a flat object, and mixed `result`+`transcription`) for
> detected language, duration **and per-segment timings**. Builds without those
> flags fall back to stdout; a non-zero exit caused *only* by an unrecognised
> flag is retried without it, so genuine transcription errors still surface.

**Server mode (faster live captions).** `whisper.cpp` ships a server that
keeps the model resident, so the live path does not spawn a process per
window:

```bash
whisper-server -m ~/.voicebridge/models/tts/whisper/ggml-large-v3-turbo.bin
export VOICEBRIDGE_WHISPER_SERVER=http://127.0.0.1:8080
```

The app and the CLI pick it up automatically. It is still 100% local.

**No terminal?** Open the app → Settings → **Download models** → *Download*.
The file is streamed into a `.partial` sidecar, verified, and renamed into
place, so an interrupted download can never look like an installed model.

## 2. TTS — engines

| Engine | Install | Offline | Notes |
|---|---|---|---|
| Built-in (AVSpeech) | — | ✅ | zero-setup fallback, always available |
| Piper (DEFAULT) | `scripts/install-piper.sh` | ✅ | local ONNX, voices under `piper/voice/` |
| Kokoro-82M | install a `kokoro` CLI | ✅ | local, heavy (first run ~15 s) |
| Edge TTS | `pip install edge-tts` | ❌ | online MS voices; the app asks before sending |
| Drama 3 (local MLX) | `scripts/install-drama3-mlx.sh` | ✅ | 4-bit Apple Silicon, 23.8 GB, ~27 GB peak |
| Drama 3 (GPU server) | `sgl-omni serve --model-path fishaudio/drama-3` | ❌ | full-precision 35B: multi-speaker + cloning |

Env overrides: `VOICEBRIDGE_PIPER`, `VOICEBRIDGE_KOKORO`, `VOICEBRIDGE_EDGE_TTS`.

> **Privacy.** Edge TTS is always online. Drama 3 is online *only* when its
> server is on another machine — a server on `127.0.0.1` keeps the text on this
> Mac. The app asks for confirmation before the first remote send and shows a
> notice in the status line. Edge TTS receives the text through a private (0600)
> temp file, never on the command line.

> **Caveat (the built-in engine in a headless CLI).** `SystemVoiceBackend`
> speaks *in place* via `AVSpeechSynthesizer`, which delivers on the main run
> loop. In a long-lived app that loop is already running, so it just plays. In
> a short-lived process it can appear to "hang" because the process exits
> before the utterance drains — the engine now has a deadline, so it fails
> with a clear error instead of hanging. For headless smoke tests, prefer a
> file-producing engine (`piper`, `edgeTTS`, `kokoro`) with `--no-play`.

## 2b. Fish Audio Drama 3 (multi-speaker, voice cloning)

### Local on Apple Silicon (no GPU)

```bash
scripts/install-drama3-mlx.sh     # venv + mlx-audio[server] + the 4-bit checkpoint
scripts/start-drama3-mlx.sh       # http://127.0.0.1:8000, Ctrl-C to stop
```

The installer is idempotent. It writes:

| Path | What |
|---|---|
| `~/.voicebridge/venvs/mlx-audio/` | private venv with `mlx-audio[server] >= 0.6.0` |
| `~/.voicebridge/models/tts/fish-audio-drama-3-4bit/` | the 4-bit MLX checkpoint (23.8 GB) |

VoiceBridge detects a *complete* checkpoint by itself: the engine appears as
**Fish Audio (Drama 3, local MLX)**, needs no environment variable, and keeps
the text on the Mac (no consent sheet). A partially downloaded checkpoint is
ignored — the engine falls back to the built-in voice.

Measured on an M4 Pro / 64 GB (macOS 27), 44.1 kHz mono output:

| Case | Time |
|---|---|
| first request (loads ~22 GB) | ~29 s |
| warm, 3.8 s clip | ~2 s |
| warm, 15 s multi-speaker dialogue | ~13 s |
| MLX peak memory | 27.1 GB |

macOS may page the weights out when the server is idle — they are file-backed
mmap pages, not a leak — so the next request is slower while they fault back
in. The server keeps the loaded model in `/v1/models` regardless.

Change the port (e.g. 8000 is taken):

```bash
VOICEBRIDGE_DRAMA_PORT=8001 scripts/start-drama3-mlx.sh
export VOICEBRIDGE_FISH_TTS=http://127.0.0.1:8001
```

### Remote on a GPU

```bash
# SGLang-Omni (or vLLM-Omni - see the Drama 3 recipes)
uv pip install --prerelease=allow -v -e ".[fishaudio]"
hf download fishaudio/drama-3            # 37 GB (FP8 experts)
# …or the 4-bit checkpoint (20.8 GB, needs compute capability 8.0+):
# hf download fishaudio/drama-3-int4
sgl-omni serve --model-path fishaudio/drama-3 --port 8000
```

```bash
export VOICEBRIDGE_FISH_TTS=http://gpu-box:8000
```

```bash
.build/release/voicebridge-cli tts --text "<|speaker:2|> Hello." --engine fish
```

| Variable | Meaning |
|---|---|
| `VOICEBRIDGE_FISH_TTS` | the server's base URL (defaults to the local MLX server when a checkpoint is installed) |
| `VOICEBRIDGE_FISH_MODEL` | the model name/path sent to the server (defaults to the local checkpoint path) |
| `VOICEBRIDGE_FISH_REFERENCE` | a reference clip (local path or URL) for voice cloning |
| `VOICEBRIDGE_FISH_REFERENCE_TEXT` | the transcript of that clip |
| `VOICEBRIDGE_FISH_API_KEY` | bearer token, if the server wants one |

`voicebridge-cli ping` shows which case is active:

```text
  TTS  fish audio   : true (local MLX server responding)
  TTS  fish audio   : configured (local MLX), server not running
  TTS  fish audio   : false
```

Without a configured server or a complete checkpoint the engine reports itself
unavailable and the manager falls back to the built-in voice (and says so).

## 3. Build and smoke test

```bash
swift build -c release
.build/release/voicebridge-cli ping                        # engine + model availability
.build/release/voicebridge-cli stt  out.m4a en large-v3-turbo   # any format
.build/release/voicebridge-cli transcribe --in ./inbox --out ./outbox
.build/release/voicebridge-cli tts --text "hello" --engine piper --no-play
.build/release/voicebridge-cli tts --text "hello" --engine system
echo "piped text" | .build/release/voicebridge-cli tts --engine piper
```

`stt` prints a transcript plus a metadata line: `audio=…s  factor=…x` when the
clip length is known, otherwise `wallclock=…s` as a cost proxy.

`transcribe` walks a folder, writes one `.txt` per audio file and reports
`N transcribed, M failed` (one bad file never stops the batch).

## 4. Tests

```bash
swift test                                        # 94 pure-logic tests, < 1 s
VOICEBRIDGE_NETWORK_TESTS=1 swift test            # + the live download test
```

Audio/shell paths are integration-tested by `voicebridge-cli`
(`ping`/`stt`/`tts`), not by the unit tests.

## 5. Audio input

Everything that enters the STT path is normalised to **16 kHz / mono / 16-bit
PCM**:

```swift
// Live: the router does it for you.
let router = AudioInputRouter()
let token = router.addSink { frame in
    print(frame.samples.count, frame.startTime)   // 16 kHz mono frames
}
try router.start()

// Files: the transcoder does it for you.
try AudioTranscoder.transcodeToWAV(from: someMovie, to: scratchURL)
```

`AudioTranscoder` uses `AVAudioConverter` (proper anti-aliasing) and streams
the result; a linear-interpolation fallback covers exotic formats.

## 6. The app

```bash
./scripts/make-app.sh release        # → Build/VoiceBridge.app
open Build/VoiceBridge.app
```

The bundle is ad-hoc signed so the microphone prompt has a stable identity.
The GUI is a *reference* shell — for a shipping build you would also want:

* an **App Sandbox** with the microphone entitlement (note: an out-of-process
  `whisper-cli` does not survive the sandbox — link whisper in-process, or
  ship the binary as a bundled helper),
* a **notarized** build (`xcrun notarytool` — see
  `.github/workflows/release.yml` for the shape),
* **model downloads inside the sandbox** (the `ModelDownloader` needs a
  security-scoped bookmark for a user-chosen folder).

## 7. Settings file

`~/Library/Application Support/VoiceBridge/config.json`:

```json
{
  "schemaVersion": 2,
  "mode": "Piper (local, DEFAULT)",
  "voice": "en_US-amy-medium",
  "sttModel": "large-v3-turbo",
  "root": "/Users/you/.voicebridge/models/tts"
}
```

`schemaVersion` guards the file: an older record is migrated forward on load,
and a file written by a **newer** build is read but never overwritten.
