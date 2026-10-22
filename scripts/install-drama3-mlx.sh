#!/usr/bin/env bash
# install-drama3-mlx.sh — install the *local* Drama 3 runtime on Apple Silicon.
#
# Drama 3 is a 35B MoE text-to-speech model. The community 4-bit MLX
# conversion (mlx-community/fish-audio-drama-3-4bit) runs natively on an M-series
# Mac: 23.8 GB on disk, ~26 GB peak while generating — so it fits a 32 GB Mac
# with room to spare.
#
# This script is idempotent: it creates a private virtualenv for `mlx-audio`,
# installs it, then downloads the checkpoint into the app's model root.
#
# After it finishes, VoiceBridge selects the engine automatically (no env var):
#   scripts/start-drama3-mlx.sh
#
# Prereqs: Apple Silicon, `uv` (brew install uv), and the HF CLI
# (pipx install huggingface_hub).
set -euo pipefail

MODEL="mlx-community/fish-audio-drama-3-4bit"
ROOT="${VOICEBRIDGE_MODELS_MAP:-$HOME/.voicebridge/models/tts}"
VENV="${VOICEBRIDGE_MLX_VENV:-$HOME/.voicebridge/venvs/mlx-audio}"
DEST="$ROOT/fish-audio-drama-3-4bit"

say() { printf '%s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

# --- 0. Sanity checks --------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  die "Drama 3 MLX needs Apple Silicon (found $(uname -sm))."
fi
command -v uv >/dev/null 2>&1 || die "uv is required: brew install uv"
command -v hf >/dev/null 2>&1 || die "the HF CLI is required: pipx install huggingface_hub"

mkdir -p "$ROOT" "$(dirname "$VENV")"
free_gb=$(df -k "$ROOT" | awk 'NR==2 {printf "%d", $4/1048576}')
if (( free_gb < 25 )); then
  die "need ~25 GB free in $ROOT (found ${free_gb} GB)."
fi

# --- 1. mlx-audio in its own virtualenv -------------------------------------
if [[ ! -x "$VENV/bin/python" ]]; then
  say "→ creating $VENV"
  uv venv "$VENV" --python 3.12
fi
if ! "$VENV/bin/python" -c "import mlx_audio" >/dev/null 2>&1; then
  say "→ installing mlx-audio[server] (>= 0.6.0, for Drama 3)"
  uv pip install --python "$VENV/bin/python" -U "mlx-audio[server]>=0.6.0"
else
  say "✓ mlx-audio present"
fi

# --- 2. The 4-bit checkpoint -------------------------------------------------
# hf writes each shard under its final name only when it is complete, so the
# app's readiness check (config + codec + >= 18 GB of shards) stays honest
# during a resumed download.
say "→ downloading $MODEL (23.8 GB) into $DEST"
hf download "$MODEL" --local-dir "$DEST"

# --- 3. Verify that the runtime can see it -----------------------------------
"$VENV/bin/python" - "$DEST" <<'PY'
import pathlib, sys
dest = pathlib.Path(sys.argv[1])
config = dest / "config.json"
if not config.exists():
    sys.exit(f"✗ {config} is missing")
import json
model_type = json.loads(config.read_text()).get("model_type")
if model_type != "fish_drama3":
    sys.exit(f"✗ unexpected model_type {model_type!r}")
weights = [p for p in dest.glob("model-*.safetensors")]
total = sum(p.stat().st_size for p in weights)
if total < 18_000_000_000:
    sys.exit(f"✗ only {total/1e9:.1f} GB of weights — the download is incomplete")
print(f"✓ checkpoint ready: {len(weights)} shards, {total/1e9:.1f} GB")
PY

say ""
say "Done. Start the local server with:"
say "   scripts/start-drama3-mlx.sh"
say ""
say "VoiceBridge then reports 'Fish Audio (Drama 3, local MLX)' and keeps your"
say "text on this Mac (no consent sheet). The first request loads ~22 GB"
say "(10–30 s); later ones are warm."
