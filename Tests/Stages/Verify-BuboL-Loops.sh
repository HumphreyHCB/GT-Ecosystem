#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TESTS_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

# shellcheck source=../lib/common.sh
source "$TESTS_DIR/lib/common.sh"

if (( ${GT_COMMON_VERSION:-0} < 3 )); then
    die "Tests/lib/common.sh is out of date; version 3 or later is required"
fi

# shellcheck source=Graal-Options.sh
source "$SCRIPT_DIR/Graal-Options.sh"

CONFIG_FILE=${GT_ECOSYSTEM_CONFIG:-"$TESTS_DIR/config.config"}
REFRESH_INPUTS=false

BUBOL_OUTPUT_ROOT="$TESTS_DIR/Output/BuboL"
BUBOL_OUTPUT=''
VERIFICATION_OUTPUT=''
ANALYSIS_OUTPUT=''
COMPILER_REPLAY_DIRECTORY=''
SLOWDOWN_JSON=''
MARKER_PHASE_JSON=''
NORMAL_BUBOL_LOG=''
SLOWDOWN_BUBOL_LOG=''
CFG_LOG=''
VTUNE_REPORT=''

GRAAL_REPOSITORY=''
GRAAL_VM_HOME=''
SCHEDULER_REPOSITORY=''
JAVA_HOME_DIRECTORY=''
BENCHMARKS_JAR=''
BUBO_AGENT_JAR=''
SCHEDULER_CLASSPATH=''
SCHEDULER_BUILD_DIRECTORY="$TESTS_DIR/Build/GTSlowdownSchedular-LoopVerification"

readonly BENCHMARK=Mandelbrot
readonly ITERATIONS=300
readonly EXTRA_ARGUMENT=750
readonly SLOWDOWN_TEST_IDENTIFIER=AUTO_PIPELINE

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [--refresh-inputs]

Options:
        --refresh-inputs    Repeat the CFG run and SlowdownTest VTune runs
    -h, --help              Show this help

By default, completed CFG and VTune inputs inside the selected BuboL result
are reused. The final analysis is always repeated.

Environment overrides:
    GT_BUBOL_MIN_RUNTIME_SHARE       Default: 2 percent
    GT_BUBOL_MAX_MEDIAN_DIFFERENCE   Default: 25 percentage points
EOF
}

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --refresh-inputs)
                REFRESH_INPUTS=true
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                fail "Unknown argument: $1"
                show_usage >&2
                exit 2
                ;;
        esac
        shift
    done
}

load_configuration() {
    require_file "$CONFIG_FILE" 'Ecosystem configuration'
    require_config_value GRAAL_REPOSITORY "$CONFIG_FILE" Dir Graal
    require_config_value \
        SCHEDULER_REPOSITORY \
        "$CONFIG_FILE" \
        Dir \
        GTSlowdownSchedular
    require_config_value \
        JAVA_HOME_DIRECTORY \
        "$CONFIG_FILE" \
        Dir \
        FallbackJavaBuild
    require_config_value BENCHMARKS_JAR "$CONFIG_FILE" Dir AWFYBenchmarksJar

    GRAAL_VM_HOME="$GRAAL_REPOSITORY/vm/latest_graalvm_home"
    load_graal_options
}

is_complete_bubol_output() {
    local candidate=$1
    local replay_file

    [[ -d "$candidate" ]] || return 1
    [[ -s "$candidate/Final_$BENCHMARK.json" ]] || return 1
    [[ -s "$candidate/MarkerPhase_BuboIncluded.json" ]] || return 1
    [[ -d "$candidate/CompilerReplay" ]] || return 1

    replay_file=$(find "$candidate/CompilerReplay" -type f -print -quit)
    [[ -n "$replay_file" ]]
}

