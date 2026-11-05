# Development guide & next steps

This is the working guide for changing VoiceBridge: the local loop, the rules
CI enforces, the conventions a reviewer will expect, and what to build next.

- **Status**: `VERSION` 1.2.0 · 143 unit tests · 5 TTS engines · 3 STT paths
- **Companions**: [`ARCHITECTURE.md`](ARCHITECTURE.md) (why the code looks like
  this) · [`RUNBOOK.md`](RUNBOOK.md) (how to install/run it)

---

## 1. The 10-minute loop

```bash
git clone https://github.com/barrontang/voicebridge.git && cd voicebridge
swift build -c release          # ~30 s cold, ~2 s warm
swift test                      # ~3 s, no engines or mic required

scripts/dev-check.sh            # every CI gate, in CI order
scripts/dev-check.sh --no-catalog   # skip the network check
scripts/dev-check.sh --fix          # rewrite formatting, then check
```

`scripts/dev-check.sh` is the contract: **if it passes locally, CI passes.**
Reach for it before every push instead of reading the workflow.

To exercise the real engines (not needed for the tests):

```bash
.build/release/voicebridge-cli ping
.build/release/voicebridge-cli tts --text "Hello" --engine system   # no setup
.build/release/voicebridge-cli stt  clip.m4a en large-v3-turbo       # needs whisper-cpp
./scripts/make-app.sh release && open Build/VoiceBridge.app          # the GUI
```

