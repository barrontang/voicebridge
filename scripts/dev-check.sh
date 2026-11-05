#!/usr/bin/env bash
# dev-check.sh — run every gate CI runs, locally, in the same order.
#
# Usage: scripts/dev-check.sh [--no-catalog] [--fix]
#
#   --no-catalog  skip the network check of ModelCatalog (fast edit loop)
#   --fix         rewrite the tree with swift-format instead of only linting it
#
# Why: CI has six cheap gates (`swift build`, `swift test`, the three hygiene
# greps and `swift-format lint`). A red CI on a pure formatting nit costs a
# round-trip; this catches it before the push.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CATALOG=1
FIX=0
for arg in "$@"; do
  case "$arg" in
    --no-catalog) CATALOG=0 ;;
    --fix)        FIX=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

failures=0
step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32mok\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; failures=$((failures + 1)); }

# ── 1. Build ────────────────────────────────────────────────────────────────
step "swift build -c release"
if swift build -c release >/tmp/voicebridge-build.log 2>&1; then
  ok "built"
else
  bad "build failed — see /tmp/voicebridge-build.log"
  tail -20 /tmp/voicebridge-build.log
fi

# ── 2. Tests ────────────────────────────────────────────────────────────────
step "swift test"
# A test must never touch the real settings file (same env as CI).
if VOICEBRIDGE_CONFIG_PATH="$TMPDIR/voicebridge-devcheck-config.json" \
   swift test >/tmp/voicebridge-test.log 2>&1; then
  ok "$(grep -oE 'Executed [0-9]+ tests, with [0-9]+ test[s]? skipped and [0-9]+ failures' \
        /tmp/voicebridge-test.log | tail -1)"
else
  bad "tests failed — see /tmp/voicebridge-test.log"
  grep -E 'error:|failed \(' /tmp/voicebridge-test.log | head -20
fi

# ── 3. Hygiene: no stdout from Core ────────────────────────────────────────
step "Core never prints"
if grep -rnE '\bprint[[:space:]]*\(' Sources/VoiceBridgeCore --include='*.swift' \
    | grep -v '/VBLog.swift' | grep -vE '^\S+:[0-9]+:[[:space:]]*///' >/dev/null; then
  bad "Core writes to stdout; route diagnostics through VBLog"
else
  ok "no print( in Core"
fi

# ── 4. Hygiene: no force-unwraps in Core ───────────────────────────────────
step "Core never force-unwraps"
if grep -rnE '[A-Za-z0-9_)]!([.,;)]|$)' Sources/VoiceBridgeCore --include='*.swift' \
    | grep -vE '^\S+:[0-9]+:[[:space:]]*///' >/dev/null; then
  bad "force unwrap in Core"
else
  ok "no force unwraps in Core"
fi

# ── 5. Hygiene: a test never builds the real config manager ────────────────
step "Tests stay off the real settings file"
if grep -rn 'TTSConfigManager()' Tests --include='*.swift' >/dev/null; then
  bad "a test builds a config manager without an explicit settings file"
else
  ok "every test passes an explicit settings file"
fi

# ── 6. Formatting ──────────────────────────────────────────────────────────
step "swift-format lint --strict"
if ! xcrun --find swift-format >/dev/null 2>&1; then
  bad "swift-format is not installed (Xcode 16+ ships it: xcrun swift-format)"
else
  if [ "$FIX" = 1 ]; then
    xcrun swift-format format --in-place --recursive \
      --configuration .swift-format Sources App Tests Package.swift
    ok "rewrote the tree with swift-format"
  fi
  if xcrun swift-format lint --recursive --strict \
      --configuration .swift-format Sources App Tests Package.swift \
      >/tmp/voicebridge-format.log 2>&1; then
    ok "formatting matches .swift-format"
  else
    bad "formatting drift — run: scripts/dev-check.sh --fix --no-catalog"
    head -20 /tmp/voicebridge-format.log
  fi
fi

# ── 6b. The app icon ──────────────────────────────────────────────────────
step "the app icon is complete"
if [ ! -f Resources/AppIcon.icns ]; then
  bad "Resources/AppIcon.icns is missing — run scripts/make-icon.sh"
else
  icns_dir="$(mktemp -d)"
  if iconutil -c iconset Resources/AppIcon.icns -o "$icns_dir/AppIcon.iconset" 2>/dev/null \
      && [ "$(ls "$icns_dir/AppIcon.iconset" | wc -l | tr -d ' ')" -ge 10 ]; then
    ok "AppIcon.icns has $(ls "$icns_dir/AppIcon.iconset" | wc -l | tr -d ' ') representations"
  else
    bad "AppIcon.icns is incomplete — rebuild it with scripts/make-icon.sh"
  fi
  rm -rf "$icns_dir"
fi

# ── 7. Version consistency ─────────────────────────────────────────────────
step "VERSION matches the CLI"
CLI_VERSION=$(grep -oE 'static let version = "[^"]+"' Sources/voicebridge-cli/VoiceBridgeCLI.swift \
  | grep -oE '[0-9][^"]+')
FILE_VERSION=$(cat VERSION)
if [ "$CLI_VERSION" = "$FILE_VERSION" ]; then
  ok "both $FILE_VERSION"
else
  bad "CLI says $CLI_VERSION, VERSION says $FILE_VERSION"
fi

# ── 8. Model catalog (network) ─────────────────────────────────────────────
if [ "$CATALOG" = 1 ]; then
  step "model catalog matches the servers (HEAD only)"
  if ./scripts/verify-catalog.sh >/tmp/voicebridge-catalog.log 2>&1; then
    ok "$(tail -1 /tmp/voicebridge-catalog.log)"
  else
    bad "catalog drift — run scripts/verify-catalog.sh --fix"
    tail -10 /tmp/voicebridge-catalog.log
  fi
else
  printf '\n(skipping the catalog check)\n'
fi

# ── Summary ────────────────────────────────────────────────────────────────
if [ "$failures" -eq 0 ]; then
  printf '\n\033[32mAll local gates passed.\033[0m\n'
  exit 0
fi
printf '\n\033[31m%d gate(s) failed.\033[0m\n' "$failures"
exit 1
