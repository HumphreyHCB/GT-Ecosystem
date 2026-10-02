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

TEST_ONLY=false

OPENJDK_CONF=''
GRAAL_BUILDER_JDK=''
GRAAL_VM_HOME=''

OUTPUT_DIRECTORY="$TESTS_DIR/Output"

declare -A BUBO_MODE_RESULTS=()
declare -A MARKER_MODE_RESULTS=()

readonly BENCHMARK_ITERATIONS=100
readonly BOUNCE_SIZE=10000
readonly SIEVE_SIZE=10000

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [--test-only]

Options:
        --test-only    Test the existing GraalVM image without rebuilding Graal
    -h, --help         Show this help
EOF
}

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --test-only)
                TEST_ONLY=true
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
    require_file \
        "$CONFIG_FILE" \
        'Ecosystem configuration'

    require_config_value \
        GRAAL_REPOSITORY \
        "$CONFIG_FILE" \
        Dir \
        Graal

    require_config_value \
        GT_SLOWDOWN_SCHEDULER \
        "$CONFIG_FILE" \
        Dir \
        GTSlowdownSchedular

    require_config_value \
        BENCHMARKS_JAR \
        "$CONFIG_FILE" \
        Dir \
        AWFYBenchmarksJar

    require_config_value \
        ASYNC_PROFILER_LIBRARY \
        "$CONFIG_FILE" \
        Dir \
        AsyncProfilerLibrary

    GRAAL_VM_HOME="$GRAAL_REPOSITORY/vm/latest_graalvm_home"

    if [[ "$TEST_ONLY" == false ]]; then
        require_config_value \
            LABS_OPENJDK \
            "$CONFIG_FILE" \
            Dir \
            LabsOpenJDK

        resolve_openjdk_configuration \
            OPENJDK_CONF \
            "$LABS_OPENJDK"

        GRAAL_BUILDER_JDK="$LABS_OPENJDK/build/$OPENJDK_CONF/images/graal-builder-jdk"
    fi

    load_graal_options
}

validate_inputs() {
    require_directory \
        "$GRAAL_REPOSITORY" \
        'Graal repository'

    require_directory \
        "$GRAAL_REPOSITORY/vm" \
        'Graal VM suite'

    require_directory \
        "$GT_SLOWDOWN_SCHEDULER" \
        'GT slowdown scheduler'

    require_file \
        "$BENCHMARKS_JAR" \
        'Are We Fast Yet benchmarks JAR'

    require_file \
        "$ASYNC_PROFILER_LIBRARY" \
        'Async-profiler native library'

    if [[ "$TEST_ONLY" == false ]]; then
        require_executable \
            "$GRAAL_BUILDER_JDK/bin/java" \
            'Graal builder JDK java'

        command -v mx >/dev/null 2>&1 || \
            die 'mx is not available on PATH'
    fi
}

prepare_output_directory() {
    mkdir -p "$OUTPUT_DIRECTORY"
}

build_graal() {
    (
        local build_pid
        local tail_pid
        local build_status
        local log_file=/tmp/gt-ecosystem-graal-build.log

        cd "$GRAAL_REPOSITORY/vm"

        : > "$log_file"

        task "Graal build log: $log_file"

        nohup mx \
            --java-home "$GRAAL_BUILDER_JDK" \
            --env libgraal \
            build \
            > "$log_file" 2>&1 < /dev/null &

        build_pid=$!

        # mx sees a normal file rather than a terminal.
        # The output is still displayed while the build runs.
        tail \
            --pid="$build_pid" \
            --lines=+1 \
            --follow=name \
            "$log_file" &

        tail_pid=$!

        trap \
            'kill -TERM "$build_pid" "$tail_pid" 2>/dev/null || true' \
            INT \
            TERM

        if wait "$build_pid"; then
            build_status=0
        else
            build_status=$?
        fi

        wait "$tail_pid" 2>/dev/null || true

        trap - INT TERM

        return "$build_status"
    )
}

verify_graalvm_image() {
    require_directory \
        "$GRAAL_VM_HOME" \
        'Latest GraalVM home'

    require_executable \
        "$GRAAL_VM_HOME/bin/java" \
        'Latest GraalVM java'

    "$GRAAL_VM_HOME/bin/java" -version
}

run_command_with_log() {
    local output_file=$1
    local command_status

    shift

    "$@" 2>&1 | tee "$output_file"
    command_status=${PIPESTATUS[0]}

    return "$command_status"
}

