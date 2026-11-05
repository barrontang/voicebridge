# Architecture

VoiceBridge is a local (on-device) **speech-to-text + text-to-speech** app for
macOS / Apple Silicon, structured so the logic is fully testable and the GUI is
a thin shell on top.

## Why a core / shell split

The original PRD tangled observable UI state with the audio pipeline, which made
the code impossible to unit-test and caused `@Published` state to be lost on
every `SettingsView` re-render. We fixed it by isolating everything
framework-agnostic into `VoiceBridgeCore` and keeping SwiftUI in a separate
`App/` shell that only *imports* the core.

```
VoiceBridgeCore     (SPM library, no SwiftUI/UIKit, @testable)
    ├── Audio/      AudioInputRouter (the single mic tap), AudioResampler,
    │               AudioTranscoder, WAVWriter, WAVStreamWriter, AudioFormats
    ├── Stt/        ProcessRunner, Shell, WhisperBackend, WhisperCliBackend,
    │               StreamingWhisperBackend, WindowedWhisperAdapter,
    │               LiveTranscriptEngine, UtteranceSegmenter,
    │               TranscriptReconciler, AudioRingBuffer,
    │               LiveSttSession, PushToTalkSession
    ├── Tts/        TTSBackend + Piper/Kokoro/EdgeTTS/FishAudio/System backends,
    │               EnginePrivacy (the one "does it leave the Mac?" answer),
    │               TTSManager (orchestration), TTSConfigManager (state),
    │               Playback, CacheGuardian, Pipeline
    ├── DI/         VoiceBridgeEnvironment, ModelPaths, BinaryLocator, AppPaths,
    │               ModelDownloader, ModelCatalog, ModelDownloadController, VBLog
    └── Models.swift
voicebridge-cli     (SPM executable)
App/                (SwiftUI shell — imports VoiceBridgeCore)
```

## Dependency injection: `VoiceBridgeEnvironment`

An earlier review found that **findings 1, 2, 3, 4, 5, and the tests gap all
traced to one root cause: the core read globals.** Model paths were static,
binary discovery was copy-pasted, config went to a reclaimed temp dir, logging
was `print`, and there was no fake-environment seam for tests.

`VoiceBridgeEnvironment` (a `Sendable` value-type container) is the single
object that carries `ModelPaths` (the user-chosen root) and a `BinaryLocator`
down into every core type:

* **Paths** — `TTSConfigManager` owns a `paths: ModelPaths` value that
  `configureRoot(_:)` updates, and both `scanSttModels()` (STT) and
  `TTSManager` (TTS) resolve off *that* value. There is no static
  `ModelPaths` anymore, so "I chose a custom models folder but half my models
  disappeared" is a **type-level impossibility**. The UI resolves the same
  way: the app asks `ttsConfig.paths.whisperDir`, never the global.
* **Config** — `AppPaths.configURL()` puts settings in
  `~/Library/Application Support/VoiceBridge/config.json` (not the OS-reclaimed
  temp dir the old `persistURL` used), with a one-time
  `migrateLegacyConfigIfNeeded()` and atomic writes.
* **Binaries** — `BinaryLocator` is the *one* implementation of "resolve a
  binary"; `Shell`, the backends and the CLI all delegate to it. Its search
  order (override → extra prefixes → `$PATH`) is injectable and unit-tested.
* **Logging** — `VBLog` is an `os.Logger` wrapper; Core no longer `print`s. A
  CI step greps `Sources/VoiceBridgeCore` for `print(` and fails on any hit.
* **Tests** — a test supplies a fake `ModelPaths` + `isExecutable` predicate and
  asserts the behaviour (`Tests/…/DIAndFixesTests.swift`).

## The audio path: one tap, many consumers

The old code had two independent microphone consumers (`AVAudioRecorder` for
push-to-talk, an `AVAudioEngine` tap for live captions), each opening its own
device session — they fought over the input device.

`AudioInputRouter` now owns **exactly one** `AVAudioEngine` tap:

```
mic ─▶ AVAudioEngine tap (real-time thread)
          │  down-mix + copy into a pre-allocated ring (no allocation)
          ▼
      AudioSampleRing ─▶ pump task (background)
          │  resample to 16 kHz mono, cut into 100 ms frames
          ▼
      AudioFrame sinks: live engine · recorder · (level meter)
```

