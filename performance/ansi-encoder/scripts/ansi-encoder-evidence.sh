#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Rigorous, disposable evidence runner for the ANSI encoder optimization.
# This script intentionally patches benchmark-only probes into detached
# worktrees. It never changes either revision or the main checkout.

readonly BASELINE_COMMIT=06ca0baa12f4203c5bbad9ecadf53f9a475a52b2
readonly CANDIDATE_COMMIT=d00dc4813d6803ce4efa3e9ad7b1c3533512aaff
readonly COOLDOWN_SECONDS=30
readonly RACE_SECONDS=10
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
readonly RESULTS_DIR="${HERDR_ANSI_OUTPUT:-${TMPDIR:-/tmp}/herdr-ansi-encoder-evidence-results}"
readonly RESULTS_MARKER="$RESULTS_DIR/.ansi-encoder-evidence-results"
readonly WORK_PARENT="${HERDR_ANSI_WORK_PARENT:-$(dirname "$REPO_ROOT")/herdr-worktrees}"
WORK_ROOT=
MASTER_TREE=
CANDIDATE_TREE=
TARGET_DIR=
BIN_DIR=
RAW_DIR=
readonly TEST_TIMING='protocol::render_ansi::tests::ansi_evidence_timing'
readonly TEST_ALLOC='protocol::render_ansi::tests::ansi_evidence_allocation_scaling'
readonly TEST_RACE='protocol::render_ansi::tests::ansi_evidence_race'

MASTER_ADDED=0
CANDIDATE_ADDED=0
INITIAL_STATUS_SHA=
INITIAL_DIFF_SHA=
INITIAL_UNTRACKED_SHA=
INITIAL_REFS_SHA=

