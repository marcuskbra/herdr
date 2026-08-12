#!/usr/bin/env python3
"""Generate deterministic Phase 1 ANSI encoder evidence charts."""

from __future__ import annotations

import hashlib
import html
import json
import math
import os
import re
import statistics
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
EVIDENCE = Path(
    os.environ.get("HERDR_ANSI_PUBLIC_ROOT", ROOT / "performance/ansi-encoder")
).resolve()
RESULTS_PATH = EVIDENCE / "data/results.json"
ECDF_RESULTS_PATH = EVIDENCE / "data/ordered-batches.json"
ECDF_TSV_PATH = EVIDENCE / "data/ordered-batches.tsv"
OUT = EVIDENCE / "charts"
MASTER = "06ca0baa"
CANDIDATE = "d00dc481"
MASTER_COLOUR = "#343A40"
MASTER_LIGHT = "#6C757D"
CANDIDATE_COLOUR = "#1769AA"
TEXT = "#202428"
MUTED = "#59636E"
GRID = "#D8DDE2"
PANEL = "#F7F8FA"
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif"
MONO = "ui-monospace, 'SFMono-Regular', Menlo, Consolas, monospace"
WORKLOADS = ["dense_colour", "plain_scroll", "sparse_edit", "full_redraw"]
WORKLOAD_LABELS = {
    "dense_colour": "Dense colour",
    "plain_scroll": "Plain scroll",
    "sparse_edit": "Sparse edit",
    "full_redraw": "Full redraw",
}


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def attrs(**values: object) -> str:
    names = {"class_": "class"}
    return " ".join(
        f'{names.get(key, key.replace("_", "-"))}="{esc(value)}"'
        for key, value in values.items()
    )


class SVG:
    def __init__(self, width: int, height: int, title: str, description: str):
        self.width = width
        self.height = height
        self.parts = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
            f'width="{width}" height="{height}" role="img" aria-labelledby="title desc">',
            f"<title id=\"title\">{esc(title)}</title>",
            f"<desc id=\"desc\">{esc(description)}</desc>",
            "<style>",
            f"text {{ font-family: {FONT}; fill: {TEXT}; }}",
            f".mono {{ font-family: {MONO}; }}",
            ".title { font-size: 30px; font-weight: 700; }",
            ".subtitle { font-size: 15px; fill: #59636E; }",
            ".panel-title { font-size: 19px; font-weight: 700; }",
            ".label { font-size: 14px; }",
            ".small { font-size: 12px; fill: #59636E; }",
            ".tiny { font-size: 11px; fill: #59636E; }",
            ".metric { font-size: 15px; font-weight: 700; }",
            "</style>",
            f'<rect width="{width}" height="{height}" fill="#FFFFFF"/>',
        ]

    def add(self, tag: str, content: str | None = None, **values: object) -> None:
        if content is None:
            self.parts.append(f"<{tag} {attrs(**values)}/>")
        else:
            self.parts.append(f"<{tag} {attrs(**values)}>{esc(content)}</{tag}>")

    def raw(self, value: str) -> None:
        self.parts.append(value)

    def finish(self) -> str:
        return "\n".join([*self.parts, "</svg>", ""])


def text(svg: SVG, x: float, y: float, value: object, css: str = "label", **extra: object) -> None:
    svg.add("text", str(value), x=f"{x:.1f}", y=f"{y:.1f}", class_=css, **extra)


def line(svg: SVG, x1: float, y1: float, x2: float, y2: float, **extra: object) -> None:
    svg.add("line", x1=f"{x1:.1f}", y1=f"{y1:.1f}", x2=f"{x2:.1f}", y2=f"{y2:.1f}", **extra)


def circle(svg: SVG, x: float, y: float, radius: float, fill: str, stroke: str, width: float = 2) -> None:
    svg.add("circle", cx=f"{x:.1f}", cy=f"{y:.1f}", r=radius, fill=fill, stroke=stroke, stroke_width=width)


