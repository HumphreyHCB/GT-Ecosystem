#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TESTS_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../lib/common.sh
source "$TESTS_DIR/lib/common.sh"
(( ${GT_COMMON_VERSION:-0} >= 4 )) || die 'common.sh version 4 or later is required'

CONFIG_FILE=${GT_ECOSYSTEM_CONFIG:-"$TESTS_DIR/config.config"}
BENCHMARK=''
ITERATIONS=''
EXTRA_ARGUMENT=''
EXPECTED_SLOWDOWN=''
SLOWDOWN_TOLERANCE_PERCENT=''
ENABLE_BUBO_LIR_PHASE=false
MODE=divine
SCHEDULER_REPOSITORY=''
JAVA_HOME_DIRECTORY=''
STAGE_ROOT=''
GENERATION_OUTPUT=''
WORK_DIRECTORY=''
BUILD_DIRECTORY=''
SCHEDULER_CLASSPATH=''

show_usage() { printf 'Usage: %s --benchmark NAME [--bubol]\n' "$(basename "$0")"; }

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --benchmark) (( $# >= 2 )) || die '--benchmark requires a name'; BENCHMARK=$2; shift ;;
            --benchmark=*) BENCHMARK=${1#*=} ;;
            --bubol) ENABLE_BUBO_LIR_PHASE=true; MODE=bubol ;;
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
    require_config_value SCHEDULER_REPOSITORY "$CONFIG_FILE" Dir GTSlowdownSchedular
    require_config_value JAVA_HOME_DIRECTORY "$CONFIG_FILE" Dir FallbackJavaBuild
    load_benchmark_configuration "$CONFIG_FILE" "$BENCHMARK" ITERATIONS EXTRA_ARGUMENT \
        EXPECTED_SLOWDOWN SLOWDOWN_TOLERANCE_PERCENT
    configure_scheduler_environment "$CONFIG_FILE"
    STAGE_ROOT="$GT_PIPELINE_ROOT/stages/$MODE/$BENCHMARK"
    GENERATION_OUTPUT="$STAGE_ROOT/generation"
    WORK_DIRECTORY="$STAGE_ROOT/work"
    BUILD_DIRECTORY="$GT_PIPELINE_ROOT/build/scheduler/$MODE/$BENCHMARK"
}

validate_inputs() {
    require_directory "$SCHEDULER_REPOSITORY" 'GT slowdown scheduler repository'
    require_file "$SCHEDULER_REPOSITORY/GodRunner.java" 'GodRunner source'
    require_executable "$JAVA_HOME_DIRECTORY/bin/java" 'Scheduler java'
    require_executable "$JAVA_HOME_DIRECTORY/bin/javac" 'Scheduler javac'
}

prepare_directories() {
    mkdir -p "$GENERATION_OUTPUT" "$WORK_DIRECTORY" "$BUILD_DIRECTORY"
    find "$GENERATION_OUTPUT" "$WORK_DIRECTORY" "$BUILD_DIRECTORY" -mindepth 1 -delete
}

build_scheduler_classpath() {
    local jar_file
    SCHEDULER_CLASSPATH=$BUILD_DIRECTORY
    while IFS= read -r jar_file; do SCHEDULER_CLASSPATH+=":$jar_file"; done < <(
        find "$SCHEDULER_REPOSITORY" -type f -name '*.jar' -print | sort
    )
}

compile_scheduler() {
    "$JAVA_HOME_DIRECTORY/bin/javac" -cp "$SCHEDULER_CLASSPATH" \
        -sourcepath "$SCHEDULER_REPOSITORY" -d "$BUILD_DIRECTORY" \
        "$SCHEDULER_REPOSITORY/GodRunner.java"
}

run_scheduler() {
    local java_status
    (
        cd "$WORK_DIRECTORY"
        "$JAVA_HOME_DIRECTORY/bin/java" -cp "$SCHEDULER_CLASSPATH" GodRunner \
            --ecosystem-divine "$BENCHMARK" "$ITERATIONS" "$EXPECTED_SLOWDOWN" \
            "$ENABLE_BUBO_LIR_PHASE" "$GENERATION_OUTPUT"
    ) 2>&1 | tee "$GENERATION_OUTPUT/Divine.log"
    java_status=${PIPESTATUS[0]}
    return "$java_status"
}

verify_outputs() {
    local replay_directory replay_file
    local -a replay_directories=()
    require_file "$GENERATION_OUTPUT/Final_$BENCHMARK.json" "Final $BENCHMARK slowdown JSON"
    [[ -s "$GENERATION_OUTPUT/Final_$BENCHMARK.json" ]] || die 'Final slowdown JSON is empty'
    if [[ "$ENABLE_BUBO_LIR_PHASE" == true ]]; then
        require_file "$GENERATION_OUTPUT/MarkerPhase_BuboIncluded.json" 'BuboL marker phase JSON'
        [[ -s "$GENERATION_OUTPUT/MarkerPhase_BuboIncluded.json" ]] || die 'Marker phase JSON is empty'
    fi
    mapfile -t replay_directories < <(
        find "$GENERATION_OUTPUT" -mindepth 1 -maxdepth 1 -type d -name '*_CompilerReplay' -print | sort
    )
    (( ${#replay_directories[@]} == 1 )) || die "Expected one CompilerReplay directory, found ${#replay_directories[@]}"
    replay_directory=${replay_directories[0]}
    replay_file=$(find "$replay_directory" -type f -print -quit)
    [[ -n "$replay_file" ]] || die "CompilerReplay is empty: $replay_directory"
    mv "$replay_directory" "$GENERATION_OUTPUT/CompilerReplay"
    pass "Generated $MODE data: $GENERATION_OUTPUT"
}

main() {
    parse_arguments "$@"
    task "Generate $MODE slowdown data for $BENCHMARK"
    INDENT_LEVEL=$((INDENT_LEVEL + 1)); export INDENT_LEVEL
    run_step 'Load generation configuration' load_configuration
    run_step 'Validate generation inputs' validate_inputs
    run_step 'Prepare isolated generation workspace' prepare_directories
    run_step 'Build scheduler classpath' build_scheduler_classpath
    run_step 'Compile GodRunner' compile_scheduler
    run_step "Divine $BENCHMARK" run_scheduler
    run_step 'Verify generated slowdown data' verify_outputs
    report_check "$MODE" "$BENCHMARK generation completed" "$GENERATION_OUTPUT"
    INDENT_LEVEL=$((INDENT_LEVEL - 1)); export INDENT_LEVEL
    pass "$MODE generation passed for $BENCHMARK"
}

main "$@"
