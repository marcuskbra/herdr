#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

readonly BASELINE=06ca0baa12f4203c5bbad9ecadf53f9a475a52b2
readonly CANDIDATE=d00dc4813d6803ce4efa3e9ad7b1c3533512aaff
readonly EXPECTED_BYTES=276444
readonly EXPECTED_HASH=edfa0379543ed13d
readonly TEST_NAME=protocol::render_ansi::tests::ansi_instruments_probe
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$(cd "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)" && pwd -P)"
# shellcheck source=ansi-private-root-safety.sh
source "$SCRIPT_DIR/ansi-private-root-safety.sh"
readonly PRIVATE_ROOT_RAW="${HERDR_ANSI_PRIVATE_ROOT:-}"
PRIVATE_ROOT=
SOURCE=
OUT=
ORIGINAL=
OUT_MARKER=
readonly EXPECTED_MASTER_SHA=bf5fb90b858a069ae8ed0bb5755829973c5a29f2ef1ca40fd7ae6a77deb832d9
readonly EXPECTED_CANDIDATE_SHA=a45a5af7b2c4f584396ac4fed4c6ec8da8833e387872a820e3a4be684ebe36cb

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
status_sha() { git -C "$REPO_ROOT" status --porcelain=v1 -z --untracked-files=all | shasum -a 256 | awk '{print $1}'; }
diff_sha() { git -C "$REPO_ROOT" diff --binary HEAD | shasum -a 256 | awk '{print $1}'; }
refs_sha() { git -C "$REPO_ROOT" show-ref | shasum -a 256 | awk '{print $1}'; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

prepare() {
  [[ -n "$PRIVATE_ROOT_RAW" ]] ||
    fail "HERDR_ANSI_PRIVATE_ROOT must name a directory outside the repository"
  PRIVATE_ROOT=$(ansi_safe_external_root "$REPO_ROOT" "$PRIVATE_ROOT_RAW") ||
    fail "HERDR_ANSI_PRIVATE_ROOT failed canonical path validation"
  SOURCE="$PRIVATE_ROOT/profiles"
  OUT="$SOURCE/retry-after-security-change"
  OUT_MARKER="$OUT/.herdr-ansi-security-retry"
  ORIGINAL="$SOURCE/build"
  [[ "$(uname -s)" == Darwin ]] || fail "native profiling requires macOS"
  ansi_revalidate_external_root "$REPO_ROOT" "$PRIVATE_ROOT" ||
    fail "private root changed before sentinel inspection"
  if [[ -e "$OUT" && ! -f "$OUT_MARKER" ]]; then
    fail "refusing unrecognized retry output directory: $OUT"
  fi
  ansi_revalidate_external_root "$REPO_ROOT" "$PRIVATE_ROOT" ||
    fail "private root changed before retry-directory creation"
  mkdir -p "$OUT"/{build,control,export,raw,traces}
  printf 'owned ANSI security retry artifacts\n' >"$OUT_MARKER"
  [[ "$(sha256 "$ORIGINAL/master-probe")" == "$EXPECTED_MASTER_SHA" ]] || fail "preserved master probe hash changed"
  [[ "$(sha256 "$ORIGINAL/candidate-probe")" == "$EXPECTED_CANDIDATE_SHA" ]] || fail "preserved candidate probe hash changed"
  [[ "$(git -C "$REPO_ROOT" rev-parse "$BASELINE^{commit}")" == "$BASELINE" ]] || fail "baseline mismatch"
  [[ "$(git -C "$REPO_ROOT" rev-parse "$CANDIDATE^{commit}")" == "$CANDIDATE" ]] || fail "candidate mismatch"
  [[ "$(git -C "$REPO_ROOT" rev-parse "$CANDIDATE^")" == "$BASELINE" ]] || fail "candidate parent mismatch"
  [[ "$(xcodebuild -version | tr '\n' ' ')" == "Xcode 26.6 Build version 17F113 " ]] || fail "unexpected Xcode"
  [[ "$(xcrun xctrace version)" == "xctrace version 16.0 (17F113)" ]] || fail "unexpected xctrace"
}

context() {
  prepare
  {
    printf 'captured_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'xcode_select=%s\n' "$(xcode-select -p)"
    xcodebuild -version
    xcrun xctrace version
    DevToolsSecurity -status
    printf 'developer_group_membership='
    if id -Gn | tr ' ' '\n' | grep -Fxq _developer; then printf 'yes\n'; else printf 'no\n'; fi
    csrutil status
    spctl --status
  } >"$OUT/security-context.txt" 2>&1
  {
    printf 'status_sha=%s\n' "$(status_sha)"
    printf 'diff_sha=%s\n' "$(diff_sha)"
    printf 'refs_sha=%s\n' "$(refs_sha)"
    printf 'head=%s\n' "$(git -C "$REPO_ROOT" rev-parse HEAD)"
  } >"$OUT/checkout-before.txt"
  for revision in master candidate; do
    {
      printf 'sha256=%s\n' "$(sha256 "$ORIGINAL/$revision-probe")"
      codesign -dv --verbose=4 "$ORIGINAL/$revision-probe" 2>&1 || true
      printf '\nentitlements:\n'
      codesign -d --entitlements - "$ORIGINAL/$revision-probe" 2>&1 || true
      printf '\nvalidity:\n'
      codesign --verify --verbose=4 "$ORIGINAL/$revision-probe" 2>&1 || true
    } >"$OUT/raw/original-$revision-signature.txt"
  done
}

record_probe() {
  local revision=$1 variant=$2 bin=$3
  local prefix="$variant-$revision"
  local ready="$OUT/control/$prefix.ready" trigger="$OUT/control/$prefix.trigger"
  local trace="$OUT/traces/$prefix.trace"
  local stdout="$OUT/raw/$prefix.probe.stdout.log" stderr="$OUT/raw/$prefix.probe.stderr.log"
  local xcout="$OUT/raw/$prefix.xctrace.stdout.log" xcerr="$OUT/raw/$prefix.xctrace.stderr.log"
  local context="$OUT/raw/$prefix.context.txt"
  ansi_revalidate_external_root "$REPO_ROOT" "$PRIVATE_ROOT" ||
    fail "private root changed before trace replacement"
  [[ -f "$OUT_MARKER" ]] || fail "retry output ownership sentinel is missing"
  rm -rf "$trace"; rm -f "$ready" "$trigger" "$stdout" "$stderr" "$xcout" "$xcerr" "$context"
  [[ -x "$bin" ]] || fail "not executable: $bin"
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" LANG="${LANG:-en_US.UTF-8}" \
    HERDR_INSTRUMENTS_MODE=allocations HERDR_INSTRUMENTS_READY="$ready" \
    HERDR_INSTRUMENTS_TRIGGER="$trigger" HERDR_INSTRUMENTS_WORK_SECONDS=4 \
    "$bin" "$TEST_NAME" --ignored --exact --nocapture --test-threads=1 >"$stdout" 2>"$stderr" &
  local probe_pid=$!
  local ready_seen=no
  for _ in $(seq 1 3000); do
    if [[ -f "$ready" ]]; then ready_seen=yes; break; fi
    if ! kill -0 "$probe_pid" 2>/dev/null; then break; fi
    sleep 0.01
  done
  {
    printf 'revision=%s\nvariant=%s\nprobe_pid=%s\nready=%s\n' "$revision" "$variant" "$probe_pid" "$ready_seen"
    printf 'pre_load=%s\n' "$(uptime | sed 's/.*load averages: //')"
  } >"$context"
  if [[ "$ready_seen" != yes ]]; then
    wait "$probe_pid" || true
    printf 'result=probe_failed_before_ready\n' >>"$context"
    return 1
  fi
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" LANG="${LANG:-en_US.UTF-8}" \
    TMPDIR="${TMPDIR:-/tmp}" xcrun xctrace record --no-prompt --template Allocations \
    --attach "$probe_pid" --time-limit 7s --output "$trace" >"$xcout" 2>"$xcerr" &
  local trace_pid=$!
  sleep 2
  local alive=yes
  kill -0 "$trace_pid" 2>/dev/null || alive=no
  printf 'xctrace_alive_before_trigger=%s\n' "$alive" >>"$context"
  printf 'trigger\n' >"$trigger"
  local xcrc=0 proberc=0
  wait "$trace_pid" || xcrc=$?
  wait "$probe_pid" || proberc=$?
  printf 'xctrace_exit=%s\nprobe_exit=%s\n' "$xcrc" "$proberc" >>"$context"
  if grep -Fq "mode=allocations frames=5 " "$stdout" && \
     grep -Fq "output_bytes=$EXPECTED_BYTES output_hash=$EXPECTED_HASH" "$stdout" && \
     grep -Fq 'allocator=production-system counting_allocator=false' "$stdout"; then
    printf 'probe_protocol=pass\n' >>"$context"
  else
    printf 'probe_protocol=fail\n' >>"$context"
    return 1
  fi
  if (( xcrc != 0 )); then printf 'result=xctrace_failed\n' >>"$context"; return 1; fi
  [[ -d "$trace" ]] || { printf 'result=trace_missing\n' >>"$context"; return 1; }
  printf 'trace_kib=%s\nresult=recorded\n' "$(du -sk "$trace" | awk '{print $1}')" >>"$context"
}

record_original() {
  prepare
  local failures=0
  record_probe master original "$ORIGINAL/master-probe" || failures=$((failures + 1))
  record_probe candidate original "$ORIGINAL/candidate-probe" || failures=$((failures + 1))
  printf 'attempts=2\nfailures=%s\n' "$failures" >"$OUT/original-summary.txt"
  (( failures == 0 ))
}

build_minimal_c() {
  prepare
  cat >"$OUT/build/minimal-attach.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 3) return 64;
    FILE *ready = fopen(argv[1], "w"); if (!ready) return 65;
    fputs("ready\n", ready); fclose(ready);
    while (access(argv[2], F_OK) != 0) usleep(10000);
    void *p = malloc(4096); if (!p) return 66;
    ((volatile unsigned char *)p)[0] = 1;
    puts("MINIMAL_C_RESULT allocations=1 bytes=4096"); fflush(stdout);
    sleep(8); free(p); return 0;
}
C
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" LANG="${LANG:-en_US.UTF-8}" \
    xcrun clang -O2 -g -o "$OUT/build/minimal-attach" "$OUT/build/minimal-attach.c"
  {
    codesign -dv --verbose=4 "$OUT/build/minimal-attach" 2>&1 || true
    printf '\nentitlements:\n'
    codesign -d --entitlements - "$OUT/build/minimal-attach" 2>&1 || true
    printf '\nvalidity:\n'
    codesign --verify --verbose=4 "$OUT/build/minimal-attach" 2>&1 || true
  } >"$OUT/raw/minimal-c-original.signature.txt"
}

