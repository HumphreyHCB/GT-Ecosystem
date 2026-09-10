#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TESTS_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

# shellcheck source=../lib/common.sh
source "$TESTS_DIR/lib/common.sh"

CONFIG_FILE=${GT_ECOSYSTEM_CONFIG:-"$TESTS_DIR/config.config"}
OPENJDK_CONF=''
JOBS=''

load_configuration() {
    require_file "$CONFIG_FILE" 'Ecosystem configuration'
    require_config_value BOOT_JDK "$CONFIG_FILE" Dir FallbackJavaBuild
    require_config_value LABS_OPENJDK "$CONFIG_FILE" Dir LabsOpenJDK
    JOBS=${GT_BUILD_JOBS:-$(nproc)}
}

validate_inputs() {
    require_directory "$BOOT_JDK" 'Boot JDK'
    require_executable "$BOOT_JDK/bin/java" 'Boot JDK java'
    require_directory "$LABS_OPENJDK" 'Labs OpenJDK source'
    require_file "$LABS_OPENJDK/configure" 'Labs OpenJDK configure script'
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "Build job count must be a positive integer: $JOBS"
}

configure_openjdk_if_needed() {
    local existing_spec

    existing_spec=$(find "$LABS_OPENJDK/build" -mindepth 2 -maxdepth 2 \
        -name spec.gmk -print -quit 2>/dev/null || true)

    if [[ -n "$existing_spec" ]]; then
        task 'An existing OpenJDK configuration was found; configure is not required'
        return 0
    fi

    (
        cd "$LABS_OPENJDK"
        bash configure \
            --with-boot-jdk="$BOOT_JDK" \
            --with-debug-level=release \
            --disable-warnings-as-errors
    )
}

select_openjdk_configuration() {
    local -a configuration_directories=()
    local spec_file

    while IFS= read -r spec_file; do
        configuration_directories+=("$(dirname "$spec_file")")
    done < <(find "$LABS_OPENJDK/build" -mindepth 2 -maxdepth 2 \
        -name spec.gmk -print 2>/dev/null | sort)

    if (( ${#configuration_directories[@]} == 0 )); then
        die "No configured OpenJDK build was found under $LABS_OPENJDK/build"
    fi

    if (( ${#configuration_directories[@]} > 1 )); then
        fail 'More than one configured OpenJDK build was found:'
        for directory in "${configuration_directories[@]}"; do
            fail "    $(basename "$directory")"
        done
        die 'Remove the unwanted build configuration or perform a full rebuild'
    fi

    OPENJDK_CONF=$(basename "${configuration_directories[0]}")
    task "Using OpenJDK configuration: $OPENJDK_CONF"
}

build_openjdk_images() {
    (
        cd "$LABS_OPENJDK"
        make images CONF="$OPENJDK_CONF" JOBS="$JOBS"
        make graal-builder-image CONF="$OPENJDK_CONF" JOBS="$JOBS"
    )
}

verify_openjdk_build() {
    local images_directory="$LABS_OPENJDK/build/$OPENJDK_CONF/images"
    local jdk_directory="$images_directory/jdk"
    local graal_builder_directory="$images_directory/graal-builder-jdk"

    require_executable "$jdk_directory/bin/java" 'Built OpenJDK java'
    require_executable "$jdk_directory/bin/javac" 'Built OpenJDK javac'
    require_executable "$graal_builder_directory/bin/java" 'Graal builder JDK java'

    "$jdk_directory/bin/java" -version
    "$jdk_directory/bin/javac" -version
    "$graal_builder_directory/bin/java" -version
}

main() {
    task 'Compile OpenJDK with compiler markers'
    INDENT_LEVEL=$((INDENT_LEVEL + 1))

    run_step 'Load build configuration' load_configuration
    run_step 'Validate OpenJDK inputs' validate_inputs
    run_step 'Configure OpenJDK when required' configure_openjdk_if_needed
    run_step 'Select the OpenJDK build configuration' select_openjdk_configuration
    run_step "Build OpenJDK images using $JOBS jobs" build_openjdk_images
    run_step 'Verify the OpenJDK and Graal builder JDK images' verify_openjdk_build

    INDENT_LEVEL=$((INDENT_LEVEL - 1))
    pass 'OpenJDK compilation stage completed'
}

main "$@"
