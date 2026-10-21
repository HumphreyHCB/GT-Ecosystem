#!/usr/bin/env bash

# Install, verify, and run commands with ReBench Denoise on Rocky Linux.

set -Eeuo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ECOSYSTEM_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)

# shellcheck source=lib/common.sh
source "$TESTS_DIR/lib/common.sh"

readonly REBENCH_INSTALL_SPEC='git+https://github.com/smarr/ReBench.git@master'
readonly CPUSET_COMMIT=db68d6daae07d12c38d7cf7375cf843ced0f6792
readonly TOOLS_DIRECTORY="$TESTS_DIR/Tools"
readonly REBENCH_ENVIRONMENT="$TOOLS_DIRECTORY/rebench"
readonly DENOISE_COMMAND="$REBENCH_ENVIRONMENT/bin/rebench-denoise"
readonly CSET_COMMAND="$REBENCH_ENVIRONMENT/bin/cset"
readonly SYSTEM_PYTHON=/usr/bin/python3

ACTION=install
SKIP_SYSTEM_PACKAGES=false
SKIP_VERIFY=false
ROOT_COMMAND=()
RUN_COMMAND=()
DENOISE_ARGUMENTS=()
CPU_COUNT=0
SHIELDED_CORE_SET=''
INITIAL_NO_TURBO=''
GOVERNOR_PATHS=()
INITIAL_GOVERNORS=()
PERF_PATHS=(
    /proc/sys/kernel/perf_event_paranoid
    /proc/sys/kernel/perf_cpu_time_max_percent
    /proc/sys/kernel/perf_event_max_sample_rate
)
INITIAL_PERF_VALUES=()
SHIELDING_ATTEMPTED=false
SHIELDING_ENABLED=false
CLEANED_UP=false

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [install] [OPTIONS]
       $(basename "$0") verify
       $(basename "$0") run -- COMMAND [ARGUMENT ...]

Commands:
    install                 Install ReBench development source and cpuset
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
    local cset_help denoise_help

    [[ -x "$DENOISE_COMMAND" && -x "$CSET_COMMAND" ]] || return 1
    "$REBENCH_ENVIRONMENT/bin/python" -c '
from importlib.metadata import version
version("ReBench")
' >/dev/null 2>&1 || return 1
    denoise_help=$("$DENOISE_COMMAND" --help 2>&1) || return 1
    cset_help=$("$CSET_COMMAND" --help 2>&1) || return 1
    grep -Fq -- '--num-cores' <<< "$denoise_help" || return 1
    grep -Fq -- '--cset-path' <<< "$denoise_help" || return 1
    grep -Fq -- '--without-shielding' <<< "$denoise_help" || return 1
    grep -Eq '(^|[|`[:space:]])exec([|`[:space:]]|$)' <<< "$denoise_help" || return 1
    grep -Fq 'shield' <<< "$cset_help" || return 1
}

rebench_is_development_install() {
    "$REBENCH_ENVIRONMENT/bin/python" -c '
from importlib.metadata import distribution
import json
import sys

metadata = distribution("ReBench").read_text("direct_url.json")
if not metadata:
    sys.exit(1)
url = json.loads(metadata).get("url", "").rstrip("/")
if url.endswith(".git"):
    url = url[:-4]
sys.exit(0 if url == "https://github.com/smarr/ReBench" else 1)
'
}

installed_rebench_version() {
    "$REBENCH_ENVIRONMENT/bin/python" -c \
        'from importlib.metadata import version; print(version("ReBench"))'
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
    if rebench_is_usable && rebench_is_development_install; then
        task "ReBench development source ($(installed_rebench_version)) and cpuset are already installed"
        return
    fi

    require_executable "$SYSTEM_PYTHON" 'System Python'
    mkdir -p "$TOOLS_DIRECTORY"

    # Virtual environments contain absolute interpreter paths in their command
    # launchers and cannot safely be moved after installation.  Also avoid the
    # old ReBench environment that common.sh adds to PATH: using it to create
    # its replacement can produce a self-referential python symlink.
    rm -rf -- "$REBENCH_ENVIRONMENT"
    "$SYSTEM_PYTHON" -m venv "$REBENCH_ENVIRONMENT"
    "$REBENCH_ENVIRONMENT/bin/python" -m pip install --upgrade pip
    "$REBENCH_ENVIRONMENT/bin/python" -m pip install \
        "$REBENCH_INSTALL_SPEC" \
        "git+https://github.com/SUSE/cpuset.git@$CPUSET_COMMIT"

    [[ -x "$DENOISE_COMMAND" ]] || \
        die 'The ReBench installation did not provide rebench-denoise'
    [[ -x "$CSET_COMMAND" ]] || \
        die 'The cpuset installation did not provide cset'

    rebench_is_usable || die 'The ReBench package or Denoise commands did not validate'
    rebench_is_development_install || die 'ReBench was not installed from the development repository'
}

