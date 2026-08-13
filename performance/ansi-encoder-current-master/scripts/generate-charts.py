#!/usr/bin/env python3
"""Generate deterministic charts for the current-master ANSI encoder addendum."""

from __future__ import annotations

import hashlib
import html
import json
import math
import os
from pathlib import Path
import statistics
import sys
import xml.etree.ElementTree as ET

ROOT = Path(
    os.environ.get(
        "HERDR_ANSI_CURRENT_MASTER_ROOT",
        Path(__file__).resolve().parents[1],
    )
).resolve()
DATA = ROOT / "data"
OUT = ROOT / "charts"
V1 = "#5B6573"
V3 = "#1769AA"
V1_LIGHT = "#B9C0C8"
V3_LIGHT = "#8EC5E8"
TEXT = "#202428"
MUTED = "#59636E"
GRID = "#D8DDE2"
PANEL = "#F7F8FA"
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif"
MONO = "ui-monospace, 'SFMono-Regular', Menlo, Consolas, monospace"
WORKLOADS = ["dense_colour", "plain_scroll", "sparse_edit", "full_redraw"]
LABELS = {
    "dense_colour": "Dense colour",
    "plain_scroll": "Plain scroll",
    "sparse_edit": "Sparse edit",
    "full_redraw": "Full redraw",
}


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def attributes(values: dict[str, object]) -> str:
    aliases = {"class_": "class"}
    return " ".join(
        f'{aliases.get(key, key.replace("_", "-"))}="{esc(value)}"'
        for key, value in values.items()
    )


class SVG:
    def __init__(self, width: int, height: int, title: str, description: str):
        self.width = width
        self.height = height
        self.parts = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            (
                f'<svg xmlns="http://www.w3.org/2000/svg" '
                f'viewBox="0 0 {width} {height}" width="{width}" '
                f'height="{height}" role="img" '
                'aria-labelledby="title desc">'
            ),
            f'<title id="title">{esc(title)}</title>',
            f'<desc id="desc">{esc(description)}</desc>',
            "<style>",
            f"text {{ font-family: {FONT}; fill: {TEXT}; }}",
            f".mono {{ font-family: {MONO}; }}",
            ".title { font-size: 29px; font-weight: 700; }",
            ".subtitle { font-size: 15px; fill: #59636E; }",
            ".panel-title { font-size: 18px; font-weight: 700; }",
            ".label { font-size: 14px; }",
            ".small { font-size: 12px; fill: #59636E; }",
            ".tiny { font-size: 11px; fill: #59636E; }",
            ".metric { font-size: 15px; font-weight: 700; }",
            "</style>",
            f'<rect width="{width}" height="{height}" fill="#FFFFFF"/>',
        ]

    def add(
        self,
        tag: str,
        content: str | None = None,
        **values: object,
    ) -> None:
        attrs = attributes(values)
        if content is None:
            self.parts.append(f"<{tag} {attrs}/>")
        else:
            self.parts.append(f"<{tag} {attrs}>{esc(content)}</{tag}>")

    def raw(self, value: str) -> None:
        self.parts.append(value)

    def finish(self) -> str:
        return "\n".join([*self.parts, "</svg>", ""])


def text(
    svg: SVG,
    x: float,
    y: float,
    value: object,
    css: str = "label",
    **extra: object,
) -> None:
    svg.add(
        "text",
        str(value),
        x=f"{x:.1f}",
        y=f"{y:.1f}",
        class_=css,
        **extra,
    )


def line(
    svg: SVG,
    x1: float,
    y1: float,
    x2: float,
    y2: float,
    **extra: object,
) -> None:
    svg.add(
        "line",
        x1=f"{x1:.1f}",
        y1=f"{y1:.1f}",
        x2=f"{x2:.1f}",
        y2=f"{y2:.1f}",
        **extra,
    )


def header(svg: SVG, title_value: str, subtitle: str) -> None:
    text(svg, 70, 58, title_value, "title")
    text(svg, 70, 87, subtitle, "subtitle")


