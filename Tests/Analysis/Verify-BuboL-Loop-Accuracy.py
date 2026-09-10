#!/usr/bin/env python3

"""Compare BuboL per-loop cycle measurements with VTune block timings."""

from __future__ import annotations

import argparse
import csv
import json
import re
import statistics
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple


NUMBER = r"-?\d+(?:\.\d+)?"

VTUNE_BLOCK_RE = re.compile(
    rf"^Method:\s*(?P<method>.*?),\s*"
    rf"Block ID:\s*(?P<block>\d+),\s*"
    rf"Normal Time:\s*(?P<normal>{NUMBER}),\s*"
    rf"Slowdown Time:\s*(?P<slow>{NUMBER}),\s*"
    rf"Percentage Increase:\s*(?P<pct>{NUMBER})(?:%)?\s*$"
)

VTUNE_RDTSC_RE = re.compile(
    rf"^Method:\s*(?P<method>.*?),\s*"
    rf"Block ID:\s*(?P<block>\d+),\s*"
    rf"RDTSC Normal Time:\s*(?P<normal>{NUMBER}),\s*"
    rf"RDTSC Slowdown Time:\s*(?P<slow>{NUMBER}),\s*"
    rf"RDTSC Percentage Increase:\s*(?P<pct>{NUMBER})(?:%)?\s*$"
)

BRIDGE_KEY_RE = re.compile(
    r"^\s*(?P<graal>\d+)\s*\(Vtune Block\s*(?P<vtune>\d+)\)\s*$"
)

BUBO_COMP_RE = re.compile(r"^Comp\s+(\d+)\s*\((.*?)\)\s*loops:\s*$")
BUBO_ENCODING_RE = re.compile(r"^Found Encoding\s*:\s*(.*)")
BUBO_LOOP_RE = re.compile(
    r"loop\s+(\d+)\s+Cycles:\s*([0-9]+)\s*\|\|\s*"
    r"Activation Count:\s*([0-9]+)\s*\|\s*LoopCallCount:\s*([0-9]+)\s*\|"
)
BUBO_TOTAL_RE = re.compile(
    r"Bubo\.RDTSC\.Harness\.main Total RDTSC cycles:\s*([0-9]+)"
)


class AnalysisError(RuntimeError):
    """A validation failure that should fail the ecosystem stage."""


@dataclass
class CfgBlock:
    block_id: int
    successors: List[int] = field(default_factory=list)
    loop_label: Optional[str] = None
    rdtsc_loop_ids: List[int] = field(default_factory=list)


@dataclass
class CfgCompilation:
    comp_id: int
    method: str
    blocks: Dict[int, CfgBlock]


@dataclass(frozen=True)
class VtuneBlock:
    method: str
    vtune_block_id: int
    normal_time: float
    slowdown_time: float


@dataclass(frozen=True)
class VtuneRdtsc:
    method: str
    vtune_block_id: int
    normal_time: float
    slowdown_time: float


@dataclass
class LoopTimes:
    normal_time: float = 0.0
    slowdown_time: float = 0.0
    block_count: int = 0
    probe_normal_time: float = 0.0
    probe_slowdown_time: float = 0.0
    probe_count: int = 0


@dataclass
class BuboLoop:
    comp_id: int
    method: str
    loop_id: int
    inclusive_cycles: int
    exclusive_cycles: int
    activation_count: int
    loop_call_count: int


@dataclass
class BuboData:
    loops: Dict[Tuple[int, int], BuboLoop]
    total_cycles: int
    encoding_count: int


def normalise_method(value: str) -> str:
    value = value.strip().strip('"').replace("::", ".")
    value = re.sub(r"-(?:Re-Comp|OSR).*?$", "", value).strip()
    if "(" in value:
        value = value.split("(", 1)[0]
    return value.strip().rstrip(",")


def percentage_increase(normal: float, slowdown: float) -> float:
    if normal <= 0.0:
        return 0.0
    return ((slowdown - normal) / normal) * 100.0


def parse_compilation_name(value: str) -> Tuple[int, str]:
    match = re.match(r"^\s*(\d+)\s*-\s*(.+?)\s*$", value)
    if not match:
        raise AnalysisError(
            f"Cannot extract a compilation ID and method from CFG compilation: {value}"
        )
    return int(match.group(1)), normalise_method(match.group(2))


