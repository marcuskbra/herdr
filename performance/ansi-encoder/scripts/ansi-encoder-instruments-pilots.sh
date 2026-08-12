#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

readonly BASELINE_COMMIT=06ca0baa12f4203c5bbad9ecadf53f9a475a52b2
readonly CANDIDATE_COMMIT=d00dc4813d6803ce4efa3e9ad7b1c3533512aaff
readonly EXPECTED_BYTES=276444
readonly EXPECTED_HASH=edfa0379543ed13d
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$(cd "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)" && pwd -P)"
# shellcheck source=ansi-private-root-safety.sh
source "$SCRIPT_DIR/ansi-private-root-safety.sh"
readonly PRIVATE_ROOT_RAW="${HERDR_ANSI_PRIVATE_ROOT:-}"
PRIVATE_ROOT=
PROFILE_DIR=
MARKER=
readonly WORK_ROOT="${HERDR_ANSI_WORK_ROOT:-${TMPDIR:-/tmp}/herdr-ansi-instruments-work}"
readonly WORK_MARKER="$WORK_ROOT/.herdr-ansi-instruments-work"
readonly MASTER_TREE="$WORK_ROOT/master"
readonly CANDIDATE_TREE="$WORK_ROOT/candidate"
readonly TARGET_ROOT="$WORK_ROOT/target"
readonly TEST_NAME=protocol::render_ansi::tests::ansi_instruments_probe

MASTER_ADDED=0
CANDIDATE_ADDED=0
INITIAL_STATUS_SHA=
INITIAL_DIFF_SHA=
INITIAL_REFS_SHA=
ACTIVE_PROBE_PID=
ACTIVE_TRACE_PID=
ACTIVE_CONTROL_FILES=()
readonly WORK_OWNER="ansi-instruments:$$:${RANDOM}${RANDOM}"

usage() {
  cat <<'EOF'
Usage: performance/ansi-encoder/scripts/ansi-encoder-instruments-pilots.sh <command>

Commands:
  build       Verify refs/toolchain, create disposable detached worktrees,
              inject the probe, and build/symbolicate both release binaries.
  cpu         Record the retained pilot master/candidate Time Profiler traces.
  final-cpu   Record new master then candidate Time Profiler traces for exactly
              8s, with 14s of post-trigger encoder work and an 8s tail.
  allocations Record master then candidate with Allocations, exactly 5 frames.
  export      Export schema names from the final CPU traces when present,
              otherwise from the retained pilot CPU traces.
  validate    Validate oracles, identities, traces, and checkout immutability.
  all         Run build, CPU, allocations, TOC export, and validation.
  clean-work  Remove only this runner's disposable worktree root.

Set HERDR_ANSI_PRIVATE_ROOT to a directory outside the repository before any
command except help. Native .trace bundles, Mach-O files and dSYMs remain there
because they inherently include local paths. The runner uses disposable
worktrees and isolated Cargo targets under HERDR_ANSI_WORK_ROOT or the system
temporary directory. Text summaries must be sanitized before sharing.
EOF
}

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
status_sha() { git -C "$REPO_ROOT" status --porcelain=v1 -z --untracked-files=all | shasum -a 256 | awk '{print $1}'; }
diff_sha() { git -C "$REPO_ROOT" diff --binary HEAD | shasum -a 256 | awk '{print $1}'; }
refs_sha() { git -C "$REPO_ROOT" show-ref | shasum -a 256 | awk '{print $1}'; }
registered() { git -C "$REPO_ROOT" worktree list --porcelain | grep -Fqx "worktree $1"; }

snapshot_checkout() {
  INITIAL_STATUS_SHA=$(status_sha)
  INITIAL_DIFF_SHA=$(diff_sha)
  INITIAL_REFS_SHA=$(refs_sha)
}