def footer(svg: SVG, y: int, digest: str) -> None:
    line(svg, 70, y - 24, svg.width - 70, y - 24, stroke=GRID)
    text(svg, 70, y, "V1 49e333ae  |  V3 90f12051", "small mono")
    text(
        svg,
        svg.width - 70,
        y,
        f"summary SHA-256 {digest[:12]}...",
        "tiny mono",
        text_anchor="end",
    )


def metadata(svg: SVG, digest: str, chart: str) -> None:
    value = json.dumps(
        {"chart": chart, "summary_json_sha256": digest},
        sort_keys=True,
    )
    svg.raw(f"<metadata>{esc(value)}</metadata>")


def log_position(
    value: float,
    minimum: float,
    maximum: float,
    start: float,
    end: float,
) -> float:
    fraction = (
        (math.log10(value) - math.log10(minimum))
        / (math.log10(maximum) - math.log10(minimum))
    )
    return start + fraction * (end - start)


def load_summary() -> tuple[dict, str]:
    path = DATA / "summary.json"
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    data = json.loads(path.read_text())
    assert data["revisions"]["V1"]["commit"].startswith("49e333ae")
    assert data["revisions"]["V3"]["commit"].startswith("90f12051")
    assert data["revisions"]["V3"]["sole_parent"] == data["revisions"]["V1"]["commit"]
    return data, digest


def comparison_chart(
    data: dict,
    digest: str,
    *,
    mode: str,
) -> str:
    if mode == "median":
        title_value = "Current-master ANSI encoder median latency"
        subtitle = (
            "Lower is better. Median of three independent process medians; "
            "logarithmic latency axis."
        )
        description = (
            "Four workload panels compare V1 and V3 median latency from the "
            "primary timing run."
        )
        chart_name = "median_process_latency"
        aggregates = data["primary_timing"]["aggregates"]
        get_value = lambda item, revision: item[revision][
            "median_of_process_medians_ns"
        ]
        get_metric = lambda item: f'{item["speedup"]:.2f}x faster'
        note = (
            "Each process: 20 warm-ups, 100 batches, 10 encodes per batch; "
            "the process is the replication unit."
        )
    else:
        title_value = "Current-master ANSI encoder descriptive p95 latency"
        subtitle = (
            "Lower is better. Nearest-rank p95 pooled across 300 retained "
            "batches; logarithmic latency axis."
        )
        description = (
            "Four workload panels compare descriptive pooled p95 latency for "
            "V1 and V3."
        )
        chart_name = "descriptive_pooled_p95_latency"
        aggregates = data["descriptive_p95"]["aggregates"]
        get_value = lambda item, revision: item[revision][
            "pooled_300_batches_p95_ns"
        ]
        get_metric = lambda item: (
            f'{get_value(item, "V1") / get_value(item, "V3"):.2f}x ratio'
        )
        note = (
            "Pooled p95 values describe repeated within-process batches. "
            "They are not independent replications or inferential results."
        )
    svg = SVG(1500, 1040, title_value, description)
    header(svg, title_value, subtitle)
    text(
        svg,
        70,
        117,
        "Grey: V1 current-master baseline. Blue: V3 candidate.",
        "small",
    )
    x0, x1 = 355, 1050
    minimum, maximum = 20_000, 4_000_000
    ticks = [
        (20_000, "20 us"),
        (50_000, "50 us"),
        (100_000, "100 us"),
        (200_000, "200 us"),
        (500_000, "500 us"),
        (1_000_000, "1 ms"),
        (2_000_000, "2 ms"),
        (4_000_000, "4 ms"),
    ]
    by_workload = {item["workload"]: item for item in aggregates}
    for index, workload in enumerate(WORKLOADS):
        item = by_workload[workload]
        top = 145 + index * 194
        svg.add(
            "rect",
            x=70,
            y=top,
            width=1360,
            height=170,
            rx=8,
            fill=PANEL,
        )
        text(svg, 92, top + 31, LABELS[workload], "panel-title")
        text(
            svg,
            1405,
            top + 31,
            get_metric(item),
            "metric",
            text_anchor="end",
        )
        for tick, label in ticks:
            x = log_position(tick, minimum, maximum, x0, x1)
            line(svg, x, top + 48, x, top + 151, stroke=GRID)
            text(svg, x, top + 165, label, "tiny", text_anchor="middle")
        for row, revision in enumerate(("V1", "V3")):
            value = get_value(item, revision)
            y = top + 76 + row * 50
            colour = V1 if revision == "V1" else V3
            x = log_position(value, minimum, maximum, x0, x1)
            text(svg, 92, y + 5, revision, "label mono")
            line(svg, x0, y, x, y, stroke=colour, stroke_width=8)
            svg.add(
                "circle",
                cx=f"{x:.1f}",
                cy=f"{y:.1f}",
                r=7,
                fill=colour,
            )
            text(svg, 1090, y + 5, f"{value:,} ns", "label mono")
    text(svg, 70, 954, note, "small")
    metadata(svg, digest, chart_name)
    footer(svg, 1010, digest)
    return svg.finish()


