#!/usr/bin/env python3
"""Extract sanitized Time Profiler stacks and generate deterministic CPU charts."""

from __future__ import annotations

import argparse
import collections
import hashlib
import html
import os
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PUBLIC = Path(
    os.environ.get("HERDR_ANSI_PUBLIC_ROOT", ROOT / "performance/ansi-encoder")
).resolve()
DATA = PUBLIC / "data"
CHARTS = PUBLIC / "charts"
PRIVATE_ROOT_VALUE = os.environ.get("HERDR_ANSI_PRIVATE_ROOT")
PRIVATE_ROOT = Path(PRIVATE_ROOT_VALUE).resolve() if PRIVATE_ROOT_VALUE else None
PROFILES = (
    PRIVATE_ROOT / "profiles"
    if PRIVATE_ROOT is not None
    else Path("__HERDR_ANSI_PRIVATE_ROOT_REQUIRED__") / "profiles"
)
EXPORT = DATA
COMMITS = {
    "master": "06ca0baa12f4203c5bbad9ecadf53f9a475a52b2",
    "candidate": "d00dc4813d6803ce4efa3e9ad7b1c3533512aaff",
}
TRACE_NAMES = {revision: f"cpu-final-{revision}.trace" for revision in COMMITS}
EXPECTED_BYTES = 276_444
EXPECTED_HASH = "edfa0379543ed13d"
MIN_SPAN_SECONDS = 7.8
MIN_SAMPLES = 7_500
MIN_RESOLVED_SHARE = 0.995
LEAF_OTHER_THRESHOLD = 0.005
MASTER = "#343A40"
MASTER_LIGHT = "#6C757D"
CANDIDATE = "#1769AA"
CANDIDATE_LIGHT = "#5A9BD4"
TEXT = "#202428"
MUTED = "#59636E"
GRID = "#D8DDE2"
PANEL = "#F7F8FA"
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif"
MONO = "ui-monospace, 'SFMono-Regular', Menlo, Consolas, monospace"

FAMILY_DEFINITIONS = [
    ("encode_inner", "BlitEncoder::encode_inner", lambda f: "BlitEncoder::encode_inner" in f),
    ("write_cell", "write_cell", lambda f: "herdr::protocol::render_ansi::write_cell" in f),
    ("alloc_format", "alloc::fmt::format", lambda f: "alloc::fmt::format" in f),
    ("malloc_family", "malloc-containing stack", lambda f: "malloc" in f.lower()),
    ("realloc_family", "realloc-containing stack", lambda f: "realloc" in f.lower()),
    ("build_sgr", "legacy build_sgr", lambda f: "herdr::protocol::render_ansi::build_sgr" in f),
    ("write_sgr", "direct write_sgr family", lambda f: "render_ansi::write_sgr" in f),
    ("write_sgr_colour", "write_sgr_colour", lambda f: "render_ansi::write_sgr_colour" in f),
    ("write_u8_decimal", "write_u8_decimal", lambda f: "render_ansi::write_u8_decimal" in f),
    ("style_key", "SgrStyleKey::from_cell", lambda f: "SgrStyleKey::from_cell" in f),
    ("write_changed_cells", "write_changed_cells", lambda f: "render_ansi::write_changed_cells" in f),
]
ABSENT_FAMILIES = {
    ("master", "write_sgr"), ("master", "write_sgr_colour"),
    ("master", "write_u8_decimal"), ("master", "style_key"),
    ("candidate", "build_sgr"),
}


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bundle_manifest_sha256(path: Path) -> tuple[str, int, int]:
    digest = hashlib.sha256()
    total = 0
    count = 0
    for item in sorted(p for p in path.rglob("*") if p.is_file()):
        relative = item.relative_to(path).as_posix()
        data_digest = sha256_file(item)
        size = item.stat().st_size
        digest.update(relative.encode())
        digest.update(b"\0")
        digest.update(str(size).encode())
        digest.update(b"\0")
        digest.update(data_digest.encode())
        digest.update(b"\n")
        total += size
        count += 1
    return digest.hexdigest(), total, count


