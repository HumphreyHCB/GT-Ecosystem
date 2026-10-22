# Troubleshooting

## Diagnose before changing anything

Run the non-mutating verifier first:

```bash
./Tests/Verify-Dependencies.sh
```

For a pipeline failure, preserve the reported run directory and inspect:

```text
results/summary.txt
results/pipeline.log
results/stages/<failed-stage>/
```

Do not delete the failed run until its backend data is no longer needed for
diagnosis.

## The pipeline was run with `sudo`

**Symptoms:** root-owned run/build files, Async-profiler cannot open its output, or
later non-root builds cannot replace files.

The complete pipeline must run as the login user. Denoise invokes sudo internally.
Repair a checkout that was accidentally built as root:

```bash
sudo chown -R "$(id -un)":"$(id -gn)" /path/to/GT-Ecosystem
```

Then test the existing Graal image without another rebuild:

```bash
./Tests/Compile-Build-Divine-Bubo.sh --test-only --stages graal
```

## Submodule recursion fails at Capstone

**Symptom:** `No url found for submodule path .../MachineCodeSourceExp/capstone`.

Capstone is not used by this ecosystem. Initialise only the top-level gitlinks:

```bash
git submodule sync
git submodule update --init --checkout --jobs "$(nproc)"
```

Do not use `--recursive`.

## A submodule directory is empty or contains only a gitlink

Inspect the expected top-level state:

```bash
git submodule status
git ls-tree HEAD repos/
```

Then reinitialise the affected top-level component:

```bash
git submodule deinit -f -- repos/COMPONENT
git submodule update --init --checkout -- repos/COMPONENT
```

This checks out the commit pinned by GT-Ecosystem; it does not pull the latest
component branch.

## VTune cannot recognise the processor

The installer deliberately pins Intel VTune 2025.0. VTune 2026.4 was found not to
recognise the older Kaby Lake experiment processor. Verify the actual collection
mode used by this project rather than relying on every test in Intel's general
self-checker:

```bash
vtune -version
./Tests/Install-Dependencies.sh
./Tests/Verify-Dependencies.sh
```

The current pipeline is not validated on AMD. See
[Future work](FUTURE-WORK.md#vendor-neutral-hardware-counter-backend).

## Hardware counters are unavailable

The verifier requires `perf` and access to cycles/instructions counters. Check:

```bash
command -v perf
sysctl kernel.perf_event_paranoid
sysctl kernel.kptr_restrict
perf stat -e cycles,instructions -- true
```

The installed persistent values are:

```text
kernel.perf_event_paranoid = 1
kernel.kptr_restrict = 0
```

Virtual machines, locked-down kernels, unsupported PMUs, or BIOS settings can still
prevent access even when the sysctl values are correct.

## Denoise cannot find CPU governors

The wrapper looks first under `/sys/devices/system/cpu/cpufreq/policy*/` and then
through per-CPU cpufreq links. Confirm that `scaling_governor` exists and is readable:

```bash
find /sys/devices/system/cpu/cpufreq -name scaling_governor -print
```

If the host exposes no cpufreq policy, inspect the kernel driver and BIOS frequency
controls. Do not silently treat an untuned run as comparable with Denoised results.

## CPU shielding is unavailable

ReBench's `cpuset` integration may not support a unified cgroup-v2 host. This is
reported as a warning and the wrapper continues with Turbo disabled, performance
governors, and raised priority. Record this difference when comparing machines.

## OpenJDK configure ends with an unexpected EOF

An interrupted configure can leave
`build/.configure-support/generated-configure.sh` truncated. The OpenJDK stage
detects a syntax-invalid generated helper, removes only that generated cache, and
retries configure once. If it still fails, inspect the earlier configure error in
`results/pipeline.log`; repeated truncation is usually a symptom rather than the
root cause.

## Async-profiler output is missing or empty

Confirm that:

- the pipeline was not launched as root;
- `AsyncProfilerLibrary` points to the x86-64 native library;
- `ldd` reports no missing dependencies; and
- the run directory is writable by the experiment user.

The pipeline pre-creates the output with the correct ownership and SELinux context.
An empty file plus `[ERROR] Could not open output file` normally indicates an
ownership or security-policy problem.

## `Could not locate BlockSlowdown.json` during a Graal smoke test

This message can appear in a mode where GT options are loaded but slowdown is
deliberately disabled. It is not the cause of a failure if the benchmark completes
and the subsequent mode validation passes. In Divine/BuboL replay stages, by
contrast, the configured slowdown JSON and compiler replay are required inputs and
their absence is fatal.

## Low memory or active swap

The verifier warns below 16 GiB and whenever swap is already in use. A build may
still finish on a smaller machine, but a 12 GiB heap plus compiler and profiler
processes can cause swapping and invalidate performance comparisons. Close other
applications, stop memory-heavy services, and prefer a machine with sufficient RAM.

## Re-run only the failed area

Runs never resume from an old run directory, but compiler build products can be
reused:

```bash
# Existing Graal build and all Graal smoke tests.
./Tests/Compile-Build-Divine-Bubo.sh --test-only --stages graal

# Fresh experiment data using existing compiler builds.
./Tests/Compile-Build-Divine-Bubo.sh --stages divine,bubol

# Rebuild Graal, then continue through measurements.
./Tests/Compile-Build-Divine-Bubo.sh --from graal
```
