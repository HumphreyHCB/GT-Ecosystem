#!/usr/bin/env bash

# Full four-stage ecosystem test:
#   1. Compile OpenJDK with compiler markers.
#   2. Build Graal with the GT modifications.
#   3. Divine a normal program and verify the requested slowdown.
#   4. Divine with BuboL and verify its loop measurements and slowdown.

set -Eeuo pipefail

# Resolve every internal path from this file.
# This works whether the caller is inside or outside Tests/.
TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/common.sh
source "$TESTS_DIR/lib/common.sh"

if (( ${GT_COMMON_VERSION:-0} < 3 )); then
    die "Tests/lib/common.sh is out of date; version 3 or later is required"
fi

FULL_REBUILD=false
TEST_ONLY=false
SKIP_DIVINING=false
SKIP_BUBOL_DIVINING=false
REFRESH_BUBOL_LOOP_INPUTS=false
VERBOSE=false

STAGE_LIST=''
START_STAGE=''

PIPELINE_STAGES=(
    openjdk
    graal
    divine
    bubol
)

SELECTED_STAGES=()

REPORT_DIRECTORY=''
REPORT_RUN_ID=''
REPORT_JSON=''
REPORT_STARTED_AT=''
REPORT_STARTED_EPOCH=0
CURRENT_STAGE=''
CURRENT_STAGE_STARTED_EPOCH=0

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
    -v, --verbose
        Show the existing detailed output while the pipeline runs

    -f, --full-rebuild
        Clean every selected build before rebuilding it

    --test-only
        Test an existing GraalVM without rebuilding Graal

    --skip-divining
        Skip normal Divine generation and verify the newest Divine output

    --skip-bubol-divining
        Skip BuboL Divine generation and verify the newest BuboL output

    --refresh-bubol-loop-inputs
        Repeat the BuboL CFG run and SlowdownTest VTune runs

    -s, --stages LIST
        Run only a comma-separated list of stages

    --from STAGE
        Run STAGE and every later stage

    -h, --help
        Show this help

Stages:
    openjdk
    graal
    divine
    bubol

Examples:
    $(basename "$0")

    $(basename "$0") --stages openjdk
    $(basename "$0") --stages graal
    $(basename "$0") --stages divine
    $(basename "$0") --stages bubol

    $(basename "$0") --stages openjdk,graal
    $(basename "$0") --from graal
    $(basename "$0") --verbose --from graal

    $(basename "$0") --full-rebuild --stages graal
    $(basename "$0") --stages graal --test-only

    $(basename "$0") --stages divine --skip-divining
    $(basename "$0") --stages bubol --skip-bubol-divining
    $(basename "$0") --stages bubol --skip-bubol-divining --refresh-bubol-loop-inputs