To use the GUI's own code path while developing the UI, `swift run
voicebridge-gui` works, but the `.app` bundle is what gets the microphone
permission and a stable code-signing identity.

---

## 2. The gates (and why each exists)

| Gate | Command | The bug it prevents |
|---|---|---|
| Build | `swift build -c release` | — |
| Tests | `swift test` (with `VOICEBRIDGE_CONFIG_PATH` set) | a test writing to the user's real settings |
| No `print(` in Core | grep over `Sources/VoiceBridgeCore` | stdout noise competing with the CLI's output; use `VBLog` |
| No force-unwrap in Core | grep over `Sources/VoiceBridgeCore` | turning a recoverable engine error into a crash |
| No `TTSConfigManager()` in tests | grep over `Tests` | a test persisting into `~/Library/Application Support` |
| Formatting | `xcrun swift-format lint --strict` | unreviewable whitespace diffs |
| Version sync | `VERSION` == CLI `static let version` | a release that reports the wrong version |
| Catalog drift | `scripts/verify-catalog.sh` | a model download that silently skips its SHA-256 |
| Icon completeness | `iconutil -c iconset` round-trip | a truncated `.icns` (Finder shows a blank document) |

The greps are intentionally crude: they are cheap tripwires, not a type system.
A legitimate exception goes in a `///` comment line, which the grep skips.

---

## 3. Conventions the gates cannot check

1. **Everything gets its dependencies injected.** Model paths come from
   `VoiceBridgeEnvironment.paths`, binaries from `BinaryLocator`, settings from
   an injected `persistURL`. No new `static let` path, no `ProcessInfo` read in
   a type that could take a parameter (the environment default belongs in
   `fromEnvironment()`).
2. **Privacy is one switch.** Whether an engine transmits goes through
   `EnginePrivacy`. Do not add a second `isOnline`-style property — the last
   time two answers existed, the GUI and the CLI disagreed and a remote server
   was used without consent.
3. **Contracts are honest.** `speak(play: false)` must not make a sound; an
   in-place engine resolves when the audio *finishes*; a cache slot is named
   after the real container (`.mp3` for edge-tts). If the name of a function
   promises something, the implementation has to deliver it or the name changes.
4. **Diagnostics go to `VBLog`**, with the subsystem that owns the message
   (`VBLog.models`, `VBLog.stt`, …). User-facing text is returned, not logged.
5. **Comments explain *why*.** The codebase records the bug a line prevents
   ("the old code claimed to migrate but the `isLoaded` guard skipped it"), so a
   future reader does not undo it. Keep that style; do not narrate *what*.
6. **Public API is a promise.** `VoiceBridgeCore` is a library. Adding a public
   type is fine; changing the meaning of an existing one is a breaking change —
   prefer a new overload, and keep decoding tolerant (see `TTSMode`).

---

## 4. Where things live

```
Sources/VoiceBridgeCore/
  Audio/   one mic tap (AudioInputRouter) → resample → frames; transcoder; WAV writers
  Stt/     WhisperBackend (file) + StreamingWhisperBackend (windowed / server),
           LiveTranscriptEngine + UtteranceSegmenter + TranscriptReconciler,
           ProcessRunner (the only way to spawn a child)
  Tts/     TTSBackend + Piper / Kokoro / Edge / Fish / System, TTSManager,
           TTSConfigManager (all persisted state), EnginePrivacy, Playback, CacheGuardian
  DI/      VoiceBridgeEnvironment, ModelPaths, BinaryLocator, AppPaths, VBLog,
           ModelCatalog + ModelDownloader + ModelDownloadController
App/       SwiftUI shell only — imports the core, contains no business logic
Sources/voicebridge-cli/   headless entry point (stt / transcribe / tts / ping)
Tests/VoiceBridgeCoreTests/  unit tests; no engine installs, no network by default
```

The rule of thumb: **if it can be tested without a screen, it lives in Core.**

---

## 5. Writing tests that hold up

- Fake the seam, not the behaviour. `ModelFetcher`, `WhisperBackend`,
  `TTSBackend`, the engine factory and `BinaryLocator.isExecutable` are all
  injectable — use them. A test that needs `whisper-cli` installed is an
  integration test and belongs behind the `VOICEBRIDGE_NETWORK_TESTS` opt-in.
- Never construct `TTSConfigManager()` in a test. Pass a temp `persistURL`.
  (CI greps for this.)
- Assert the *user-visible* outcome, and name the test after it
  (`testStopCommitsTheOpenUtterance`, not `testFlush`).
- Every fix gets a test that fails before it. `ReviewRegressionTests.swift` is
  the model: one test per defect, named after the symptom.
- Timing: use `XCTestExpectation`/`fulfillment(of:)` with a generous timeout.
  `waitForDownload` in `ModelDownloadTests` polls the controller's own status
  rather than sleeping a fixed amount.

---

## 6. Adding an engine

**TTS**

1. Implement `TTSBackend` in `Sources/VoiceBridgeCore/Tts/`
   (`synthesize`, `producesAudioFile`, `isAvailable`, `displayName`,
   `requiresNetwork`, `preferredFileExtension`).
2. Add the case to `TTSMode` with a **stable slug** raw value, and its label to
   `displayName`. Do not touch an existing raw value — it is in `config.json`.
3. Register the factory in `TTSManager.defaultEngineFactory`.
4. Answer the privacy question in `EnginePrivacy` (and only there).
5. Add a test with a fake binary; add the engine to the README table and to
   `docs/RUNBOOK.md` §2.

**STT**

1. Implement `WhisperBackend` (file) or `StreamingWhisperBackend` (streaming).
2. Wire it into `LiveSttSession` / `WhisperCliBackend` selection, not into the UI.
3. Add a test with canned JSON; the parsers are all pure functions.

---

## 7. What to build next

Ordered by user value per week of work. Each entry names its entry point and a
definition of done, so the next agent can start without re-deriving the design.

### P0 · In-process whisper (`whisper.spm`)

*Why*: the live path spawns `whisper-cli` per window; that is the reason
`partialInterval` is 1.2 s, and a spawned child is also what blocks the App
Sandbox. `VOICEBRIDGE_WHISPER_SERVER` is the working interim (model stays
resident) but still needs a server the user must start.

*Start here*: `Sources/VoiceBridgeCore/Stt/StreamingWhisperBackend.swift`
(protocol) and `WhisperCliBackend.swift` (the process-backed implementation).

*Done when*: `SwiftWhisperBackend` conforms to `StreamingWhisperBackend`, is
selected automatically when the model is present, `partialInterval` drops to
≈0.3 s, and the package builds in a sandboxed app with no child process. Keep
the CLI backend as the fallback.

### P1 · Ship a notarized release

*Why*: the app is ad-hoc signed, so Gatekeeper warns on every download.

*Start here*: `.github/workflows/release.yml` — the notarization step exists but
is skipped without `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_SPECIFIC_PASSWORD`
(and `APPLE_KEY_ID` + `APPLE_PRIVATE_KEY` for the key path).

*Done when*: a `v*` tag produces `VoiceBridge-macOS-notarized.zip`, `stapler
validate` passes on a clean machine, and the release page is no longer a draft.

### P1 · Streaming playback for long text

*Why*: every engine renders the whole utterance to a file before a sound is
heard; a paragraph on Kokoro means seconds of silence. Fish already chunks
server-side; the local engines do not.

*Start here*: `Sources/VoiceBridgeCore/Tts/Playback.swift` +
`TTSManager.speak`.

*Done when*: the text is split on sentence boundaries, the first chunk plays
while the second synthesises, `stop()` cancels the queue, and
`speak(play: false)` still writes exactly one file.

### P2 · Localization

*Why*: the UI is English-only while the STT/TTS stacks are multilingual.

*Start here*: `App/ContentView.swift`, `App/SettingsView.swift` — user-visible
strings are inline `Text`/`Label` literals.

*Done when*: a String Catalog (`Localizable.xcstrings`) carries every string,
`swift build` emits no "unlocalized string" warnings, and at least `zh-Hans`
ships. Core error strings stay English (they are logs/API), but their *UI
copy* is localized at the call site.

### P2 · Voice cloning behind `TTSBackend`

*Why*: Drama 3 already clones from `VOICEBRIDGE_FISH_REFERENCE`; a local
zero-shot path (XTTS-v2 / MLX) would remove the 23.8 GB MoE.

*Start here*: `FishAudioBackend.swift` (the reference-clip plumbing is the
shape to copy) and the `CloningTTSEngine` note in `ARCHITECTURE.md`.

*Done when*: a reference clip + transcript on disk produces a cloned voice
offline, `EnginePrivacy` says `false`, and the Settings page can pick the clip.

### P3 · Live-caption polish

*Why*: captions are correct but dense; long sessions have no way to scroll back
or copy a range.

*Start here*: `LiveTranscriptViewModel` (state) and `App/ContentView.swift`
(rendering).

### P3 · Sandbox + entitlements

*Why*: the `.app` is unsandboxed, which is what makes `Process` and arbitrary
model folders work. Sandboxing becomes realistic only after P0.

*Done when*: `com.apple.security.app-sandbox` + `device.audio-input` +
user-selected read-only file access are in an entitlements file, and the model
folder is a security-scoped bookmark.

## 8. Release checklist

The version lives in **three** places; the CI gate only checks two of them.

1. `VERSION` — the file `make-app.sh` reads into `CFBundleVersion`.
2. `Sources/voicebridge-cli/VoiceBridgeCLI.swift` — `static let version`
   (CI fails if it differs from `VERSION`).
3. `.github/workflows/release.yml` — the `workflow_dispatch` default.

```bash
scripts/dev-check.sh                    # all gates
git tag -a v1.2.0 -m "VoiceBridge 1.2.0" && git push origin v1.2.0
```

The release workflow builds the bundle, notarizes when credentials exist, and
opens a **draft** release with both zips attached.

---

## 9. Environment variables

All of these are development seams; the app works without any of them. They are
documented in the README's privacy note because an absolute path in the
environment is also a hijack vector.

| Variable | Effect |
|---|---|
| `WHISPER_CLI` | absolute path to `whisper-cli` |
| `VOICEBRIDGE_WHISPER_SERVER` | `http://127.0.0.1:8080` → server mode |
| `VOICEBRIDGE_WHISPER_MODEL` / `_LANG` | default STT model / language |
| `VOICEBRIDGE_MODELS_MAP` | model root (same as Settings → Model folder) |
| `VOICEBRIDGE_PIPER` / `_KOKORO` / `_EDGE_TTS` | engine binaries |
| `VOICEBRIDGE_FISH_TTS` | Fish Audio / Drama 3 base URL |
| `VOICEBRIDGE_FISH_REFERENCE` / `_REFERENCE_TEXT` / `_API_KEY` / `_MODEL` | cloning + auth |
| `VOICEBRIDGE_CONFIG_PATH` | redirect `config.json` (tests use this) |
| `VOICEBRIDGE_NETWORK_TESTS=1` | opt in to the live download test |

---

## 10. The app icon

`Resources/AppIcon.icns` is built from two committed masters
(`AppIcon-1024.png`, `AppIcon-1024-small.png`): 16–64 px use the simplified art
because the sound arcs turn to mush there. Regenerate after a design change:

```bash
scripts/make-icon.sh --redraw   # needs a python3 with Pillow
scripts/make-icon.sh            # just rebuild the .icns (sips + iconutil)
```

`make-app.sh` copies the `.icns` into the bundle and points `CFBundleIconFile`
at it; `dev-check.sh` and CI fail if the icns loses a representation.
