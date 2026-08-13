#!/usr/bin/env python3
"""Validate the sanitized current-master ANSI encoder evidence addendum."""

from __future__ import annotations

import csv
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = "scripts/validate-public-evidence.py"


class ValidationError(RuntimeError):
    """A public evidence invariant failed."""


def fail(message: str) -> None:
    raise ValidationError(message)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


# PRIVACY_PATTERN_DEFINITIONS_START
FORBIDDEN_PUNCTUATION = ("\u2013", "\u2014", "\u2018", "\u2019", "\u201c", "\u201d", "\u2026")
PRIVATE_PATH_RE = re.compile(r"(?i)(?:/(?:Users|home|private|var/folders)(?:/|\b)|[A-Z]:\\Users\\)")
PRIVATE_RELATIVE_PATH_RE = re.compile(r"(?i)(?:^|[\s\"'`])(?:\.local/|[^\s\"'`]*/performance-investigations/)")
HOME_SHORTCUT_RE = re.compile(r"(?<![A-Za-z0-9_])~/(?:[^\s\"']+)")
EMAIL_RE = re.compile(r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b")
IDENTITY_ASSIGNMENT_RE = re.compile(r"(?i)\b(user(?:name)?|host(?:name)?)\s*[:=]\s*[\"']?([A-Za-z0-9._-]{3,})")
CREDENTIAL_ASSIGNMENT_RE = re.compile(r"(?i)(?:^|\b|[\"'])(?:GOOGLE_APPLICATION_CREDENTIALS|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|GITHUB_TOKEN|GITLAB_TOKEN|SLACK_TOKEN|[A-Z0-9_]*(?:API[_-]?KEY|PASSWORD|PASSWD|SECRET|TOKEN|CLIENT[_-]?SECRET|ACCESS[_-]?KEY|CREDENTIALS?)[A-Z0-9_]*)[\"']?\s*(?::|=|=>)\s*[\"']?(?!<(?:redacted|path|token|secret)>)[^\s\"']{6,}")
TOKEN_RE = re.compile(r"(?i)(?:\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b|\bglpat-[A-Za-z0-9_-]{20,}\b|\bxox[baprs]-[A-Za-z0-9-]{10,}\b|\bxapp-[A-Za-z0-9-]{20,}\b|\b(?:AKIA|ASIA)[0-9A-Z]{16}\b|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b)")
AUTHORIZATION_RE = re.compile(r"(?i)\bauthorization\s*:\s*(?:bearer|basic)\s+\S+")
COOKIE_RE = re.compile(r"(?i)\b(?:cookie|set-cookie)\s*:\s*(?!<(?:redacted|cookie)>)[^\s;,=]+=[^\s;,]{4,}")
PRIVATE_KEY_RE = re.compile(r"-----BEGIN (?:ENCRYPTED |RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY(?: BLOCK)?-----")
IPV4_RE = re.compile(r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])")
IPV6_RE = re.compile(r"(?<![0-9A-Za-z:])[0-9A-Fa-f:]{2,}:[0-9A-Fa-f:]+(?![0-9A-Za-z:])")
MAC_RE = re.compile(r"(?i)(?<![0-9A-F])(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}(?![0-9A-F])")
NATIVE_MAGICS = {bytes.fromhex(value) for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "7f454c46", "4d5a9000")}
NATIVE_SUFFIXES = (".trace", ".dsym", ".o", ".a", ".so", ".dylib", ".dll", ".exe", ".pdb", ".profraw", ".symbols")
SAFE_IDENTITIES = {"example", "example.invalid", "localhost", "root", "runner", "unknown"}
CURRENT_IDENTITIES = {value.casefold() for value in (os.environ.get("USER", ""), os.environ.get("LOGNAME", ""), os.uname().nodename) if len(value) >= 3 and value.casefold() not in SAFE_IDENTITIES}
# PRIVACY_PATTERN_DEFINITIONS_END

