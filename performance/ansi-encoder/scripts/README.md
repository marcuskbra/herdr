# ANSI Encoder Script Index

All commands run from the repository root. None fetches, creates a source
branch, changes a remote, commits or pushes. Benchmark runners add and remove
only detached disposable worktrees. Native profiling commands require a private
root outside the repository.

## Public Audit and Charts

- [`validate-public-evidence.py`](validate-public-evidence.py) audits the public
  scope, formats, links, counts, privacy patterns and SHA-256 manifest.
- [`generate-ansi-encoder-charts.py`](generate-ansi-encoder-charts.py)
  regenerates charts 01 to 03 from `results.json` and ordered batches.
- [`generate-ansi-encoder-cpu-charts.py`](generate-ansi-encoder-cpu-charts.py)
  regenerates charts 04 to 07 from sanitized CPU data. Its `extract` and `all`
  modes require private native traces.

Safe audit commands:

```bash
python3 performance/ansi-encoder/scripts/validate-public-evidence.py
python3 performance/ansi-encoder/scripts/generate-ansi-encoder-charts.py generate
python3 \
  performance/ansi-encoder/scripts/generate-ansi-encoder-cpu-charts.py generate
```

Use `HERDR_ANSI_PUBLIC_ROOT` to direct chart output to a temporary copy.

## Benchmark Runners

- [`ansi-encoder-demo.sh`](ansi-encoder-demo.sh) provides comparison,
  interactive animation, virtual race and optional private trace commands. The
  internal `master` and `improved` labels are retained for command
  compatibility, but defaults resolve to the declared baseline and candidate
  commits.
- [`ansi-encoder-evidence.sh`](ansi-encoder-evidence.sh) runs the full validated
  benchmark protocol and writes to `HERDR_ANSI_OUTPUT` or a marked system
  temporary directory.
- [`ansi-encoder-ecdf-rerun.sh`](ansi-encoder-ecdf-rerun.sh) runs the focused
  six-process ordered-batch capture.

These commands build release binaries and are not quick checks. Their output
roots are replaceable only when the expected marker exists.

## Native Profile Runners

These are forensic preservation scripts. They depend on retained private
native traces, exact profiling binaries and Xcode-specific copies from the
recorded investigation. They are not a stable public end-to-end reproduction
path. Every script requires an explicit command or mode; invoking one without a
mode prints usage and performs no private or destructive operation.

- [`ansi-encoder-instruments-pilots.sh`](ansi-encoder-instruments-pilots.sh)
  builds disposable profiling probes and records private Time Profiler or
  Allocations traces with isolated Cargo targets and a minimal launch
  environment.
- [`ansi-encoder-security-retry.sh`](ansi-encoder-security-retry.sh) reproduces
  the failed unsigned attachments, minimal C control and signed-copy retry.
  `get-task-allow` is applied only to disposable copies.
- [`export-ansi-allocations-retry.py`](export-ansi-allocations-retry.py) uses
  the explicit `export` mode to write sanitized allocation tables from private
  signed traces to an external, owned output root.
- [`validate-ansi-allocations-retry.sh`](validate-ansi-allocations-retry.sh)
  uses the explicit `validate` mode to validate private trace lineage, the exact
  disposable-copy entitlement and sanitized allocation totals.

Set the private root before using any native command:

```bash
export HERDR_ANSI_PRIVATE_ROOT="$HOME/herdr-ansi-private"
```

The scripts canonicalize roots before any write, reject symlink traversal, Git
worktrees, repository paths, destructive ancestors and control characters that
cannot survive shell command substitution. Owned-directory sentinels and
immediate revalidation narrow replacement races before writes and removals; the
remaining filesystem race between validation and the kernel operation is
unavoidable with path-based shell interfaces. Native `.trace` bundles, Mach-O
files, dSYMs, symbol archives, control files and raw logs remain under that
private root. Run the bounded path-safety tests with:

```bash
performance/ansi-encoder/scripts/ansi-private-root-safety.sh --self-test
```

## Excluded History Utility

`clean-ansi-encoder-commit.sh` is not included. It was a one-time history
rewrite and personal fork force-push utility, not reproduction tooling. Its
branch and owner defaults were private to that workflow. A generalized version
would still mutate refs and remotes, so the historical copy remains only in the
private archive.
