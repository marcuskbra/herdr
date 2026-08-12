#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Focused timing-only rerun that retains every ordered batch latency.
# It uses detached disposable worktrees and never modifies either revision.
readonly BASELINE_COMMIT=06ca0baa12f4203c5bbad9ecadf53f9a475a52b2
readonly CANDIDATE_COMMIT=d00dc4813d6803ce4efa3e9ad7b1c3533512aaff
readonly COOLDOWN_SECONDS=30
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
readonly SOURCE_RUNNER="$SCRIPT_DIR/ansi-encoder-evidence.sh"
readonly RESULTS_DIR="${HERDR_ANSI_OUTPUT:-${TMPDIR:-/tmp}/herdr-ansi-encoder-ecdf-results}"
readonly MARKER="$RESULTS_DIR/.ansi-encoder-ecdf-rerun"
readonly WORK_PARENT="${HERDR_ANSI_WORK_PARENT:-$(dirname "$REPO_ROOT")/herdr-worktrees}"
readonly TEST_NAME='protocol::render_ansi::tests::ansi_evidence_timing'
WORK_ROOT=
MASTER_TREE=
CANDIDATE_TREE=
TARGET_ROOT=
BIN_DIR=
RAW_DIR=

MASTER_ADDED=0
CANDIDATE_ADDED=0
INITIAL_STATUS_SHA=
INITIAL_DIFF_SHA=
INITIAL_UNTRACKED_SHA=
INITIAL_REFS_SHA=

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
sha_stream() { shasum -a 256 | awk '{print $1}'; }
status_sha() { git -C "$REPO_ROOT" status --porcelain=v1 -z --untracked-files=all | sha_stream; }
diff_sha() { git -C "$REPO_ROOT" diff --binary HEAD | sha_stream; }
refs_sha() { git -C "$REPO_ROOT" show-ref | sha_stream; }
untracked_sha() {
  python3 - "$REPO_ROOT" <<'PY' | sha_stream
from pathlib import Path
import hashlib, subprocess, sys
root = Path(sys.argv[1])
names = subprocess.check_output(["git", "-C", str(root), "ls-files", "-o", "--exclude-standard", "-z"]).decode().split("\0")
for name in sorted(filter(None, names)):
    path = root / name
    print(name)
    print(hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "non-file")
PY
}
worktree_registered() { git -C "$REPO_ROOT" worktree list --porcelain | grep -Fqx "worktree $1"; }
initialize_paths() {
  mkdir -p "$WORK_PARENT"
  WORK_ROOT=$(mktemp -d "$WORK_PARENT/ansi-encoder-ecdf.XXXXXX")
  MASTER_TREE="$WORK_ROOT/master"
  CANDIDATE_TREE="$WORK_ROOT/candidate"
  TARGET_ROOT="$WORK_ROOT/targets"
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

usage() {
  cat <<'EOF'
Usage: performance/ansi-encoder/scripts/ansi-encoder-ecdf-rerun.sh run

Runs only the fixed six-process ANSI timing protocol and retains all 2,400
ordered batch values under HERDR_ANSI_OUTPUT, or under the default marked
system-temporary output directory. Existing curated public results are never
modified.
EOF
}

verify_preconditions() {
  [[ "$(uname -s)" == Darwin ]] || fail "fixed environment recorder expects macOS"
  [[ -f "$SOURCE_RUNNER" ]] || fail "validated fixture source runner missing"
  local baseline candidate parent parents ahead
  baseline=$(git -C "$REPO_ROOT" rev-parse --verify "$BASELINE_COMMIT^{commit}")
  candidate=$(git -C "$REPO_ROOT" rev-parse --verify "$CANDIDATE_COMMIT^{commit}")
  parent=$(git -C "$REPO_ROOT" rev-parse --verify "$CANDIDATE_COMMIT^")
  parents=$(git -C "$REPO_ROOT" show -s --format=%P "$CANDIDATE_COMMIT")
  ahead=$(git -C "$REPO_ROOT" rev-list --count "$BASELINE_COMMIT..$CANDIDATE_COMMIT")
  [[ "$baseline" == "$BASELINE_COMMIT" && "$candidate" == "$CANDIDATE_COMMIT" ]] || fail "revision resolution mismatch"
  [[ "$parent" == "$BASELINE_COMMIT" && "$parents" == "$BASELINE_COMMIT" && "$ahead" == 1 ]] || fail "candidate is not a one-parent, one-commit child of baseline"
  for process in Instruments samply perf; do
    if pgrep -x "$process" >/dev/null 2>&1; then fail "profiler process $process is running"; fi
  done
}

prepare_results() {
  if [[ -e "$RESULTS_DIR" ]]; then
    [[ -f "$MARKER" ]] || fail "refusing to replace unrecognized ECDF directory"
    rm -rf "$RESULTS_DIR"
  fi
  mkdir -p "$RAW_DIR"
  printf 'fixed ANSI encoder ordered timing rerun\n' >"$MARKER"
  printf 'utc\tphase\tkey\tload_1m\tload_5m\tload_15m\n' >"$RESULTS_DIR/loads.tsv"
}

# Reuse the already-validated workload/oracle fixture verbatim, retain only its
# timing portion, and replace only the summary block so ordered samples survive.
probe_source() {
  python3 - "$SOURCE_RUNNER" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
start = text.index("    // HERDR ANSI ENCODER EVIDENCE PROBES")
end = text.index("    #[cfg(feature = \"test-allocation-counting\")]", start)
probe = text[start:end]
old = '''            samples.sort_unstable();
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
'''
new = '''            let ordered_samples = samples;
            let mut sorted_samples = ordered_samples.clone();
            sorted_samples.sort_unstable();
            let ordered_ns = ordered_samples
                .iter()
                .map(u128::to_string)
                .collect::<Vec<_>>()
                .join(",");
            println!("EVIDENCE_TIMING_SAMPLES workload={} ordered_ns={}", workload.name, ordered_ns);
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
                sorted_samples[0],
                sorted_samples[sorted_samples.len() / 2],
                sorted_samples[sorted_samples.len() - 1],
                output_bytes,
                output_hash,
                workload.expected_full,
            );
'''
if probe.count(old) != 1:
    raise SystemExit("validated timing summary block not found exactly once")
print(probe.replace(old, new), end="")
PY
}

instrument_tree() {
  local tree=$1
  local probe="$tree/.ecdf-probe.rs"
  probe_source >"$probe"
  python3 - "$tree" "$probe" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
probe = Path(sys.argv[2]).read_text()
render = root / "src/protocol/render_ansi.rs"
text = render.read_text()
if "HERDR ANSI ENCODER EVIDENCE PROBES" in text:
    raise SystemExit("probe marker already present")
index = text.rfind("}")
if index < 0:
    raise SystemExit("test module closing brace not found")
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
    printf 'source_runner_sha256=%s\n' "$(shasum -a 256 "$SOURCE_RUNNER" | awk '{print $1}')"
    printf 'ordered_probe_sha256=%s\n' "$(probe_source | sha_stream)"
  } >"$RESULTS_DIR/refs.txt"
}

