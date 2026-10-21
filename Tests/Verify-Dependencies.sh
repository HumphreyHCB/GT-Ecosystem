#!/usr/bin/env bash

# Fast, non-mutating preflight for the GT ecosystem build and test pipeline.

set -Eeuo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ECOSYSTEM_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)

# shellcheck source=lib/common.sh
source "$TESTS_DIR/lib/common.sh"

readonly EXPECTED_MX_VERSION=7.68.9
readonly EXPECTED_VTUNE_VERSION=2025.0
readonly CONFIG_FILE=${GT_ECOSYSTEM_CONFIG:-"$TESTS_DIR/config.config"}

PIPELINE_MODE=false
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0

BOOT_JDK=''
LABS_OPENJDK=''
SCHEDULER_REPOSITORY=''
BUBO_EXPERIMENTS=''
GRAAL_REPOSITORY=''
AWFY_SOURCE=''
BENCHMARKS_JAR=''
ASYNC_PROFILER_LIBRARY=''

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [--pipeline]

Check the host, repositories, tools, generated benchmark JAR, and VTune
configuration without changing anything. --pipeline uses compact output.
EOF
}

check_pass() {
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    [[ "$PIPELINE_MODE" == true ]] || pass "$1"
}

check_fail() {
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fail "$1"
}

check_warn() {
    CHECKS_WARNED=$((CHECKS_WARNED + 1))
    printf '⚠ %s\n' "$1" >&2
}

check_command() {
    local command_name=$1

    if command -v "$command_name" >/dev/null 2>&1; then
        check_pass "Command available: $command_name"
    else
        check_fail "Missing command: $command_name"
    fi
}

check_file() {
    local path=$1
    local description=$2

    if [[ -f "$path" ]]; then
        check_pass "$description"
    else
        check_fail "$description is missing: $path"
    fi
}

check_executable() {
    local path=$1
    local description=$2

    if [[ -x "$path" ]]; then
        check_pass "$description"
    else
        check_fail "$description is missing or not executable: $path"
    fi
}

load_configuration() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        check_fail "Configuration is missing: $CONFIG_FILE"
        return 1
    fi

    require_config_value BOOT_JDK "$CONFIG_FILE" Dir FallbackJavaBuild
    require_config_value LABS_OPENJDK "$CONFIG_FILE" Dir LabsOpenJDK
    require_config_value SCHEDULER_REPOSITORY "$CONFIG_FILE" Dir GTSlowdownSchedular
    require_config_value BUBO_EXPERIMENTS "$CONFIG_FILE" Dir BuboExperiments
    require_config_value GRAAL_REPOSITORY "$CONFIG_FILE" Dir Graal
    require_config_value AWFY_SOURCE "$CONFIG_FILE" Dir AWFYSource
    require_config_value BENCHMARKS_JAR "$CONFIG_FILE" Dir AWFYBenchmarksJar
    require_config_value ASYNC_PROFILER_LIBRARY "$CONFIG_FILE" Dir AsyncProfilerLibrary
    check_pass 'Configuration loaded'
}