def normalize_frame(value: str) -> str:
    value = re.sub(r"::h[0-9a-f]{16}$", "", value.strip())
    value = value.replace("\t", " ").replace("\n", " ").replace(";", ",")
    return re.sub(r"\s+", " ", value) or "[unnamed frame]"


def resolved(element: ET.Element, ids: dict[str, ET.Element]) -> ET.Element:
    return ids.get(element.get("ref", ""), element)


def frame_list(backtrace: ET.Element, ids: dict[str, ET.Element]) -> list[tuple[str, str]]:
    result = []
    backtrace = resolved(backtrace, ids)
    for raw_frame in backtrace.findall("frame"):
        frame = resolved(raw_frame, ids)
        name = normalize_frame(frame.get("name", "[unnamed frame]"))
        raw_binary = frame.find("binary")
        binary = resolved(raw_binary, ids).get("name", "") if raw_binary is not None else ""
        result.append((name, binary))
    return result


@dataclass
class Capture:
    revision: str
    samples: int
    span_seconds: float
    resolved_samples: int
    herdr_samples: int
    collapsed: collections.Counter[tuple[str, ...]]
    leaf_counts: collections.Counter[str]
    family_counts: dict[str, int]
    trace_hash: str
    trace_bytes: int
    trace_files: int


def extract_capture(revision: str) -> Capture:
    trace = PROFILES / TRACE_NAMES[revision]
    if not trace.is_dir():
        raise SystemExit(f"missing final trace: {trace}")
    probe_log = (PROFILES / f"raw/cpu-final-{revision}.stdout.log").read_text()
    required_log_values = [
        f"revision={COMMITS[revision]}", "mode=cpu", "width=200 height=50 cells=10000",
        f"output_bytes={EXPECTED_BYTES} output_hash={EXPECTED_HASH}",
        "allocator=production-system counting_allocator=false",
    ]
    if any(value not in probe_log for value in required_log_values):
        raise SystemExit(f"{revision}: probe identity, fixture, allocator, or oracle log validation failed")
    result_match = re.search(r"INSTRUMENTS_RESULT .*?elapsed_seconds=([0-9.]+)", probe_log)
    if result_match is None or float(result_match.group(1)) < 14.0:
        raise SystemExit(f"{revision}: post-trigger work duration was below 14 seconds")
    with tempfile.NamedTemporaryFile(prefix=f"herdr-{revision}-time-profile-", suffix=".xml", delete=False) as handle:
        xml_path = Path(handle.name)
    try:
        subprocess.run(
            [
                "xcrun", "xctrace", "export", "--input", str(trace),
                "--xpath", '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]',
                "--output", str(xml_path),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        root = ET.parse(xml_path).getroot()
    finally:
        xml_path.unlink(missing_ok=True)

    ids = {element.get("id", ""): element for element in root.iter() if element.get("id")}
    identity_lines = (PROFILES / "binary-identities.tsv").read_text().splitlines()
    identity_header = identity_lines[0].split("\t")
    identity_records = [dict(zip(identity_header, line.split("\t"))) for line in identity_lines[1:]]
    expected_uuid = next(record["binary_uuid"] for record in identity_records if record["revision"] == revision)
    probe_binary = f"{revision}-probe"
    trace_uuids = {
        element.get("UUID", "") for element in root.iter("binary")
        if element.get("name") == probe_binary and element.get("UUID")
    }
    if trace_uuids != {expected_uuid}:
        raise SystemExit(f"{revision}: trace target UUID {sorted(trace_uuids)} != binary UUID {expected_uuid}")
    times: list[int] = []
    resolved_samples = 0
    herdr_samples = 0
    collapsed: collections.Counter[tuple[str, ...]] = collections.Counter()
    leaf_counts: collections.Counter[str] = collections.Counter()
    family_counts = {key: 0 for key, _label, _predicate in FAMILY_DEFINITIONS}

    rows = list(root.iter("row"))
    for row in rows:
        sample_time = row.find("sample-time")
        if sample_time is None:
            raise SystemExit(f"{revision}: row lacks sample-time")
        times.append(int((resolved(sample_time, ids).text or "0").strip()))
        tagged = row.find("tagged-backtrace")
        frames_leaf_first: list[tuple[str, str]] = []
        if tagged is not None:
            tagged = resolved(tagged, ids)
            raw_backtrace = tagged.find("backtrace")
            if raw_backtrace is not None:
                frames_leaf_first = frame_list(raw_backtrace, ids)
        if frames_leaf_first:
            resolved_samples += 1
        names = [name for name, _binary in frames_leaf_first]
        for key, _label, predicate in FAMILY_DEFINITIONS:
            if any(predicate(name) for name in names):
                family_counts[key] += 1

        herdr_leaf = next(
            (name for name, binary in frames_leaf_first if binary == probe_binary and "herdr::" in name),
            None,
        )
        if herdr_leaf is not None:
            herdr_samples += 1
            leaf_counts[herdr_leaf] += 1

        probe_indexes = [index for index, (name, binary) in enumerate(frames_leaf_first)
                         if binary == probe_binary and "ansi_instruments_probe" in name]
        if probe_indexes:
            probe_index = max(probe_indexes)
            stack = tuple(name for name, _binary in reversed(frames_leaf_first[: probe_index + 1]))
        elif frames_leaf_first:
            stack = ("[sample outside probe subtree]",)
        else:
            stack = ("[unresolved sample]",)
        collapsed[stack] += 1

    samples = len(rows)
    if samples == 0:
        raise SystemExit(f"{revision}: no time-profile samples")
    span_seconds = (max(times) - min(times)) / 1_000_000_000
    if span_seconds < MIN_SPAN_SECONDS:
        raise SystemExit(f"{revision}: active span {span_seconds:.9f}s is below {MIN_SPAN_SECONDS:.1f}s")
    if samples < MIN_SAMPLES:
        raise SystemExit(f"{revision}: {samples} samples is below {MIN_SAMPLES}")
    if resolved_samples / samples < MIN_RESOLVED_SHARE:
        raise SystemExit(f"{revision}: resolved share {resolved_samples / samples:.6f} is weak")
    if sum(collapsed.values()) != samples or sum(leaf_counts.values()) != herdr_samples:
        raise SystemExit(f"{revision}: extraction arithmetic failed")
    trace_hash, trace_bytes, trace_files = bundle_manifest_sha256(trace)
    return Capture(
        revision, samples, span_seconds, resolved_samples, herdr_samples,
        collapsed, leaf_counts, family_counts, trace_hash, trace_bytes, trace_files,
    )


def write_extracted(captures: dict[str, Capture]) -> None:
    EXPORT.mkdir(parents=True, exist_ok=True)
    collapsed_path = EXPORT / "cpu-final-collapsed-stacks.tsv"
    lines = ["revision\tcount\tstack_root_to_leaf"]
    for revision in ("master", "candidate"):
        capture = captures[revision]
        for stack, count in sorted(capture.collapsed.items(), key=lambda item: (-item[1], item[0])):
            lines.append(f"{revision}\t{count}\t{';'.join(stack)}")
    collapsed_path.write_text("\n".join(lines) + "\n")

    summary = ["revision\tkind\tmetric\tlabel\tcount\tshare_of_all_samples\tstatus"]
    displayed_leaves = {
        name
        for capture in captures.values()
        for name, count in capture.leaf_counts.items()
        if count / capture.samples >= LEAF_OTHER_THRESHOLD
    }

    def leaf_status(revision: str, name: str, count: int) -> str:
        new_tokens = ("::write_sgr", "::write_u8_decimal", "::SgrStyleKey", "::SgrColour", "::SgrModifier")
        old_tokens = ("::build_sgr", "::color_to_sgr_", "::modifier_to_sgr_parts")
        if revision == "master" and any(token in name for token in new_tokens):
            return "absent"
        if revision == "candidate" and any(token in name for token in old_tokens):
            return "absent"
        return "observed" if count else "zero_samples"

    for revision in ("master", "candidate"):
        capture = captures[revision]
        summary.extend([
            f"{revision}\tidentity\tsamples\tall exported CPU samples\t{capture.samples}\t1.000000\tobserved",
            f"{revision}\tidentity\tresolved_stacks\tresolved native backtraces\t{capture.resolved_samples}\t{capture.resolved_samples / capture.samples:.6f}\tobserved",
            f"{revision}\tidentity\therdr_leaf_samples\tinnermost target Herdr frame\t{capture.herdr_samples}\t{capture.herdr_samples / capture.samples:.6f}\tobserved",
            f"{revision}\tidentity\tsample_span_seconds\tfirst-to-last active CPU sample\t\t{capture.span_seconds:.9f}\tobserved",
        ])
        other = capture.samples
        for name in sorted(displayed_leaves, key=lambda value: (-capture.leaf_counts.get(value, 0), value)):
            count = capture.leaf_counts.get(name, 0)
            status = leaf_status(revision, name, count)
            summary.append(f"{revision}\tleaf\t{name}\t{name}\t{count}\t{count / capture.samples:.6f}\t{status}")
            other -= count
        summary.append(f"{revision}\tleaf\tOther\tOther (<0.5% target leaves + non-target/unresolved)\t{other}\t{other / capture.samples:.6f}\tgrouped")
        for key, label, _predicate in FAMILY_DEFINITIONS:
            count = capture.family_counts[key]
            status = "absent" if (revision, key) in ABSENT_FAMILIES else ("zero_samples" if count == 0 else "observed")
            summary.append(f"{revision}\tstack_family\t{key}\t{label}\t{count}\t{count / capture.samples:.6f}\t{status}")
    (EXPORT / "cpu-summary.tsv").write_text("\n".join(summary) + "\n")

    identities = ["trace\tcommit\tdisk_size_kib\tlogical_bytes\tbundle_manifest_sha256\tfile_count\tsamples\tsample_span_seconds\tresolved_samples\tstatus"]
    for revision in ("master", "candidate"):
        capture = captures[revision]
        disk_kib = int(subprocess.check_output(["du", "-sk", str(PROFILES / TRACE_NAMES[revision])], text=True).split()[0])
        identities.append(
            f"cpu-final-{revision}\t{COMMITS[revision]}\t{disk_kib}\t{capture.trace_bytes}\t{capture.trace_hash}\t{capture.trace_files}\t{capture.samples}\t{capture.span_seconds:.9f}\t{capture.resolved_samples}\taccepted-final"
        )
    (DATA / "cpu-trace-summary.tsv").write_text("\n".join(identities) + "\n")


def read_summary() -> tuple[dict[str, dict[str, dict]], dict[str, dict[str, str]]]:
    rows = (EXPORT / "cpu-summary.tsv").read_text().splitlines()
    header = rows[0].split("\t")
    data: dict[str, dict[str, dict]] = {"master": {}, "candidate": {}}
    identities: dict[str, dict[str, str]] = {"master": {}, "candidate": {}}
    for line in rows[1:]:
        record = dict(zip(header, line.split("\t")))
        if record["kind"] == "identity":
            identities[record["revision"]][record["metric"]] = (
                record["share_of_all_samples"] if record["metric"] == "sample_span_seconds" else record["count"]
            )
        else:
            data[record["revision"]][(record["kind"], record["metric"])] = record
    return data, identities


def read_collapsed() -> dict[str, collections.Counter[tuple[str, ...]]]:
    result = {"master": collections.Counter(), "candidate": collections.Counter()}
    lines = (EXPORT / "cpu-final-collapsed-stacks.tsv").read_text().splitlines()
    if lines[0] != "revision\tcount\tstack_root_to_leaf":
        raise SystemExit("unexpected collapsed stack header")
    for line in lines[1:]:
        revision, count, stack = line.split("\t", 2)
        result[revision][tuple(stack.split(";"))] += int(count)
    return result


def validate_sanitized(captures: dict[str, Capture] | None = None) -> tuple[dict, dict, dict]:
    data, identities = read_summary()
    collapsed = read_collapsed()
    for revision in ("master", "candidate"):
        total = sum(collapsed[revision].values())
        declared = int(data[revision].get(("identity", "samples"), {}).get("count", 0)) if False else int(float(identities[revision]["samples"]))
        if total != declared:
            raise SystemExit(f"{revision}: collapsed total {total} != declared {declared}")
        leaf_total = sum(int(record["count"]) for (kind, _metric), record in data[revision].items() if kind == "leaf")
        if leaf_total != declared:
            raise SystemExit(f"{revision}: normalized leaf categories sum to {leaf_total}, not {declared}")
        if captures is not None and total != captures[revision].samples:
            raise SystemExit(f"{revision}: independent sanitized total differs from XML extraction")
    return data, identities, collapsed


class SVG:
    def __init__(self, width: int, height: int, title: str, description: str):
        self.width = width
        self.height = height
        self.parts = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}" role="img" aria-labelledby="title desc">',
            f'<title id="title">{esc(title)}</title>', f'<desc id="desc">{esc(description)}</desc>',
            "<style>", f"text {{ font-family: {FONT}; fill: {TEXT}; }}", f".mono {{ font-family: {MONO}; }}",
            ".title { font-size: 29px; font-weight: 700; }", ".subtitle { font-size: 15px; fill: #59636E; }",
            ".label { font-size: 14px; }", ".small { font-size: 12px; fill: #59636E; }",
            ".tiny { font-size: 11px; fill: #59636E; }", ".value { font-size: 13px; font-weight: 700; }",
            "</style>", f'<rect width="{width}" height="{height}" fill="#FFFFFF"/>',
        ]

    def add(self, tag: str, content: str | None = None, **attrs: object) -> None:
        attr_names = {"class_": "class"}
        attr_text = " ".join(
            f'{attr_names.get(key, key.replace("_", "-"))}="{esc(value)}"'
            for key, value in attrs.items()
        )
        if content is None:
            self.parts.append(f"<{tag} {attr_text}/>")
        else:
            self.parts.append(f"<{tag} {attr_text}>{esc(content)}</{tag}>")

    def raw(self, value: str) -> None:
        self.parts.append(value)

    def finish(self) -> str:
        return "\n".join([*self.parts, "</svg>", ""])


