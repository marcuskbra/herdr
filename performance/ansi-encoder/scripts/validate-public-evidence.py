#!/usr/bin/env python3
"""Validate the sanitized public ANSI encoder evidence pack."""

from __future__ import annotations

import csv
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR_RELATIVE = "scripts/validate-public-evidence.py"


class ValidationError(RuntimeError):
    """A public evidence invariant failed."""


def fail(message: str) -> None:
    raise ValidationError(message)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


# PRIVACY_PATTERN_DEFINITIONS_START
FORBIDDEN_PUNCTUATION = ("\u2013", "\u2014", "\u2018", "\u2019", "\u201c", "\u201d", "\u2026")
PRIVATE_PATH_RE = re.compile(r"(?i)(?:^|[\s\"'=:(])/(?:Users(?:/[^/\s]+)?|home(?:/[^/\s]+)?|private)(?=/|[\s\"'():,;]|$)")
HOME_SHORTCUT_RE = re.compile(r"(?<![A-Za-z0-9_])~/(?:[^\s\"']+)")
EMAIL_RE = re.compile(r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b")
IDENTITY_ASSIGNMENT_RE = re.compile(r"(?i)\b(user(?:name)?|host(?:name)?)\s*[:=]\s*[\"']?([A-Za-z0-9._-]{3,})")
CREDENTIAL_ASSIGNMENT_RE = re.compile(r"(?i)(?:^|\b|[\"'])(?:GOOGLE_APPLICATION_CREDENTIALS|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|GITHUB_TOKEN|GITLAB_TOKEN|SLACK_TOKEN|[A-Z0-9_]*(?:API[_-]?KEY|PASSWORD|PASSWD|SECRET|TOKEN|CLIENT[_-]?SECRET|ACCESS[_-]?KEY|CREDENTIALS?)[A-Z0-9_]*)[\"']?\s*(?::|=|=>)\s*[\"']?(?!<(?:redacted|path|token|secret)>)[^\s\"']{6,}")
TOKEN_RE = re.compile(r"(?i)(?:\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b|\bglpat-[A-Za-z0-9_-]{20,}\b|\bxox[baprs]-[A-Za-z0-9-]{10,}\b|\bxapp-[A-Za-z0-9-]{20,}\b|\b(?:AKIA|ASIA)[0-9A-Z]{16}\b|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b)")
AUTHORIZATION_RE = re.compile(r"(?i)\bauthorization\s*:\s*(?:bearer|basic)\s+\S+")
COOKIE_RE = re.compile(r"(?i)\b(?:cookie|set-cookie)\s*:\s*(?!<(?:redacted|cookie)>)[^\s;,=]+=[^\s;,]{4,}")
PRIVATE_KEY_RE = re.compile(r"-----BEGIN (?:ENCRYPTED |RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY(?: BLOCK)?-----")
RAW_PID_RE = re.compile(r"(?i)[\"']?(?:pid|process[_-]?id|target[_-]?pid)[\"']?\s*(?:[:=]|\t)\s*[\"']?([1-9][0-9]{1,})\b")
IPV4_RE = re.compile(r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])")
IPV6_CANDIDATE_RE = re.compile(r"(?<![0-9A-Za-z:])[0-9A-Fa-f:]{2,}:[0-9A-Fa-f:]+(?![0-9A-Za-z:])")
MAC_RE = re.compile(r"(?i)(?<![0-9A-F])(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}(?![0-9A-F])")
NATIVE_MAGICS = {
    bytes.fromhex(value)
    for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "7f454c46", "4d5a9000")
}
SAFE_IDENTITY_VALUES = {"example", "example.invalid", "localhost", "unknown"}
CURRENT_IDENTITIES = {
    value.casefold()
    for value in (os.environ.get("USER", ""), os.environ.get("LOGNAME", ""), os.uname().nodename)
    if len(value) >= 3 and value.casefold() not in SAFE_IDENTITY_VALUES
}
# PRIVACY_PATTERN_DEFINITIONS_END

