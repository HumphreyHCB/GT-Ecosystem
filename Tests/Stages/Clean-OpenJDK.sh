#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TESTS_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

# shellcheck source=../lib/common.sh
source "$TESTS_DIR/lib/common.sh"

CONFIG_FILE=${GT_ECOSYSTEM_CONFIG:-"$TESTS_DIR/config.config"}

clean_openjdk() {
    require_file "$CONFIG_FILE" 'Ecosystem configuration'
    require_config_value LABS_OPENJDK "$CONFIG_FILE" Dir LabsOpenJDK
    require_directory "$LABS_OPENJDK" 'Labs OpenJDK source'

    if [[ ! -d "$LABS_OPENJDK/build" ]]; then
        task 'OpenJDK build directory is already clean'
        return 0
    fi

    rm -rf -- "$LABS_OPENJDK/build"
    [[ ! -e "$LABS_OPENJDK/build" ]] || die "Failed to remove $LABS_OPENJDK/build"
}

main() {
    run_step 'Clean the OpenJDK build directory' clean_openjdk
}

main "$@"