def text(svg: SVG, x: float, y: float, value: object, css: str = "label", **attrs: object) -> None:
    svg.add("text", str(value), x=f"{x:.1f}", y=f"{y:.1f}", class_=css, **attrs)


def line(svg: SVG, x1: float, y1: float, x2: float, y2: float, **attrs: object) -> None:
    svg.add("line", x1=f"{x1:.1f}", y1=f"{y1:.1f}", x2=f"{x2:.1f}", y2=f"{y2:.1f}", **attrs)


def header(svg: SVG, title_value: str, subtitle: str, identities: dict, hashes: dict[str, str]) -> None:
    text(svg, 70, 56, title_value, "title")
    text(svg, 70, 84, subtitle, "subtitle")
    text(svg, 70, 111, f"master: {int(float(identities['master']['samples'])):,} samples / {float(identities['master']['sample_span_seconds']):.3f}s / trace {hashes['master'][:12]}...", "small mono")
    text(svg, 805, 111, f"candidate: {int(float(identities['candidate']['samples'])):,} samples / {float(identities['candidate']['sample_span_seconds']):.3f}s / trace {hashes['candidate'][:12]}...", "small mono")


def footer(svg: SVG, y: int) -> None:
    line(svg, 70, y - 23, svg.width - 70, y - 23, stroke=GRID, stroke_width=1)
    text(svg, 70, y, f"master {COMMITS['master']}  |  candidate {COMMITS['candidate']}", "tiny mono")
    text(svg, svg.width - 70, y, "Xcode 26.6 Time Profiler | 8s each | 200×50 dense fixture | oracle 276444 B / edfa0379543ed13d", "tiny", text_anchor="end")