# PRIVACY_SELF_TEST_FIXTURES_START
FORBIDDEN_SELF_TESTS = {
    "private-user-root": "/Users",
    "private-user-path": "/Users/private-user/capture.trace",
    "private-system-root": "/private",
    "private-system-path": "/private/tmp/capture",
    "home-path": "~/local-capture",
    "email": "owner@corp.example",
    "username": "USERNAME=private-user",
    "hostname": "HOSTNAME=private-laptop",
    "ipv4": "build_host=10.23.45.67",
    "ipv6": "build_host=2001:4860:4860::8888",
    "mac": "device_mac=00:11:22:33:44:55",
    "private-key": "-----BEGIN PRIVATE KEY-----",
    "dsa-private-key": "-----BEGIN DSA PRIVATE KEY-----",
    "pgp-private-key": "-----BEGIN PGP PRIVATE KEY BLOCK-----",
    "github-token": "ghp_" + "A" * 36,
    "gitlab-token": "glpat-" + "A" * 24,
    "aws-access-id": "AK" + "IA" + "A" * 16,
    "aws-temporary-id": "AS" + "IA" + "A" * 16,
    "slack-token": "xo" + "xb-" + "1" * 12 + "-" + "A" * 24,
    "slack-app-token": "xa" + "pp-1-" + "A" * 24,
    "jwt": "ey" + "J" + "A" * 12 + "." + "B" * 12 + "." + "C" * 12,
    "encrypted-private-key": "-----BEGIN ENCRYPTED " + "PRIVATE KEY-----",
    "authorization-basic": "Authorization: " + "Basic " + "A" * 24,
    "cookie": "Cookie: session=" + "A" * 24,
    "set-cookie": "Set-Cookie: session=" + "A" * 24 + "; HttpOnly",
    "quoted-mapping-secret": "\"password\" => \"" + "A" * 24 + "\"",
    "token": "API_TOKEN=super-secret-token-value",
    "credential": "AWS_SECRET_ACCESS_KEY=private-credential-value",
    "google-credential": "GOOGLE_APPLICATION_CREDENTIALS=/tmp/private-key.json",
    "pid": "pid=43127",
}
# PRIVACY_SELF_TEST_FIXTURES_END


def validator_allowlisted_lines(relative: str, text: str) -> set[int]:
    """Allow only the validator's marked pattern definitions and test fixtures."""
    if relative != VALIDATOR_RELATIVE:
        return set()
    markers = (
        ("# PRIVACY_PATTERN_DEFINITIONS_START", "# PRIVACY_PATTERN_DEFINITIONS_END"),
        ("# PRIVACY_SELF_TEST_FIXTURES_START", "# PRIVACY_SELF_TEST_FIXTURES_END"),
        ("# PRIVACY_EXACT_ALLOWLIST_START", "# PRIVACY_EXACT_ALLOWLIST_END"),
    )
    lines = text.splitlines()
    allowed: set[int] = set()
    for start_marker, end_marker in markers:
        starts = [index for index, line in enumerate(lines) if line == start_marker]
        ends = [index for index, line in enumerate(lines) if line == end_marker]
        if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
            fail(f"validator privacy allowlist markers are malformed: {start_marker}")
        allowed.update(range(starts[0] + 1, ends[0]))
    return allowed


def scan_path_component(name: str) -> None:
    if (
        EMAIL_RE.search(name)
        or PRIVATE_PATH_RE.search("/" + name)
        or HOME_SHORTCUT_RE.search(name)
        or IDENTITY_ASSIGNMENT_RE.search(name)
        or CREDENTIAL_ASSIGNMENT_RE.search(name)
        or TOKEN_RE.search(name)
        or AUTHORIZATION_RE.search(name)
        or COOKIE_RE.search(name)
        or PRIVATE_KEY_RE.search(name)
    ):
        fail("sensitive directory or filename included (name redacted)")
    folded = name.casefold()
    if any(
        re.search(rf"(?<![A-Za-z0-9_.-]){re.escape(value)}(?![A-Za-z0-9_.-])", folded)
        for value in CURRENT_IDENTITIES
    ):
        fail("local identity in directory or filename (name redacted)")


