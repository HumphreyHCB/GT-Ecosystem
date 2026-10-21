#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TESTS_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../lib/common.sh
source "$TESTS_DIR/lib/common.sh"
(( ${GT_COMMON_VERSION:-0} >= 4 )) || die 'common.sh version 4 or later is required'
# shellcheck source=Graal-Options.sh
source "$SCRIPT_DIR/Graal-Options.sh"

CONFIG_FILE=${GT_ECOSYSTEM_CONFIG:-"$TESTS_DIR/config.config"}
BENCHMARK=''
ITERATIONS=''
EXTRA_ARGUMENT=''
EXPECTED_SLOWDOWN=''
SLOWDOWN_TOLERANCE_PERCENT=''
GRAAL_REPOSITORY=''
GRAAL_VM_HOME=''
BENCHMARKS_JAR=''
GENERATION_OUTPUT=''
VERIFICATION_OUTPUT=''
COMPILER_REPLAY_DIRECTORY=''
SLOWDOWN_JSON=''
NORMAL_AVERAGE=''
SLOWDOWN_AVERAGE=''
NORMAL_BUBOL_DATA=''
SLOWDOWN_BUBOL_DATA=''
OBSERVED_SLOWDOWN_RATIO=''
MINIMUM_SLOWDOWN_RATIO=''
MAXIMUM_SLOWDOWN_RATIO=''

show_usage() { printf 'Usage: %s --benchmark NAME\n' "$(basename "$0")"; }
parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --benchmark) (( $# >= 2 )) || die '--benchmark requires a name'; BENCHMARK=$2; shift ;;
            --benchmark=*) BENCHMARK=${1#*=} ;;
            -h|--help) show_usage; exit 0 ;;
            *) fail "Unknown argument: $1"; show_usage >&2; exit 2 ;;
        esac
        shift
    done
    [[ -n "$BENCHMARK" ]] || die '--benchmark is required'
}

load_configuration() {
    require_run_context
    require_file "$CONFIG_FILE" 'Ecosystem configuration'
    require_config_value GRAAL_REPOSITORY "$CONFIG_FILE" Dir Graal
    require_config_value BENCHMARKS_JAR "$CONFIG_FILE" Dir AWFYBenchmarksJar
    load_benchmark_configuration "$CONFIG_FILE" "$BENCHMARK" ITERATIONS EXTRA_ARGUMENT \
        EXPECTED_SLOWDOWN SLOWDOWN_TOLERANCE_PERCENT
    GRAAL_VM_HOME="$GRAAL_REPOSITORY/vm/latest_graalvm_home"
    GENERATION_OUTPUT="$GT_PIPELINE_ROOT/stages/bubol/$BENCHMARK/generation"
    VERIFICATION_OUTPUT="$GT_PIPELINE_ROOT/stages/bubol/$BENCHMARK/verification"
    COMPILER_REPLAY_DIRECTORY="$GENERATION_OUTPUT/CompilerReplay"
    SLOWDOWN_JSON="$GENERATION_OUTPUT/Final_$BENCHMARK.json"
    load_graal_options
}

validate_inputs() {
    local replay_file
    require_executable "$GRAAL_VM_HOME/bin/java" 'Latest GraalVM java'
    require_file "$BENCHMARKS_JAR" 'Are We Fast Yet benchmarks JAR'
    require_directory "$COMPILER_REPLAY_DIRECTORY" 'BuboL CompilerReplay input'
    require_file "$SLOWDOWN_JSON" 'Final BuboL slowdown JSON'
    require_file "$GENERATION_OUTPUT/MarkerPhase_BuboIncluded.json" 'BuboL marker phase JSON'
    replay_file=$(find "$COMPILER_REPLAY_DIRECTORY" -type f -print -quit)
    [[ -n "$replay_file" ]] || die "CompilerReplay is empty: $COMPILER_REPLAY_DIRECTORY"
    mkdir -p "$VERIFICATION_OUTPUT"
    load_bubol_verification_options "$COMPILER_REPLAY_DIRECTORY" "$SLOWDOWN_JSON"
}

run_command_with_log() { local output=$1 status; shift; "$@" 2>&1 | tee "$output"; status=${PIPESTATUS[0]}; return "$status"; }
run_benchmark() {
    local output=$1; shift
    run_command_with_log "$output" "$GRAAL_VM_HOME/bin/java" "$@" -cp "$BENCHMARKS_JAR" \
        Harness "$BENCHMARK" "$ITERATIONS" "$EXTRA_ARGUMENT"
}
extract_average_runtime() {
    awk -v benchmark="$BENCHMARK" -v iterations="$ITERATIONS" '
        $1 == benchmark ":" && $2 == "iterations=" iterations && $3 == "average:" && $4 ~ /^[0-9]+us$/ {
            value=$4; sub(/us$/, "", value); matches++
        }
        END {if (matches != 1 || value <= 0) exit 1; print value}
    ' "$1"
}