usage() {
  cat <<'EOF'
Usage: performance/ansi-encoder/scripts/ansi-encoder-evidence.sh run

Runs the fixed ANSI encoder evidence protocol for exactly:
  baseline:  06ca0baa12f4203c5bbad9ecadf53f9a475a52b2
  candidate: d00dc4813d6803ce4efa3e9ad7b1c3533512aaff

Results are written under HERDR_ANSI_OUTPUT. If unset, the default is:
  ${TMPDIR:-/tmp}/herdr-ansi-encoder-evidence-results

The script creates detached worktrees under the repository's sibling worktree
root, injects test-only probes, builds release test binaries, runs all cooldowns and measurements, validates
byte/hash equivalence and arithmetic, then removes all disposable work.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

sha_stream() {
  shasum -a 256 | awk '{print $1}'
}

checkout_status_sha() {
  git -C "$REPO_ROOT" status --porcelain=v1 -z --untracked-files=all | sha_stream
}

checkout_diff_sha() {
  git -C "$REPO_ROOT" diff --binary HEAD | sha_stream
}

untracked_content_sha() {
  python3 - "$REPO_ROOT" <<'PY' | sha_stream
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
raw = subprocess.check_output(
    ["git", "-C", str(root), "ls-files", "-o", "--exclude-standard", "-z"]
)
for name in sorted(filter(None, raw.decode().split("\0"))):
    path = root / name
    print(name)
    if path.is_file():
        import hashlib
        print(hashlib.sha256(path.read_bytes()).hexdigest())
    else:
        print("non-file")
PY
}

refs_sha() {
  git -C "$REPO_ROOT" show-ref | sha_stream
}

worktree_registered() {
  git -C "$REPO_ROOT" worktree list --porcelain | grep -Fqx "worktree $1"
}

initialize_paths() {
  mkdir -p "$WORK_PARENT"
  WORK_ROOT=$(mktemp -d "$WORK_PARENT/ansi-encoder-evidence.XXXXXX")
  MASTER_TREE="$WORK_ROOT/master"
  CANDIDATE_TREE="$WORK_ROOT/candidate"
  TARGET_DIR="$WORK_ROOT/target"
  BIN_DIR="$WORK_ROOT/bin"
  RAW_DIR="$RESULTS_DIR/raw"
  trap cleanup EXIT INT TERM
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if (( CANDIDATE_ADDED )) && worktree_registered "$CANDIDATE_TREE"; then
    git -C "$REPO_ROOT" worktree remove --force "$CANDIDATE_TREE" >/dev/null 2>&1 || true
  fi
  if (( MASTER_ADDED )) && worktree_registered "$MASTER_TREE"; then
    git -C "$REPO_ROOT" worktree remove --force "$MASTER_TREE" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_ROOT"
  git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
  exit "$rc"
}

verify_refs() {
  local baseline candidate parent count
  baseline=$(git -C "$REPO_ROOT" rev-parse --verify "$BASELINE_COMMIT^{commit}")
  candidate=$(git -C "$REPO_ROOT" rev-parse --verify "$CANDIDATE_COMMIT^{commit}")
  parent=$(git -C "$REPO_ROOT" rev-parse --verify "$CANDIDATE_COMMIT^")
  count=$(git -C "$REPO_ROOT" rev-list --count "$BASELINE_COMMIT..$CANDIDATE_COMMIT")

  [[ "$baseline" == "$BASELINE_COMMIT" ]] || fail "baseline object resolved incorrectly"
  [[ "$candidate" == "$CANDIDATE_COMMIT" ]] || fail "candidate object resolved incorrectly"
  [[ "$parent" == "$BASELINE_COMMIT" ]] ||
    fail "candidate parent is $parent, expected exactly $BASELINE_COMMIT"
  [[ "$count" == 1 ]] || fail "candidate is not exactly one commit ahead of baseline"

  git -C "$REPO_ROOT" merge-base --is-ancestor "$BASELINE_COMMIT" "$CANDIDATE_COMMIT" ||
    fail "baseline is not an ancestor of candidate"
}

prepare_results() {
  if [[ -e "$RESULTS_DIR" ]]; then
    [[ -f "$RESULTS_MARKER" ]] ||
      fail "refusing to replace unrecognized results directory: $RESULTS_DIR"
    rm -rf "$RESULTS_DIR"
  fi
  mkdir -p "$RAW_DIR"
  printf 'fixed ANSI encoder evidence results\n' >"$RESULTS_MARKER"
}

record_environment() {
  python3 - "$RESULTS_DIR/environment.json" <<'PY'
import json
import platform
import subprocess
import sys


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def sysctl(name):
    return output("sysctl", "-n", name)

sw = {}
for line in output("sw_vers").splitlines():
    key, value = line.split(":", 1)
    sw[key.strip()] = value.strip()

env = {
    "cpu_model": sysctl("machdep.cpu.brand_string"),
    "logical_cores": int(sysctl("hw.ncpu")),
    "memory_bytes": int(sysctl("hw.memsize")),
    "memory_gib": round(int(sysctl("hw.memsize")) / 1024**3, 2),
    "macos_product": sw["ProductName"],
    "macos_version": sw["ProductVersion"],
    "macos_build": sw["BuildVersion"],
    "architecture": platform.machine(),
    "rustc_version": output("rustc", "--version"),
    "cargo_version": output("cargo", "--version"),
    "release_profile": {
        "manifest_overrides": "none",
        "cargo_defaults": {
            "opt_level": 3,
            "debug": False,
            "debug_assertions": False,
            "overflow_checks": False,
            "lto": False,
            "panic": "unwind",
            "incremental": False,
            "codegen_units": 16,
        },
    },
    "timing_allocator": "Rust production default (System on this target); allocation-counting feature disabled",
    "allocation_allocator": "feature-gated test counting allocator delegating to System",
}
with open(sys.argv[1], "w") as f:
    json.dump(env, f, indent=2)
    f.write("\n")
PY
}

write_protocol() {
  cat >"$RESULTS_DIR/protocol.md" <<EOF
# Commands and Protocol

## Fixed Revisions

- Baseline: \`$BASELINE_COMMIT\`.
- Candidate: \`$CANDIDATE_COMMIT\` (must have baseline as its sole first parent
  and be exactly one commit ahead).

No fetch, branch creation, commit, amend, remote write, push, PR or post command
is used. Both sources are detached disposable worktrees under the repository's
sibling worktree root. Benchmark-only files and probes exist only there and are
removed on exit. Raw build logs replace absolute home/work/repository paths with
\`<HOME>\`, \`<WORK_ROOT>\`, and \`<REPO_ROOT>\`.

## Build

Both revisions use \`cargo test --release --locked --bin herdr --no-run\` with
\`CARGO_INCREMENTAL=0\`, \`CARGO_BUILD_JOBS=1\`, and profiling/Rust flag
environment removed. Timing/race binaries have no features (production
allocator). Allocation binaries alone use \`--features
test-allocation-counting\`. Builds complete before any cooldown or timed run.

## Timing

All four exact 200x50 workloads run in each independent release test process:
\`dense_colour\`, \`plain_scroll\`, \`sparse_edit\` (16 deterministic edits),
and \`full_redraw\`. Each workload uses 20 warm-up frames followed by 100
samples of 10 encodes. Fixtures and oracle bytes/hashes are constructed outside
timed regions. Every process reports sample minimum, median, maximum, output
byte count and FNV-1a 64-bit hash.

Three independent processes per revision run in counterbalanced order:

1. baseline, candidate
2. candidate, baseline
3. baseline, candidate

Immediately before every process, the runner sleeps exactly 30 seconds, then
records the 1/5/15-minute load averages, then launches the already-built test
binary. The effective invocation is:

\`env -u HERDR_RENDER_PROF ... <production-release-test-binary> $TEST_TIMING --ignored --exact --nocapture --test-threads=1\`

## Allocation Scaling

After a separate 30-second cooldown immediately before each revision's suite,
the feature-gated release binary measures deterministic dense styled encodes at
1, 10, 100, 1,000 and 10,000 cells (geometries 1x1, 10x1, 100x1, 100x10 and
200x50). Each point uses 20 warm-ups and 10 measured frames; allocation count
and requested bytes must be stable across those frames. Output bytes and hashes
are recorded and compared.

## 800x600 Race

Two 10-second counterbalanced rounds run baseline/candidate then
candidate/baseline. Every side is a fresh production-allocator release process
with a 30-second cooldown and load recording immediately before it. Each side
uses two untimed warm-ups, then encodes until the 10-second deadline. Sample
output byte count and hash are verified outside the loop; byte count and redraw
classification are checked inside. Aggregation sums frames and actual elapsed
seconds, giving approximately 20 seconds per revision.

## Validation

The report generator refuses missing/duplicate measurements, dimension or
protocol drift, any comparable output byte/hash mismatch, non-production timing
binaries, arithmetic inconsistencies, or unexpected process counts. It writes
\`results.json\`, recomputes every reported percentage/speedup, and records
checkout and ref hashes before and after the run. Main-checkout status, tracked
diff, pre-existing untracked contents, and refs must remain byte-for-byte
unchanged.
EOF
}

probe_source() {
  cat <<'RUST'

    // HERDR ANSI ENCODER EVIDENCE PROBES (disposable worktrees only)
    const EVIDENCE_WIDTH: u16 = 200;
    const EVIDENCE_HEIGHT: u16 = 50;
    const EVIDENCE_CELLS: usize = EVIDENCE_WIDTH as usize * EVIDENCE_HEIGHT as usize;
    const EVIDENCE_WARMUPS: usize = 20;
    const EVIDENCE_FRAMES_PER_SAMPLE: usize = 10;
    const EVIDENCE_SAMPLES: usize = 100;

    struct EvidenceWorkload {
        name: &'static str,
        previous: Option<FrameData>,
        current: FrameData,
        expected_full: bool,
    }

    fn evidence_hash(bytes: &[u8]) -> u64 {
        bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
            (hash ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3)
        })
    }

    fn evidence_colour(index: usize) -> u32 {
        match index % 3 {
            0 => 1 + ((index / 3) % 16) as u32,
            1 => 0x01_00_00_00 | ((index * 37) % 256) as u32,
            _ => {
                let red = ((index * 17) % 256) as u32;
                let green = ((index * 43) % 256) as u32;
                let blue = ((index * 97) % 256) as u32;
                0x02_00_00_00 | (red << 16) | (green << 8) | blue
            }
        }
    }

    fn evidence_modifier(index: usize) -> u16 {
        use ratatui::style::Modifier;
        let (modifier, underline_style) = match index % 8 {
            0 => (Modifier::empty(), 0),
            1 => (Modifier::BOLD, 0),
            2 => (Modifier::DIM | Modifier::ITALIC, 0),
            3 => (Modifier::UNDERLINED, 1),
            4 => (Modifier::BOLD | Modifier::UNDERLINED, 2),
            5 => (Modifier::ITALIC | Modifier::UNDERLINED, 3),
            6 => (Modifier::DIM | Modifier::UNDERLINED, 4),
            _ => (Modifier::BOLD | Modifier::ITALIC | Modifier::UNDERLINED, 5),
        };
        crate::protocol::modifier_to_u16(crate::protocol::modifier_with_underline_style(
            modifier,
            underline_style,
        ))
    }

    fn evidence_dense_frame(width: u16, height: u16, generation: usize) -> FrameData {
        let cells = (0..usize::from(width) * usize::from(height))
            .map(|index| {
                let symbol = char::from(b'!' + ((index + generation) % 94) as u8).to_string();
                make_cell(
                    &symbol,
                    evidence_colour(index + generation),
                    evidence_colour(index * 5 + generation + 1),
                    evidence_modifier(index + generation),
                )
            })
            .collect();
        make_frame(width, height, cells)
    }

    fn evidence_plain_frame(row_offset: usize) -> FrameData {
        let cells = (0..EVIDENCE_CELLS)
            .map(|index| {
                let row = index / usize::from(EVIDENCE_WIDTH);
                let col = index % usize::from(EVIDENCE_WIDTH);
                let symbol =
                    char::from(b'A' + ((row + row_offset + col * 7) % 26) as u8).to_string();
                make_cell(&symbol, 0, 0, 0)
            })
            .collect();
        make_frame(EVIDENCE_WIDTH, EVIDENCE_HEIGHT, cells)
    }

    fn evidence_sparse_frame() -> FrameData {
        let cells = (0..EVIDENCE_CELLS)
            .map(|index| {
                let symbol = char::from(b'a' + (index % 26) as u8).to_string();
                make_cell(&symbol, 0, 0, 0)
            })
            .collect();
        make_frame(EVIDENCE_WIDTH, EVIDENCE_HEIGHT, cells)
    }

    fn evidence_workloads() -> [EvidenceWorkload; 4] {
        let dense_previous = evidence_dense_frame(EVIDENCE_WIDTH, EVIDENCE_HEIGHT, 0);
        let dense_current = evidence_dense_frame(EVIDENCE_WIDTH, EVIDENCE_HEIGHT, 1);
        assert!(dense_previous
            .cells
            .iter()
            .zip(&dense_current.cells)
            .all(|(previous, current)| previous != current));

        let plain_previous = evidence_plain_frame(0);
        let plain_current = evidence_plain_frame(1);
        assert!(plain_previous
            .cells
            .iter()
            .zip(&plain_current.cells)
            .all(|(previous, current)| previous != current));

        let sparse_previous = evidence_sparse_frame();
        let mut sparse_current = sparse_previous.clone();
        for edit in 0..16 {
            let index = (edit * 613 + 97) % EVIDENCE_CELLS;
            sparse_current.cells[index] = make_cell("#", 0, 0, 0);
        }
        assert_eq!(
            sparse_previous
                .cells
                .iter()
                .zip(&sparse_current.cells)
                .filter(|(previous, current)| previous != current)
                .count(),
            16
        );

        [
            EvidenceWorkload {
                name: "dense_colour",
                previous: Some(dense_previous),
                current: dense_current,
                expected_full: false,
            },
            EvidenceWorkload {
                name: "plain_scroll",
                previous: Some(plain_previous),
                current: plain_current,
                expected_full: false,
            },
            EvidenceWorkload {
                name: "sparse_edit",
                previous: Some(sparse_previous),
                current: sparse_current,
                expected_full: false,
            },
            EvidenceWorkload {
                name: "full_redraw",
                previous: None,
                current: evidence_plain_frame(3),
                expected_full: true,
            },
        ]
    }

    fn evidence_encoder(previous: Option<&FrameData>) -> BlitEncoder {
        let mut encoder = BlitEncoder::new();
        if let Some(previous) = previous {
            let encoded = encoder.encode(previous, false);
            encoder.commit(previous.clone(), encoded);
        }
        encoder
    }

    fn evidence_oracle(workload: &EvidenceWorkload, encoder: &BlitEncoder) -> (usize, u64) {
        let first = encoder.encode(&workload.current, false);
        let second = encoder.encode(&workload.current, false);
        assert_eq!(first.full, workload.expected_full);
        assert_eq!(second.full, workload.expected_full);
        assert_eq!(first.bytes, second.bytes, "{} repeated oracle", workload.name);
        assert!(!first.bytes.is_empty());
        (first.bytes.len(), evidence_hash(&first.bytes))
    }

    #[test]
    #[ignore = "manual release timing evidence"]
    fn ansi_evidence_timing() {
        assert!(!cfg!(debug_assertions), "requires --release");
        assert!(
            !cfg!(feature = "test-allocation-counting"),
            "timing must use the production allocator"
        );
        assert!(!crate::render_prof::enabled(), "HERDR_RENDER_PROF must be disabled");

        let workloads = evidence_workloads();
        for workload in &workloads {
            assert_eq!((workload.current.width, workload.current.height), (200, 50));
            assert_eq!(workload.current.cells.len(), 10_000);
            let encoder = evidence_encoder(workload.previous.as_ref());
            let (output_bytes, output_hash) = evidence_oracle(workload, &encoder);

            for _ in 0..EVIDENCE_WARMUPS {
                let encoded = std::hint::black_box(
                    encoder.encode(std::hint::black_box(&workload.current), false),
                );
                assert_eq!(encoded.full, workload.expected_full);
                assert_eq!(encoded.bytes.len(), output_bytes);
                drop(encoded);
            }

            let mut samples = Vec::with_capacity(EVIDENCE_SAMPLES);
            for _ in 0..EVIDENCE_SAMPLES {
                let started = std::time::Instant::now();
                for _ in 0..EVIDENCE_FRAMES_PER_SAMPLE {
                    let encoded = std::hint::black_box(
                        encoder.encode(std::hint::black_box(&workload.current), false),
                    );
                    assert_eq!(encoded.full, workload.expected_full);
                    assert_eq!(encoded.bytes.len(), output_bytes);
                    std::hint::black_box(&encoded.bytes);
                    drop(encoded);
                }
                samples.push(
                    started.elapsed().as_nanos() / EVIDENCE_FRAMES_PER_SAMPLE as u128,
                );
            }
            samples.sort_unstable();
            println!(
                concat!(
                    "EVIDENCE_TIMING workload={} width=200 height=50 warmups={} ",
                    "frames_per_sample={} samples={} min_ns={} median_ns={} max_ns={} ",
                    "output_bytes={} output_hash={:016x} full={} counting_allocator=false"
                ),
                workload.name,
                EVIDENCE_WARMUPS,
                EVIDENCE_FRAMES_PER_SAMPLE,
                EVIDENCE_SAMPLES,
                samples[0],
                samples[samples.len() / 2],
                samples[samples.len() - 1],
                output_bytes,
                output_hash,
                workload.expected_full,
            );
        }
    }

    #[cfg(feature = "test-allocation-counting")]
    #[test]
    #[ignore = "manual release allocation scaling evidence"]
    fn ansi_evidence_allocation_scaling() {
        assert!(!cfg!(debug_assertions), "requires --release");
        assert!(!crate::render_prof::enabled(), "HERDR_RENDER_PROF must be disabled");

        for (width, height) in [(1, 1), (10, 1), (100, 1), (100, 10), (200, 50)] {
            let previous = evidence_dense_frame(width, height, 0);
            let current = evidence_dense_frame(width, height, 1);
            let encoder = evidence_encoder(Some(&previous));
            let workload = EvidenceWorkload {
                name: "allocation_dense",
                previous: Some(previous),
                current,
                expected_full: false,
            };
            let (output_bytes, output_hash) = evidence_oracle(&workload, &encoder);

            for _ in 0..EVIDENCE_WARMUPS {
                let encoded = encoder.encode(&workload.current, false);
                assert_eq!(encoded.bytes.len(), output_bytes);
                drop(encoded);
            }

            let mut expected = None;
            for _ in 0..10 {
                let (encoded, stats) = crate::test_alloc::measure(|| {
                    std::hint::black_box(
                        encoder.encode(std::hint::black_box(&workload.current), false),
                    )
                });
                assert_eq!(encoded.full, false);
                assert_eq!(encoded.bytes.len(), output_bytes);
                if let Some(prior) = expected {
                    assert_eq!(stats, prior, "allocation statistics must be stable");
                } else {
                    expected = Some(stats);
                }
                drop(encoded);
            }
            let stats = expected.expect("ten allocation measurements");
            println!(
                concat!(
                    "EVIDENCE_ALLOCATION width={} height={} cells={} warmups={} measured_frames=10 ",
                    "allocations={} requested_bytes={} output_bytes={} output_hash={:016x} ",
                    "counting_allocator=true"
                ),
                width,
                height,
                usize::from(width) * usize::from(height),
                EVIDENCE_WARMUPS,
                stats.allocations,
                stats.requested_bytes,
                output_bytes,
                output_hash,
            );
        }
    }

    #[test]
    #[ignore = "manual 800x600 release race evidence"]
    fn ansi_evidence_race() {
        assert!(!cfg!(debug_assertions), "requires --release");
        assert!(
            !cfg!(feature = "test-allocation-counting"),
            "race must use the production allocator"
        );
        assert!(!crate::render_prof::enabled(), "HERDR_RENDER_PROF must be disabled");
        let seconds: u64 = std::env::var("HERDR_EVIDENCE_RACE_SECONDS")
            .expect("runner sets race seconds")
            .parse()
            .expect("race seconds is an integer");
        assert_eq!(seconds, 10, "evidence protocol requires exactly 10 seconds");

        let width = 800;
        let height = 600;
        let previous = evidence_dense_frame(width, height, 0);
        let current = evidence_dense_frame(width, height, 1);
        let encoder = evidence_encoder(Some(&previous));
        let sample = encoder.encode(&current, false);
        assert!(!sample.full);
        let output_bytes = sample.bytes.len();
        let output_hash = evidence_hash(&sample.bytes);
        let repeated = encoder.encode(&current, false);
        assert_eq!(sample.bytes, repeated.bytes, "race oracle stability");
        drop(sample);
        drop(repeated);

        for _ in 0..2 {
            let encoded = encoder.encode(&current, false);
            assert!(!encoded.full);
            assert_eq!(encoded.bytes.len(), output_bytes);
            drop(encoded);
        }

        let started = std::time::Instant::now();
        let deadline = started + std::time::Duration::from_secs(seconds);
        let mut frames = 0usize;
        while std::time::Instant::now() < deadline {
            let encoded = std::hint::black_box(
                encoder.encode(std::hint::black_box(&current), false),
            );
            assert!(!encoded.full);
            assert_eq!(encoded.bytes.len(), output_bytes);
            std::hint::black_box(&encoded.bytes);
            drop(encoded);
            frames += 1;
        }
        let elapsed = started.elapsed().as_secs_f64();
        println!(
            concat!(
                "EVIDENCE_RACE width={} height={} cells={} requested_seconds={} elapsed_seconds={:.9} ",
                "frames={} fps={:.6} output_bytes={} output_hash={:016x} ",
                "warmups=2 counting_allocator=false"
            ),
            width,
            height,
            usize::from(width) * usize::from(height),
            seconds,
            elapsed,
            frames,
            frames as f64 / elapsed,
            output_bytes,
            output_hash,
        );
    }
RUST
}

instrument_tree() {
  local tree=$1
  local probe="$tree/.ansi-evidence-probe.rs"

  # Both revisions receive the exact same feature-gated allocator implementation.
  git -C "$REPO_ROOT" show "$CANDIDATE_COMMIT:src/test_alloc.rs" >"$tree/src/test_alloc.rs"

  python3 - "$tree" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
cargo = root / "Cargo.toml"
text = cargo.read_text()
if "test-allocation-counting = []" not in text:
    text = text.replace(
        "[dependencies]\n",
        "[features]\n"
        "# Test-only allocator instrumentation. Never enable for timing benchmarks.\n"
        "test-allocation-counting = []\n\n"
        "[dependencies]\n",
        1,
    )
    cargo.write_text(text)

main = root / "src/main.rs"
text = main.read_text()
if "mod test_alloc;" not in text:
    text = text.replace(
        "mod terminal_theme;\n",
        "mod terminal_theme;\n"
        "#[cfg(all(test, feature = \"test-allocation-counting\"))]\n"
        "mod test_alloc;\n",
        1,
    )
    main.write_text(text)
PY

  probe_source >"$probe"
  python3 - "$tree" "$probe" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
probe = Path(sys.argv[2]).read_text()
render = root / "src/protocol/render_ansi.rs"
text = render.read_text()
marker = "HERDR ANSI ENCODER EVIDENCE PROBES"
if marker in text:
    raise SystemExit("evidence marker unexpectedly already present")
index = text.rfind("}")
if index < 0:
    raise SystemExit("could not locate test module closing brace")
render.write_text(text[:index] + probe + "\n" + text[index:])
PY
  rm "$probe"
}

create_worktrees() {
  git -C "$REPO_ROOT" worktree add --quiet --detach "$MASTER_TREE" "$BASELINE_COMMIT"
  MASTER_ADDED=1
  git -C "$REPO_ROOT" worktree add --quiet --detach "$CANDIDATE_TREE" "$CANDIDATE_COMMIT"
  CANDIDATE_ADDED=1
  instrument_tree "$MASTER_TREE"
  instrument_tree "$CANDIDATE_TREE"

  {
    printf 'baseline_commit=%s\n' "$BASELINE_COMMIT"
    printf 'candidate_commit=%s\n' "$CANDIDATE_COMMIT"
    printf 'candidate_parent=%s\n' "$(git -C "$REPO_ROOT" rev-parse "$CANDIDATE_COMMIT^")"
    printf 'ahead_count=%s\n' "$(git -C "$REPO_ROOT" rev-list --count "$BASELINE_COMMIT..$CANDIDATE_COMMIT")"
    printf 'probe_sha256=%s\n' "$(probe_source | sha_stream)"
  } >"$RESULTS_DIR/refs.txt"
}

build_binary() {
  local revision=$1 tree=$2 feature=$3 destination=$4 json_log=$5 stderr_log=$6
  local -a args=(test --release --locked --bin herdr --no-run --message-format=json)
  if [[ -n "$feature" ]]; then
    args+=(--features "$feature")
  fi
  (
    cd "$tree"
    # Separate revision targets prevent Cargo from reusing the package artifact
    # across detached worktrees that share package identity and close mtimes.
    env -u HERDR_RENDER_PROF -u RUSTFLAGS -u CARGO_PROFILE_RELEASE_DEBUG \
      CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=1 CARGO_TARGET_DIR="$TARGET_DIR/$revision" \
      cargo "${args[@]}"
  ) >"$json_log" 2>"$stderr_log"

  local executable
  executable=$(python3 - "$json_log" <<'PY'
import json
import sys

found = []
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    target = event.get("target", {})
    profile = event.get("profile", {})
    if target.get("name") == "herdr" and profile.get("test") and event.get("executable"):
        found.append(event["executable"])
if not found:
    raise SystemExit("could not find Herdr test executable")
print(found[-1])
PY
)
  mkdir -p "$BIN_DIR"
  cp "$executable" "$destination"
  chmod 755 "$destination"
  python3 - "$json_log" "$stderr_log" "$HOME" "$WORK_ROOT" "$REPO_ROOT" <<'PY'
from pathlib import Path
import sys

json_log, stderr_log, home, work_root, repo_root = sys.argv[1:]
for name in [json_log, stderr_log]:
    path = Path(name)
    text = path.read_text()
    # Longest/specific paths first; retained logs must not disclose user names.
    for value, replacement in [
        (work_root, "<WORK_ROOT>"),
        (repo_root, "<REPO_ROOT>"),
        (home, "<HOME>"),
    ]:
        text = text.replace(value, replacement)
    path.write_text(text)
PY
  printf '%s\t%s\t%s\n' "$revision" "${feature:-production}" "$(shasum -a 256 "$destination" | awk '{print $1}')" >>"$RESULTS_DIR/binaries.tsv"
}

build_all() {
  printf 'revision\tallocator_build\tsha256\n' >"$RESULTS_DIR/binaries.tsv"
  build_binary master "$MASTER_TREE" '' "$BIN_DIR/master-production" \
    "$RAW_DIR/build-master-production.jsonl" "$RAW_DIR/build-master-production.stderr.log"
  build_binary candidate "$CANDIDATE_TREE" '' "$BIN_DIR/candidate-production" \
    "$RAW_DIR/build-candidate-production.jsonl" "$RAW_DIR/build-candidate-production.stderr.log"
  build_binary master "$MASTER_TREE" test-allocation-counting "$BIN_DIR/master-allocation" \
    "$RAW_DIR/build-master-allocation.jsonl" "$RAW_DIR/build-master-allocation.stderr.log"
  build_binary candidate "$CANDIDATE_TREE" test-allocation-counting "$BIN_DIR/candidate-allocation" \
    "$RAW_DIR/build-candidate-allocation.jsonl" "$RAW_DIR/build-candidate-allocation.stderr.log"

  if cmp -s "$BIN_DIR/master-production" "$BIN_DIR/candidate-production"; then
    fail "revision production binaries are unexpectedly identical"
  fi
  if cmp -s "$BIN_DIR/master-allocation" "$BIN_DIR/candidate-allocation"; then
    fail "revision allocation binaries are unexpectedly identical"
  fi
}

record_load() {
  local phase=$1 key=$2
  local raw
  raw=$(sysctl -n vm.loadavg)
  python3 - "$RESULTS_DIR/loads.tsv" "$phase" "$key" "$raw" <<'PY'
from datetime import datetime, timezone
import re
import sys

path, phase, key, raw = sys.argv[1:]
values = re.findall(r"[0-9]+(?:\.[0-9]+)?", raw)
if len(values) != 3:
    raise SystemExit(f"unexpected vm.loadavg: {raw!r}")
with open(path, "a") as f:
    f.write("\t".join([
        datetime.now(timezone.utc).isoformat(), phase, key, *values
    ]) + "\n")
PY
}

cooldown_and_run() {
  local phase=$1 key=$2 binary=$3 test_name=$4 log=$5
  printf 'cooldown phase=%s key=%s seconds=%s\n' "$phase" "$key" "$COOLDOWN_SECONDS"
  sleep "$COOLDOWN_SECONDS"
  record_load "$phase" "$key"
  env -u HERDR_RENDER_PROF -u RUSTFLAGS -u CARGO_PROFILE_RELEASE_DEBUG \
    -u MallocStackLogging -u MallocStackLoggingNoCompact \
    "$binary" "$test_name" --ignored --exact --nocapture --test-threads=1 >"$log" 2>&1
}

run_timing() {
  local round position revision binary key log
  local -a order=(master candidate candidate master master candidate)
  for index in "${!order[@]}"; do
    round=$((index / 2 + 1))
    position=$((index % 2 + 1))
    revision=${order[$index]}
    binary="$BIN_DIR/$revision-production"
    key="round${round}-side${position}-${revision}"
    log="$RAW_DIR/timing-$key.log"
    cooldown_and_run timing "$key" "$binary" "$TEST_TIMING" "$log"
  done
}

run_allocation() {
  local revision key log
  for revision in master candidate; do
    key="suite-${revision}"
    log="$RAW_DIR/allocation-$revision.log"
    cooldown_and_run allocation "$key" "$BIN_DIR/$revision-allocation" "$TEST_ALLOC" "$log"
  done
}

run_race() {
  local round position revision key log
  local -a order=(master candidate candidate master)
  for index in "${!order[@]}"; do
    round=$((index / 2 + 1))
    position=$((index % 2 + 1))
    revision=${order[$index]}
    key="round${round}-side${position}-${revision}"
    log="$RAW_DIR/race-$key.log"
    printf 'cooldown phase=race key=%s seconds=%s\n' "$key" "$COOLDOWN_SECONDS"
    sleep "$COOLDOWN_SECONDS"
    record_load race "$key"
    env -u HERDR_RENDER_PROF -u RUSTFLAGS -u CARGO_PROFILE_RELEASE_DEBUG \
      -u MallocStackLogging -u MallocStackLoggingNoCompact \
      HERDR_EVIDENCE_RACE_SECONDS="$RACE_SECONDS" \
      "$BIN_DIR/$revision-production" "$TEST_RACE" \
      --ignored --exact --nocapture --test-threads=1 >"$log" 2>&1
  done
}

generate_results() {
  python3 - "$RESULTS_DIR" <<'PY'
from collections import defaultdict
from pathlib import Path
import json
import math
import re
import statistics
import sys

root = Path(sys.argv[1])
raw = root / "raw"
workloads = ["dense_colour", "plain_scroll", "sparse_edit", "full_redraw"]

def fields(line):
    return dict(re.findall(r"([a-z_]+)=([^ ]+)", line))

def integer(data, key):
    return int(data[key])

def floating(data, key):
    return float(data[key])

# Three process pairs with the required counterbalancing.
timing_specs = [
    (1, 1, "master"), (1, 2, "candidate"),
    (2, 1, "candidate"), (2, 2, "master"),
    (3, 1, "master"), (3, 2, "candidate"),
]
timing = []
for round_no, side, revision in timing_specs:
    path = raw / f"timing-round{round_no}-side{side}-{revision}.log"
    matches = [
        fields(line.split("EVIDENCE_TIMING ", 1)[1])
        for line in path.read_text().splitlines()
        if "EVIDENCE_TIMING " in line
    ]
    if len(matches) != 4:
        raise SystemExit(f"{path.name}: expected four timing records, got {len(matches)}")
    if [m["workload"] for m in matches] != workloads:
        raise SystemExit(f"{path.name}: workload order drift")
    for data in matches:
        if (integer(data, "width"), integer(data, "height")) != (200, 50):
            raise SystemExit("timing dimensions drifted")
        if (integer(data, "warmups"), integer(data, "frames_per_sample"), integer(data, "samples")) != (20, 10, 100):
            raise SystemExit("timing sample protocol drifted")
        if data["counting_allocator"] != "false":
            raise SystemExit("timing used counting allocator")
        if not (integer(data, "min_ns") <= integer(data, "median_ns") <= integer(data, "max_ns")):
            raise SystemExit("invalid timing range")
        timing.append({
            "round": round_no, "side": side, "revision": revision,
            "workload": data["workload"],
            "min_ns": integer(data, "min_ns"),
            "median_ns": integer(data, "median_ns"),
            "max_ns": integer(data, "max_ns"),
            "output_bytes": integer(data, "output_bytes"),
            "output_hash": data["output_hash"],
            "full": data["full"] == "true",
        })

# Output equivalence across all timing processes and revisions.
equivalence = []
for workload in workloads:
    rows = [r for r in timing if r["workload"] == workload]
    outputs = {(r["output_bytes"], r["output_hash"], r["full"]) for r in rows}
    if len(outputs) != 1:
        raise SystemExit(f"timing output mismatch for {workload}: {outputs}")
    output_bytes, output_hash, full = outputs.pop()
    equivalence.append({
        "scope": f"timing:{workload}", "output_bytes": output_bytes,
        "output_hash": output_hash, "full": full, "matching": True,
    })

aggregates = []
for workload in workloads:
    per_revision = {}
    for revision in ["master", "candidate"]:
        values = [r["median_ns"] for r in timing if r["workload"] == workload and r["revision"] == revision]
        if len(values) != 3:
            raise SystemExit("expected three process medians")
        per_revision[revision] = {
            "process_medians_ns": values,
            "median_of_process_medians_ns": int(statistics.median(values)),
        }
    master = per_revision["master"]["median_of_process_medians_ns"]
    candidate = per_revision["candidate"]["median_of_process_medians_ns"]
    aggregates.append({
        "workload": workload,
        "master": per_revision["master"],
        "candidate": per_revision["candidate"],
        "time_reduction_percent": (master - candidate) / master * 100,
        "speedup": master / candidate,
    })

allocation = []
for revision in ["master", "candidate"]:
    path = raw / f"allocation-{revision}.log"
    matches = [
        fields(line.split("EVIDENCE_ALLOCATION ", 1)[1])
        for line in path.read_text().splitlines()
        if "EVIDENCE_ALLOCATION " in line
    ]
    if len(matches) != 5:
        raise SystemExit(f"{path.name}: expected five allocation records")
    for data in matches:
        if (integer(data, "warmups"), integer(data, "measured_frames")) != (20, 10):
            raise SystemExit("allocation protocol drifted")
        if data["counting_allocator"] != "true":
            raise SystemExit("allocation suite did not use counting allocator")
        allocation.append({
            "revision": revision,
            "width": integer(data, "width"), "height": integer(data, "height"),
            "cells": integer(data, "cells"), "allocations": integer(data, "allocations"),
            "requested_bytes": integer(data, "requested_bytes"),
            "output_bytes": integer(data, "output_bytes"), "output_hash": data["output_hash"],
        })
if sorted({r["cells"] for r in allocation}) != [1, 10, 100, 1000, 10000]:
    raise SystemExit("allocation scaling cells drifted")
for cells in [1, 10, 100, 1000, 10000]:
    rows = [r for r in allocation if r["cells"] == cells]
    if len(rows) != 2 or len({(r["output_bytes"], r["output_hash"]) for r in rows}) != 1:
        raise SystemExit(f"allocation output mismatch at {cells} cells")
    equivalence.append({
        "scope": f"allocation:{cells}", "output_bytes": rows[0]["output_bytes"],
        "output_hash": rows[0]["output_hash"], "matching": True,
    })

race_specs = [(1, 1, "master"), (1, 2, "candidate"), (2, 1, "candidate"), (2, 2, "master")]
race = []
for round_no, side, revision in race_specs:
    path = raw / f"race-round{round_no}-side{side}-{revision}.log"
    matches = [
        fields(line.split("EVIDENCE_RACE ", 1)[1])
        for line in path.read_text().splitlines()
        if "EVIDENCE_RACE " in line
    ]
    if len(matches) != 1:
        raise SystemExit(f"{path.name}: expected one race record")
    data = matches[0]
    if (integer(data, "width"), integer(data, "height"), integer(data, "cells")) != (800, 600, 480000):
        raise SystemExit("race dimensions drifted")
    if integer(data, "requested_seconds") != 10 or integer(data, "warmups") != 2:
        raise SystemExit("race protocol drifted")
    if data["counting_allocator"] != "false":
        raise SystemExit("race used counting allocator")
    elapsed = floating(data, "elapsed_seconds")
    frames = integer(data, "frames")
    fps = floating(data, "fps")
    if not math.isclose(fps, frames / elapsed, rel_tol=2e-6):
        raise SystemExit("race fps arithmetic mismatch")
    race.append({
        "round": round_no, "side": side, "revision": revision,
        "elapsed_seconds": elapsed, "frames": frames, "fps": fps,
        "output_bytes": integer(data, "output_bytes"), "output_hash": data["output_hash"],
    })
if len({(r["output_bytes"], r["output_hash"]) for r in race}) != 1:
    raise SystemExit("race output mismatch")
equivalence.append({
    "scope": "race:800x600", "output_bytes": race[0]["output_bytes"],
    "output_hash": race[0]["output_hash"], "matching": True,
})
race_aggregate = {}
for revision in ["master", "candidate"]:
    rows = [r for r in race if r["revision"] == revision]
    elapsed = sum(r["elapsed_seconds"] for r in rows)
    frames = sum(r["frames"] for r in rows)
    fps = frames / elapsed
    round_fps = [r["fps"] for r in rows]
    race_aggregate[revision] = {
        "elapsed_seconds": elapsed, "frames": frames, "fps": fps,
        "round_fps": round_fps,
        "round_fps_range": max(round_fps) - min(round_fps),
        "round_fps_relative_spread_percent": (max(round_fps) - min(round_fps)) / statistics.mean(round_fps) * 100,
    }
race_speedup = race_aggregate["candidate"]["fps"] / race_aggregate["master"]["fps"]

loads = []
lines = (root / "loads.tsv").read_text().splitlines()
if lines[0] != "utc\tphase\tkey\tload_1m\tload_5m\tload_15m":
    raise SystemExit("load header mismatch")
for line in lines[1:]:
    utc, phase, key, one, five, fifteen = line.split("\t")
    loads.append({"utc": utc, "phase": phase, "key": key, "load_1m": float(one), "load_5m": float(five), "load_15m": float(fifteen)})
if len(loads) != 12:
    raise SystemExit(f"expected 12 pre-process load records, got {len(loads)}")

result = {
    "schema_version": 1,
    "revisions": {
        "master": "06ca0baa12f4203c5bbad9ecadf53f9a475a52b2",
        "candidate": "d00dc4813d6803ce4efa3e9ad7b1c3533512aaff",
    },
    "protocol": {
        "cooldown_seconds_before_every_process": 30,
        "timing_processes_per_revision": 3,
        "timing_order": ["master/candidate", "candidate/master", "master/candidate"],
        "timing_warmups": 20, "timing_samples": 100, "frames_per_sample": 10,
        "allocation_scaling_cells": [1, 10, 100, 1000, 10000],
        "allocation_warmups": 20, "allocation_measured_frames": 10,
        "race_dimensions": [800, 600], "race_round_seconds": 10,
        "race_order": ["master/candidate", "candidate/master"],
    },
    "timing_processes": timing,
    "timing_aggregates": aggregates,
    "allocation_scaling": allocation,
    "race_rounds": race,
    "race_aggregate": race_aggregate,
    "race_speedup": race_speedup,
    "equivalence": equivalence,
    "pre_process_loads": loads,
    "environment": json.loads((root / "environment.json").read_text()),
    "validation": {
        "all_comparable_outputs_match": all(x["matching"] for x in equivalence),
        "timing_arithmetic_recomputed": True,
        "race_arithmetic_recomputed": True,
        "expected_process_and_sample_counts": True,
    },
}
(root / "results.json").write_text(json.dumps(result, indent=2) + "\n")

fmt_ns = lambda n: f"{n:,}"
lines = [
    "# ANSI Encoder Evidence: Direct Candidate vs Current Master", "",
    f"Baseline: `{result['revisions']['master']}`.  ",
    f"Candidate: `{result['revisions']['candidate']}` (exactly one commit ahead).", "",
    "## Result", "",
    "All comparable byte counts and FNV-1a hashes matched. Timing uses release",
    "binaries with the production allocator; allocation counts use a separate,",
    "feature-gated release binary.", "",
    "| Workload (200x50) | Master median of process medians | Candidate median of process medians | Time reduction | Speedup |",
    "|---|---:|---:|---:|---:|",
]
for a in aggregates:
    lines.append(f"| {a['workload']} | {fmt_ns(a['master']['median_of_process_medians_ns'])} ns | {fmt_ns(a['candidate']['median_of_process_medians_ns'])} ns | {a['time_reduction_percent']:.2f}% | {a['speedup']:.2f}x |")

lines += ["", "## Independent Timing Processes", "",
          "Ranges are the minimum-to-maximum of the 100 per-process batch samples.", "",
          "| Round | Position | Workload | Master median [range] ns | Candidate median [range] ns |",
          "|---:|---:|---|---:|---:|"]
for round_no in [1, 2, 3]:
    for workload in workloads:
        mr = next(r for r in timing if r["round"] == round_no and r["revision"] == "master" and r["workload"] == workload)
        cr = next(r for r in timing if r["round"] == round_no and r["revision"] == "candidate" and r["workload"] == workload)
        master_position = mr["side"]
        candidate_position = cr["side"]
        position = f"M{master_position}/C{candidate_position}"
        lines.append(f"| {round_no} | {position} | {workload} | {fmt_ns(mr['median_ns'])} [{fmt_ns(mr['min_ns'])}-{fmt_ns(mr['max_ns'])}] | {fmt_ns(cr['median_ns'])} [{fmt_ns(cr['min_ns'])}-{fmt_ns(cr['max_ns'])}] |")

lines += ["", "## Allocation Scaling", "",
          "Counts include successful allocations/reallocations made by one encode.", "",
          "| Cells | Geometry | Master allocations / requested bytes | Candidate allocations / requested bytes | Allocation reduction | Output bytes / hash |",
          "|---:|---:|---:|---:|---:|---:|"]
for cells in [1, 10, 100, 1000, 10000]:
    m = next(r for r in allocation if r["revision"] == "master" and r["cells"] == cells)
    c = next(r for r in allocation if r["revision"] == "candidate" and r["cells"] == cells)
    reduction = (m["allocations"] - c["allocations"]) / m["allocations"] * 100
    lines.append(f"| {cells:,} | {m['width']}x{m['height']} | {m['allocations']:,} / {m['requested_bytes']:,} | {c['allocations']:,} / {c['requested_bytes']:,} | {reduction:.3f}% | {m['output_bytes']:,} / `{m['output_hash']}` |")

lines += ["", "## 800x600 Race", "",
          "| Round | Order position | Revision | Frames | Actual seconds | FPS |",
          "|---:|---:|---|---:|---:|---:|"]
for r in race:
    lines.append(f"| {r['round']} | {r['side']} | {r['revision']} | {r['frames']:,} | {r['elapsed_seconds']:.6f} | {r['fps']:.3f} |")
lines += ["", "| Revision | Aggregate frames | Aggregate seconds | Aggregate FPS | Round FPS range | Relative spread |",
          "|---|---:|---:|---:|---:|---:|"]
for revision in ["master", "candidate"]:
    a = race_aggregate[revision]
    lines.append(f"| {revision} | {a['frames']:,} | {a['elapsed_seconds']:.6f} | {a['fps']:.3f} | {a['round_fps_range']:.3f} | {a['round_fps_relative_spread_percent']:.2f}% |")
lines += ["", f"Candidate aggregate race throughput was **{race_speedup:.2f}x** master.",
          f"Every round emitted {race[0]['output_bytes']:,} bytes/frame with matching hash `{race[0]['output_hash']}`.",
          "", "## Equivalence and Validation", "",
          f"- {len(equivalence)} comparable timing/allocation/race scopes matched in byte count and hash.",
          "- All timing reductions and speedups were recomputed from the median of three process medians.",
          "- Race FPS and aggregation were recomputed from frames and actual elapsed time.",
          "- Every timing/race log declared `counting_allocator=false`; allocation logs declared it `true`.",
          "- Expected process, workload, sample, scale and race counts were enforced.",
          "- `validation.txt` records checkout/ref immutability checks.",
          "", "## Environment", ""]
env = result["environment"]
lines += [
    f"- CPU: {env['cpu_model']} ({env['logical_cores']} logical cores)",
    f"- Memory: {env['memory_gib']:.2f} GiB",
    f"- OS: {env['macos_product']} {env['macos_version']} ({env['macos_build']})",
    f"- Architecture: {env['architecture']}",
    f"- Rust: {env['rustc_version']}",
    f"- Cargo: {env['cargo_version']}",
    "- Release profile: no manifest overrides; Cargo release defaults (opt-level 3,",
    "  debug/debug-assertions/overflow-checks/incremental/LTO off, unwind, 16 codegen units)",
    "", "## Caveats", "",
    "- These are isolated encoder microbenchmarks, not end-to-end terminal latency or GPU measurements.",
    "- macOS load averages were recorded immediately before every measured process in `loads.tsv`; normal workstation noise remains possible.",
    "- The 800x600 race checks output length in-loop but hashes a stable sample outside the timed loop so hashing does not dominate encoder throughput.",
    "- Allocation `requested_bytes` sums allocator request sizes and is not retained or resident memory.",
    "", "## Artifacts", "",
    "- Machine-readable results: `results.json`",
    "- Raw build and process logs: `raw/`",
    "- Exact protocol: `protocol.md`",
    "- Pre-process load averages: `loads.tsv`",
    "- Technical environment: `environment.json`",
    "- Revision and probe hashes: `refs.txt`",
    "- Immutability/arithmetic validation: `validation.txt`",
]
(root / "report.md").write_text("\n".join(lines) + "\n")
PY
}

final_validation() {
  local final_status_sha final_diff_sha final_untracked_sha final_refs_sha
  final_status_sha=$(checkout_status_sha)
  final_diff_sha=$(checkout_diff_sha)
  final_untracked_sha=$(untracked_content_sha)
  final_refs_sha=$(refs_sha)

  {
    printf 'shell_syntax=pass\n'
    printf 'baseline_ref=pass\n'
    printf 'candidate_exactly_one_commit_ahead=pass\n'
    printf 'main_status_before_sha256=%s\n' "$INITIAL_STATUS_SHA"
    printf 'main_status_after_sha256=%s\n' "$final_status_sha"
    printf 'tracked_diff_before_sha256=%s\n' "$INITIAL_DIFF_SHA"
    printf 'tracked_diff_after_sha256=%s\n' "$final_diff_sha"
    printf 'untracked_content_before_sha256=%s\n' "$INITIAL_UNTRACKED_SHA"
    printf 'untracked_content_after_sha256=%s\n' "$final_untracked_sha"
    printf 'refs_before_sha256=%s\n' "$INITIAL_REFS_SHA"
    printf 'refs_after_sha256=%s\n' "$final_refs_sha"
  } >"$RESULTS_DIR/validation.txt"

  [[ "$INITIAL_STATUS_SHA" == "$final_status_sha" ]] || fail "main checkout status changed"
  [[ "$INITIAL_DIFF_SHA" == "$final_diff_sha" ]] || fail "main checkout tracked diff changed"
  [[ "$INITIAL_UNTRACKED_SHA" == "$final_untracked_sha" ]] || fail "pre-existing untracked content changed"
  [[ "$INITIAL_REFS_SHA" == "$final_refs_sha" ]] || fail "refs changed"

  python3 - "$RESULTS_DIR/results.json" "$RESULTS_DIR/validation.txt" <<'PY'
import json
import math
import statistics
import sys

result = json.load(open(sys.argv[1]))
for row in result["timing_aggregates"]:
    m = int(statistics.median(row["master"]["process_medians_ns"]))
    c = int(statistics.median(row["candidate"]["process_medians_ns"]))
    assert m == row["master"]["median_of_process_medians_ns"]
    assert c == row["candidate"]["median_of_process_medians_ns"]
    assert math.isclose(row["time_reduction_percent"], (m-c)/m*100, rel_tol=1e-12)
    assert math.isclose(row["speedup"], m/c, rel_tol=1e-12)
assert result["validation"]["all_comparable_outputs_match"]
with open(sys.argv[2], "a") as f:
    f.write("output_equivalence=pass\n")
    f.write("timing_arithmetic=pass\n")
    f.write("race_arithmetic=pass\n")
    f.write("process_counts=pass\n")
    f.write("main_checkout_unchanged=pass\n")
    f.write("refs_unchanged=pass\n")
PY
}

run() {
  [[ "$(uname -s)" == Darwin ]] || fail "this fixed environment recorder expects macOS"
  command -v cargo >/dev/null || fail "cargo not found"
  command -v rustc >/dev/null || fail "rustc not found"
  command -v python3 >/dev/null || fail "python3 not found"

  bash -n "$0"
  verify_refs
  initialize_paths
  INITIAL_STATUS_SHA=$(checkout_status_sha)
  INITIAL_DIFF_SHA=$(checkout_diff_sha)
  INITIAL_UNTRACKED_SHA=$(untracked_content_sha)
  INITIAL_REFS_SHA=$(refs_sha)

  prepare_results
  record_environment
  write_protocol
  printf 'utc\tphase\tkey\tload_1m\tload_5m\tload_15m\n' >"$RESULTS_DIR/loads.tsv"
  create_worktrees

  printf 'Building four release binaries before measurements...\n'
  build_all
  printf 'Running six counterbalanced timing processes...\n'
  run_timing
  printf 'Running two allocation scaling suites...\n'
  run_allocation
  printf 'Running four counterbalanced 800x600 race sides...\n'
  run_race
  printf 'Parsing, validating and reporting...\n'
  generate_results
  final_validation
  printf 'Complete: %s\n' "$RESULTS_DIR/report.md"
}

case "${1:-}" in
  run) run ;;
  -h|--help|help|'') usage ;;
  *) usage >&2; fail "unknown command: $1" ;;
esac