def square(svg: SVG, x: float, y: float, size: float, fill: str, stroke: str, width: float = 2) -> None:
    svg.add(
        "rect", x=f"{x - size / 2:.1f}", y=f"{y - size / 2:.1f}", width=size,
        height=size, fill=fill, stroke=stroke, stroke_width=width,
    )


def log_scale(value: float, low: float, high: float, start: float, end: float) -> float:
    return start + (math.log10(value) - math.log10(low)) / (math.log10(high) - math.log10(low)) * (end - start)


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_hash() -> str:
    return file_hash(RESULTS_PATH)


def parse_fields(line_value: str) -> dict[str, str]:
    return dict(re.findall(r"([a-z_]+)=([^ ]+)", line_value))


def load_and_validate() -> tuple[dict, str, bool]:
    data = json.loads(RESULTS_PATH.read_text())
    assert data["revisions"]["master"].startswith(MASTER)
    assert data["revisions"]["candidate"].startswith(CANDIDATE)
    protocol = data["protocol"]
    assert protocol["timing_processes_per_revision"] == 3
    assert protocol["timing_samples"] == 100
    assert protocol["frames_per_sample"] == 10
    assert protocol["allocation_scaling_cells"] == [1, 10, 100, 1000, 10000]

    by_key: dict[tuple[str, str], list[int]] = {}
    for record in data["timing_processes"]:
        by_key.setdefault((record["workload"], record["revision"]), []).append(record["median_ns"])
    for aggregate in data["timing_aggregates"]:
        workload = aggregate["workload"]
        for revision in ("master", "candidate"):
            values = by_key[(workload, revision)]
            assert values == aggregate[revision]["process_medians_ns"]
            assert statistics.median(values) == aggregate[revision]["median_of_process_medians_ns"]
        master = aggregate["master"]["median_of_process_medians_ns"]
        candidate = aggregate["candidate"]["median_of_process_medians_ns"]
        assert math.isclose(aggregate["time_reduction_percent"], (1 - candidate / master) * 100)
        assert math.isclose(aggregate["speedup"], master / candidate)

    assert len(data["timing_processes"]) == 24
    assert len(data["allocation_scaling"]) == 10
    assert all(item["matching"] for item in data["equivalence"])
    return data, source_hash(), True


def header(svg: SVG, title_value: str, subtitle: str) -> None:
    text(svg, 70, 58, title_value, "title")
    text(svg, 70, 88, subtitle, "subtitle")


def metadata(svg: SVG, **values: str) -> None:
    svg.raw("<metadata>" + esc(json.dumps(values, sort_keys=True)) + "</metadata>")


def footer(svg: SVG, y: int, digest: str) -> None:
    line(svg, 70, y - 23, svg.width - 70, y - 23, stroke=GRID, stroke_width=1)
    text(svg, 70, y, f"master {MASTER}  |  candidate {CANDIDATE}", "small mono")
    text(svg, svg.width - 70, y, f"audit SHA-256 {digest[:12]}...", "tiny mono", text_anchor="end")


def draw_revision_marker(svg: SVG, revision: str, x: float, y: float, large: bool = False) -> None:
    size = 12 if large else 8
    if revision == "master":
        square(svg, x, y, size, "#FFFFFF", MASTER_COLOUR, 2.5 if large else 2)
    else:
        circle(svg, x, y, size / 2, CANDIDATE_COLOUR, CANDIDATE_COLOUR, 2)


