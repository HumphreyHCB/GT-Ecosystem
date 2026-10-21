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
MIN_RUNTIME_SHARE=''
MAX_MEDIAN_DIFFERENCE=''
GRAAL_REPOSITORY=''
GRAAL_VM_HOME=''
SCHEDULER_REPOSITORY=''
JAVA_HOME_DIRECTORY=''
BENCHMARKS_JAR=''
GENERATION_OUTPUT=''
VERIFICATION_OUTPUT=''
ANALYSIS_OUTPUT=''
WORK_DIRECTORY=''
SCHEDULER_BUILD_DIRECTORY=''
SCHEDULER_CLASSPATH=''
COMPILER_REPLAY_DIRECTORY=''
SLOWDOWN_JSON=''
MARKER_PHASE_JSON=''
NORMAL_BUBOL_LOG=''
SLOWDOWN_BUBOL_LOG=''
CFG_LOG=''
VTUNE_REPORT=''
readonly SLOWDOWN_TEST_IDENTIFIER=AUTO_PIPELINE

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
    require_config_value SCHEDULER_REPOSITORY "$CONFIG_FILE" Dir GTSlowdownSchedular
    require_config_value JAVA_HOME_DIRECTORY "$CONFIG_FILE" Dir FallbackJavaBuild
    require_config_value BENCHMARKS_JAR "$CONFIG_FILE" Dir AWFYBenchmarksJar
    load_benchmark_configuration "$CONFIG_FILE" "$BENCHMARK" ITERATIONS EXTRA_ARGUMENT \
        EXPECTED_SLOWDOWN SLOWDOWN_TOLERANCE_PERCENT
    MIN_RUNTIME_SHARE=$(config_get "$CONFIG_FILE" Run BuboLMinRuntimeSharePercent)
    MAX_MEDIAN_DIFFERENCE=$(config_get "$CONFIG_FILE" Run BuboLMaxMedianDifferencePoints)
    [[ "$MIN_RUNTIME_SHARE" =~ ^[0-9]+([.][0-9]+)?$ ]] || die '[Run] BuboLMinRuntimeSharePercent must be numeric'
    [[ "$MAX_MEDIAN_DIFFERENCE" =~ ^[0-9]+([.][0-9]+)?$ ]] || die '[Run] BuboLMaxMedianDifferencePoints must be numeric'

    GRAAL_VM_HOME="$GRAAL_REPOSITORY/vm/latest_graalvm_home"
    GENERATION_OUTPUT="$GT_PIPELINE_ROOT/stages/bubol/$BENCHMARK/generation"
    VERIFICATION_OUTPUT="$GT_PIPELINE_ROOT/stages/bubol/$BENCHMARK/verification"
    ANALYSIS_OUTPUT="$VERIFICATION_OUTPUT/loop-analysis"
    WORK_DIRECTORY="$GT_PIPELINE_ROOT/stages/bubol/$BENCHMARK/loop-work"
    SCHEDULER_BUILD_DIRECTORY="$GT_PIPELINE_ROOT/build/scheduler/bubol-loops/$BENCHMARK"
    COMPILER_REPLAY_DIRECTORY="$GENERATION_OUTPUT/CompilerReplay"
    SLOWDOWN_JSON="$GENERATION_OUTPUT/Final_$BENCHMARK.json"
    MARKER_PHASE_JSON="$GENERATION_OUTPUT/MarkerPhase_BuboIncluded.json"
    NORMAL_BUBOL_LOG="$VERIFICATION_OUTPUT/Normal-BuboL.log"
    SLOWDOWN_BUBOL_LOG="$VERIFICATION_OUTPUT/Slowdown-BuboL.log"
    CFG_LOG="$VERIFICATION_OUTPUT/CFG-BuboL.log"
    VTUNE_REPORT="$VERIFICATION_OUTPUT/VTune-Slowdown-Blocks.txt"
    configure_scheduler_environment "$CONFIG_FILE"
    load_graal_options
    load_bubol_verification_options "$COMPILER_REPLAY_DIRECTORY" "$SLOWDOWN_JSON"
}

validate_inputs() {
    local replay_file
    require_file "$NORMAL_BUBOL_LOG" 'Normal BuboL verification log'
    require_file "$SLOWDOWN_BUBOL_LOG" 'Slowdown BuboL verification log'
    require_file "$SLOWDOWN_JSON" 'Final BuboL slowdown JSON'
    require_file "$MARKER_PHASE_JSON" 'BuboL marker phase JSON'
    require_directory "$COMPILER_REPLAY_DIRECTORY" 'BuboL CompilerReplay input'
    require_executable "$TESTS_DIR/Analysis/Verify-BuboL-Loop-Accuracy.py" 'BuboL loop analyser'
    require_executable "$GRAAL_VM_HOME/bin/java" 'Latest GraalVM java'
    require_file "$BENCHMARKS_JAR" 'Are We Fast Yet benchmarks JAR'
    require_executable "$JAVA_HOME_DIRECTORY/bin/java" 'Scheduler java'
    require_executable "$JAVA_HOME_DIRECTORY/bin/javac" 'Scheduler javac'
    require_file "$SCHEDULER_REPOSITORY/Tests/SlowdownTest.java" 'SlowdownTest source'
    replay_file=$(find "$COMPILER_REPLAY_DIRECTORY" -type f -print -quit)
    [[ -n "$replay_file" ]] || die "CompilerReplay is empty: $COMPILER_REPLAY_DIRECTORY"
    mkdir -p "$ANALYSIS_OUTPUT" "$WORK_DIRECTORY" "$SCHEDULER_BUILD_DIRECTORY"
}

