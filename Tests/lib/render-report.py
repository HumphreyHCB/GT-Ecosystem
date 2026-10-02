#!/usr/bin/env python3

"""Render the final GT ecosystem console report and JSON report."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


STAGE_LABELS = {
    "openjdk": "OpenJDK",
    "graal": "Graal",
    "divine": "Divine",
    "bubol": "BuboL",
}


def duration_text(total_seconds: int) -> str:
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    parts: list[str] = []

    if hours:
        parts.append(f"{hours}h")
    if minutes or hours:
        parts.append(f"{minutes}m")
    parts.append(f"{seconds}s")
    return " ".join(parts)


def read_events(path: Path, selected_stages: list[str]) -> list[dict[str, Any]]:
    stages: dict[str, dict[str, Any]] = {
        name: {
            "name": name,
            "label": STAGE_LABELS.get(name, name),
            "status": "not_run",
            "duration_seconds": 0,
            "detail": "",
            "checks": [],
        }
        for name in selected_stages
    }

    if path.exists():
        for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            fields = raw_line.split("\t", 4)
            if len(fields) != 5:
                continue

            event_type, stage_name, value, label_or_duration, detail = fields
            stage = stages.get(stage_name)
            if stage is None:
                continue

            if event_type == "check":
                stage["checks"].append(
                    {
                        "name": label_or_duration,
                        "status": value,
                        "detail": detail,
                    }
                )
            elif event_type == "stage":
                stage["status"] = value
                try:
                    stage["duration_seconds"] = int(label_or_duration)
                except ValueError:
                    stage["duration_seconds"] = 0
                stage["detail"] = detail

    return list(stages.values())


def print_console_report(report: dict[str, Any]) -> None:
    overall_symbol = "✔" if report["status"] == "passed" else "✘"

    print()
    print("GT Ecosystem Final Report")
    print(f"{overall_symbol} Overall: {report['status'].upper()}")
    print(f"  Duration: {duration_text(report['duration_seconds'])}")

    for stage in report["stages"]:
        status = stage["status"]
        symbol = {"passed": "✔", "failed": "✘"}.get(status, "○")
        duration = duration_text(stage["duration_seconds"])
        print(f"  {symbol} {stage['label']}: {status.upper()} ({duration})")

        for check in stage["checks"]:
            check_symbol = "✔" if check["status"] == "passed" else "✘"
            line = f"      {check_symbol} {check['name']}"
            if check["detail"]:
                line += f": {check['detail']}"
            print(line)

        if stage["detail"]:
            print(f"      {stage['detail']}")

    print(f"  JSON report: {report['report_file']}")
    print(f"  Detailed log: {report['detailed_log']}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--events", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--started-at", required=True)
    parser.add_argument("--finished-at", required=True)
    parser.add_argument("--duration-seconds", required=True, type=int)
    parser.add_argument("--status", required=True, choices=("passed", "failed"))
    parser.add_argument("--stage", action="append", default=[])
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--detailed-log", required=True, type=Path)
    args = parser.parse_args()

    report = {
        "pipeline": "GT Ecosystem",
        "status": args.status,
        "started_at": args.started_at,
        "finished_at": args.finished_at,
        "duration_seconds": args.duration_seconds,
        "verbose": args.verbose,
        "selected_stages": args.stage,
        "stages": read_events(args.events, args.stage),
        "report_file": str(args.output),
        "detailed_log": str(args.detailed_log),
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print_console_report(report)


if __name__ == "__main__":
    main()
