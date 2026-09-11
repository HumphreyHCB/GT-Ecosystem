#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TESTS_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

# shellcheck source=../lib/common.sh
source "$TESTS_DIR/lib/common.sh"

if (( ${GT_COMMON_VERSION:-0} < 2 )); then
    die "Tests/lib/common.sh is out of date; version 2 or later is required"
fi

CONFIG_FILE=${GT_ECOSYSTEM_CONFIG:-"$TESTS_DIR/config.config"}

SCHEDULER_REPOSITORY=''
JAVA_HOME_DIRECTORY=''
BUILD_DIRECTORY="$TESTS_DIR/Build/GTSlowdownSchedular"

OUTPUT_ROOT=''
RUN_OUTPUT=''
SCHEDULER_CLASSPATH=''

ENABLE_BUBO_LIR_PHASE=false
DIVINE_MODE=Divine

readonly BENCHMARK=Mandelbrot
readonly ITERATIONS=300
readonly SLOWDOWN_AMOUNT=2

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [--bubol]

Options:
        --bubol    Enable BuboL throughout the Divine run
    -h, --help     Show this help
EOF
}

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --bubol)
                ENABLE_BUBO_LIR_PHASE=true
                DIVINE_MODE=BuboL
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

    OUTPUT_ROOT="$TESTS_DIR/Output/$DIVINE_MODE"
}

load_configuration() {
    require_file \
        "$CONFIG_FILE" \
        'Ecosystem configuration'

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
}

validate_inputs() {
    require_directory \
        "$SCHEDULER_REPOSITORY" \
        'GT slowdown scheduler repository'

    require_file \
        "$SCHEDULER_REPOSITORY/GodRunner.java" \
        'GodRunner source'

    require_executable \
        "$JAVA_HOME_DIRECTORY/bin/java" \
        'Scheduler java'

    require_executable \
        "$JAVA_HOME_DIRECTORY/bin/javac" \
        'Scheduler javac'
}

prepare_directories() {
    local timestamp

    timestamp=$(date '+%Y_%m_%d_%H_%M_%S')

    RUN_OUTPUT="$OUTPUT_ROOT/${DIVINE_MODE}_${BENCHMARK}_$timestamp"

    mkdir -p "$BUILD_DIRECTORY"

    find "$BUILD_DIRECTORY" \
        -mindepth 1 \
        -delete

    if [[ -e "$RUN_OUTPUT" ]]; then
        die "Divine output already exists: $RUN_OUTPUT"
    fi

    mkdir -p "$RUN_OUTPUT"
}

build_scheduler_classpath() {
    local jar_file

    SCHEDULER_CLASSPATH="$BUILD_DIRECTORY"

    while IFS= read -r jar_file; do
        SCHEDULER_CLASSPATH+=":$jar_file"
    done < <(
        find "$SCHEDULER_REPOSITORY" \
            -type f \
            -name '*.jar' \
            -print |
            sort
    )
}

compile_scheduler_entry_point() {
    "$JAVA_HOME_DIRECTORY/bin/javac" \
        -cp "$SCHEDULER_CLASSPATH" \
        -sourcepath "$SCHEDULER_REPOSITORY" \
        -d "$BUILD_DIRECTORY" \
        "$SCHEDULER_REPOSITORY/GodRunner.java"
}

run_scheduler() {
    local log_file="$RUN_OUTPUT/Divine.log"
    local java_status

    (
        cd "$SCHEDULER_REPOSITORY"

        "$JAVA_HOME_DIRECTORY/bin/java" \
            -cp "$SCHEDULER_CLASSPATH" \
            GodRunner \
            --ecosystem-divine \
            "$BENCHMARK" \
            "$ITERATIONS" \
            "$SLOWDOWN_AMOUNT" \
            "$ENABLE_BUBO_LIR_PHASE" \
            "$RUN_OUTPUT"
    ) 2>&1 | tee "$log_file"

    java_status=${PIPESTATUS[0]}

    return "$java_status"
}

verify_and_tidy_outputs() {
    local final_json="$RUN_OUTPUT/Final_$BENCHMARK.json"
    local marker_phase_json="$RUN_OUTPUT/MarkerPhase_BuboIncluded.json"
    local latest_result="$OUTPUT_ROOT/Latest-$BENCHMARK"
    local replay_directory
    local replay_file

    local -a replay_directories=()

    require_file \
        "$final_json" \
        "Final $BENCHMARK slowdown JSON"

    if [[ ! -s "$final_json" ]]; then
        die "Final slowdown JSON is empty: $final_json"
    fi

    if [[ "$ENABLE_BUBO_LIR_PHASE" == true ]]; then
        require_file \
            "$marker_phase_json" \
            'BuboL marker phase JSON'

        if [[ ! -s "$marker_phase_json" ]]; then
            die "BuboL marker phase JSON is empty: $marker_phase_json"
        fi
    fi

    while IFS= read -r replay_directory; do
        replay_directories+=("$replay_directory")
    done < <(
        find "$RUN_OUTPUT" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -name '*_CompilerReplay' \
            -print |
            sort
    )

    if (( ${#replay_directories[@]} != 1 )); then
        die "Expected one CompilerReplay directory in $RUN_OUTPUT, found ${#replay_directories[@]}"
    fi

    replay_directory=${replay_directories[0]}

    replay_file=$(
        find "$replay_directory" \
            -type f \
            -print \
            -quit
    )

    if [[ -z "$replay_file" ]]; then
        die "CompilerReplay directory contains no files: $replay_directory"
    fi

    mv \
        "$replay_directory" \
        "$RUN_OUTPUT/CompilerReplay"

    require_directory \
        "$RUN_OUTPUT/CompilerReplay" \
        'Tidied CompilerReplay output'

    # Only update this link after both required outputs have been verified.
    #
    # The link is relative, so the complete Output directory can be moved
    # without breaking it.
    ln -sfn \
        "$(basename -- "$RUN_OUTPUT")" \
        "$latest_result"

    pass "Final slowdown JSON: $final_json"

    if [[ "$ENABLE_BUBO_LIR_PHASE" == true ]]; then
        pass "BuboL marker phase JSON: $marker_phase_json"
    fi

    pass "Compiler replay: $RUN_OUTPUT/CompilerReplay"
    pass "Divine log: $RUN_OUTPUT/Divine.log"
    pass "Latest completed $DIVINE_MODE result: $latest_result"
}

main() {
    parse_arguments "$@"

    task "$DIVINE_MODE Divine $BENCHMARK with slowdown $SLOWDOWN_AMOUNT"

    INDENT_LEVEL=$((INDENT_LEVEL + 1))
    export INDENT_LEVEL

    run_step \
        'Load Divine configuration' \
        load_configuration

    run_step \
        'Validate Divine inputs' \
        validate_inputs

    run_step \
        'Prepare Divine output directories' \
        prepare_directories

    run_step \
        'Build scheduler classpath' \
        build_scheduler_classpath

    run_step \
        'Compile GodRunner ecosystem entry point' \
        compile_scheduler_entry_point

    run_step \
        "Divine $BENCHMARK" \
        run_scheduler

    run_step \
        'Verify and tidy Divine outputs' \
        verify_and_tidy_outputs

    INDENT_LEVEL=$((INDENT_LEVEL - 1))
    export INDENT_LEVEL

    pass "$DIVINE_MODE Divine stage passed: $RUN_OUTPUT"
}

main "$@"
