#!/usr/bin/env bash

# One-time bootstrap for a clean Rocky Linux workstation.

set -Eeuo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ECOSYSTEM_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)

# shellcheck source=lib/common.sh
source "$TESTS_DIR/lib/common.sh"

readonly MX_VERSION=7.68.9
readonly JDK_FEATURE_VERSION=25
readonly VTUNE_PACKAGE_VERSION=2025.0.0-1129
readonly TOOLS_DIRECTORY="$TESTS_DIR/Tools"
readonly BOOT_JDK="$TOOLS_DIRECTORY/jdk-$JDK_FEATURE_VERSION"
readonly MX_DIRECTORY="$TOOLS_DIRECTORY/mx"
readonly BENCHMARKS_JAR="$TOOLS_DIRECTORY/benchmarks.jar"

SKIP_SYSTEM_PACKAGES=false
SKIP_VTUNE_SELF_CHECK=false
ROOT_COMMAND=()

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install and verify everything required by Compile-Build-Divine-Bubo.sh on
Rocky Linux. Run this once from any directory; it is safe to run again.

Options:
    --skip-system-packages    Do not use dnf or change system settings
    --skip-vtune-self-check   Skip the VTune hardware Hotspots check
    -h, --help                Show this help
EOF
}

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --skip-system-packages)
                SKIP_SYSTEM_PACKAGES=true
                ;;
            --skip-vtune-self-check)
                SKIP_VTUNE_SELF_CHECK=true
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
        die 'System package installation needs root or sudo'
    fi
}

validate_platform() {
    local distribution_id=''

    [[ $(uname -s) == Linux ]] || die 'This installer supports Linux only'
    [[ $(uname -m) == x86_64 ]] || \
        die 'The bundled async-profiler and JNI library require x86_64'

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        distribution_id=${ID:-}
    fi

    case "$distribution_id" in
        rocky|rhel|almalinux|centos)
            ;;
        *)
            die "Expected Rocky/RHEL-family Linux, found: ${distribution_id:-unknown}"
            ;;
    esac

    command -v dnf >/dev/null 2>&1 || die 'dnf is required'
}

install_system_packages() {
    local installed_vtune_version=''
    local repository_file=/etc/yum.repos.d/oneAPI.repo
    local repository_contents

    "${ROOT_COMMAND[@]}" dnf -y group install 'Development Tools'
    "${ROOT_COMMAND[@]}" dnf -y install \
        alsa-lib-devel \
        autoconf \
        bison \
        cmake \
        cups-devel \
        curl \
        file \
        flex \
        fontconfig-devel \
        freetype-devel \
        gcc \
        gcc-c++ \
        git \
        gzip \
        libffi-devel \
        libX11-devel \
        libXext-devel \
        libXi-devel \
        libXrandr-devel \
        libXrender-devel \
        libXt-devel \
        libXtst-devel \
        make \
        maven \
        ninja-build \
        perf \
        pkgconf-pkg-config \
        procps-ng \
        python3 \
        tar \
        unzip \
        which \
        xz \
        zip

    repository_contents=$'[oneAPI]\nname=Intel oneAPI repository\nbaseurl=https://yum.repos.intel.com/oneapi\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=https://yum.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB'

    if [[ ! -f "$repository_file" ]] || \
        ! grep -q 'yum.repos.intel.com/oneapi' "$repository_file"; then
        printf '%s\n' "$repository_contents" | \
            "${ROOT_COMMAND[@]}" tee "$repository_file" >/dev/null
    fi

    # VTune 2026.4 does not recognize the Kaby Lake processor used by the
    # experiment machine.  The checked-in successful experiment logs use
    # VTune 2025.0 for hardware Hotspots collection, so keep the setup
    # reproducible instead of silently installing the newest release.
    installed_vtune_version=$(rpm -q --qf '%{VERSION}-%{RELEASE}\n' \
        intel-oneapi-vtune 2>/dev/null || true)
    if [[ "$installed_vtune_version" == "$VTUNE_PACKAGE_VERSION" ]]; then
        task "VTune package $VTUNE_PACKAGE_VERSION is already installed"
    elif [[ -n "$installed_vtune_version" ]]; then
        "${ROOT_COMMAND[@]}" dnf -y downgrade \
            "intel-oneapi-vtune-$VTUNE_PACKAGE_VERSION"
    else
        "${ROOT_COMMAND[@]}" dnf -y install \
            "intel-oneapi-vtune-$VTUNE_PACKAGE_VERSION"
    fi

    rpm -q --qf '%{VERSION}-%{RELEASE}\n' intel-oneapi-vtune | \
        grep -Fxq "$VTUNE_PACKAGE_VERSION" || \
        die "VTune package $VTUNE_PACKAGE_VERSION was not installed"

    printf '%s\n' 'kernel.perf_event_paranoid = 0' | \
        "${ROOT_COMMAND[@]}" tee \
            /etc/sysctl.d/99-gt-ecosystem-vtune.conf >/dev/null
    "${ROOT_COMMAND[@]}" sysctl --system
}

