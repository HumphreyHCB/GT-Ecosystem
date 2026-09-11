#!/usr/bin/env python3

"""Compare BuboL per-loop cycle measurements with VTune block timings.

The VTune/CFG/probe matching path deliberately follows the older working
script as closely as possible.  The command-line interface, output filenames,
and final BuboL-vs-VTune validation are retained from the newer ecosystem
script.
"""

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


class AnalysisError(RuntimeError):
    """A validation failure that should fail the ecosystem stage."""


# ============================================================
# Part 1: HumphreysDebugDataPhase output
# Working-script parsing behaviour retained.
# ============================================================


@dataclass
class Block:
    bid: int
    successors: List[int] = field(default_factory=list)
    loop: Optional[str] = None
    sources: List[str] = field(default_factory=list)

    bubo_lines: List[str] = field(default_factory=list)
    marker_classes: List[str] = field(default_factory=list)
    marker_loop_ids: Dict[str, int] = field(default_factory=dict)

    has_rdtsc: bool = False
    has_gt_marker: bool = False


@dataclass
class Compilation:
    name: str
    blocks: Dict[int, Block]


def parse_debug_output(text: str) -> List[Compilation]:
    lines = text.splitlines()
    comps: List[Compilation] = []

    in_comp = False
    comp_name: Optional[str] = None
    blocks: Dict[int, Block] = {}
    current_block: Optional[Block] = None
    mode: Optional[str] = None
    last_marker_class: Optional[str] = None

    for raw in lines:
        line = raw.strip()

        if line.startswith("=== HumphreysDebugDataPhase ==="):
            in_comp = True
            comp_name = None
            blocks = {}
            current_block = None
            mode = None
            last_marker_class = None
            continue

        if not in_comp:
            continue

        if line.startswith("=== End HumphreysDebugDataPhase ==="):
            if comp_name is None:
                comp_name = "<unknown-compilation>"
            comps.append(Compilation(name=comp_name, blocks=blocks))
            in_comp = False
            current_block = None
            mode = None
            last_marker_class = None
            continue

        if line.startswith("Compilation: "):
            comp_name = line[len("Compilation: "):].strip()
            continue

        if line.startswith("Number of loops:"):
            continue

        if line.startswith("Block "):
            m = re.match(r"Block\s+(\d+)", line)
            if not m:
                continue
            bid = int(m.group(1))
            current_block = Block(bid)
            blocks[bid] = current_block
            mode = None
            last_marker_class = None
            continue

        if line.startswith("Successors:"):
            mode = "succ"
            continue

        if line.startswith("Predecessors:"):
            mode = "pred"
            continue

        if line.startswith("In loop:"):
            if current_block is not None:
                val = line[len("In loop:"):].strip()
                current_block.loop = None if val == "<none>" else val
            continue

        if line.startswith("Source positions in block:"):
            mode = "src"
            continue

        if line.startswith("BuboLoopMakers:"):
            mode = "bubo"
            last_marker_class = None
            continue

        if current_block is None:
            continue

        if mode == "succ":
            if "->" in line:
                succ_str = line.split("->", 1)[1].strip()
                if succ_str:
                    try:
                        current_block.successors.append(int(succ_str))
                    except ValueError:
                        pass
            continue

        if mode == "src":
            if line and line != "<none>":
                current_block.sources.append(line)
            continue

        if mode == "bubo":
            if not line:
                continue

            current_block.bubo_lines.append(line)

            m = re.search(r"Found in this block\s*:\s*(?:class\s+)?(.+)$", line)
            if m:
                cls = m.group(1).strip()
                current_block.marker_classes.append(cls)
                last_marker_class = cls

                u = cls.upper()
                if "RDTSC" in u or "RDTSCP" in u or "RDTCP" in u:
                    current_block.has_rdtsc = True

                if "GT" in u or "SLOWDOWN" in u or "GTSLOW" in u:
                    current_block.has_gt_marker = True
                continue

            m = re.match(r"LoopID:\s*(\d+)", line)
            if m and last_marker_class is not None:
                current_block.marker_loop_ids[last_marker_class] = int(m.group(1))
                continue

            continue

    return comps


