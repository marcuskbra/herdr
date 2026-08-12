# ANSI Encoder Learnings and Failures

## Process Replication Matters

The first validated benchmark retained process summaries but not ordered batch
vectors. That was enough for the median-of-process-medians result, but not for a
valid distribution chart. The focused rerun retained every batch and preserved
the process boundary. The ECDF now exposes tails without pretending that 300
batches are 300 independent runs.

One baseline process developed long right tails across all four workloads after
a recorded one-minute load average of 12.12. The load value is context, not a
causal explanation. Keeping process lines separate made the noise visible.

## Allocation Totals and Native Events Answer Different Questions

The counting allocator measured calls delegated to `System`: 124,651 baseline
operations and 17 candidate operations for one 10,000-cell encode. Xcode
Allocations applied its own event and persistence model. Its unexpectedly small
baseline transient count cannot replace or invalidate the counting result.

The public report therefore uses the counting allocator for scaling. Native
Statistics remain diagnostic context.

## Unsigned Xcode Attachment Failed

Unsigned Allocations attachment failed for the baseline probe, candidate probe
and an independent minimal C control. The common failure showed that the issue
was not specific to Rust, Herdr or the benchmark workload.

Ad hoc signing worked only after creating disposable copies with exactly the
`get-task-allow` entitlement. Validation confirmed that signing preserved the
`__TEXT,__text` bytes. The original binaries remained unchanged.

The public scripts keep this constraint explicit: native work stays outside the
repository, launch environments are minimized and entitlements apply only to
disposable copies.

## Native Call-Site Export Was Incomplete

The signed traces captured the full five-frame interval and exposed Statistics
and Allocations List surfaces. The list still could not support responsible
call-site attribution:

- It returned 1,074 live rows while Statistics reported 21,113 persistent heap
  allocations.
- Every listed row was live at the end of recording.
- It omitted all 7 baseline and 92 candidate transient allocations.
- 1,072 rows per revision ended at a call-stack limit.
- The CLI exposed no complete allocation call-tree detail node.

Chart 08 was rejected rather than presenting partial live-object callers as
frame attribution. This is a useful failure: an exportable table is not
necessarily a complete measurement surface.

## A Short CPU Pilot Was Rejected

The first candidate Time Profiler pilot had only a 3.999-second active sample
span. It was unsuitable for final cross-trace attribution. The hardened probe
used 14 seconds of post-trigger work plus an eight-second tail. Final captures
passed the duration, sample-count and symbol-resolution gates.

The rejected pilot remains private and appears only as an omitted artifact
class in the manifest.

## Profile Shares Are Not Speedup

Optimizing a function can increase the normalized share of the work that
remains. Candidate samples spread across direct SGR writers and style-key work,
but those larger shares occur within a much shorter encoder operation. The
validated benchmark measures speed. Time Profiler explains the change in work.

Flame widths are independently normalized for the same reason. Comparing width
between the baseline and candidate charts as absolute time would be invalid.

## Extreme Races Need Clear Boundaries

The 800x600 virtual race produced a large throughput ratio, but the frame is
deliberately extreme and baseline round rates varied more than candidate rates.
It is retained as a stress demonstration, not as the headline result and not as
a normal Herdr frame rate.

## Public Curation Must Be Deliberate

Raw logs, native bundles and symbol files can contain usernames, hostnames,
paths, environment values and build metadata. Even technically sanitized build
logs add little beyond the validated JSON and protocol. The public pack keeps
only data that supports recomputation or audit.

`clean-ansi-encoder-commit.sh` is excluded. It belonged to a one-time private
history rewrite and fork push, not benchmark reproduction. Generalizing it
would still introduce branch mutation and force-push behaviour into an evidence
pack. The private archive retains the historical script.

No PNG preview is included because SVG is the accepted public format. No raw
log, native trace, Mach-O file, dSYM, symbol archive, control file or trigger is
included.