def short_function(name: str) -> str:
    return name.replace("herdr::protocol::render_ansi::", "").replace("herdr::protocol::wire::", "wire::")


def leaf_chart(data: dict, identities: dict, hashes: dict[str, str]) -> str:
    values: dict[str, dict[str, dict]] = collections.defaultdict(dict)
    for revision in ("master", "candidate"):
        for (kind, metric), record in data[revision].items():
            if kind == "leaf":
                values[metric][revision] = record
    ordered = sorted(values, key=lambda metric: (-max(float(r["share_of_all_samples"]) for r in values[metric].values()), metric))
    height = 280 + len(ordered) * 56
    svg = SVG(1600, height, "Dense ANSI CPU leaf share", "Ranked normalized shares of the innermost target Herdr function in each Time Profiler CPU sample.")
    header(svg, "Dense ANSI CPU: normalized target-leaf share", "Each trace is normalized independently. Leaf = innermost symbol from the target Herdr binary; CPU samples, not speedup.", identities, hashes)
    text(svg, 70, 143, "Master: charcoal open square / dashed. Candidate: blue circle / solid. Values use all samples in that trace as denominator.", "small")
    plot_left, plot_right = 560, 1450
    max_share = max(float(record["share_of_all_samples"]) for revision in values.values() for record in revision.values())
    axis_max = max(0.1, (int(max_share * 10 + 0.999) / 10))
    for tick_index in range(0, 6):
        share = axis_max * tick_index / 5
        x = plot_left + (plot_right - plot_left) * share / axis_max
        line(svg, x, 177, x, height - 92, stroke=GRID, stroke_width=1)
        text(svg, x, 169, f"{share * 100:.0f}%", "tiny", text_anchor="middle")
    for index, metric in enumerate(ordered):
        y = 205 + index * 56
        if index % 2 == 0:
            svg.add("rect", x=70, y=y - 23, width=1460, height=49, fill=PANEL)
        text(svg, 92, y + 5, short_function(metric), "label mono")
        for revision, offset in (("master", -8), ("candidate", 10)):
            record = values[metric].get(revision)
            share = float(record["share_of_all_samples"]) if record else 0.0
            status = record["status"] if record else "absent"
            x = plot_left + (plot_right - plot_left) * share / axis_max
            colour = MASTER if revision == "master" else CANDIDATE
            dash = "6 5" if revision == "master" else "none"
            if status != "absent":
                line(svg, plot_left, y + offset, x, y + offset, stroke=colour, stroke_width=3, stroke_dasharray=dash)
                if revision == "master":
                    svg.add("rect", x=f"{x - 5:.1f}", y=f"{y + offset - 5:.1f}", width=10, height=10, fill="#FFFFFF", stroke=colour, stroke_width=2)
                else:
                    svg.add("circle", cx=f"{x:.1f}", cy=f"{y + offset:.1f}", r=5, fill=colour, stroke=colour)
            label = "absent" if status == "absent" else f"{share * 100:.1f}% ({int(record['count']):,})"
            text(svg, 535, y + offset + 4, ("M " if revision == "master" else "C ") + label, "tiny mono", text_anchor="end")
    text(svg, 70, height - 58, "Other groups target leaves below 0.5% individually plus non-target/unresolved samples. Full categories sum to 100.0% per trace.", "small")
    footer(svg, height - 22)
    return svg.finish()


