# Current-Master ANSI Encoder Chart Notes

The four SVG charts compare V1 `49e333ae` with its sole-child V3 candidate
`90f12051`. The immutable historical V0-vs-V2 charts live in a separate
showcase and are not inputs here.

## Chart Interpretation

- `01-median-current-master-latency.svg` shows the median of three independent
  process medians for four 200x50 workloads. The latency axis is logarithmic.
- `02-p95-current-master-latency.svg` shows nearest-rank p95 values pooled over
  300 retained batches for each workload and revision. These values are
  descriptive only. The process is the replication unit.
- `03-allocation-scaling.svg` shows counting-allocator operations and requested
  bytes over five exact cell counts. Requested bytes are not retained memory.
- `04-race-throughput.svg` shows aggregate encoder FPS for a virtual 800x600
  stress fixture. It is not a normal terminal frame rate.

## Sources

All charts use `../data/summary.json`. The p95 chart's values are independently
recomputed by the validator from `../data/ordered-batches.json` and
`../data/ordered-batches.tsv`.

## SHA-256

| File | SHA-256 |
| --- | --- |
| `01-median-current-master-latency.svg` | `f57565258c1b43bd6ae85e8d819a36734ec465b3ecf107fb4758045500ce3868` |
| `02-p95-current-master-latency.svg` | `cca8d5055b72352d131b89124f64bb5716bb90bafbb5186a7c12c8a38caa396d` |
| `03-allocation-scaling.svg` | `b020ca84ec66397e39370b182020c33edad2bb951fb2f97151f2d0fded3c05cf` |
| `04-race-throughput.svg` | `726067caeb04c632f8241e7456482f4a95756024f4c47c23bdfe6a20f6bed85a` |

## Deterministic Regeneration

Run the [temporary-copy regeneration command][1]. It produces byte-identical
SVG files with Python's standard library. No PNG preview or native trace is
included.

[1]: ../REPRODUCTION.md
