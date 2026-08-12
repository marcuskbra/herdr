#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)" && pwd -P)
# shellcheck source=ansi-private-root-safety.sh
source "$SCRIPT_DIR/ansi-private-root-safety.sh"
MASTER_REF=${MASTER_REF:-06ca0baa12f4203c5bbad9ecadf53f9a475a52b2}
IMPROVED_REF=${IMPROVED_REF:-d00dc4813d6803ce4efa3e9ad7b1c3533512aaff}
WORK_ROOT=${WORK_ROOT:-${TMPDIR:-/tmp}/herdr-ansi-encoder-demo}
MASTER_DIR="$WORK_ROOT/master"
IMPROVED_DIR="$WORK_ROOT/improved"
RESULTS_DIR="$WORK_ROOT/results"
TARGET_ROOT="$WORK_ROOT/target"
MARKER="// HERDR ANSI ENCODER DEMO PROBES"

usage() {
  cat <<'EOF'
Usage: ansi-encoder-demo.sh <command> [version]

Commands:
  compare                 Run timing and allocation probes on master and improved.
  animate <version>       Animate repeated dense transitions in the terminal.
                          Version is master or improved. `visualize` is an alias.
  race                    Run the virtual large-frame workload on both versions.
  trace <version>         Capture a macOS Allocations trace.
  paths                   Print the disposable paths and resolved revisions.
  clean                   Remove the disposable worktrees and results.

Environment:
  MASTER_REF              Baseline ref. Default: fixed baseline commit
  IMPROVED_REF            Candidate ref. Default: fixed candidate commit
  WORK_ROOT               Disposable root. Default:
                          ${TMPDIR:-/tmp}/herdr-ansi-encoder-demo
  HERDR_ANSI_DEMO_SECONDS Animation or race duration. Default: 10
  HERDR_ANSI_DEMO_FPS     Target animation rate. Default: 10
  HERDR_ANSI_DEMO_WIDTH   Animated frame width. Default: 200
  HERDR_ANSI_DEMO_HEIGHT  Animated frame height. Default: 50
  HERDR_ANSI_RACE_WIDTH   Virtual race width. Default: 800
  HERDR_ANSI_RACE_HEIGHT  Virtual race height. Default: 600
  HERDR_ANSI_TRACE_SECONDS Trace workload duration. Default: 5
  HERDR_ANSI_PRIVATE_ROOT  Required outside-repository root for native traces

The script never modifies either source branch. It creates detached disposable
worktrees, injects test-only probes there and keeps logs under WORK_ROOT.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

resolve_ref() {
  git -C "$REPO_ROOT" rev-parse --verify "$1^{commit}"
}

worktree_registered() {
  git -C "$REPO_ROOT" worktree list --porcelain |
    grep -Fqx "worktree $1"
}

remove_worktree() {
  local path=$1
  if worktree_registered "$path"; then
    git -C "$REPO_ROOT" worktree remove --force "$path"
  elif [[ -e "$path" ]]; then
    [[ -f "$WORK_ROOT/.herdr-ansi-encoder-demo" ]] ||
      fail "refusing to remove unrecognized path: $path"
    rm -rf "$path"
  fi
}

configure_build_environment() {
  unset HERDR_RENDER_PROF CARGO_PROFILE_RELEASE_DEBUG RUSTFLAGS
  export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-1}
  if [[ -z "${ZIG:-}" && -x /opt/homebrew/bin/zig ]]; then
    export ZIG=/opt/homebrew/bin/zig
  fi
}

