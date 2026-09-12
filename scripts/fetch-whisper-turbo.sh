#!/usr/bin/env bash
# fetch-whisper-turbo.sh — download a whisper.cpp ggml model into the app's
# model root so the STT path works out of the box.
#
# Models download from ggerganov/whisper.cpp on HuggingFace.
# Usage:  scripts/fetch-whisper-turbo.sh [model]    (default: large-v3-turbo)
#   large-v3-turbo  ~1.6 GB   recommended
#   large-v3        ~3.1 GB   max accuracy
#   medium          ~1.5 GB
#   small           ~0.5 GB
#   base            ~0.14 GB  fast dictation
#   tiny            ~0.075 GB quick smoke test
set -euo pipefail

MODEL="${1:-large-v3-turbo}"
ROOT="${VOICEBRIDGE_MODELS_MAP:-$HOME/.voicebridge/models/tts}"
DIR="$ROOT/whisper"
mkdir -p "$DIR"
DEST="$DIR/ggml-$MODEL.bin"

if [[ -f "$DEST" ]]; then
  echo "✓ ggml-$MODEL.bin already present at $DEST"
  exit 0
fi

echo "→ downloading ggml-$MODEL.bin  →  $DEST"
# The ggml models live at: ggerganov/whisper.cpp (raw), and per-model repos.
# Try the canonical raw path first, fall back to the repo layout.
URLS=(
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/models/ggml-$MODEL.bin"
)
for url in "${URLS[@]}"; do
  echo "  $url"
  if curl -fL --progress-bar -o "$DEST.tmp" "$url"; then
     mv "$DEST.tmp" "$DEST"
     echo "✓ $DEST ($(du -h "$DEST" | cut -f1))"
     exit 0
  fi
done

echo "✗ could not download ggml-$MODEL.bin from any known location" >&2
echo "  Inspect layout:  https://huggingface.co/ggerganov/whisper.cpp/tree/main" >&2
exit 1
