---
name: voicebridge-tts
description: |
  Turn any text — including this agent's own output — into spoken audio on the
  local machine using VoiceBridge's TTS engines. Activates when the user asks to
  "speak/read aloud/tts/voice this", "read my answer out loud", "say that", or
  wants a spoken summary/notification. Default engine is offline (Piper / system
  AVSpeech); use `--engine edge` only when the user accepts sending text online.
metadata:
  version: "1.0.0"
---

# voicebridge-tts — speak text aloud, including your own output

VoiceBridge is a macOS-on-Silicon STT/TTS bridge. The `voicebridge-cli` binary
turns text into audio and (when built with `--engine system` or a file-producing
engine like Piper) can play it. This skill teaches the agent to pipe text —
often its **own generated answer** — down `voicebridge-cli tts` and have the
machine speak it.

## When to use

- User says "read that out loud", "speak", "say it", "tts", "voice this".
- User wants a spoken confirmation / alert ("voice agent that can speak for me").
- You produced a long answer and the user wants an audio version.

## Prerequisite

The `voicebridge-cli` binary must be built and `piper` (offline, recommended) or
`edge-tts` (online) available. Check first:

```sh
<repo>/.build/release/voicebridge-cli ping
```

Build if missing:

```sh
cd <repo> && swift build -c release --target voicebridge-cli
# offline Piper voice (one-time):
bash <repo>/scripts/install-piper.sh      # if present
```

## How to speak text

### 1. Speak a literal string

```sh
<repo>/.build/release/voicebridge-cli tts --text "Hello from the agent." \
    --engine system
```

`--engine` options:
| engine       | offline? | note                                   |
|--------------|----------|----------------------------------------|
| `system`     | yes      | macOS built-in AVSpeech; always works  |
| `piper`      | yes      | high-quality offline; best default     |
| `kokoro`     | yes      | offline neural (needs model)           |
| `edge`       | no       | Microsoft voices; needs internet       |

### 2. Speak piped / agent-generated text (the main use-case)

Pipe whatever the agent just produced into the CLI:

```sh
printf '%s' "$AGENT_REPLY" | <repo>/.build/release/voicebridge-cli tts --engine piper
```

Equivalent explicit forms: `tts --stdin` or `tts --text -`. When text arrives
on a pipe, the CLI reads it and speaks it; if nothing arrives it prints
`[no text supplied on --stdin]` and stays silent rather than speaking a demo.

### 3. Pick a voice

```sh
… voicebridge-cli tts --voice en_US-lessac-medium --engine piper
# edge voices: --voice en-US-AriaNeural / zh-CN-XiaoxiaoNeural
```

## Privacy rule

`edge`/`edgeTTS` send the text to a Microsoft gateway — the CLI prints a
`[privacy] … is online` warning to stderr when it does. For an agent that "speaks
for me", prefer the **offline** engines (`system` or `piper`) so the text never
leaves the device. Only use `edge` when the user has accepted network egress.

## Notes

- The GUI (`VoiceBridgeApp`) has the same engine selector plus a "read my
  transcript/answer aloud" path — this skill is the headless/CI/agent variant.
- `--no-play` writes the WAV to the cache dir instead of playing; useful for
  capturing audio to a file for a later delivery channel.
