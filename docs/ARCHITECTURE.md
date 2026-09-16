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
VoiceBridgeCore     (SPM library, no SwiftUI, @testable)
    ├── Audio/        AudioFormats, AudioTranscoder, MicrophoneCapture
    ├── Stt/          Shell, WhisperBackend, WhisperCliBackend, StreamingSttController
    ├── Tts/          TTSBackend + Piper/Kokoro/EdgeTTS/System backends,
    │                 TTSManager (orchestration), TTSConfigManager (state), Pipeline
    ├── Models.swift  SttModel, SttModelDescriptor, SttModelCatalog, Transcription,
    │                 VoiceError
    ├── DI/           the dependency-injection seam (see below)
    │   ├── VoiceBridgeEnvironment   the one container threaded into every core type
    │   ├── ModelPaths               on-disk layout (value type, not a static)
    │   ├── BinaryLocator            single, testable binary discovery
    │   ├── AppPaths                 persistent config + legacy migration
    │   ├── ModelDownloader          progress + checksum + crash-safe write
    │   └── VBLog                    os.Logger categories (no `print` in Core)
    └── Extensions
voicebridge-cli     (SPM executable, headless smoke test of the pipeline)
App/                (reference SwiftUI shell — NOT built by `swift build` tests)
    └── VoiceBridgeApp / ContentView / SettingsView
```

## Dependency injection: `VoiceBridgeEnvironment`

A code review found that **findings 1, 2, 3, 4, 5, and the tests gap all traced to
one root cause: the core read globals.** Model paths were static, binary discovery
was copy-pasted, config went to a reclaimed temp dir, logging was `print`, and there
was no fake-environment seam for tests.

`VoiceBridgeEnvironment` (a `Sendable`, value-type container) fixes this by being the
single object that carries `ModelPaths` (the user-chosen root) and a `BinaryLocator`
down into every core type:

* **Finding 1 & 2** — `TTSConfigManager` now owns a `paths: ModelPaths` value that
  `configureRoot(_:)` updates, and both `scanSttModels()` (STT) and
  `TTSManager.makeEngine()` (TTS) resolve off *that* value. There is no static
  `ModelPaths` anymore, so "I chose a custom models folder but half my models
  disappeared" is a **type-level impossibility**.
* **Finding 3** — `AppPaths.configURL()` puts settings in
  `~/Library/Application Support/VoiceBridge/config.json` (not the OS-reclaimed
  `DARWIN_USER_TEMP_DIR` the old `persistURL` used), with a one-time
  `migrateLegacyConfigIfNeeded()` and atomic writes.
* **Finding 4** — `BinaryLocator` is the *one* implementation of "resolve a binary";
  `Shell`, the backends, and the CLI all delegate to it. Its search order (override →
  extra prefixes → `$PATH`) is injectable and unit-tested.
* **Finding 5** — `VBLog` is an `os.Logger` wrapper; Core no longer `print`s. A CI
  step greps `Sources/VoiceBridgeCore` for `print(` and fails on any hit (outside
  `VBLog.swift`'s doc comments).
* **Finding 11** — because paths/binary/FS are injected, a test supplies a fake
  `ModelPaths` + `isExecutable` predicate and asserts the behavior. See
  `Tests/…/DIAndFixesTests.swift`; every correctness bug in the list is now caught
  by a single test.

## Pluggable engine contracts

- **`WhisperBackend`** — `transcribe(audio:language:model:useTimestamps:)`.
  Shipped impl: `WhisperCliBackend` (out-of-process `whisper-cli`). A future
  in-process `InProcessWhisper` (Finding 12: link whisper.cpp in-process) drops in
  behind the same protocol.
- **`TTSBackend`** — `synthesize(text:voice:outputPath:)`, `producesAudioFile`,
  `isAvailable()`, `displayName`. Shipped impls:
  - `PiperBackend`   — local ONNX, offline, DEFAULT.
  - `KokoroBackend`  — local high-quality runtime.
  - `EdgeTTSBackend` — online Microsoft Edge voices (not offline).
  - `SystemVoiceBackend` — `AVSpeechSynthesizer`, in-place, always available,
    zero-setup fallback.

`TTSManager.speak(...)` picks the engine, applies **graceful fallback**
(chosen engine unavailable → built-in voice), and (optionally) plays the result.

## Correctness fixes carried into the core

1. **State ownership.** The manager is owned once as `@StateObject` in
   `VoiceBridgeApp` and injected as `@ObservedObject` / `@EnvironmentObject`, so
   published selection survives re-renders (see `App/VoiceBridgeApp.swift`).
2. **Process pipes.** `Shell.run` and `Pipeline.runWithStdin` drain *both* stdout
   and stderr on background queues before waiting, so a large transcript can't fill
   a pipe buffer and deadlock the caller; non-zero exit surfaces as a `VoiceError`.
3. **Cancellation propagation.** Both process runners wrap their child in
   `withTaskCancellationHandler { … } onCancel: { process.terminate() }`, so a
   Stop / app-quit can't orphan a 30-minute transcription (Missing #2).
4. **Persistent, versioned config.** `AppPaths` + a top-level
   `schemaVersion` in `config.json` guard against a silent full-reset on the next
   schema change (Missing #4). `TTSConfigManager.load()` decodes both the versioned
   and legacy record, then re-persists as a forward migration.
5. **Crash-safe downloads.** `ModelDownloader` writes a `.partial` sidecar and
   `rename`-s to the final `.bin` only on success (and after a SHA-256 check when
   given one), pre-flights free disk space with
   `volumeAvailableCapacityForImportantUsage`, and streams `Progress` (Finding 8,
   Missing #3).
6. **User-extensible models.** `SttModel` (the closed enum) is now a *well-known
   subset* of the `SttModelDescriptor` value type + `SttModelCatalog.bundled`; a
   `.huggingFace(…)` / `.imported(…)` / `.userPath(…)` model is representable
   without a code change (Finding 7).

## Audio shape

whisper.cpp wants **16 kHz / mono / 16-bit little-endian PCM**. `AudioFormats.target`
is that exact shape and is used both as the mic-capture settings and the transcode
target, so the live-mic path needs no post-processing tap.

## Transcode (extension point)

`AudioTranscoder.transcodeToWAV` is a *fast path*: it copies files that are already
16 kHz / mono PCM, and **throws** for other shapes (e.g. 48 kHz stereo) with a
"resample required" signal, rather than shipping a half-verified converter.

---

## What this review intentionally left as extension points

These are larger, orthogonal efforts and are scoped separately from the bug fixes
above:

- **Finding 6 — single `AudioInputRouter`.** `MicrophoneCapture` (push-to-talk) and
  `StreamingSttController` (live) each open their *own* tap on the input device.
  The correct shape is one `AudioInputRouter` actor (one tap, N subscribers) that
  both become *consumers* of. Left for a dedicated pass.
- **Finding 9 — batch transcriber** (`voicebridge-cli transcribe --in dir --out dir`),
  which exercises a not-yet-implemented `AudioTranscoder` resampler.
- **Finding 10 — voice cloning.** Piper's zero-shot clone is a research branch
  (needs a training pass, GPU/CPU); a real cloning path would be a separate
  `CloningTTSEngine` (XTTS-v2 / Kokoro / MLX) behind `TTSBackend`.
- **Finding 12 — in-process whisper.** Linking `whisper.spm` removes the
  process-spawn overhead that forces `flushInterval = 1.2s` and unblocks the
  App Sandbox; it does not violate the "offline, no cloud" ethos (it's local
  inference) but is a C/C++ link step, handled separately.