initialise_repositories() {
    (
        cd "$ECOSYSTEM_ROOT"
        git submodule sync
        # Deliberately not recursive: BuboExperiments contains an unused,
        # incompletely declared Capstone gitlink.
        git submodule update --init --checkout --jobs "$(nproc)"
    )
}

jdk_is_usable() {
    [[ -x "$BOOT_JDK/bin/java" ]] || return 1
    [[ -x "$BOOT_JDK/bin/javac" ]] || return 1
    [[ -x "$BOOT_JDK/bin/jar" ]] || return 1
    "$BOOT_JDK/bin/java" -version 2>&1 | \
        grep -Eq 'version "25([.+"]|$)'
}

install_boot_jdk() {
    local archive
    local checksum
    local download_url
    local extracted_directory
    local -a metadata=()
    local temporary_directory

    if jdk_is_usable; then
        task "Temurin JDK $JDK_FEATURE_VERSION is already installed"
        return 0
    fi

    temporary_directory=$(mktemp -d "$TOOLS_DIRECTORY/.jdk-install.XXXXXX")
    trap 'rm -rf -- "$temporary_directory"' RETURN

    mapfile -t metadata < <(
        curl --fail --silent --show-error --retry 3 \
            "https://api.adoptium.net/v3/assets/latest/$JDK_FEATURE_VERSION/hotspot?architecture=x64&image_type=jdk&os=linux&vendor=eclipse" |
            python3 -c '
import json
import sys

for release in json.load(sys.stdin):
    package = release.get("binary", {}).get("package", {})
    if package.get("name", "").endswith(".tar.gz"):
        print(package["link"])
        print(package["checksum"])
        break
'
    )
    (( ${#metadata[@]} == 2 )) || die 'Could not resolve the Temurin JDK download'
    download_url=${metadata[0]}
    checksum=${metadata[1]}

    curl --fail --location --retry 3 \
        --output "$temporary_directory/jdk.tar.gz" \
        "$download_url"
    archive="$temporary_directory/jdk.tar.gz"
    printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check --status || \
        die 'Temurin JDK checksum validation failed'
    tar -xzf "$archive" -C "$temporary_directory"

    extracted_directory=$(find "$temporary_directory" \
        -mindepth 1 -maxdepth 1 -type d -name 'jdk-*' -print -quit)
    [[ -n "$extracted_directory" ]] || die 'Downloaded JDK archive had no JDK directory'

    rm -rf -- "$BOOT_JDK"
    mv -- "$extracted_directory" "$BOOT_JDK"
    jdk_is_usable || die "Installed JDK $JDK_FEATURE_VERSION did not validate"

    rm -rf -- "$temporary_directory"
    trap - RETURN
}

mx_is_usable() {
    [[ -x "$MX_DIRECTORY/mx" ]] || return 1
    "$MX_DIRECTORY/mx" --version 2>&1 | grep -Fq "$MX_VERSION"
}

install_mx() {
    local temporary_directory

    if mx_is_usable; then
        task "mx $MX_VERSION is already installed"
        return 0
    fi

    temporary_directory=$(mktemp -d "$TOOLS_DIRECTORY/.mx-install.XXXXXX")
    trap 'rm -rf -- "$temporary_directory"' RETURN

    git clone --depth 1 --branch "$MX_VERSION" \
        https://github.com/graalvm/mx.git \
        "$temporary_directory/mx"

    rm -rf -- "$MX_DIRECTORY"
    mv -- "$temporary_directory/mx" "$MX_DIRECTORY"
    mx_is_usable || die "Installed mx did not report version $MX_VERSION"

    rm -rf -- "$temporary_directory"
    trap - RETURN
}

build_benchmarks_jar() {
    local awfy_source="$ECOSYSTEM_ROOT/repos/are-we-fast-yet/benchmarks/Java/src"
    local temporary_directory

    require_file "$awfy_source/Run.java" 'AWFY benchmark runner source'
    require_file "$awfy_source/tsc.c" 'AWFY TSC JNI source'

    temporary_directory=$(mktemp -d "$TOOLS_DIRECTORY/.benchmarks-build.XXXXXX")
    trap 'rm -rf -- "$temporary_directory"' RETURN

    mkdir -p \
        "$temporary_directory/classes" \
        "$temporary_directory/native/linux-x86_64"

    find "$awfy_source" -type f -name '*.java' -print0 | \
        sort -z > "$temporary_directory/sources.list"

    xargs -0 "$BOOT_JDK/bin/javac" \
        -g \
        -d "$temporary_directory/classes" \
        < "$temporary_directory/sources.list"

    gcc -shared -fPIC \
        -I"$BOOT_JDK/include" \
        -I"$BOOT_JDK/include/linux" \
        "$awfy_source/tsc.c" \
        -o "$temporary_directory/native/linux-x86_64/libtsc.so"

    "$BOOT_JDK/bin/jar" --create \
        --file "$temporary_directory/benchmarks.jar" \
        -C "$temporary_directory/classes" . \
        -C "$temporary_directory/native" .

    mv -- "$temporary_directory/benchmarks.jar" "$BENCHMARKS_JAR"
    rm -rf -- "$temporary_directory"
    trap - RETURN
}

run_vtune_self_check() {
    local result_directory
    local temporary_directory
    local vtune_command=/opt/intel/oneapi/vtune/latest/bin64/vtune

    require_executable "$vtune_command" 'VTune command'
    require_command perf

    # Confirm the Linux perf subsystem can read the counters VTune needs.
    perf stat -e cycles,instructions -- \
        python3 -c 'sum(i*i for i in range(5000000))' >/dev/null

    temporary_directory=$(mktemp -d "$TOOLS_DIRECTORY/.vtune-check.XXXXXX")
    result_directory="$temporary_directory/result"
    trap 'rm -rf -- "$temporary_directory"' RETURN

    # Intel's general self-checker also tests GPU, uncore, and newer CPU
    # analyses that this pipeline never uses.  Test the exact collection mode
    # used by GTSlowdownSchedular instead.
    "$vtune_command" \
        -collect hotspots \
        -knob sampling-mode=hw \
        -knob enable-stack-collection=false \
        -result-dir "$result_directory" \
        -- python3 -c 'sum(i*i for i in range(15000000))'

    rm -rf -- "$temporary_directory"
    trap - RETURN
}

main() {
    parse_arguments "$@"
    mkdir -p "$TOOLS_DIRECTORY"

    task 'Bootstrap the GT ecosystem'
    INDENT_LEVEL=$((INDENT_LEVEL + 1))
    export INDENT_LEVEL

    if [[ "$SKIP_SYSTEM_PACKAGES" == false ]]; then
        run_step 'Validate the Rocky Linux host' validate_platform
        run_step 'Select root privileges' select_privilege_command
        run_step 'Install compiler, build, Maven, and VTune packages' \
            install_system_packages
    fi

    run_step 'Initialize the top-level ecosystem repositories' \
        initialise_repositories
    run_step "Install Temurin JDK $JDK_FEATURE_VERSION" install_boot_jdk
    run_step "Install mx $MX_VERSION" install_mx
    run_step 'Build the AWFY benchmark JAR and TSC JNI library' \
        build_benchmarks_jar

    if [[ "$SKIP_VTUNE_SELF_CHECK" == false ]]; then
        run_step 'Verify VTune hardware Hotspots collection' run_vtune_self_check
    fi

    run_step 'Verify the complete machine setup' \
        "$TESTS_DIR/Verify-Dependencies.sh"

    INDENT_LEVEL=$((INDENT_LEVEL - 1))
    export INDENT_LEVEL
    pass 'Setup complete; Compile-Build-Divine-Bubo.sh is ready to run'
}

main "$@"
