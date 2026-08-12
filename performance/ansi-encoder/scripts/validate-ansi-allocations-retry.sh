#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly ROOT="$(cd "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)" && pwd -P)"
# shellcheck source=ansi-private-root-safety.sh
source "$SCRIPT_DIR/ansi-private-root-safety.sh"
readonly PRIVATE_ROOT_RAW="${HERDR_ANSI_PRIVATE_ROOT:-}"
PRIVATE_ROOT=
PROFILE_DIR=
RETRY_DIR=
EXPORT_DIR=
readonly MASTER=06ca0baa12f4203c5bbad9ecadf53f9a475a52b2
readonly CANDIDATE=d00dc4813d6803ce4efa3e9ad7b1c3533512aaff

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s validate\n' "$0" >&2
  printf 'Set HERDR_ANSI_PRIVATE_ROOT and optionally HERDR_ANSI_EXPORT_DIR to safe external roots.\n' >&2
}

case "${1:-}" in
  validate) [[ $# -eq 1 ]] || { usage; exit 2; } ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

[[ -n "$PRIVATE_ROOT_RAW" ]] ||
  fail "HERDR_ANSI_PRIVATE_ROOT must name the private capture directory"
PRIVATE_ROOT=$(ansi_safe_external_root "$ROOT" "$PRIVATE_ROOT_RAW") ||
  fail "HERDR_ANSI_PRIVATE_ROOT failed canonical path validation"
PROFILE_DIR="$PRIVATE_ROOT/profiles"
RETRY_DIR="$PROFILE_DIR/retry-after-security-change"
# Validation and export are forensic operations. Their output must also stay
# outside the repository, even when a caller provides HERDR_ANSI_EXPORT_DIR.
EXPORT_DIR=$(ansi_safe_external_root "$ROOT" "${HERDR_ANSI_EXPORT_DIR:-$PRIVATE_ROOT/validated-allocation-export}") ||
  fail "HERDR_ANSI_EXPORT_DIR failed canonical path validation"
export HERDR_ANSI_PRIVATE_ROOT="$PRIVATE_ROOT"
export HERDR_ANSI_EXPORT_DIR="$EXPORT_DIR"
[[ "$(uname -s)" == Darwin ]] || fail "allocation trace validation requires macOS"
[[ -d "$RETRY_DIR/traces" ]] || fail "private allocation traces are missing"

bash -n "$SCRIPT_DIR/ansi-encoder-security-retry.sh"
bash -n "$0"
python3 - "$SCRIPT_DIR/export-ansi-allocations-retry.py" <<'PY'
from pathlib import Path
import sys
compile(Path(sys.argv[1]).read_text(), sys.argv[1], "exec")
PY
ansi_revalidate_external_root "$ROOT" "$PRIVATE_ROOT" ||
  fail "private root changed before validation"
ansi_revalidate_external_root "$ROOT" "$EXPORT_DIR" ||
  fail "export root changed before write"
HERDR_ANSI_EXPORT_DIR="$EXPORT_DIR" \
  python3 "$SCRIPT_DIR/export-ansi-allocations-retry.py" export

[[ "$(git -C "$ROOT" rev-parse "$MASTER^{commit}")" == "$MASTER" ]]
[[ "$(git -C "$ROOT" rev-parse "$CANDIDATE^{commit}")" == "$CANDIDATE" ]]
[[ "$(git -C "$ROOT" rev-parse "$CANDIDATE^")" == "$MASTER" ]]

for revision in master candidate; do
  original="$PROFILE_DIR/build/$revision-probe"
  copy="$RETRY_DIR/build/$revision-probe-get-task-allow"
  [[ -x "$original" && -x "$copy" ]] || fail "profiling binaries are missing"
  codesign --verify --strict --verbose=4 "$copy" >/dev/null 2>&1
  entitlements=$(mktemp "${TMPDIR:-/tmp}/herdr-entitlements.XXXXXX.plist")
  trap 'rm -f "$entitlements"' EXIT
  codesign -d --entitlements :- "$copy" >"$entitlements" 2>/dev/null
  python3 - "$entitlements" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    value = plistlib.load(stream)
assert value == {"com.apple.security.get-task-allow": True}, value
PY
  rm -f "$entitlements"
  trap - EXIT
  grep -Fq 'mode=allocations frames=5 ' \
    "$RETRY_DIR/raw/signed-$revision.probe.stdout.log"
  grep -Fq \
    'output_bytes=276444 output_hash=edfa0379543ed13d allocator=production-system counting_allocator=false' \
    "$RETRY_DIR/raw/signed-$revision.probe.stdout.log"
done

python3 - "$EXPORT_DIR" <<'PY'
from pathlib import Path
import csv
import re
import sys

root = Path(sys.argv[1])
with (root / "allocation-statistics.tsv").open() as stream:
    rows = list(csv.DictReader(stream, delimiter="\t"))
expected = {
    "master": (21113, 7, 21120, 1950368, 11360, 1961728),
    "candidate": (21113, 92, 21205, 1950432, 5254240, 7204672),
}
for revision, values in expected.items():
    heap = next(
        row for row in rows
        if row["revision"] == revision
        and row["category"] == "All Heap Allocations"
    )
    actual = tuple(
        int(heap[key])
        for key in (
            "persistent_count", "transient_count", "total_count",
            "persistent_bytes", "transient_bytes", "total_bytes",
        )
    )
    assert actual == values, (revision, actual)

for path in root.iterdir():
    if not path.is_file():
        continue
    text = path.read_text(errors="replace")
    assert not re.search(r"/(Users|home)/[^/<]+/", text), path
    assert not re.search(
        r"(?i)(authorization:\s*bearer|api[_-]?key\s*[:=]|password\s*[:=]|secret\s*[:=])",
        text,
    ), path
print("allocation export validation: pass")
PY

printf 'Validated private native captures and sanitized exports in %s\n' "$EXPORT_DIR"