probe_source() {
  cat <<'RUST'

    // HERDR ANSI ENCODER DEMO PROBES
    const ALLOCATION_DEMO_WIDTH: u16 = 200;
    const ALLOCATION_DEMO_HEIGHT: u16 = 50;

    fn allocation_demo_colour(index: usize) -> u32 {
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

    fn allocation_demo_modifier(index: usize) -> u16 {
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

    fn allocation_demo_frame(width: u16, height: u16, generation: usize) -> FrameData {
        let cells = (0..usize::from(width) * usize::from(height))
            .map(|index| {
                let symbol = char::from(b'!' + ((index + generation) % 94) as u8).to_string();
                make_cell(
                    &symbol,
                    allocation_demo_colour(index + generation),
                    allocation_demo_colour(index * 5 + generation + 1),
                    allocation_demo_modifier(index + generation),
                )
            })
            .collect();
        make_frame(width, height, cells)
    }

    fn allocation_demo_encoder(previous: &FrameData) -> BlitEncoder {
        let mut encoder = BlitEncoder::new();
        let encoded = encoder.encode(previous, false);
        encoder.commit(previous.clone(), encoded);
        encoder
    }

    fn allocation_demo_hash(bytes: &[u8]) -> u64 {
        bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
            (hash ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3)
        })
    }

    #[test]
    #[ignore = "manual ANSI encoder timing demonstration"]
    fn ansi_encoder_timing_demo() {
        const FRAMES_PER_BATCH: usize = 10;
        const BATCHES: usize = 100;
        let previous = allocation_demo_frame(ALLOCATION_DEMO_WIDTH, ALLOCATION_DEMO_HEIGHT, 0);
        let current = allocation_demo_frame(ALLOCATION_DEMO_WIDTH, ALLOCATION_DEMO_HEIGHT, 1);
        let encoder = allocation_demo_encoder(&previous);

        for _ in 0..20 {
            drop(std::hint::black_box(encoder.encode(&current, false)));
        }

        let expected = encoder.encode(&current, false);
        let output_bytes = expected.bytes.len();
        let output_hash = allocation_demo_hash(&expected.bytes);
        drop(expected);
        let mut samples = Vec::with_capacity(BATCHES);
        for _ in 0..BATCHES {
            let started = std::time::Instant::now();
            for _ in 0..FRAMES_PER_BATCH {
                let encoded = std::hint::black_box(encoder.encode(&current, false));
                assert_eq!(encoded.bytes.len(), output_bytes);
                drop(encoded);
            }
            samples.push(started.elapsed().as_nanos() / FRAMES_PER_BATCH as u128);
        }
        samples.sort_unstable();
        let p95 = samples[(samples.len() * 95).div_ceil(100) - 1];
        println!(
            "DEMO_TIMING median_ns={} p95_ns={} max_ns={} output_bytes={} output_hash={:016x}",
            samples[samples.len() / 2],
            p95,
            samples[samples.len() - 1],
            output_bytes,
            output_hash
        );
    }

    #[cfg(feature = "test-allocation-counting")]
    #[test]
    #[ignore = "manual ANSI encoder allocation demonstration"]
    fn ansi_encoder_allocation_demo() {
        for (width, height) in [(1, 1), (10, 1), (100, 1), (100, 10), (200, 50)] {
            let previous = allocation_demo_frame(width, height, 0);
            let current = allocation_demo_frame(width, height, 1);
            let encoder = allocation_demo_encoder(&previous);
            let (encoded, stats) = crate::test_alloc::measure(|| {
                std::hint::black_box(encoder.encode(std::hint::black_box(&current), false))
            });
            println!(
                "DEMO_METRIC cells={} allocations={} requested_bytes={} output_bytes={} output_hash={:016x}",
                usize::from(width) * usize::from(height),
                stats.allocations,
                stats.requested_bytes,
                encoded.bytes.len(),
                allocation_demo_hash(&encoded.bytes)
            );
        }
    }

    fn allocation_demo_env_usize(name: &str, default: usize) -> usize {
        std::env::var(name)
            .ok()
            .and_then(|value| value.parse().ok())
            .filter(|value| *value > 0)
            .unwrap_or(default)
    }

    struct AllocationDemoTerminal;

    impl Drop for AllocationDemoTerminal {
        fn drop(&mut self) {
            let mut stdout = std::io::stdout();
            let _ = stdout.write_all(b"\x1b[0m\x1b[?25h\x1b[?1049l");
            let _ = stdout.flush();
        }
    }

    fn allocation_demo_label(stdout: &mut impl Write, row: u16, text: &str) {
        let _ = write!(stdout, "\x1b[{row};1H\x1b[0m\x1b[2K{text}");
        let _ = stdout.flush();
    }

    #[test]
    #[ignore = "manual repeated ANSI encoder visualization"]
    fn ansi_encoder_visual_demo() {
        use std::io::IsTerminal;

        assert!(
            std::io::stdout().is_terminal(),
            "run the visual demonstration from an interactive terminal"
        );
        let (columns, rows) = crossterm::terminal::size().expect("read terminal dimensions");
        let requested_width = allocation_demo_env_usize("HERDR_ANSI_DEMO_WIDTH", 200);
        let requested_height = allocation_demo_env_usize("HERDR_ANSI_DEMO_HEIGHT", 50);
        let width = requested_width.min(usize::from(columns)).min(usize::from(u16::MAX)) as u16;
        let height = requested_height
            .min(usize::from(rows.saturating_sub(1)))
            .min(usize::from(u16::MAX)) as u16;
        assert!(width > 0 && height > 0, "the terminal has no space for the demo");

        let seconds = allocation_demo_env_usize("HERDR_ANSI_DEMO_SECONDS", 10);
        let fps = allocation_demo_env_usize("HERDR_ANSI_DEMO_FPS", 10);
        let frame_interval = std::time::Duration::from_secs_f64(1.0 / fps as f64);
        let started = std::time::Instant::now();
        let deadline = started + std::time::Duration::from_secs(seconds as u64);
        let mut generation = 0usize;
        let first_frame = allocation_demo_frame(width, height, generation);
        let mut encoder = BlitEncoder::new();
        let first = encoder.encode(&first_frame, false);
        let mut stdout = std::io::stdout();

        stdout.write_all(b"\x1b[?1049h").expect("enter alternate screen");
        let _guard = AllocationDemoTerminal;
        stdout.write_all(&first.bytes).expect("draw first frame");
        encoder.commit(first_frame, first);

        let mut frames = 1usize;
        let mut total_encode_ns = 0u128;
        let mut total_output_bytes = 0usize;
        while std::time::Instant::now() < deadline {
            let frame_started = std::time::Instant::now();
            generation = generation.wrapping_add(1);
            let frame = allocation_demo_frame(width, height, generation);
            let encode_started = std::time::Instant::now();
            let encoded = encoder.encode(&frame, false);
            let encode_ns = encode_started.elapsed().as_nanos();
            total_encode_ns += encode_ns;
            total_output_bytes += encoded.bytes.len();
            stdout.write_all(&encoded.bytes).expect("draw transition");
            encoder.commit(frame, encoded);
            frames += 1;

            let average_us = total_encode_ns / (frames - 1) as u128 / 1_000;
            allocation_demo_label(
                &mut stdout,
                height + 1,
                &format!(
                    "Dense {width}x{height} | frame {frames} | avg encode {average_us} us | ANSI {} KiB/frame",
                    total_output_bytes / (frames - 1) / 1024
                ),
            );
            if let Some(remaining) = frame_interval.checked_sub(frame_started.elapsed()) {
                std::thread::sleep(remaining);
            }
        }
        let elapsed = started.elapsed().as_secs_f64();
        allocation_demo_label(
            &mut stdout,
            height + 1,
            &format!(
                "Complete | {frames} frames in {elapsed:.2} s | {:.1} displayed frames/s",
                frames as f64 / elapsed
            ),
        );
        std::thread::sleep(std::time::Duration::from_secs(2));
    }

    #[test]
    #[ignore = "manual large virtual-frame race"]
    fn ansi_encoder_virtual_race_demo() {
        let width = allocation_demo_env_usize("HERDR_ANSI_RACE_WIDTH", 800)
            .min(usize::from(u16::MAX)) as u16;
        let height = allocation_demo_env_usize("HERDR_ANSI_RACE_HEIGHT", 600)
            .min(usize::from(u16::MAX)) as u16;
        let seconds = allocation_demo_env_usize("HERDR_ANSI_DEMO_SECONDS", 10);
        let previous = allocation_demo_frame(width, height, 0);
        let current = allocation_demo_frame(width, height, 1);
        let encoder = allocation_demo_encoder(&previous);
        let sample = encoder.encode(&current, false);
        let output_bytes = sample.bytes.len();
        let output_hash = allocation_demo_hash(&sample.bytes);
        drop(sample);

        let started = std::time::Instant::now();
        let deadline = started + std::time::Duration::from_secs(seconds as u64);
        let mut frames = 0usize;
        let mut next_report = started + std::time::Duration::from_secs(1);
        while std::time::Instant::now() < deadline {
            let encoded = std::hint::black_box(encoder.encode(&current, false));
            assert_eq!(encoded.bytes.len(), output_bytes);
            assert_eq!(allocation_demo_hash(&encoded.bytes), output_hash);
            drop(encoded);
            frames += 1;
            let now = std::time::Instant::now();
            if now >= next_report {
                let elapsed = started.elapsed().as_secs_f64();
                println!(
                    "DEMO_RACE_PROGRESS elapsed={elapsed:.1} frames={frames} fps={:.2}",
                    frames as f64 / elapsed
                );
                next_report += std::time::Duration::from_secs(1);
            }
        }
        let elapsed = started.elapsed().as_secs_f64();
        println!(
            concat!(
                "DEMO_RACE width={} height={} cells={} seconds={:.3} ",
                "frames={} fps={:.3} output_bytes={} output_hash={:016x}"
            ),
            width,
            height,
            usize::from(width) * usize::from(height),
            elapsed,
            frames,
            frames as f64 / elapsed,
            output_bytes,
            output_hash
        );
    }

    #[test]
    #[ignore = "manual workload for an external allocation profiler"]
    fn ansi_encoder_allocation_trace_demo() {
        let seconds = std::env::var("HERDR_ANSI_TRACE_SECONDS")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(5);
        let previous = allocation_demo_frame(ALLOCATION_DEMO_WIDTH, ALLOCATION_DEMO_HEIGHT, 0);
        let current = allocation_demo_frame(ALLOCATION_DEMO_WIDTH, ALLOCATION_DEMO_HEIGHT, 1);
        let encoder = allocation_demo_encoder(&previous);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(seconds);
        let mut frames = 0usize;
        while std::time::Instant::now() < deadline {
            drop(std::hint::black_box(encoder.encode(&current, false)));
            frames += 1;
        }
        println!("DEMO_TRACE frames={frames} seconds={seconds}");
    }
RUST
}

