# ANSI Encoder Public Scope Inventory

This inventory is an index, so it uses inline links for direct navigation.
`MANIFEST.sha256` is the complete machine-readable file list and digest source.

## Narrative and Protocol

- [`README.md`](README.md): supported claim, seven-chart narrative and caveats.
- [`METHODOLOGY.md`](METHODOLOGY.md): build, timing, allocation, race and native
  profile protocols.
- [`RESULTS.md`](RESULTS.md): validated human-readable tables.
- [`LEARNINGS.md`](LEARNINGS.md): failed attempts, rejected claims and curation
  decisions.
- [`REPRODUCTION.md`](REPRODUCTION.md): Audit, Recompute and Reproduce levels.
- [`private-artifacts.manifest.tsv`](private-artifacts.manifest.tsv): omitted
  private artifact classes without private paths.

## Charts

Seven accepted SVGs appear under [`charts/`](charts/README.md):

1. Independent timing process medians.
2. Ordered-batch latency ECDFs.
3. Allocation scaling.
4. Dense CPU target-leaf shares.
5. Dense CPU overlapping stack families.
6. Baseline native CPU flame summary.
7. Candidate native CPU flame summary.

No PNG or native trace is in scope.

## Sanitized Data

- [`data/results.json`](data/results.json): primary timing, allocation, race,
  equivalence, load and environment result.
- [`data/ordered-batches.json`](data/ordered-batches.json): process vectors,
  aggregates and capture protocol.
- [`data/ordered-batches.tsv`](data/ordered-batches.tsv): 2,400 long-form batch
  observations.
- [`data/environment.json`](data/environment.json): technical environment
  without username, hostname or path.
- [`data/cpu-summary.tsv`](data/cpu-summary.tsv): CPU identity, leaf and
  overlapping family rows.
- [`data/cpu-final-collapsed-stacks.tsv`](data/cpu-final-collapsed-stacks.tsv):
  473 sanitized root-to-leaf stack rows plus header.
- [`data/cpu-trace-summary.tsv`](data/cpu-trace-summary.tsv): accepted trace
  aggregate identities and bundle-manifest hashes.
- [`data/allocation/allocation-statistics.tsv`](data/allocation/allocation-statistics.tsv):
  exported native allocation Statistics rows.
- [`data/allocation/allocation-export-surfaces.tsv`](data/allocation/allocation-export-surfaces.tsv):
  export surface availability.
- [`data/allocation/allocation-list-callers.tsv`](data/allocation/allocation-list-callers.tsv):
  explicitly incomplete live-object caller categories.
- [`data/allocation/counting-allocator-context.tsv`](data/allocation/counting-allocator-context.tsv):
  comparison context for the counting allocator.

## Reproduction Scripts

The [`scripts/README.md`](scripts/README.md) index describes every included
script, safe commands, private-root requirements and the exclusion of the
history rewrite utility.

## Manifest Rules

`MANIFEST.sha256` lists every public file except itself. Paths are relative to
this directory and sorted bytewise. The audit script verifies both hashes and
scope, so an unlisted file fails validation.