def parse_cfg_log(path: Path) -> List[CfgCompilation]:
    compilations: List[CfgCompilation] = []
    in_compilation = False
    compilation_name: Optional[str] = None
    blocks: Dict[int, CfgBlock] = {}
    current_block: Optional[CfgBlock] = None
    mode: Optional[str] = None
    last_marker_is_rdtsc = False

    def finish_compilation() -> None:
        nonlocal compilation_name, blocks
        if compilation_name is None:
            raise AnalysisError("A HumphreysDebugDataPhase section has no Compilation line")
        comp_id, method = parse_compilation_name(compilation_name)
        compilations.append(CfgCompilation(comp_id, method, blocks))

    with path.open("r", encoding="utf-8", errors="replace") as source:
        for raw_line in source:
            line = raw_line.strip()

            if line.startswith("=== HumphreysDebugDataPhase ==="):
                in_compilation = True
                compilation_name = None
                blocks = {}
                current_block = None
                mode = None
                last_marker_is_rdtsc = False
                continue

            if not in_compilation:
                continue

            if line.startswith("=== End HumphreysDebugDataPhase ==="):
                finish_compilation()
                in_compilation = False
                current_block = None
                mode = None
                last_marker_is_rdtsc = False
                continue

            if line.startswith("Compilation: "):
                compilation_name = line[len("Compilation: ") :].strip()
                continue

            block_match = re.match(r"Block\s+(\d+)", line)
            if block_match:
                current_block = CfgBlock(int(block_match.group(1)))
                blocks[current_block.block_id] = current_block
                mode = None
                last_marker_is_rdtsc = False
                continue

            if line.startswith("Successors:"):
                mode = "successors"
                continue

            if line.startswith("Predecessors:"):
                mode = "predecessors"
                continue

            if line.startswith("In loop:"):
                if current_block is not None:
                    loop_value = line[len("In loop:") :].strip()
                    current_block.loop_label = (
                        None if loop_value == "<none>" else loop_value
                    )
                continue

            if line.startswith("Source positions in block:"):
                mode = "sources"
                continue

            if line.startswith("BuboLoopMakers:"):
                mode = "bubo"
                last_marker_is_rdtsc = False
                continue

            if current_block is None:
                continue

            if mode == "successors" and "->" in line:
                successor_text = line.split("->", 1)[1].strip()
                try:
                    current_block.successors.append(int(successor_text))
                except ValueError:
                    pass
                continue

            if mode != "bubo" or not line:
                continue

            marker_match = re.search(
                r"Found in this block\s*:\s*(?:class\s+)?(.+)$", line
            )
            if marker_match:
                marker_name = marker_match.group(1).strip().upper()
                last_marker_is_rdtsc = any(
                    token in marker_name for token in ("RDTSC", "RDTSCP", "RDTCP")
                )
                continue

            loop_match = re.match(r"LoopID:\s*(\d+)", line)
            if loop_match and last_marker_is_rdtsc:
                current_block.rdtsc_loop_ids.append(int(loop_match.group(1)))

    if in_compilation:
        raise AnalysisError("CFG log ended inside a HumphreysDebugDataPhase section")
    if not compilations:
        raise AnalysisError(f"No HumphreysDebugDataPhase sections were found in {path}")

    return compilations


def build_cfg_maps(
    compilations: Iterable[CfgCompilation],
) -> Tuple[
    Dict[Tuple[int, str, int], int],
    Dict[Tuple[int, str, int], Set[int]],
    Dict[str, Set[int]],
]:
    node_to_loop: Dict[Tuple[int, str, int], int] = {}
    probe_blocks: Dict[Tuple[int, str, int], Set[int]] = defaultdict(set)
    method_compilations: Dict[str, Set[int]] = defaultdict(set)

    for compilation in compilations:
        method_compilations[compilation.method].add(compilation.comp_id)
        label_to_loop_id: Dict[str, int] = {}

        for block in compilation.blocks.values():
            for marker_loop_id in block.rdtsc_loop_ids:
                matched_label: Optional[str] = None
                for successor in block.successors:
                    successor_block = compilation.blocks.get(successor)
                    if successor_block and successor_block.loop_label:
                        matched_label = successor_block.loop_label
                        break

                if matched_label is None and block.loop_label:
                    matched_label = block.loop_label

                if matched_label is not None:
                    old_loop_id = label_to_loop_id.get(matched_label)
                    if old_loop_id is not None and old_loop_id != marker_loop_id:
                        raise AnalysisError(
                            f"CFG loop {matched_label} in compilation {compilation.comp_id} "
                            f"maps to both loop {old_loop_id} and loop {marker_loop_id}"
                        )
                    label_to_loop_id[matched_label] = marker_loop_id

                probe_loop_id = (
                    label_to_loop_id.get(matched_label, marker_loop_id)
                    if matched_label is not None
                    else marker_loop_id
                )
                probe_blocks[
                    (compilation.comp_id, compilation.method, probe_loop_id)
                ].add(block.block_id)

        for block in compilation.blocks.values():
            if block.loop_label not in label_to_loop_id:
                continue
            node_to_loop[
                (compilation.comp_id, compilation.method, block.block_id)
            ] = label_to_loop_id[block.loop_label]

    if not node_to_loop:
        raise AnalysisError("CFG data produced no Graal-block to BuboL-loop mappings")
    if not probe_blocks:
        raise AnalysisError("CFG data produced no RDTSC probe-block mappings")

    return node_to_loop, probe_blocks, method_compilations