assert_checkout_unchanged() {
  [[ "$(status_sha)" == "$INITIAL_STATUS_SHA" ]] || fail "main checkout status changed"
  [[ "$(diff_sha)" == "$INITIAL_DIFF_SHA" ]] || fail "main checkout tracked diff changed"
  [[ "$(refs_sha)" == "$INITIAL_REFS_SHA" ]] || fail "git refs changed"
}

verify() {
  [[ -n "$PRIVATE_ROOT_RAW" ]] ||
    fail "HERDR_ANSI_PRIVATE_ROOT must name a directory outside the repository"
  PRIVATE_ROOT=$(ansi_safe_external_root "$REPO_ROOT" "$PRIVATE_ROOT_RAW") ||
    fail "HERDR_ANSI_PRIVATE_ROOT failed canonical path validation"
  PROFILE_DIR="$PRIVATE_ROOT/profiles"
  MARKER="$PROFILE_DIR/.ansi-encoder-instruments-pilots"
  [[ "$(uname -s)" == Darwin ]] || fail "native profiling requires macOS"
  local baseline candidate parent count
  baseline=$(git -C "$REPO_ROOT" rev-parse --verify "$BASELINE_COMMIT^{commit}")
  candidate=$(git -C "$REPO_ROOT" rev-parse --verify "$CANDIDATE_COMMIT^{commit}")
  parent=$(git -C "$REPO_ROOT" rev-parse --verify "$CANDIDATE_COMMIT^")
  count=$(git -C "$REPO_ROOT" rev-list --count "$BASELINE_COMMIT..$CANDIDATE_COMMIT")
  [[ "$baseline" == "$BASELINE_COMMIT" ]] || fail "wrong baseline object"
  [[ "$candidate" == "$CANDIDATE_COMMIT" ]] || fail "wrong candidate object"
  [[ "$parent" == "$BASELINE_COMMIT" ]] || fail "candidate parent mismatch: $parent"
  [[ "$count" == 1 ]] || fail "candidate must be exactly one commit ahead"
  git -C "$REPO_ROOT" merge-base --is-ancestor "$BASELINE_COMMIT" "$CANDIDATE_COMMIT" || fail "parent relationship failed"
  [[ "$(xcodebuild -version | tr '\n' ' ')" == "Xcode 26.6 Build version 17F113 " ]] || fail "unexpected Xcode"
  [[ "$(xcrun xctrace version)" == "xctrace version 16.0 (17F113)" ]] || fail "unexpected xctrace"
  xcrun xctrace list templates | grep -Fx 'Time Profiler' >/dev/null || fail "Time Profiler unavailable"
  xcrun xctrace list templates | grep -Fx 'Allocations' >/dev/null || fail "Allocations unavailable"
}

assert_profile_root_owned() {
  ansi_revalidate_external_root "$REPO_ROOT" "$PRIVATE_ROOT" ||
    fail "private root changed before filesystem operation"
  [[ -f "$MARKER" ]] || fail "private profile ownership sentinel is missing"
}

prepare_profile_dir() {
  ansi_revalidate_external_root "$REPO_ROOT" "$PRIVATE_ROOT" ||
    fail "private root changed before sentinel inspection"
  if [[ -e "$PROFILE_DIR" && ! -f "$MARKER" ]]; then
    fail "refusing unrecognized profile directory: $PROFILE_DIR"
  fi
  ansi_revalidate_external_root "$REPO_ROOT" "$PRIVATE_ROOT" ||
    fail "private root changed before profile-directory creation"
  mkdir -p "$PROFILE_DIR"/{build,raw,export,control}
  printf 'local private Xcode Instruments pilot artifacts\n' >"$MARKER"
}

