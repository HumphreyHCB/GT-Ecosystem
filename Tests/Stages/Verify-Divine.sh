#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TESTS_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

# shellcheck source=../lib/common.sh
source "$TESTS_DIR/lib/common.sh"

if (( ${GT_COMMON_VERSION:-0} < 2 )); then
    die "Tests/lib/common.sh is out of date; version 2 or later is required"
fi

# shellcheck source=Graal-Options.sh
source "$SCRIPT_DIR/Graal-Options.sh"

CONFIG_FILE=${GT_ECOSYSTEM_CONFIG:-"$TESTS_DIR/config.config"}

DIVINE_OUTPUT_ROOT="$TESTS_DIR/Output/Divine"
DIVINE_OUTPUT=''
COMPILER_REPLAY_DIRECTORY=''
SLOWDOWN_JSON=''
VERIFICATION_OUTPUT=''

GRAAL_REPOSITORY=''
GRAAL_VM_HOME=''
GT_SLOWDOWN_SCHEDULER=''
BENCHMARKS_JAR=''

NORMAL_AVERAGE=''
SLOWDOWN_AVERAGE=''

readonly BENCHMARK=Mandelbrot
readonly ITERATIONS=300
readonly EXTRA_ARGUMENT=750
readonly EXPECTED_SLOWDOWN=2
readonly SLOWDOWN_TOLERANCE_PERCENT=10

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

    GRAAL_VM_HOME="$GRAAL_REPOSITORY/vm/latest_graalvm_home"

    load_graal_options
}

is_complete_divine_output() {
    local candidate=$1
    local replay_file

    [[ -d "$candidate" ]] || return 1
    [[ -s "$candidate/Final_$BENCHMARK.json" ]] || return 1
    [[ -d "$candidate/CompilerReplay" ]] || return 1

    replay_file=$(
        find "$candidate/CompilerReplay" \
            -type f \
            -print \
            -quit
    )

    [[ -n "$replay_file" ]]
}

