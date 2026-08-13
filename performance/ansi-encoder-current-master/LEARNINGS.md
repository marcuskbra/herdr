# Current-Master ANSI Encoder Learnings

## Separate Captures Need Separate Claims

The primary benchmark supplied the requested median values. A focused rerun
retained ordered batches for descriptive p95 analysis. The two captures use the
same workloads and replication plan, but their medians are not identical.
Keeping their roles explicit avoids silently mixing statistics from separate
runs.

## The Process Is the Replication Unit

Retaining 2,400 batches makes tail shape auditable. It does not create 2,400
independent experiments. Each group of 100 batches shares one process. Process
medians and process p95 values preserve that structure; a p95 pooled across 300
batches is descriptive only.

## Allocation Counts Explain the Scale of the Change

At 10,000 cells, V1 made 124,651 allocation operations while V3 made 17. The
requested-byte reduction was smaller, from 5,386,440 to 1,048,568, because the
candidate still needs output storage. Operation counts and requested bytes
answer different questions and should be reported together.

Requested bytes are cumulative allocator requests, not retained memory. Calling
them heap use or resident memory would overstate the evidence.

## Stress Throughput Is Supporting Evidence

The 800x600 race amplified the encoder difference to a clear throughput ratio,
but the fixture is deliberately extreme. Its 18.20x ratio supports the
isolated encoder result. It does not predict a normal terminal frame rate or an
overall application speedup.

## A Shared Failure Is Still a Failing Check

The same live-handoff test failed on V1 and V3 while 3,272 other tests passed.
That symmetry argues against a candidate regression. It does not turn the run
into a successful `just check`, so the addendum discloses the failure instead
of claiming a fully green checkpoint.

## Historical Evidence Must Stay Immutable

The existing V0-vs-V2 showcase answers a historical comparison. This addendum
answers the current-master V1-vs-V3 comparison. Reusing old charts with new
labels or replacing the old pack would make the evidence ambiguous. Separate
paths, revision labels and manifests preserve both records.

## Public Evidence Should Be Smaller Than the Private Archive

Raw logs, native traces, binaries and symbol material carry privacy risk while
adding little to arithmetic verification. The public addendum keeps only the
sanitized values needed to recompute claims, deterministic chart generators and
a validator that rejects unsafe artifact classes.
