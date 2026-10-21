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
    GENERATION_OUTPUT="$GT_PIPELINE_ROOT/stages/divine/$BENCHMARK/generation"
    VERIFICATION_OUTPUT="$GT_PIPELINE_ROOT/stages/divine/$BENCHMARK/verification"
    COMPILER_REPLAY_DIRECTORY="$GENERATION_OUTPUT/CompilerReplay"
    SLOWDOWN_JSON="$GENERATION_OUTPUT/Final_$BENCHMARK.json"
    load_graal_options
}

validate_inputs() {
    local replay_file
    require_executable "$GRAAL_VM_HOME/bin/java" 'Latest GraalVM java'
    require_file "$BENCHMARKS_JAR" 'Are We Fast Yet benchmarks JAR'
    require_directory "$COMPILER_REPLAY_DIRECTORY" 'CompilerReplay input'
    require_file "$SLOWDOWN_JSON" 'Final slowdown JSON'
    [[ -s "$SLOWDOWN_JSON" ]] || die "Final slowdown JSON is empty: $SLOWDOWN_JSON"
    replay_file=$(find "$COMPILER_REPLAY_DIRECTORY" -type f -print -quit)
    [[ -n "$replay_file" ]] || die "CompilerReplay is empty: $COMPILER_REPLAY_DIRECTORY"
    mkdir -p "$VERIFICATION_OUTPUT"
    load_divine_verification_options "$COMPILER_REPLAY_DIRECTORY" "$SLOWDOWN_JSON"
}

run_command_with_log() {
    local output_file=$1 status
    shift
    "$@" 2>&1 | tee "$output_file"
    status=${PIPESTATUS[0]}
    return "$status"
}

run_benchmark() {
    local output_file=$1
    shift
    run_command_with_log "$output_file" "$GRAAL_VM_HOME/bin/java" "$@" \
        -cp "$BENCHMARKS_JAR" Harness "$BENCHMARK" "$ITERATIONS" "$EXTRA_ARGUMENT"
}

extract_average_runtime() {
    local output_file=$1
    awk -v benchmark="$BENCHMARK" -v iterations="$ITERATIONS" '
        $1 == benchmark ":" && $2 == "iterations=" iterations && $3 == "average:" && $4 ~ /^[0-9]+us$/ {
            value=$4; sub(/us$/, "", value); matches++
        }
        END { if (matches != 1 || value <= 0) exit 1; print value }
    ' "$output_file"
}

run_normal_replay() {
    local log="$VERIFICATION_OUTPUT/Normal.log"
    run_benchmark "$log" "${GT_GRAAL_OPTIONS[@]}" "${DIVINE_REPLAY_OPTIONS[@]}" || return 1
    NORMAL_AVERAGE=$(extract_average_runtime "$log") || { fail "Cannot read average runtime from $log"; return 1; }
    pass "Normal average: ${NORMAL_AVERAGE}us"
}

run_slowdown_replay() {
    local log="$VERIFICATION_OUTPUT/Slowdown.log"
    run_benchmark "$log" "${GT_GRAAL_OPTIONS[@]}" "${DIVINE_REPLAY_OPTIONS[@]}" \
        "${DIVINE_SLOWDOWN_OPTIONS[@]}" || return 1
    SLOWDOWN_AVERAGE=$(extract_average_runtime "$log") || { fail "Cannot read average runtime from $log"; return 1; }
    pass "Slowdown average: ${SLOWDOWN_AVERAGE}us"
}

verify_ratio() {
    MINIMUM_SLOWDOWN_RATIO=$(awk -v e="$EXPECTED_SLOWDOWN" -v t="$SLOWDOWN_TOLERANCE_PERCENT" 'BEGIN {printf "%.6f", e*(1-t/100)}')
    MAXIMUM_SLOWDOWN_RATIO=$(awk -v e="$EXPECTED_SLOWDOWN" -v t="$SLOWDOWN_TOLERANCE_PERCENT" 'BEGIN {printf "%.6f", e*(1+t/100)}')
    OBSERVED_SLOWDOWN_RATIO=$(awk -v n="$NORMAL_AVERAGE" -v s="$SLOWDOWN_AVERAGE" 'BEGIN {printf "%.6f", s/n}')
    write_summary || return 1
    awk -v o="$OBSERVED_SLOWDOWN_RATIO" -v min="$MINIMUM_SLOWDOWN_RATIO" -v max="$MAXIMUM_SLOWDOWN_RATIO" \
        'BEGIN {exit !(o >= min && o <= max)}' || {
        fail "Observed ${OBSERVED_SLOWDOWN_RATIO}x; expected ${MINIMUM_SLOWDOWN_RATIO}x to ${MAXIMUM_SLOWDOWN_RATIO}x"
        return 1
    }
    pass "Observed slowdown: ${OBSERVED_SLOWDOWN_RATIO}x"
}

write_summary() {
    python3 - "$VERIFICATION_OUTPUT/summary.json" "$BENCHMARK" "$EXPECTED_SLOWDOWN" \
        "$OBSERVED_SLOWDOWN_RATIO" "$NORMAL_AVERAGE" "$SLOWDOWN_AVERAGE" \
        "$MINIMUM_SLOWDOWN_RATIO" "$MAXIMUM_SLOWDOWN_RATIO" <<'PY'
import json, pathlib, sys
path, benchmark, expected, achieved, normal, slowdown, minimum, maximum = sys.argv[1:]
data = {"benchmark": benchmark, "expected_slowdown_ratio": float(expected),
        "achieved_slowdown_ratio": float(achieved), "normal_average_us": int(normal),
        "slowdown_average_us": int(slowdown), "accepted_minimum_ratio": float(minimum),
        "accepted_maximum_ratio": float(maximum)}
pathlib.Path(path).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

main() {
    parse_arguments "$@"
    task "Verify Divine slowdown for $BENCHMARK"
    INDENT_LEVEL=$((INDENT_LEVEL + 1)); export INDENT_LEVEL
    run_step 'Load Divine verification configuration' load_configuration
    run_step 'Validate Divine verification inputs' validate_inputs
    run_step 'Run normal compiler replay' run_normal_replay
    run_step 'Run slowdown compiler replay' run_slowdown_replay
    run_step 'Verify slowdown ratio' verify_ratio
    report_check divine "$BENCHMARK slowdown verified" \
        "Expected ${EXPECTED_SLOWDOWN}x; achieved ${OBSERVED_SLOWDOWN_RATIO}x"
    INDENT_LEVEL=$((INDENT_LEVEL - 1)); export INDENT_LEVEL
    pass "Divine verification passed for $BENCHMARK"
}
main "$@"
