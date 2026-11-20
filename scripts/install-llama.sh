#!/usr/bin/env bash
# install-llama.sh — put a known-good llama-server on this Mac, for Qwen3-ASR.
#
# Usage: scripts/install-llama.sh [BUILD]
#
# Why not `brew install llama.cpp`:
#   Qwen3-ASR needs a build with the `qwen3vl` audio architecture (b8769+).
#   Homebrew may ship an older one, which starts happily and then fails with
#   "unknown model architecture: 'qwen3vl'" — a message that reads like a
#   corrupt model rather than an old binary. Pinning a build we tested, and
#   checking its checksum, removes that whole class of confusion.
#
# The app looks in ~/.voicebridge/bin/llama-b<build>/llama-server *before*
# $PATH, so this install wins over a stale Homebrew copy. Settings › Speech
# shows which binary is actually in use.
set -euo pipefail

BUILD="${1:-12560}"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) ASSET="llama-b${BUILD}-bin-macos-arm64.tar.gz" ;;
  x86_64) ASSET="llama-b${BUILD}-bin-macos-x64.tar.gz" ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

DEST="$HOME/.voicebridge/bin/llama-b${BUILD}"
URL="https://github.com/ggml-org/llama.cpp/releases/download/b${BUILD}/${ASSET}"
# SHA-256 of the arm64 asset for the default build; empty means "unverified"
# for a build the caller chose themselves.
EXPECTED=""
if [ "$BUILD" = "12560" ] && [ "$ARCH" = "arm64" ]; then
  EXPECTED="a755ae3beb436542485d27c197111ec7e9ac02789e936424406b33a80a778c63"
fi

if [ -x "$DEST/llama-server" ]; then
  echo "already installed: $DEST/llama-server"
  "$DEST/llama-server" --version | head -1
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "downloading $ASSET …"
curl -fL --progress-bar -o "$TMP/llama.tar.gz" "$URL"

if [ -n "$EXPECTED" ]; then
  ACTUAL="$(shasum -a 256 "$TMP/llama.tar.gz" | cut -d' ' -f1)"
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "checksum mismatch" >&2
    echo "  expected $EXPECTED" >&2
    echo "  actual   $ACTUAL" >&2
    exit 1
  fi
  echo "checksum ok"
else
  echo "note: no pinned checksum for build $BUILD — skipping verification"
fi

mkdir -p "$HOME/.voicebridge/bin"
tar xzf "$TMP/llama.tar.gz" -C "$TMP"
EXTRACTED="$TMP/llama-b${BUILD}"
[ -d "$EXTRACTED" ] || { echo "unexpected archive layout" >&2; exit 1; }

rm -rf "$DEST"
mv "$EXTRACTED" "$DEST"
echo "installed: $DEST/llama-server"
"$DEST/llama-server" --version | head -1

cat <<'EOF'

Next:
  1. Settings › Speech recognition › Engine → Qwen3-ASR
  2. Download the 0.6B and/or 1.7B model in "Download models"
  3. Pick a language, then use push-to-talk or Live

Models land in ~/.voicebridge/models/stt/qwen3/.
EOF