# PRIVACY_SELF_TEST_FIXTURES_START
FORBIDDEN_SELF_TESTS = {
    "private-user-path": "/Users/private-user/capture.trace",
    "private-home-path": "/home/private-user/output",
    "private-system-path": "/private/tmp/capture",
    "private-temporary-path": "/var/folders/aa/capture",
    "private-relative-path": ".local/performance-investigations/capture",
    "home-shortcut": "~/local-capture",
    "email": "owner@corp.example",
    "username": "USERNAME=private-user",
    "hostname": "HOSTNAME=private-laptop",
    "ipv4": "build_host=10.23.45.67",
    "ipv6": "build_host=2001:4860:4860::8888",
    "mac": "device_mac=00:11:22:33:44:55",
    "private-key": "-----BEGIN PRIVATE KEY-----",
    "github-token": "ghp_" + "A" * 36,
    "gitlab-token": "glpat-" + "A" * 24,
    "aws-access-id": "AK" + "IA" + "A" * 16,
    "slack-token": "xo" + "xb-" + "1" * 12 + "-" + "A" * 24,
    "slack-app-token": "xa" + "pp-1-" + "A" * 24,
    "jwt": "ey" + "J" + "A" * 12 + "." + "B" * 12 + "." + "C" * 12,
    "bearer-authorization": "Authorization: " + "Bearer " + "A" * 24,
    "basic-authorization": "Authorization: " + "Basic " + "A" * 24,
    "cookie": "Cookie: session=" + "A" * 24,
    "mapping-secret": "\"password\" => \"" + "A" * 24 + "\"",
    "credential": "AWS_SECRET_ACCESS_KEY=private-credential-value",
}
# PRIVACY_SELF_TEST_FIXTURES_END


def allowlisted_validator_lines(relative: str, text: str) -> set[int]:
    if relative != VALIDATOR:
        return set()
    pairs = (
        ("# PRIVACY_PATTERN_DEFINITIONS_START", "# PRIVACY_PATTERN_DEFINITIONS_END"),
        ("# PRIVACY_SELF_TEST_FIXTURES_START", "# PRIVACY_SELF_TEST_FIXTURES_END"),
        ("# PRIVACY_EXACT_ALLOWLIST_START", "# PRIVACY_EXACT_ALLOWLIST_END"),
    )
    lines = text.splitlines()
    allowed: set[int] = set()
    for start, end in pairs:
        starts = [index for index, line in enumerate(lines) if line == start]
        ends = [index for index, line in enumerate(lines) if line == end]
        if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
            fail("validator privacy markers are malformed")
        allowed.update(range(starts[0] + 1, ends[0]))
    return allowed


def contains_current_identity(value: str) -> bool:
    folded = value.casefold()
    return any(
        re.search(
            rf"(?<![A-Za-z0-9_.-]){re.escape(identity)}(?![A-Za-z0-9_.-])",
            folded,
        )
        for identity in CURRENT_IDENTITIES
    )


# PRIVACY_EXACT_ALLOWLIST_START
def declared_fixture_address(line: str, address: str) -> bool:
    if "fixture" not in line.casefold():
        return False
    try:
        value = ipaddress.ip_address(address)
    except ValueError:
        return False
    return (
        value.is_loopback
        or value.is_unspecified
        or value in ipaddress.ip_network("192.0.2.0/24")
        or value in ipaddress.ip_network("198.51.100.0/24")
        or value in ipaddress.ip_network("203.0.113.0/24")
        or value in ipaddress.ip_network("2001:db8::/32")
    )
# PRIVACY_EXACT_ALLOWLIST_END


def scan_name(name: str) -> None:
    if (
        PRIVATE_PATH_RE.search("/" + name)
        or PRIVATE_RELATIVE_PATH_RE.search(name)
        or HOME_SHORTCUT_RE.search(name)
        or EMAIL_RE.search(name)
        or IDENTITY_ASSIGNMENT_RE.search(name)
        or CREDENTIAL_ASSIGNMENT_RE.search(name)
        or TOKEN_RE.search(name)
        or AUTHORIZATION_RE.search(name)
        or COOKIE_RE.search(name)
        or PRIVATE_KEY_RE.search(name)
        or contains_current_identity(name)
    ):
        fail("sensitive directory or filename included (name redacted)")