def latency_chart(data: dict, digest: str) -> str:
    svg = SVG(1600, 1120, "ANSI encoder process medians", "Four aligned workload panels show three independent process medians per revision and each median-of-medians on a logarithmic latency axis.")
    header(svg, "ANSI encoder latency: independent process medians", "Lower is better. Log axis; each point is one fresh process median from 100 batches of 10 encodes.")
    text(svg, 70, 119, "Open squares / dashed: master. Blue circles / solid: candidate. Enlarged marker: median-of-medians.", "small")
    x0, x1 = 360, 1020
    low, high = 20_000, 4_000_000
    ticks = [(20_000, "20 µs"), (50_000, "50 µs"), (100_000, "100 µs"), (200_000, "200 µs"), (500_000, "500 µs"), (1_000_000, "1 ms"), (2_000_000, "2 ms"), (4_000_000, "4 ms")]
    panels = {item["workload"]: item for item in data["timing_aggregates"]}
    for index, workload in enumerate(WORKLOADS):
        aggregate = panels[workload]
        top = 145 + index * 224
        bottom = top + 200
        svg.add("rect", x=70, y=top, width=1460, height=200, rx=8, fill=PANEL)
        text(svg, 92, top + 31, WORKLOAD_LABELS[workload], "panel-title")
        reduction = aggregate["time_reduction_percent"]
        speedup = aggregate["speedup"]
        metric = f"{reduction:.2f}% lower  |  {speedup:.2f}×"
        text(svg, 1505, top + 31, metric, "metric", text_anchor="end")
        for tick, label in ticks:
            x = log_scale(tick, low, high, x0, x1)
            line(svg, x, top + 50, x, bottom - 25, stroke=GRID, stroke_width=1)
            text(svg, x, bottom - 8, label, "tiny", text_anchor="middle")
        for row, revision in enumerate(("master", "candidate")):
            y = top + 87 + row * 58
            values = aggregate[revision]["process_medians_ns"]
            mom = aggregate[revision]["median_of_process_medians_ns"]
            colour = MASTER_COLOUR if revision == "master" else CANDIDATE_COLOUR
            dash = "6 5" if revision == "master" else "none"
            name = f"master {MASTER}" if revision == "master" else f"candidate {CANDIDATE}"
            text(svg, 92, y + 5, name, "label mono")
            positions = [log_scale(value, low, high, x0, x1) for value in values]
            line(svg, min(positions), y, max(positions), y, stroke=colour, stroke_width=2, stroke_dasharray=dash)
            for point_index, x in enumerate(positions):
                # A small vertical dodge keeps all three marks visible when
                # process medians are nearly identical; x remains exact.
                marker_y = y + (-5, 0, 5)[point_index]
                draw_revision_marker(svg, revision, x, marker_y, values[point_index] == mom)
            text(svg, 1050, y + 5, ", ".join(f"{value:,}" for value in values) + " ns", "small mono")
            text(svg, 1505, y + 5, f"MoM {mom:,} ns", "label mono", text_anchor="end")
    text(svg, 70, 1060, "Protocol: 200×50 workloads; 20 warm-ups; 3 fresh processes/revision; 100 timed batches/process; 10 encodes/batch; 30 s pre-process cooldown; counterbalanced order.", "small")
    metadata(svg, results_json_sha256=digest)
    footer(svg, 1095, digest)
    return svg.finish()


def load_ecdf_and_validate(data: dict) -> tuple[dict, str, str]:
    capture = json.loads(ECDF_RESULTS_PATH.read_text())
    json_digest = file_hash(ECDF_RESULTS_PATH)
    tsv_digest = file_hash(ECDF_TSV_PATH)
    assert capture["revisions"] == data["revisions"]
    protocol = capture["protocol"]
    assert protocol["dimensions"] == [200, 50]
    assert (protocol["warmups"], protocol["batches_per_process"], protocol["encodes_per_batch"]) == (20, 100, 10)
    assert protocol["processes_per_revision"] == 3
    assert protocol["order"] == ["master/candidate", "candidate/master", "master/candidate"]
    assert protocol["cooldown_seconds"] == 30
    assert protocol["replication_unit"] == "process"
    processes = capture["processes"]
    assert len(processes) == 24
    assert sum(len(record["ordered_batch_ns"]) for record in processes) == 2400
    assert len(capture["pre_process_loads"]) == 6
    for workload in WORKLOADS:
        records = [record for record in processes if record["workload"] == workload]
        assert len(records) == 6
        assert len({(record["output_bytes"], record["output_hash"], record["full"]) for record in records}) == 1
        for revision in ("master", "candidate"):
            assert len([record for record in records if record["revision"] == revision]) == 3
    for record in processes:
        ordered = record["ordered_batch_ns"]
        sorted_values = sorted(ordered)
        assert (record["min_ns"], record["median_ns"], record["max_ns"]) == (sorted_values[0], sorted_values[50], sorted_values[-1])
    lines = ECDF_TSV_PATH.read_text().splitlines()
    assert lines[0] == "revision\tround\tside\tworkload\tbatch_index\tlatency_ns"
    assert len(lines) == 2401
    return capture, json_digest, tsv_digest


