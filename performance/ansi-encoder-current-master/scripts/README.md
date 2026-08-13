# Current-Master ANSI Encoder Script Index

Both scripts use Python's standard library. They fetch nothing and do not
create branches, change remotes, commit, push or modify source files.

## `validate-public-evidence.py`

The validator audits the complete addendum, recomputes its arithmetic, checks
ordered-value agreement, validates Markdown and SVG structure, verifies the
manifest and rejects sensitive or unsafe content.

```bash
python3 \
  performance/ansi-encoder-current-master/scripts/validate-public-evidence.py
```

Its `--self-test` mode exercises rejection of private paths, identities,
credential patterns, symlinks, hardlinks, native artifacts, binary content and
special files. It also verifies that bare and help invocations write nothing.
The validator fails closed.

## `generate-charts.py`

The generator's explicit `generate` mode writes four deterministic SVG charts
from `data/summary.json`:

```bash
python3 \
  performance/ansi-encoder-current-master/scripts/generate-charts.py \
  generate
```

Set `HERDR_ANSI_CURRENT_MASTER_ROOT` to a temporary copy when verifying
byte-identical regeneration. Bare invocation and `--help` print usage and make
no writes.

Neither script runs Herdr benchmarks. Fresh measurement is outside this
sanitized preservation pack.