instrument_tree() {
  local tree=$1
  local improved_commit=$2

  git -C "$REPO_ROOT" show "$improved_commit:src/test_alloc.rs" >"$tree/src/test_alloc.rs"
  probe_source >"$tree/.allocation-demo-probe.rs"
  python3 - "$tree" "$MARKER" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
marker = sys.argv[2]

cargo = root / "Cargo.toml"
text = cargo.read_text()
if "test-allocation-counting = []" not in text:
    text = text.replace(
        "[dependencies]\n",
        "[features]\n"
        "# Test-only allocator instrumentation. Never enable for timing.\n"
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

render = root / "src/protocol/render_ansi.rs"
text = render.read_text()
if marker not in text:
    probe = (root / ".allocation-demo-probe.rs").read_text()
    index = text.rfind("}")
    if index < 0:
        raise SystemExit("could not find the test module closing brace")
    render.write_text(text[:index] + probe + "\n" + text[index:])
PY
  rm "$tree/.allocation-demo-probe.rs"
  (cd "$tree" && cargo fmt)
}

ensure_tree() {
  local label=$1
  local tree=$2
  local commit=$3
  local improved_commit=$4
  local fingerprint_file="$WORK_ROOT/$label.fingerprint"
  local fingerprint
  fingerprint=$(printf '%s\n%s\n' "$commit" "$(shasum -a 256 "$0")" | shasum -a 256)

  if [[ -e "$tree" ]] &&
    { [[ ! -f "$fingerprint_file" ]] || [[ $(<"$fingerprint_file") != "$fingerprint" ]]; }
  then
    remove_worktree "$tree"
  fi
  if [[ ! -d "$tree/.git" && ! -f "$tree/.git" ]]; then
    git -C "$REPO_ROOT" worktree add --detach "$tree" "$commit"
    instrument_tree "$tree" "$improved_commit"
    printf '%s\n' "$fingerprint" >"$fingerprint_file"
  fi
}

setup() {
  local master_commit improved_commit
  master_commit=$(resolve_ref "$MASTER_REF")
  improved_commit=$(resolve_ref "$IMPROVED_REF")
  [[ "$master_commit" == "06ca0baa12f4203c5bbad9ecadf53f9a475a52b2" ]] ||
    fail "baseline ref does not resolve to the declared baseline"
  [[ "$improved_commit" == "d00dc4813d6803ce4efa3e9ad7b1c3533512aaff" ]] ||
    fail "candidate ref does not resolve to the declared candidate"
  [[ "$(git -C "$REPO_ROOT" rev-parse "$improved_commit^")" == "$master_commit" ]] ||
    fail "candidate is not the direct child of the baseline"

  mkdir -p "$WORK_ROOT" "$RESULTS_DIR" "$TARGET_ROOT"
  printf '%s\n' "$REPO_ROOT" >"$WORK_ROOT/.herdr-ansi-encoder-demo"
  ensure_tree master "$MASTER_DIR" "$master_commit" "$improved_commit"
  ensure_tree improved "$IMPROVED_DIR" "$improved_commit" "$improved_commit"
}

run_test() {
  local label=$1
  local tree=$2
  local test_name=$3
  local features=${4:-}
  local log="$RESULTS_DIR/$label-$test_name.log"
  local args=(test --release --locked --bin herdr)
  if [[ -n "$features" ]]; then
    args+=(--features "$features")
  fi
  args+=("protocol::render_ansi::tests::$test_name" -- --ignored --exact --nocapture --test-threads=1)

  printf '\n== %s: %s ==\n' "$label" "$test_name"
  (
    cd "$tree"
    CARGO_TARGET_DIR="$TARGET_ROOT/$label" cargo "${args[@]}"
  ) 2>&1 | tee "$log"
}

print_comparison() {
  python3 - "$RESULTS_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
metric_pattern = re.compile(
    r"DEMO_METRIC cells=(\d+) allocations=(\d+) requested_bytes=(\d+) "
    r"output_bytes=(\d+) output_hash=([0-9a-f]+)"
)
timing_pattern = re.compile(
    r"DEMO_TIMING median_ns=(\d+) p95_ns=(\d+) max_ns=(\d+) "
    r"output_bytes=(\d+) output_hash=([0-9a-f]+)"
)

def read(label, test, pattern):
    path = root / f"{label}-{test}.log"
    matches = pattern.findall(path.read_text())
    if not matches:
        raise SystemExit(f"no demo metrics found in {path}")
    return matches

master = {int(row[0]): tuple(row[1:]) for row in read(
    "master", "ansi_encoder_allocation_demo", metric_pattern
)}
improved = {int(row[0]): tuple(row[1:]) for row in read(
    "improved", "ansi_encoder_allocation_demo", metric_pattern
)}
master_timing = read("master", "ansi_encoder_timing_demo", timing_pattern)[0]
improved_timing = read("improved", "ansi_encoder_timing_demo", timing_pattern)[0]

print("\nAllocation scaling")
print("+---------+----------------+----------------+------------+--------------+")
print("| Cells   | Master allocs  | Improved      | Reduction  | Bytes equal  |")
print("+---------+----------------+----------------+------------+--------------+")
for cells in sorted(master):
    ma, _, mb, mh = master[cells]
    ia, _, ib, ih = improved[cells]
    equal = "yes" if (mb, mh) == (ib, ih) else "NO"
    reduction = (1 - int(ia) / int(ma)) * 100
    print(f"| {cells:>7,} | {int(ma):>14,} | {int(ia):>14,} | {reduction:>8.3f}% | {equal:^12} |")
print("+---------+----------------+----------------+------------+--------------+")

mm, _, _, mb, mh = master_timing
im, _, _, ib, ih = improved_timing
if (mb, mh) != (ib, ih):
    raise SystemExit("master and improved timing probes emitted different bytes")
speedup = int(mm) / int(im)
reduction = (1 - int(im) / int(mm)) * 100
print("\nDense 200x50 timing")
print(f"  Master median:   {int(mm):>10,} ns/frame")
print(f"  Improved median: {int(im):>10,} ns/frame")
print(f"  Improvement:     {reduction:>10.1f}% ({speedup:.2f}x faster)")
print(f"  Output:          {int(mb):>10,} bytes, identical hash {mh}")

ma, mr, mb, mh = master[10_000]
ia, ir, ib, ih = improved[10_000]
print("\nExact dense 200x50 allocation result")
print(f"  Master:          {int(ma):>10,} allocation/reallocation operations")
print(f"  Improved:        {int(ia):>10,} allocation/reallocation operations")
print(f"  Reduction:       {(1 - int(ia) / int(ma)) * 100:>10.3f}%")
print(f"  Output:          {int(mb):>10,} bytes, identical hash {mh}")
PY
}

compare() {
  configure_build_environment
  setup
  run_test master "$MASTER_DIR" ansi_encoder_timing_demo
  run_test improved "$IMPROVED_DIR" ansi_encoder_timing_demo
  run_test master "$MASTER_DIR" ansi_encoder_allocation_demo test-allocation-counting
  run_test improved "$IMPROVED_DIR" ansi_encoder_allocation_demo test-allocation-counting
  print_comparison
  printf '\nLogs: %s\n' "$RESULTS_DIR"
}

select_tree() {
  case "${1:-}" in
    master) printf '%s\n' "$MASTER_DIR" ;;
    improved) printf '%s\n' "$IMPROVED_DIR" ;;
    *) fail "version must be master or improved" ;;
  esac
}