# ============================================================
# Part 2: The old DOT -> loops.csv/probe_nodes.csv logic,
# performed directly in memory so the new program keeps its
# current input/output layout.
# ============================================================


def normalise_method_name(s: str) -> str:
    return s.strip().replace("::", ".")


def parse_graph_label(label: str) -> Tuple[Optional[int], str]:
    comp_id = None
    method = label
    m = re.match(r"^\s*(\d+)\s*-\s*(.+?)\s*$", label)
    if m:
        comp_id = int(m.group(1))
        rest = m.group(2).strip()
        method = rest.split("(", 1)[0].strip()
    return comp_id, method


def exact_rdtsc_probe_loop_id(block: Block) -> Optional[int]:
    """Match the exact probe class used by the working script's RDTSC_RE."""
    for marker_class, loop_id in block.marker_loop_ids.items():
        short_name = marker_class.split(".")[-1]
        if short_name == "AMD64BuboRDTSCToSlot":
            return loop_id
    return None


def infer_looplabel_to_loopid(
    node_looplabel: Dict[int, str],
    node_rdtsc_loopid: Dict[int, int],
    edges: List[Tuple[int, int]],
) -> Dict[str, int]:
    looplabel_to_id: Dict[str, int] = {}

    succs: Dict[int, List[int]] = {}
    for s, d in edges:
        succs.setdefault(s, []).append(d)

    # The old DOT writer emitted nodes in numeric order, so retain that order.
    for src in sorted(node_rdtsc_loopid):
        k = node_rdtsc_loopid[src]
        for dst in succs.get(src, []):
            lx = node_looplabel.get(dst)
            if lx is None:
                continue
            # Working-script behaviour: first mapping wins.
            if lx not in looplabel_to_id:
                looplabel_to_id[lx] = k

    return looplabel_to_id


def infer_probe_nodes_for_loopid(
    node_looplabel: Dict[int, str],
    node_rdtsc_loopid: Dict[int, int],
    edges: List[Tuple[int, int]],
    looplabel_to_id: Dict[str, int],
) -> Dict[int, Set[int]]:
    succs: Dict[int, List[int]] = {}
    for s, d in edges:
        succs.setdefault(s, []).append(d)

    out: Dict[int, Set[int]] = defaultdict(set)

    for src in sorted(node_rdtsc_loopid):
        marker_loopid = node_rdtsc_loopid[src]
        assigned: Optional[int] = None

        for dst in succs.get(src, []):
            lx = node_looplabel.get(dst)
            if lx is None:
                continue
            lid = looplabel_to_id.get(lx)
            if lid is not None:
                assigned = lid
                break

        if assigned is None:
            assigned = marker_loopid

        out[assigned].add(src)

    return out


