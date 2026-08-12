#!/usr/bin/env python3
"""Export, sanitize, and validate the signed Allocations retry traces.

Xcode 26.6 exposes Allocations Statistics and Allocations List through track-detail
XPath nodes, not through run/data schema tables. The list is a partial live-object
view and cannot support a complete call-site comparison. Temporary XML is always
deleted.
"""
from __future__ import annotations

from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[3]
PUBLIC = ROOT / "performance/ansi-encoder"
PRIVATE_ROOT_VALUE = os.environ.get("HERDR_ANSI_PRIVATE_ROOT")
PRIVATE_ROOT = Path(PRIVATE_ROOT_VALUE) if PRIVATE_ROOT_VALUE else None
BASE = (
    PRIVATE_ROOT / "profiles/retry-after-security-change"
    if PRIVATE_ROOT is not None
    else Path("__HERDR_ANSI_PRIVATE_ROOT_REQUIRED__")
)
TRACES = BASE / "traces"
EXPORT = Path(
    os.environ.get("HERDR_ANSI_EXPORT_DIR", PUBLIC / "data/allocation")
)
RAW = BASE / "raw"
EXPECTED = {
    "master": ("06ca0baa12f4203c5bbad9ecadf53f9a475a52b2", "signed-master", "master-probe-get-task-allow", "9E25FDD4-FBEE-30B0-8474-C85D035C943C"),
    "candidate": ("d00dc4813d6803ce4efa3e9ad7b1c3533512aaff", "signed-candidate", "candidate-probe-get-task-allow", "A7DF9D1F-9662-3648-842A-67D95B572A1C"),
}
TARGET_SYMBOLS = {
    "master": ("ansi_instruments_probe", "BlitEncoder"),
    "candidate": ("ansi_instruments_probe", "BlitEncoder", "write_cell", "encode_inner", "write_sgr"),
}
PRIVATE = (str(Path.home()), os.uname().nodename)
STAT_FIELDS = (
    "persistent-bytes", "count-persistent", "total-bytes", "transient-bytes",
    "count-events", "count-transient", "count-total",
)
DETAIL_XPATH = (
    '/trace-toc/run[@number="1"]/tracks/track[@name="Allocations"]'
    '/details/detail[@name="{detail}"]'
)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def bundle_identity(path: Path) -> tuple[int, int, str]:
    files = sorted(p for p in path.rglob("*") if p.is_file())
    h = hashlib.sha256()
    total = 0
    for p in files:
        rel = p.relative_to(path).as_posix().encode()
        digest = bytes.fromhex(sha256(p))
        size = p.stat().st_size
        total += size
        h.update(len(rel).to_bytes(4, "big"))
        h.update(rel)
        h.update(size.to_bytes(8, "big"))
        h.update(digest)
    return len(files), total, h.hexdigest()


def xctrace_export(trace: Path, *, toc: bool = False, xpath: str | None = None) -> ET.Element:
    fd, name = tempfile.mkstemp(prefix="herdr-alloc-export-", suffix=".xml")
    os.close(fd)
    tmp = Path(name)
    try:
        cmd = ["xcrun", "xctrace", "export", "--quiet", "--input", str(trace)]
        if toc:
            cmd.append("--toc")
        else:
            assert xpath
            cmd += ["--xpath", xpath]
        cmd += ["--output", str(tmp)]
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
        return ET.parse(tmp).getroot()
    finally:
        tmp.unlink(missing_ok=True)


def toc_metadata(toc: ET.Element, target_name: str) -> tuple[str, float, str, str, list[str], list[str]]:
    run = toc.find('./run[@number="1"]')
    if run is None:
        raise AssertionError("run 1 missing")
    target = run.find("./info/target/process")
    if target is None or target.get("name") != target_name:
        raise AssertionError(f"wrong target: {target.attrib if target is not None else None}")
    if target.get("type") != "attached" or target.get("return-exit-status") != "0":
        raise AssertionError(f"target did not attach and exit cleanly: {target.attrib}")
    duration = float(run.findtext("./info/summary/duration", "0"))
    template = run.findtext("./info/summary/template-name", "")
    end_reason = run.findtext("./info/summary/end-reason", "")
    tracks = [x.get("name", "") for x in run.findall("./tracks/track")]
    details = [x.get("name", "") for x in run.findall("./tracks/track/details/detail")]
    return target.get("pid", ""), duration, template, end_reason, tracks, details