def family_chart(data: dict, identities: dict, hashes: dict[str, str]) -> str:
    values: dict[str, dict[str, dict]] = collections.defaultdict(dict)
    labels = {}
    for revision in ("master", "candidate"):
        for (kind, metric), record in data[revision].items():
            if kind == "stack_family":
                values[metric][revision] = record
                labels[metric] = record["label"]
    ordered = sorted(values, key=lambda metric: (-max(float(r["share_of_all_samples"]) for r in values[metric].values()), metric))
    height = 310 + len(ordered) * 56
    svg = SVG(1600, height, "Dense ANSI overlapping stack-family share", "Ranked comparative CPU sample shares for overlapping call-stack families. Families must not be added.")
    header(svg, "Dense ANSI CPU: overlapping stack-family share", "FAMILIES OVERLAP AND MUST NOT BE ADDED. Each value is the share of all samples whose native stack contains the family.", identities, hashes)
    text(svg, 70, 143, "Absent = function is not in that revision. 0.0% = present family with zero observed samples. Independent per-trace normalization.", "small")
    plot_left, plot_right = 560, 1450
    for tick_index in range(0, 6):
        share = tick_index / 5
        x = plot_left + (plot_right - plot_left) * share
        line(svg, x, 177, x, height - 92, stroke=GRID, stroke_width=1)
        text(svg, x, 169, f"{share * 100:.0f}%", "tiny", text_anchor="middle")
    for index, metric in enumerate(ordered):
        y = 205 + index * 56
        if index % 2 == 0:
            svg.add("rect", x=70, y=y - 23, width=1460, height=49, fill=PANEL)
        text(svg, 92, y + 5, labels[metric], "label mono")
        for revision, offset in (("master", -8), ("candidate", 10)):
            record = values[metric][revision]
            share = float(record["share_of_all_samples"])
            status = record["status"]
            x = plot_left + (plot_right - plot_left) * share
            colour = MASTER if revision == "master" else CANDIDATE
            if status != "absent":
                line(svg, plot_left, y + offset, x, y + offset, stroke=colour, stroke_width=3, stroke_dasharray="6 5" if revision == "master" else "none")
                if revision == "master":
                    svg.add("rect", x=f"{x - 5:.1f}", y=f"{y + offset - 5:.1f}", width=10, height=10, fill="#FFFFFF", stroke=colour, stroke_width=2)
                else:
                    svg.add("circle", cx=f"{x:.1f}", cy=f"{y + offset:.1f}", r=5, fill=colour, stroke=colour)
            label = "absent" if status == "absent" else f"{share * 100:.1f}% ({int(record['count']):,})"
            text(svg, 535, y + offset + 4, ("M " if revision == "master" else "C ") + label, "tiny mono", text_anchor="end")
    text(svg, 70, height - 58, "Containment is evaluated against complete sanitized native stacks; malloc/realloc and caller families intentionally overlap.", "small")
    footer(svg, height - 22)
    return svg.finish()