def build_cfg_maps_from_debug(
    compilations: Iterable[Compilation],
) -> Tuple[
    Dict[str, List[int]],
    Dict[Tuple[int, str, int], int],
    Dict[Tuple[int, str, int], Set[int]],
]:
    method_to_comps_set: Dict[str, Set[int]] = defaultdict(set)
    node_map: Dict[Tuple[int, str, int], int] = {}
    probe_blocks_by_loop: Dict[Tuple[int, str, int], Set[int]] = defaultdict(set)

    for compilation in compilations:
        comp_id, method = parse_graph_label(compilation.name)
        if comp_id is None:
            continue

        method_norm = normalise_method_name(method)
        method_to_comps_set[method_norm].add(comp_id)

        node_looplabel: Dict[int, str] = {}
        node_rdtsc_loopid: Dict[int, int] = {}
        edges: List[Tuple[int, int]] = []

        # This reproduces the information that the working script wrote to DOT
        # and then parsed back from the DOT files.
        for bid in sorted(compilation.blocks):
            block = compilation.blocks[bid]

            if block.loop is not None:
                node_looplabel[bid] = block.loop

            probe_loop_id = exact_rdtsc_probe_loop_id(block)
            if probe_loop_id is not None:
                node_rdtsc_loopid[bid] = probe_loop_id

            for successor in block.successors:
                if successor in compilation.blocks:
                    edges.append((bid, successor))

        looplabel_to_id = infer_looplabel_to_loopid(
            node_looplabel,
            node_rdtsc_loopid,
            edges,
        )

        probe_nodes_by_loopid = infer_probe_nodes_for_loopid(
            node_looplabel,
            node_rdtsc_loopid,
            edges,
            looplabel_to_id,
        )

        for node, loop_label in node_looplabel.items():
            if loop_label not in looplabel_to_id:
                continue
            node_map[(comp_id, method_norm, node)] = looplabel_to_id[loop_label]

        for loop_id, nodes in probe_nodes_by_loopid.items():
            for graal_block_id in nodes:
                probe_blocks_by_loop[(comp_id, method_norm, loop_id)].add(
                    graal_block_id
                )

    method_to_comps = {
        method: sorted(comp_ids)
        for method, comp_ids in method_to_comps_set.items()
    }

    if not node_map:
        raise AnalysisError("CFG data produced no Graal-block to BuboL-loop mappings")
    if not probe_blocks_by_loop:
        raise AnalysisError("CFG data produced no RDTSC probe-block mappings")

    return method_to_comps, node_map, probe_blocks_by_loop


# ============================================================
# Part 3: slowdown blocks + bridge + MarkerPhaseInfo
# Working-script matching behaviour retained.
# ============================================================


NUMBER = r"-?\d+(?:\.\d+)?"

LINE_RE = re.compile(
    rf"^Method:\s*(?P<method>.*?),\s*"
    rf"Block ID:\s*(?P<block>\d+),\s*"
    rf"Normal Time:\s*(?P<normal>{NUMBER}),\s*"
    rf"Slowdown Time:\s*(?P<slow>{NUMBER}),\s*"
    rf"Percentage Increase:\s*(?P<pct>{NUMBER})(?:%)?\s*$"
)

RDTSC_LINE_RE = re.compile(
    rf"^Method:\s*(?P<method>.*?),\s*"
    rf"Block ID:\s*(?P<block>\d+),\s*"
    rf"RDTSC Normal Time:\s*(?P<normal>{NUMBER}),\s*"
    rf"RDTSC Slowdown Time:\s*(?P<slow>{NUMBER}),\s*"
    rf"RDTSC Percentage Increase:\s*(?P<pct>{NUMBER})(?:%)?\s*$"
)

BRIDGE_KEY_RE = re.compile(
    r"^\s*(?P<graal>\d+)\s*\(Vtune Block\s*(?P<vtune>\d+)\)\s*$"
)


@dataclass(frozen=True)
class BlockRow:
    method_raw: str
    method_norm: str
    block_id: int
    normal_time: float
    slowdown_time: float


@dataclass(frozen=True)
class RdtscRow:
    method_raw: str
    method_norm: str
    vtune_block_id: int
    rdtsc_normal: float
    rdtsc_slow: float


@dataclass
class LoopAgg:
    num_blocks: int = 0
    sum_normal: float = 0.0
    sum_slow: float = 0.0
    probe_sum_normal: float = 0.0
    probe_sum_slow: float = 0.0
    probe_count: int = 0


def safe_pct_increase(normal: float, slow: float) -> float:
    if normal <= 0.0:
        return 0.0
    return ((slow - normal) / normal) * 100.0