find_latest_bubol_output() {
    local candidate
    local candidate_name
    local candidate_timestamp
    local latest_result="$BUBOL_OUTPUT_ROOT/Latest-$BENCHMARK"

    require_directory "$BUBOL_OUTPUT_ROOT" 'BuboL output root'

    if [[ -e "$latest_result" ]]; then
        candidate=$(readlink -f -- "$latest_result" 2>/dev/null || true)
        [[ -n "$candidate" ]] || die "Cannot resolve latest BuboL result: $latest_result"
        BUBOL_OUTPUT=$candidate
        is_complete_bubol_output "$BUBOL_OUTPUT" || \
            die "Latest BuboL result is missing Final_$BENCHMARK.json, MarkerPhase_BuboIncluded.json, or CompilerReplay: $BUBOL_OUTPUT"
    fi

    if [[ -z "$BUBOL_OUTPUT" ]]; then
        while IFS= read -r candidate; do
            if is_complete_bubol_output "$candidate"; then
                BUBOL_OUTPUT=$candidate
                break
            fi
        done < <(
            while IFS= read -r candidate; do
                candidate_name=${candidate##*/}
                candidate_timestamp=${candidate_name: -19}

                if [[ "$candidate_timestamp" =~ ^[0-9]{4}(_[0-9]{2}){5}$ ]]; then
                    printf '%s\t%s\n' "$candidate_timestamp" "$candidate"
                fi
            done < <(
                find "$BUBOL_OUTPUT_ROOT" \
                    -mindepth 1 \
                    -maxdepth 1 \
                    -type d \
                    \( \
                        -name "BuboL_${BENCHMARK}_*" -o \
                        -name "${BENCHMARK}_*" \
                    \) \
                    -print
            ) | sort -r | cut -f2-
        )
    fi

    [[ -n "$BUBOL_OUTPUT" ]] || \
        die "No complete $BENCHMARK BuboL output with MarkerPhase_BuboIncluded.json was found in $BUBOL_OUTPUT_ROOT"

    ln -sfnT "$(basename -- "$BUBOL_OUTPUT")" "$latest_result"

    COMPILER_REPLAY_DIRECTORY="$BUBOL_OUTPUT/CompilerReplay"
    SLOWDOWN_JSON="$BUBOL_OUTPUT/Final_$BENCHMARK.json"
    MARKER_PHASE_JSON="$BUBOL_OUTPUT/MarkerPhase_BuboIncluded.json"
    VERIFICATION_OUTPUT="$BUBOL_OUTPUT/Verification"
    ANALYSIS_OUTPUT="$VERIFICATION_OUTPUT/Loop-Analysis"
    NORMAL_BUBOL_LOG="$VERIFICATION_OUTPUT/Normal-BuboL.log"
    SLOWDOWN_BUBOL_LOG="$VERIFICATION_OUTPUT/Slowdown-BuboL.log"
    CFG_LOG="$VERIFICATION_OUTPUT/CFG-BuboL.log"
    VTUNE_REPORT="$VERIFICATION_OUTPUT/VTune-Slowdown-Blocks.txt"

    task "Using BuboL Divine output: $BUBOL_OUTPUT"
}

find_bubo_agent() {
    local candidate
    local -a candidates=()

    while IFS= read -r candidate; do
        candidates+=("$candidate")
    done < <(
        find "$GRAAL_REPOSITORY/Bubo-Agent/target" \
            -maxdepth 1 \
            -type f \
            -name '*-jar-with-dependencies.jar' \
            -print 2>/dev/null | sort
    )

    if (( ${#candidates[@]} != 1 )); then
        die "Expected one Bubo agent jar in $GRAAL_REPOSITORY/Bubo-Agent/target, found ${#candidates[@]}"
    fi

    BUBO_AGENT_JAR=${candidates[0]}
}

validate_inputs() {
    local need_cfg_input=false
    local need_vtune_input=false
    local replay_file

    require_file "$NORMAL_BUBOL_LOG" 'Normal BuboL verification log'
    require_file "$SLOWDOWN_BUBOL_LOG" 'Slowdown BuboL verification log'
    require_file "$SLOWDOWN_JSON" 'Final BuboL slowdown JSON'
    require_file "$MARKER_PHASE_JSON" 'BuboL marker phase JSON'
    require_directory "$COMPILER_REPLAY_DIRECTORY" 'BuboL CompilerReplay input'
    require_executable "$TESTS_DIR/Analysis/Verify-BuboL-Loop-Accuracy.py" 'BuboL loop analyser'

    [[ -s "$NORMAL_BUBOL_LOG" ]] || die "Normal BuboL log is empty: $NORMAL_BUBOL_LOG"
    [[ -s "$SLOWDOWN_BUBOL_LOG" ]] || die "Slowdown BuboL log is empty: $SLOWDOWN_BUBOL_LOG"
    [[ -s "$SLOWDOWN_JSON" ]] || die "Final BuboL slowdown JSON is empty: $SLOWDOWN_JSON"
    [[ -s "$MARKER_PHASE_JSON" ]] || die "BuboL marker phase JSON is empty: $MARKER_PHASE_JSON"

    replay_file=$(find "$COMPILER_REPLAY_DIRECTORY" -type f -print -quit)
    [[ -n "$replay_file" ]] || \
        die "BuboL CompilerReplay directory contains no files: $COMPILER_REPLAY_DIRECTORY"

    if [[ "$REFRESH_INPUTS" == true || ! -s "$CFG_LOG" ]]; then
        need_cfg_input=true
    fi
    if [[ "$REFRESH_INPUTS" == true || ! -s "$VTUNE_REPORT" ]]; then
        need_vtune_input=true
    fi

    if [[ "$need_cfg_input" == true ]]; then
        require_executable "$GRAAL_VM_HOME/bin/java" 'Latest GraalVM java'
        require_file "$BENCHMARKS_JAR" 'Are We Fast Yet benchmarks JAR'
        find_bubo_agent
    fi

    if [[ "$need_vtune_input" == true ]]; then
        require_executable "$JAVA_HOME_DIRECTORY/bin/java" 'Scheduler java'
        require_executable "$JAVA_HOME_DIRECTORY/bin/javac" 'Scheduler javac'
        require_directory "$SCHEDULER_REPOSITORY" 'GT slowdown scheduler repository'
        require_file "$SCHEDULER_REPOSITORY/Tests/SlowdownTest.java" 'SlowdownTest source'
    fi

    mkdir -p "$VERIFICATION_OUTPUT" "$ANALYSIS_OUTPUT" || return 1
    load_bubol_verification_options \
        "$COMPILER_REPLAY_DIRECTORY" \
        "$SLOWDOWN_JSON"
}

run_command_with_log() {
    local output_file=$1
    local -a pipeline_status

    shift

    "$@" 2>&1 | tee "$output_file"
    pipeline_status=("${PIPESTATUS[@]}")

    (( pipeline_status[0] == 0 )) || return "${pipeline_status[0]}"
    return "${pipeline_status[1]}"
}

run_cfg_benchmark() {
    if [[ "$REFRESH_INPUTS" == false && -s "$CFG_LOG" ]]; then
        task "Reuse CFG input: $CFG_LOG"
        return 0
    fi

    run_command_with_log \
        "$CFG_LOG" \
        "$GRAAL_VM_HOME/bin/java" \
        "${GT_GRAAL_OPTIONS[@]}" \
        "${BUBOL_REPLAY_OPTIONS[@]}" \
        -Djdk.graal.HumphreysDebugData=true \
        "${BUBOL_NORMAL_OPTIONS[@]}" \
        "-javaagent:$BUBO_AGENT_JAR" \
        -cp "$BENCHMARKS_JAR" \
        Harness \
        "$BENCHMARK" \
        "$ITERATIONS" \
        "$EXTRA_ARGUMENT" || return 1

    grep -q '^=== HumphreysDebugDataPhase ===' "$CFG_LOG" || \
        die "CFG run produced no HumphreysDebugDataPhase sections: $CFG_LOG"
}

build_scheduler_classpath() {
    local jar_file

    SCHEDULER_CLASSPATH="$SCHEDULER_BUILD_DIRECTORY"

    while IFS= read -r jar_file; do
        SCHEDULER_CLASSPATH+=":$jar_file"
    done < <(find "$SCHEDULER_REPOSITORY" -type f -name '*.jar' -print | sort)
}

compile_slowdown_test() {
    mkdir -p "$SCHEDULER_BUILD_DIRECTORY" || return 1
    find "$SCHEDULER_BUILD_DIRECTORY" -mindepth 1 -delete || return 1

    build_scheduler_classpath || return 1

    "$JAVA_HOME_DIRECTORY/bin/javac" \
        -cp "$SCHEDULER_CLASSPATH" \
        -sourcepath "$SCHEDULER_REPOSITORY" \
        -d "$SCHEDULER_BUILD_DIRECTORY" \
        "$SCHEDULER_REPOSITORY/Tests/SlowdownTest.java"
}

prepare_slowdown_test_input() {
    local benchmark_input="$VERIFICATION_OUTPUT/SlowdownTestInput/$BENCHMARK"

    mkdir -p "$benchmark_input" || return 1

    ln -sfnT \
        "$SLOWDOWN_JSON" \
        "$benchmark_input/Final_$BENCHMARK.json" || return 1
    ln -sfnT \
        "$COMPILER_REPLAY_DIRECTORY" \
        "$benchmark_input/${BENCHMARK}_CompilerReplay"
}

run_slowdown_test() {
    local result_directory="$SCHEDULER_REPOSITORY/Tests/TestResults"
    local input_parent="$VERIFICATION_OUTPUT/SlowdownTestInput"
    local start_marker="$VERIFICATION_OUTPUT/.SlowdownTest-start"
    local newest_result
    local -a pipeline_status

    if [[ "$REFRESH_INPUTS" == false && -s "$VTUNE_REPORT" ]]; then
        task "Reuse VTune input: $VTUNE_REPORT"
        return 0
    fi

    compile_slowdown_test || return 1
    prepare_slowdown_test_input || return 1
    mkdir -p "$result_directory" || return 1
    touch "$start_marker" || return 1

    (
        cd "$SCHEDULER_REPOSITORY"
        "$JAVA_HOME_DIRECTORY/bin/java" \
            -cp "$SCHEDULER_CLASSPATH" \
            Tests.SlowdownTest \
            "$input_parent" \
            "$BENCHMARK" \
            "$ITERATIONS" \
            true
    ) 2>&1 | tee "$VERIFICATION_OUTPUT/SlowdownTest.log"

    pipeline_status=("${PIPESTATUS[@]}")
    (( pipeline_status[0] == 0 )) || return "${pipeline_status[0]}"
    (( pipeline_status[1] == 0 )) || return "${pipeline_status[1]}"

    newest_result=$(
        find "$result_directory" \
            -maxdepth 1 \
            -type f \
            -newer "$start_marker" \
            -name "*_${BENCHMARK}_SlowdownTest_${SLOWDOWN_TEST_IDENTIFIER}.txt" \
            -printf '%T@\t%p\n' \
            | sort -rn \
            | sed -n '1p' \
            | cut -f2-
    )

    [[ -n "$newest_result" ]] || \
        die "SlowdownTest produced no new $BENCHMARK result in $result_directory"
    [[ -s "$newest_result" ]] || die "SlowdownTest result is empty: $newest_result"

    cp -- "$newest_result" "$VTUNE_REPORT" || return 1
    pass "Copied SlowdownTest report: $VTUNE_REPORT"
}

analyse_loop_accuracy() {
    local min_runtime_share=${GT_BUBOL_MIN_RUNTIME_SHARE:-2}
    local max_median_difference=${GT_BUBOL_MAX_MEDIAN_DIFFERENCE:-25}

    "$TESTS_DIR/Analysis/Verify-BuboL-Loop-Accuracy.py" \
        --benchmark "$BENCHMARK" \
        --cfg-log "$CFG_LOG" \
        --vtune-report "$VTUNE_REPORT" \
        --bridge-json "$SLOWDOWN_JSON" \
        --markerphase-json "$MARKER_PHASE_JSON" \
        --normal-bubol-log "$NORMAL_BUBOL_LOG" \
        --slowdown-bubol-log "$SLOWDOWN_BUBOL_LOG" \
        --output-dir "$ANALYSIS_OUTPUT" \
        --min-runtime-share "$min_runtime_share" \
        --max-median-difference "$max_median_difference"
}

record_loop_accuracy_report() {
    local comparison_csv="$ANALYSIS_OUTPUT/BuboL-VTune-Loop-Comparison.csv"
    local max_median_difference=${GT_BUBOL_MAX_MEDIAN_DIFFERENCE:-25}
    local qualifying_count
    local median_difference
    local maximum_difference
    local middle
    local -a differences=()

    mapfile -t differences < <(
        awk -F',' '
            NR == 1 {
                for (column = 1; column <= NF; column++) {
                    if ($column == "qualifies") {
                        qualifies_column = column
                    }
                    if ($column == "absolute_difference_pct_points") {
                        difference_column = column
                    }
                }
                next
            }

            qualifies_column > 0 &&
            difference_column > 0 &&
            $qualifies_column == "true" &&
            $difference_column ~ /^[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$/ {
                print $difference_column
            }
        ' "$comparison_csv" | sort -n
    )

    qualifying_count=${#differences[@]}

    if (( qualifying_count == 0 )); then
        report_check \
            bubol \
            'BuboL per-loop accuracy verified against VTune' \
            "Comparison: $comparison_csv; marker data: $MARKER_PHASE_JSON"
        return 0
    fi

    maximum_difference=$(
        awk \
            -v value="${differences[qualifying_count - 1]}" \
            'BEGIN { printf "%.3f", value }'
    )
    middle=$((qualifying_count / 2))

    if (( qualifying_count % 2 == 1 )); then
        median_difference=$(
            awk \
                -v value="${differences[middle]}" \
                'BEGIN { printf "%.3f", value }'
        )
    else
        median_difference=$(
            awk \
                -v lower="${differences[middle - 1]}" \
                -v upper="${differences[middle]}" \
                'BEGIN { printf "%.3f", (lower + upper) / 2 }'
        )
    fi

    report_check \
        bubol \
        'BuboL per-loop accuracy verified against VTune' \
        "$qualifying_count qualifying loops; median difference ${median_difference}pp; maximum ${maximum_difference}pp; accepted median at most ${max_median_difference}pp; marker data: $MARKER_PHASE_JSON"
}

main() {
    parse_arguments "$@"

    task "Verify BuboL per-loop accuracy for $BENCHMARK"
    INDENT_LEVEL=$((INDENT_LEVEL + 1))
    export INDENT_LEVEL

    run_step 'Load BuboL loop configuration' load_configuration
    run_step 'Find latest complete BuboL Divine output' find_latest_bubol_output
    run_step 'Validate BuboL loop inputs' validate_inputs

    report_check \
        bubol \
        'BuboL marker phase data verified' \
        "$MARKER_PHASE_JSON"

    run_step 'Produce BuboL CFG input' run_cfg_benchmark
    run_step 'Produce VTune block slowdown input' run_slowdown_test
    run_step 'Compare BuboL loop measurements with VTune' analyse_loop_accuracy
    record_loop_accuracy_report

    INDENT_LEVEL=$((INDENT_LEVEL - 1))
    export INDENT_LEVEL
    pass "BuboL per-loop accuracy passed: $ANALYSIS_OUTPUT/BuboL-VTune-Loop-Comparison.csv"
}

main "$@"
