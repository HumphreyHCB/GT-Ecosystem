#!/usr/bin/env bash

# Install, verify, and run commands with ReBench Denoise on Rocky Linux.

set -Eeuo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ECOSYSTEM_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)

# shellcheck source=lib/common.sh
source "$TESTS_DIR/lib/common.sh"

readonly REBENCH_VERSION=1.4.0
readonly CPUSET_COMMIT=db68d6daae07d12c38d7cf7375cf843ced0f6792
readonly TOOLS_DIRECTORY="$TESTS_DIR/Tools"
readonly REBENCH_ENVIRONMENT="$TOOLS_DIRECTORY/rebench"
readonly DENOISE_COMMAND="$REBENCH_ENVIRONMENT/bin/rebench-denoise"
readonly CSET_COMMAND="$REBENCH_ENVIRONMENT/bin/cset"

ACTION=install
SKIP_SYSTEM_PACKAGES=false
SKIP_VERIFY=false
ROOT_COMMAND=()
RUN_COMMAND=()
DENOISE_ARGUMENTS=()
CPU_COUNT=0
INITIAL_NO_TURBO=''
INITIAL_GOVERNOR=''
SHIELDING_ATTEMPTED=false
SHIELDING_ENABLED=false
KEEPALIVE_PID=''
CLEANED_UP=false

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [install] [OPTIONS]
       $(basename "$0") verify
       $(basename "$0") run -- COMMAND [ARGUMENT ...]

Commands:
    install                 Install pinned ReBench and cpuset, then verify them
    verify                  Test Denoise and restore the original CPU settings
    run -- COMMAND          Run COMMAND with reduced benchmark noise

Install options:
    --skip-system-packages  Do not install Python packaging dependencies
    --skip-verify           Install without the privileged functional test
    -h, --help              Show this help

The run command disables Turbo Boost temporarily, selects the performance
governor, raises command priority, and uses CPU shielding when supported.
It deliberately leaves perf sampling controls alone so VTune keeps working.
EOF
}