build_binary() {
  local revision=$1 tree=$2 destination=$3 json_log=$4 stderr_log=$5
  (
    cd "$tree"
    env -u HERDR_RENDER_PROF -u RUSTFLAGS -u CARGO_PROFILE_RELEASE_DEBUG -u MallocStackLogging -u MallocStackLoggingNoCompact \
      CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=1 CARGO_TARGET_DIR="$TARGET_ROOT/$revision" \
      cargo test --release --locked --bin herdr --no-run --message-format=json
  ) >"$json_log" 2>"$stderr_log"
  local executable
  executable=$(python3 - "$json_log" <<'PY'
import json, sys
found = []
for line in open(sys.argv[1]):
    try: event = json.loads(line)
    except json.JSONDecodeError: continue
    if event.get("target", {}).get("name") == "herdr" and event.get("profile", {}).get("test") and event.get("executable"):
        found.append(event["executable"])
if not found: raise SystemExit("Herdr test executable not found")
print(found[-1])
PY
)
  mkdir -p "$BIN_DIR"
  cp "$executable" "$destination"
  chmod 755 "$destination"
  python3 - "$json_log" "$stderr_log" "$HOME" "$WORK_ROOT" "$REPO_ROOT" <<'PY'
from pathlib import Path
import sys
for name in sys.argv[1:3]:
    path = Path(name); text = path.read_text()
    for value, replacement in [(sys.argv[4], "<WORK_ROOT>"), (sys.argv[5], "<REPO_ROOT>"), (sys.argv[3], "<HOME>")]:
        text = text.replace(value, replacement)
    path.write_text(text)
PY
  printf '%s\tproduction\t%s\n' "$revision" "$(shasum -a 256 "$destination" | awk '{print $1}')" >>"$RESULTS_DIR/binaries.tsv"
}