def allocation_chart(data: dict, digest: str) -> str:
    svg = SVG(
        1500,
        930,
        "Current-master ANSI encoder allocation scaling",
        (
            "Two logarithmic panels compare allocation operations and "
            "requested bytes across five cell counts for V1 and V3."
        ),
    )
    header(
        svg,
        "Current-master ANSI encoder allocation scaling",
        (
            "Lower is better. Five dense styled sizes; both axes are "
            "logarithmic."
        ),
    )
    text(
        svg,
        70,
        117,
        "Grey dashed: V1 current-master baseline. Blue solid: V3 candidate.",
        "small",
    )
    rows = data["allocation_scaling"]
    grouped = {
        revision: [item for item in rows if item["revision"] == revision]
        for revision in ("V1", "V3")
    }
    panels = [
        ("Allocation operations", "allocations", 4, 200_000),
        ("Requested bytes", "requested_bytes", 200, 10_000_000),
    ]
    for panel_index, (title_value, key, low, high) in enumerate(panels):
        left = 70 + panel_index * 715
        top = 150
        plot_left, plot_right = left + 90, left + 625
        plot_top, plot_bottom = top + 75, top + 545
        svg.add(
            "rect",
            x=left,
            y=top,
            width=675,
            height=650,
            rx=8,
            fill=PANEL,
        )
        text(svg, left + 22, top + 38, title_value, "panel-title")
        for cells in (1, 10, 100, 1_000, 10_000):
            x = log_position(cells, 1, 10_000, plot_left, plot_right)
            line(svg, x, plot_top, x, plot_bottom, stroke=GRID)
            text(svg, x, plot_bottom + 23, f"{cells:,}", "small", text_anchor="middle")
        y_ticks = (
            (5, 10, 100, 1_000, 10_000, 100_000)
            if key == "allocations"
            else (250, 1_000, 10_000, 100_000, 1_000_000, 10_000_000)
        )
        for tick in y_ticks:
            y = log_position(tick, low, high, plot_bottom, plot_top)
            line(svg, plot_left, y, plot_right, y, stroke=GRID)
            if tick >= 1_000_000:
                label = f"{tick / 1_000_000:g}M"
            elif tick >= 1_000:
                label = f"{tick / 1_000:g}k"
            else:
                label = str(tick)
            text(svg, plot_left - 12, y + 4, label, "small", text_anchor="end")
        for revision in ("V1", "V3"):
            colour = V1 if revision == "V1" else V3
            dash = "7 6" if revision == "V1" else "none"
            points = [
                (
                    log_position(item["cells"], 1, 10_000, plot_left, plot_right),
                    log_position(item[key], low, high, plot_bottom, plot_top),
                )
                for item in grouped[revision]
            ]
            svg.add(
                "polyline",
                points=" ".join(f"{x:.1f},{y:.1f}" for x, y in points),
                fill="none",
                stroke=colour,
                stroke_width=3,
                stroke_dasharray=dash,
                stroke_linejoin="round",
            )
            for x, y in points:
                svg.add(
                    "circle",
                    cx=f"{x:.1f}",
                    cy=f"{y:.1f}",
                    r=5,
                    fill=colour,
                )
            end = grouped[revision][-1][key]
            x, y = points[-1]
            offset = -13 if revision == "V1" else 22
            text(
                svg,
                x - 4,
                y + offset,
                f"{revision} {end:,}",
                "label mono",
                text_anchor="end",
            )
        metric = (
            "10,000 cells: 124,651 to 17 operations"
            if key == "allocations"
            else "10,000 cells: 5,386,440 to 1,048,568 requested bytes"
        )
        text(svg, left + 22, top + 625, metric, "metric")
    text(
        svg,
        70,
        835,
        (
            "Requested bytes sum allocator request sizes. They are not "
            "retained memory, heap size or resident set size."
        ),
        "small",
    )
    metadata(svg, digest, "allocation_scaling")
    footer(svg, 900, digest)
    return svg.finish()


