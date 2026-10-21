#!/usr/bin/env python3

"""Create a compact, read-only results view from private pipeline data."""

from __future__ import annotations

import argparse
import csv
import html
import json
import shutil
from pathlib import Path
from typing import Any, Iterable

STAGE_LABELS = {"openjdk": "OpenJDK", "graal": "Graal", "divine": "Divine", "bubol": "BuboL"}


def duration_text(total: int) -> str:
    hours, remainder = divmod(total, 3600)
    minutes, seconds = divmod(remainder, 60)
    values = ([f"{hours}h"] if hours else []) + ([f"{minutes}m"] if minutes or hours else []) + [f"{seconds}s"]
    return " ".join(values)


def read_events(path: Path, selected: list[str]) -> list[dict[str, Any]]:
    stages = {name: {"name": name, "label": STAGE_LABELS.get(name, name), "status": "not_run",
                     "duration_seconds": 0, "detail": "", "checks": []} for name in selected}
    if path.exists():
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            fields = line.split("\t", 4)
            if len(fields) != 5 or fields[1] not in stages:
                continue
            kind, name, value, label_or_duration, detail = fields
            if kind == "check":
                stages[name]["checks"].append({"name": label_or_duration, "status": value, "detail": detail})
            elif kind == "stage":
                stages[name]["status"] = value
                try:
                    stages[name]["duration_seconds"] = int(label_or_duration)
                except ValueError:
                    pass
                stages[name]["detail"] = detail
    return list(stages.values())


def copy_if_present(source: Path, destination: Path) -> None:
    if source.is_file():
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


def publish_stage_files(pipeline: Path, results: Path, benchmarks: list[str]) -> None:
    copy_if_present(pipeline / "logs/pipeline.log", results / "pipeline.log")
    graal = pipeline / "stages/graal"
    if graal.exists():
        for source in graal.rglob("*.log"):
            copy_if_present(source, results / "stages/graal" / source.relative_to(graal))

    for mode in ("divine", "bubol"):
        for benchmark in benchmarks:
            source_root = pipeline / "stages" / mode / benchmark
            destination_root = results / "stages" / mode / benchmark
            generation = source_root / "generation"
            verification = source_root / "verification"
            for name in (f"Final_{benchmark}.json", "MarkerPhase_BuboIncluded.json", "Divine.log"):
                copy_if_present(generation / name, destination_root / name)
            for name in ("summary.json", "Normal.log", "Slowdown.log", "Normal-BuboL.log",
                         "Slowdown-BuboL.log", "CFG-BuboL.log", "SlowdownTest.log",
                         "VTune-Slowdown-Blocks.txt"):
                copy_if_present(verification / name, destination_root / name)
            copy_if_present(verification / "loop-analysis/BuboL-VTune-Loop-Comparison.csv",
                            destination_root / "BuboL-VTune-Loop-Comparison.csv")


