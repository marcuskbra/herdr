# Current-Master ANSI Encoder Methodology

## Fixed Revision Relationship

The measured current-master baseline, V1, is
`49e333ae87a57952fc82ba479a55c35b975ff3cc`. The candidate, V3, is
`90f12051690f46f8d5837b861df14350a6ea4fde`. Git verification established
that V3 has one parent, that the parent is V1 and that V3 is exactly one commit
ahead.

The historical V0-vs-V2 showcase remains a separate immutable comparison.
Neither its latency values nor its revision labels are inputs to this addendum.

## Build Isolation

Both measured revisions used detached disposable worktrees and isolated Cargo
targets. The probes existed only in those worktrees. Builds completed before
cooldowns or measurements began.

Release test binaries were built with the locked dependency graph, Cargo
incremental compilation disabled and one build job. Timing and race binaries
used the production allocator. Allocation measurements alone used a
feature-gated counting allocator that delegates to the system allocator.

## Timing Protocol

Each fresh process ran four deterministic 200x50 workloads:

- Dense colour changes every styled cell.
- Plain scroll changes every unstyled cell.
- Sparse edit changes 16 deterministic cells.
- Full redraw encodes without a previous frame.

Each workload performed 20 warm-ups followed by 100 batches of 10 encodes.
Fixtures and output oracles were prepared outside timed regions. Three
independent processes per revision ran in counterbalanced order:

1. V1, then V3.
2. V3, then V1.
3. V1, then V3.

An exact 30-second cooldown preceded each process. The headline latency is the
median of three process medians. The process is the replication unit.

## Ordered-Batch p95 Protocol

A focused timing-only rerun retained 100 execution-order batches for every
workload in every process. The public JSON and TSV therefore contain:

`2 revisions x 3 processes x 4 workloads x 100 batches = 2,400 values`.

The p95 uses the empirical nearest-rank definition. Each process p95 preserves
the replication structure. The pooled p95 combines 300 batches for one
workload and revision to describe tail shape only. Pooled batches are repeated
within-process observations, not independent replications, and are not used
for inference.

The focused p95 rerun and the primary timing run are separate captures. Median
claims use the primary timing run requested for this comparison. Pooled p95
claims use the ordered-batch rerun.

## Allocation Scaling

The feature-gated counting allocator measured dense styled encodes at 1, 10,
100, 1,000 and 10,000 cells. The geometries were 1x1, 10x1, 100x1, 100x10 and
200x50. Each point followed 20 warm-ups and used 10 measured frames. Counts and
requested bytes had to remain stable across those frames.

Requested bytes sum successful allocator request sizes. They are not retained
memory, heap size or resident set size.

## Virtual Race

The 800x600 stress fixture ran two counterbalanced 10-second rounds in V1/V3,
then V3/V1 order. The encoder checked output length inside the timed loop and
hashed a stable sample outside it. Aggregate FPS divides summed frames by
summed elapsed seconds per revision.

The race measures isolated encoder capacity under a deliberately extreme
fixture. It does not measure a normal terminal frame rate.

## Output Equivalence

Every comparable scope recorded an output byte count and FNV-1a 64-bit hash.
The report generator required V1 and V3 to match across four timing workloads,
five allocation sizes and one race fixture. All 10 scopes matched.

Byte count and hash equality guard against a false speedup caused by skipped
cells, fewer style transitions or truncated output. They do not replace the
candidate's permanent differential tests.

## Supporting Validation

The accepted supporting record includes these bounded conclusions:

- Render scaling found no candidate regression.
- Correctness review found no issue.
- Performance review found no issue.
- One live-handoff test failed the same way on V1 and V3.
- The other 3,272 tests passed.

The shared failure prevents a claim that `just check` passed completely. It
does not indicate a V3-specific failure because it reproduced on the baseline.

## Public Data Boundary

This addendum includes sanitized aggregates, all 2,400 ordered latency values,
deterministic SVG charts and their generators. It excludes raw logs, native
traces, binaries, symbols, build paths, usernames, hostnames, process
identifiers and environment details that do not support the public claims.

The [reproduction guide][1] separates public audit from chart regeneration.

[1]: REPRODUCTION.md