def ecdf_points(values: list[int], low: float, high: float, left: float, right: float, top: float, bottom: float) -> list[tuple[float, float]]:
    ordered = sorted(values)
    points = []
    for index, value in enumerate(ordered, start=1):
        x = log_scale(value, low, high, left, right)
        y = bottom - index / len(ordered) * (bottom - top)
        points.append((x, y))
    return points


def ecdf_chart(capture: dict, results_digest: str, capture_digest: str, tsv_digest: str) -> str:
    svg = SVG(1600, 1080, "ANSI encoder ordered-batch latency ECDF", "Four workload panels show one empirical cumulative distribution line per fresh process and revision on a logarithmic latency axis. Lines are grouped by revision but never pooled.")
    header(svg, "ANSI encoder latency: within-process ECDFs", "Lower and farther left is better. Log latency axis; one line per fresh process, grouped by revision but unpooled.")
    text(svg, 70, 118, "Batches are repeated observations within a process; the process is the replication unit. Three lines/revision/panel.", "small")
    processes = capture["processes"]
    lows = {w: min(r["min_ns"] for r in processes if r["workload"] == w) / 1.12 for w in WORKLOADS}
    highs = {w: max(r["max_ns"] for r in processes if r["workload"] == w) * 1.12 for w in WORKLOADS}
    for index, workload in enumerate(WORKLOADS):
        col, row = index % 2, index // 2
        panel_x, panel_y = 70 + col * 735, 150 + row * 390
        panel_w, panel_h = 700, 360
        left, right = panel_x + 90, panel_x + 675
        top, bottom = panel_y + 62, panel_y + 295
        svg.add("rect", x=panel_x, y=panel_y, width=panel_w, height=panel_h, rx=8, fill=PANEL)
        text(svg, panel_x + 22, panel_y + 35, WORKLOAD_LABELS[workload], "panel-title")
        for fraction, label in [(0, "0"), (0.25, ".25"), (0.5, ".50"), (0.75, ".75"), (1, "1")]:
            y = bottom - fraction * (bottom - top)
            line(svg, left, y, right, y, stroke=GRID, stroke_width=1)
            text(svg, left - 12, y + 4, label, "tiny", text_anchor="end")
        low, high = lows[workload], highs[workload]
        log_low, log_high = math.log10(low), math.log10(high)
        tick_start, tick_end = math.floor(log_low), math.ceil(log_high)
        tick_values = []
        for exponent in range(tick_start, tick_end + 1):
            for multiplier in (1, 2, 5):
                value = multiplier * 10 ** exponent
                if low <= value <= high:
                    tick_values.append(value)
        for value in tick_values:
            x = log_scale(value, low, high, left, right)
            line(svg, x, top, x, bottom, stroke=GRID, stroke_width=1)
            label = f"{value / 1_000_000:g} ms" if value >= 1_000_000 else f"{value / 1000:g} µs"
            text(svg, x, bottom + 20, label, "tiny", text_anchor="middle")
        for revision in ("master", "candidate"):
            colour = MASTER_COLOUR if revision == "master" else CANDIDATE_COLOUR
            dash = "6 5" if revision == "master" else "none"
            records = sorted((r for r in processes if r["workload"] == workload and r["revision"] == revision), key=lambda r: r["round"])
            for process_index, record in enumerate(records):
                points = ecdf_points(record["ordered_batch_ns"], low, high, left, right, top, bottom)
                svg.add("polyline", points=" ".join(f"{x:.1f},{y:.1f}" for x, y in points), fill="none", stroke=colour, stroke_width=2, stroke_opacity=0.55 + process_index * 0.2, stroke_dasharray=dash, stroke_linejoin="round")
        text(svg, panel_x + 22, panel_y + 340, f"range {min(r['min_ns'] for r in processes if r['workload'] == workload):,}-{max(r['max_ns'] for r in processes if r['workload'] == workload):,} ns", "tiny mono")
    draw_revision_marker(svg, "master", 80, 945, False)
    line(svg, 92, 945, 140, 945, stroke=MASTER_COLOUR, stroke_width=2, stroke_dasharray="6 5")
    text(svg, 150, 950, f"master {MASTER}", "label mono")
    draw_revision_marker(svg, "candidate", 375, 945, False)
    line(svg, 387, 945, 435, 945, stroke=CANDIDATE_COLOUR, stroke_width=2)
    text(svg, 445, 950, f"candidate {CANDIDATE}", "label mono")
    text(svg, 70, 985, "Capture: ansi-encoder-ecdf-rerun  |  24 process-workload vectors  |  2,400 ordered batches", "small mono")
    text(svg, 70, 1012, f"ordered-batches.json {capture_digest[:12]}...  |  TSV {tsv_digest[:12]}...", "tiny mono")
    metadata(svg, results_json_sha256=results_digest, ordered_batches_json_sha256=capture_digest, ordered_batches_tsv_sha256=tsv_digest, capture="ansi-encoder-ecdf-rerun")
    footer(svg, 1052, results_digest)
    return svg.finish()