record_minimal_c() {
  build_minimal_c
  local prefix=minimal-c-original ready="$OUT/control/minimal-c-original.ready" trigger="$OUT/control/minimal-c-original.trigger"
  local trace="$OUT/traces/minimal-c-original.trace" stdout="$OUT/raw/minimal-c-original.stdout.log" stderr="$OUT/raw/minimal-c-original.stderr.log"
  ansi_revalidate_external_root "$REPO_ROOT" "$PRIVATE_ROOT" ||
    fail "private root changed before control-trace replacement"
  [[ -f "$OUT_MARKER" ]] || fail "retry output ownership sentinel is missing"
  rm -rf "$trace"; rm -f "$ready" "$trigger" "$stdout" "$stderr"
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" LANG="${LANG:-en_US.UTF-8}" \
    "$OUT/build/minimal-attach" "$ready" "$trigger" >"$stdout" 2>"$stderr" &
  local pid=$!
  for _ in $(seq 1 3000); do [[ -f "$ready" ]] && break; kill -0 "$pid" 2>/dev/null || break; sleep .01; done
  [[ -f "$ready" ]] || { wait "$pid" || true; return 1; }
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" LANG="${LANG:-en_US.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" \
    xcrun xctrace record --no-prompt --template Allocations --attach "$pid" --time-limit 7s --output "$trace" \
    >"$OUT/raw/$prefix.xctrace.stdout.log" 2>"$OUT/raw/$prefix.xctrace.stderr.log" &
  local xpid=$!; sleep 2; local alive=yes; kill -0 "$xpid" 2>/dev/null || alive=no
  printf 'trigger\n' >"$trigger"
  local xrc=0 prc=0; wait "$xpid" || xrc=$?; wait "$pid" || prc=$?
  printf 'xctrace_alive_before_trigger=%s\nxctrace_exit=%s\nprobe_exit=%s\n' "$alive" "$xrc" "$prc" >"$OUT/raw/$prefix.context.txt"
  grep -Fq 'MINIMAL_C_RESULT allocations=1 bytes=4096' "$stdout" || return 1
  (( xrc == 0 && prc == 0 )) && [[ -d "$trace" ]]
}

text_hash() {
  python3 - "$1" <<'PY'
import hashlib, subprocess, sys
p=sys.argv[1]
lines=subprocess.check_output(["otool","-l",p], text=True).splitlines()
segment=section=None; offset=size=None
for i,line in enumerate(lines):
    s=line.strip()
    if s.startswith("segname "): segment=s.split(None,1)[1]
    elif s.startswith("sectname "): section=s.split(None,1)[1]
    elif segment=="__TEXT" and section=="__text" and s.startswith("size "): size=int(s.split()[1],0)
    elif segment=="__TEXT" and section=="__text" and s.startswith("offset "):
        offset=int(s.split()[1],0)
        if size is not None: break
if offset is None or size is None: raise SystemExit("__TEXT,__text not found")
with open(p,"rb") as f: f.seek(offset); data=f.read(size)
if len(data)!=size: raise SystemExit("short __text read")
print(f"{offset}\t{size}\t{hashlib.sha256(data).hexdigest()}")
PY
}

sign_copies() {
  prepare
  cat >"$OUT/build/get-task-allow.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
PLIST
  plutil -lint "$OUT/build/get-task-allow.plist" >"$OUT/raw/entitlement-plist-validation.txt"
  printf 'revision\toriginal_sha256\tsigned_sha256\toriginal_text_offset\toriginal_text_bytes\toriginal_text_sha256\tsigned_text_offset\tsigned_text_bytes\tsigned_text_sha256\ttext_equivalent\n' >"$OUT/signing-identities.tsv"
  local revision orig copy ot st equivalent oo os oh so ss sh
  for revision in master candidate; do
    orig="$ORIGINAL/$revision-probe"; copy="$OUT/build/$revision-probe-get-task-allow"
    cp -p "$orig" "$copy"
    codesign --force --sign - --entitlements "$OUT/build/get-task-allow.plist" "$copy" >"$OUT/raw/signed-$revision.codesign.stdout.log" 2>"$OUT/raw/signed-$revision.codesign.stderr.log"
    codesign --verify --verbose=4 "$copy" >"$OUT/raw/signed-$revision.verify.txt" 2>&1
    codesign -d --entitlements - "$copy" >"$OUT/raw/signed-$revision.entitlements.plist" 2>"$OUT/raw/signed-$revision.entitlements.stderr.log"
    codesign -dv --verbose=4 "$copy" >"$OUT/raw/signed-$revision.metadata.txt" 2>&1 || true
    ot=$(text_hash "$orig"); st=$(text_hash "$copy"); equivalent=no
    IFS=$'\t' read -r oo os oh <<<"$ot"
    IFS=$'\t' read -r so ss sh <<<"$st"
    [[ "$os\t$oh" == "$ss\t$sh" ]] && equivalent=yes
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$revision" "$(sha256 "$orig")" "$(sha256 "$copy")" \
      "$oo" "$os" "$oh" "$so" "$ss" "$sh" "$equivalent" >>"$OUT/signing-identities.tsv"
    [[ "$equivalent" == yes ]] || fail "$revision __TEXT,__text changed during signing"
    [[ "$(sha256 "$orig")" == "$([[ "$revision" == master ]] && printf %s "$EXPECTED_MASTER_SHA" || printf %s "$EXPECTED_CANDIDATE_SHA")" ]] || fail "$revision original changed during signing"
  done
}

record_signed() {
  prepare
  [[ -x "$OUT/build/master-probe-get-task-allow" && -x "$OUT/build/candidate-probe-get-task-allow" ]] || fail "run sign-copies first"
  local failures=0
  record_probe master signed "$OUT/build/master-probe-get-task-allow" || failures=$((failures + 1))
  record_probe candidate signed "$OUT/build/candidate-probe-get-task-allow" || failures=$((failures + 1))
  printf 'attempts=2\nfailures=%s\n' "$failures" >"$OUT/signed-summary.txt"
  (( failures == 0 ))
}

tmp_cargo_policy() {
  prepare
  local project
  project=$(mktemp -d /tmp/herdr-security-retry-cargo.XXXXXX)
  cleanup_tmp_cargo() { rm -rf "$project"; }
  trap cleanup_tmp_cargo EXIT
  mkdir -p "$project/src"
  cat >"$project/Cargo.toml" <<'EOF'
[package]
name = "herdr_tmp_exec_policy_probe"
version = "0.0.0"
edition = "2024"
EOF
  cat >"$project/build.rs" <<'EOF'
fn main() {
    let out = std::env::var_os("OUT_DIR").expect("OUT_DIR");
    std::fs::write(std::path::Path::new(&out).join("build-script-ran"), b"ok\n")
        .expect("write build marker");
    println!("cargo:warning=TMP_BUILD_SCRIPT_EXECUTED");
}
EOF
  cat >"$project/src/main.rs" <<'EOF'
fn main() {
    println!("TMP_BINARY_EXECUTED");
}
EOF
  {
    printf 'test=disposable cargo project under /tmp\n'
    printf 'cargo='; cargo --version
    printf 'rustc='; rustc --version
    printf 'temp_created=yes\n'
  } >"$OUT/raw/tmp-cargo-context.txt"
  local build_rc=0 run_rc=125 marker_count=0 build_exe
  (cd "$project" && cargo build --verbose) >"$OUT/raw/tmp-cargo-build.stdout.log" 2>"$OUT/raw/tmp-cargo-build.stderr.log" || build_rc=$?
  marker_count=$(find "$project/target/debug/build" -name build-script-ran -type f 2>/dev/null | wc -l | tr -d ' ')
  printf 'build_exit=%s\nbuild_marker_count=%s\n' "$build_rc" "$marker_count" >>"$OUT/raw/tmp-cargo-context.txt"
  if (( build_rc == 0 )); then
    build_exe=$(find "$project/target/debug/build" -path '*/build-script-build' -type f -perm +111 | head -1)
    {
      printf 'binary:\n'; codesign -dv --verbose=4 "$project/target/debug/herdr_tmp_exec_policy_probe" 2>&1 || true
      printf '\nbuild_script:\n'; codesign -dv --verbose=4 "$build_exe" 2>&1 || true
    } >"$OUT/raw/tmp-cargo-signatures.txt"
    run_rc=0
    "$project/target/debug/herdr_tmp_exec_policy_probe" >"$OUT/raw/tmp-cargo-run.stdout.log" 2>"$OUT/raw/tmp-cargo-run.stderr.log" || run_rc=$?
  else
    : >"$OUT/raw/tmp-cargo-run.stdout.log"; : >"$OUT/raw/tmp-cargo-run.stderr.log"; : >"$OUT/raw/tmp-cargo-signatures.txt"
  fi
  printf 'run_exit=%s\n' "$run_rc" >>"$OUT/raw/tmp-cargo-context.txt"
  grep -Fq TMP_BUILD_SCRIPT_EXECUTED "$OUT/raw/tmp-cargo-build.stderr.log" && printf 'build_script_launch=pass\n' >>"$OUT/raw/tmp-cargo-context.txt" || printf 'build_script_launch=fail\n' >>"$OUT/raw/tmp-cargo-context.txt"
  grep -Fq TMP_BINARY_EXECUTED "$OUT/raw/tmp-cargo-run.stdout.log" && printf 'binary_launch=pass\n' >>"$OUT/raw/tmp-cargo-context.txt" || printf 'binary_launch=fail\n' >>"$OUT/raw/tmp-cargo-context.txt"
  python3 - "$OUT" "$project" <<'PY'
from pathlib import Path
import sys
out=Path(sys.argv[1]); project=sys.argv[2]
for f in out.joinpath('raw').glob('tmp-cargo-*'):
    text=f.read_text(errors='replace').replace('/pri'+'vate'+project, '<TMP_CARGO_PROJECT>').replace(project, '<TMP_CARGO_PROJECT>').replace(str(Path.home()), '<HOME>')
    f.write_text(text)
PY
  cleanup_tmp_cargo; trap - EXIT
  printf 'temp_cleaned=%s\n' "$([[ ! -e "$project" ]] && echo yes || echo no)" >>"$OUT/raw/tmp-cargo-context.txt"
  (( build_rc == 0 && marker_count == 1 && run_rc == 0 ))
}

usage() {
  printf '%s\n' 'usage: performance/ansi-encoder/scripts/ansi-encoder-security-retry.sh {context|record-original|record-minimal-c|sign-copies|record-signed|tmp-cargo-policy}'
}
case "${1:-}" in
  context) context ;;
  record-original) record_original ;;
  record-minimal-c) record_minimal_c ;;
  sign-copies) sign_copies ;;
  record-signed) record_signed ;;
  tmp-cargo-policy) tmp_cargo_policy ;;
  *) usage; exit 2 ;;
esac
