# ANSI Encoder Methodology

## Fixed Revision Relationship

The measured baseline is
`06ca0baa12f4203c5bbad9ecadf53f9a475a52b2`. The candidate is
`d00dc4813d6803ce4efa3e9ad7b1c3533512aaff`. Git verifies that the candidate has
one parent, that the parent is the baseline and that the candidate is exactly
one commit ahead.

The showcase evidence is a separate fork-only layer based on the candidate. It
does not alter either measured revision.

## Disposable Build Isolation

The runners create detached worktrees for both revisions. Benchmark-only probes
are injected into those worktrees, never into a source branch. Each revision
uses a separate Cargo target directory to prevent artifact reuse across equal
package identities. Cleanup removes only work roots carrying the runner's
marker.

Builds use `cargo test --release --locked --bin herdr --no-run`,
`CARGO_INCREMENTAL=0` and one Cargo build job. Profiling and Rust flag
environment variables are removed. Production timing binaries use the system
allocator. Allocation binaries alone enable the test counting allocator, which
delegates to `System`.

## Timing Protocol

Each fresh process runs four 200x50 workloads:

- Dense colour changes every styled cell.
- Plain scroll changes every unstyled cell.
- Sparse edit changes 16 deterministic cells.
- Full redraw encodes without a previous frame.

Each workload performs 20 warm-ups and then 100 batches of 10 encodes. Fixtures
and output oracles are prepared outside the timed region. Every process reports
the sample minimum, median and maximum plus output bytes and hash.

Three independent processes per revision run in counterbalanced order:

1. Baseline, candidate.
2. Candidate, baseline.
3. Baseline, candidate.

A 30-second cooldown precedes every process. The runner records the 1, 5 and
15-minute load averages immediately before launch. The headline statistic is
the median of three process medians. It does not treat the 300 within-process
batches as independent runs.

## Ordered Batch Rerun

A timing-only rerun retains all 100 batch latencies for every workload and
process. The resulting 24 vectors contain 2,400 values. ECDF lines remain
separate by process and are grouped by revision only for display. Tails are
descriptive evidence, not extra replication.

## Allocation Scaling

The feature-gated counting allocator measures dense styled encodes at 1, 10,
100, 1,000 and 10,000 cells. Each point follows 20 warm-ups and contains 10
measured frames. The runner requires stable allocation counts and requested
bytes across those frames.

`requested_bytes` sums successful allocator request sizes. It is not retained
memory, heap size or resident set size.

## Virtual Race

The 800x600 stress fixture runs two counterbalanced 10-second rounds. The
encoder checks output length inside the loop and hashes a stable sample outside
the timed region. Aggregation sums frames and elapsed seconds per revision.
This test shows isolated encoder capacity under an extreme fixture. It is not a
normal terminal frame rate.

## Native CPU Attribution

Final CPU captures use Xcode 26.6 Time Profiler with an eight-second time limit,
a deterministic dense 200x50 fixture and a 14-second post-trigger work window.
The probe then stays alive for eight seconds to prevent target exit from
truncating capture.

The accepted baseline trace contains 7,894 samples over 7.895996542 seconds.
The candidate contains 7,707 samples over 8.091001458 seconds. All samples have
resolved native backtraces and an innermost Herdr frame.

Leaf shares choose the innermost Herdr function. Stack-family shares inspect the
complete native stack and overlap. Flame summaries preserve native root-to-leaf
order and crop only the outer test harness at `ansi_instruments_probe`.

Native traces and symbols remain private. Public CPU TSVs contain sanitized
aggregates and collapsed stacks.

## Allocation Trace Retry

Unsigned Xcode Allocations attachment failed for both Herdr probes and a minimal
C control. Disposable copies were ad hoc signed with exactly
`com.apple.security.get-task-allow=true`. The signing step verified that the
`__TEXT,__text` bytes remained unchanged. Original build products were never
modified.

The signed traces captured the complete five-frame interval, but Xcode's CLI
Allocations List was incomplete and did not export transient responsible
callers. Native Statistics totals are retained as context. No responsible
call-site claim or chart is accepted.

## Validation Gates

The evidence generators reject:

- A baseline or candidate object mismatch.
- A candidate that is not the baseline's sole direct child.
- Missing or duplicate measurements.
- Workload, dimension, warm-up or sample-count drift.
- Timing with the counting allocator enabled.
- Any paired output byte or hash mismatch.
- Arithmetic that cannot be recomputed from retained values.
- CPU traces below duration, sample or symbol-resolution gates.
- Native allocation exports that imply complete call-site coverage.

The [reproduction guide][1] separates audit, recomputation and fresh capture.

[1]: REPRODUCTION.md