* The tap never allocates and never blocks on anything but a short mutex, so
  it is safe to leave installed for the life of the app.
* `AudioResampler` is the single resampling implementation (live path *and*
  file transcoder), with a two-pole anti-aliasing pre-filter — without it the
  8–24 kHz band folds back down and the speech turns metallic.
* `LiveSttSession` (live captions) and `PushToTalkSession` (record a clip) are
  both *sinks* on the router.

## Live captions: how the text stays correct

The live path used to re-transcribe a rolling window and patch the text with
word matching. That is O(n²), re-words earlier segments and leaks fragments.
The current pipeline is:

1. **VAD segmentation** (`UtteranceSegmenter`) — energy + zero-crossing with
   hysteresis splits the stream into utterances (1 s of silence closes one,
   a 30 s cap closes a monologue). Both numbers are accuracy settings, not
   latency knobs: 0.6 s cut people off mid-clause and 15 s split long turns
   at an arbitrary point.
   Each pass is then handed `overlapSeconds` (0.8 s) of already-heard audio as
   **left context**, clamped to the last committed audio so a 30 s hard cut
   never re-transcribes speech the transcript already covers.
2. **Timed segments** (`WhisperTranscriptParser`) — whisper's JSON carries
   per-segment `offsets`; they are parsed and shifted into the window's
   absolute time base.
   **Partial scheduling.** A partial re-transcribes the whole open utterance, so
   it slows down as the sentence grows. The scheduler therefore *coalesces*: it
   lets the running pass finish and queues one follow-up, instead of cancelling
   the pass on every tick. Cancelling made long utterances produce no caption
   at all (every pass was killed before whisper returned; the log showed
   `whisper-cli exited with status 15`).
3. **Reconciliation** (`TranscriptReconciler`) — a *watermark* (the end of the
   last committed utterance) drops everything that was already committed, so
   the overlap between two passes is never shown twice. A final utterance is
   committed forever; a partial may still be revised and is rendered muted.

The partial pass covers the **open utterance** (from its start to now), so the
caption reads as a sentence instead of an arbitrary trailing window.

## Contextual correction (opt-in, local)

Whisper has no memory: a homophone or a merged word is committed as-is. When the optional
corrector is on, each committed sentence is sent — with the previous three sentences — to a
local Ollama model (`think: false`, native `/api/chat`), and the answer is applied as a
**word-level revision**:

* `WordDiff` measures the change with a token Levenshtein distance (characters for CJK, which
  has no spaces), giving a changed-ratio rather than a new string.
* `CorrectionPolicy` rejects anything that smells like a paraphrase: more than 34 % of the
  sentence changed, a language/script switch, or a length outside 0.6–1.5×.
* An accepted correction becomes a `.revision` event carrying the **same id and range**, so
  the view model replaces one committed segment in place; nothing after it moves.
* One request in flight at a time, 6 s timeout, failures are silent (captions keep whisper's
  words) and logged at info level.

## Process execution: one hardened runner

`Shell.run` and `Pipeline.runWithStdin` were duplicated and shared the same
three bugs. They now both use `ProcessRunner`:

* a **launch failure** closes the pipe write ends explicitly (otherwise the
  readers wait for an EOF that never comes — a hang);
* the child's exit is awaited through a **continuation** fed by
  `terminationHandler` (no blocking `waitUntilExit()` on a Swift concurrency
  thread);
* **stdin is written on a detached task** (a payload bigger than the 64 KB
  pipe buffer would otherwise block the executor);
* both pipes are drained concurrently, so a large transcript can never fill a
  pipe buffer and deadlock the child;
* a **timeout** terminates the child (and the timer kills it *before* the
  error propagates, because the exit waiter only finishes when the child
  dies);
* **cancellation** terminates the child, so a Stop never orphans a
  30-minute transcription.

## Pluggable engine contracts

- **`WhisperBackend`** — `transcribe(audio:language:model:useTimestamps:)`.
  Shipped impl: `WhisperCliBackend` (out-of-process `whisper-cli`).