parse_arguments() {
    if (( $# > 0 )); then
        case "$1" in
            install|verify|run)
                ACTION=$1
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
        esac
    fi

    if [[ "$ACTION" == run ]]; then
        [[ ${1:-} == -- ]] || die 'run requires -- before the command'
        shift
        (( $# > 0 )) || die 'run requires a command'
        RUN_COMMAND=("$@")
        return
    fi

    while (( $# > 0 )); do
        case "$1" in
            --skip-system-packages)
                [[ "$ACTION" == install ]] || die "$1 is valid only with install"
                SKIP_SYSTEM_PACKAGES=true
                ;;
            --skip-verify)
                [[ "$ACTION" == install ]] || die "$1 is valid only with install"
                SKIP_VERIFY=true
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
        shift
    done
}

select_privilege_command() {
    if (( EUID == 0 )); then
        ROOT_COMMAND=()
    elif command -v sudo >/dev/null 2>&1; then
        ROOT_COMMAND=(sudo)
    else
        die 'ReBench Denoise needs root or sudo to control CPU settings'
    fi
}

validate_host() {
    [[ $(uname -s) == Linux ]] || die 'ReBench Denoise requires Linux'
    [[ -r /sys/devices/system/cpu/online ]] || die 'Linux CPU topology is unavailable'
    CPU_COUNT=$(nproc)
    (( CPU_COUNT >= 2 )) || die 'Denoise requires at least two CPUs'
}

rebench_is_usable() {
    [[ -x "$DENOISE_COMMAND" && -x "$CSET_COMMAND" ]] || return 1
    "$DENOISE_COMMAND" --version 2>&1 | grep -Fq "$REBENCH_VERSION"
}

install_system_packages() {
    command -v dnf >/dev/null 2>&1 || \
        die 'Automatic package installation currently supports Rocky/RHEL-family Linux'
    "${ROOT_COMMAND[@]}" dnf -y install \
        git \
        python3 \
        python3-pip \
        python3-setuptools \
        python3-wheel \
        sudo \
        which
}

install_rebench() {
    local temporary_directory

    if rebench_is_usable; then
        task "ReBench $REBENCH_VERSION and cpuset are already installed"
        return
    fi

    mkdir -p "$TOOLS_DIRECTORY"
    temporary_directory=$(mktemp -d "$TOOLS_DIRECTORY/.rebench-install.XXXXXX")
    trap 'rm -rf -- "$temporary_directory"' RETURN

    python3 -m venv "$temporary_directory/rebench"
    "$temporary_directory/rebench/bin/python" -m pip install --upgrade pip
    "$temporary_directory/rebench/bin/python" -m pip install \
        "ReBench==$REBENCH_VERSION" \
        "git+https://github.com/SUSE/cpuset.git@$CPUSET_COMMIT"

    [[ -x "$temporary_directory/rebench/bin/rebench-denoise" ]] || \
        die 'The ReBench installation did not provide rebench-denoise'
    [[ -x "$temporary_directory/rebench/bin/cset" ]] || \
        die 'The cpuset installation did not provide cset'

    rm -rf -- "$REBENCH_ENVIRONMENT"
    mv -- "$temporary_directory/rebench" "$REBENCH_ENVIRONMENT"
    rebench_is_usable || die "ReBench $REBENCH_VERSION did not validate"

    rm -rf -- "$temporary_directory"
    trap - RETURN
}

read_cpu_state() {
    local no_turbo_file=/sys/devices/system/cpu/intel_pstate/no_turbo
    local governor_file=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

    INITIAL_NO_TURBO=''
    INITIAL_GOVERNOR=''
    [[ ! -r "$no_turbo_file" ]] || INITIAL_NO_TURBO=$(< "$no_turbo_file")
    [[ ! -r "$governor_file" ]] || INITIAL_GOVERNOR=$(< "$governor_file")
}

denoise_base_arguments() {
    DENOISE_ARGUMENTS=(
        --num-cores "$CPU_COUNT"
        --cset-path "$CSET_COMMAND"
        --without-min-perf-sampling
    )
}

restore_cpu_state() {
    local current_governor=''
    local current_no_turbo=''
    local restore_failed=false
    local -a restore_arguments

    denoise_base_arguments
    if [[ "$SHIELDING_ATTEMPTED" == true ]]; then
        if ! "${ROOT_COMMAND[@]}" "$DENOISE_COMMAND" \
            "${DENOISE_ARGUMENTS[@]}" \
            --without-no-turbo \
            --without-scaling-governor \
            --without-nice \
            restore >/dev/null 2>&1; then
            [[ "$SHIELDING_ENABLED" != true ]] || restore_failed=true
        fi
    fi

    restore_arguments=(
        "${DENOISE_ARGUMENTS[@]}"
        --without-shielding
        --without-nice
    )
    case "$INITIAL_NO_TURBO" in
        0) restore_arguments+=(--no-turbo false) ;;
        1) restore_arguments+=(--no-turbo true) ;;
        *) restore_arguments+=(--without-no-turbo) ;;
    esac
    case "$INITIAL_GOVERNOR" in
        performance|powersave) restore_arguments+=(--governor "$INITIAL_GOVERNOR") ;;
        *) restore_arguments+=(--without-scaling-governor) ;;
    esac

    if ! "${ROOT_COMMAND[@]}" "$DENOISE_COMMAND" \
        "${restore_arguments[@]}" minimize >/dev/null 2>&1; then
        restore_failed=true
    fi

    if [[ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        current_no_turbo=$(< /sys/devices/system/cpu/intel_pstate/no_turbo)
        [[ -z "$INITIAL_NO_TURBO" || "$current_no_turbo" == "$INITIAL_NO_TURBO" ]] || \
            restore_failed=true
    fi
    if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        current_governor=$(< /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
        [[ -z "$INITIAL_GOVERNOR" || "$current_governor" == "$INITIAL_GOVERNOR" ]] || \
            restore_failed=true
    fi

    if [[ "$restore_failed" == true ]]; then
        fail 'Could not restore every original CPU setting'
        return 1
    fi
}

stop_sudo_keepalive() {
    if [[ -n "$KEEPALIVE_PID" ]]; then
        kill "$KEEPALIVE_PID" >/dev/null 2>&1 || true
        wait "$KEEPALIVE_PID" >/dev/null 2>&1 || true
        KEEPALIVE_PID=''
    fi
}

cleanup() {
    local cleanup_status=0

    [[ "$CLEANED_UP" == false ]] || return 0
    CLEANED_UP=true
    set +e
    restore_cpu_state
    cleanup_status=$?
    stop_sudo_keepalive
    set -e
    return "$cleanup_status"
}

handle_signal() {
    local signal_number=$1
    exit "$((128 + signal_number))"
}

start_privileged_session() {
    select_privilege_command
    if (( EUID != 0 )); then
        sudo -v
        (
            while true; do
                sudo -n true >/dev/null 2>&1 || exit
                sleep 45
            done
        ) &
        KEEPALIVE_PID=$!
    fi
}

minimize_noise() {
    local output

    denoise_base_arguments
    SHIELDING_ATTEMPTED=true
    if output=$("${ROOT_COMMAND[@]}" "$DENOISE_COMMAND" \
        "${DENOISE_ARGUMENTS[@]}" \
        --no-turbo true \
        --governor performance \
        minimize 2>&1); then
        SHIELDING_ENABLED=true
        pass "Denoise active: Turbo off, performance governor, priority and CPU shielding"
        return
    fi

    printf '%s\n' "$output" >> "${GT_DETAILED_LOG:-/dev/null}"
    task 'CPU shielding is unavailable; continuing with the other Denoise controls'
    "${ROOT_COMMAND[@]}" "$DENOISE_COMMAND" \
        "${DENOISE_ARGUMENTS[@]}" \
        --without-shielding \
        --no-turbo true \
        --governor performance \
        minimize
    SHIELDING_ENABLED=false
    pass 'Denoise active: Turbo off, performance governor and raised priority'
}

append_environment_variable() {
    local variable_name=$1
    local -n destination=$2

    if [[ -v "$variable_name" ]]; then
        destination+=("$variable_name=${!variable_name}")
    fi
}

execute_denoised_command() {
    local run_user run_home status
    local -a command_prefix environment_arguments
    local variable_name

    run_user=${SUDO_USER:-$(id -un)}
    run_home=$(getent passwd "$run_user" | awk -F: '{print $6}')
    [[ -n "$run_home" ]] || run_home=${HOME:-$ECOSYSTEM_ROOT}

    environment_arguments=(
        "HOME=$run_home"
        "USER=$run_user"
        "LOGNAME=$run_user"
        "PATH=$PATH"
    )
    for variable_name in \
        LANG LC_ALL \
        GT_RUN_ROOT GT_PIPELINE_ROOT GT_RESULTS_ROOT GT_DETAILED_LOG \
        GT_REPORT_EVENTS GT_ECOSYSTEM_CONFIG GT_VERBOSE INDENT_LEVEL; do
        append_environment_variable "$variable_name" environment_arguments
    done

    if [[ "$run_user" == root ]]; then
        command_prefix=(/usr/bin/env "${environment_arguments[@]}")
    else
        command_prefix=(
            /usr/bin/sudo -u "$run_user"
            /usr/bin/env "${environment_arguments[@]}"
        )
    fi

    denoise_base_arguments
    [[ "$SHIELDING_ENABLED" == true ]] || DENOISE_ARGUMENTS+=(--without-shielding)

    if "${ROOT_COMMAND[@]}" "$DENOISE_COMMAND" \
        "${DENOISE_ARGUMENTS[@]}" \
        exec -- "${command_prefix[@]}" "${RUN_COMMAND[@]}"; then
        status=0
    else
        status=$?
    fi
    return "$status"
}

run_denoised() {
    local status

    CLEANED_UP=false
    SHIELDING_ATTEMPTED=false
    SHIELDING_ENABLED=false
    rebench_is_usable || \
        die "ReBench Denoise is missing; run $TESTS_DIR/Setup-Denoise.sh install"
    validate_host
    read_cpu_state
    start_privileged_session

    trap 'cleanup || true' EXIT
    trap 'handle_signal 2' INT
    trap 'handle_signal 15' TERM

    minimize_noise
    if execute_denoised_command; then
        status=0
    else
        status=$?
    fi

    if ! cleanup; then
        status=1
    fi
    trap - EXIT INT TERM
    if (( status == 0 )); then
        pass 'Original CPU settings restored'
    else
        task 'Measurement command failed; original CPU settings were restored where possible'
    fi
    return "$status"
}

verify_denoise() {
    local cgroup_mode='v1 or hybrid'
    local swap_used_kib=0

    rebench_is_usable || \
        die "ReBench Denoise is missing; run $TESTS_DIR/Setup-Denoise.sh install"
    validate_host

    if [[ -r /sys/fs/cgroup/cgroup.controllers ]]; then
        cgroup_mode=v2
    fi
    swap_used_kib=$(awk '/^SwapTotal:/ {total=$2} /^SwapFree:/ {free=$2} END {print total-free}' /proc/meminfo)

    task "ReBench $REBENCH_VERSION functional test"
    task "CPU count: $CPU_COUNT; cgroup mode: $cgroup_mode"
    if [[ "$cgroup_mode" == v2 ]]; then
        task 'ReBench cpuset shielding may be unavailable; automatic fallback will be used'
    fi
    if (( swap_used_kib > 0 )); then
        task "Swap is currently in use ($((swap_used_kib / 1024)) MiB); avoid memory pressure during measurements"
    fi

    RUN_COMMAND=(/usr/bin/true)
    run_denoised
    pass 'ReBench Denoise is ready'
}

main() {
    parse_arguments "$@"
    case "$ACTION" in
        install)
            validate_host
            select_privilege_command
            task 'Install ReBench Denoise'
            INDENT_LEVEL=$((INDENT_LEVEL + 1)); export INDENT_LEVEL
            if [[ "$SKIP_SYSTEM_PACKAGES" == false ]]; then
                run_step 'Install Python packaging dependencies' install_system_packages
            fi
            run_step "Install ReBench $REBENCH_VERSION and cpuset" install_rebench
            if [[ "$SKIP_VERIFY" == false ]]; then
                run_step 'Verify Denoise and CPU-state restoration' verify_denoise
            fi
            INDENT_LEVEL=$((INDENT_LEVEL - 1)); export INDENT_LEVEL
            pass 'ReBench Denoise setup complete'
            ;;
        verify)
            verify_denoise
            ;;
        run)
            run_denoised
            ;;
    esac
}

main "$@"