read_cpu_state() {
    local no_turbo_file=/sys/devices/system/cpu/intel_pstate/no_turbo
    local path

    INITIAL_NO_TURBO=''
    GOVERNOR_PATHS=()
    INITIAL_GOVERNORS=()
    INITIAL_PERF_VALUES=()
    [[ ! -r "$no_turbo_file" ]] || INITIAL_NO_TURBO=$(< "$no_turbo_file")

    # cpuN/cpufreq is normally a symlink to cpufreq/policyN.  `find` does not
    # follow those links by default, so inspect the real policy files first.
    for path in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
        [[ -r "$path" ]] || continue
        GOVERNOR_PATHS+=("$path")
        INITIAL_GOVERNORS+=("$(< "$path")")
    done

    # Older kernels may expose only the per-CPU symlink layout.
    if (( ${#GOVERNOR_PATHS[@]} == 0 )); then
        for path in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
            [[ -r "$path" ]] || continue
            GOVERNOR_PATHS+=("$path")
            INITIAL_GOVERNORS+=("$(< "$path")")
        done
    fi

    for path in "${PERF_PATHS[@]}"; do
        if [[ -r "$path" ]]; then
            INITIAL_PERF_VALUES+=("$(< "$path")")
        else
            INITIAL_PERF_VALUES+=('')
        fi
    done
}

denoise_base_arguments() {
    DENOISE_ARGUMENTS=(
        --num-cores "$CPU_COUNT"
        --cset-path "$CSET_COMMAND"
    )
}

write_privileged_file() {
    local path=$1
    local value=$2

    printf '%s\n' "$value" | "${ROOT_COMMAND[@]}" tee "$path" >/dev/null
}

set_measurement_cpu_state() {
    local path

    [[ -n "$INITIAL_NO_TURBO" ]] || \
        die 'Intel Turbo control is unavailable; refusing an incompletely controlled measurement'
    (( ${#GOVERNOR_PATHS[@]} > 0 )) || \
        die 'CPU frequency governors are unavailable'

    write_privileged_file /sys/devices/system/cpu/intel_pstate/no_turbo 1
    for path in "${GOVERNOR_PATHS[@]}"; do
        write_privileged_file "$path" performance
    done
}

restore_cpu_state() {
    local current_value=''
    local current_no_turbo=''
    local index path
    local restore_failed=false

    if [[ "$SHIELDING_ATTEMPTED" == true ]]; then
        if ! "${ROOT_COMMAND[@]}" "$CSET_COMMAND" shield -r \
            >/dev/null 2>&1; then
            [[ "$SHIELDING_ENABLED" != true ]] || restore_failed=true
        fi
    fi

    [[ -z "$INITIAL_NO_TURBO" ]] || \
        write_privileged_file \
            /sys/devices/system/cpu/intel_pstate/no_turbo \
            "$INITIAL_NO_TURBO" || restore_failed=true

    for index in "${!GOVERNOR_PATHS[@]}"; do
        write_privileged_file \
            "${GOVERNOR_PATHS[$index]}" \
            "${INITIAL_GOVERNORS[$index]}" || restore_failed=true
    done
    for index in "${!PERF_PATHS[@]}"; do
        [[ -z "${INITIAL_PERF_VALUES[$index]}" ]] || \
            write_privileged_file \
                "${PERF_PATHS[$index]}" \
                "${INITIAL_PERF_VALUES[$index]}" || restore_failed=true
    done

    if [[ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        current_no_turbo=$(< /sys/devices/system/cpu/intel_pstate/no_turbo)
        [[ -z "$INITIAL_NO_TURBO" || "$current_no_turbo" == "$INITIAL_NO_TURBO" ]] || \
            restore_failed=true
    fi
    for index in "${!GOVERNOR_PATHS[@]}"; do
        path=${GOVERNOR_PATHS[$index]}
        current_value=$(< "$path")
        [[ "$current_value" == "${INITIAL_GOVERNORS[$index]}" ]] || restore_failed=true
    done
    for index in "${!PERF_PATHS[@]}"; do
        path=${PERF_PATHS[$index]}
        [[ -z "${INITIAL_PERF_VALUES[$index]}" ]] && continue
        current_value=$(< "$path")
        [[ "$current_value" == "${INITIAL_PERF_VALUES[$index]}" ]] || restore_failed=true
    done

    if [[ "$restore_failed" == true ]]; then
        fail 'Could not restore every original CPU setting'
        return 1
    fi
}

cleanup() {
    local cleanup_status=0

    [[ "$CLEANED_UP" == false ]] || return 0
    CLEANED_UP=true
    set +e
    restore_cpu_state
    cleanup_status=$?
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
    fi
}

prepare_denoised_state() {
    local output

    set_measurement_cpu_state
    SHIELDING_ATTEMPTED=true
    if output=$("${ROOT_COMMAND[@]}" "$CSET_COMMAND" \
        shield -c "$SHIELDED_CORE_SET" -k on 2>&1); then
        SHIELDING_ENABLED=true
        pass "Denoise active: Turbo off, performance governor, priority and CPU shielding"
        return
    fi

    printf '%s\n' "$output" >> "${GT_DETAILED_LOG:-/dev/null}"
    task 'CPU shielding is unavailable; continuing with the other Denoise controls'
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
        GT_REPORT_EVENTS GT_ECOSYSTEM_CONFIG GT_VERBOSE GT_USE_DENOISE \
        INDENT_LEVEL; do
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
    SHIELDED_CORE_SET=$("$REBENCH_ENVIRONMENT/bin/python" -c '
from math import floor, log
import sys
cores = int(sys.argv[1])
print(f"{floor(log(cores))}-{cores - 1}")
' "$CPU_COUNT")
    read_cpu_state
    start_privileged_session

    trap 'cleanup || true' EXIT
    trap 'handle_signal 2' INT
    trap 'handle_signal 15' TERM

    prepare_denoised_state
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

    task "ReBench development build $(installed_rebench_version) functional test"
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
            start_privileged_session
            task 'Install ReBench Denoise'
            INDENT_LEVEL=$((INDENT_LEVEL + 1)); export INDENT_LEVEL
            if [[ "$SKIP_SYSTEM_PACKAGES" == false ]]; then
                run_step 'Install Python packaging dependencies' install_system_packages
            fi
            run_step 'Install ReBench development source and cpuset' install_rebench
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