probe_source() {
  cat <<'RUST'

    // HERDR ANSI INSTRUMENTS PROBE (disposable detached worktrees only)
    const INSTRUMENTS_WIDTH: u16 = 200;
    const INSTRUMENTS_HEIGHT: u16 = 50;
    const INSTRUMENTS_CELLS: usize = 10_000;
    const INSTRUMENTS_EXPECTED_BYTES: usize = 276_444;
    const INSTRUMENTS_EXPECTED_HASH: u64 = 0xedfa_0379_543e_d13d;

    fn instruments_hash(bytes: &[u8]) -> u64 {
        bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
            (hash ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3)
        })
    }

    fn instruments_colour(index: usize) -> u32 {
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

    fn instruments_modifier(index: usize) -> u16 {
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

    fn instruments_dense_frame(generation: usize) -> FrameData {
        let cells = (0..INSTRUMENTS_CELLS)
            .map(|index| {
                let symbol = char::from(b'!' + ((index + generation) % 94) as u8).to_string();
                make_cell(
                    &symbol,
                    instruments_colour(index + generation),
                    instruments_colour(index * 5 + generation + 1),
                    instruments_modifier(index + generation),
                )
            })
            .collect();
        make_frame(INSTRUMENTS_WIDTH, INSTRUMENTS_HEIGHT, cells)
    }

    fn instruments_wait_for(path: &std::path::Path) {
        while !path.exists() {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    #[test]
    #[ignore = "manual Xcode Instruments probe"]
    fn ansi_instruments_probe() {
        use std::io::Write;
        assert!(!cfg!(debug_assertions), "requires optimized release build");
        assert!(!cfg!(feature = "test-allocation-counting"), "requires production allocator");
        assert!(!crate::render_prof::enabled(), "HERDR_RENDER_PROF must be disabled");

        let mode = std::env::var("HERDR_INSTRUMENTS_MODE").expect("mode");
        let ready = std::path::PathBuf::from(std::env::var_os("HERDR_INSTRUMENTS_READY").expect("ready"));
        let trigger = std::path::PathBuf::from(std::env::var_os("HERDR_INSTRUMENTS_TRIGGER").expect("trigger"));
        let work_seconds: f64 = std::env::var("HERDR_INSTRUMENTS_WORK_SECONDS")
            .unwrap_or_else(|_| "4".to_owned()).parse().expect("work seconds");
        let revision = env!("HERDR_PROFILE_REVISION");

        let previous = instruments_dense_frame(0);
        let current = instruments_dense_frame(1);
        assert!(previous.cells.iter().zip(&current.cells).all(|(a, b)| a != b));
        let mut encoder = BlitEncoder::new();
        let initial = encoder.encode(&previous, false);
        encoder.commit(previous, initial);
        let oracle = encoder.encode(&current, false);
        let output_bytes = oracle.bytes.len();
        let output_hash = instruments_hash(&oracle.bytes);
        assert_eq!(output_bytes, INSTRUMENTS_EXPECTED_BYTES, "wrong output byte oracle");
        assert_eq!(output_hash, INSTRUMENTS_EXPECTED_HASH, "wrong output hash oracle");

        for _ in 0..20 {
            let encoded = std::hint::black_box(encoder.encode(std::hint::black_box(&current), false));
            assert_eq!(encoded.bytes.len(), INSTRUMENTS_EXPECTED_BYTES);
            std::hint::black_box(&encoded.bytes);
        }

        std::fs::write(&ready, b"ready\n").expect("write READY file");
        println!(
            "INSTRUMENTS_READY revision={} mode={} warmups=20 width=200 height=50 cells=10000 allocator=production-system counting_allocator=false",
            revision, mode
        );
        std::io::stdout().flush().expect("flush READY");
        instruments_wait_for(&trigger);

        let started = std::time::Instant::now();
        let mut frames = 0_u64;
        match mode.as_str() {
            "cpu" => {
                let duration = std::time::Duration::from_secs_f64(work_seconds);
                while started.elapsed() < duration {
                    let encoded = std::hint::black_box(encoder.encode(std::hint::black_box(&current), false));
                    assert_eq!(encoded.bytes.len(), INSTRUMENTS_EXPECTED_BYTES);
                    std::hint::black_box(&encoded.bytes);
                    frames += 1;
                }
            }
            "allocations" => {
                for _ in 0..5 {
                    let encoded = std::hint::black_box(encoder.encode(std::hint::black_box(&current), false));
                    assert_eq!(encoded.bytes.len(), INSTRUMENTS_EXPECTED_BYTES);
                    std::hint::black_box(&encoded.bytes);
                    frames += 1;
                }
            }
            other => panic!("unknown mode {other}"),
        }
        let elapsed = started.elapsed().as_secs_f64();
        println!(
            "INSTRUMENTS_RESULT revision={} mode={} frames={} elapsed_seconds={:.9} output_bytes={} output_hash={:016x} allocator=production-system counting_allocator=false",
            revision, mode, frames, elapsed, output_bytes, output_hash
        );
        std::io::stdout().flush().expect("flush result");
        // Stay alive beyond an 8s recording that starts two seconds before
        // the trigger. This prevents target exit from truncating equal-duration
        // Time Profiler captures.
        std::thread::sleep(std::time::Duration::from_secs(8));
    }
RUST
}

instrument_tree() {
  local tree=$1
  local probe="$tree/.ansi-instruments-probe.rs"
  probe_source >"$probe"
  python3 - "$tree" "$probe" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
probe = Path(sys.argv[2]).read_text()
render = root / "src/protocol/render_ansi.rs"
text = render.read_text()
marker = "HERDR ANSI INSTRUMENTS PROBE"
if marker in text:
    raise SystemExit("probe marker already present")
index = text.rfind("}")
if index < 0:
    raise SystemExit("test module close not found")
render.write_text(text[:index] + probe + "\n" + text[index:])
PY
  rm "$probe"
}

owns_work_root() {
  [[ -f "$WORK_MARKER" ]] && [[ "$(cat "$WORK_MARKER")" == "$WORK_OWNER" ]]
}

cleanup_worktrees() {
  owns_work_root || fail "refusing to remove unrecognized work root: $WORK_ROOT"
  # Registered paths under our owned root are disposable even if an interrupted
  # git worktree add exited before its in-memory flag was updated.
  if registered "$CANDIDATE_TREE"; then
    git -C "$REPO_ROOT" worktree remove --force "$CANDIDATE_TREE"
  fi
  if registered "$MASTER_TREE"; then
    git -C "$REPO_ROOT" worktree remove --force "$MASTER_TREE"
  fi
  rm -rf "$WORK_ROOT"
  MASTER_ADDED=0
  CANDIDATE_ADDED=0
}

cleanup_on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ -n "$ACTIVE_TRACE_PID" ]]; then kill "$ACTIVE_TRACE_PID" 2>/dev/null || true; wait "$ACTIVE_TRACE_PID" 2>/dev/null || true; fi
  if [[ -n "$ACTIVE_PROBE_PID" ]]; then kill "$ACTIVE_PROBE_PID" 2>/dev/null || true; wait "$ACTIVE_PROBE_PID" 2>/dev/null || true; fi
  if [[ -n "$MARKER" && -f "$MARKER" ]]; then rm -f "${ACTIVE_CONTROL_FILES[@]}" 2>/dev/null || true; fi
  if (( MASTER_ADDED || CANDIDATE_ADDED )) && owns_work_root; then cleanup_worktrees >/dev/null 2>&1 || true; fi
  exit "$rc"
}
trap cleanup_on_exit EXIT INT TERM