def walk_scope(root: Path) -> tuple[list[Path], list[Path]]:
    directories: list[Path] = []
    files: list[Path] = []

    def visit(directory: Path) -> None:
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
        except OSError as error:
            fail(f"cannot inspect {directory.relative_to(root)}: {error}")
        for entry in entries:
            scan_path_component(entry.name)
            path = Path(entry.path)
            relative = path.relative_to(root).as_posix()
            try:
                info = entry.stat(follow_symlinks=False)
            except OSError as error:
                fail(f"cannot stat public entry: {error}")
            mode = info.st_mode
            if stat.S_ISLNK(mode):
                fail(f"symlink included: {relative}")
            if stat.S_ISDIR(mode):
                lower = entry.name.casefold()
                if lower == ".trace" or lower.endswith(".trace") or lower == ".dsym" or lower.endswith(".dsym"):
                    fail(f"private native directory included: {relative}")
                directories.append(path)
                visit(path)
            elif stat.S_ISREG(mode):
                if info.st_nlink != 1:
                    fail("hardlinked public file included (name redacted)")
                files.append(path)
            else:
                fail(f"non-regular file included: {relative}")

    visit(root)
    return directories, files


# PRIVACY_EXACT_ALLOWLIST_START
def declared_fixture_address(line: str, address: str) -> bool:
    if "fixture" not in line.lower():
        return False
    try:
        value = ipaddress.ip_address(address)
    except ValueError:
        return False
    return value.is_loopback or value.is_unspecified or value in ipaddress.ip_network("192.0.2.0/24") or value in ipaddress.ip_network("198.51.100.0/24") or value in ipaddress.ip_network("203.0.113.0/24") or value in ipaddress.ip_network("2001:db8::/32")
# PRIVACY_EXACT_ALLOWLIST_END


def scan_text(relative: str, text: str) -> None:
    allowed = validator_allowlisted_lines(relative, text)
    for line_number, line in enumerate(text.splitlines(), 1):
        if line_number - 1 in allowed:
            continue
        if any(token in line for token in FORBIDDEN_PUNCTUATION):
            fail(f"forbidden Unicode punctuation in {relative}:{line_number}")
        if PRIVATE_PATH_RE.search(line) or HOME_SHORTCUT_RE.search(line):
            fail(f"private absolute or home path in {relative}:{line_number}")
        if EMAIL_RE.search(line):
            fail(f"email address in {relative}:{line_number}")
        identity = IDENTITY_ASSIGNMENT_RE.search(line)
        if identity and identity.group(2).lower() not in SAFE_IDENTITY_VALUES and not identity.group(2).startswith("<"):
            fail(f"username or hostname assignment in {relative}:{line_number}")
        folded = line.casefold()
        if any(re.search(rf"(?<![A-Za-z0-9_.-]){re.escape(value)}(?![A-Za-z0-9_.-])", folded) for value in CURRENT_IDENTITIES):
            fail(f"current local identity in {relative}:{line_number}")
        if (CREDENTIAL_ASSIGNMENT_RE.search(line) or TOKEN_RE.search(line) or AUTHORIZATION_RE.search(line) or COOKIE_RE.search(line) or PRIVATE_KEY_RE.search(line)):
            fail(f"possible credential material in {relative}:{line_number}")
        if ".auto" + "/" in line:
            fail(f"private .auto reference in {relative}:{line_number}")
        if RAW_PID_RE.search(line):
            fail(f"raw process identifier in {relative}:{line_number}")
        for match in IPV4_RE.finditer(line):
            address = match.group(0)
            try:
                ipaddress.IPv4Address(address)
            except ValueError:
                continue
            if not declared_fixture_address(line, address):
                fail(f"IPv4 address in {relative}:{line_number}")
        for match in IPV6_CANDIDATE_RE.finditer(line):
            address = match.group(0)
            try:
                ipaddress.IPv6Address(address)
            except ValueError:
                continue
            if not declared_fixture_address(line, address):
                fail(f"IPv6 address in {relative}:{line_number}")
        mac = MAC_RE.search(line)
        if mac and not ("fixture" in line.lower() and mac.group(0).lower().startswith("02:")):
            fail(f"MAC address in {relative}:{line_number}")