record_environment() {
  python3 - "$RESULTS_DIR/environment.json" <<'PY'
import json, platform, subprocess, sys
def out(*args): return subprocess.check_output(args, text=True).strip()
def sysctl(name): return out("sysctl", "-n", name)
sw = dict(line.split(":", 1) for line in out("sw_vers").splitlines())
env = {
  "cpu_model": sysctl("machdep.cpu.brand_string"), "logical_cores": int(sysctl("hw.ncpu")),
  "memory_bytes": int(sysctl("hw.memsize")), "architecture": platform.machine(),
  "macos_version": sw["ProductVersion"].strip(), "macos_build": sw["BuildVersion"].strip(),
  "rustc_version": out("rustc", "--version"), "cargo_version": out("cargo", "--version"),
  "build": {"cargo": "cargo test --release --locked --bin herdr --no-run", "incremental": False, "jobs": 1, "isolated_target_per_revision": True},
  "timing_allocator": "production allocator; test-allocation-counting feature disabled",
  "profiler": "none; known profiler processes rejected and HERDR_RENDER_PROF unset"
}
with open(sys.argv[1], "w") as f: json.dump(env, f, indent=2); f.write("\n")
PY
}

record_load() {
  local key=$1 raw
  raw=$(sysctl -n vm.loadavg)
  python3 - "$RESULTS_DIR/loads.tsv" "$key" "$raw" <<'PY'
from datetime import datetime, timezone
import re, sys
values = re.findall(r"[0-9]+(?:\.[0-9]+)?", sys.argv[3])
if len(values) != 3: raise SystemExit("unexpected load average")
with open(sys.argv[1], "a") as f: f.write("\t".join([datetime.now(timezone.utc).isoformat(), "timing", sys.argv[2], *values]) + "\n")
PY
}

run_timing() {
  local -a order=(master candidate candidate master master candidate)
  local index round side revision key
  for index in "${!order[@]}"; do
    round=$((index / 2 + 1)); side=$((index % 2 + 1)); revision=${order[$index]}
    key="round${round}-side${side}-${revision}"
    printf 'cooldown key=%s seconds=%s\n' "$key" "$COOLDOWN_SECONDS"
    sleep "$COOLDOWN_SECONDS"
    record_load "$key"
    env -u HERDR_RENDER_PROF -u RUSTFLAGS -u CARGO_PROFILE_RELEASE_DEBUG -u MallocStackLogging -u MallocStackLoggingNoCompact \
      "$BIN_DIR/$revision-production" "$TEST_NAME" --ignored --exact --nocapture --test-threads=1 \
      >"$RAW_DIR/timing-$key.log" 2>&1
  done
}