create_worktrees() {
  [[ ! -e "$WORK_ROOT" ]] || fail "work root exists; run clean-work after confirming it is disposable: $WORK_ROOT"
  mkdir -p "$WORK_ROOT"
  printf '%s\n' "$WORK_OWNER" >"$WORK_MARKER"
  MASTER_ADDED=1
  git -C "$REPO_ROOT" worktree add --quiet --detach "$MASTER_TREE" "$BASELINE_COMMIT"
  CANDIDATE_ADDED=1
  git -C "$REPO_ROOT" worktree add --quiet --detach "$CANDIDATE_TREE" "$CANDIDATE_COMMIT"
  instrument_tree "$MASTER_TREE"
  instrument_tree "$CANDIDATE_TREE"
}

sanitize_log() {
  python3 - "$1" "$HOME" "$WORK_ROOT" "$REPO_ROOT" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(errors="replace")
for value, replacement in [(sys.argv[3], "<WORK_ROOT>"), (sys.argv[4], "<REPO_ROOT>"), (sys.argv[2], "<HOME>")]:
    text = text.replace(value, replacement)
path.write_text(text)
PY
}

build_one() {
  local revision=$1 tree=$2 commit=$3
  local json="$PROFILE_DIR/raw/build-$revision.jsonl" stderr="$PROFILE_DIR/raw/build-$revision.stderr.log"
  (
    cd "$tree"
    env -u RUSTFLAGS -u HERDR_RENDER_PROF CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=1 \
      CARGO_PROFILE_RELEASE_DEBUG=1 CARGO_TARGET_DIR="$TARGET_ROOT/$revision" \
      HERDR_PROFILE_REVISION="$commit" \
      cargo test --release --locked --bin herdr --no-run --message-format=json
  ) >"$json" 2>"$stderr"
  local executable
  executable=$(python3 - "$json" <<'PY'
import json, sys
found=[]
for line in open(sys.argv[1]):
    try: event=json.loads(line)
    except json.JSONDecodeError: continue
    if event.get("target",{}).get("name")=="herdr" and event.get("profile",{}).get("test") and event.get("executable"):
        found.append(event["executable"])
if not found: raise SystemExit("Herdr test executable missing")
print(found[-1])
PY
)
  cp "$executable" "$PROFILE_DIR/build/$revision-probe"
  chmod 755 "$PROFILE_DIR/build/$revision-probe"
  assert_profile_root_owned
  rm -rf "$PROFILE_DIR/build/$revision-probe.dSYM"
  dsymutil "$PROFILE_DIR/build/$revision-probe" -o "$PROFILE_DIR/build/$revision-probe.dSYM" >"$PROFILE_DIR/raw/dsymutil-$revision.stdout.log" 2>"$PROFILE_DIR/raw/dsymutil-$revision.stderr.log"
  sanitize_log "$json"; sanitize_log "$stderr"
  sanitize_log "$PROFILE_DIR/raw/dsymutil-$revision.stdout.log"; sanitize_log "$PROFILE_DIR/raw/dsymutil-$revision.stderr.log"
}