def polyline(svg: SVG, points: list[tuple[float, float]], revision: str) -> None:
    colour = MASTER_COLOUR if revision == "master" else CANDIDATE_COLOUR
    dash = "7 6" if revision == "master" else "none"
    svg.add("polyline", points=" ".join(f"{x:.1f},{y:.1f}" for x, y in points), fill="none", stroke=colour, stroke_width=3, stroke_dasharray=dash, stroke_linejoin="round")
    for x, y in points:
        draw_revision_marker(svg, revision, x, y, False)


def format_bytes(value: int) -> str:
    return f"{value:,} B"


def allocation_chart(data: dict, digest: str) -> str:
    svg = SVG(1600, 940, "ANSI encoder allocation scaling", "Two logarithmic panels compare allocation operations and requested bytes over five exact cell counts for master and candidate revisions.")
    header(svg, "ANSI encoder allocation scaling", "Lower is better. Log-log axes; five exact dense styled sizes; 20 warm-ups and 10 stable measured frames/point.")
    text(svg, 70, 120, "Open squares / dashed: master. Blue circles / solid: candidate. Counting allocator delegates to System.", "small")
    grouped = {revision: [r for r in data["allocation_scaling"] if r["revision"] == revision] for revision in ("master", "candidate")}
    specs = [
        ("Allocation operations", "allocations", 4, 200_000, lambda value: f"{value:,}"),
        ("Requested bytes", "requested_bytes", 200, 10_000_000, format_bytes),
    ]
    for panel_index, (title_value, key, y_low, y_high, formatter) in enumerate(specs):
        left = 70 + panel_index * 765
        top = 155
        width, height = 700, 600
        plot_left, plot_right = left + 95, left + 590
        plot_top, plot_bottom = top + 70, top + 515
        svg.add("rect", x=left, y=top, width=700, height=600, rx=8, fill=PANEL)
        text(svg, left + 22, top + 37, title_value, "panel-title")
        for cells in [1, 10, 100, 1000, 10000]:
            x = log_scale(cells, 1, 10000, plot_left, plot_right)
            line(svg, x, plot_top, x, plot_bottom, stroke=GRID, stroke_width=1)
            text(svg, x, plot_bottom + 24, f"{cells:,}", "small", text_anchor="middle")
        if key == "allocations":
            y_ticks = [5, 10, 100, 1000, 10000, 100000]
        else:
            y_ticks = [250, 1000, 10000, 100000, 1000000, 10000000]
        for tick in y_ticks:
            y = log_scale(tick, y_low, y_high, plot_bottom, plot_top)
            line(svg, plot_left, y, plot_right, y, stroke=GRID, stroke_width=1)
            label = f"{tick / 1_000_000:g}M" if tick >= 1_000_000 else (f"{tick // 1000}k" if tick >= 1000 else str(tick))
            text(svg, plot_left - 13, y + 4, label, "small", text_anchor="end")
        text(svg, (plot_left + plot_right) / 2, plot_bottom + 48, "Cells", "label", text_anchor="middle")
        for revision in ("master", "candidate"):
            points = [
                (log_scale(r["cells"], 1, 10000, plot_left, plot_right), log_scale(r[key], y_low, y_high, plot_bottom, plot_top))
                for r in grouped[revision]
            ]
            polyline(svg, points, revision)
            end_x, end_y = points[-1]
            label = f"master {formatter(grouped[revision][-1][key])}" if revision == "master" else f"candidate {formatter(grouped[revision][-1][key])}"
            offset = -13 if revision == "master" else 20
            text(svg, end_x - 4, end_y + offset, label, "label mono", text_anchor="end")
        start_y = top + 584
        if key == "allocations":
            text(svg, left + 22, start_y, "10,000 cells: 124,651 → 17 operations; 99.986% fewer.", "metric")
        else:
            requested_reduction = (1 - grouped["candidate"][-1][key] / grouped["master"][-1][key]) * 100
            text(svg, left + 22, start_y, f"10,000 cells: 5,386,440 B → 1,048,568 B; {requested_reduction:.2f}% lower.", "metric")
    text(svg, 70, 797, "Exact sizes: 1, 10, 100, 1,000 and 10,000 cells (1×1, 10×1, 100×1, 100×10 and 200×50).", "label")
    text(svg, 70, 827, "Every paired point has exact output byte/hash equivalence. Requested bytes are allocator requests, not RSS or retained memory.", "label")
    text(svg, 70, 857, "Each revision suite followed a 30 s cooldown; counts and requested bytes were stable across the 10 measured frames at each point.", "small")
    metadata(svg, results_json_sha256=digest, allocation_operations_reduction_exact="99.98636192248759%", requested_bytes_reduction_exact="80.53319075307624%")
    footer(svg, 910, digest)
    return svg.finish()


def main() -> None:
    if sys.argv[1:] != ["generate"]:
        print("usage: generate-ansi-encoder-charts.py generate", file=sys.stderr)
        raise SystemExit(0 if sys.argv[1:] in (["-h"], ["--help"]) else 2)
    data, digest, _prior_raw_samples_available = load_and_validate()
    capture, capture_digest, tsv_digest = load_ecdf_and_validate(data)
    raw_samples_available = True
    OUT.mkdir(parents=True, exist_ok=True)
    charts = {
        "01-latency-process-medians.svg": latency_chart(data, digest),
        "02-latency-ecdf.svg": ecdf_chart(capture, digest, capture_digest, tsv_digest),
        "03-allocation-scaling.svg": allocation_chart(data, digest),
    }
    for name, content in charts.items():
        path = OUT / name
        path.write_text(content)
        ET.parse(path)
    print(f"validated results and retained summaries; results.json SHA-256 {digest}")
    print(f"validated focused capture; ordered-batches.json SHA-256 {capture_digest}")
    print(f"raw 100-batch vectors available: {raw_samples_available}")
    print(f"wrote {len(charts)} deterministic SVG files")


if __name__ == "__main__":
    main()