check_platform() {
    local architecture
    local cpu_vendor='unknown'
    local kptr_restrict=''
    local paranoid=''

    architecture=$(uname -m)
    if [[ $(uname -s) == Linux && "$architecture" == x86_64 ]]; then
        check_pass 'Linux x86_64 host'
    else
        check_fail "Expected Linux x86_64, found $(uname -s) $architecture"
    fi

    if [[ -r /proc/cpuinfo ]]; then
        cpu_vendor=$(awk -F: '/vendor_id/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo)
    fi
    if [[ "$cpu_vendor" == GenuineIntel ]]; then
        check_pass 'Intel CPU detected'
    else
        check_warn "CPU vendor is $cpu_vendor; VTune hardware analyses may be unavailable"
    fi

    if [[ -r /proc/sys/kernel/perf_event_paranoid ]]; then
        paranoid=$(< /proc/sys/kernel/perf_event_paranoid)
        if [[ "$paranoid" =~ ^-?[0-9]+$ ]] && (( paranoid <= 1 )); then
            check_pass "VTune perf access is enabled (perf_event_paranoid=$paranoid)"
        else
            check_fail "kernel.perf_event_paranoid must be 1 or lower; found ${paranoid:-unknown}"
        fi
    else
        check_fail 'Cannot read kernel.perf_event_paranoid'
    fi

    if [[ -r /proc/sys/kernel/kptr_restrict ]]; then
        kptr_restrict=$(< /proc/sys/kernel/kptr_restrict)
        if [[ "$kptr_restrict" == 0 ]]; then
            check_pass 'Kernel symbols are available to VTune (kptr_restrict=0)'
        else
            check_fail "kernel.kptr_restrict must be 0; found ${kptr_restrict:-unknown}"
        fi
    else
        check_fail 'Cannot read kernel.kptr_restrict'
    fi

    if command -v perf >/dev/null 2>&1; then
        if perf stat -e cycles,instructions -- \
            python3 -c 'sum(i*i for i in range(1000000))' \
            >/dev/null 2>&1; then
            check_pass 'Hardware cycles and instructions counters are readable'
        else
            check_fail 'Linux perf cannot read hardware cycles and instructions counters'
        fi
    fi
}

check_capacity() {
    local available_disk_kib
    local available_memory_kib
    local cpu_count
    local minimum_disk_gib=${GT_MIN_DISK_GIB:-30}
    local minimum_memory_gib=${GT_MIN_MEMORY_GIB:-16}

    available_memory_kib=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
    if [[ "$available_memory_kib" =~ ^[0-9]+$ ]] && \
        (( available_memory_kib >= minimum_memory_gib * 1024 * 1024 )); then
        check_pass "At least ${minimum_memory_gib} GiB RAM available"
    else
        check_warn "Less than ${minimum_memory_gib} GiB RAM available; the 12 GiB benchmark heap may cause swapping"
    fi

    available_disk_kib=$(df -Pk "$ECOSYSTEM_ROOT" | awk 'NR == 2 {print $4}')
    if [[ "$available_disk_kib" =~ ^[0-9]+$ ]] && \
        (( available_disk_kib >= minimum_disk_gib * 1024 * 1024 )); then
        check_pass "At least ${minimum_disk_gib} GiB free disk space available"
    else
        check_fail "At least ${minimum_disk_gib} GiB free disk space is required for OpenJDK and Graal builds"
    fi

    cpu_count=$(nproc 2>/dev/null || printf '1')
    if (( cpu_count >= 4 )); then
        check_pass 'At least four build CPUs available'
    else
        check_warn "Only $cpu_count build CPU(s) detected; compilation will be slow"
    fi
}

check_commands() {
    local command_name
    local -a commands=(
        autoconf awk bash cmake curl df diff file find gcc g++ git grep ldd make
        ninja nproc perf pkg-config python3 readelf realpath sed sha256sum sort
        tar unzip wget which xargs zip
    )

    for command_name in "${commands[@]}"; do
        check_command "$command_name"
    done
}

check_repository() {
    local path=$1
    local description=$2
    local repository_root=''

    if [[ ! -d "$path" ]]; then
        check_fail "$description is missing: $path"
        return
    fi

    repository_root=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)
    if [[ -n "$repository_root" ]] && \
        [[ $(realpath -m -- "$repository_root") == $(realpath -m -- "$path") ]]; then
        check_pass "$description initialized"
    else
        check_fail "$description is not an initialized Git repository: $path"
    fi
}

check_repositories() {
    check_repository "$LABS_OPENJDK" 'Labs OpenJDK submodule'
    check_repository "$SCHEDULER_REPOSITORY" 'GTSlowdownSchedular submodule'
    check_repository "$BUBO_EXPERIMENTS" 'BuboExperiments submodule'
    check_repository "$GRAAL_REPOSITORY" 'graal-instrumentation submodule'
    check_repository "$(dirname "$(dirname "$(dirname "$AWFY_SOURCE")")")" \
        'are-we-fast-yet submodule'
}