def read_json(path: Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def divine_rows(pipeline: Path, benchmarks: list[str]) -> list[dict[str, Any]]:
    rows = []
    for benchmark in benchmarks:
        data = read_json(pipeline / f"stages/divine/{benchmark}/verification/summary.json")
        if data:
            rows.append(data)
    return rows


def loop_rows(pipeline: Path, benchmarks: list[str]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for benchmark in benchmarks:
        path = pipeline / f"stages/bubol/{benchmark}/verification/loop-analysis/BuboL-VTune-Loop-Comparison.csv"
        if not path.is_file():
            continue
        with path.open(newline="", encoding="utf-8") as source:
            for row in csv.DictReader(source):
                if row.get("qualifies", "").lower() == "true" and row.get("bubol_slowdown_pct") and row.get("vtune_slowdown_pct"):
                    rows.append(row)
    return rows


def write_csv(path: Path, fieldnames: list[str], rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as destination:
        writer = csv.DictWriter(destination, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def shorten(value: str, limit: int = 54) -> str:
    return value if len(value) <= limit else "…" + value[-(limit - 1):]


def render_bar_chart(path: Path, title: str, subtitle: str, rows: list[tuple[str, float, float]],
                     expected_label: str, achieved_label: str, unit: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    width, left, right, top, row_height = 1200, 390, 80, 145, 54
    height = max(280, top + row_height * max(1, len(rows)) + 85)
    plot_width = width - left - right
    maximum = max([value for _, expected, achieved in rows for value in (expected, achieved)] + [1.0]) * 1.12
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
             '<rect width="100%" height="100%" fill="#ffffff"/>',
             '<style>text{font-family:Inter,Segoe UI,sans-serif;fill:#172033}.title{font-size:26px;font-weight:700}.sub{font-size:14px;fill:#5d6678}.label{font-size:13px}.value{font-size:12px;font-weight:600}.axis{stroke:#d8dde8;stroke-width:1}</style>',
             f'<text class="title" x="40" y="42">{html.escape(title)}</text>',
             f'<text class="sub" x="40" y="68">{html.escape(subtitle)}</text>',
             '<rect x="40" y="88" width="18" height="18" rx="3" fill="#4f76d9"/>',
             f'<text class="label" x="66" y="102">{html.escape(expected_label)}</text>',
             '<rect x="230" y="92" width="18" height="10" rx="3" fill="#ef8b45"/>',
             f'<text class="label" x="256" y="102">{html.escape(achieved_label)}</text>']
    if not rows:
        parts.append('<text class="sub" x="40" y="165">No completed benchmark data was available.</text>')
    for index, (label, expected, achieved) in enumerate(rows):
        y = top + index * row_height
        expected_width = plot_width * expected / maximum
        achieved_width = plot_width * achieved / maximum
        parts.extend([
            f'<text class="label" x="{left - 14}" y="{y + 20}" text-anchor="end">{html.escape(shorten(label))}</text>',
            f'<line class="axis" x1="{left}" y1="{y + 36}" x2="{left + plot_width}" y2="{y + 36}"/>',
            f'<rect x="{left}" y="{y + 4}" width="{expected_width:.2f}" height="28" rx="4" fill="#4f76d9" opacity="0.82"/>',
            f'<rect x="{left}" y="{y + 11}" width="{achieved_width:.2f}" height="14" rx="4" fill="#ef8b45"/>',
            f'<text class="value" x="{min(left + max(expected_width, achieved_width) + 8, width - right)}" y="{y + 24}">{expected:.2f}{html.escape(unit)} / {achieved:.2f}{html.escape(unit)}</text>'
        ])
    parts.append('</svg>')
    path.write_text("\n".join(parts) + "\n", encoding="utf-8")


def print_report(report: dict[str, Any], results: Path) -> None:
    symbol = "✔" if report["status"] == "passed" else "✘"
    print("\nGT Ecosystem Final Report")
    print(f"{symbol} Overall: {report['status'].upper()} ({duration_text(report['duration_seconds'])})")
    for stage in report["stages"]:
        stage_symbol = {"passed": "✔", "failed": "✘"}.get(stage["status"], "○")
        print(f"  {stage_symbol} {stage['label']}: {stage['status'].upper()} ({duration_text(stage['duration_seconds'])})")
        for check in stage["checks"]:
            print(f"      ✔ {check['name']}: {check['detail']}".rstrip(": "))
    print(f"  Results: {results}")
    print(f"  Summary: {results / 'summary.txt'}")
    print(f"  Divine plot: {results / 'plots/divine-slowdown.svg'}")
    print(f"  BuboL loop plot: {results / 'plots/bubol-loop-slowdown.svg'}")


def write_stage_summaries(results: Path, stages: list[dict[str, Any]],
                          divine: list[dict[str, Any]], loops: list[dict[str, str]],
                          benchmarks: list[str]) -> None:
    for stage in stages:
        lines = [f"{stage['label']} Stage", "=" * (len(stage["label"]) + 6), "",
                 f"Status: {stage['status'].upper()}",
                 f"Duration: {duration_text(stage['duration_seconds'])}"]
        if stage["checks"]:
            lines += ["", "Checks:"]
            for check in stage["checks"]:
                detail = f" — {check['detail']}" if check["detail"] else ""
                lines.append(f"- {check['name']}{detail}")
        destination = results / "stages" / stage["name"] / "summary.txt"
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text("\n".join(lines) + "\n", encoding="utf-8")

    divine_by_benchmark = {str(row["benchmark"]): row for row in divine}
    loops_by_benchmark: dict[str, list[dict[str, str]]] = {}
    for row in loops:
        loops_by_benchmark.setdefault(row["benchmark"], []).append(row)

    for benchmark in benchmarks:
        divine_data = divine_by_benchmark.get(benchmark)
        if divine_data:
            destination = results / f"stages/divine/{benchmark}/summary.txt"
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(
                f"{benchmark} — Pure Divine\n"
                f"Expected slowdown: {float(divine_data['expected_slowdown_ratio']):.3f}x\n"
                f"Achieved slowdown: {float(divine_data['achieved_slowdown_ratio']):.3f}x\n"
                f"Normal average: {divine_data['normal_average_us']}us\n"
                f"Slowdown average: {divine_data['slowdown_average_us']}us\n",
                encoding="utf-8",
            )

        bubol_data = read_json(results / f"stages/bubol/{benchmark}/summary.json")
        benchmark_loops = loops_by_benchmark.get(benchmark, [])
        if bubol_data or benchmark_loops:
            lines = [f"{benchmark} — BuboL"]
            if bubol_data:
                lines += [f"Expected overall slowdown: {float(bubol_data['expected_slowdown_ratio']):.3f}x",
                          f"Achieved overall slowdown: {float(bubol_data['achieved_slowdown_ratio']):.3f}x"]
            lines.append(f"Qualifying loops compared with VTune: {len(benchmark_loops)}")
            lines.append("Loop details: BuboL-VTune-Loop-Comparison.csv")
            destination = results / f"stages/bubol/{benchmark}/summary.txt"
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-root", required=True, type=Path)
    parser.add_argument("--events", required=True, type=Path)
    parser.add_argument("--started-at", required=True)
    parser.add_argument("--finished-at", required=True)
    parser.add_argument("--duration-seconds", required=True, type=int)
    parser.add_argument("--status", required=True, choices=("passed", "failed"))
    parser.add_argument("--stage", action="append", default=[])
    parser.add_argument("--benchmark", action="append", default=[])
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    pipeline = args.run_root / "pipeline"
    results = args.run_root / "results"
    results.mkdir(parents=True, exist_ok=True)
    publish_stage_files(pipeline, results, args.benchmark)

    divine = divine_rows(pipeline, args.benchmark)
    loops = loop_rows(pipeline, args.benchmark)
    write_csv(results / "data/divine-slowdown.csv",
              ["benchmark", "expected_slowdown_ratio", "achieved_slowdown_ratio", "normal_average_us", "slowdown_average_us"], divine)
    loop_fields = ["benchmark", "comp_id", "method", "loop_id", "runtime_share_pct", "vtune_slowdown_pct",
                   "bubol_slowdown_pct", "absolute_difference_pct_points"]
    write_csv(results / "data/bubol-loop-slowdown.csv", loop_fields, loops)

    render_bar_chart(results / "plots/divine-slowdown.svg", "Pure Divine slowdown",
                     "Expected and achieved slowdown for each configured benchmark",
                     [(str(row["benchmark"]), float(row["expected_slowdown_ratio"]), float(row["achieved_slowdown_ratio"])) for row in divine],
                     "Expected slowdown", "Achieved slowdown", "×")
    render_bar_chart(results / "plots/bubol-loop-slowdown.svg", "BuboL loop slowdown",
                     "Every qualifying loop; VTune is expected and BuboL is achieved",
                     [(f"{row['benchmark']}: {row['method']} loop {row['loop_id']}", float(row["vtune_slowdown_pct"]),
                       float(row["bubol_slowdown_pct"])) for row in loops],
                     "Expected (VTune)", "Achieved (BuboL)", "%")

    report = {"pipeline": "GT Ecosystem", "status": args.status, "started_at": args.started_at,
              "finished_at": args.finished_at, "duration_seconds": args.duration_seconds,
              "verbose": args.verbose, "benchmarks": args.benchmark, "selected_stages": args.stage,
              "stages": read_events(args.events, args.stage), "divine_benchmarks": divine,
              "bubol_qualifying_loops": len(loops), "pipeline_directory": str(pipeline),
              "results_directory": str(results)}
    write_stage_summaries(results, report["stages"], divine, loops, args.benchmark)
    (results / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    lines = ["GT Ecosystem Final Report", "=========================", "",
             f"Status: {args.status.upper()}", f"Started: {args.started_at}", f"Finished: {args.finished_at}",
             f"Duration: {duration_text(args.duration_seconds)}", f"Benchmarks: {', '.join(args.benchmark)}", "", "Stages:"]
    for stage in report["stages"]:
        lines.append(f"- {stage['label']}: {stage['status'].upper()} ({duration_text(stage['duration_seconds'])})")
    lines += ["", "Outputs:", "- data/divine-slowdown.csv", "- data/bubol-loop-slowdown.csv",
              "- plots/divine-slowdown.svg", "- plots/bubol-loop-slowdown.svg", "- stages/ (selected diagnostic copies)", ""]
    (results / "summary.txt").write_text("\n".join(lines), encoding="utf-8")
    print_report(report, results)


if __name__ == "__main__":
    main()