animate() {
  local version=${1:-}
  local tree
  configure_build_environment
  setup
  tree=$(select_tree "$version")
  printf 'Animating %s for %s seconds at up to %s frames/s.\n' \
    "$version" "${HERDR_ANSI_DEMO_SECONDS:-10}" "${HERDR_ANSI_DEMO_FPS:-10}"
  printf 'Requested frame: %sx%s. It is clipped to the current terminal.\n' \
    "${HERDR_ANSI_DEMO_WIDTH:-200}" "${HERDR_ANSI_DEMO_HEIGHT:-50}"
  (
    cd "$tree"
    CARGO_TARGET_DIR="$TARGET_ROOT/$version" cargo test --release --locked --bin herdr \
      protocol::render_ansi::tests::ansi_encoder_visual_demo -- \
      --ignored --exact --nocapture --test-threads=1
  )
}

run_race_version() {
  local version=$1
  local tree log
  tree=$(select_tree "$version")
  log="$RESULTS_DIR/$version-ansi_encoder_virtual_race_demo.log"
  printf '\n== Virtual race: %s ==\n' "$version"
  (
    cd "$tree"
    CARGO_TARGET_DIR="$TARGET_ROOT/$version" cargo test --release --locked --bin herdr \
      protocol::render_ansi::tests::ansi_encoder_virtual_race_demo -- \
      --ignored --exact --nocapture --test-threads=1
  ) 2>&1 | tee "$log"
}