record_identities() {
  : >"$PROFILE_DIR/binary-identities.tsv"
  printf 'revision\tcommit\tbinary_sha256\tbinary_uuid\tdsym_uuid\tdsym_dwarf_sha256\tbinary_bytes\n' >>"$PROFILE_DIR/binary-identities.tsv"
  local revision commit bin dsym_dwarf binary_uuid dsym_uuid
  for revision in master candidate; do
    [[ "$revision" == master ]] && commit=$BASELINE_COMMIT || commit=$CANDIDATE_COMMIT
    bin="$PROFILE_DIR/build/$revision-probe"
    dsym_dwarf=$(find "$PROFILE_DIR/build/$revision-probe.dSYM/Contents/Resources/DWARF" -type f -maxdepth 1 -print -quit)
    binary_uuid=$(xcrun dwarfdump --uuid "$bin" | awk '{print $2}')
    dsym_uuid=$(xcrun dwarfdump --uuid "$PROFILE_DIR/build/$revision-probe.dSYM" | awk '{print $2}')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$revision" "$commit" "$(sha256 "$bin")" "$binary_uuid" "$dsym_uuid" "$(sha256 "$dsym_dwarf")" "$(stat -f %z "$bin")" >>"$PROFILE_DIR/binary-identities.tsv"
  done
  [[ "$(awk -F '\t' 'NR==2{print $3}' "$PROFILE_DIR/binary-identities.tsv")" != "$(awk -F '\t' 'NR==3{print $3}' "$PROFILE_DIR/binary-identities.tsv")" ]] || fail "revision binaries are not distinct"
}

