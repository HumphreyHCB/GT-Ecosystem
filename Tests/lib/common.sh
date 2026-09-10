#!/usr/bin/env bash

# Shared output, configuration, and validation helpers for all ecosystem tests.

GT_COMMON_VERSION=2
export INDENT_LEVEL=${INDENT_LEVEL:-0}

indent() {
    printf '%*s' $((INDENT_LEVEL * 4)) ''
}

task() {
    printf '%s→ %s\n' "$(indent)" "$*"
}

pass() {
    printf '%s✔ %s\n' "$(indent)" "$*"
}

fail() {
    printf '%s✘ %s\n' "$(indent)" "$*" >&2
}

die() {
    fail "$*"
    exit 1
}

run_step() {
    local description=$1
    shift

    task "$description"
    INDENT_LEVEL=$((INDENT_LEVEL + 1))
    export INDENT_LEVEL

    if "$@"; then
        INDENT_LEVEL=$((INDENT_LEVEL - 1))
        export INDENT_LEVEL
        pass "$description"
    else
        local exit_code=$?
        INDENT_LEVEL=$((INDENT_LEVEL - 1))
        export INDENT_LEVEL
        fail "$description failed with exit code $exit_code"
        return "$exit_code"
    fi
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