def load_bridge(path: Path) -> Dict[str, Dict[int, int]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    result: Dict[str, Dict[int, int]] = {}

    if not isinstance(data, dict):
        raise AnalysisError(f"Final slowdown JSON must contain an object: {path}")

    for raw_method, raw_mapping in data.items():
        if not isinstance(raw_mapping, dict):
            continue
        method = normalise_method(str(raw_method))
        mapping: Dict[int, int] = {}
        for raw_key in raw_mapping:
            match = BRIDGE_KEY_RE.match(str(raw_key))
            if match:
                mapping[int(match.group("vtune"))] = int(match.group("graal"))
        if mapping:
            result[method] = mapping

    if not result:
        raise AnalysisError(f"No VTune-to-Graal block mappings were found in {path}")
    return result


def load_marker_phase(path: Path) -> Dict[str, Dict[int, int]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    result: Dict[str, Dict[int, int]] = {}

    if not isinstance(data, dict):
        raise AnalysisError(f"MarkerPhaseInfo JSON must contain an object: {path}")

    for raw_method, entries in data.items():
        if not isinstance(entries, list):
            continue
        method = normalise_method(str(raw_method))
        mapping: Dict[int, int] = {}
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            try:
                graal_id = int(str(entry["GraalID"]).strip())
                vtune_id = int(str(entry["VtuneBlock"]).strip())
            except (KeyError, TypeError, ValueError):
                continue
            mapping[graal_id] = vtune_id
        if mapping:
            result[method] = mapping

    if not result:
        raise AnalysisError(f"No Graal-to-VTune marker mappings were found in {path}")
    return result


def parse_vtune_report(
    path: Path,
) -> Tuple[List[VtuneBlock], Dict[Tuple[str, int], VtuneRdtsc]]:
    blocks: List[VtuneBlock] = []
    rdtsc_rows: Dict[Tuple[str, int], VtuneRdtsc] = {}

    with path.open("r", encoding="utf-8", errors="replace") as source:
        for raw_line in source:
            line = raw_line.strip()
            block_match = VTUNE_BLOCK_RE.match(line)
            if block_match:
                blocks.append(
                    VtuneBlock(
                        normalise_method(block_match.group("method")),
                        int(block_match.group("block")),
                        float(block_match.group("normal")),
                        float(block_match.group("slow")),
                    )
                )
                continue

            rdtsc_match = VTUNE_RDTSC_RE.match(line)
            if rdtsc_match:
                row = VtuneRdtsc(
                    normalise_method(rdtsc_match.group("method")),
                    int(rdtsc_match.group("block")),
                    float(rdtsc_match.group("normal")),
                    float(rdtsc_match.group("slow")),
                )
                rdtsc_rows[(row.method, row.vtune_block_id)] = row

    if not blocks:
        raise AnalysisError(f"No normal VTune block rows were found in {path}")
    if not rdtsc_rows:
        raise AnalysisError(f"No RDTSC VTune block rows were found in {path}")

    return blocks, rdtsc_rows


def invert_marker_phase(
    marker_phase: Dict[str, Dict[int, int]],
) -> Dict[str, Dict[int, int]]:
    result: Dict[str, Dict[int, int]] = {}
    for method, graal_to_vtune in marker_phase.items():
        vtune_to_graal: Dict[int, int] = {}
        for graal_id, vtune_id in graal_to_vtune.items():
            if vtune_id not in vtune_to_graal or graal_id < vtune_to_graal[vtune_id]:
                vtune_to_graal[vtune_id] = graal_id
        result[method] = vtune_to_graal
    return result


def map_vtune_block_to_graal(
    block: VtuneBlock,
    bridge: Dict[str, Dict[int, int]],
    marker_fallback: Dict[str, Dict[int, int]],
) -> Optional[int]:
    graal_id = bridge.get(block.method, {}).get(block.vtune_block_id)
    if graal_id is None:
        graal_id = marker_fallback.get(block.method, {}).get(block.vtune_block_id)
    return graal_id


def select_compilations(
    vtune_blocks: Iterable[VtuneBlock],
    bridge: Dict[str, Dict[int, int]],
    marker_fallback: Dict[str, Dict[int, int]],
    node_to_loop: Dict[Tuple[int, str, int], int],
    method_compilations: Dict[str, Set[int]],
) -> Dict[str, int]:
    mapped_blocks: Dict[str, List[int]] = defaultdict(list)
    for block in vtune_blocks:
        graal_id = map_vtune_block_to_graal(block, bridge, marker_fallback)
        if graal_id is not None:
            mapped_blocks[block.method].append(graal_id)

    selected: Dict[str, int] = {}
    for method, graal_ids in mapped_blocks.items():
        candidates = method_compilations.get(method, set())
        scores = {
            comp_id: sum(
                (comp_id, method, graal_id) in node_to_loop for graal_id in graal_ids
            )
            for comp_id in candidates
        }
        scores = {comp_id: score for comp_id, score in scores.items() if score > 0}
        if scores:
            selected[method] = max(scores, key=lambda comp_id: (scores[comp_id], comp_id))

    if not selected:
        raise AnalysisError(
            "No CFG compilation matched the blocks in the SlowdownTest report"
        )
    return selected


def aggregate_vtune_loops(
    vtune_blocks: List[VtuneBlock],
    rdtsc_rows: Dict[Tuple[str, int], VtuneRdtsc],
    bridge: Dict[str, Dict[int, int]],
    marker_phase: Dict[str, Dict[int, int]],
    node_to_loop: Dict[Tuple[int, str, int], int],
    probe_blocks: Dict[Tuple[int, str, int], Set[int]],
    selected_compilations: Dict[str, int],
) -> Tuple[
    Dict[Tuple[int, str, int], LoopTimes],
    List[Dict[str, object]],
    Dict[str, int],
]:
    marker_fallback = invert_marker_phase(marker_phase)
    grouped: Dict[Tuple[int, str, int], LoopTimes] = defaultdict(LoopTimes)
    block_output: List[Dict[str, object]] = []
    statistics_map = {
        "bridge_misses": 0,
        "cfg_misses": 0,
        "blocks_used": 0,
        "probe_blocks_added": 0,
        "probe_marker_misses": 0,
        "probe_timing_misses": 0,
    }

    for block in vtune_blocks:
        graal_id = map_vtune_block_to_graal(block, bridge, marker_fallback)
        if graal_id is None:
            statistics_map["bridge_misses"] += 1
            continue

        comp_id = selected_compilations.get(block.method)
        if comp_id is None:
            statistics_map["cfg_misses"] += 1
            continue

        loop_id = node_to_loop.get((comp_id, block.method, graal_id))
        if loop_id is None:
            statistics_map["cfg_misses"] += 1
            continue

        key = (comp_id, block.method, loop_id)
        totals = grouped[key]
        totals.normal_time += block.normal_time
        totals.slowdown_time += block.slowdown_time
        totals.block_count += 1
        statistics_map["blocks_used"] += 1

        block_output.append(
            {
                "comp_id": comp_id,
                "method": block.method,
                "loop_id": loop_id,
                "vtune_block_id": block.vtune_block_id,
                "graal_block_id": graal_id,
                "normal_time": block.normal_time,
                "slowdown_time": block.slowdown_time,
                "pct_increase_block": percentage_increase(
                    block.normal_time, block.slowdown_time
                ),
            }
        )

    for key, totals in grouped.items():
        comp_id, method, loop_id = key
        for graal_probe_id in probe_blocks.get((comp_id, method, loop_id), set()):
            vtune_probe_id = marker_phase.get(method, {}).get(graal_probe_id)
            if vtune_probe_id is None:
                statistics_map["probe_marker_misses"] += 1
                continue

            timing = rdtsc_rows.get((method, vtune_probe_id))
            if timing is None:
                statistics_map["probe_timing_misses"] += 1
                continue

            totals.probe_normal_time += timing.normal_time
            totals.probe_slowdown_time += timing.slowdown_time
            totals.probe_count += 1
            statistics_map["probe_blocks_added"] += 1

    if not grouped:
        raise AnalysisError("No VTune blocks could be assigned to BuboL loops")
    if statistics_map["probe_blocks_added"] == 0:
        raise AnalysisError(
            "No RDTSC probe timings were added through MarkerPhaseInfo.json"
        )

    return grouped, block_output, statistics_map


def parse_bubo_log(path: Path) -> BuboData:
    comp_id: Optional[int] = None
    comp_methods: Dict[int, str] = {}
    parent_maps: Dict[int, Dict[int, int]] = defaultdict(dict)
    loops_by_comp: Dict[int, Dict[int, BuboLoop]] = defaultdict(dict)
    total_cycles = 0
    encoding_count = 0

    with path.open("r", encoding="utf-8", errors="replace") as source:
        for raw_line in source:
            line = raw_line.rstrip("\n")

            total_match = BUBO_TOTAL_RE.search(line)
            if total_match:
                total_cycles = int(total_match.group(1))
                continue

            comp_match = BUBO_COMP_RE.match(line)
            if comp_match:
                comp_id = int(comp_match.group(1))
                comp_methods[comp_id] = normalise_method(comp_match.group(2))
                continue

            if comp_id is None:
                continue

            encoding_match = BUBO_ENCODING_RE.match(line)
            if encoding_match:
                encoding_count += 1
                parent_map: Dict[int, int] = {}
                for item in encoding_match.group(1).split(","):
                    if ":" not in item:
                        continue
                    loop_text, parent_text = item.strip().split(":", 1)
                    try:
                        parent_map[int(loop_text)] = int(parent_text)
                    except ValueError:
                        continue
                parent_maps[comp_id] = parent_map
                continue

            loop_match = BUBO_LOOP_RE.search(line)
            if loop_match:
                loop_id = int(loop_match.group(1))
                inclusive_cycles = int(loop_match.group(2))
                loops_by_comp[comp_id][loop_id] = BuboLoop(
                    comp_id=comp_id,
                    method=comp_methods.get(comp_id, ""),
                    loop_id=loop_id,
                    inclusive_cycles=inclusive_cycles,
                    exclusive_cycles=inclusive_cycles,
                    activation_count=int(loop_match.group(3)),
                    loop_call_count=int(loop_match.group(4)),
                )

    loops: Dict[Tuple[int, int], BuboLoop] = {}
    for current_comp_id, current_loops in loops_by_comp.items():
        children: Dict[int, List[int]] = defaultdict(list)
        for loop_id, parent_id in parent_maps[current_comp_id].items():
            if parent_id != -1 and loop_id in current_loops and parent_id in current_loops:
                children[parent_id].append(loop_id)

        for loop_id, loop in current_loops.items():
            child_cycles = sum(
                current_loops[child_id].inclusive_cycles
                for child_id in children.get(loop_id, [])
            )
            loop.exclusive_cycles = max(0, loop.inclusive_cycles - child_cycles)
            loops[(current_comp_id, loop_id)] = loop

    if encoding_count == 0:
        raise AnalysisError(f"No BuboL encodings were found in {path}")
    if not loops:
        raise AnalysisError(f"No BuboL loop measurements were found in {path}")
    if total_cycles <= 0:
        raise AnalysisError(f"No positive total RDTSC cycle count was found in {path}")

    return BuboData(loops, total_cycles, encoding_count)


def write_csv(path: Path, fieldnames: List[str], rows: Iterable[Dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as destination:
        writer = csv.DictWriter(destination, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def write_cfg_map(
    output_dir: Path, node_to_loop: Dict[Tuple[int, str, int], int]
) -> None:
    rows = [
        {
            "comp_id": comp_id,
            "method": method,
            "graal_block_id": graal_block_id,
            "loop_id": loop_id,
        }
        for (comp_id, method, graal_block_id), loop_id in sorted(node_to_loop.items())
    ]
    write_csv(
        output_dir / "CFG-Block-to-Loop.csv",
        ["comp_id", "method", "graal_block_id", "loop_id"],
        rows,
    )


def write_vtune_outputs(
    output_dir: Path,
    grouped: Dict[Tuple[int, str, int], LoopTimes],
    block_rows: List[Dict[str, object]],
) -> Dict[Tuple[int, str, int], float]:
    loop_values: Dict[Tuple[int, str, int], float] = {}
    loop_rows: List[Dict[str, object]] = []

    for key in sorted(grouped):
        comp_id, method, loop_id = key
        totals = grouped[key]
        total_normal = totals.normal_time + totals.probe_normal_time
        total_slowdown = totals.slowdown_time + totals.probe_slowdown_time
        slowdown_pct = percentage_increase(total_normal, total_slowdown)
        loop_values[key] = slowdown_pct
        loop_rows.append(
            {
                "comp_id": comp_id,
                "method": method,
                "loop_id": loop_id,
                "num_blocks_matched": totals.block_count,
                "num_probe_blocks_matched": totals.probe_count,
                "total_normal_time": total_normal,
                "total_slowdown_time": total_slowdown,
                "median_pct_slowdown": slowdown_pct,
            }
        )

    write_csv(
        output_dir / "VTune-Loop-Totals.csv",
        [
            "comp_id",
            "method",
            "loop_id",
            "num_blocks_matched",
            "num_probe_blocks_matched",
            "total_normal_time",
            "total_slowdown_time",
            "median_pct_slowdown",
        ],
        loop_rows,
    )
    write_csv(
        output_dir / "VTune-Block-to-Loop.csv",
        [
            "comp_id",
            "method",
            "loop_id",
            "vtune_block_id",
            "graal_block_id",
            "normal_time",
            "slowdown_time",
            "pct_increase_block",
        ],
        block_rows,
    )
    return loop_values


def compare_bubol_with_vtune(
    benchmark: str,
    normal_bubo: BuboData,
    slowdown_bubo: BuboData,
    vtune_loop_values: Dict[Tuple[int, str, int], float],
    output_dir: Path,
    min_runtime_share: float,
    max_median_difference: float,
) -> None:
    comparison_rows: List[Dict[str, object]] = []
    qualifying_differences: List[float] = []
    qualifying_count = 0
    missing_normal: List[str] = []
    missing_vtune: List[str] = []

    for key in sorted(slowdown_bubo.loops):
        slowdown_loop = slowdown_bubo.loops[key]
        method = slowdown_loop.method
        runtime_share = (
            slowdown_loop.exclusive_cycles / slowdown_bubo.total_cycles
        ) * 100.0
        is_benchmark_method = method.startswith(f"{benchmark}.")
        is_main = method == f"{benchmark}.main"
        qualifies = (
            is_benchmark_method
            and not is_main
            and slowdown_loop.loop_call_count == 0
            and runtime_share > min_runtime_share
        )

        if qualifies:
            qualifying_count += 1

        normal_loop = normal_bubo.loops.get(key)
        if normal_loop is None:
            if qualifies:
                missing_normal.append(
                    f"comp {slowdown_loop.comp_id}, {method}, loop {slowdown_loop.loop_id}"
                )
            continue

        bubol_pct: Optional[float] = None
        if normal_loop.exclusive_cycles > 0:
            bubol_pct = percentage_increase(
                float(normal_loop.exclusive_cycles),
                float(slowdown_loop.exclusive_cycles),
            )

        vtune_key = (
            slowdown_loop.comp_id,
            method,
            slowdown_loop.loop_id,
        )
        vtune_pct = vtune_loop_values.get(vtune_key)
        difference: Optional[float] = None
        if bubol_pct is not None and vtune_pct is not None:
            difference = abs(bubol_pct - vtune_pct)

        if qualifies:
            if bubol_pct is None:
                missing_normal.append(
                    f"comp {slowdown_loop.comp_id}, {method}, loop {slowdown_loop.loop_id} "
                    "has zero baseline exclusive cycles"
                )
            elif vtune_pct is None:
                alternative_compilations = sorted(
                    comp_id
                    for comp_id, vtune_method, vtune_loop_id in vtune_loop_values
                    if vtune_method == method and vtune_loop_id == slowdown_loop.loop_id
                )
                suffix = (
                    f"; VTune used compilation(s) {alternative_compilations}"
                    if alternative_compilations
                    else "; VTune has no matching method and loop"
                )
                missing_vtune.append(
                    f"comp {slowdown_loop.comp_id}, {method}, loop {slowdown_loop.loop_id}{suffix}"
                )
            else:
                qualifying_differences.append(difference if difference is not None else 0.0)

        reason = "qualifying"
        if not is_benchmark_method:
            reason = "not benchmark method"
        elif is_main:
            reason = "benchmark main method"
        elif slowdown_loop.loop_call_count != 0:
            reason = "LoopCallCount is not zero"
        elif runtime_share <= min_runtime_share:
            reason = "runtime share is below threshold"

        comparison_rows.append(
            {
                "benchmark": benchmark,
                "comp_id": slowdown_loop.comp_id,
                "comp_name": method,
                "method_dot": method,
                "method": method,
                "loop_id": slowdown_loop.loop_id,
                "loop_call_count": slowdown_loop.loop_call_count,
                "baseline_exclusive_cycles": normal_loop.exclusive_cycles,
                "slowdown_exclusive_cycles": slowdown_loop.exclusive_cycles,
                "slowdown_pct": "" if bubol_pct is None else bubol_pct,
                "loop_median_pct": "" if vtune_pct is None else vtune_pct,
                "bubol_slowdown_pct": "" if bubol_pct is None else bubol_pct,
                "vtune_slowdown_pct": "" if vtune_pct is None else vtune_pct,
                "absolute_difference_pct_points": (
                    "" if difference is None else difference
                ),
                "runtime_share_pct": runtime_share,
                "total_cycles_slowdown": slowdown_bubo.total_cycles,
                "prog_slowdown_pct": "",
                "qualifies": str(qualifies).lower(),
                "qualification": reason,
            }
        )

    comparison_path = output_dir / "BuboL-VTune-Loop-Comparison.csv"
    write_csv(
        comparison_path,
        [
            "benchmark",
            "comp_id",
            "comp_name",
            "method_dot",
            "method",
            "loop_id",
            "loop_call_count",
            "baseline_exclusive_cycles",
            "slowdown_exclusive_cycles",
            "slowdown_pct",
            "loop_median_pct",
            "bubol_slowdown_pct",
            "vtune_slowdown_pct",
            "absolute_difference_pct_points",
            "runtime_share_pct",
            "total_cycles_slowdown",
            "prog_slowdown_pct",
            "qualifies",
            "qualification",
        ],
        comparison_rows,
    )

    print(f"[INFO] BuboL baseline: {normal_bubo.encoding_count} encodings, "
          f"{len(normal_bubo.loops)} loops")
    print(f"[INFO] BuboL slowdown: {slowdown_bubo.encoding_count} encodings, "
          f"{len(slowdown_bubo.loops)} loops, "
          f"{slowdown_bubo.total_cycles} total cycles")
    print(f"[INFO] Qualifying loops: {qualifying_count}")
    print(f"[INFO] Comparison CSV: {comparison_path}")

    failures: List[str] = []
    if qualifying_count == 0:
        failures.append(
            f"no pure {benchmark} loops exceeded {min_runtime_share:.2f}% runtime share"
        )
    if missing_normal:
        failures.append("qualifying BuboL loops were absent from the baseline: " + "; ".join(missing_normal))
    if missing_vtune:
        failures.append(
            "qualifying loops did not have an exact VTune compilation match: "
            + "; ".join(missing_vtune)
        )

    if qualifying_differences:
        median_difference = statistics.median(qualifying_differences)
        maximum_difference = max(qualifying_differences)
        print(
            f"[INFO] Absolute BuboL versus VTune difference: "
            f"median={median_difference:.3f} percentage points, "
            f"maximum={maximum_difference:.3f} percentage points"
        )
        print(
            f"[INFO] Accepted median difference: "
            f"at most {max_median_difference:.3f} percentage points"
        )
        if median_difference > max_median_difference:
            failures.append(
                f"median absolute difference was {median_difference:.3f} percentage points"
            )

        for row in comparison_rows:
            if row["qualifies"] == "true" and row["absolute_difference_pct_points"] != "":
                print(
                    f"[INFO] Comp {row['comp_id']} {row['method']} loop {row['loop_id']}: "
                    f"BuboL={float(row['bubol_slowdown_pct']):.3f}%, "
                    f"VTune={float(row['vtune_slowdown_pct']):.3f}%, "
                    f"difference={float(row['absolute_difference_pct_points']):.3f}pp, "
                    f"runtime share={float(row['runtime_share_pct']):.3f}%"
                )

    if failures:
        raise AnalysisError("; ".join(failures))

    print("[PASS] BuboL per-loop measurements agree with VTune")


def positive_float(value: str) -> float:
    parsed = float(value)
    if parsed < 0.0:
        raise argparse.ArgumentTypeError("value must not be negative")
    return parsed


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify BuboL per-loop slowdown measurements against VTune"
    )
    parser.add_argument("--benchmark", required=True)
    parser.add_argument("--cfg-log", required=True, type=Path)
    parser.add_argument("--vtune-report", required=True, type=Path)
    parser.add_argument("--bridge-json", required=True, type=Path)
    parser.add_argument("--markerphase-json", required=True, type=Path)
    parser.add_argument("--normal-bubol-log", required=True, type=Path)
    parser.add_argument("--slowdown-bubol-log", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--min-runtime-share", type=positive_float, default=2.0)
    parser.add_argument("--max-median-difference", type=positive_float, default=25.0)
    return parser.parse_args()


def require_input_file(path: Path, description: str) -> None:
    if not path.is_file():
        raise AnalysisError(f"{description} does not exist: {path}")
    if path.stat().st_size == 0:
        raise AnalysisError(f"{description} is empty: {path}")


def run(args: argparse.Namespace) -> None:
    for path, description in (
        (args.cfg_log, "CFG log"),
        (args.vtune_report, "SlowdownTest VTune report"),
        (args.bridge_json, "Final slowdown JSON"),
        (args.markerphase_json, "MarkerPhaseInfo JSON"),
        (args.normal_bubol_log, "normal BuboL log"),
        (args.slowdown_bubol_log, "slowdown BuboL log"),
    ):
        require_input_file(path, description)

    args.output_dir.mkdir(parents=True, exist_ok=True)

    compilations = parse_cfg_log(args.cfg_log)
    node_to_loop, probe_blocks, method_compilations = build_cfg_maps(compilations)
    write_cfg_map(args.output_dir, node_to_loop)

    bridge = load_bridge(args.bridge_json)
    marker_phase = load_marker_phase(args.markerphase_json)
    vtune_blocks, rdtsc_rows = parse_vtune_report(args.vtune_report)
    marker_fallback = invert_marker_phase(marker_phase)
    selected_compilations = select_compilations(
        vtune_blocks,
        bridge,
        marker_fallback,
        node_to_loop,
        method_compilations,
    )

    grouped, block_rows, mapping_statistics = aggregate_vtune_loops(
        vtune_blocks,
        rdtsc_rows,
        bridge,
        marker_phase,
        node_to_loop,
        probe_blocks,
        selected_compilations,
    )
    vtune_loop_values = write_vtune_outputs(args.output_dir, grouped, block_rows)

    print(f"[INFO] CFG compilations: {len(compilations)}")
    print(f"[INFO] CFG block-to-loop mappings: {len(node_to_loop)}")
    print(f"[INFO] VTune blocks used: {mapping_statistics['blocks_used']}")
    print(f"[INFO] VTune bridge misses: {mapping_statistics['bridge_misses']}")
    print(f"[INFO] VTune CFG misses: {mapping_statistics['cfg_misses']}")
    print(f"[INFO] RDTSC probe blocks added: {mapping_statistics['probe_blocks_added']}")
    print(f"[INFO] Probe MarkerPhaseInfo misses: {mapping_statistics['probe_marker_misses']}")
    print(f"[INFO] Probe timing misses: {mapping_statistics['probe_timing_misses']}")
    for method, comp_id in sorted(selected_compilations.items()):
        if method.startswith(f"{args.benchmark}."):
            print(f"[INFO] Selected CFG compilation: {comp_id} for {method}")

    normal_bubo = parse_bubo_log(args.normal_bubol_log)
    slowdown_bubo = parse_bubo_log(args.slowdown_bubol_log)
    compare_bubol_with_vtune(
        args.benchmark,
        normal_bubo,
        slowdown_bubo,
        vtune_loop_values,
        args.output_dir,
        args.min_runtime_share,
        args.max_median_difference,
    )


def main() -> int:
    try:
        run(parse_arguments())
    except (AnalysisError, json.JSONDecodeError, OSError, ValueError) as error:
        print(f"[FAIL] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