def read_slowdown_and_rdtsc_rows(
    path: Path,
) -> Tuple[List[BlockRow], Dict[Tuple[str, int], RdtscRow], int, int, int]:
    block_rows: List[BlockRow] = []
    rdtsc_map: Dict[Tuple[str, int], RdtscRow] = {}

    matched_blocks = 0
    matched_rdtsc = 0
    total = 0

    with path.open("r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            total += 1
            line = raw.strip()
            if not line:
                continue

            m = LINE_RE.match(line)
            if m:
                method_raw = m.group("method").strip()
                method_norm = normalise_method_name(method_raw)
                block_rows.append(
                    BlockRow(
                        method_raw=method_raw,
                        method_norm=method_norm,
                        block_id=int(m.group("block")),
                        normal_time=float(m.group("normal")),
                        slowdown_time=float(m.group("slow")),
                    )
                )
                matched_blocks += 1
                continue

            r = RDTSC_LINE_RE.match(line)
            if r:
                method_raw = r.group("method").strip()
                method_norm = normalise_method_name(method_raw)
                vtune_block_id = int(r.group("block"))
                rr = RdtscRow(
                    method_raw=method_raw,
                    method_norm=method_norm,
                    vtune_block_id=vtune_block_id,
                    rdtsc_normal=float(r.group("normal")),
                    rdtsc_slow=float(r.group("slow")),
                )
                rdtsc_map[(method_norm, vtune_block_id)] = rr
                matched_rdtsc += 1
                continue

    if not block_rows:
        raise AnalysisError(f"No normal VTune block rows were found in {path}")
    if not rdtsc_map:
        raise AnalysisError(f"No RDTSC VTune block rows were found in {path}")

    return block_rows, rdtsc_map, matched_blocks, matched_rdtsc, total


def read_bridge_vtune_to_graal(path: Path) -> Dict[str, Dict[int, int]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    out: Dict[str, Dict[int, int]] = {}

    for method, mapping in data.items():
        method_norm = normalise_method_name(method)
        vtune_to_graal: Dict[int, int] = {}

        if not isinstance(mapping, dict):
            continue

        for k in mapping.keys():
            m = BRIDGE_KEY_RE.match(str(k))
            if not m:
                continue
            graal_id = int(m.group("graal"))
            vtune_id = int(m.group("vtune"))
            vtune_to_graal[vtune_id] = graal_id

        out[method_norm] = vtune_to_graal

    if not any(out.values()):
        raise AnalysisError(f"No VTune-to-Graal block mappings were found in {path}")

    return out


def read_markerphase_graal_to_vtune(path: Path) -> Dict[str, Dict[int, int]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    out: Dict[str, Dict[int, int]] = {}

    if not isinstance(data, dict):
        return out

    for method, arr in data.items():
        method_norm = normalise_method_name(method)
        graal_to_vtune: Dict[int, int] = {}

        if not isinstance(arr, list):
            continue

        for entry in arr:
            if not isinstance(entry, dict):
                continue
            g = entry.get("GraalID")
            v = entry.get("VtuneBlock")
            if g is None or v is None:
                continue
            try:
                graal_id = int(str(g).strip())
                vtune_id = int(str(v).strip())
            except ValueError:
                continue
            graal_to_vtune[graal_id] = vtune_id

        out[method_norm] = graal_to_vtune

    if not any(out.values()):
        raise AnalysisError(f"No Graal-to-VTune marker mappings were found in {path}")

    return out


def invert_graal_to_vtune_map(
    graal_to_vtune_by_method: Dict[str, Dict[int, int]],
) -> Dict[str, Dict[int, int]]:
    out: Dict[str, Dict[int, int]] = {}
    for method_norm, g2v in graal_to_vtune_by_method.items():
        v2g: Dict[int, int] = {}
        for g, v in g2v.items():
            if v not in v2g or g < v2g[v]:
                v2g[v] = g
        out[method_norm] = v2g
    return out


def choose_best_comp_per_method(
    blocks: List[BlockRow],
    method_to_comps: Dict[str, List[int]],
    node_map: Dict[Tuple[int, str, int], int],
    slowdown_block_id_is_vtune: bool,
    vtune_to_graal_by_method: Dict[str, Dict[int, int]],
    vtune_to_graal_fallback_by_method: Dict[str, Dict[int, int]],
    enable_method_fallback_match: bool,
) -> Dict[str, int]:
    def method_alternatives(m: str) -> List[str]:
        if not enable_method_fallback_match:
            return [m]
        alt = m.replace(".", "::") if "." in m else m.replace("::", ".")
        alt_norm = normalise_method_name(alt)
        if alt_norm != m:
            return [m, alt_norm]
        return [m]

    method_to_graal_blocks: Dict[str, List[int]] = defaultdict(list)

    for br in blocks:
        method_norm = br.method_norm

        if slowdown_block_id_is_vtune:
            vtune_bid = br.block_id

            vtune_to_graal = vtune_to_graal_by_method.get(method_norm, {})
            graal_bid = vtune_to_graal.get(vtune_bid)

            if graal_bid is None:
                fallback = vtune_to_graal_fallback_by_method.get(method_norm, {})
                graal_bid = fallback.get(vtune_bid)

            if graal_bid is None:
                continue
        else:
            graal_bid = br.block_id

        method_to_graal_blocks[method_norm].append(graal_bid)

    best_comp_for_method: Dict[str, int] = {}

    for method_norm, graal_bids in method_to_graal_blocks.items():
        candidate_comps: Set[int] = set()
        for m in method_alternatives(method_norm):
            for cid in method_to_comps.get(m, []):
                candidate_comps.add(cid)

        if not candidate_comps:
            continue

        best_score = -1
        best_cid = None

        for cid in sorted(candidate_comps):
            score = 0
            for m in method_alternatives(method_norm):
                for gb in graal_bids:
                    if (cid, m, gb) in node_map:
                        score += 1

            if score > best_score or (
                score == best_score
                and best_cid is not None
                and cid > best_cid
            ):
                best_score = score
                best_cid = cid

        if best_cid is not None and best_score > 0:
            best_comp_for_method[method_norm] = best_cid

    return best_comp_for_method


def find_comp_for_method_block(
    method_norm: str,
    block_id: int,
    method_to_comps: Dict[str, List[int]],
    node_map: Dict[Tuple[int, str, int], int],
    enable_fallback: bool,
) -> Optional[int]:
    comps = method_to_comps.get(method_norm, [])
    for cid in reversed(comps):
        if (cid, method_norm, block_id) in node_map:
            return cid

    if not enable_fallback:
        return None

    alt = (
        method_norm.replace(".", "::")
        if "." in method_norm
        else method_norm.replace("::", ".")
    )
    alt_norm = normalise_method_name(alt)
    comps = method_to_comps.get(alt_norm, [])
    for cid in reversed(comps):
        if (cid, alt_norm, block_id) in node_map:
            return cid
    return None


def build_vtune_totals(
    vtune_report: Path,
    bridge_json: Path,
    markerphase_json: Path,
    method_to_comps: Dict[str, List[int]],
    node_map: Dict[Tuple[int, str, int], int],
    probe_blocks_by_loop: Dict[Tuple[int, str, int], Set[int]],
) -> Tuple[
    Dict[Tuple[int, str, int], LoopAgg],
    List[Dict[str, object]],
    Dict[str, int],
    Dict[str, int],
]:
    blocks, rdtsc_map, matched, matched_rdtsc, total = read_slowdown_and_rdtsc_rows(
        vtune_report
    )

    # The new ecosystem input always supplies VTune block IDs and both mapping files.
    # The matching order below is the same as the working script:
    # Final_*.json first, MarkerPhaseInfo inversion second.
    vtune_to_graal_by_method = read_bridge_vtune_to_graal(bridge_json)
    graal_to_vtune_by_method = read_markerphase_graal_to_vtune(markerphase_json)
    vtune_to_graal_fallback_by_method = invert_graal_to_vtune_map(
        graal_to_vtune_by_method
    )

    grouped: Dict[Tuple[int, str, int], LoopAgg] = defaultdict(LoopAgg)
    block_rows: List[Dict[str, object]] = []

    missing_methodblock = 0
    missing_block = 0
    used = 0
    missing_bridge = 0

    # Same compilation-selection algorithm as the working script.
    best_comp_by_method = choose_best_comp_per_method(
        blocks=blocks,
        method_to_comps=method_to_comps,
        node_map=node_map,
        slowdown_block_id_is_vtune=True,
        vtune_to_graal_by_method=vtune_to_graal_by_method,
        vtune_to_graal_fallback_by_method=vtune_to_graal_fallback_by_method,
        enable_method_fallback_match=True,
    )

    for br in blocks:
        method_norm = br.method_norm
        vtune_block_id = br.block_id

        vtune_to_graal = vtune_to_graal_by_method.get(method_norm, {})
        graal_block_id = vtune_to_graal.get(vtune_block_id)

        if graal_block_id is None:
            fallback = vtune_to_graal_fallback_by_method.get(method_norm, {})
            graal_block_id = fallback.get(vtune_block_id)

        if graal_block_id is None:
            missing_bridge += 1
            continue

        comp_id = best_comp_by_method.get(method_norm)
        if comp_id is None:
            comp_id = find_comp_for_method_block(
                method_norm,
                graal_block_id,
                method_to_comps,
                node_map,
                True,
            )

        if comp_id is None:
            missing_methodblock += 1
            continue

        loop_id = node_map.get((comp_id, method_norm, graal_block_id))
        if loop_id is None:
            missing_block += 1
            continue

        g = grouped[(comp_id, method_norm, loop_id)]
        g.num_blocks += 1
        g.sum_normal += br.normal_time
        g.sum_slow += br.slowdown_time
        used += 1

        block_rows.append(
            {
                "comp_id": comp_id,
                "method": method_norm,
                "loop_id": loop_id,
                "vtune_block_id": vtune_block_id,
                "graal_block_id": graal_block_id,
                "normal_time": br.normal_time,
                "slowdown_time": br.slowdown_time,
                "pct_increase_block": safe_pct_increase(
                    br.normal_time, br.slowdown_time
                ),
            }
        )

    probe_added_keys = 0
    probe_added_blocks = 0
    probe_missing_marker_map = 0
    probe_missing_rdtsc_line = 0

    # This is the probe-augmentation block from the working script.
    for (comp_id, method_norm, loop_id), g in grouped.items():
        probe_graal_blocks = probe_blocks_by_loop.get(
            (comp_id, method_norm, loop_id)
        )
        if not probe_graal_blocks:
            continue

        graal_to_vtune = graal_to_vtune_by_method.get(method_norm)
        if not graal_to_vtune:
            probe_missing_marker_map += len(probe_graal_blocks)
            continue

        any_added = False

        for graal_bid in probe_graal_blocks:
            vtune_bid = graal_to_vtune.get(graal_bid)
            if vtune_bid is None:
                probe_missing_marker_map += 1
                continue

            rr = rdtsc_map.get((method_norm, vtune_bid))
            if rr is None:
                probe_missing_rdtsc_line += 1
                continue

            g.probe_sum_normal += rr.rdtsc_normal
            g.probe_sum_slow += rr.rdtsc_slow
            g.probe_count += 1
            probe_added_blocks += 1
            any_added = True

        if any_added:
            probe_added_keys += 1

    if not grouped:
        raise AnalysisError("No VTune blocks could be assigned to BuboL loops")
    if probe_added_blocks == 0:
        raise AnalysisError(
            "No RDTSC probe timings were added through the marker phase JSON"
        )

    statistics_map = {
        "report_lines": total,
        "matched_blocks": matched,
        "matched_rdtsc": matched_rdtsc,
        "blocks_used": used,
        "bridge_misses": missing_bridge,
        "missing_methodblock": missing_methodblock,
        "cfg_misses": missing_block,
        "probe_loops_updated": probe_added_keys,
        "probe_blocks_added": probe_added_blocks,
        "probe_marker_misses": probe_missing_marker_map,
        "probe_timing_misses": probe_missing_rdtsc_line,
    }

    return grouped, block_rows, statistics_map, best_comp_by_method


# ============================================================
# New ecosystem outputs and final BuboL comparison.
# ============================================================


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


BUBO_COMP_RE = re.compile(r"^Comp\s+(\d+)\s*\((.*?)\)\s*loops:\s*$")
BUBO_ENCODING_RE = re.compile(r"^Found Encoding\s*:\s*(.*)")
BUBO_LOOP_RE = re.compile(
    r"loop\s+(\d+)\s+Cycles:\s*([0-9]+)\s*\|\|\s*"
    r"Activation Count:\s*([0-9]+)\s*\|\s*LoopCallCount:\s*([0-9]+)\s*\|"
)
BUBO_TOTAL_RE = re.compile(
    r"Bubo\.RDTSC\.Harness\.main Total RDTSC cycles:\s*([0-9]+)"
)


def normalise_bubo_method(value: str) -> str:
    # Keep the newer Bubo-log cleanup because these logs are a new input to this stage.
    value = value.strip().strip('"').replace("::", ".")
    value = re.sub(r"-(?:Re-Comp|OSR).*?$", "", value).strip()
    if "(" in value:
        value = value.split("(", 1)[0]
    return value.strip().rstrip(",")


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
                comp_methods[comp_id] = normalise_bubo_method(comp_match.group(2))
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
            if (
                parent_id != -1
                and loop_id in current_loops
                and parent_id in current_loops
            ):
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


def write_csv(
    path: Path,
    fieldnames: List[str],
    rows: Iterable[Dict[str, object]],
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as destination:
        writer = csv.DictWriter(destination, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def write_cfg_map(
    output_dir: Path,
    node_map: Dict[Tuple[int, str, int], int],
) -> None:
    rows = [
        {
            "comp_id": comp_id,
            "method": method,
            "graal_block_id": graal_block_id,
            "loop_id": loop_id,
        }
        for (comp_id, method, graal_block_id), loop_id in sorted(node_map.items())
    ]

    write_csv(
        output_dir / "CFG-Block-to-Loop.csv",
        ["comp_id", "method", "graal_block_id", "loop_id"],
        rows,
    )


def write_vtune_outputs(
    output_dir: Path,
    grouped: Dict[Tuple[int, str, int], LoopAgg],
    block_rows: List[Dict[str, object]],
) -> Dict[Tuple[int, str, int], float]:
    loop_values: Dict[Tuple[int, str, int], float] = {}
    loop_rows: List[Dict[str, object]] = []

    for key in sorted(grouped):
        comp_id, method, loop_id = key
        totals = grouped[key]
        total_normal = totals.sum_normal + totals.probe_sum_normal
        total_slowdown = totals.sum_slow + totals.probe_sum_slow
        slowdown_pct = safe_pct_increase(total_normal, total_slowdown)
        loop_values[key] = slowdown_pct

        loop_rows.append(
            {
                "comp_id": comp_id,
                "method": method,
                "loop_id": loop_id,
                "num_blocks_matched": totals.num_blocks,
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

    # VTune has already selected one compilation per method.  For the final
    # BuboL comparison, match that selected VTune result by method + loop ID,
    # as the working script does, rather than requiring BuboL's compilation ID
    # to be identical to VTune's selected compilation ID.
    vtune_by_method_loop: Dict[Tuple[str, int], float] = {
        (method, loop_id): value
        for (_comp_id, method, loop_id), value in vtune_loop_values.items()
    }

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
            bubol_pct = safe_pct_increase(
                float(normal_loop.exclusive_cycles),
                float(slowdown_loop.exclusive_cycles),
            )

        vtune_pct = vtune_by_method_loop.get(
            (method, slowdown_loop.loop_id)
        )
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
                missing_vtune.append(
                    f"{method}, loop {slowdown_loop.loop_id}"
                )
            else:
                qualifying_differences.append(
                    difference if difference is not None else 0.0
                )

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

    print(
        f"[INFO] BuboL baseline: {normal_bubo.encoding_count} encodings, "
        f"{len(normal_bubo.loops)} loops"
    )
    print(
        f"[INFO] BuboL slowdown: {slowdown_bubo.encoding_count} encodings, "
        f"{len(slowdown_bubo.loops)} loops, "
        f"{slowdown_bubo.total_cycles} total cycles"
    )
    print(f"[INFO] Qualifying loops: {qualifying_count}")
    print(f"[INFO] Comparison CSV: {comparison_path}")

    failures: List[str] = []
    if qualifying_count == 0:
        failures.append(
            f"no pure {benchmark} loops exceeded {min_runtime_share:.2f}% runtime share"
        )
    if missing_normal:
        failures.append(
            "qualifying BuboL loops were absent from the baseline: "
            + "; ".join(missing_normal)
        )
    if missing_vtune:
        failures.append(
            "qualifying loops did not have a matching VTune method and loop: "
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
            if (
                row["qualifies"] == "true"
                and row["absolute_difference_pct_points"] != ""
            ):
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


# ============================================================
# New ecosystem command-line interface and output locations.
# ============================================================


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
        (args.markerphase_json, "marker phase JSON"),
        (args.normal_bubol_log, "normal BuboL log"),
        (args.slowdown_bubol_log, "slowdown BuboL log"),
    ):
        require_input_file(path, description)

    args.output_dir.mkdir(parents=True, exist_ok=True)

    # Same logical stages as the old working script, but kept in memory so the
    # new stage does not need its old processed/cfg/dots directory structure.
    debug_text = args.cfg_log.read_text(encoding="utf-8", errors="replace")
    compilations = parse_debug_output(debug_text)
    if not compilations:
        raise AnalysisError(
            f"No HumphreysDebugDataPhase sections were found in {args.cfg_log}"
        )

    method_to_comps, node_map, probe_blocks_by_loop = build_cfg_maps_from_debug(
        compilations
    )
    write_cfg_map(args.output_dir, node_map)

    grouped, block_rows, mapping_statistics, selected_compilations = (
        build_vtune_totals(
            args.vtune_report,
            args.bridge_json,
            args.markerphase_json,
            method_to_comps,
            node_map,
            probe_blocks_by_loop,
        )
    )

    vtune_loop_values = write_vtune_outputs(
        args.output_dir,
        grouped,
        block_rows,
    )

    print(f"[INFO] CFG compilations: {len(compilations)}")
    print(f"[INFO] CFG block-to-loop mappings: {len(node_map)}")
    print(
        f"[INFO] VTune report: {mapping_statistics['report_lines']} lines, "
        f"{mapping_statistics['matched_blocks']} block rows, "
        f"{mapping_statistics['matched_rdtsc']} RDTSC rows"
    )
    print(f"[INFO] VTune blocks used: {mapping_statistics['blocks_used']}")
    print(f"[INFO] VTune bridge misses: {mapping_statistics['bridge_misses']}")
    print(f"[INFO] VTune CFG misses: {mapping_statistics['cfg_misses']}")
    print(
        f"[INFO] RDTSC probe blocks added: "
        f"{mapping_statistics['probe_blocks_added']}"
    )
    print(
        f"[INFO] Probe marker phase misses: "
        f"{mapping_statistics['probe_marker_misses']}"
    )
    print(
        f"[INFO] Probe timing misses: "
        f"{mapping_statistics['probe_timing_misses']}"
    )

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