def scan_public_scope(root: Path) -> list[Path]:
    _directories, files = walk_scope(root)
    for path in files:
        relative = path.relative_to(root).as_posix()
        lower = path.name.lower()
        if lower.endswith(".png"):
            fail(f"PNG included despite SVG-only policy: {relative}")
        if lower.endswith(".trace") or lower.endswith(".dsym"):
            fail(f"private native artifact included: {relative}")
        data = path.read_bytes()
        if data[:4] in NATIVE_MAGICS:
            fail(f"native executable or binary included: {relative}")
        try:
            description = subprocess.check_output(
                ["file", "-b", "--", os.fspath(path)], text=True, stderr=subprocess.DEVNULL
            )
        except (OSError, subprocess.CalledProcessError) as error:
            fail(f"file-type inspection failed for {relative}: {error}")
        if any(token in description for token in ("Mach-O", "ELF ", "PE32", "MS-DOS executable")):
            fail(f"native executable or binary included: {relative}")
        if b"\0" in data:
            fail(f"binary file included: {relative}")
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            fail(f"non-UTF-8 file included: {relative}")
        scan_text(relative, text)
    return files


def validate_json() -> None:
    for path in sorted(ROOT.rglob("*.json")):
        json.loads(path.read_text())


def read_tsv(path: Path) -> list[dict[str, str]]:
    lines = path.read_text().splitlines()
    if not lines:
        fail(f"empty TSV: {path.relative_to(ROOT)}")
    width = len(lines[0].split("\t"))
    for index, line in enumerate(lines[1:], 2):
        if len(line.split("\t")) != width:
            fail(f"TSV width mismatch: {path.relative_to(ROOT)}:{index}")
    with path.open(newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def validate_tsv() -> None:
    for path in sorted(ROOT.rglob("*.tsv")):
        read_tsv(path)
    ordered = read_tsv(ROOT / "data/ordered-batches.tsv")
    if len(ordered) != 2400:
        fail(f"expected 2,400 ordered batches, found {len(ordered):,}")
    collapsed = read_tsv(ROOT / "data/cpu-final-collapsed-stacks.tsv")
    totals = {"master": 0, "candidate": 0}
    for row in collapsed:
        totals[row["revision"]] += int(row["count"])
    if totals != {"master": 7894, "candidate": 7707}:
        fail(f"CPU collapsed stack totals differ: {totals}")
    summary = read_tsv(ROOT / "data/cpu-summary.tsv")
    for revision, expected in totals.items():
        leaf_total = sum(int(row["count"]) for row in summary if row["revision"] == revision and row["kind"] == "leaf" and row["count"])
        if leaf_total != expected:
            fail(f"CPU leaf total for {revision} is {leaf_total}, expected {expected}")


def validate_svg() -> None:
    charts = sorted((ROOT / "charts").glob("*.svg"))
    if len(charts) != 7:
        fail(f"expected seven SVG charts, found {len(charts)}")
    for path in charts:
        root = ET.parse(path).getroot()
        if not root.tag.endswith("svg"):
            fail(f"not an SVG document: {path.name}")


def validate_markdown_links() -> None:
    definition = re.compile(r"^\[([^]]+)\]:\s+(\S+)", re.MULTILINE)
    inline = re.compile(r"!?\[[^]]*\]\(([^)]+)\)")
    reference = re.compile(r"!?\[[^]]+\]\[([^]]+)\]")
    for path in sorted(ROOT.rglob("*.md")):
        text = path.read_text()
        definitions = dict(definition.findall(text))
        targets = list(inline.findall(text))
        for label in reference.findall(text):
            if label not in definitions:
                fail(f"undefined reference [{label}] in {path.relative_to(ROOT)}")
            targets.append(definitions[label])
        for target in targets:
            target = target.split("#", 1)[0]
            if not target or re.match(r"^[a-z]+://", target):
                continue
            resolved = path.parent / target
            if not resolved.exists():
                fail(f"broken link {target!r} in {path.relative_to(ROOT)}")


def validate_manifest(files: list[Path]) -> None:
    path = ROOT / "MANIFEST.sha256"
    if not path.is_file():
        fail("MANIFEST.sha256 is missing")
    listed: list[str] = []
    for line in path.read_text().splitlines():
        try:
            digest, relative = line.split("  ", 1)
        except ValueError:
            fail("malformed manifest line")
        target = ROOT / relative
        if not target.is_file():
            fail(f"manifest target is missing: {relative}")
        if sha256(target) != digest:
            fail(f"manifest digest mismatch: {relative}")
        listed.append(relative)
    actual = sorted(item.relative_to(ROOT).as_posix() for item in files if item != path)
    if listed != sorted(listed) or len(listed) != len(set(listed)):
        fail("manifest entries are not unique and sorted")
    if listed != actual:
        fail(f"manifest scope differs: missing={sorted(set(actual) - set(listed))}, extra={sorted(set(listed) - set(actual))}")


def filesystem_snapshot(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        info = path.lstat()
        digest.update(f"{relative}\0{info.st_mode}\0{info.st_size}\0{info.st_mtime_ns}\0".encode())
        if path.is_file() and not path.is_symlink():
            digest.update(path.read_bytes())
    return digest.hexdigest()


def git_state_snapshot() -> tuple[bytes, bytes, bytes]:
    repository = ROOT.parents[1]
    return tuple(
        subprocess.check_output(command)
        for command in (
            ["git", "-C", os.fspath(repository), "status", "--porcelain=v1", "-z", "--untracked-files=all"],
            ["git", "-C", os.fspath(repository), "diff", "--binary", "HEAD"],
            ["git", "-C", os.fspath(repository), "show-ref"],
        )
    )


def validate_bare_script_invocations() -> None:
    if os.environ.get("HERDR_ANSI_BARE_INVOCATION_TEST") == "1":
        return
    scripts = sorted(
        path for path in (ROOT / "scripts").iterdir()
        if path.suffix in (".py", ".sh")
    )
    with tempfile.TemporaryDirectory(prefix="herdr-ansi-bare-script-") as temporary:
        environment = os.environ.copy()
        environment.update({
            "HERDR_ANSI_BARE_INVOCATION_TEST": "1",
            "HERDR_ANSI_OUTPUT": str(Path(temporary) / "output"),
            "HERDR_ANSI_PRIVATE_ROOT": "",
            "HERDR_ANSI_PUBLIC_ROOT": str(ROOT),
            "HERDR_ANSI_WORK_PARENT": str(Path(temporary) / "work"),
            "PYTHONDONTWRITEBYTECODE": "1",
        })
        for script in scripts:
            before_files = filesystem_snapshot(ROOT)
            before_git = git_state_snapshot()
            before_temporary = filesystem_snapshot(Path(temporary))
            command = [sys.executable, os.fspath(script)] if script.suffix == ".py" else ["bash", os.fspath(script)]
            subprocess.run(
                command,
                cwd=ROOT.parents[1],
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=20,
                check=False,
            )
            if (
                filesystem_snapshot(ROOT) != before_files
                or git_state_snapshot() != before_git
                or filesystem_snapshot(Path(temporary)) != before_temporary
            ):
                fail(f"bare public script invocation changed filesystem or Git state: {script.name}")

        for script_name in ("ansi-encoder-evidence.sh", "ansi-encoder-ecdf-rerun.sh"):
            script = ROOT / "scripts" / script_name
            for help_argument in ("--help",):
                before_files = filesystem_snapshot(ROOT)
                before_git = git_state_snapshot()
                before_temporary = filesystem_snapshot(Path(temporary))
                subprocess.run(
                    ["bash", os.fspath(script), help_argument],
                    cwd=ROOT.parents[1],
                    env=environment,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=20,
                    check=True,
                )
                if (
                    filesystem_snapshot(ROOT) != before_files
                    or git_state_snapshot() != before_git
                    or filesystem_snapshot(Path(temporary)) != before_temporary
                ):
                    fail(f"help invocation changed filesystem or Git state: {script.name}")


def validate_privacy_self_tests() -> None:
    with tempfile.TemporaryDirectory(prefix="herdr-public-validator-") as temporary:
        base = Path(temporary)
        cases = dict(FORBIDDEN_SELF_TESTS)
        suffixes = (".sh", ".py", ".log", ".txt", ".md", ".tsv", ".json", ".svg")
        for index, (name, value) in enumerate(cases.items()):
            root = base / name
            root.mkdir()
            (root / ("record" + suffixes[index % len(suffixes)])).write_text(value + "\n")
            try:
                scan_public_scope(root)
            except ValidationError:
                pass
            else:
                fail(f"privacy self-test did not reject {name}")

        structural = base / "structural"
        structural.mkdir()
        symlink_case = structural / "symlink"
        symlink_case.mkdir()
        (symlink_case / "target.txt").write_text("safe\n")
        (symlink_case / "link.txt").symlink_to("target.txt")
        dsym_case = structural / "dsym"
        (dsym_case / "binary.dSYM").mkdir(parents=True)
        native_case = structural / "native"
        native_case.mkdir()
        (native_case / "binary").write_bytes(bytes.fromhex("feedfacf") + b"native")
        png_case = structural / "png"
        png_case.mkdir()
        (png_case / "preview.png").write_bytes(b"not really an image")
        fifo_case = structural / "fifo"
        fifo_case.mkdir()
        os.mkfifo(fifo_case / "pipe")
        hardlink_case = structural / "hardlink"
        hardlink_case.mkdir()
        (hardlink_case / "first").write_text("safe\n")
        os.link(hardlink_case / "first", hardlink_case / "second")
        for name in ("symlink", "dsym", "native", "png", "fifo", "hardlink"):
            try:
                scan_public_scope(structural / name)
            except ValidationError:
                pass
            else:
                fail(f"privacy self-test did not reject {name}")

        for kind, sensitive_name in (
            ("directory", "owner@" + "corp.example"),
            ("file", "gh" + "p_" + "A" * 36),
        ):
            named_case = base / ("sensitive-" + kind)
            named_case.mkdir()
            if kind == "directory":
                (named_case / sensitive_name).mkdir()
            else:
                (named_case / sensitive_name).write_text("safe\n")
            try:
                scan_public_scope(named_case)
            except ValidationError as error:
                if sensitive_name in str(error):
                    fail("sensitive path self-test leaked the rejected name")
            else:
                fail(f"privacy self-test did not reject sensitive {kind} name")

        valid = base / "valid"
        valid.mkdir()
        (valid / "fixture.txt").write_text(
            "fixture IPv4 192.0.2.1 and fixture IPv6 2001:db8::1\n"
            "commit d00dc4813d6803ce4efa3e9ad7b1c3533512aaff\n"
            "FNV hash edfa0379543ed13d; version 26.6; pid prose has no raw number\n"
            "API_TOKEN=<redacted>; GOOGLE_APPLICATION_CREDENTIALS=<path>\n"
        )
        scan_public_scope(valid)


def main() -> None:
    validate_privacy_self_tests()
    validate_bare_script_invocations()
    if sys.argv[1:] == ["--self-test"]:
        print("public evidence privacy self-tests: pass")
        return
    if sys.argv[1:]:
        fail("usage: validate-public-evidence.py [--self-test]")
    files = scan_public_scope(ROOT)
    validate_json()
    validate_tsv()
    validate_svg()
    validate_markdown_links()
    validate_manifest(files)
    size = sum(path.stat().st_size for path in files)
    print(f"public evidence validation: pass ({len(files)} files, {size:,} bytes)")


if __name__ == "__main__":
    try:
        main()
    except (ValidationError, json.JSONDecodeError, ET.ParseError) as error:
        raise SystemExit(f"error: {error}") from None
