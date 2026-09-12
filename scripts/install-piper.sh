#!/usr/bin/env bash
# install-piper.sh — install the Piper TTS engine and a default voice.
#
# Piper is a local/ONNX TTS engine. We install the Python CLI + a couple of
# default multilingual voices into the app's model root, so the default engine
# (.piper) works offline with zero manual setup.
#
# Voices:
#   en:  en_US-lessac-medium        (clear, fast, ~25 MB)
#   zh:  zh_CN-huangshaoyu-medium   (natural Mandarin, ~30 MB) — or xiaoyi-medium
#
# Prereq: a working python3 + pip (Homebrew python or miniconda both fine).
set -euo pipefail

ROOT="${VOICEBRIDGE_MODELS_MAP:-$HOME/.voicebridge/models/tts}"
VOICE_DIR="$ROOT/piper/voice"
mkdir -p "$VOICE_DIR"

# --- 1. Install the piper-tts Python package -------------------------------
python3 -m pip install --upgrade pip >/dev/null 2>&1 || true
if command -v piper >/dev/null 2>&1; then
  echo "✓ piper CLI already on PATH"
else
  python3 -m pip install piper-tts || \
    python3 -m pip install --user piper-tts || {
       echo "✗ pip install piper-tts failed; install Python 3.10+ and retry" >&2
       exit 1
    }
  # Some builds put the entry point under a bin/; make it discoverable.
  hash -r 2>/dev/null || true
fi

# --- 2. Download default voices (onnx + onnx.json) -------------------------
download_voice() {
  local name="$1"; shift
  local out="$VOICE_DIR/$name"
  [[ -f "$out" && -f "$out.onnx.json" ]] && { echo "✓ $name present"; return 0; }
  echo "→ fetching voice $name …"
  # Official piper-voices host on HuggingFace (rhasspy/piper-voices).
  local base="https://huggingface.co/rhasspy/piper-voices/resolve/main"
  local ok=0
  for ext in "onnx" "onnx.json"; do
    url="$base/$name/$name.$ext"
    echo "   $url"
    if curl -fL --progress-bar -o "$VOICE_DIR/$name.$ext" "$url"; then
       ok=$((ok+1))
    fi
  done
  [[ $ok -eq 2 ]] && echo "✓ $name downloaded" || { echo "  voice $name incomplete (skipped)"; }
}

echo "Installing default voices…"
download_voice "en_US-lessac-medium" || true
download_voice "zh_CN-xiaoyi-medium" || true

echo
echo "Done. Voices in: $VOICE_DIR"
ls -1 "$VOICE_DIR" 2>/dev/null || true
echo
echo "Try:  .build/debug/voicebridge-cli tts --text \"你好, world\" --voice zh_CN-xiaoyi-medium"
