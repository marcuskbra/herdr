# ANSI Encoder Performance Case Study

This fork-only engineering case study documents an isolated ANSI encoder
optimization. It does not claim an overall Herdr speedup, authorize an upstream
pull request or change Herdr's tracked documentation policy.

The evidence layer is based on candidate
`d00dc4813d6803ce4efa3e9ad7b1c3533512aaff`. Its sole parent and measured
baseline is `06ca0baa12f4203c5bbad9ecadf53f9a475a52b2`. The showcase branch adds
only this public evidence directory on top of the candidate.

## Supported Result

For four deterministic 200x50 encoder workloads, the candidate reduced the
median of three independent process medians by 68.19% to 95.16%, a 3.14x to
20.66x isolated encoder speedup. Every comparable output matched in byte count
and FNV-1a hash. At 10,000 cells, counting-allocator operations fell from
124,651 to 17.

| Workload | Baseline | Candidate | Reduction | Speedup |
| --- | ---: | ---: | ---: | ---: |
| Dense colour | 2,904,975 ns | 177,608 ns | 93.89% | 16.36x |
| Plain scroll | 1,396,079 ns | 67,583 ns | 95.16% | 20.66x |
| Sparse edit | 99,825 ns | 31,750 ns | 68.19% | 3.14x |
| Full redraw | 1,442,512 ns | 233,545 ns | 83.81% | 6.18x |

These are release-mode encoder microbenchmarks. They exclude terminal drawing,
GPU work, transport and complete client/server latency. The supported claim is
that the isolated ANSI encoder is faster for these workloads while emitting
identical output.

## Independent Process Medians

Each point is a fresh process median from 100 batches of 10 encodes. The large
mark is the median of the three process medians. A logarithmic axis keeps the
four workloads comparable.

![Independent process medians for four 200x50 workloads][chart-1]

The gain appears in dense styled output, plain scrolling, sparse edits and full
redraws. The sparse result is smaller, which is consistent with less per-cell
work being available to remove.

## Ordered Batch Distributions

The focused rerun retained all 2,400 ordered batch values. Each panel contains
three process lines per revision. Candidate lines remain left of baseline lines
in all four workloads.

![Within-process ECDFs for four 200x50 workloads][chart-2]

Batches within one process are repeated observations, not independent
replicates. The process is the replication unit. These ECDFs show distribution
shape and tails, while the process-median chart remains the primary timing
result.

## Allocation Scaling

Baseline allocation operations grow almost linearly with cell count. Candidate
operations rise from 5 to 17 as output storage grows, instead of creating
per-cell temporary objects.

![Allocation operations and requested bytes by cell count][chart-3]

At 10,000 cells, allocation operations fell by 99.986%. Requested bytes fell
from 5,386,440 to 1,048,568, or 80.53%. Requested bytes are cumulative allocator
requests, not retained memory or resident set size. Both revisions emitted
276,444 bytes with hash `edfa0379543ed13d`.

## CPU Samples Shift to Direct Writers

The Time Profiler charts explain the mechanism. Each trace is normalized
independently, so its shares describe where sampled CPU work occurs within that
build. They do not measure wall-clock speedup.

![Normalized target-leaf CPU shares][chart-4]

Baseline samples concentrate in `write_cell` and legacy `build_sgr`. Candidate
samples move into `write_sgr`, `write_sgr_colour`, `write_u8_decimal`, style-key
construction and other direct-writer paths.

![Overlapping CPU stack-family shares][chart-5]

| Overlapping Stack Family | Baseline | Candidate |
| --- | ---: | ---: |
| `alloc::fmt::format` | 38.8% | 0.0% |
| `malloc`-containing | 35.6% | 1.3% |
| `realloc`-containing | 31.4% | 1.3% |
| Legacy `build_sgr` | 24.2% | absent |
| Direct `write_sgr*` | absent | 43.3% |

Families overlap and must not be added. A value of 0.0% means the family was
present but received no observed samples. "Absent" means that a
revision-specific function did not exist in that build.

## Native Call Trees

The flame summaries use actual sanitized root-to-leaf native stacks, cropped at
the profiling probe boundary. Width is normalized CPU sample share within one
trace.

![Baseline native CPU flame summary][chart-6]

The baseline tree contains wide branches through `write_cell`, `build_sgr`,
`alloc::fmt::format` and allocator functions.

![Candidate native CPU flame summary][chart-7]

The candidate tree replaces those branches with direct SGR writers, decimal
byte emission, style-key construction and output-buffer work. The two flame
charts are independently normalized. Their widths must not be compared as
absolute elapsed time.

## Output Equivalence

The dense 200x50 oracle was 276,444 bytes with FNV-1a hash
`edfa0379543ed13d`. The deliberately extreme 800x600 virtual fixture was
13,254,757 bytes with hash `29e298525b420eb3`. All timing, allocation and race
scopes matched across the two revisions.

Hash and byte equality prevent a false speedup caused by skipped cells or fewer
style transitions. Permanent differential tests cover colours, modifiers, wide
cells, hyperlinks, graphics and cursor transitions.

## Evidence Boundary

The 800x600 race produced 17.86x aggregate encoder throughput, but it is a
stress demonstration rather than a typical terminal frame. It remains in the
validated results and is not a headline chart.

Allocation call-site attribution is intentionally absent. Xcode's exported
Allocations List omitted transient responsible callers and was incomplete even
for retained objects. Publishing a call-site chart would imply coverage that
the export did not provide.

Native traces, Mach-O files, dSYMs, symbol archives, raw logs and PNG previews
are excluded. The [private artifact manifest][1] identifies those classes
without exposing local paths. The [learnings report][2] records failed and
rejected attempts.

## Reproduction Paths

The public pack supports three levels:

1. Audit checks the retained data, links, manifests and arithmetic without
   running a benchmark.
2. Recompute regenerates all seven SVG charts from sanitized data.
3. Reproduce reruns the fixed benchmark or private macOS/Xcode profiles in
   disposable worktrees.

The native allocation security retry, export and validation scripts are
forensic preservation tools, not a stable end-to-end reproduction command.
They require the retained private traces and exact profiling copies from the
recorded investigation. They have explicit subcommands, require safe external
roots and perform no private or destructive operation by default.

See the [reproduction guide][3], [methodology][4], [validated results][5] and
[public inventory][6] for exact commands and file scope.

[chart-1]: charts/01-latency-process-medians.svg
[chart-2]: charts/02-latency-ecdf.svg
[chart-3]: charts/03-allocation-scaling.svg
[chart-4]: charts/04-dense-cpu-leaf-share.svg
[chart-5]: charts/05-dense-cpu-stack-families.svg
[chart-6]: charts/06-dense-cpu-flame-master.svg
[chart-7]: charts/07-dense-cpu-flame-candidate.svg
[1]: private-artifacts.manifest.tsv
[2]: LEARNINGS.md
[3]: REPRODUCTION.md
[4]: METHODOLOGY.md
[5]: RESULTS.md
[6]: INVENTORY.md
