#!/usr/bin/env bash
# start-drama3-mlx.sh — run Drama 3 locally with mlx-audio on Apple Silicon.
#
# The server keeps the ~22 GB checkpoint resident, so it must outlive a single
# request: start it once and leave it running. VoiceBridge talks to it over the
# OpenAI-compatible POST /v1/audio/speech API on 127.0.0.1:8000.
#
#   scripts/start-drama3-mlx.sh                 # foreground, Ctrl-C to stop
#   VOICEBRIDGE_DRAMA_PORT=8001 scripts/…       # another port
#
# Any extra arguments are passed to `mlx_audio.server`.
set -euo pipefail

VENV="${VOICEBRIDGE_MLX_VENV:-$HOME/.voicebridge/venvs/mlx-audio}"
HOST="${VOICEBRIDGE_DRAMA_HOST:-127.0.0.1}"
PORT="${VOICEBRIDGE_DRAMA_PORT:-8000}"

if [[ ! -x "$VENV/bin/mlx_audio.server" ]]; then
  echo "✗ mlx-audio is not installed in $VENV" >&2
  echo "  run scripts/install-drama3-mlx.sh first" >&2
  exit 1
fi

echo "Drama 3 (MLX) listening on http://$HOST:$PORT"
echo "The first request loads the checkpoint (~22 GB, 10–30 s); later ones are warm."
echo "VoiceBridge defaults to $HOST:$PORT — no VOICEBRIDGE_FISH_TTS needed."
exec "$VENV/bin/mlx_audio.server" --host "$HOST" --port "$PORT" "$@"
