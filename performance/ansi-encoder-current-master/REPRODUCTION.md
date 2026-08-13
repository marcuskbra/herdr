# Current-Master ANSI Encoder Reproduction

## Audit the Public Addendum

Run the fail-closed validator from the repository root:

```bash
python3 \
  performance/ansi-encoder-current-master/scripts/validate-public-evidence.py
```

The audit verifies:

- The fixed V1/V3 revision relationship and comparison labels.
- Median, reduction, speedup, p95 and equivalence arithmetic.
- Exactly 24 ordered process-workload vectors and 2,400 ordered values.
- Exact JSON-to-TSV agreement.
- Four well-formed SVG charts and local Markdown links.
- Complete, unique and sorted SHA-256 manifest coverage.
- UTF-8 text-only scope with no symlinks, hardlinks, native artifacts,
  binaries, private paths, local identities or credential patterns.
- No filesystem or Git-state writes from bare or help script invocations.

Run the bounded privacy and no-write cases alone with:

```bash
python3 \
  performance/ansi-encoder-current-master/scripts/validate-public-evidence.py \
  --self-test
```

The validator fails closed when an invariant cannot be established.

## Regenerate Charts Byte-Identically

The generator uses only Python's standard library and the sanitized public
data. Regenerate into a temporary copy so the checked-out addendum remains
unchanged:

```bash
set -euo pipefail
pack=performance/ansi-encoder-current-master
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ansi-current-master.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cp -R "$pack" "$tmp/pack"
HERDR_ANSI_CURRENT_MASTER_ROOT="$tmp/pack" \
  python3 "$pack/scripts/generate-charts.py" generate
for chart in "$pack"/charts/*.svg; do
  cmp "$chart" "$tmp/pack/charts/$(basename "$chart")"
done
```

A successful run reproduces all four SVGs byte-for-byte. It does not compile
Herdr or run a benchmark.

## Inspect Machine-Readable Evidence

The [summary JSON][1] contains the fixed revisions, primary process summaries,
descriptive p95 values, allocation scaling, race data, output equivalence and
supporting check disclosures.

The [ordered JSON][2] preserves the process structure and all execution-order
values. The [ordered TSV][3] provides one value per row. The validator requires
the two representations to agree exactly.

## Fresh Measurement Boundary

This addendum is a preservation and audit pack, not a benchmark runner. A fresh
measurement would need to reconstruct the exact disposable-worktree protocol
described in [Methodology][4], build both fixed revisions in isolation and
capture a new environment record. New measurements must not overwrite this
retained comparison without review.

Hardware, toolchain, operating-system and workstation-load changes can alter
absolute latency. The retained evidence supports the recorded V1-vs-V3 result,
not a portable performance guarantee.

## Safe Invocation Contract

Invoking either public Python script with no arguments or `--help` performs no
write:

```bash
python3 performance/ansi-encoder-current-master/scripts/generate-charts.py
python3 \
  performance/ansi-encoder-current-master/scripts/validate-public-evidence.py \
  --help
```

Only the chart generator's explicit `generate` mode writes, and
`HERDR_ANSI_CURRENT_MASTER_ROOT` can direct those writes to a temporary copied
pack. The validator never modifies the addendum.

[1]: data/summary.json
[2]: data/ordered-batches.json
[3]: data/ordered-batches.tsv
[4]: METHODOLOGY.md