validate_bubo_output() {
    local output_file=$1
    local benchmark=$2
    local encoding_count
    local loop_count
    local total_cycles

    read -r \
        encoding_count \
        loop_count \
        total_cycles < <(
            awk '
                /Found Encoding[[:space:]]*:/ {
                    encodings++
                }

                /^[[:space:]]*loop [0-9]+ Cycles:[[:space:]]*[0-9]+/ {
                    loops++

                    cycle_text = $0
                    sub(
                        /^.*Cycles:[[:space:]]*/,
                        "",
                        cycle_text
                    )

                    split(
                        cycle_text,
                        fields,
                        /[[:space:]]+/
                    )

                    total += fields[1]
                }

                END {
                    printf "%d %d %.0f\n",
                        encodings,
                        loops,
                        total
                }
            ' "$output_file"
        )

    if (( encoding_count <= 0 )); then
        fail "No BuboL encodings were found in $output_file"
        return 1
    fi

    if (( loop_count <= 0 )); then
        fail "No BuboL loops were found in $output_file"
        return 1
    fi

    if (( total_cycles <= 0 )); then
        fail "BuboL recorded zero total loop cycles in $output_file"
        return 1
    fi

    pass "BuboL data: $encoding_count encodings, $loop_count loops, $total_cycles total loop cycles"
    BUBO_MODE_RESULTS["$benchmark"]="$encoding_count encodings, $loop_count loops, $total_cycles cycles"
}

validate_debug_markers() {
    local profile_file=$1
    local benchmark=$2
    local marker_stacks
    local marker_frames
    local hottest_marker_percentage
    local hottest_marker

    require_file \
        "$profile_file" \
        'Async-profiler text output'

    if [[ ! -s "$profile_file" ]]; then
        fail "Async-profiler output is empty: $profile_file"
        return 1
    fi

    read -r \
        marker_stacks \
        marker_frames \
        hottest_marker_percentage \
        hottest_marker < <(
            awk '
                function finish_trace(
                    marker,
                    found_marker
                ) {
                    if (!trace_started) {
                        return
                    }

                    found_marker = 0

                    for (marker in trace_markers) {
                        marker_percentage[marker] += trace_percentage
                        delete trace_markers[marker]
                        found_marker = 1
                    }

                    if (found_marker) {
                        stacks++
                    }
                }

                /^--- .*\([0-9]+([.][0-9]+)?%\)/ {
                    finish_trace()

                    percentage_text = $0
                    sub(/^.*\(/, "", percentage_text)
                    sub(/%.*/, "", percentage_text)

                    trace_percentage = percentage_text + 0
                    trace_started = 1
                    next
                }

                {
                    remaining = $0

                    while (
                        match(
                            remaining,
                            /my[.]custom[.]BuboAgentCompilerMarkers[.](Marker[0-9]+|MarkerDelimiter)/
                        )
                    ) {
                        marker_name = substr(
                            remaining,
                            RSTART,
                            RLENGTH
                        )

                        frames++
                        trace_markers[marker_name] = 1

                        remaining = substr(
                            remaining,
                            RSTART + RLENGTH
                        )
                    }
                }

                END {
                    finish_trace()

                    hottest_percentage = 0
                    hottest_marker = "none"

                    for (marker in marker_percentage) {
                        if (
                            marker_percentage[marker] >
                            hottest_percentage
                        ) {
                            hottest_percentage = marker_percentage[marker]
                            hottest_marker = marker
                        }
                    }

                    printf "%d %d %.6f %s\n",
                        stacks,
                        frames,
                        hottest_percentage,
                        hottest_marker
                }
            ' "$profile_file"
        )

    if (( marker_frames < 2 )); then
        fail "Fewer than two compiler-marker occurrences were found in $profile_file"
        return 1
    fi

    if ! awk \
        -v percentage="$hottest_marker_percentage" \
        'BEGIN {
            exit !(percentage >= 2.0)
        }'; then

        fail "No compiler marker accounted for at least 2% of the async-profiler report"
        fail "Highest marker: $hottest_marker at $hottest_marker_percentage%"

        return 1
    fi

    pass "Debug markers: $marker_frames occurrences across $marker_stacks trace records"
    pass "Highest marker: $hottest_marker at $hottest_marker_percentage%"

    task "Async-profiler output: $profile_file"
    MARKER_MODE_RESULTS["$benchmark"]="$marker_frames marker frames, hottest $hottest_marker at $hottest_marker_percentage%"
}