def schema_details(toc: ET.Element) -> list[tuple[str, str, str]]:
    return [
        (table.get("schema", ""), table.get("target-pid", ""), table.get("documentation", ""))
        for table in toc.findall('.//run[@number="1"]//data/table')
    ]


def issue_summary(trace: Path) -> list[tuple[int, int, str]]:
    db = trace / "Trace1.run/RunIssues.storedata"
    with sqlite3.connect(db) as conn:
        rows = conn.execute("select ZTYPE, ZCOUNT, ZMESSAGE from ZISSUE order by Z_PK").fetchall()
    return [(int(t), int(c), str(m)) for t, c, m in rows]


def symbols(trace: Path, needles: tuple[str, ...]) -> list[str]:
    text = b"".join(p.read_bytes() for p in sorted((trace / "symbols/stores").glob("*.symbolsarchive")))
    return [needle for needle in needles if needle.encode() in text]


def probe_validation(revision: str, commit: str) -> tuple[float, float]:
    text = (RAW / f"signed-{revision}.probe.stdout.log").read_text()
    result = re.search(
        rf"INSTRUMENTS_RESULT revision={commit} mode=allocations frames=(\d+) "
        rf"elapsed_seconds=([0-9.]+) output_bytes=(\d+) output_hash=([0-9a-f]+) "
        rf"allocator=production-system counting_allocator=false",
        text,
    )
    if not result or (result.group(1), result.group(3), result.group(4)) != (
        "5", "276444", "edfa0379543ed13d"
    ):
        raise AssertionError(f"probe protocol failed: {revision}")
    ready = re.search(r"INSTRUMENTS_READY .* warmups=(\d+) width=(\d+) height=(\d+) cells=(\d+)", text)
    if not ready or ready.groups() != ("20", "200", "50", "10000"):
        raise AssertionError(f"probe READY protocol failed: {revision}")
    finished = re.search(r"test result: ok\..* finished in ([0-9.]+)s", text)
    if not finished:
        raise AssertionError(f"test duration missing: {revision}")
    return float(result.group(2)), float(finished.group(1))


def allocation_rows(trace: Path, detail: str) -> list[dict[str, str]]:
    root = xctrace_export(trace, xpath=DETAIL_XPATH.format(detail=detail))
    return [dict(row.attrib) for row in root.findall(".//row")]


def validate_statistics(rows: list[dict[str, str]]) -> dict[str, str]:
    by_name = {row["category"]: row for row in rows}
    heap = by_name["All Heap Allocations"]
    anon = by_name["All Anonymous VM"]
    combined = by_name["All Heap & Anonymous VM"]
    for field in STAT_FIELDS:
        assert int(combined[field]) == int(heap[field]) + int(anon[field]), field
    assert int(heap["count-total"]) == int(heap["count-persistent"]) + int(heap["count-transient"])
    assert int(heap["total-bytes"]) == int(heap["persistent-bytes"]) + int(heap["transient-bytes"])
    return heap


def oa_summary(trace: Path) -> tuple[str, int, int, int, str]:
    files = list((trace / "Trace1.run").glob("event_data_*.oa"))
    if len(files) != 1:
        raise AssertionError(f"expected one OA file: {files}")
    path = files[0]
    data = path.read_bytes()
    nonzero = sum(byte != 0 for byte in data)
    last_nonzero = max((i for i, byte in enumerate(data) if byte), default=-1)
    return path.name, len(data), nonzero, last_nonzero, sha256(path)


def shared_allocation_data(trace: Path) -> tuple[int, str]:
    archives = list(trace.glob("shared_data/1.run/*.zip"))
    if len(archives) != 1:
        raise AssertionError(f"expected one shared archive: {archives}")
    with zipfile.ZipFile(archives[0]) as archive:
        names = archive.namelist()
        if len(names) != 1:
            raise AssertionError(f"unexpected shared archive: {names}")
        data = archive.read(names[0])
    if b"com.apple.Instruments.AllocationsDescriptor" not in data or b"XRObjectAllocEvent" not in data:
        raise AssertionError("native allocation descriptors missing")
    return len(data), hashlib.sha256(data).hexdigest()


def caller_family(row: dict[str, str]) -> str:
    caller = row.get("responsible-caller", "")
    if caller == "<Call stack limit reached>":
        return "call-stack-limit-reached"
    if "thread_parking" in caller and "Parker" in caller:
        return "rust-thread-parker-drop"
    return "other"


