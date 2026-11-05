#!/bin/bash
# Verifies that every model in ModelCatalog is still where we say it is, with
# the size and checksum we recorded.
#
# Why this exists: `ModelDownloadController` only verifies a download when the
# catalog entry carries a `sha256`. A nil one silently disables the integrity
# check, and a stale `byteSize` silently misreports how much disk a model needs.
# Both rot quietly when an upstream repo re-uploads a file — this script makes
# that a CI failure instead of a user's corrupted model.
#
# Read-only: HEAD requests only, no downloads.
#
# Usage: scripts/verify-catalog.sh [--fix]
#        --fix  print ready-to-paste DownloadableModel snippets with the
#               values the server currently reports
set -uo pipefail

CATALOG="$(cd "$(dirname "$0")/.." && pwd)/Sources/VoiceBridgeCore/DI/ModelCatalog.swift"
FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

if [ ! -f "$CATALOG" ]; then
  echo "error: cannot find $CATALOG" >&2
  exit 2
fi

# Pull the (id, url, declared size, declared sha) out of the Swift source. The
# entries are written one property per line, which keeps this simple and means
# the script fails loudly if the formatting changes shape.
python3 - "$CATALOG" "$FIX" <<'PY'
import re, subprocess, sys, json

path, fix = sys.argv[1], sys.argv[2] == "1"
src = open(path).read()

entries, cur = [], {}
bases = dict(re.findall(r'let\s+(\w+Base)\s*=\s*"([^"]+)"', src))
if not bases:
    print("error: could not resolve the *Base constants", file=sys.stderr)
    sys.exit(2)


def resolve(raw):
    # Entries are written as url("\(whisperBase)/ggml-x.bin").
    for name, value in bases.items():
        raw = raw.replace("\\(" + name + ")", value)
    return raw


for line in src.splitlines():
    m = re.search(r'id:\s*"([^"]+)"', line)
    if m:
        if cur.get("url"):
            entries.append(cur)
        cur = {"id": m.group(1)}
    # The first remoteURL after an id is the model itself; later ones are
    # companions (.onnx.json).
    m = re.search(r'remoteURL:\s*url\("([^"]+)"\)', line)
    if m and not cur.get("url"):
        cur["url"] = resolve(m.group(1))
    m = re.search(r'byteSize:\s*([0-9_]+)', line)
    if m:
        cur["size"] = int(m.group(1).replace("_", ""))
    m = re.search(r'sha256:\s*"([0-9a-f]{64})"', line)
    if m:
        cur["sha"] = m.group(1)
if cur.get("url"):
    entries.append(cur)

if not entries:
    print("error: no catalog entries parsed", file=sys.stderr)
    sys.exit(2)

bad = 0
for e in entries:
    out = subprocess.run(
        ["curl", "-sIL", "--max-time", "30", e["url"]],
        capture_output=True, text=True).stdout
    status = re.findall(r'^HTTP/[0-9.]+ (\d{3})', out, re.M)
    sha = re.search(r'^x-linked-etag:\s*"?([0-9a-f]{64})"?', out, re.I | re.M)
    size = re.search(r'^x-linked-size:\s*(\d+)', out, re.I | re.M)

    if not status or status[-1] != "200":
        print(f"FAIL {e['id']}: HTTP {status[-1] if status else '???'} for {e['url']}")
        bad += 1
        continue

    remote_sha = sha.group(1).lower() if sha else None
    remote_size = int(size.group(1)) if size else None

    if remote_size is None:
        print(f"FAIL {e['id']}: server reported no size (not an LFS object?)")
        bad += 1
        continue

    if e.get("size") != remote_size:
        print(f"FAIL {e['id']}: byteSize {e.get('size')} != server {remote_size}")
        bad += 1
    if remote_sha and e.get("sha") != remote_sha:
        print(f"FAIL {e['id']}: sha256 {e.get('sha') or '(missing)'} != server {remote_sha}")
        bad += 1

    if fix:
        print(f'            byteSize: {remote_size:,},')
        print(f'            sha256: "{remote_sha}",')
    else:
        print(f"  ok {e['id']} ({remote_size:,} B)")

print()
if bad:
    print(f"{bad} catalog problem(s). Re-run with --fix to print the current values.")
    sys.exit(1)
print(f"catalog ok: {len(entries)} entries match the server")
PY