run_awfy_benchmark() {
    local mode=$1
    local validation=$2
    local benchmark=$3
    local iterations=$4
    local size=$5

    shift 5

    local -a java_options=("$@")

    local output_file=''
    local profile_file=''
    local agent_option=''

    if [[ "$validation" == bubo ]]; then
        output_file="$OUTPUT_DIRECTORY/${mode// /-}-$benchmark.log"
    fi

    if [[ "$validation" == marker-debug ]]; then
        profile_file="$OUTPUT_DIRECTORY/${mode// /-}-$benchmark.txt"

        rm -f -- "$profile_file"

        agent_option="-agentpath:$ASYNC_PROFILER_LIBRARY=start,event=cpu,interval=10us,file=$profile_file"

        java_options=(
            "$agent_option"
            "${java_options[@]}"
        )
    fi

    if [[ -n "$output_file" ]]; then
        run_step \
            "$mode: $benchmark, $iterations iterations, size $size" \
            run_command_with_log \
            "$output_file" \
            "$GRAAL_VM_HOME/bin/java" \
            "${java_options[@]}" \
            -cp "$BENCHMARKS_JAR" \
            Harness \
            "$benchmark" \
            "$iterations" \
            "$size"

        run_step \
            "$mode: validate $benchmark BuboL output" \
            validate_bubo_output \
            "$output_file" \
            "$benchmark"
    else
        run_step \
            "$mode: $benchmark, $iterations iterations, size $size" \
            "$GRAAL_VM_HOME/bin/java" \
            "${java_options[@]}" \
            -cp "$BENCHMARKS_JAR" \
            Harness \
            "$benchmark" \
            "$iterations" \
            "$size"
    fi

    if [[ "$validation" == marker-debug ]]; then
        run_step \
            "$mode: validate $benchmark compiler markers" \
            validate_debug_markers \
            "$profile_file" \
            "$benchmark"
    fi
}

run_mode() {
    local mode=$1
    local validation=$2

    shift 2

    local -a java_options=("$@")

    task "Verify $mode mode"

    INDENT_LEVEL=$((INDENT_LEVEL + 1))
    export INDENT_LEVEL

    run_awfy_benchmark \
        "$mode" \
        "$validation" \
        Bounce \
        "$BENCHMARK_ITERATIONS" \
        "$BOUNCE_SIZE" \
        "${java_options[@]}"

    run_awfy_benchmark \
        "$mode" \
        "$validation" \
        Sieve \
        "$BENCHMARK_ITERATIONS" \
        "$SIEVE_SIZE" \
        "${java_options[@]}"

    INDENT_LEVEL=$((INDENT_LEVEL - 1))
    export INDENT_LEVEL

    pass "$mode mode passed"

    case "$validation" in
        bubo)
            report_check \
                graal \
                'BuboL compiler tests passed' \
                "Bounce: ${BUBO_MODE_RESULTS[Bounce]}; Sieve: ${BUBO_MODE_RESULTS[Sieve]}"
            ;;
        marker-debug)
            report_check \
                graal \
                'GT compiler marker tests passed' \
                "Bounce: ${MARKER_MODE_RESULTS[Bounce]}; Sieve: ${MARKER_MODE_RESULTS[Sieve]}"
            ;;
        none)
            report_check \
                graal \
                "$mode benchmark tests passed" \
                'Bounce and Sieve completed 100 iterations with size 10000'
            ;;
    esac
}

verify_graal_configurations() {
    run_mode \
        'Clean GraalVM' \
        none

    run_mode \
        'GT options' \
        none \
        "${GT_GRAAL_OPTIONS[@]}"

    run_mode \
        'BuboL' \
        bubo \
        "${GT_GRAAL_OPTIONS[@]}" \
        "${BUBO_GRAAL_OPTIONS[@]}" \
        -Djdk.graal.GTAssignDebug=false \
        -Djdk.graal.LIRGTSlowDown=false

    run_mode \
        'GT marker debug' \
        marker-debug \
        "${GT_GRAAL_OPTIONS[@]}" \
        -Djdk.graal.GTAssignDebug=true
}

main() {
    parse_arguments "$@"

    if [[ "$TEST_ONLY" == true ]]; then
        task 'Test the existing Graal compiler'
    else
        task 'Build and verify the Graal compiler'
    fi

    INDENT_LEVEL=$((INDENT_LEVEL + 1))
    export INDENT_LEVEL

    run_step \
        'Load Graal build configuration' \
        load_configuration

    run_step \
        'Validate Graal build inputs' \
        validate_inputs

    run_step \
        'Prepare Graal test output directory' \
        prepare_output_directory

    if [[ "$TEST_ONLY" == true ]]; then
        task 'Skip Graal build because --test-only was requested'
    else
        run_step \
            'Build Graal with the OpenJDK graal-builder-jdk' \
            build_graal
    fi

    run_step \
        'Verify the generated GraalVM image' \
        verify_graalvm_image

    if [[ "$TEST_ONLY" == true ]]; then
        report_check \
            graal \
            'Existing Graal compiler image verified' \
            "$GRAAL_VM_HOME"
    else
        report_check \
            graal \
            'Graal compiler image built' \
            "$GRAAL_VM_HOME"
    fi

    verify_graal_configurations

    INDENT_LEVEL=$((INDENT_LEVEL - 1))
    export INDENT_LEVEL

    if [[ "$TEST_ONLY" == true ]]; then
        pass 'Existing GraalVM verification completed'
    else
        pass 'Graal compilation and verification stage completed'
    fi
}

main "$@"