build_all() {
  snapshot_checkout; verify; prepare_profile_dir; create_worktrees
  build_one master "$MASTER_TREE" "$BASELINE_COMMIT"
  build_one candidate "$CANDIDATE_TREE" "$CANDIDATE_COMMIT"
  record_identities
  cleanup_worktrees
  assert_checkout_unchanged
}

load_snapshot() {
  INITIAL_STATUS_SHA=$(awk -F= '$1=="status_sha"{print $2}' "$PROFILE_DIR/checkout-before.txt" 2>/dev/null || true)
  INITIAL_DIFF_SHA=$(awk -F= '$1=="diff_sha"{print $2}' "$PROFILE_DIR/checkout-before.txt" 2>/dev/null || true)
  INITIAL_REFS_SHA=$(awk -F= '$1=="refs_sha"{print $2}' "$PROFILE_DIR/checkout-before.txt" 2>/dev/null || true)
  if [[ -z "$INITIAL_STATUS_SHA" ]]; then
    snapshot_checkout
    printf 'status_sha=%s\ndiff_sha=%s\nrefs_sha=%s\n' "$INITIAL_STATUS_SHA" "$INITIAL_DIFF_SHA" "$INITIAL_REFS_SHA" >"$PROFILE_DIR/checkout-before.txt"
  fi
}