def race_chart(data: dict, digest: str) -> str:
    race = data["race"]
    v1 = race["aggregate"]["V1"]["fps"]
    v3 = race["aggregate"]["V3"]["fps"]
    svg = SVG(
        1200,
        720,
        "Current-master ANSI encoder race throughput",
        (
            "A horizontal bar chart compares aggregate isolated encoder "
            "throughput for V1 and V3 in an 800 by 600 stress fixture."
        ),
    )
    header(
        svg,
        "Current-master ANSI encoder race throughput",
        (
            "Higher is better. Aggregate frames divided by aggregate elapsed "
            "seconds across two counterbalanced rounds."
        ),
    )
    text(
        svg,
        70,
        117,
        "This 800x600 virtual fixture is an encoder stress test, not a normal terminal frame rate.",
        "small",
    )
    x0, x1 = 250, 1080
    maximum = 125
    for tick in (0, 25, 50, 75, 100, 125):
        x = x0 + tick / maximum * (x1 - x0)
        line(svg, x, 175, x, 515, stroke=GRID)
        text(svg, x, 540, str(tick), "small", text_anchor="middle")
    for index, (revision, value, colour) in enumerate(
        (("V1", v1, V1), ("V3", v3, V3))
    ):
        y = 250 + index * 165
        width = value / maximum * (x1 - x0)
        text(svg, 90, y + 8, revision, "panel-title mono")
        svg.add(
            "rect",
            x=x0,
            y=y - 30,
            width=f"{width:.1f}",
            height=60,
            rx=5,
            fill=colour,
        )
        text(svg, x0 + width + 15, y + 8, f"{value:.3f} FPS", "metric mono")
    text(
        svg,
        70,
        595,
        f'Aggregate ratio: {race["speedup"]:.2f}x. Every race output byte count and hash matched.',
        "metric",
    )
    text(
        svg,
        70,
        625,
        "Two 10-second rounds per revision; order V1/V3, then V3/V1.",
        "small",
    )
    metadata(svg, digest, "race_throughput")
    footer(svg, 685, digest)
    return svg.finish()


def main() -> None:
    if sys.argv[1:] != ["generate"]:
        print("usage: generate-charts.py generate", file=sys.stderr)
        raise SystemExit(0 if sys.argv[1:] in ([], ["-h"], ["--help"]) else 2)
    data, digest = load_summary()
    charts = {
        "01-median-current-master-latency.svg": comparison_chart(
            data,
            digest,
            mode="median",
        ),
        "02-p95-current-master-latency.svg": comparison_chart(
            data,
            digest,
            mode="p95",
        ),
        "03-allocation-scaling.svg": allocation_chart(data, digest),
        "04-race-throughput.svg": race_chart(data, digest),
    }
    OUT.mkdir(parents=True, exist_ok=True)
    for name, content in charts.items():
        path = OUT / name
        path.write_text(content)
        ET.parse(path)
    print(f"wrote {len(charts)} deterministic SVG files")
    print(f"summary.json SHA-256 {digest}")


if __name__ == "__main__":
    main()