write_protocol() {
  cat >"$RESULTS_DIR/protocol.md" <<EOF
# Focused Ordered-Batch Timing Protocol

Fixed baseline: \`$BASELINE_COMMIT\`. Fixed candidate: \`$CANDIDATE_COMMIT\`,
whose sole parent is the baseline. This timing-only rerun injects the validated
200x50 workload/oracle fixture into detached disposable worktrees. It builds
release test binaries with isolated Cargo targets, no features, no profiler and
the production allocator. Different binary SHA-256 hashes are required.

Each process runs dense_colour, plain_scroll, sparse_edit and full_redraw, with
20 warm-ups then 100 ordered batches of 10 encodes. The order is
master/candidate, candidate/master, master/candidate. Every fresh process has an
exact 30-second cooldown, followed by a recorded load average. Output bytes and
FNV-1a hashes must match across every process and revision.

All 2 revisions x 3 processes x 4 workloads x 100 batches = 2,400 ordered batch
values are retained in \`ordered-batches.json\` and \`ordered-batches.tsv\`.
Batches are repeated observations within a process; the process is the
replication unit. They must not be pooled as 300 independent runs/revision.
EOF
}

generate_results() {
  python3 - "$RESULTS_DIR" "$REPO_ROOT/performance/ansi-encoder/data/results.json" <<'PY'
from collections import defaultdict
from pathlib import Path
import csv, hashlib, json, math, re, statistics, sys
root, prior_path = Path(sys.argv[1]), Path(sys.argv[2])
raw = root / "raw"
workloads = ["dense_colour", "plain_scroll", "sparse_edit", "full_redraw"]
specs = [(1,1,"master"),(1,2,"candidate"),(2,1,"candidate"),(2,2,"master"),(3,1,"master"),(3,2,"candidate")]
def fields(line): return dict(re.findall(r"([a-z_]+)=([^ ]+)", line))
processes, rows = [], []
for round_no, side, revision in specs:
    path = raw / f"timing-round{round_no}-side{side}-{revision}.log"
    lines = path.read_text().splitlines()
    vectors = [fields(x.split("EVIDENCE_TIMING_SAMPLES ",1)[1]) for x in lines if "EVIDENCE_TIMING_SAMPLES " in x]
    summaries = [fields(x.split("EVIDENCE_TIMING ",1)[1]) for x in lines if "EVIDENCE_TIMING " in x and "EVIDENCE_TIMING_SAMPLES " not in x]
    if len(vectors) != 4 or len(summaries) != 4: raise SystemExit(f"{path.name}: expected four vectors and summaries")
    if [x["workload"] for x in vectors] != workloads or [x["workload"] for x in summaries] != workloads: raise SystemExit("workload order drift")
    for vector, summary in zip(vectors, summaries):
        samples = [int(x) for x in vector["ordered_ns"].split(",")]
        if len(samples) != 100: raise SystemExit("ordered vector count drift")
        sorted_samples = sorted(samples)
        expected = (sorted_samples[0], sorted_samples[50], sorted_samples[-1])
        actual = tuple(int(summary[k]) for k in ("min_ns","median_ns","max_ns"))
        if expected != actual: raise SystemExit("summary does not reproduce ordered values")
        if (int(summary["width"]),int(summary["height"]),int(summary["warmups"]),int(summary["frames_per_sample"]),int(summary["samples"])) != (200,50,20,10,100): raise SystemExit("protocol drift")
        if summary["counting_allocator"] != "false": raise SystemExit("non-production allocator")
        item = {"capture_id": f"r{round_no}s{side}-{revision}-{vector['workload']}", "round": round_no, "side": side, "revision": revision, "workload": vector["workload"], "ordered_batch_ns": samples, "min_ns": actual[0], "median_ns": actual[1], "max_ns": actual[2], "output_bytes": int(summary["output_bytes"]), "output_hash": summary["output_hash"], "full": summary["full"] == "true"}
        processes.append(item)
        for batch_index, value in enumerate(samples, 1): rows.append({"revision":revision,"round":round_no,"side":side,"workload":vector["workload"],"batch_index":batch_index,"latency_ns":value})
if len(processes) != 24 or len(rows) != 2400: raise SystemExit("total count mismatch")
for workload in workloads:
    outputs = {(x["output_bytes"],x["output_hash"],x["full"]) for x in processes if x["workload"] == workload}
    if len(outputs) != 1: raise SystemExit(f"output mismatch: {workload}")
aggregates=[]
prior=json.loads(prior_path.read_text())
for workload in workloads:
    entry={"workload":workload}
    for revision in ("master","candidate"):
        vals=[x["median_ns"] for x in processes if x["workload"]==workload and x["revision"]==revision]
        if len(vals)!=3: raise SystemExit("process count mismatch")
        entry[revision]={"process_medians_ns":vals,"median_of_process_medians_ns":sorted(vals)[1]}
    m,c=entry["master"]["median_of_process_medians_ns"],entry["candidate"]["median_of_process_medians_ns"]
    entry["time_reduction_percent"]=(1-c/m)*100; entry["speedup"]=m/c
    old=next(x for x in prior["timing_aggregates"] if x["workload"]==workload)
    entry["drift_vs_prior_percent"]={r:(entry[r]["median_of_process_medians_ns"]/old[r]["median_of_process_medians_ns"]-1)*100 for r in ("master","candidate")}
    aggregates.append(entry)
loads=[]
for line in (root/"loads.tsv").read_text().splitlines()[1:]:
    utc,phase,key,one,five,fifteen=line.split("\t"); loads.append({"utc":utc,"phase":phase,"key":key,"load_1m":float(one),"load_5m":float(five),"load_15m":float(fifteen)})
if len(loads)!=6: raise SystemExit("load record count mismatch")
result={"schema_version":1,"capture":"ansi-encoder-ecdf-rerun","revisions":{"master":"06ca0baa12f4203c5bbad9ecadf53f9a475a52b2","candidate":"d00dc4813d6803ce4efa3e9ad7b1c3533512aaff"},"protocol":{"dimensions":[200,50],"warmups":20,"batches_per_process":100,"encodes_per_batch":10,"processes_per_revision":3,"order":["master/candidate","candidate/master","master/candidate"],"cooldown_seconds":30,"replication_unit":"process"},"processes":processes,"aggregates":aggregates,"pre_process_loads":loads,"validation":{"ordered_batch_values":2400,"output_equivalence":True,"production_allocator":True,"summary_arithmetic":True}}
(root/"ordered-batches.json").write_text(json.dumps(result,indent=2)+"\n")
with open(root/"ordered-batches.tsv","w",newline="") as f:
    writer=csv.DictWriter(f,fieldnames=["revision","round","side","workload","batch_index","latency_ns"],delimiter="\t"); writer.writeheader(); writer.writerows(rows)
(root/"capture.sha256").write_text(f"{hashlib.sha256((root/'ordered-batches.json').read_bytes()).hexdigest()}  ordered-batches.json\n{hashlib.sha256((root/'ordered-batches.tsv').read_bytes()).hexdigest()}  ordered-batches.tsv\n")
report=["# Ordered-Batch ECDF Rerun","","This focused rerun supplements, and does not replace, the earlier validated headline results.","","| Workload | Master process medians (ns) | Candidate process medians (ns) | New master MoM | New candidate MoM | Master drift | Candidate drift |","|---|---:|---:|---:|---:|---:|---:|"]
for a in aggregates:
    report.append(f"| {a['workload']} | {', '.join(f'{x:,}' for x in a['master']['process_medians_ns'])} | {', '.join(f'{x:,}' for x in a['candidate']['process_medians_ns'])} | {a['master']['median_of_process_medians_ns']:,} | {a['candidate']['median_of_process_medians_ns']:,} | {a['drift_vs_prior_percent']['master']:+.2f}% | {a['drift_vs_prior_percent']['candidate']:+.2f}% |")
report += ["","The 100 batches per line are ordered within-process observations. They expose distribution shape and tails, but are not independent process replications and are not pooled for inference.",""]
(root/"report.md").write_text("\n".join(report))
PY
}

final_validation() {
  local final_status final_diff final_untracked final_refs
  final_status=$(status_sha); final_diff=$(diff_sha); final_untracked=$(untracked_sha); final_refs=$(refs_sha)
  local master_hash candidate_hash
  master_hash=$(awk -F '\t' '$1=="master"{print $3}' "$RESULTS_DIR/binaries.tsv")
  candidate_hash=$(awk -F '\t' '$1=="candidate"{print $3}' "$RESULTS_DIR/binaries.tsv")
  [[ -n "$master_hash" && -n "$candidate_hash" && "$master_hash" != "$candidate_hash" ]] || fail "production binary hashes are not distinct"
  [[ "$INITIAL_STATUS_SHA" == "$final_status" && "$INITIAL_DIFF_SHA" == "$final_diff" && "$INITIAL_UNTRACKED_SHA" == "$final_untracked" && "$INITIAL_REFS_SHA" == "$final_refs" ]] || fail "checkout or refs changed"
  ! grep -R -E '/(home|Users)/[^/<]+/' "$RESULTS_DIR" --exclude='validation.txt' >/dev/null || fail "private path or identity found"
  {
    printf 'shell_syntax=pass\nfixed_refs_and_parent=pass\nprofiler_absent=pass\nproduction_allocator=pass\ndistinct_binary_hashes=pass\n'
    printf 'ordered_batch_count=2400=pass\nprocess_count=24=pass\nload_count=6=pass\nsummary_arithmetic=pass\noutput_equivalence=pass\nprivacy_scan=pass\n'
    printf 'main_status_before_sha256=%s\nmain_status_after_sha256=%s\n' "$INITIAL_STATUS_SHA" "$final_status"
    printf 'tracked_diff_before_sha256=%s\ntracked_diff_after_sha256=%s\n' "$INITIAL_DIFF_SHA" "$final_diff"
    printf 'untracked_before_sha256=%s\nuntracked_after_sha256=%s\n' "$INITIAL_UNTRACKED_SHA" "$final_untracked"
    printf 'refs_before_sha256=%s\nrefs_after_sha256=%s\n' "$INITIAL_REFS_SHA" "$final_refs"
    printf 'disposable_worktrees_removed=pass\nrepository_unchanged=pass\n'
  } >"$RESULTS_DIR/validation.txt"
}

run() {
  bash -n "$0"
  verify_preconditions
  initialize_paths
  INITIAL_STATUS_SHA=$(status_sha); INITIAL_DIFF_SHA=$(diff_sha); INITIAL_UNTRACKED_SHA=$(untracked_sha); INITIAL_REFS_SHA=$(refs_sha)
  prepare_results; record_environment; write_protocol; create_worktrees
  printf 'revision\tallocator_build\tsha256\n' >"$RESULTS_DIR/binaries.tsv"
  printf 'Building two production release binaries...\n'
  build_binary master "$MASTER_TREE" "$BIN_DIR/master-production" "$RAW_DIR/build-master.jsonl" "$RAW_DIR/build-master.stderr.log"
  build_binary candidate "$CANDIDATE_TREE" "$BIN_DIR/candidate-production" "$RAW_DIR/build-candidate.jsonl" "$RAW_DIR/build-candidate.stderr.log"
  [[ "$(shasum -a 256 "$BIN_DIR/master-production" | awk '{print $1}')" != "$(shasum -a 256 "$BIN_DIR/candidate-production" | awk '{print $1}')" ]] || fail "identical binaries"
  printf 'Running six counterbalanced timing processes...\n'
  run_timing
  generate_results
  git -C "$REPO_ROOT" worktree remove --force "$CANDIDATE_TREE"; CANDIDATE_ADDED=0
  git -C "$REPO_ROOT" worktree remove --force "$MASTER_TREE"; MASTER_ADDED=0
  rm -rf "$WORK_ROOT"; git -C "$REPO_ROOT" worktree prune
  final_validation
  printf 'Complete: %s\n' "$RESULTS_DIR/report.md"
}

case "${1:-}" in
  run) run ;;
  -h|--help|help|'') usage ;;
  *) usage >&2; fail "unknown command: $1" ;;
esac
