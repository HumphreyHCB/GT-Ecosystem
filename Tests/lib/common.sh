#!/usr/bin/env bash

# Shared output, configuration, reporting, and validation helpers.

GT_COMMON_VERSION=3
export INDENT_LEVEL=${INDENT_LEVEL:-0}
export GT_VERBOSE=${GT_VERBOSE:-false}

GT_COMMON_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GT_TESTS_DIRECTORY=$(cd -- "$GT_COMMON_DIRECTORY/.." && pwd)

prepend_path_if_directory() {
    local directory=$1

    [[ -d "$directory" ]] || return 0

    case ":$PATH:" in
        *":$directory:"*) ;;
        *) PATH="$directory:$PATH" ;;
    esac
}

# Tools installed by Tests/Install-Dependencies.sh and Intel's stable
# version-independent VTune path are available to every stage.
prepend_path_if_directory "$GT_TESTS_DIRECTORY/Tools/mx"
prepend_path_if_directory '/opt/intel/oneapi/vtune/latest/bin64'
export PATH

indent() {
    printf '%*s' $((INDENT_LEVEL * 4)) ''
}

task() {
    local message

    message="$(indent)→ $*"
    write_status_message stdout "$message"
}

pass() {
    local message

    message="$(indent)✔ $*"
    write_status_message stdout "$message"
}

fail() {
    local message

    message="$(indent)✘ $*"
    write_status_message stderr "$message"
}

write_status_message() {
    local destination=$1
    local message=$2

    if [[ -n ${GT_DETAILED_LOG:-} ]]; then
        printf '%s\n' "$message" >> "$GT_DETAILED_LOG"
    fi

    if [[ "$GT_VERBOSE" == true || -z ${GT_DETAILED_LOG:-} ]]; then
        if [[ "$destination" == stderr ]]; then
            printf '%s\n' "$message" >&2
        else
            printf '%s\n' "$message"
        fi
    fi
}

die() {
    fail "$*"
    exit 1
}

run_step() {
    local description=$1
    local exit_code
    shift

    task "$description"
    INDENT_LEVEL=$((INDENT_LEVEL + 1))
    export INDENT_LEVEL

    if [[ "$GT_VERBOSE" == true || -z ${GT_DETAILED_LOG:-} ]]; then
        if "$@"; then
            exit_code=0
        else
            exit_code=$?
        fi
    else
        if "$@" >> "$GT_DETAILED_LOG" 2>&1; then
            exit_code=0
        else
            exit_code=$?
        fi
    fi

    if (( exit_code == 0 )); then
        INDENT_LEVEL=$((INDENT_LEVEL - 1))
        export INDENT_LEVEL
        pass "$description"
    else
        INDENT_LEVEL=$((INDENT_LEVEL - 1))
        export INDENT_LEVEL
        fail "$description failed with exit code $exit_code"
        return "$exit_code"
    fi
}

report_field() {
    local value=$1

    value=${value//$'\t'/ }
    value=${value//$'\r'/ }
    value=${value//$'\n'/ }

    printf '%s' "$value"
}

report_check() {
    local stage=$1
    local label=$2
    local detail=${3:-}

    [[ -n ${GT_REPORT_EVENTS:-} ]] || return 0

    printf 'check\t%s\tpassed\t%s\t%s\n' \
        "$(report_field "$stage")" \
        "$(report_field "$label")" \
        "$(report_field "$detail")" \
        >> "$GT_REPORT_EVENTS"
}

report_stage() {
    local stage=$1
    local status=$2
    local duration_seconds=$3
    local detail=${4:-}

    [[ -n ${GT_REPORT_EVENTS:-} ]] || return 0

    printf 'stage\t%s\t%s\t%s\t%s\n' \
        "$(report_field "$stage")" \
        "$(report_field "$status")" \
        "$(report_field "$duration_seconds")" \
        "$(report_field "$detail")" \
        >> "$GT_REPORT_EVENTS"
}

config_get() {
    local config_file=$1
    local wanted_section=$2
    local wanted_key=$3

    awk -v wanted_section="$wanted_section" -v wanted_key="$wanted_key" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }

        /^[[:space:]]*[#;]/ || /^[[:space:]]*$/ {
            next
        }

        /^[[:space:]]*\[/ {
            section = $0
            sub(/^[[:space:]]*\[/, "", section)
            sub(/\][[:space:]]*$/, "", section)
            section = trim(section)
            next
        }

        section == wanted_section {
            separator = index($0, "=")
            if (separator == 0) {
                next
            }

            key = trim(substr($0, 1, separator - 1))
            if (key == wanted_key) {
                print trim(substr($0, separator + 1))
                exit
            }
        }
    ' "$config_file"
}

require_config_value() {
    local destination_variable=$1
    local config_file=$2
    local section=$3
    local key=$4
    local value

    value=$(config_get "$config_file" "$section" "$key")
    [[ -n "$value" ]] || die "Missing [$section] $key in $config_file"

    if [[ "$section" == Dir && "$value" != /* ]]; then
        value=$(realpath -m -- "$(dirname -- "$config_file")/$value")
    fi

    printf -v "$destination_variable" '%s' "$value"
}

require_directory() {
    local path=$1
    local description=$2
    [[ -d "$path" ]] || die "$description directory does not exist: $path"
}

require_file() {
    local path=$1
    local description=$2
    [[ -f "$path" ]] || die "$description file does not exist: $path"
}

require_executable() {
    local path=$1
    local description=$2
    [[ -x "$path" ]] || die "$description is missing or is not executable: $path"
}

configure_scheduler_environment() {
    local config_file=$1
    local scheduler_repository
    local graal_repository
    local awfy_jar
    local awfy_source
    local vtune_command

    require_config_value \
        scheduler_repository \
        "$config_file" \
        Dir \
        GTSlowdownSchedular
    require_config_value graal_repository "$config_file" Dir Graal
    require_config_value awfy_jar "$config_file" Dir AWFYBenchmarksJar
    require_config_value awfy_source "$config_file" Dir AWFYSource

    vtune_command=$(command -v vtune 2>/dev/null || true)
    [[ -n "$vtune_command" ]] || die 'VTune is not available on PATH'

    export GT_SCHEDULER_ROOT=$scheduler_repository
    export GT_GRAAL_JAVA="$graal_repository/vm/latest_graalvm_home/bin/java"
    export GT_AWFY_JAR=$awfy_jar
    export GT_AWFY_SOURCE_DIR=$awfy_source
    export GT_VTUNE_COMMAND=$vtune_command
}

resolve_openjdk_configuration() {
    local destination_variable=$1
    local labs_openjdk=$2
    local -a configuration_directories=()
    local spec_file

    while IFS= read -r spec_file; do
        configuration_directories+=("$(dirname "$spec_file")")
    done < <(find "$labs_openjdk/build" -mindepth 2 -maxdepth 2 \
        -name spec.gmk -print 2>/dev/null | sort)

    if (( ${#configuration_directories[@]} == 0 )); then
        die "No configured OpenJDK build was found under $labs_openjdk/build"
    fi

    if (( ${#configuration_directories[@]} > 1 )); then
        fail 'More than one configured OpenJDK build was found:'
        for directory in "${configuration_directories[@]}"; do
            fail "    $(basename "$directory")"
        done
        die 'Remove the unwanted build configuration or perform a full OpenJDK rebuild'
    fi

    printf -v "$destination_variable" '%s' \
        "$(basename "${configuration_directories[0]}")"
}