def privacy_check(paths: list[Path]) -> None:
    for path in paths:
        text = path.read_text(errors="replace")
        for value in PRIVATE:
            if value and value in text:
                raise AssertionError(f"private value in {path.name}")
        if re.search(r"/(Users|home)/[^/<]+/", text):
            raise AssertionError(f"user path in {path.name}")


def require_external_root(label: str, path: Path) -> Path:
    helper = PUBLIC / "scripts/ansi-private-root-safety.sh"
    command = 'source "$1"; ansi_safe_external_root "$2" "$3"'
    try:
        result = subprocess.run(
            ["bash", "-c", command, "ansi-root-check", os.fspath(helper), os.fspath(ROOT), os.fspath(path)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError):
        # Do not repeat the unsafe path or helper diagnostics: they can contain
        # the private value that this boundary exists to protect.
        raise SystemExit(f"{label} failed canonical external-root validation") from None
    output = result.stdout
    if not output.endswith(b"\n") or output.count(b"\n") != 1 or b"\r" in output:
        raise SystemExit(f"{label} produced an unsafe canonical transport")
    try:
        return Path(output[:-1].decode("utf-8"))
    except UnicodeDecodeError:
        raise SystemExit(f"{label} produced a non-UTF-8 canonical path") from None


def main() -> None:
    if sys.argv[1:] != ["export"]:
        print(
            "usage: export-ansi-allocations-retry.py export\n"
            "Set HERDR_ANSI_PRIVATE_ROOT and HERDR_ANSI_EXPORT_DIR to safe external roots.",
            file=sys.stderr,
        )
        raise SystemExit(0 if sys.argv[1:] in (["-h"], ["--help"]) else 2)
    if PRIVATE_ROOT is None:
        raise SystemExit("HERDR_ANSI_PRIVATE_ROOT must name the private capture directory")
    private_root = require_external_root("HERDR_ANSI_PRIVATE_ROOT", PRIVATE_ROOT)
    export_root = require_external_root("HERDR_ANSI_EXPORT_DIR", EXPORT)
    if export_root == PUBLIC / "data/allocation" or PUBLIC in export_root.parents:
        raise SystemExit("refusing to overwrite tracked public evidence")
    globals()["BASE"] = private_root / "profiles/retry-after-security-change"
    globals()["TRACES"] = BASE / "traces"
    globals()["RAW"] = BASE / "raw"
    globals()["EXPORT"] = export_root
    if not TRACES.is_dir():
        raise SystemExit(f"private trace directory is missing: {TRACES}")
    marker = EXPORT / ".herdr-ansi-allocation-export"
    if require_external_root("HERDR_ANSI_EXPORT_DIR", EXPORT) != EXPORT:
        raise SystemExit("HERDR_ANSI_EXPORT_DIR changed before sentinel inspection")
    if EXPORT.exists() and any(EXPORT.iterdir()) and not marker.is_file():
        raise SystemExit("HERDR_ANSI_EXPORT_DIR is non-empty and lacks the ownership sentinel")
    # Re-resolve immediately before the first write. This narrows but cannot
    # eliminate replacement races between validation and filesystem mutation.
    if require_external_root("HERDR_ANSI_EXPORT_DIR", EXPORT) != EXPORT:
        raise SystemExit("HERDR_ANSI_EXPORT_DIR changed before write")
    EXPORT.mkdir(parents=True, exist_ok=True)
    marker.write_text("owned sanitized allocation export\n")
    schemas_path = EXPORT / "allocation-schemas.tsv"
    surfaces_path = EXPORT / "allocation-export-surfaces.tsv"
    statistics_path = EXPORT / "allocation-statistics.tsv"
    callers_path = EXPORT / "allocation-list-callers.tsv"
    counting_path = EXPORT / "counting-allocator-context.tsv"
    traces_path = EXPORT / "allocation-trace-summary.tsv"
    validation_path = EXPORT / "allocation-validation.tsv"
    toc_path = EXPORT / "toc-inspection.txt"

    schema_lines = ["trace\trun\tschema\ttarget_scope\tdocumentation"]
    surface_lines = ["trace\tsurface\tname\texportable\tscope"]
    stat_lines = ["revision\tcategory\tpersistent_bytes\tpersistent_count\ttransient_bytes\ttransient_count\ttotal_bytes\ttotal_count\tevent_count"]
    caller_lines = ["revision\tcaller_family\tlisted_live_allocations\tlisted_live_bytes\tlisted_rows_scope\tcompleteness"]
    trace_lines = ["trace\tcommit\tdisk_kib\tlogical_bytes\tfile_count\tbundle_manifest_sha256\tstatus"]
    val_lines = [
        "revision\ttarget_name\ttarget_pid\trecording_seconds\tprobe_test_seconds\tconservative_pretrigger_seconds\tprotocol\toracle\trun_issues\ttarget_uuid_archive\toa_bytes\toa_nonzero_bytes\tshared_allocation_bytes\theap_persistent_count\theap_transient_count\theap_total_count\theap_persistent_bytes\theap_transient_bytes\theap_total_bytes\tstatistics_rows\tallocation_list_rows\tallocation_list_live_rows\tcallsite_export"
    ]
    toc_lines = [
        "Xcode 26.6 (17F113), xctrace 16.0 (17F113)",
        "Run-1 Allocation track inspection; private device and path fields omitted.",
    ]

    for revision, (commit, trace_name, target_name, target_uuid) in EXPECTED.items():
        trace = TRACES / f"{trace_name}.trace"
        toc = xctrace_export(trace, toc=True)
        pid, duration, template, end_reason, tracks, details = toc_metadata(toc, target_name)
        if template != "Allocations" or end_reason != "Target app exited":
            raise AssertionError(f"unexpected trace summary: {template}, {end_reason}")
        if "Allocations" not in tracks or details[:2] != ["Statistics", "Allocations List"]:
            raise AssertionError(f"allocation track/details missing: {tracks}, {details}")
        for schema, scope, documentation in schema_details(toc):
            schema_lines.append(f"{trace_name}\t1\t{schema}\t{scope or 'unspecified'}\t{documentation}")
        for track in toc.findall('.//run[@number="1"]/tracks/track'):
            surface_lines.append(f"{trace_name}\ttrack\t{track.get('name', '')}\tmetadata-only\trun-1")
            for detail in track.findall("./details/detail"):
                name = detail.get("name", "")
                exportable = "yes" if track.get("name") == "Allocations" and name in {"Statistics", "Allocations List"} else "not-tested"
                surface_lines.append(f"{trace_name}\ttrack-detail\t{name}\t{exportable}\t{track.get('name', '')}")

        stats = allocation_rows(trace, "Statistics")
        listed = allocation_rows(trace, "Allocations List")
        heap = validate_statistics(stats)
        if not listed or any(row.get("live") != "true" for row in listed):
            raise AssertionError(f"unexpected Allocation List semantics: {revision}")
        for row in stats:
            stat_lines.append(
                f"{revision}\t{row['category']}\t{row['persistent-bytes']}\t{row['count-persistent']}\t"
                f"{row['transient-bytes']}\t{row['count-transient']}\t{row['total-bytes']}\t"
                f"{row['count-total']}\t{row['count-events']}"
            )
        caller_counts: Counter[str] = Counter()
        caller_bytes: Counter[str] = Counter()
        for row in listed:
            family = caller_family(row)
            caller_counts[family] += 1
            caller_bytes[family] += int(row["size"])
        for family in sorted(caller_counts):
            caller_lines.append(
                f"{revision}\t{family}\t{caller_counts[family]}\t{caller_bytes[family]}\t"
                "end-of-recording-live-list\tincomplete-versus-statistics"
            )

        issues = issue_summary(trace)
        if issues != [(2, 1, "Data stream: Time Mapping")]:
            raise AssertionError(f"unexpected run issues for {revision}: {issues}")
        markers = symbols(trace, TARGET_SYMBOLS[revision])
        if len(markers) != len(TARGET_SYMBOLS[revision]):
            raise AssertionError(f"target symbols missing for {revision}: {markers}")
        uuid_archive = trace / "symbols/stores" / f"{target_uuid}.symbolsarchive"
        if not uuid_archive.is_file():
            raise AssertionError(f"target UUID symbol archive missing: {revision}")
        frame_seconds, test_seconds = probe_validation(revision, commit)
        conservative_margin = duration - (test_seconds - 2.0)
        if conservative_margin <= 0:
            raise AssertionError(f"frame interval not proven inside trace: {revision}")
        oa_name, oa_bytes, oa_nonzero, oa_last, oa_hash = oa_summary(trace)
        shared_bytes, shared_hash = shared_allocation_data(trace)
        files, logical, manifest = bundle_identity(trace)
        disk_kib = int(subprocess.check_output(["du", "-sk", str(trace)], text=True).split()[0])
        trace_lines.append(
            f"{trace_name}\t{commit}\t{disk_kib}\t{logical}\t{files}\t{manifest}\taccepted-native-allocation-capture"
        )
        val_lines.append(
            f"{revision}\t{target_name}\t{pid}\t{duration:.6f}\t{test_seconds:.2f}\t{conservative_margin:.6f}\t"
            f"pass\tpass\ttime-mapping-info-only\tpass\t{oa_bytes}\t{oa_nonzero}\t{shared_bytes}\t"
            f"{heap['count-persistent']}\t{heap['count-transient']}\t{heap['count-total']}\t"
            f"{heap['persistent-bytes']}\t{heap['transient-bytes']}\t{heap['total-bytes']}\t"
            f"{len(stats)}\t{len(listed)}\t{len(listed)}\tblocked-incomplete-live-list-no-transient-callers"
        )
        toc_lines += [
            f"revision={revision}",
            f"target={target_name} pid={pid} attached=true exit=0 duration_seconds={duration:.6f}",
            "template=Allocations record=Heap-and-VM freed-memory=Keep-events types=All",
            f"tracks={','.join(tracks)}",
            f"allocation_details={','.join(details[:2])}",
            f"oa={oa_name} bytes={oa_bytes} nonzero_bytes={oa_nonzero} last_nonzero_offset={oa_last} sha256={oa_hash}",
            f"shared_allocation_data_bytes={shared_bytes} sha256={shared_hash}",
            f"core_schema_count={len(schema_details(toc))} allocation_named_core_schema_count=0",
            "statistics_xpath=run-1/track:Allocations/detail:Statistics exportable=true",
            "allocation_list_xpath=run-1/track:Allocations/detail:Allocations-List exportable=true",
            "callsite_status=blocked: exported list contains live rows only and is incomplete versus Statistics; transient responsible callers are absent",
        ]

    rejected = (
        ("original-master", EXPECTED["master"][0], "rejected-attach-failure"),
        ("original-candidate", EXPECTED["candidate"][0], "rejected-attach-failure"),
        ("minimal-c-original", "not-applicable", "rejected-host-wide-attach-failure"),
    )
    for trace_name, commit, status in rejected:
        trace = TRACES / f"{trace_name}.trace"
        files, logical, manifest = bundle_identity(trace)
        disk_kib = int(subprocess.check_output(["du", "-sk", str(trace)], text=True).split()[0])
        trace_lines.append(f"{trace_name}\t{commit}\t{disk_kib}\t{logical}\t{files}\t{manifest}\t{status}")

    evidence = json.loads((PUBLIC / "data/results.json").read_text())
    context_lines = ["revision\tcells\tmeasured_frames\tcounting_allocator_operations_per_frame\tcounting_allocator_requested_bytes_per_frame\tdefinition"]
    for revision in ("master", "candidate"):
        row = next(x for x in evidence["allocation_scaling"] if x["revision"] == revision and x["cells"] == 10000)
        context_lines.append(
            f"{revision}\t10000\t{evidence['protocol']['allocation_measured_frames']}\t{row['allocations']}\t{row['requested_bytes']}\t"
            "test-counting allocator requests delegated to System; context only, not xctrace equality"
        )

    outputs = {
        schemas_path: "\n".join(schema_lines) + "\n",
        surfaces_path: "\n".join(surface_lines) + "\n",
        statistics_path: "\n".join(stat_lines) + "\n",
        callers_path: "\n".join(caller_lines) + "\n",
        counting_path: "\n".join(context_lines) + "\n",
        traces_path: "\n".join(trace_lines) + "\n",
        validation_path: "\n".join(val_lines) + "\n",
        toc_path: "\n".join(toc_lines) + "\n",
    }
    for path, text in outputs.items():
        path.write_text(text)
    privacy_check(list(outputs))
    leftovers = list(Path(tempfile.gettempdir()).glob("herdr-alloc-export-*.xml"))
    if leftovers:
        raise AssertionError(f"unsanitized XML leftovers: {leftovers}")


if __name__ == "__main__":
    main()
