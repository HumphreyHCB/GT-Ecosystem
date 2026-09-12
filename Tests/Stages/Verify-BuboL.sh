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

BUBOL_OUTPUT_ROOT="$TESTS_DIR/Output/BuboL"
BUBOL_OUTPUT=''
COMPILER_REPLAY_DIRECTORY=''
SLOWDOWN_JSON=''
VERIFICATION_OUTPUT=''

GRAAL_REPOSITORY=''
GRAAL_VM_HOME=''
GT_SLOWDOWN_SCHEDULER=''
BENCHMARKS_JAR=''

NORMAL_AVERAGE=''
SLOWDOWN_AVERAGE=''
NORMAL_BUBOL_DATA=''
SLOWDOWN_BUBOL_DATA=''
OBSERVED_SLOWDOWN_RATIO=''
MINIMUM_SLOWDOWN_RATIO=''
MAXIMUM_SLOWDOWN_RATIO=''

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

is_complete_bubol_output() {
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

find_latest_bubol_output() {
    local candidate
    local candidate_name
    local candidate_timestamp
    local latest_result="$BUBOL_OUTPUT_ROOT/Latest-$BENCHMARK"

    require_directory \
        "$BUBOL_OUTPUT_ROOT" \
        'BuboL output root'

    # Prefer the stable link written after a successful Divine run.
    if [[ -e "$latest_result" ]]; then
        candidate=$(
            readlink -f -- "$latest_result" 2>/dev/null ||
                true
        )

        if [[ -n "$candidate" ]] &&
            is_complete_bubol_output "$candidate"; then
            BUBOL_OUTPUT=$candidate
        fi
    fi

    # Fall back to scanning completed results.
    #
    # The second filename pattern supports results created before the explicit
    # BuboL prefix was added.
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
                    printf \
                        '%s\t%s\n' \
                        "$candidate_timestamp" \
                        "$candidate"
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
            ) |
                sort -r |
                cut -f2-
        )
    fi

    if [[ -z "$BUBOL_OUTPUT" ]]; then
        die "No complete $BENCHMARK BuboL Divine output was found in $BUBOL_OUTPUT_ROOT"
    fi

    # Create or repair the stable link, including when a legacy result was
    # found by scanning.
    ln -sfn \
        "$(basename -- "$BUBOL_OUTPUT")" \
        "$latest_result"

    COMPILER_REPLAY_DIRECTORY="$BUBOL_OUTPUT/CompilerReplay"
    SLOWDOWN_JSON="$BUBOL_OUTPUT/Final_$BENCHMARK.json"
    VERIFICATION_OUTPUT="$BUBOL_OUTPUT/Verification"

    task "Using BuboL Divine output: $BUBOL_OUTPUT"
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
        'BuboL CompilerReplay input'

    require_file \
        "$SLOWDOWN_JSON" \
        'Final BuboL slowdown JSON'

    if [[ ! -s "$SLOWDOWN_JSON" ]]; then
        die "Final BuboL slowdown JSON is empty: $SLOWDOWN_JSON"
    fi

    replay_file=$(
        find "$COMPILER_REPLAY_DIRECTORY" \
            -type f \
            -print \
            -quit
    )

    if [[ -z "$replay_file" ]]; then
        die "BuboL CompilerReplay directory contains no files: $COMPILER_REPLAY_DIRECTORY"
    fi

    mkdir -p "$VERIFICATION_OUTPUT"

    load_bubol_verification_options \
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

    task "$mode"

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

validate_bubol_output() {
    local output_file=$1
    local run_kind=$2
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
                    sub(/^.*Cycles:[[:space:]]*/, "", cycle_text)
                    split(cycle_text, fields, /[[:space:]]+/)
                    total += fields[1]
                }

                END {
                    printf "%d %d %.0f\n", encodings, loops, total
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

    if [[ "$run_kind" == normal ]]; then
        NORMAL_BUBOL_DATA="$encoding_count encodings, $loop_count loops, $total_cycles cycles"
    else
        SLOWDOWN_BUBOL_DATA="$encoding_count encodings, $loop_count loops, $total_cycles cycles"
    fi
}

run_normal_bubol_replay() {
    local output_file="$VERIFICATION_OUTPUT/Normal-BuboL.log"

    run_benchmark \
        'Normal BuboL compiler replay' \
        "$output_file" \
        "${GT_GRAAL_OPTIONS[@]}" \
        "${BUBOL_REPLAY_OPTIONS[@]}" \
        "${BUBOL_NORMAL_OPTIONS[@]}" ||
        return 1

    validate_bubol_output "$output_file" normal ||
        return 1

    NORMAL_AVERAGE=$(extract_average_runtime "$output_file") || {
        fail "Could not extract one valid $BENCHMARK average runtime from $output_file"
        return 1
    }

    pass "Normal BuboL average: ${NORMAL_AVERAGE}us"
}