check_jdk_and_mx() {
    local java_version=''
    local mx_version=''

    check_executable "$BOOT_JDK/bin/java" 'Boot JDK java'
    check_executable "$BOOT_JDK/bin/javac" 'Boot JDK javac'
    check_executable "$BOOT_JDK/bin/jar" 'Boot JDK jar'

    if [[ -x "$BOOT_JDK/bin/java" ]]; then
        java_version=$("$BOOT_JDK/bin/java" -version 2>&1 | head -1)
        if grep -Eq 'version "25([.+"]|$)' <<< "$java_version"; then
            check_pass "Boot JDK major version is 25: $java_version"
        else
            check_fail "Boot JDK must be version 25; found: $java_version"
        fi
    fi

    if command -v mx >/dev/null 2>&1; then
        mx_version=$(mx --version 2>&1 | head -1)
        if grep -Fq "$EXPECTED_MX_VERSION" <<< "$mx_version"; then
            check_pass "mx version is $EXPECTED_MX_VERSION"
        else
            check_fail "mx must be $EXPECTED_MX_VERSION; found: $mx_version"
        fi
    else
        check_fail 'mx is not available on PATH'
    fi
}

check_vtune() {
    local vtune_command=''
    local vtune_version=''

    vtune_command=$(command -v vtune 2>/dev/null || true)
    if [[ -n "$vtune_command" ]]; then
        check_pass "VTune command available: $vtune_command"
        if vtune_version=$(vtune -version 2>&1); then
            if grep -Fq "VTune(TM) Profiler $EXPECTED_VTUNE_VERSION" \
                <<< "$vtune_version"; then
                check_pass "VTune $EXPECTED_VTUNE_VERSION starts successfully"
            else
                check_fail "VTune $EXPECTED_VTUNE_VERSION is required; found: $(head -1 <<< "$vtune_version")"
            fi
        else
            check_fail 'VTune is installed but does not start successfully'
        fi
    else
        check_fail 'VTune is not available on PATH'
    fi
}

check_generated_files() {
    local jar_listing=''
    local missing_libraries=''

    check_file "$AWFY_SOURCE/Run.java" 'AWFY benchmark sources'
    check_file "$ASYNC_PROFILER_LIBRARY" 'Async-profiler native library'
    check_file "$BENCHMARKS_JAR" 'Generated AWFY benchmark JAR'

    if [[ -f "$ASYNC_PROFILER_LIBRARY" ]] && command -v ldd >/dev/null 2>&1; then
        missing_libraries=$(ldd "$ASYNC_PROFILER_LIBRARY" 2>&1 | grep 'not found' || true)
        if [[ -z "$missing_libraries" ]]; then
            check_pass 'Async-profiler native dependencies resolve'
        else
            check_fail "Async-profiler has unresolved libraries: $missing_libraries"
        fi
    fi

    if [[ -f "$BENCHMARKS_JAR" && -x "$BOOT_JDK/bin/jar" ]]; then
        jar_listing=$("$BOOT_JDK/bin/jar" tf "$BENCHMARKS_JAR" 2>/dev/null || true)
        if grep -Fxq 'Run.class' <<< "$jar_listing"; then
            check_pass 'Benchmark JAR contains Run.class'
        else
            check_fail 'Benchmark JAR does not contain Run.class'
        fi
        if grep -Fxq 'linux-x86_64/libtsc.so' <<< "$jar_listing"; then
            check_pass 'Benchmark JAR contains the TSC JNI library'
        else
            check_fail 'Benchmark JAR does not contain linux-x86_64/libtsc.so'
        fi
    fi
}

main() {
    if (( $# > 1 )); then
        show_usage >&2
        exit 2
    fi
    if (( $# == 1 )); then
        case "$1" in
            --pipeline) PIPELINE_MODE=true ;;
            -h|--help) show_usage; exit 0 ;;
            *) show_usage >&2; exit 2 ;;
        esac
    fi

    task 'Verify GT ecosystem dependencies'
    load_configuration || true
    check_platform
    check_capacity
    check_commands

    if [[ -n "$BOOT_JDK" ]]; then
        check_repositories
        check_jdk_and_mx
        check_vtune
        check_generated_files
    fi

    printf '\nDependency checks: %d passed, %d warnings, %d failed\n' \
        "$CHECKS_PASSED" "$CHECKS_WARNED" "$CHECKS_FAILED"

    if (( CHECKS_FAILED > 0 )); then
        printf 'Run %s to install or repair the setup.\n' \
            "$TESTS_DIR/Install-Dependencies.sh" >&2
        exit 1
    fi

    pass 'GT ecosystem dependencies are ready'
}

main "$@"