print_race_comparison() {
  python3 - "$RESULTS_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
pattern = re.compile(
    r"DEMO_RACE width=(\d+) height=(\d+) cells=(\d+) seconds=([0-9.]+) "
    r"frames=(\d+) fps=([0-9.]+) output_bytes=(\d+) output_hash=([0-9a-f]+)"
)

def load(version):
    path = root / f"{version}-ansi_encoder_virtual_race_demo.log"
    matches = pattern.findall(path.read_text())
    if not matches:
        raise SystemExit(f"no virtual race result in {path}")
    return matches[-1]

master = load("master")
improved = load("improved")
if master[:3] != improved[:3]:
    raise SystemExit("master and improved race dimensions differ")
if master[6:] != improved[6:]:
    raise SystemExit("master and improved race output differs")

width, height, cells = map(int, master[:3])
master_seconds, master_frames, master_fps = float(master[3]), int(master[4]), float(master[5])
improved_seconds, improved_frames, improved_fps = (
    float(improved[3]), int(improved[4]), float(improved[5])
)
output_bytes, output_hash = int(master[6]), master[7]

print("\nVirtual dense-frame race")
print(f"  Frame:            {width:,}x{height:,} ({cells:,} cells)")
print(f"  Master:           {master_frames:,} frames in {master_seconds:.2f} s ({master_fps:.2f} fps)")
print(f"  Improved:         {improved_frames:,} frames in {improved_seconds:.2f} s ({improved_fps:.2f} fps)")
print(f"  Encoder speedup:  {improved_fps / master_fps:.2f}x")
print(f"  ANSI per frame:   {output_bytes / 1024 / 1024:.2f} MiB")
print(f"  Output hash:      {output_hash}, identical")
print("\nThe race encodes and hashes the full virtual frame off-screen.")
print("Terminal drawing is excluded so both versions measure the encoder itself.")
PY
}