run_slowdown_bubol_replay() {
    local output_file="$VERIFICATION_OUTPUT/Slowdown-BuboL.log"

    run_benchmark \
        'Slowdown BuboL compiler replay' \
        "$output_file" \
        "${GT_GRAAL_OPTIONS[@]}" \
        "${BUBOL_REPLAY_OPTIONS[@]}" \
        "${BUBOL_SLOWDOWN_OPTIONS[@]}" ||
        return 1

    validate_bubol_output "$output_file" slowdown ||
        return 1

    SLOWDOWN_AVERAGE=$(extract_average_runtime "$output_file") || {
        fail "Could not extract one valid $BENCHMARK average runtime from $output_file"
        return 1
    }

    pass "Slowdown BuboL average: ${SLOWDOWN_AVERAGE}us"
}

verify_slowdown_ratio() {
    MINIMUM_SLOWDOWN_RATIO=$(
        awk \
            -v expected="$EXPECTED_SLOWDOWN" \
            -v tolerance="$SLOWDOWN_TOLERANCE_PERCENT" \
            'BEGIN { printf "%.6f", expected * (1 - tolerance / 100) }'
    )

    MAXIMUM_SLOWDOWN_RATIO=$(
        awk \
            -v expected="$EXPECTED_SLOWDOWN" \
            -v tolerance="$SLOWDOWN_TOLERANCE_PERCENT" \
            'BEGIN { printf "%.6f", expected * (1 + tolerance / 100) }'
    )

    OBSERVED_SLOWDOWN_RATIO=$(
        awk \
            -v normal="$NORMAL_AVERAGE" \
            -v slowdown="$SLOWDOWN_AVERAGE" \
            'BEGIN { printf "%.6f", slowdown / normal }'
    )

    if ! awk \
        -v observed="$OBSERVED_SLOWDOWN_RATIO" \
        -v minimum="$MINIMUM_SLOWDOWN_RATIO" \
        -v maximum="$MAXIMUM_SLOWDOWN_RATIO" \
        'BEGIN { exit !(observed >= minimum && observed <= maximum) }'; then

        fail "BuboL slowdown ratio was ${OBSERVED_SLOWDOWN_RATIO}x"
        fail "Expected between ${MINIMUM_SLOWDOWN_RATIO}x and ${MAXIMUM_SLOWDOWN_RATIO}x"

        return 1
    fi

    pass "Observed BuboL slowdown: ${OBSERVED_SLOWDOWN_RATIO}x"
    pass "Accepted range: ${MINIMUM_SLOWDOWN_RATIO}x to ${MAXIMUM_SLOWDOWN_RATIO}x"
}

main() {
    task "Verify BuboL Divine slowdown for $BENCHMARK"

    INDENT_LEVEL=$((INDENT_LEVEL + 1))
    export INDENT_LEVEL

    run_step \
        'Load BuboL verification configuration' \
        load_configuration

    run_step \
        'Find latest BuboL Divine output' \
        find_latest_bubol_output

    run_step \
        'Validate BuboL verification inputs' \
        validate_inputs

    report_check \
        bubol \
        'BuboL Divine output verified' \
        "Slowdown file: $SLOWDOWN_JSON; compiler replay: $COMPILER_REPLAY_DIRECTORY"

    run_step \
        'Run normal BuboL compiler replay' \
        run_normal_bubol_replay

    run_step \
        'Run slowdown BuboL compiler replay' \
        run_slowdown_bubol_replay

    report_check \
        bubol \
        'BuboL loop data verified' \
        "Normal: $NORMAL_BUBOL_DATA; slowdown: $SLOWDOWN_BUBOL_DATA"

    run_step \
        'Verify BuboL slowdown ratio' \
        verify_slowdown_ratio

    report_check \
        bubol \
        'Requested BuboL slowdown verified' \
        "Observed ${OBSERVED_SLOWDOWN_RATIO}x from ${NORMAL_AVERAGE}us to ${SLOWDOWN_AVERAGE}us; accepted ${MINIMUM_SLOWDOWN_RATIO}x to ${MAXIMUM_SLOWDOWN_RATIO}x"

    INDENT_LEVEL=$((INDENT_LEVEL - 1))
    export INDENT_LEVEL

    pass "BuboL stage passed: $BUBOL_OUTPUT"
}

main "$@"
