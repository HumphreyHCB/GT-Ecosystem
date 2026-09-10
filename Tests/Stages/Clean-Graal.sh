#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TESTS_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

# shellcheck source=../lib/common.sh
source "$TESTS_DIR/lib/common.sh"

CONFIG_FILE=${GT_ECOSYSTEM_CONFIG:-"$TESTS_DIR/config.config"}

load_configuration() {
    require_file "$CONFIG_FILE" 'Ecosystem configuration'
    require_config_value LABS_OPENJDK "$CONFIG_FILE" Dir LabsOpenJDK
    require_config_value GRAAL_REPOSITORY "$CONFIG_FILE" Dir Graal
    resolve_openjdk_configuration OPENJDK_CONF "$LABS_OPENJDK"
    GRAAL_BUILDER_JDK="$LABS_OPENJDK/build/$OPENJDK_CONF/images/graal-builder-jdk"
}

clean_graal() {
    require_directory "$GRAAL_REPOSITORY/vm" 'Graal VM suite'
    require_executable "$GRAAL_BUILDER_JDK/bin/java" 'Graal builder JDK java'
    command -v mx >/dev/null 2>&1 || die 'mx is not available on PATH'

    (
        cd "$GRAAL_REPOSITORY/vm"
        mx --java-home "$GRAAL_BUILDER_JDK" --env libgraal clean
    )
}

main() {
    run_step 'Load Graal clean configuration' load_configuration
    run_step 'Clean the Graal build' clean_graal
}

main "$@"