EOF
}

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            -v|--verbose)
                VERBOSE=true
                ;;

            -f|--full-rebuild)
                FULL_REBUILD=true
                ;;

            --test-only)
                TEST_ONLY=true
                ;;

            --skip-divining)
                SKIP_DIVINING=true
                ;;

            --skip-bubol-divining)
                SKIP_BUBOL_DIVINING=true
                ;;

            --refresh-bubol-loop-inputs)
                REFRESH_BUBOL_LOOP_INPUTS=true
                ;;

            -s|--stages)
                (( $# >= 2 )) || \
                    die "$1 requires a comma-separated stage list"

                [[ -n "$2" ]] || \
                    die "$1 requires a non-empty stage list"

                STAGE_LIST=$2
                shift
                ;;

            --stages=*)
                STAGE_LIST=${1#*=}

                [[ -n "$STAGE_LIST" ]] || \
                    die '--stages requires a non-empty stage list'
                ;;

            --from)
                (( $# >= 2 )) || \
                    die "$1 requires a stage name"

                [[ -n "$2" ]] || \
                    die "$1 requires a stage name"

                START_STAGE=$2
                shift
                ;;

            --from=*)
                START_STAGE=${1#*=}

                [[ -n "$START_STAGE" ]] || \
                    die '--from requires a stage name'
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

initialise_reporting() {
    local timestamp

    timestamp=$(date '+%Y_%m_%d_%H_%M_%S')
    REPORT_RUN_ID="GT-Ecosystem_${timestamp}_$$"
    REPORT_DIRECTORY=${GT_REPORT_DIRECTORY:-"$TESTS_DIR/Output/Reports"}
    REPORT_JSON="$REPORT_DIRECTORY/$REPORT_RUN_ID.json"
    GT_DETAILED_LOG="$REPORT_DIRECTORY/$REPORT_RUN_ID.log"
    GT_REPORT_EVENTS="$REPORT_DIRECTORY/.$REPORT_RUN_ID.events"
    REPORT_STARTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    REPORT_STARTED_EPOCH=$(date +%s)

    GT_VERBOSE=$VERBOSE

    mkdir -p "$REPORT_DIRECTORY"
    : > "$GT_DETAILED_LOG"
    : > "$GT_REPORT_EVENTS"

    export GT_VERBOSE GT_DETAILED_LOG GT_REPORT_EVENTS

    printf 'GT Ecosystem pipeline started. Detailed output: %s\n' \
        "$GT_DETAILED_LOG" \
        >> "$GT_DETAILED_LOG"

    if [[ "$VERBOSE" == false ]]; then
        printf 'Running GT ecosystem stages: %s\n' "${SELECTED_STAGES[*]}"
    fi
}

finalise_reporting() {
    local exit_code=$1
    local finished_at
    local finished_epoch
    local duration_seconds
    local pipeline_status=passed
    local -a report_arguments=()
    local stage

    trap - EXIT
    set +e

    finished_epoch=$(date +%s)
    finished_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    duration_seconds=$((finished_epoch - REPORT_STARTED_EPOCH))

    if (( exit_code != 0 )); then
        pipeline_status=failed

        if [[ -n "$CURRENT_STAGE" ]]; then
            report_stage \
                "$CURRENT_STAGE" \
                failed \
                "$((finished_epoch - CURRENT_STAGE_STARTED_EPOCH))" \
                "Stage exited with code $exit_code"
        fi
    fi

    for stage in "${SELECTED_STAGES[@]}"; do
        report_arguments+=(--stage "$stage")
    done

    if [[ "$VERBOSE" == true ]]; then
        report_arguments+=(--verbose)
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 "$TESTS_DIR/lib/render-report.py" \
            --events "$GT_REPORT_EVENTS" \
            --output "$REPORT_JSON" \
            --started-at "$REPORT_STARTED_AT" \
            --finished-at "$finished_at" \
            --duration-seconds "$duration_seconds" \
            --status "$pipeline_status" \
            --detailed-log "$GT_DETAILED_LOG" \
            "${report_arguments[@]}"
    else
        printf '\n%s GT ecosystem pipeline %s\n' \
            "$([[ "$pipeline_status" == passed ]] && printf '✔' || printf '✘')" \
            "$pipeline_status"
        printf 'Detailed log: %s\n' "$GT_DETAILED_LOG"
        printf 'JSON report was not written because python3 is unavailable.\n' >&2
    fi

    if (( exit_code != 0 )) && [[ "$VERBOSE" == false ]]; then
        printf '\nLast 20 lines from the failed run:\n' >&2
        tail -n 20 "$GT_DETAILED_LOG" | sed 's/^/  /' >&2
    fi

    rm -f -- "$GT_REPORT_EVENTS"
    exit "$exit_code"
}

stage_exists() {
    local wanted_stage=$1
    local stage

    for stage in "${PIPELINE_STAGES[@]}"; do
        if [[ "$stage" == "$wanted_stage" ]]; then
            return 0
        fi
    done

    return 1
}

select_stages() {
    local -a requested_stages=()
    local requested_stage
    local pipeline_stage
    local include_stage=false

    if [[ -n "$STAGE_LIST" && -n "$START_STAGE" ]]; then
        die '--stages and --from cannot be used together'
    fi

    if [[ -n "$STAGE_LIST" ]]; then
        IFS=',' read -r -a requested_stages <<< "$STAGE_LIST"

        for requested_stage in "${requested_stages[@]}"; do
            stage_exists "$requested_stage" || \
                die "Unknown or unavailable stage: $requested_stage"
        done

        # Always execute selected stages in pipeline order.
        for pipeline_stage in "${PIPELINE_STAGES[@]}"; do
            for requested_stage in "${requested_stages[@]}"; do
                if [[ "$pipeline_stage" == "$requested_stage" ]]; then
                    SELECTED_STAGES+=("$pipeline_stage")
                    break
                fi
            done
        done

        return 0
    fi

    if [[ -n "$START_STAGE" ]]; then
        stage_exists "$START_STAGE" || \
            die "Unknown or unavailable stage: $START_STAGE"

        for pipeline_stage in "${PIPELINE_STAGES[@]}"; do
            if [[ "$pipeline_stage" == "$START_STAGE" ]]; then
                include_stage=true
            fi

            if [[ "$include_stage" == true ]]; then
                SELECTED_STAGES+=("$pipeline_stage")
            fi
        done

        return 0
    fi

    SELECTED_STAGES=("${PIPELINE_STAGES[@]}")
}

validate_arguments() {
    local stage
    local divine_selected=false
    local bubol_selected=false

    if [[ "$TEST_ONLY" == true && "$FULL_REBUILD" == true ]]; then
        die '--test-only cannot be combined with --full-rebuild'
    fi

    if [[ "$TEST_ONLY" == true ]]; then
        for stage in "${SELECTED_STAGES[@]}"; do
            if [[ "$stage" != graal ]]; then
                die '--test-only can only be used when the selected stage is graal'
            fi
        done
    fi

    if [[ "$SKIP_DIVINING" == true ]]; then
        for stage in "${SELECTED_STAGES[@]}"; do
            if [[ "$stage" == divine ]]; then
                divine_selected=true
            fi
        done

        if [[ "$divine_selected" != true ]]; then
            die '--skip-divining requires the divine stage to be selected'
        fi
    fi

    if [[ "$SKIP_BUBOL_DIVINING" == true ]]; then
        for stage in "${SELECTED_STAGES[@]}"; do
            if [[ "$stage" == bubol ]]; then
                bubol_selected=true
            fi
        done

        if [[ "$bubol_selected" != true ]]; then
            die '--skip-bubol-divining requires the bubol stage to be selected'
        fi
    fi

    if [[ "$REFRESH_BUBOL_LOOP_INPUTS" == true ]]; then
        bubol_selected=false

        for stage in "${SELECTED_STAGES[@]}"; do
            if [[ "$stage" == bubol ]]; then
                bubol_selected=true
            fi
        done

        if [[ "$bubol_selected" != true ]]; then
            die '--refresh-bubol-loop-inputs requires the bubol stage to be selected'
        fi
    fi
}

compile_openjdk() {
    if [[ "$FULL_REBUILD" == true ]]; then
        run_step \
            'Clean OpenJDK' \
            "$TESTS_DIR/Stages/Clean-OpenJDK.sh"
    fi

    run_step \
        'Compile OpenJDK with compiler markers' \
        "$TESTS_DIR/Stages/Compile-OpenJDK.sh"
}

compile_graal() {
    local -a graal_arguments=()

    if [[ "$FULL_REBUILD" == true ]]; then
        run_step \
            'Clean Graal' \
            "$TESTS_DIR/Stages/Clean-Graal.sh"
    fi

    if [[ "$TEST_ONLY" == true ]]; then
        graal_arguments+=(--test-only)
    fi

    run_step \
        'Build and verify Graal' \
        "$TESTS_DIR/Stages/Compile-Graal.sh" \
        "${graal_arguments[@]}"
}

run_divine() {
    if [[ "$SKIP_DIVINING" == true ]]; then
        task \
            'Skip Divine generation because --skip-divining was requested'
    else
        run_step \
            'Divine a benchmark' \
            "$TESTS_DIR/Stages/Divine.sh"
    fi

    run_step \
        'Verify the divined slowdown' \
        "$TESTS_DIR/Stages/Verify-Divine.sh"
}

run_bubol() {
    local -a loop_verification_arguments=()

    if [[ "$SKIP_BUBOL_DIVINING" == true ]]; then
        task \
            'Skip BuboL Divine generation because --skip-bubol-divining was requested'
    else
        run_step \
            'Divine a benchmark with BuboL enabled' \
            "$TESTS_DIR/Stages/Divine.sh" \
            --bubol
    fi

    run_step \
        'Verify the BuboL-divined slowdown' \
        "$TESTS_DIR/Stages/Verify-BuboL.sh"

    if [[ "$REFRESH_BUBOL_LOOP_INPUTS" == true ]]; then
        loop_verification_arguments+=(--refresh-inputs)
    fi

    run_step \
        'Verify BuboL per-loop measurements against VTune' \
        "$TESTS_DIR/Stages/Verify-BuboL-Loops.sh" \
        "${loop_verification_arguments[@]}"
}

run_selected_stages() {
    local stage
    local stage_finished_epoch

    for stage in "${SELECTED_STAGES[@]}"; do
        CURRENT_STAGE=$stage
        CURRENT_STAGE_STARTED_EPOCH=$(date +%s)

        case "$stage" in
            openjdk)
                compile_openjdk
                ;;

            graal)
                compile_graal
                ;;

            divine)
                run_divine
                ;;

            bubol)
                run_bubol
                ;;
        esac

        stage_finished_epoch=$(date +%s)
        report_stage \
            "$stage" \
            passed \
            "$((stage_finished_epoch - CURRENT_STAGE_STARTED_EPOCH))"
        CURRENT_STAGE=''
    done
}

main() {
    parse_arguments "$@"
    select_stages
    validate_arguments
    initialise_reporting
    trap 'finalise_reporting $?' EXIT

    task "Start GT ecosystem stages: ${SELECTED_STAGES[*]}"

    INDENT_LEVEL=$((INDENT_LEVEL + 1))
    export INDENT_LEVEL

    run_selected_stages

    INDENT_LEVEL=$((INDENT_LEVEL - 1))
    export INDENT_LEVEL

    pass "Selected ecosystem stages passed: ${SELECTED_STAGES[*]}"
}

main "$@"
