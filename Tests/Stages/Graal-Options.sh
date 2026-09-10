#!/usr/bin/env bash

# JVM options used by the Graal verification modes.
# These options define the compiler configurations being tested.

load_graal_options() {
    GT_GRAAL_OPTIONS=(
        -XX:+UnlockExperimentalVMOptions
        -XX:+UnlockDiagnosticVMOptions
        -XX:+EnableJVMCI
        -XX:+UseJVMCICompiler
        -XX:+UseJVMCINativeLibrary
        -XX:+DebugNonSafepoints
        -Djdk.graal.StrictProfiles=false
        -Djdk.graal.WarnAboutCodeSignatureMismatch=false
        -Djdk.graal.TrackNodeSourcePosition=true
        --enable-native-access=ALL-UNNAMED
        -XX:-TieredCompilation
        -XX:-BackgroundCompilation
        -Djdk.graal.LoopHeaderAlignment=0
        -Djdk.graal.IsolatedLoopHeaderAlignment=0
    )

    BUBO_GRAAL_OPTIONS=(
        -Djdk.graal.BuboLIRPhase=true
        -Djdk.graal.HumphreysDebugData=false
        -Djdk.graal.DisableCodeEntryAlignment=true
        -Djdk.graal.CompilationFailureAction=Diagnose
    )
}

load_divine_verification_options() {
    local compiler_replay_directory=$1
    local slowdown_json=$2

    DIVINE_REPLAY_OPTIONS=(
        -Djdk.graal.StrictProfiles=false
        "-Djdk.graal.LoadProfiles=$compiler_replay_directory"
    )

    DIVINE_SLOWDOWN_OPTIONS=(
        -Djdk.graal.LIRGTSlowDown=true
        "-Djdk.graal.LIRBlockSlowdownFileName=$slowdown_json"
    )
}

load_bubol_verification_options() {
    local compiler_replay_directory=$1
    local slowdown_json=$2

    BUBOL_REPLAY_OPTIONS=(
        "${BUBO_GRAAL_OPTIONS[@]}"
        -Djdk.graal.GTAssignDebug=false
        -Djdk.graal.StrictProfiles=false
        "-Djdk.graal.LoadProfiles=$compiler_replay_directory"
    )

    BUBOL_NORMAL_OPTIONS=(
        -Djdk.graal.LIRGTSlowDown=false
    )

    BUBOL_SLOWDOWN_OPTIONS=(
        -Djdk.graal.LIRGTSlowDown=true
        "-Djdk.graal.LIRBlockSlowdownFileName=$slowdown_json"
    )
}