def walk_scope(root: Path) -> list[Path]:
    files: list[Path] = []

    def visit(directory: Path) -> None:
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
        except OSError as error:
            fail(f"cannot inspect public scope: {error}")
        for entry in entries:
            scan_name(entry.name)
            relative = Path(entry.path).relative_to(root).as_posix()
            try:
                info = entry.stat(follow_symlinks=False)
            except OSError as error:
                fail(f"cannot inspect {relative}: {error}")
            if stat.S_ISLNK(info.st_mode):
                fail(f"symlink included: {relative}")
            if stat.S_ISDIR(info.st_mode):
                if entry.name.casefold().endswith((".trace", ".dsym")):
                    fail(f"native trace or symbols included: {relative}")
                visit(Path(entry.path))
            elif stat.S_ISREG(info.st_mode):
                if info.st_nlink != 1:
                    fail("hardlinked public file included (name redacted)")
                files.append(Path(entry.path))
            else:
                fail(f"non-regular file included: {relative}")

    visit(root)
    return files


def scan_text(relative: str, value: str) -> None:
    allowed = allowlisted_validator_lines(relative, value)
    for line_number, line in enumerate(value.splitlines(), 1):
        if line_number - 1 in allowed:
            continue
        if any(character in line for character in FORBIDDEN_PUNCTUATION):
            fail(f"forbidden Unicode punctuation in {relative}:{line_number}")
        if (
            PRIVATE_PATH_RE.search(line)
            or PRIVATE_RELATIVE_PATH_RE.search(line)
            or HOME_SHORTCUT_RE.search(line)
        ):
            fail(f"private path in {relative}:{line_number}")
        if EMAIL_RE.search(line):
            fail(f"email address in {relative}:{line_number}")
        identity = IDENTITY_ASSIGNMENT_RE.search(line)
        if (
            identity
            and identity.group(2).casefold() not in SAFE_IDENTITIES
            and not identity.group(2).startswith("<")
        ):
            fail(f"username or hostname in {relative}:{line_number}")
        if contains_current_identity(line):
            fail(f"local identity in {relative}:{line_number}")
        if (
            CREDENTIAL_ASSIGNMENT_RE.search(line)
            or TOKEN_RE.search(line)
            or AUTHORIZATION_RE.search(line)
            or COOKIE_RE.search(line)
            or PRIVATE_KEY_RE.search(line)
        ):
            fail(f"possible credential material in {relative}:{line_number}")
        for match in IPV4_RE.finditer(line):
            address = match.group(0)
            try:
                ipaddress.IPv4Address(address)
            except ValueError:
                continue
            if not declared_fixture_address(line, address):
                fail(f"IPv4 address in {relative}:{line_number}")
        for match in IPV6_RE.finditer(line):
            address = match.group(0)
            try:
                ipaddress.IPv6Address(address)
            except ValueError:
                continue
            if not declared_fixture_address(line, address):
                fail(f"IPv6 address in {relative}:{line_number}")
        match = MAC_RE.search(line)
        if match and not (
            "fixture" in line.casefold()
            and match.group(0).casefold().startswith("02:")
        ):
            fail(f"MAC address in {relative}:{line_number}")


