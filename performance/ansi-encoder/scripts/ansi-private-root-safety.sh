#!/usr/bin/env bash
# Shared fail-closed validation for paths that may receive private native data.
# Successful stdout is exactly one validated physical path plus one LF separator.

ansi_safe_external_root() {
  local repo_root=${1-} candidate=${2-}
  python3 - "$repo_root" "$candidate" <<'PY'
from __future__ import annotations

import os
from pathlib import Path
import stat
import subprocess
import sys


def reject(message: str) -> None:
    raise SystemExit(f"unsafe external root: {message}")


def require_transport_safe(label: str, value: str) -> None:
    # Command substitution removes trailing LF bytes. Reject every Unicode
    # control character before path comparison so its output remains lossless.
    if not value:
        reject(f"{label} is empty")
    if any(not character.isprintable() for character in value):
        reject(f"{label} contains a control or non-printable character")


def physical_identity(path: Path) -> tuple[int, int]:
    try:
        info = path.stat()
    except OSError as error:
        reject(f"cannot inspect filesystem identity: {error}")
    return info.st_dev, info.st_ino


def identity_ancestors(path: Path) -> set[tuple[int, int]]:
    identities: set[tuple[int, int]] = set()
    current = path
    while True:
        identities.add(physical_identity(current))
        if current == Path(current.anchor):
            return identities
        current = current.parent


def resolve_existing_directory(label: str, value: str) -> Path:
    require_transport_safe(label, value)
    try:
        path = Path(value).resolve(strict=True)
    except (OSError, RuntimeError) as error:
        reject(f"{label} cannot be resolved: {error}")
    require_transport_safe(f"physical {label}", os.fspath(path))
    if not path.is_dir():
        reject(f"{label} is not a directory")
    return path


def lexical_absolute(value: str) -> tuple[Path, list[str]]:
    expanded = os.path.expanduser(value)
    require_transport_safe("expanded requested root", expanded)
    combined = expanded if os.path.isabs(expanded) else os.path.join(os.getcwd(), expanded)
    drive, tail = os.path.splitdrive(combined)
    anchor = drive + os.sep
    parts: list[str] = []
    for part in tail.split(os.sep):
        if part in ("", "."):
            continue
        require_transport_safe("requested path component", part)
        if part == "..":
            if not parts:
                reject("requested path escapes the filesystem root")
            parts.pop()
        else:
            parts.append(part)
    return Path(anchor), parts


def inspect_candidate(anchor: Path, parts: list[str]) -> tuple[Path, list[str]]:
    current = anchor
    missing: list[str] = []
    for index, part in enumerate(parts):
        next_path = current / part
        try:
            info = next_path.lstat()
        except FileNotFoundError:
            missing = parts[index:]
            break
        except OSError as error:
            reject(f"cannot inspect requested path: {error}")
        if stat.S_ISLNK(info.st_mode):
            reject("requested path traverses a symlink")
        if index < len(parts) - 1 and not stat.S_ISDIR(info.st_mode):
            reject("requested path traverses a non-directory")
        current = next_path
    if not missing:
        try:
            info = current.lstat()
        except OSError as error:
            reject(f"cannot inspect requested root: {error}")
        if stat.S_ISLNK(info.st_mode):
            reject("requested root is a symlink")
        if not stat.S_ISDIR(info.st_mode):
            reject("requested root is not a directory")
    elif not current.is_dir():
        reject("nearest existing ancestor is not a directory")
    try:
        physical = current.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        reject(f"nearest existing ancestor cannot be resolved: {error}")
    require_transport_safe("physical existing ancestor", os.fspath(physical))
    for part in missing:
        require_transport_safe("reconstructed path component", part)
        if part in ("", ".", "..") or os.sep in part:
            reject("non-existing suffix is not a plain path component")
    return physical, missing


if len(sys.argv) != 3:
    reject("expected repository root and requested root")
repo_input, candidate_input = sys.argv[1:]
require_transport_safe("repository root", repo_input)
require_transport_safe("requested root", candidate_input)
repo = resolve_existing_directory("repository root", repo_input)

try:
    output = subprocess.check_output(
        ["git", "-C", os.fspath(repo), "worktree", "list", "--porcelain", "-z"],
        stderr=subprocess.DEVNULL,
    ).decode("utf-8")
except (OSError, UnicodeDecodeError, subprocess.CalledProcessError) as error:
    reject(f"Git worktrees cannot be enumerated: {error}")
protected = [repo]
for record in output.split("\0"):
    if not record.startswith("worktree "):
        continue
    worktree_text = record.removeprefix("worktree ")
    protected.append(resolve_existing_directory("registered worktree", worktree_text))

anchor, parts = lexical_absolute(candidate_input)
if not parts:
    reject("filesystem root is not allowed")
ancestor, missing = inspect_candidate(anchor, parts)
candidate = ancestor.joinpath(*missing)
require_transport_safe("validated requested root", os.fspath(candidate))

ancestor_chain = identity_ancestors(ancestor)
ancestor_identity = physical_identity(ancestor)
for protected_root in protected:
    protected_chain = identity_ancestors(protected_root)
    protected_identity = physical_identity(protected_root)
    # Use samefile as well as explicit device/inode ancestry. This detects
    # case-folded, Unicode-normalized, hardlink and mount aliases without
    # trusting the spelling returned by realpath.
    try:
        equal = os.path.samefile(ancestor, protected_root)
    except OSError as error:
        reject(f"cannot compare filesystem identity: {error}")
    if equal or protected_identity in ancestor_chain:
        reject("path is a Git worktree or is inside one")
    if ancestor_identity in protected_chain:
        reject("path would contain a Git worktree")

sys.stdout.write(os.fspath(candidate) + "\n")
PY
}