find_latest_divine_output() {
    local candidate
    local candidate_name
    local candidate_timestamp
    local latest_result="$DIVINE_OUTPUT_ROOT/Latest-$BENCHMARK"

    require_directory \
        "$DIVINE_OUTPUT_ROOT" \
        'Divine output root'

    if [[ -e "$latest_result" ]]; then
        candidate=$(
            readlink -f -- "$latest_result" 2>/dev/null ||
                true
        )

        if [[ -n "$candidate" ]] &&
            is_complete_divine_output "$candidate"; then
            DIVINE_OUTPUT=$candidate
        fi
    fi

    if [[ -z "$DIVINE_OUTPUT" ]]; then
        while IFS= read -r candidate; do
            if is_complete_divine_output "$candidate"; then
                DIVINE_OUTPUT=$candidate
                break
            fi
        done < <(
            while IFS= read -r candidate; do
                candidate_name=${candidate##*/}
                candidate_timestamp=${candidate_name: -19}

                if [[ "$candidate_timestamp" =~ ^[0-9]{4}(_[0-9]{2}){5}$ ]]; then
                    printf \
                        '%s\t%s\n' \
                        "$candidate_timestamp" \
                        "$candidate"
                fi
            done < <(
                find "$DIVINE_OUTPUT_ROOT" \
                    -mindepth 1 \
                    -maxdepth 1 \
                    -type d \
                    \( \
                        -name "Divine_${BENCHMARK}_*" -o \
                        -name "${BENCHMARK}_*" \
                    \) \
                    -print
            ) |
                sort -r |
                cut -f2-
        )
    fi

    if [[ -z "$DIVINE_OUTPUT" ]]; then
        die "No complete $BENCHMARK Divine output was found in $DIVINE_OUTPUT_ROOT"
    fi

    ln -sfn \
        "$(basename -- "$DIVINE_OUTPUT")" \
        "$latest_result"

    COMPILER_REPLAY_DIRECTORY="$DIVINE_OUTPUT/CompilerReplay"
    SLOWDOWN_JSON="$DIVINE_OUTPUT/Final_$BENCHMARK.json"
    VERIFICATION_OUTPUT="$DIVINE_OUTPUT/Verification"

    task "Using Divine output: $DIVINE_OUTPUT"
}

validate_inputs() {
    local replay_file

    require_executable \
        "$GRAAL_VM_HOME/bin/java" \
        'Latest GraalVM java'

    require_file \
        "$BENCHMARKS_JAR" \
        'Are We Fast Yet benchmarks JAR'

    require_directory \
        "$COMPILER_REPLAY_DIRECTORY" \
        'CompilerReplay input'

    require_file \
        "$SLOWDOWN_JSON" \
        'Final slowdown JSON'

    if [[ ! -s "$SLOWDOWN_JSON" ]]; then
        die "Final slowdown JSON is empty: $SLOWDOWN_JSON"
    fi

    replay_file=$(
        find "$COMPILER_REPLAY_DIRECTORY" \
            -type f \
            -print \
            -quit
    )

    if [[ -z "$replay_file" ]]; then
        die "CompilerReplay directory contains no files: $COMPILER_REPLAY_DIRECTORY"
    fi

    mkdir -p "$VERIFICATION_OUTPUT"

    load_divine_verification_options \
        "$COMPILER_REPLAY_DIRECTORY" \
        "$SLOWDOWN_JSON"
}

run_command_with_log() {
    local output_file=$1
    local command_status

    shift

    "$@" 2>&1 | tee "$output_file"
    command_status=${PIPESTATUS[0]}

    return "$command_status"
}

run_benchmark() {
    local mode=$1
    local output_file=$2

    shift 2

    local -a java_options=("$@")

    run_command_with_log \
        "$output_file" \
        "$GRAAL_VM_HOME/bin/java" \
        "${java_options[@]}" \
        -cp "$BENCHMARKS_JAR" \
        Harness \
        "$BENCHMARK" \
        "$ITERATIONS" \
        "$EXTRA_ARGUMENT"
}

extract_average_runtime() {
    local output_file=$1

    awk \
        -v benchmark="$BENCHMARK" \
        -v iterations="$ITERATIONS" '
            $1 == benchmark ":" && $2 == "iterations=" iterations && $3 == "average:" && $4 ~ /^[0-9]+us$/ {
                value = $4
                sub(/us$/, "", value)
                matches++
            }

            END {
                if (matches != 1 || value <= 0) {
                    exit 1
                }

                print value
            }
        ' "$output_file"
}

run_normal_replay() {
    local output_file="$VERIFICATION_OUTPUT/Normal.log"

    run_benchmark \
        'Normal compiler replay' \
        "$output_file" \
        "${GT_GRAAL_OPTIONS[@]}" \
        "${DIVINE_REPLAY_OPTIONS[@]}" ||
        return 1

    NORMAL_AVERAGE=$(extract_average_runtime "$output_file") || {
        fail "Could not extract one valid $BENCHMARK average runtime from $output_file"
        return 1
    }

    pass "Normal average: ${NORMAL_AVERAGE}us"
}

run_slowdown_replay() {
    local output_file="$VERIFICATION_OUTPUT/Slowdown.log"

    run_benchmark \
        'Slowdown compiler replay' \
        "$output_file" \
        "${GT_GRAAL_OPTIONS[@]}" \
        "${DIVINE_REPLAY_OPTIONS[@]}" \
        "${DIVINE_SLOWDOWN_OPTIONS[@]}" ||
        return 1

    SLOWDOWN_AVERAGE=$(extract_average_runtime "$output_file") || {
        fail "Could not extract one valid $BENCHMARK average runtime from $output_file"
        return 1
    }

    pass "Slowdown average: ${SLOWDOWN_AVERAGE}us"
}

verify_slowdown_ratio() {
    local minimum_ratio
    local maximum_ratio
    local observed_ratio

    minimum_ratio=$(
        awk \
            -v expected="$EXPECTED_SLOWDOWN" \
            -v tolerance="$SLOWDOWN_TOLERANCE_PERCENT" \
            'BEGIN { printf "%.6f", expected * (1 - tolerance / 100) }'
    )

    maximum_ratio=$(
        awk \
            -v expected="$EXPECTED_SLOWDOWN" \
            -v tolerance="$SLOWDOWN_TOLERANCE_PERCENT" \
            'BEGIN { printf "%.6f", expected * (1 + tolerance / 100) }'
    )

    observed_ratio=$(
        awk \
            -v normal="$NORMAL_AVERAGE" \
            -v slowdown="$SLOWDOWN_AVERAGE" \
            'BEGIN { printf "%.6f", slowdown / normal }'
    )

    if ! awk \
        -v observed="$observed_ratio" \
        -v minimum="$minimum_ratio" \
        -v maximum="$maximum_ratio" \
        'BEGIN { exit !(observed >= minimum && observed <= maximum) }'; then

        fail "Slowdown ratio was ${observed_ratio}x"
        fail "Expected between ${minimum_ratio}x and ${maximum_ratio}x"

        return 1
    fi

    pass "Observed slowdown: ${observed_ratio}x"
    pass "Accepted range: ${minimum_ratio}x to ${maximum_ratio}x"
}

main() {
    task "Verify Divine slowdown for $BENCHMARK"

    INDENT_LEVEL=$((INDENT_LEVEL + 1))
    export INDENT_LEVEL

    run_step \
        'Load Divine verification configuration' \
        load_configuration

    run_step \
        'Find latest Divine output' \
        find_latest_divine_output

    run_step \
        'Validate Divine verification inputs' \
        validate_inputs

    run_step \
        'Run normal compiler replay' \
        run_normal_replay

    run_step \
        'Run slowdown compiler replay' \
        run_slowdown_replay

    run_step \
        'Verify slowdown ratio' \
        verify_slowdown_ratio

    INDENT_LEVEL=$((INDENT_LEVEL - 1))
    export INDENT_LEVEL

    pass "Divine verification passed: $DIVINE_OUTPUT"
}

main "$@"