record_one() {
  local template=$1 mode=$2 revision=$3 time_limit=$4
  local artifact_mode=${5:-$mode} work_seconds=${6:-4}
  local bin="$PROFILE_DIR/build/$revision-probe"
  local control="$PROFILE_DIR/control/$artifact_mode-$revision"
  local ready="$control.ready" trigger="$control.trigger"
  local stdout="$PROFILE_DIR/raw/$artifact_mode-$revision.stdout.log"
  local stderr="$PROFILE_DIR/raw/$artifact_mode-$revision.stderr.log"
  local xcout="$PROFILE_DIR/raw/$artifact_mode-$revision.xctrace.stdout.log"
  local xcerr="$PROFILE_DIR/raw/$artifact_mode-$revision.xctrace.stderr.log"
  local trace="$PROFILE_DIR/$artifact_mode-$revision.trace"
  ACTIVE_CONTROL_FILES=("$ready" "$trigger")
  assert_profile_root_owned
  rm -rf "$trace"; rm -f "$ready" "$trigger" "$stdout" "$stderr" "$xcout" "$xcerr"
  [[ -x "$bin" ]] || fail "missing built probe: $bin"

  env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" LANG="${LANG:-en_US.UTF-8}" \
    HERDR_INSTRUMENTS_MODE="$mode" HERDR_INSTRUMENTS_READY="$ready" \
    HERDR_INSTRUMENTS_TRIGGER="$trigger" HERDR_INSTRUMENTS_WORK_SECONDS="$work_seconds" \
    "$bin" "$TEST_NAME" --ignored --exact --nocapture --test-threads=1 >"$stdout" 2>"$stderr" &
  local probe_pid=$!
  ACTIVE_PROBE_PID=$probe_pid
  for _ in $(seq 1 3000); do [[ -f "$ready" ]] && break; kill -0 "$probe_pid" 2>/dev/null || fail "$revision $mode probe exited before READY"; sleep 0.01; done
  [[ -f "$ready" ]] || fail "$revision $mode READY timeout"
  printf 'template=%s mode=%s artifact=%s revision=%s probe_pid=%s work_seconds=%s pre_load=%s\n' "$template" "$mode" "$artifact_mode" "$revision" "$probe_pid" "$work_seconds" "$(uptime | sed 's/.*load averages: //')" >"$PROFILE_DIR/raw/$artifact_mode-$revision.context.log"

  if [[ "$mode" == allocations ]]; then
    (trap - INT; exec xcrun xctrace record --no-prompt --template "$template" \
      --attach "$probe_pid" --time-limit 7s --output "$trace") >"$xcout" 2>"$xcerr" &
  else
    (trap - INT; exec xcrun xctrace record --no-prompt --template "$template" --attach "$probe_pid" \
      --time-limit "$time_limit" --output "$trace") >"$xcout" 2>"$xcerr" &
  fi
  local trace_pid=$!
  ACTIVE_TRACE_PID=$trace_pid
  sleep 2
  kill -0 "$trace_pid" 2>/dev/null || fail "xctrace exited before trigger for $mode $revision"
  printf 'trigger\n' >"$trigger"
  local trace_rc=0
  wait "$trace_pid" || trace_rc=$?
  if (( trace_rc != 0 )); then
    printf 'xctrace_exit=%s\n' "$trace_rc" >>"$PROFILE_DIR/raw/$artifact_mode-$revision.context.log"
    wait "$probe_pid" || true
    fail "xctrace failed for $mode $revision (exit $trace_rc)"
  fi
  wait "$probe_pid"
  ACTIVE_PROBE_PID=
  ACTIVE_TRACE_PID=
  ACTIVE_CONTROL_FILES=()
  grep -q "output_bytes=$EXPECTED_BYTES output_hash=$EXPECTED_HASH" "$stdout" || fail "oracle missing for $mode $revision"
  grep -q 'allocator=production-system counting_allocator=false' "$stdout" || fail "allocator declaration missing for $mode $revision"
  if [[ "$mode" == allocations ]]; then grep -q 'mode=allocations frames=5 ' "$stdout" || fail "allocation frame count mismatch"; fi
  sanitize_log "$stdout"; sanitize_log "$stderr"; sanitize_log "$xcout"; sanitize_log "$xcerr"; sanitize_log "$PROFILE_DIR/raw/$artifact_mode-$revision.context.log"
}

record_cpu() {
  verify; load_snapshot
  record_one 'Time Profiler' cpu master 8s
  record_one 'Time Profiler' cpu candidate 8s
  assert_checkout_unchanged
}

record_final_cpu() {
  verify; load_snapshot
  # Fourteen seconds of identical post-trigger work exceeds xctrace startup plus
  # the complete eight-second recording window even when attach initialization
  # is slower than the fixed two-second pre-trigger wait. The probe then remains
  # alive for another eight seconds.
  record_one 'Time Profiler' cpu master 8s cpu-final 14
  record_one 'Time Profiler' cpu candidate 8s cpu-final 14
  assert_checkout_unchanged
}

record_allocations() {
  verify; load_snapshot
  record_one 'Allocations' allocations master 7s
  local master_size
  master_size=$(du -sk "$PROFILE_DIR/allocations-master.trace" | awk '{print $1}')
  (( master_size < 5 * 1024 * 1024 )) || fail "master allocation trace exceeded 5 GiB safety limit; stopping before candidate"
  record_one 'Allocations' allocations candidate 7s
  assert_checkout_unchanged
}

