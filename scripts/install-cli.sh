#!/usr/bin/env bash
# install-cli.sh — build voicebridge-cli and put it on your PATH.
#
# Usage: scripts/install-cli.sh [BIN_DIR]     (default: ~/.local/bin)
#
# It installs a *symlink* to the release build, so a later `swift build -c
# release` (or re-running this script) updates the command in place. It also
# copies the DSH example patches to ~/.voicebridge/dsh/, so
#   voicebridge-cli chat --patch ~/.voicebridge/dsh/dsh-ollama.yml
# works from any directory, not just from inside the repo.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${1:-$HOME/.local/bin}"

cd "$ROOT"
swift build -c release --product voicebridge-cli
BIN="$ROOT/.build/release/voicebridge-cli"
[ -x "$BIN" ] || { echo "build failed: $BIN missing" >&2; exit 1; }

mkdir -p "$BIN_DIR"
ln -sf "$BIN" "$BIN_DIR/voicebridge-cli"
echo "installed: $BIN_DIR/voicebridge-cli -> $BIN"

mkdir -p "$HOME/.voicebridge/dsh"
cp "$ROOT"/examples/dsh-*.yml "$HOME/.voicebridge/dsh/"
echo "DSH patches: $HOME/.voicebridge/dsh/"

case ":$PATH:" in
  *":$BIN_DIR:"*) echo "✓ $BIN_DIR is on your PATH — run: voicebridge-cli ping" ;;
  *)
    echo
    echo "$BIN_DIR is not on your PATH. Add it (zsh):"
    echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
    ;;
esac
