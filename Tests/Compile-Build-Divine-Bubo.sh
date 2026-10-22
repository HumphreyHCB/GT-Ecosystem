#!/usr/bin/env bash

# Build and verify the GT ecosystem in one isolated, timestamped run.

set -Eeuo pipefail
TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$TESTS_DIR/lib/common.sh"
(( ${GT_COMMON_VERSION:-0} >= 4 )) || die 'common.sh version 4 or later is required'

CONFIG_FILE="$TESTS_DIR/config.config"
FULL_REBUILD=false
TEST_ONLY=false
VERBOSE=false
USE_DENOISE=''
DENOISE_REQUIRED=false
STAGE_LIST=''
START_STAGE=''
PIPELINE_STAGES=(openjdk graal divine bubol)
SELECTED_STAGES=()
BENCHMARKS=()
REPORT_STARTED_AT=''
REPORT_STARTED_EPOCH=0
CURRENT_STAGE=''
CURRENT_STAGE_STARTED_EPOCH=0

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
    -c, --config FILE       Use a different ecosystem configuration
    -v, --verbose           Stream detailed command output
    -f, --full-rebuild      Clean selected compiler builds first
        --test-only         Test an existing GraalVM; requires --stages graal
        --without-denoise   Do not tune the CPU around measurement stages
    -s, --stages LIST       Run a comma-separated subset in pipeline order
        --from STAGE        Run STAGE and every later stage
    -h, --help              Show this help

Stages: openjdk, graal, divine, bubol

The [Run] Benchmarks list controls every Divine and BuboL benchmark.
Every invocation creates a new Runs/<timestamp>/ directory.
EOF
}

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            -c|--config) (( $# >= 2 )) || die "$1 requires a file"; CONFIG_FILE=$2; shift ;;
            --config=*) CONFIG_FILE=${1#*=} ;;
            -v|--verbose) VERBOSE=true ;;
            -f|--full-rebuild) FULL_REBUILD=true ;;
            --test-only) TEST_ONLY=true ;;
            --without-denoise) USE_DENOISE=false ;;
            -s|--stages) (( $# >= 2 )) || die "$1 requires a stage list"; STAGE_LIST=$2; shift ;;
            --stages=*) STAGE_LIST=${1#*=} ;;
            --from) (( $# >= 2 )) || die "$1 requires a stage"; START_STAGE=$2; shift ;;
            --from=*) START_STAGE=${1#*=} ;;
            -h|--help) show_usage; exit 0 ;;
            *) fail "Unknown argument: $1"; show_usage >&2; exit 2 ;;
        esac
        shift
    done
    CONFIG_FILE=$(realpath -m -- "$CONFIG_FILE")
}

validate_invocation_user() {
    if (( EUID == 0 )); then
        fail 'Do not run the GT ecosystem pipeline with sudo or as root.'
        fail 'Run it as your normal user; Setup-Denoise.sh requests sudo only when CPU controls require it.'
        if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
            fail "Re-run as $SUDO_USER: ./Tests/Compile-Build-Divine-Bubo.sh ${*:-}"
        fi
        return 1
    fi
}

authorize_unattended_pipeline() {
    [[ "$DENOISE_REQUIRED" == true ]] || return 0
    task 'Authorize unattended Denoise controls'
    "$TESTS_DIR/Setup-Denoise.sh" authorize
}

stage_exists() {
    local wanted=$1 stage
    for stage in "${PIPELINE_STAGES[@]}"; do
        [[ "$stage" == "$wanted" ]] && return 0
    done
    return 1
}