run_command_with_log() {
    local output=$1
    local -a statuses
    shift
    "$@" 2>&1 | tee "$output"
    statuses=("${PIPESTATUS[@]}")
    (( statuses[0] == 0 )) || return "${statuses[0]}"
    return "${statuses[1]}"
}

run_cfg_benchmark() {
    run_command_with_log "$CFG_LOG" "$GRAAL_VM_HOME/bin/java" \
        "${GT_GRAAL_OPTIONS[@]}" "${BUBOL_REPLAY_OPTIONS[@]}" \
        -Djdk.graal.HumphreysDebugData=true "${BUBOL_NORMAL_OPTIONS[@]}" \
        -cp "$BENCHMARKS_JAR" Harness "$BENCHMARK" "$ITERATIONS" "$EXTRA_ARGUMENT" || return 1
    grep -q '^=== HumphreysDebugDataPhase ===' "$CFG_LOG" || {
        fail "CFG run produced no HumphreysDebugDataPhase sections: $CFG_LOG"; return 1;
    }
}

build_scheduler_classpath() {
    local jar_file
    SCHEDULER_CLASSPATH=$SCHEDULER_BUILD_DIRECTORY
    while IFS= read -r jar_file; do SCHEDULER_CLASSPATH+=":$jar_file"; done < <(
        find "$SCHEDULER_REPOSITORY" -type f -name '*.jar' -print | sort
    )
}

compile_slowdown_test() {
    find "$SCHEDULER_BUILD_DIRECTORY" -mindepth 1 -delete
    build_scheduler_classpath
    "$JAVA_HOME_DIRECTORY/bin/javac" -cp "$SCHEDULER_CLASSPATH" \
        -sourcepath "$SCHEDULER_REPOSITORY" -d "$SCHEDULER_BUILD_DIRECTORY" \
        "$SCHEDULER_REPOSITORY/Tests/SlowdownTest.java"
}

prepare_slowdown_input() {
    local input="$VERIFICATION_OUTPUT/SlowdownTestInput/$BENCHMARK"
    mkdir -p "$input"
    ln -sfnT "$SLOWDOWN_JSON" "$input/Final_$BENCHMARK.json"
    ln -sfnT "$COMPILER_REPLAY_DIRECTORY" "$input/${BENCHMARK}_CompilerReplay"
}

run_slowdown_test() {
    local results="$WORK_DIRECTORY/Tests/TestResults"
    local input_parent="$VERIFICATION_OUTPUT/SlowdownTestInput"
    local marker="$WORK_DIRECTORY/.slowdown-test-start"
    local newest_result
    local -a statuses
    mkdir -p "$results"
    touch "$marker"
    (
        cd "$WORK_DIRECTORY"
        "$JAVA_HOME_DIRECTORY/bin/java" -cp "$SCHEDULER_CLASSPATH" Tests.SlowdownTest \
            "$input_parent" "$BENCHMARK" "$ITERATIONS" true
    ) 2>&1 | tee "$VERIFICATION_OUTPUT/SlowdownTest.log"
    statuses=("${PIPESTATUS[@]}")
    (( statuses[0] == 0 && statuses[1] == 0 )) || return 1
    newest_result=$(find "$results" -maxdepth 1 -type f -newer "$marker" \
        -name "*_${BENCHMARK}_SlowdownTest_${SLOWDOWN_TEST_IDENTIFIER}.txt" \
        -printf '%T@\t%p\n' | sort -rn | sed -n '1p' | cut -f2-)
    [[ -n "$newest_result" && -s "$newest_result" ]] || \
        die "SlowdownTest produced no $BENCHMARK result in $results"
    cp "$newest_result" "$VTUNE_REPORT"
}

analyse_loop_accuracy() {
    "$TESTS_DIR/Analysis/Verify-BuboL-Loop-Accuracy.py" \
        --benchmark "$BENCHMARK" --cfg-log "$CFG_LOG" --vtune-report "$VTUNE_REPORT" \
        --bridge-json "$SLOWDOWN_JSON" --markerphase-json "$MARKER_PHASE_JSON" \
        --normal-bubol-log "$NORMAL_BUBOL_LOG" --slowdown-bubol-log "$SLOWDOWN_BUBOL_LOG" \
        --output-dir "$ANALYSIS_OUTPUT" --min-runtime-share "$MIN_RUNTIME_SHARE" \
        --max-median-difference "$MAX_MEDIAN_DIFFERENCE"
}

record_report() {
    local csv="$ANALYSIS_OUTPUT/BuboL-VTune-Loop-Comparison.csv" qualifying
    require_file "$csv" 'BuboL loop comparison CSV'
    qualifying=$(awk -F, 'NR == 1 {for(i=1;i<=NF;i++) if($i=="qualifies") q=i; next} q && $q=="true" {n++} END {print n+0}' "$csv")
    report_check bubol "$BENCHMARK per-loop accuracy verified" \
        "$qualifying qualifying loops; comparison: $csv"
}

main() {
    parse_arguments "$@"
    task "Verify every BuboL loop for $BENCHMARK"
    INDENT_LEVEL=$((INDENT_LEVEL + 1)); export INDENT_LEVEL
    run_step 'Load BuboL loop configuration' load_configuration
    run_step 'Validate BuboL loop inputs' validate_inputs
    run_step 'Produce BuboL CFG input' run_cfg_benchmark
    run_step 'Compile scheduler SlowdownTest' compile_slowdown_test
    run_step 'Prepare isolated SlowdownTest input' prepare_slowdown_input
    run_step 'Produce VTune block slowdown input' run_slowdown_test
    run_step 'Compare every BuboL loop with VTune' analyse_loop_accuracy
    record_report
    INDENT_LEVEL=$((INDENT_LEVEL - 1)); export INDENT_LEVEL
    pass "BuboL loop verification passed for $BENCHMARK"
}
main "$@"