race() {
  configure_build_environment
  setup
  printf 'Running a %sx%s virtual dense-frame race for %s seconds per version.\n' \
    "${HERDR_ANSI_RACE_WIDTH:-800}" "${HERDR_ANSI_RACE_HEIGHT:-600}" \
    "${HERDR_ANSI_DEMO_SECONDS:-10}"
  run_race_version master
  run_race_version improved
  print_race_comparison
}

find_test_binary() {
  local version=$1
  local tree=$2
  local build_log="$RESULTS_DIR/$version-trace-build.jsonl"
  (
    cd "$tree"
    CARGO_PROFILE_RELEASE_DEBUG=1 RUSTFLAGS='-C force-frame-pointers=yes' \
      CARGO_TARGET_DIR="$TARGET_ROOT/$version-trace" \
      cargo test --release --locked --bin herdr --no-run --message-format=json
  ) >"$build_log"
  python3 - "$build_log" <<'PY'
import json
import sys
path = sys.argv[1]
executable = None
with open(path) as lines:
    for line in lines:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        target = event.get("target", {})
        profile = event.get("profile", {})
        if target.get("name") == "herdr" and profile.get("test") and event.get("executable"):
            executable = event["executable"]
if not executable:
    raise SystemExit("could not locate the Herdr test binary")
print(executable)
PY
}

