#!/usr/bin/env bash
# build.sh — one-shot: build the Swift package + CLI.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
echo
echo "CLI:  .build/release/voicebridge-cli ping"
echo "Try:  .build/release/voicebridge-cli tts --text \"Hello\" --engine system"
