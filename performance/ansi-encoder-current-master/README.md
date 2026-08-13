# Current-Master ANSI Encoder Addendum

## Decision

The V3 ANSI encoder candidate is ready for review as an isolated encoder
optimization against the current-master V1 baseline. Across four deterministic
200x50 workloads, V3 was 3.21x to 23.93x faster by the median of three
independent process medians. All 10 timing, allocation and race scopes matched
in output byte count and FNV-1a hash.

| Workload | V1 Median | V3 Median | Speedup |
| --- | ---: | ---: | ---: |
| Dense colour | 2,936,629 ns | 164,054 ns | 17.90x |
| Plain scroll | 1,404,308 ns | 69,620 ns | 20.17x |
| Sparse edit | 100,262 ns | 31,220 ns | 3.21x |
| Full redraw | 1,338,825 ns | 55,954 ns | 23.93x |

At 10,000 cells, allocation operations fell from 124,651 to 17 and
cumulative requested bytes fell from 5,386,440 to 1,048,568. The candidate
showed no regression in render scaling. Separate correctness and performance
reviews reported no findings.

## Evidence Boundary

This fork-only addendum compares these revisions:

- V1 is `49e333ae87a57952fc82ba479a55c35b975ff3cc`, the current-master
  baseline when the evidence was captured.
- V3 is `90f12051690f46f8d5837b861df14350a6ea4fde`, whose sole parent is V1.

The immutable historical showcase under `performance/ansi-encoder/` compares
V0 with V2. Its measurements must not be presented as V1-vs-V3 evidence. This
addendum does not replace or rewrite that showcase.

The claims here concern the isolated ANSI encoder. They do not establish an
overall Herdr speedup, terminal drawing latency, GPU performance, transport
latency or complete client/server latency.

## Validation Disclosure

A full `just check` success is not claimed. One live-handoff test failed
identically on V1 and V3 while 3,272 other tests passed. The shared failure
provides no evidence of a V3 regression, but it remains a failing check and is
not hidden.

The retained ordered-batch capture provides descriptive tail evidence. The
process is the replication unit. Each pooled p95 combines 300 repeated
within-process batches and is descriptive only; it is not an inferential
sample of 300 independent replications.

## Primary Charts

![Median current-master latency by workload][chart-1]

![Descriptive pooled p95 current-master latency by workload][chart-2]

![Allocation scaling by cell count][chart-3]

The optional race chart shows 6.494 FPS for V1 and 118.205 FPS for V3, an
18.20x isolated encoder throughput ratio under a deliberately extreme 800x600
fixture. It is not a normal terminal frame rate.

![Virtual race throughput][chart-4]

## Audit Paths

- [Results][1] contains the complete accepted numeric record.
- [Methodology][2] defines the fixtures, replication and validation boundary.
- [Reproduction][3] gives public audit and byte-identical chart commands.
- [Learnings][4] records interpretation limits and publication choices.
- [Machine-readable summary][5] supports arithmetic recomputation.
- [Ordered batch JSON][6] and [ordered batch TSV][7] retain all 2,400 values.

[chart-1]: charts/01-median-current-master-latency.svg
[chart-2]: charts/02-p95-current-master-latency.svg
[chart-3]: charts/03-allocation-scaling.svg
[chart-4]: charts/04-race-throughput.svg
[1]: RESULTS.md
[2]: METHODOLOGY.md
[3]: REPRODUCTION.md
[4]: LEARNINGS.md
[5]: data/summary.json
[6]: data/ordered-batches.json
[7]: data/ordered-batches.tsv