validate_bubol_output() {
    local output=$1 kind=$2 encoding_count loop_count total_cycles
    read -r encoding_count loop_count total_cycles < <(awk '
        /Found Encoding[[:space:]]*:/ {encodings++}
        /^[[:space:]]*loop[[:space:]]+[0-9]+[[:space:]]+Cycles:[[:space:]]*[0-9]+/ {
            loops++; text=$0; sub(/^.*Cycles:[[:space:]]*/, "", text); split(text, fields, /[[:space:]]+/); total += fields[1]
        }
        END {printf "%d %d %.0f\n", encodings, loops, total}
    ' "$output")
    (( encoding_count > 0 && loop_count > 0 && total_cycles > 0 )) || {
        fail "Missing usable BuboL data in $output"; return 1;
    }
    if [[ "$kind" == normal ]]; then
        NORMAL_BUBOL_DATA="$encoding_count encodings, $loop_count loops, $total_cycles cycles"
    else
        SLOWDOWN_BUBOL_DATA="$encoding_count encodings, $loop_count loops, $total_cycles cycles"
    fi
}

run_normal() {
    local log="$VERIFICATION_OUTPUT/Normal-BuboL.log"
    run_benchmark "$log" "${GT_GRAAL_OPTIONS[@]}" "${BUBOL_REPLAY_OPTIONS[@]}" \
        "${BUBOL_NORMAL_OPTIONS[@]}" || return 1
    validate_bubol_output "$log" normal || return 1
    NORMAL_AVERAGE=$(extract_average_runtime "$log") || { fail "Cannot read average runtime from $log"; return 1; }
}

run_slowdown() {
    local log="$VERIFICATION_OUTPUT/Slowdown-BuboL.log"
    run_benchmark "$log" "${GT_GRAAL_OPTIONS[@]}" "${BUBOL_REPLAY_OPTIONS[@]}" \
        "${BUBOL_SLOWDOWN_OPTIONS[@]}" || return 1
    validate_bubol_output "$log" slowdown || return 1
    SLOWDOWN_AVERAGE=$(extract_average_runtime "$log") || { fail "Cannot read average runtime from $log"; return 1; }
}

verify_ratio() {
    MINIMUM_SLOWDOWN_RATIO=$(awk -v e="$EXPECTED_SLOWDOWN" -v t="$SLOWDOWN_TOLERANCE_PERCENT" 'BEGIN {printf "%.6f", e*(1-t/100)}')
    MAXIMUM_SLOWDOWN_RATIO=$(awk -v e="$EXPECTED_SLOWDOWN" -v t="$SLOWDOWN_TOLERANCE_PERCENT" 'BEGIN {printf "%.6f", e*(1+t/100)}')
    OBSERVED_SLOWDOWN_RATIO=$(awk -v n="$NORMAL_AVERAGE" -v s="$SLOWDOWN_AVERAGE" 'BEGIN {printf "%.6f", s/n}')
    write_summary || return 1
    awk -v o="$OBSERVED_SLOWDOWN_RATIO" -v min="$MINIMUM_SLOWDOWN_RATIO" -v max="$MAXIMUM_SLOWDOWN_RATIO" \
        'BEGIN {exit !(o >= min && o <= max)}' || {
        fail "Observed ${OBSERVED_SLOWDOWN_RATIO}x; expected ${MINIMUM_SLOWDOWN_RATIO}x to ${MAXIMUM_SLOWDOWN_RATIO}x"; return 1;
    }
}

write_summary() {
    python3 - "$VERIFICATION_OUTPUT/summary.json" "$BENCHMARK" "$EXPECTED_SLOWDOWN" \
        "$OBSERVED_SLOWDOWN_RATIO" "$NORMAL_AVERAGE" "$SLOWDOWN_AVERAGE" \
        "$MINIMUM_SLOWDOWN_RATIO" "$MAXIMUM_SLOWDOWN_RATIO" "$NORMAL_BUBOL_DATA" "$SLOWDOWN_BUBOL_DATA" <<'PY'
import json, pathlib, sys
path, benchmark, expected, achieved, normal, slowdown, minimum, maximum, normal_data, slowdown_data = sys.argv[1:]
data = {"benchmark": benchmark, "expected_slowdown_ratio": float(expected),
        "achieved_slowdown_ratio": float(achieved), "normal_average_us": int(normal),
        "slowdown_average_us": int(slowdown), "accepted_minimum_ratio": float(minimum),
        "accepted_maximum_ratio": float(maximum), "normal_bubol_data": normal_data,
        "slowdown_bubol_data": slowdown_data}
pathlib.Path(path).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

main() {
    parse_arguments "$@"
    task "Verify BuboL slowdown for $BENCHMARK"
    INDENT_LEVEL=$((INDENT_LEVEL + 1)); export INDENT_LEVEL
    run_step 'Load BuboL verification configuration' load_configuration
    run_step 'Validate BuboL verification inputs' validate_inputs
    run_step 'Run normal BuboL compiler replay' run_normal
    run_step 'Run slowdown BuboL compiler replay' run_slowdown
    run_step 'Verify BuboL slowdown ratio' verify_ratio
    report_check bubol "$BENCHMARK slowdown verified" \
        "Expected ${EXPECTED_SLOWDOWN}x; achieved ${OBSERVED_SLOWDOWN_RATIO}x; $SLOWDOWN_BUBOL_DATA"
    INDENT_LEVEL=$((INDENT_LEVEL - 1)); export INDENT_LEVEL
    pass "BuboL verification passed for $BENCHMARK"
}
main "$@"