export_tocs() {
  verify
  # WARNING: raw TOCs include the target's inherited environment. Export to a
  # private temporary file, project only schema names, then delete the TOC.
  local revision tmp trace_prefix=cpu
  [[ -d "$PROFILE_DIR/cpu-final-master.trace" && -d "$PROFILE_DIR/cpu-final-candidate.trace" ]] && trace_prefix=cpu-final
  printf 'trace\trun\tschema\n' >"$PROFILE_DIR/export/schemas.tsv"
  for revision in master candidate; do
    tmp=$(mktemp "${TMPDIR:-/tmp}/herdr-$trace_prefix-$revision-toc.XXXXXX.xml")
    xcrun xctrace export --input "$PROFILE_DIR/$trace_prefix-$revision.trace" --toc --output "$tmp" >/dev/null
    python3 - "$tmp" "$trace_prefix-$revision" >>"$PROFILE_DIR/export/schemas.tsv" <<'PY'
import sys
import xml.etree.ElementTree as ET
root=ET.parse(sys.argv[1]).getroot()
for run in root.findall('.//run'):
    for table in run.findall('.//table'):
        print(f"{sys.argv[2]}\t{run.get('number','')}\t{table.get('schema','')}")
PY
    rm -f "$tmp"
  done
}

validate() {
  verify; load_snapshot
  local revision trace bin_uuid dsym_uuid
  for revision in master candidate; do
    bin_uuid=$(xcrun dwarfdump --uuid "$PROFILE_DIR/build/$revision-probe" | awk '{print $2}')
    dsym_uuid=$(xcrun dwarfdump --uuid "$PROFILE_DIR/build/$revision-probe.dSYM" | awk '{print $2}')
    [[ "$bin_uuid" == "$dsym_uuid" ]] || fail "$revision binary/dSYM UUID mismatch"
    trace="$PROFILE_DIR/cpu-$revision.trace"
    [[ -d "$trace" ]] || fail "missing $trace"
    grep -q "output_bytes=$EXPECTED_BYTES output_hash=$EXPECTED_HASH" "$PROFILE_DIR/raw/cpu-$revision.stdout.log" || fail "cpu $revision oracle"
    if [[ -f "$PROFILE_DIR/raw/allocations-$revision.xctrace.stderr.log" ]] && \
       grep -q 'Failed to attach to target process' "$PROFILE_DIR/raw/allocations-$revision.xctrace.stderr.log"; then
      printf 'warning: allocation %s trace rejected: attach failure\n' "$revision" >&2
    fi
  done
  [[ "$(awk -F '\t' 'NR==2{print $3}' "$PROFILE_DIR/binary-identities.tsv")" != "$(awk -F '\t' 'NR==3{print $3}' "$PROFILE_DIR/binary-identities.tsv")" ]] || fail "binary hashes equal"
  assert_checkout_unchanged
  {
    printf 'validated=true\n'
    printf 'baseline=%s\ncandidate=%s\ncandidate_parent=%s\n' "$BASELINE_COMMIT" "$CANDIDATE_COMMIT" "$(git -C "$REPO_ROOT" rev-parse "$CANDIDATE_COMMIT^")"
    printf 'expected_bytes=%s\nexpected_hash=%s\n' "$EXPECTED_BYTES" "$EXPECTED_HASH"
    printf 'status_sha=%s\ndiff_sha=%s\nrefs_sha=%s\n' "$(status_sha)" "$(diff_sha)" "$(refs_sha)"
  } >"$PROFILE_DIR/validation.txt"
}

main() {
  case "${1:-}" in
    build) build_all ;;
    cpu) record_cpu ;;
    final-cpu) record_final_cpu ;;
    allocations) record_allocations ;;
    export) export_tocs ;;
    validate) validate ;;
    all) build_all; record_cpu; record_allocations; export_tocs; validate ;;
    clean-work)
      [[ -e "$WORK_ROOT" ]] || { printf 'No work root at %s\n' "$WORK_ROOT"; return; }
      [[ -f "$WORK_MARKER" ]] || fail "refusing to remove unrecognized work root: $WORK_ROOT"
      # clean-work may remove only a root created by this process. A prior run's
      # worktree is deliberately left for explicit manual review.
      owns_work_root || fail "refusing to remove a pre-existing work root"
      cleanup_worktrees
      ;;
    *) usage; exit 2 ;;
  esac
}
main "$@"
