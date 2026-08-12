# ANSI Encoder Chart Notes

The seven accepted charts compare baseline `06ca0baa` with candidate
`d00dc481`. The full commit identifiers and parent relationship appear in the
case-study root.

## Chart Interpretation

- `01-latency-process-medians.svg` shows three independent process medians per
  revision and the median of those medians. The latency axis is logarithmic.
- `02-latency-ecdf.svg` shows one ECDF per fresh process and workload. Lines are
  grouped by revision but not pooled for inference.
- `03-allocation-scaling.svg` shows counting-allocator operations and requested
  bytes over five exact cell counts. Requested bytes are not retained memory.
- `04-dense-cpu-leaf-share.svg` ranks the innermost target Herdr function in
  each sample. Each trace is independently normalized.
- `05-dense-cpu-stack-families.svg` reports complete-stack containment.
  Families overlap and must not be added.
- `06-dense-cpu-flame-master.svg` preserves sanitized baseline root-to-leaf
  stack hierarchy.
- `07-dense-cpu-flame-candidate.svg` preserves sanitized candidate root-to-leaf
  stack hierarchy.

Flame width is normalized CPU sample share within one trace, not elapsed time.
The validated timing benchmark remains authoritative for speedup.

## Sources

Charts 01 to 03 use `../data/results.json`,
`../data/ordered-batches.json` and `../data/ordered-batches.tsv`. Charts 04 to
07 use `../data/cpu-summary.tsv`,
`../data/cpu-final-collapsed-stacks.tsv` and
`../data/cpu-trace-summary.tsv`.

Native traces remain private. The public pack intentionally contains no PNG
previews.

## SHA-256

| File | SHA-256 |
| --- | --- |
| `01-latency-process-medians.svg` | `18d9e757240d958367561ff11d96a6769d74fec4ae01490dd4458e18b261546b` |
| `02-latency-ecdf.svg` | `28fe2d7eec7e6ee3d4e0b273201bc0976ebdc7d997ec1e38b5a948610031812f` |
| `03-allocation-scaling.svg` | `c7591afe25e6e3bdf82df95740414ec218e45023ebe1798df527b5a713cbf854` |
| `04-dense-cpu-leaf-share.svg` | `7044ab12433aa045f394496f75794f2d34d17cb75769003fdc6d1edb4a605d04` |
| `05-dense-cpu-stack-families.svg` | `9cf224de296687e93bc3eeb45c590ebf1a0ca6accecc3bb7c7676b7b7d1fbc82` |
| `06-dense-cpu-flame-master.svg` | `fbc5e7e62b52109f4bea313d81a2b4beda4120f532a79ebe36ba9e044114b938` |
| `07-dense-cpu-flame-candidate.svg` | `a20b66c839be65ed9ef6913aaba4332fb753f3701dd8a0b3743ee870c2f1d442` |

## Deterministic Regeneration

Run the [reproduction guide][1] Recompute command. The chart generators use the
Python standard library and write SVG only. A temporary-copy run produced
byte-identical output for all seven files.

[1]: ../REPRODUCTION.md