def scan_public_scope(root: Path) -> list[Path]:
    files = walk_scope(root)
    for path in files:
        relative = path.relative_to(root).as_posix()
        lower = path.name.casefold()
        if lower.endswith(NATIVE_SUFFIXES) or lower.endswith(".png"):
            fail(f"native or excluded artifact included: {relative}")
        raw = path.read_bytes()
        if raw[:4] in NATIVE_MAGICS or b"\0" in raw:
            fail(f"binary or native artifact included: {relative}")
        try:
            description = subprocess.check_output(
                ["file", "-b", "--", os.fspath(path)],
                text=True,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            fail(f"file-type inspection failed for {relative}: {error}")
        if any(
            token in description
            for token in ("Mach-O", "ELF ", "PE32", "MS-DOS executable")
        ):
            fail(f"native executable included: {relative}")
        try:
            text_value = raw.decode("utf-8")
        except UnicodeDecodeError:
            fail(f"non-UTF-8 file included: {relative}")
        scan_text(relative, text_value)
    return files


def nearest_rank(values: list[int], percentile: float) -> int:
    ordered = sorted(values)
    return ordered[math.ceil(percentile * len(ordered)) - 1]


def validate_json_and_arithmetic() -> None:
    for path in sorted(ROOT.rglob("*.json")):
        json.loads(path.read_text())
    summary = json.loads((ROOT / "data/summary.json").read_text())
    ordered = json.loads((ROOT / "data/ordered-batches.json").read_text())
    v1 = summary["revisions"]["V1"]["commit"]
    v3 = summary["revisions"]["V3"]["commit"]
    if (
        v1 != "49e333ae87a57952fc82ba479a55c35b975ff3cc"
        or v3 != "90f12051690f46f8d5837b861df14350a6ea4fde"
        or summary["revisions"]["V3"]["sole_parent"] != v1
        or summary["historical_showcase"]
        != {
            "comparison": "V0_vs_V2",
            "status": "immutable_and_separate",
            "data_included_here": False,
        }
        or ordered["revisions"] != {"V1": v1, "V3": v3}
    ):
        fail("revision relationship or historical boundary differs")
    expected_medians = {
        "dense_colour": (2_936_629, 164_054),
        "plain_scroll": (1_404_308, 69_620),
        "sparse_edit": (100_262, 31_220),
        "full_redraw": (1_338_825, 55_954),
    }
    expected_p95s = {
        "dense_colour": (3_010_054, 168_495),
        "plain_scroll": (1_447_629, 72_991),
        "sparse_edit": (101_841, 34_975),
        "full_redraw": (1_378_733, 72_279),
    }
    processes = summary["primary_timing"]["processes"]
    if len(processes) != 24:
        fail(f"expected 24 primary process-workload records, found {len(processes)}")
    aggregates = {
        item["workload"]: item
        for item in summary["primary_timing"]["aggregates"]
    }
    for workload in ("dense_colour", "plain_scroll", "sparse_edit", "full_redraw"):
        item = aggregates[workload]
        for revision in ("V1", "V3"):
            values = [
                record["median_ns"]
                for record in processes
                if record["workload"] == workload
                and record["revision"] == revision
            ]
            if values != item[revision]["process_medians_ns"] or len(values) != 3:
                fail(f"primary process medians differ for {workload} {revision}")
            if statistics_median(values) != item[revision]["median_of_process_medians_ns"]:
                fail(f"primary median arithmetic differs for {workload} {revision}")
        baseline = item["V1"]["median_of_process_medians_ns"]
        candidate = item["V3"]["median_of_process_medians_ns"]
        if (baseline, candidate) != expected_medians[workload]:
            fail(f"accepted median values differ for {workload}")
        if not math.isclose(item["speedup"], baseline / candidate):
            fail(f"speedup arithmetic differs for {workload}")
        if not math.isclose(
            item["time_reduction_percent"],
            (1 - candidate / baseline) * 100,
        ):
            fail(f"reduction arithmetic differs for {workload}")
    ordered_processes = ordered["processes"]
    if (
        len(ordered_processes) != 24
        or sum(len(item["ordered_batch_ns"]) for item in ordered_processes)
        != 2400
    ):
        fail("ordered batch JSON must contain 24 vectors and 2,400 values")
    p95s = {
        item["workload"]: item
        for item in summary["descriptive_p95"]["aggregates"]
    }
    for workload in ("dense_colour", "plain_scroll", "sparse_edit", "full_redraw"):
        records = [
            item for item in ordered_processes if item["workload"] == workload
        ]
        for revision in ("V1", "V3"):
            selected = [item for item in records if item["revision"] == revision]
            if len(selected) != 3:
                fail(f"expected three ordered processes for {workload} {revision}")
            process_p95s = [
                nearest_rank(item["ordered_batch_ns"], 0.95) for item in selected
            ]
            pooled = [
                value for item in selected for value in item["ordered_batch_ns"]
            ]
            expected = p95s[workload][revision]
            if process_p95s != expected["process_p95s_ns"]:
                fail(f"process p95 arithmetic differs for {workload} {revision}")
            if nearest_rank(pooled, 0.95) != expected["pooled_300_batches_p95_ns"]:
                fail(f"pooled p95 arithmetic differs for {workload} {revision}")
        accepted_pair = (
            p95s[workload]["V1"]["pooled_300_batches_p95_ns"],
            p95s[workload]["V3"]["pooled_300_batches_p95_ns"],
        )
        if accepted_pair != expected_p95s[workload]:
            fail(f"accepted pooled p95 values differ for {workload}")
    allocation_10k = {
        item["revision"]: (item["allocations"], item["requested_bytes"])
        for item in summary["allocation_scaling"]
        if item["cells"] == 10_000
    }
    if allocation_10k != {
        "V1": (124_651, 5_386_440),
        "V3": (17, 1_048_568),
    }:
        fail("accepted 10,000-cell allocation values differ")
    race = summary["race"]
    if (
        not math.isclose(race["aggregate"]["V1"]["fps"], 6.4944198753622)
        or not math.isclose(race["aggregate"]["V3"]["fps"], 118.20524666836039)
        or not math.isclose(race["speedup"], 18.201047812876123)
    ):
        fail("accepted race throughput values differ")
    if not summary["descriptive_p95"]["pooled_batches_are_descriptive_only"]:
        fail("pooled p95 boundary is missing")
    if summary["descriptive_p95"]["replication_unit"] != "process":
        fail("process replication unit is missing")
    equivalence = summary["equivalence"]
    if len(equivalence) != 10 or not all(item["matching"] for item in equivalence):
        fail("all 10 output-equivalence scopes must match")
    checks = summary["checks"]
    required_checks = {
        "other_tests_passed": 3272,
        "shared_live_handoff_failure_count": 1,
        "full_just_check_success": False,
        "render_scaling_candidate_regression_found": False,
        "correctness_review_findings": 0,
        "performance_review_findings": 0,
    }
    if (
        any(checks.get(key) != value for key, value in required_checks.items())
        or checks.get("comparable_scope_count") != 10
        or not checks.get("all_comparable_output_bytes_and_hashes_match")
        or checks.get("shared_live_handoff_failure_reproduced_on")
        != ["V1", "V3"]
    ):
        fail("validation and review disclosure differs from the accepted record")


def statistics_median(values: list[int]) -> int:
    ordered = sorted(values)
    return ordered[len(ordered) // 2]


def read_tsv(path: Path) -> list[dict[str, str]]:
    lines = path.read_text().splitlines()
    if not lines:
        fail(f"empty TSV: {path.relative_to(ROOT)}")
    width = len(lines[0].split("\t"))
    if any(len(line.split("\t")) != width for line in lines[1:]):
        fail(f"TSV width mismatch: {path.relative_to(ROOT)}")
    with path.open(newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def validate_tsv_matches_json() -> None:
    rows = read_tsv(ROOT / "data/ordered-batches.tsv")
    if len(rows) != 2400:
        fail(f"expected 2,400 TSV values, found {len(rows):,}")
    ordered = json.loads((ROOT / "data/ordered-batches.json").read_text())
    expected = []
    for process in ordered["processes"]:
        expected.extend(
            {
                "revision": process["revision"],
                "round": str(process["round"]),
                "side": str(process["side"]),
                "workload": process["workload"],
                "batch_index": str(index),
                "latency_ns": str(value),
            }
            for index, value in enumerate(process["ordered_batch_ns"], 1)
        )
    if rows != expected:
        fail("ordered batch TSV differs from JSON")


def validate_svg() -> None:
    charts = sorted((ROOT / "charts").glob("*.svg"))
    if len(charts) != 4:
        fail(f"expected four SVG charts, found {len(charts)}")
    for path in charts:
        root = ET.parse(path).getroot()
        if not root.tag.endswith("svg"):
            fail(f"not an SVG document: {path.name}")
        width = root.attrib.get("width", "")
        height = root.attrib.get("height", "")
        view_box = root.attrib.get("viewBox", "").split()
        if (
            not width.isdecimal()
            or not height.isdecimal()
            or view_box != ["0", "0", width, height]
        ):
            fail(f"invalid SVG dimensions: {path.name}")


def validate_markdown_links() -> None:
    definition = re.compile(r"^\[([^]]+)\]:\s+(\S+)", re.MULTILINE)
    inline = re.compile(r"!?\[[^]]*\]\(([^)]+)\)")
    reference = re.compile(r"!?\[[^]]+\]\[([^]]+)\]")
    for path in sorted(ROOT.rglob("*.md")):
        value = path.read_text()
        definitions = dict(definition.findall(value))
        targets = list(inline.findall(value))
        for label in reference.findall(value):
            if label not in definitions:
                fail(f"undefined reference [{label}] in {path.relative_to(ROOT)}")
            targets.append(definitions[label])
        for target in targets:
            target = target.split("#", 1)[0]
            if not target or re.match(r"^[a-z]+://", target):
                continue
            if not (path.parent / target).exists():
                fail(f"broken link in {path.relative_to(ROOT)}: {target}")


def validate_manifest(files: list[Path]) -> None:
    path = ROOT / "MANIFEST.sha256"
    if not path.is_file():
        fail("MANIFEST.sha256 is missing")
    listed: list[str] = []
    for line_value in path.read_text().splitlines():
        try:
            digest, relative = line_value.split("  ", 1)
        except ValueError:
            fail("malformed manifest line")
        target = ROOT / relative
        if not target.is_file() or sha256(target) != digest:
            fail(f"manifest mismatch: {relative}")
        listed.append(relative)
    actual = sorted(
        item.relative_to(ROOT).as_posix() for item in files if item != path
    )
    if listed != sorted(set(listed)) or listed != actual:
        fail("manifest scope is incomplete, duplicated or unsorted")


def filesystem_snapshot(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        info = path.lstat()
        relative = path.relative_to(root).as_posix()
        digest.update(
            f"{relative}\0{info.st_mode}\0{info.st_size}\0{info.st_mtime_ns}\0".encode()
        )
        if path.is_file() and not path.is_symlink():
            digest.update(path.read_bytes())
    return digest.hexdigest()


def git_snapshot() -> tuple[bytes, bytes, bytes]:
    repository = ROOT.parents[1]
    commands = (
        ["git", "-C", os.fspath(repository), "status", "--porcelain=v1", "-z", "--untracked-files=all"],
        ["git", "-C", os.fspath(repository), "diff", "--binary", "HEAD"],
        ["git", "-C", os.fspath(repository), "show-ref"],
    )
    return tuple(subprocess.check_output(command) for command in commands)


def validate_bare_invocations() -> None:
    if os.environ.get("HERDR_ANSI_CURRENT_MASTER_BARE_TEST") == "1":
        return
    scripts = sorted((ROOT / "scripts").glob("*.py"))
    with tempfile.TemporaryDirectory(prefix="ansi-current-master-bare-") as name:
        temporary = Path(name)
        environment = os.environ.copy()
        environment.update(
            {
                "HERDR_ANSI_CURRENT_MASTER_BARE_TEST": "1",
                "HERDR_ANSI_CURRENT_MASTER_ROOT": os.fspath(ROOT),
                "PYTHONDONTWRITEBYTECODE": "1",
            }
        )
        for script in scripts:
            for arguments in ([], ["--help"]):
                before_scope = filesystem_snapshot(ROOT)
                before_git = git_snapshot()
                before_temporary = filesystem_snapshot(temporary)
                subprocess.run(
                    [sys.executable, os.fspath(script), *arguments],
                    cwd=ROOT.parents[1],
                    env=environment,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=20,
                    check=False,
                )
                if (
                    filesystem_snapshot(ROOT) != before_scope
                    or git_snapshot() != before_git
                    or filesystem_snapshot(temporary) != before_temporary
                ):
                    fail(
                        "bare or help script invocation changed filesystem or "
                        f"Git state: {script.name}"
                    )


def expect_scope_rejection(root: Path, label: str) -> None:
    try:
        scan_public_scope(root)
    except ValidationError:
        return
    fail(f"privacy self-test did not reject {label}")


def validate_privacy_self_tests() -> None:
    with tempfile.TemporaryDirectory(prefix="ansi-current-master-privacy-") as name:
        base = Path(name)
        for index, (label, value) in enumerate(FORBIDDEN_SELF_TESTS.items()):
            root = base / f"content-{index}"
            root.mkdir()
            (root / "record.txt").write_text(value + "\n")
            expect_scope_rejection(root, label)
        structural = base / "structural"
        structural.mkdir()
        symlink = structural / "symlink"
        symlink.mkdir()
        (symlink / "target.txt").write_text("safe\n")
        (symlink / "link.txt").symlink_to("target.txt")
        hardlink = structural / "hardlink"
        hardlink.mkdir()
        (hardlink / "first.txt").write_text("safe\n")
        os.link(hardlink / "first.txt", hardlink / "second.txt")
        native = structural / "native"
        native.mkdir()
        (native / "program").write_bytes(bytes.fromhex("feedfacf") + b"native")
        trace = structural / "trace"
        (trace / "capture.trace").mkdir(parents=True)
        binary = structural / "binary"
        binary.mkdir()
        (binary / "payload.txt").write_bytes(b"safe\0unsafe")
        fifo = structural / "fifo"
        fifo.mkdir()
        os.mkfifo(fifo / "pipe")
        for label in ("symlink", "hardlink", "native", "trace", "binary", "fifo"):
            expect_scope_rejection(structural / label, label)
        sensitive_file = base / "sensitive-file"
        sensitive_file.mkdir()
        (sensitive_file / ("gh" + "p_" + "A" * 36)).write_text("safe\n")
        expect_scope_rejection(sensitive_file, "sensitive filename")
        sensitive_directory = base / "sensitive-directory"
        sensitive_directory.mkdir()
        (sensitive_directory / ("owner" + "@corp.example")).mkdir()
        expect_scope_rejection(sensitive_directory, "sensitive directory name")
        valid = base / "valid"
        valid.mkdir()
        (valid / "fixture.txt").write_text(
            "fixture IPv4 192.0.2.1 and fixture IPv6 2001:db8::1\n"
            "commit 90f12051690f46f8d5837b861df14350a6ea4fde\n"
            "API_TOKEN=<redacted> and HOSTNAME=<redacted>\n"
        )
        scan_public_scope(valid)


def main() -> None:
    if sys.argv[1:] in (["-h"], ["--help"]):
        print("usage: validate-public-evidence.py [--self-test]")
        return
    if sys.argv[1:] not in ([], ["--self-test"]):
        fail("usage: validate-public-evidence.py [--self-test]")
    validate_privacy_self_tests()
    validate_bare_invocations()
    if sys.argv[1:] == ["--self-test"]:
        print("public evidence privacy and no-write self-tests: pass")
        return
    files = scan_public_scope(ROOT)
    validate_json_and_arithmetic()
    validate_tsv_matches_json()
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