@dataclass
class Node:
    name: str
    count: int = 0
    children: dict[str, "Node"] = field(default_factory=dict)


def make_tree(stacks: collections.Counter[tuple[str, ...]]) -> Node:
    root = Node("all CPU samples")
    for stack, count in stacks.items():
        root.count += count
        node = root
        for name in stack:
            child = node.children.setdefault(name, Node(name))
            child.count += count
            node = child
    return root


def display_name(name: str) -> str:
    name = name.replace("herdr::protocol::render_ansi::", "")
    name = name.replace("::_$u7b$$u7b$closure$u7d$$u7d$", "::{closure}")
    return name


def flame_chart(revision: str, stacks: collections.Counter[tuple[str, ...]], identities: dict, hashes: dict[str, str]) -> str:
    root = make_tree(stacks)
    total = root.count
    max_depth = max(len(stack) for stack in stacks)
    width, height = 1600, 370 + max_depth * 30
    svg = SVG(width, height, f"Dense ANSI CPU flame summary: {revision}", "Actual call-tree hierarchy from sanitized native Time Profiler stacks. Widths are independently normalized CPU sample shares.")
    title_revision = "master" if revision == "master" else "candidate"
    header(svg, f"Dense ANSI CPU flame summary: {title_revision}", "Actual native call-tree hierarchy, cropped at ansi_instruments_probe. Width = CPU sample share, not wall-clock speedup.", identities, hashes)
    text(svg, 70, 143, f"{total:,} samples; independent normalization within this trace. Rectangles under 3 px are retained in ancestor widths but not drawn.", "small")
    left, right = 70.0, 1530.0
    plot_width = right - left
    bottom = height - 92
    palette = ["#E4E7EA", "#C9CED3", "#ADB5BD", "#868E96", "#6C757D"] if revision == "master" else ["#DDECF8", "#B8D7EF", "#8DC0E5", "#5A9BD4", "#1769AA"]
    text_colours = [TEXT, TEXT, TEXT, "#FFFFFF", "#FFFFFF"]
    clip_index = 0

    def draw_node(node: Node, x: float, depth: int, parent_width: float) -> None:
        nonlocal clip_index
        node_width = plot_width * node.count / total
        y = bottom - depth * 30
        if node_width >= 3:
            colour_index = min(depth, len(palette) - 1)
            svg.raw(f'<g><title>{esc(node.name)} - {node.count:,} samples ({node.count / total * 100:.1f}%)</title>')
            svg.add("rect", x=f"{x:.2f}", y=f"{y:.1f}", width=f"{node_width:.2f}", height=27, fill=palette[colour_index], stroke="#FFFFFF", stroke_width=1)
            if node_width >= 34:
                clip_id = f"clip-{revision}-{clip_index}"
                clip_index += 1
                svg.raw(f'<clipPath id="{clip_id}"><rect x="{x + 3:.2f}" y="{y:.1f}" width="{max(0, node_width - 6):.2f}" height="27"/></clipPath>')
                text(svg, x + 5, y + 18, display_name(node.name), "tiny mono", style=f"fill:{text_colours[colour_index]}", clip_path=f"url(#{clip_id})")
            svg.raw("</g>")
        child_x = x
        for child in sorted(node.children.values(), key=lambda value: (-value.count, value.name)):
            draw_node(child, child_x, depth + 1, node_width)
            child_x += plot_width * child.count / total

    # The synthetic all-samples container is not rendered; every displayed frame is native.
    child_x = left
    for child in sorted(root.children.values(), key=lambda value: (-value.count, value.name)):
        draw_node(child, child_x, 0, plot_width)
        child_x += plot_width * child.count / total
    text(svg, 70, height - 58, "Source: sanitized collapsed native stacks (root-to-leaf). Outer Rust test-harness frames are cropped; no stack frames are inferred or fabricated.", "small")
    footer(svg, height - 22)
    return svg.finish()