trace_allocations() {
  local version=${1:-}
  local tree binary trace_path private_root_raw=${HERDR_ANSI_PRIVATE_ROOT:-} private_root
  [[ "$(uname -s)" == Darwin ]] || fail "native tracing requires macOS"
  [[ -n "$private_root_raw" ]] ||
    fail "HERDR_ANSI_PRIVATE_ROOT must name a directory outside the repository"
  private_root=$(ansi_safe_external_root "$REPO_ROOT" "$private_root_raw") ||
    fail "HERDR_ANSI_PRIVATE_ROOT failed canonical path validation"
  configure_build_environment
  setup
  tree=$(select_tree "$version")
  if ! /usr/bin/xctrace list templates >/dev/null 2>&1; then
    fail "xctrace needs full Xcode. Install Xcode and select it with: sudo xcode-select -s /Applications/Xcode.app"
  fi
  binary=$(find_test_binary "$version" "$tree")
  local trace_root="$private_root/demo-traces"
  local trace_marker="$trace_root/.herdr-ansi-demo-traces"
  ansi_revalidate_external_root "$REPO_ROOT" "$private_root" ||
    fail "private root changed before sentinel inspection"
  if [[ -e "$trace_root" && ! -f "$trace_marker" ]]; then
    fail "refusing unrecognized private trace directory: $trace_root"
  fi
  ansi_revalidate_external_root "$REPO_ROOT" "$private_root" ||
    fail "private root changed before trace-directory creation"
  mkdir -p "$trace_root"
  printf 'owned ANSI demo traces\n' >"$trace_marker"
  trace_path="$trace_root/$version-allocations.trace"
  ansi_revalidate_external_root "$REPO_ROOT" "$private_root" ||
    fail "private root changed before trace replacement"
  [[ -f "$trace_marker" ]] || fail "trace ownership sentinel is missing"
  rm -rf "$trace_path"
  printf 'Capturing %s allocations to private path %s\n' "$version" "$trace_path"
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" \
    LANG="${LANG:-en_US.UTF-8}" \
    HERDR_ANSI_TRACE_SECONDS="${HERDR_ANSI_TRACE_SECONDS:-5}" \
    /usr/bin/xctrace record \
      --template Allocations \
      --output "$trace_path" \
      --no-prompt \
      --launch -- "$binary" \
      protocol::render_ansi::tests::ansi_encoder_allocation_trace_demo \
      --ignored --exact --nocapture --test-threads=1
  printf 'Open the private trace locally: open %q\n' "$trace_path"
}

print_paths() {
  printf 'Repository: %s\n' "$REPO_ROOT"
  printf 'Master:     %s (%s)\n' "$MASTER_REF" "$(resolve_ref "$MASTER_REF")"
  printf 'Improved:   %s (%s)\n' "$IMPROVED_REF" "$(resolve_ref "$IMPROVED_REF")"
  printf 'Work root:  %s\n' "$WORK_ROOT"
  printf 'Master WT:  %s\n' "$MASTER_DIR"
  printf 'Improved WT:%s\n' "$IMPROVED_DIR"
  printf 'Results:    %s\n' "$RESULTS_DIR"
}

clean() {
  if [[ ! -e "$WORK_ROOT" ]]; then
    printf 'Nothing to clean at %s\n' "$WORK_ROOT"
    return
  fi
  [[ -f "$WORK_ROOT/.herdr-ansi-encoder-demo" ]] ||
    fail "refusing to clean unrecognized directory: $WORK_ROOT"
  remove_worktree "$MASTER_DIR"
  remove_worktree "$IMPROVED_DIR"
  rm -rf "$WORK_ROOT"
  git -C "$REPO_ROOT" worktree prune
  printf 'Removed %s\n' "$WORK_ROOT"
}

case "${1:-}" in
  compare) compare ;;
  animate|visualize) animate "${2:-}" ;;
  race) race ;;
  trace) trace_allocations "${2:-}" ;;
  paths) print_paths ;;
  clean) clean ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; fail "unknown command: $1" ;;
esac