# Re-resolve immediately before mkdir/write/rm and require identity with the
# earlier captured value. This narrows, but cannot eliminate, filesystem TOCTOU.
ansi_revalidate_external_root() {
  local repo_root=${1-} expected=${2-} captured
  captured=$(ansi_safe_external_root "$repo_root" "$expected") || return
  python3 - "$expected" "$captured" <<'PY' || {
import os
from pathlib import Path
import sys


def existing_ancestor(value: str) -> tuple[Path, list[str]]:
    path = Path(value)
    suffix: list[str] = []
    while True:
        try:
            path.lstat()
            return path, list(reversed(suffix))
        except FileNotFoundError:
            suffix.append(path.name)
            path = path.parent


expected, captured = sys.argv[1:]
expected_ancestor, expected_suffix = existing_ancestor(expected)
captured_ancestor, captured_suffix = existing_ancestor(captured)
if expected_suffix != captured_suffix or not os.path.samefile(expected_ancestor, captured_ancestor):
    raise SystemExit(1)
PY
    printf 'unsafe external root: filesystem identity changed before operation\n' >&2
    return 1
  }
}

ansi_private_root_safety_self_test() {
  local script_dir repo tmp outside relative captured unsafe registered worktree rc=0 created
  local parent repo_name alternate_case unicode_name unicode_alias consumer_repo consumer_alias
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
  repo=$(cd "$(git -C "$script_dir" rev-parse --show-toplevel)" && pwd -P)
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/herdr-ansi-path-safety.XXXXXX")
  tmp=$(python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve(strict=True))
PY
)
  trap 'rm -rf "$tmp"' RETURN
  outside="$tmp/outside space-雪"
  mkdir -p "$outside"

  captured=$(ansi_safe_external_root "$repo" "$outside") || rc=1
  [[ "$captured" == "$outside" ]] || rc=1
  ansi_safe_external_root "$repo" "$tmp/new/nested/root" >/dev/null || rc=1
  relative=$(python3 - "$PWD" "$outside" <<'PY'
import os, sys
print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
)
  captured=$(ansi_safe_external_root "$repo" "$relative") || rc=1
  [[ "$captured" == "$outside" ]] || rc=1

  for unsafe in \
    "/" "$repo" "$repo/../$(basename "$repo")/private" "$repo/.." \
    "$repo/nonexistent/private" \
    $'\n'"$outside" "$outside"$'\n' "$tmp/out"$'\n'"side" \
    "$outside"$'\n\n' "$outside"$'\r' "$outside"$'\t' "$outside"$'\001' \
    "$repo"$'\n'; do
    created="$tmp/side-effect-$RANDOM"
    if captured=$(ansi_safe_external_root "$repo" "$unsafe" 2>/dev/null); then
      mkdir -p "$created"
      rc=1
    fi
    [[ ! -e "$created" ]] || rc=1
  done

  registered=$(git -C "$repo" worktree list --porcelain | awk '/^worktree /{sub(/^worktree /, ""); print}')
  while IFS= read -r worktree; do
    [[ -z "$worktree" ]] && continue
    if captured=$(ansi_safe_external_root "$repo" "$worktree" 2>/dev/null); then rc=1; fi
  done <<<"$registered"

  ln -s "$repo" "$tmp/repo-link"
  if captured=$(ansi_safe_external_root "$repo" "$tmp/repo-link/private" 2>/dev/null); then rc=1; fi
  ln -s "$outside" "$tmp/outside-link"
  if captured=$(ansi_safe_external_root "$repo" "$tmp/outside-link/private" 2>/dev/null); then rc=1; fi
  control_component="control"$'\n'"component"
  mkdir "$tmp/$control_component"
  if captured=$(ansi_safe_external_root "$repo" "$tmp/$control_component" 2>/dev/null); then rc=1; fi
  ln -s "$tmp/$control_component" "$tmp/control-link"
  if captured=$(ansi_safe_external_root "$repo" "$tmp/control-link" 2>/dev/null); then rc=1; fi

  parent=$(dirname "$repo")
  repo_name=$(basename "$repo")
  alternate_case=$(printf '%s' "$repo_name" | tr '[:lower:][:upper:]' '[:upper:][:lower:]')
  if [[ "$alternate_case" != "$repo_name" && -d "$parent/$alternate_case" ]]; then
    if captured=$(ansi_safe_external_root "$repo" "$parent/$alternate_case/nonexistent-private" 2>/dev/null); then rc=1; fi
  fi

  consumer_repo="$tmp/ConsumerRepo"
  mkdir -p "$consumer_repo/performance/ansi-encoder/scripts"
  git -C "$consumer_repo" init -q
  cp "$script_dir/ansi-private-root-safety.sh" "$consumer_repo/performance/ansi-encoder/scripts/"
  cp "$script_dir/ansi-encoder-security-retry.sh" "$consumer_repo/performance/ansi-encoder/scripts/"
  consumer_alias="$tmp/consumerrepo"
  if [[ -d "$consumer_alias" ]]; then
    HERDR_ANSI_PRIVATE_ROOT="$consumer_alias/private-capture" \
      bash "$consumer_repo/performance/ansi-encoder/scripts/ansi-encoder-security-retry.sh" context \
      >/dev/null 2>&1 && rc=1
    [[ ! -e "$consumer_repo/private-capture" ]] || rc=1
  fi

  unicode_name="ansi-é-alias"
  unicode_alias=$(python3 - "$unicode_name" <<'PY'
import sys, unicodedata
print(unicodedata.normalize("NFD", sys.argv[1]))
PY
)
  mkdir "$tmp/$unicode_name"
  if [[ "$unicode_alias" != "$unicode_name" && -d "$tmp/$unicode_alias" ]]; then
    captured=$(ansi_safe_external_root "$repo" "$tmp/$unicode_alias/child") || rc=1
    python3 - "$(dirname "$captured")" "$tmp/$unicode_name" <<'PY' || rc=1
import os, sys
raise SystemExit(0 if os.path.samefile(sys.argv[1], sys.argv[2]) else 1)
PY
  fi

  (( rc == 0 )) || return "$rc"
  printf 'private-root path safety self-test: pass\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --self-test) ansi_private_root_safety_self_test ;;
    *) printf 'usage: %s --self-test\n' "$0" >&2; exit 2 ;;
  esac
fi