def write_charts(data: dict, identities: dict, collapsed: dict) -> None:
    CHARTS.mkdir(parents=True, exist_ok=True)
    trace_rows = (DATA / "cpu-trace-summary.tsv").read_text().splitlines()
    trace_header = trace_rows[0].split("\t")
    trace_records = [dict(zip(trace_header, row.split("\t"))) for row in trace_rows[1:]]
    hashes = {record["trace"].removeprefix("cpu-final-"): record["bundle_manifest_sha256"] for record in trace_records if record["trace"].startswith("cpu-final-")}
    charts = {
        "04-dense-cpu-leaf-share.svg": leaf_chart(data, identities, hashes),
        "05-dense-cpu-stack-families.svg": family_chart(data, identities, hashes),
        "06-dense-cpu-flame-master.svg": flame_chart("master", collapsed["master"], identities, hashes),
        "07-dense-cpu-flame-candidate.svg": flame_chart("candidate", collapsed["candidate"], identities, hashes),
    }
    for name, content in charts.items():
        path = CHARTS / name
        path.write_text(content)
        ET.parse(path)
        # The public showcase intentionally contains SVG charts only.


def privacy_scan() -> None:
    forbidden = ["/" + "Users" + "/", "HOME=", "probe_pid=", "load averages:"]
    paths = [EXPORT / "cpu-summary.tsv", EXPORT / "cpu-final-collapsed-stacks.tsv", DATA / "cpu-trace-summary.tsv", *sorted(CHARTS.glob("0[4-7]-*.svg"))]
    for path in paths:
        value = path.read_text(errors="replace")
        for token in forbidden:
            if token in value:
                raise SystemExit(f"privacy scan failed: {token!r} in {path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("extract", "generate", "all"), nargs="?", default="all")
    args = parser.parse_args()
    captures = None
    if args.command in ("extract", "all"):
        if PRIVATE_ROOT is None:
            raise SystemExit(
                "HERDR_ANSI_PRIVATE_ROOT must name the private capture directory"
            )
        if PRIVATE_ROOT == ROOT or ROOT in PRIVATE_ROOT.parents:
            raise SystemExit("HERDR_ANSI_PRIVATE_ROOT must be outside the repository")
        captures = {revision: extract_capture(revision) for revision in ("master", "candidate")}
        write_extracted(captures)
    if args.command in ("generate", "all"):
        data, identities, collapsed = validate_sanitized(captures)
        write_charts(data, identities, collapsed)
        privacy_scan()
        for revision in ("master", "candidate"):
            print(f"{revision}: {int(float(identities[revision]['samples'])):,} samples, {float(identities[revision]['sample_span_seconds']):.9f}s")
        print(f"wrote sanitized stacks, summary, identities and four SVGs under {PUBLIC}")


if __name__ == "__main__":
    main()
