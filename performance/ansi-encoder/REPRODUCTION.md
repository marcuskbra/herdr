# Preservation and Reproduction Guide

This pack separates verification by cost and trust boundary. Audit and
Recompute use retained public data. Reproduce builds or profiles the fixed
revisions and can take substantial time.

## Audit

Audit parses JSON and XML, checks every TSV width, verifies all Markdown links,
confirms 2,400 ordered batches, recomputes CPU stack totals, rejects private or
binary artifact classes and verifies the SHA-256 manifest.

Run from the repository root:

```bash
python3 performance/ansi-encoder/scripts/validate-public-evidence.py
```

This level does not compile Herdr, run a benchmark or open a native trace.

## Recompute

The chart generators use the Python standard library and sanitized public data.
They do not need native traces for the `generate` path. To prove determinism
without changing the checked-out files, regenerate in a temporary copy:

```bash
set -euo pipefail
pack=performance/ansi-encoder
tmp=$(mktemp -d "${TMPDIR:-/tmp}/herdr-ansi-recompute.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cp -R "$pack" "$tmp/pack"
HERDR_ANSI_PUBLIC_ROOT="$tmp/pack" \
  python3 "$pack/scripts/generate-ansi-encoder-charts.py" generate
HERDR_ANSI_PUBLIC_ROOT="$tmp/pack" \
  python3 "$pack/scripts/generate-ansi-encoder-cpu-charts.py" generate
for chart in "$pack"/charts/*.svg; do
  cmp "$chart" "$tmp/pack/charts/$(basename "$chart")"
done
```

A successful run produces byte-identical copies of all seven SVGs. The public
pack intentionally excludes PNG previews.

## Reproduce the Benchmark

Fresh benchmark capture is supported only on macOS because the runner records
macOS load and environment data. It builds release test binaries in detached
disposable worktrees with isolated Cargo targets. The default output is in the
system temporary directory. Set an explicit output directory to preserve a new
run outside this tracked evidence pack.

```bash
HERDR_ANSI_OUTPUT="$HOME/herdr-ansi-evidence-output" \
  performance/ansi-encoder/scripts/ansi-encoder-evidence.sh run
```

The complete protocol includes build time, twelve 30-second cooldowns, six
timing processes, two allocation suites and four race processes. Do not use
this command as a quick validation check.

A timing-only ordered-batch rerun is also available:

```bash
HERDR_ANSI_OUTPUT="$HOME/herdr-ansi-ecdf-output" \
  performance/ansi-encoder/scripts/ansi-encoder-ecdf-rerun.sh run
```

Both runners verify the exact baseline and candidate objects plus their direct
parent relationship. They do not fetch, create branches, commit, modify remotes
or push.

## Reproduce Native CPU Profiles

Native profiling requires macOS, full Xcode 26.6 and xctrace 16.0. It creates
Mach-O files, dSYMs, symbols, logs and `.trace` bundles. They must remain
private.
Point `HERDR_ANSI_PRIVATE_ROOT` at a directory outside the repository.

```bash
export HERDR_ANSI_PRIVATE_ROOT="$HOME/herdr-ansi-private"
export HERDR_ANSI_WORK_ROOT="${TMPDIR:-/tmp}/herdr-ansi-instruments-work"
performance/ansi-encoder/scripts/ansi-encoder-instruments-pilots.sh build
performance/ansi-encoder/scripts/ansi-encoder-instruments-pilots.sh final-cpu
```

The runner injects its probe only into detached disposable worktrees, uses
separate Cargo targets, removes inherited profiling flags and launches profiled
targets with a minimal environment. Native traces never default to the public
pack.

Extract sanitized CPU data and regenerate the CPU charts only after reviewing
the private capture:

```bash
review=$(mktemp -d "${TMPDIR:-/tmp}/herdr-ansi-cpu-review.XXXXXX")
cp -R performance/ansi-encoder "$review/pack"
HERDR_ANSI_PRIVATE_ROOT="$HERDR_ANSI_PRIVATE_ROOT" \
HERDR_ANSI_PUBLIC_ROOT="$review/pack" \
  python3 \
  performance/ansi-encoder/scripts/generate-ansi-encoder-cpu-charts.py all
```

The `all` command writes sanitized TSVs and charts to the public-root selection.
Review and compare the temporary copy before replacing any retained evidence.

## Forensic Allocation Retry Review

This is not a stable public end-to-end reproduction command. It depends on the
retained private native traces and exact profiling copies from the recorded
investigation. The original Allocations attachment attempt failed without
entitlements. The retry signs only disposable copies with exactly
`get-task-allow`; it never changes original build products. Each operation
requires an explicit subcommand; invoking the script without one only prints
usage.

```bash
export HERDR_ANSI_PRIVATE_ROOT="$HOME/herdr-ansi-private"
performance/ansi-encoder/scripts/ansi-encoder-security-retry.sh context
performance/ansi-encoder/scripts/ansi-encoder-security-retry.sh record-original
performance/ansi-encoder/scripts/ansi-encoder-security-retry.sh record-minimal-c
performance/ansi-encoder/scripts/ansi-encoder-security-retry.sh sign-copies
performance/ansi-encoder/scripts/ansi-encoder-security-retry.sh record-signed
```

Re-export and validate retained private traces without recording again:

```bash
export_dir=$(mktemp -d "${TMPDIR:-/tmp}/herdr-ansi-allocation-review.XXXXXX")
HERDR_ANSI_EXPORT_DIR="$export_dir" \
  python3 performance/ansi-encoder/scripts/export-ansi-allocations-retry.py export
HERDR_ANSI_EXPORT_DIR="$export_dir" \
  performance/ansi-encoder/scripts/validate-ansi-allocations-retry.sh validate
```

Both scripts refuse export roots inside the repository and require the external
output to be empty or carry their ownership sentinel. Invoke either without its
explicit mode to print usage without creating or changing files. They
revalidate canonical roots immediately before destructive operations. This
narrows filesystem replacement races, but no path-based interface can eliminate
the race between final validation and the kernel operation. Neither command
makes an allocation call-site chart because the CLI export is incomplete.

## Preserve and Compare

For a new evidence run:

1. Keep native artifacts and raw logs outside the repository.
2. Review sanitized exports for paths, host values and secrets.
3. Recompute arithmetic from machine-readable inputs.
4. Regenerate charts in a temporary public-root copy.
5. Compare every SVG byte-for-byte.
6. Update `MANIFEST.sha256` only after the public scope is final.
7. Record excluded classes in `private-artifacts.manifest.tsv` without private
   paths.

The retained public data is evidence from one recorded environment, not a
portable performance guarantee. A fresh run may differ because of toolchain,
operating-system, hardware and workstation-load changes.