select_stages() {
    local requested stage include=false
    local -a requested_stages=()
    [[ -z "$STAGE_LIST" || -z "$START_STAGE" ]] || die '--stages and --from cannot be used together'

    if [[ -n "$STAGE_LIST" ]]; then
        IFS=',' read -r -a requested_stages <<< "$STAGE_LIST"
        for requested in "${requested_stages[@]}"; do
            stage_exists "$requested" || die "Unknown stage: $requested"
        done
        for stage in "${PIPELINE_STAGES[@]}"; do
            for requested in "${requested_stages[@]}"; do
                [[ "$stage" == "$requested" ]] && SELECTED_STAGES+=("$stage")
            done
        done
    elif [[ -n "$START_STAGE" ]]; then
        stage_exists "$START_STAGE" || die "Unknown stage: $START_STAGE"
        for stage in "${PIPELINE_STAGES[@]}"; do
            [[ "$stage" == "$START_STAGE" ]] && include=true
            [[ "$include" == true ]] && SELECTED_STAGES+=("$stage")
        done
    else
        SELECTED_STAGES=("${PIPELINE_STAGES[@]}")
    fi
    (( ${#SELECTED_STAGES[@]} > 0 )) || die 'No stages selected'
}

validate_arguments() {
    local configured_denoise stage

    [[ "$TEST_ONLY" != true || "$FULL_REBUILD" != true ]] || die '--test-only cannot be combined with --full-rebuild'
    if [[ "$TEST_ONLY" == true ]]; then
        (( ${#SELECTED_STAGES[@]} == 1 )) && [[ "${SELECTED_STAGES[0]}" == graal ]] || \
            die '--test-only requires --stages graal'
    fi

    if [[ -z "$USE_DENOISE" ]]; then
        configured_denoise=$(config_get "$CONFIG_FILE" Run Denoise)
        case "${configured_denoise,,}" in
            true|yes|1) USE_DENOISE=true ;;
            false|no|0) USE_DENOISE=false ;;
            *) die '[Run] Denoise must be true or false' ;;
        esac
    fi

    DENOISE_REQUIRED=false
    if [[ "$USE_DENOISE" == true ]]; then
        for stage in "${SELECTED_STAGES[@]}"; do
            case "$stage" in
                graal|divine|bubol)
                    DENOISE_REQUIRED=true
                    break
                    ;;
            esac
        done
    fi
}

initialise_run() {
    local configured_run_root timestamp
    require_file "$CONFIG_FILE" 'Ecosystem configuration'
    require_config_value configured_run_root "$CONFIG_FILE" Dir RunRoot
    load_configured_benchmarks BENCHMARKS "$CONFIG_FILE"

    timestamp=$(date '+%Y_%m_%d_%H_%M_%S')
    GT_RUN_ROOT="$configured_run_root/${timestamp}_$$"
    GT_PIPELINE_ROOT="$GT_RUN_ROOT/pipeline"
    GT_RESULTS_ROOT="$GT_RUN_ROOT/results"
    GT_DETAILED_LOG="$GT_PIPELINE_ROOT/logs/pipeline.log"
    GT_REPORT_EVENTS="$GT_PIPELINE_ROOT/report.events"
    GT_ECOSYSTEM_CONFIG=$CONFIG_FILE
    GT_VERBOSE=$VERBOSE
    GT_USE_DENOISE=$USE_DENOISE

    mkdir -p "$GT_PIPELINE_ROOT/logs" "$GT_PIPELINE_ROOT/stages" "$GT_PIPELINE_ROOT/build" "$GT_RESULTS_ROOT"
    : > "$GT_DETAILED_LOG"
    : > "$GT_REPORT_EVENTS"
    REPORT_STARTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    REPORT_STARTED_EPOCH=$(date +%s)
    export GT_RUN_ROOT GT_PIPELINE_ROOT GT_RESULTS_ROOT GT_DETAILED_LOG
    export GT_REPORT_EVENTS GT_ECOSYSTEM_CONFIG GT_VERBOSE GT_USE_DENOISE

    printf 'GT Ecosystem run: %s\nConfiguration: %s\nBenchmarks: %s\nDenoise: %s\n' \
        "$GT_RUN_ROOT" "$CONFIG_FILE" "${BENCHMARKS[*]}" "$USE_DENOISE" >> "$GT_DETAILED_LOG"
    printf 'Run directory: %s\nBenchmarks: %s\nDenoise: %s\n' \
        "$GT_RUN_ROOT" "${BENCHMARKS[*]}" "$USE_DENOISE"
}

finalise_run() {
    local exit_code=$1 finished_at finished_epoch duration status=passed render_status stage
    local -a args=()
    trap - EXIT
    set +e
    finished_epoch=$(date +%s)
    finished_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    duration=$((finished_epoch - REPORT_STARTED_EPOCH))
    if (( exit_code != 0 )); then
        status=failed
        [[ -z "$CURRENT_STAGE" ]] || report_stage "$CURRENT_STAGE" failed \
            "$((finished_epoch - CURRENT_STAGE_STARTED_EPOCH))" "Stage exited with code $exit_code"
    fi
    for stage in "${SELECTED_STAGES[@]}"; do args+=(--stage "$stage"); done
    for stage in "${BENCHMARKS[@]}"; do args+=(--benchmark "$stage"); done
    [[ "$VERBOSE" == true ]] && args+=(--verbose)

    # All privileged measurement cleanup has completed by this point.  Do not
    # leave the deliberately long unattended-run timestamp valid afterwards.
    if [[ "$DENOISE_REQUIRED" == true ]]; then
        sudo -k >/dev/null 2>&1 || true
    fi

    python3 "$TESTS_DIR/lib/render-results.py" --run-root "$GT_RUN_ROOT" \
        --events "$GT_REPORT_EVENTS" --started-at "$REPORT_STARTED_AT" \
        --finished-at "$finished_at" --duration-seconds "$duration" \
        --status "$status" "${args[@]}"
    render_status=$?
    (( render_status == 0 )) || printf 'Could not render results (exit %d); backend data: %s\n' \
        "$render_status" "$GT_PIPELINE_ROOT" >&2
    if (( exit_code != 0 )) && [[ "$VERBOSE" == false ]]; then
        printf '\nLast 20 detailed log lines:\n' >&2
        tail -n 20 "$GT_DETAILED_LOG" | sed 's/^/  /' >&2
    fi
    exit "$exit_code"
}

compile_openjdk() {
    [[ "$FULL_REBUILD" != true ]] || run_step 'Clean OpenJDK' "$TESTS_DIR/Stages/Clean-OpenJDK.sh"
    run_step 'Compile OpenJDK with compiler markers' "$TESTS_DIR/Stages/Compile-OpenJDK.sh"
}

compile_graal() {
    local -a args=()
    [[ "$FULL_REBUILD" != true ]] || run_step 'Clean Graal' "$TESTS_DIR/Stages/Clean-Graal.sh"
    [[ "$TEST_ONLY" != true ]] || args+=(--test-only)
    run_step 'Build and verify Graal' "$TESTS_DIR/Stages/Compile-Graal.sh" "${args[@]}"
}

run_divine() {
    local benchmark
    local -a denoise_prefix=()
    [[ "$USE_DENOISE" != true ]] || denoise_prefix=("$TESTS_DIR/Setup-Denoise.sh" run --)
    for benchmark in "${BENCHMARKS[@]}"; do
        run_step "Divine $benchmark" "${denoise_prefix[@]}" \
            "$TESTS_DIR/Stages/Divine.sh" --benchmark "$benchmark"
        run_step "Verify Divine slowdown for $benchmark" "$TESTS_DIR/Stages/Verify-Divine.sh" --benchmark "$benchmark"
    done
}

run_bubol() {
    local benchmark
    local -a denoise_prefix=()
    [[ "$USE_DENOISE" != true ]] || denoise_prefix=("$TESTS_DIR/Setup-Denoise.sh" run --)
    for benchmark in "${BENCHMARKS[@]}"; do
        run_step "Divine $benchmark with BuboL" "${denoise_prefix[@]}" \
            "$TESTS_DIR/Stages/Divine.sh" --bubol --benchmark "$benchmark"
        run_step "Verify BuboL slowdown for $benchmark" "$TESTS_DIR/Stages/Verify-BuboL.sh" --benchmark "$benchmark"
        run_step "Verify every BuboL loop for $benchmark" "$TESTS_DIR/Stages/Verify-BuboL-Loops.sh" --benchmark "$benchmark"
    done
}

run_selected_stages() {
    local stage finished
    for stage in "${SELECTED_STAGES[@]}"; do
        CURRENT_STAGE=$stage
        CURRENT_STAGE_STARTED_EPOCH=$(date +%s)
        case "$stage" in
            openjdk) compile_openjdk ;;
            graal) compile_graal ;;
            divine) run_divine ;;
            bubol) run_bubol ;;
        esac
        finished=$(date +%s)
        report_stage "$stage" passed "$((finished - CURRENT_STAGE_STARTED_EPOCH))"
        CURRENT_STAGE=''
    done
}

main() {
    parse_arguments "$@"
    validate_invocation_user "$@"
    select_stages
    validate_arguments
    authorize_unattended_pipeline
    initialise_run
    trap 'finalise_run $?' EXIT
    task "Run GT ecosystem stages: ${SELECTED_STAGES[*]}"
    INDENT_LEVEL=$((INDENT_LEVEL + 1)); export INDENT_LEVEL
    if [[ "$DENOISE_REQUIRED" == true ]]; then
        run_step 'Verify machine dependencies' "$TESTS_DIR/Verify-Dependencies.sh" --pipeline
    else
        run_step 'Verify machine dependencies' \
            "$TESTS_DIR/Verify-Dependencies.sh" --pipeline --without-denoise
    fi
    run_selected_stages
    INDENT_LEVEL=$((INDENT_LEVEL - 1)); export INDENT_LEVEL
    pass "Selected stages passed: ${SELECTED_STAGES[*]}"
}

main "$@"