- **`StreamingWhisperBackend`** — `transcribe(samples:sampleRate:startTime:…)`
  for the live path. Shipped impl: `WindowedWhisperAdapter`, which wraps the
  file backend and maps whisper's timed segments into absolute time.
- **`TTSBackend`** — `synthesize(text:voice:outputPath:)`, `producesAudioFile`,
  `isAvailable()`, `displayName`, `requiresNetwork`, `preferredFileExtension`.
  Shipped impls: `PiperBackend`, `KokoroBackend`, `EdgeTTSBackend`,
  `FishAudioBackend` (Fish Audio Drama 3 — a 35B MoE model behind an
  OpenAI-compatible `/v1/audio/speech` endpoint: multi-speaker and voice
  cloning. The default is the 4-bit MLX checkpoint on `127.0.0.1`, which keeps
  the text on-device; a server on another machine is treated like Edge TTS by
  the consent flow, driven by `FishAudioBackend.requiresNetwork`),
  `SystemVoiceBackend`.

`TTSManager.speak(...)` picks the engine, applies **graceful fallback**
(chosen engine unavailable → built-in voice), plays the result and returns a
`SpeakResult` that says what actually ran (`fellBack`, `hasAudioFile`,
`privacyNotice`). The engine factory is injectable, so all of that is unit
tested without any engine installed.

## Correctness fixes carried into the core

1. **State ownership.** The manager is owned once as `@StateObject` in
   `App/VoiceBridgeApp.swift` and injected as `@ObservedObject` /
   `@EnvironmentObject`, so published selection survives re-renders.
2. **Process pipes.** See "Process execution" above.
3. **Cancellation propagation.** Both process runners terminate their child on
   cancellation.
4. **Persistent, versioned config.** `AppPaths` + a `schemaVersion` in
   `config.json` guard against a silent full-reset on the next schema change.
   `TTSConfigManager.load()` decodes both the versioned and the legacy record,
   migrates a legacy file forward *immediately* (the old code claimed to but
   the `isLoaded` guard skipped it), and refuses to overwrite a file written
   by a **newer** build.
5. **Crash-safe downloads.** `ModelDownloader` writes a `.partial` sidecar and
   `rename`s to the final file only on success (and after a SHA-256 check when
   one is known), pre-flights free disk space and streams `Progress`.
6. **User-extensible models.** `SttModel` (the closed enum) is a well-known
   subset of `SttModelDescriptor` + `SttModelCatalog.bundled`;
   `ModelCatalog` is the *downloadable* catalog the Settings page renders.
7. **Honest playback.** `speak(play: false)` does not speak; an in-place engine
   resolves when the utterance finishes (with a deadline, so a host without
   an output device fails instead of hanging); the cache slot is named after
   the engine's real file type (edge-tts writes `.mp3`, not mp3 bytes in a
   `.wav`).

## Audio shape

whisper.cpp wants **16 kHz / mono / 16-bit little-endian PCM**. Everything
that enters the STT path is normalised to that shape:

* the live path: the router resamples the mic to 16 kHz mono;
* the file path: `AudioTranscoder` converts with `AVAudioConverter`
  (streaming, chunked, so a long recording has a flat memory profile) and
  falls back to a linear resampler if the converter refuses the format;
* the push-to-talk path: the recorder writes the canonical shape itself.

## Extension points (intentionally left open)

- **In-process whisper** (Finding 12). Linking `whisper.spm` removes the
  per-window process spawn (the reason `partialInterval` is 1.2 s) and
  unblocks the App Sandbox. It does not violate the offline ethos — it is
  local inference — but it is a C/C++ link step. **Interim (implemented):**
  `WhisperServerBackend` talks to a local `whisper.cpp` server
  (`VOICEBRIDGE_WHISPER_SERVER=http://127.0.0.1:8080`), which keeps the
  model resident and speaks the same `WhisperBackend` protocol.
- **Voice cloning.** Piper's zero-shot clone is a research branch; a real
  cloning path would be a `CloningTTSEngine` (XTTS-v2 / Kokoro / MLX) behind
  `TTSBackend`.
- **Localization.** The UI is small and its strings live in the SwiftUI
  shell; moving them into a String Catalog is a mechanical follow-up.
- **A `whisper.cpp` model server / GPU batching** for throughput on long
  files.
