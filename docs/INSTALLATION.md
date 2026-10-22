# Installation and system requirements

## Supported and recommended host

The installer currently supports Rocky Linux and compatible RHEL-family systems.
The experiment implementation is currently tied to Linux x86-64, Intel performance
counters, and Intel VTune.

| Requirement | Minimum checked by the scripts | Recommendation |
| --- | --- | --- |
| Operating system | Linux x86-64; Rocky/RHEL family for automatic installation | A dedicated Rocky Linux experiment machine |
| Processor | Two logical CPUs for Denoise; a count below four produces a warning | Intel CPU with at least four logical CPUs and stable `intel_pstate` controls |
| Memory | Less than 16 GiB produces a warning | At least 16 GiB; avoid active swap during measurements |
| Free disk | 30 GiB | More for retained run directories and repeated clean builds |
| Privileges | User account with `sudo` | Dedicated experiment account |
| Network | Required during installation | GitHub, Adoptium, Intel oneAPI, and Python package access |

The dependency checker warns rather than fails when memory is below 16 GiB, but a
12 GiB benchmark heap can place an 8 GiB machine under swap pressure. Such a host
may build successfully while producing noisier measurements.

## What the installer provides

`Tests/Install-Dependencies.sh` performs the following work:

1. Installs the C/C++ and OpenJDK build toolchain, CMake, Ninja, Python tooling,
   `perf`, libraries required by OpenJDK, and common archive utilities.
2. Installs the known-working Intel VTune 2025.0 package. Newer VTune releases are
   not assumed to support older processors used by this project.
3. Writes persistent VTune kernel settings:
   `kernel.perf_event_paranoid=1` and `kernel.kptr_restrict=0`.
4. Initialises only the five top-level component submodules.
5. Downloads Temurin JDK 25 and `mx` 7.68.9 into `Tests/Tools/`.
6. Installs the ReBench development version and the pinned `cpuset` dependency in
   an isolated Python environment.
7. Creates a user-specific 12-hour sudo timestamp policy for unattended runs. It
   does not grant passwordless sudo and the pipeline invalidates its timestamp on
   normal completion.
8. Builds `Tests/Tools/benchmarks.jar`, including the TSC JNI library.
9. Runs the VTune hardware-Hotspots check and the complete dependency verifier.

Installed build packages include the ALSA, CUPS, Fontconfig, FreeType, X11, zlib,
libffi, and ELF development headers required by OpenJDK.

## Clean installation

```bash
git clone https://github.com/HumphreyHCB/GT-Ecosystem.git
cd GT-Ecosystem
./Tests/Install-Dependencies.sh
```

Do not add `--recurse-submodules` to the clone command. The installer initialises
the five required top-level repositories without descending into the unused
Capstone gitlink.

Do not run the installer or pipeline as `sudo bash ...`. Run as the experiment user
and enter the password when the script invokes `sudo` for a privileged operation.
This prevents root-owned compiler builds and output directories.

Useful installer options are:

```bash
# Keep existing OS packages and system configuration.
./Tests/Install-Dependencies.sh --skip-system-packages

# Skip the hardware collection test, for diagnosis only.
./Tests/Install-Dependencies.sh --skip-vtune-self-check
```

Skipping the VTune self-check does not make an unsupported machine suitable for
the current accuracy pipeline.

## Existing clone or externally located components

For an existing clone, initialise the top-level repositories without recursion:

```bash
git submodule sync
git submodule update --init --checkout --jobs "$(nproc)"
```

Do not add `--recursive`; the unused Capstone gitlink inside `BuboExperiments` is
not required and is not fully declared.

Components do not have to be submodules. Every path in `Tests/config.config` is
resolved relative to that configuration file and may point to an external checkout:

```ini
[Dir]
LabsOpenJDK=/work/labs-openjdk-jvmci-25.1-b13
Graal=/work/graal-instrumentation
GTSlowdownSchedular=/work/GTSlowdownSchedular
BuboExperiments=/work/BuboExperiments
AWFYSource=/work/are-we-fast-yet/benchmarks/Java/src
AsyncProfilerLibrary=/work/are-we-fast-yet/Async/async-profiler-4.2.1-linux-x64/lib/libasyncProfiler.so
RunRoot=/data/gt-runs
```

## Verify without changing the machine

```bash
./Tests/Verify-Dependencies.sh
```

The verifier checks the host, capacity, commands, configured repositories, boot
JDK, `mx`, VTune, Denoise, benchmark JAR, native dependencies, hardware counters,
and benchmark configuration. Warnings identify conditions likely to increase noise;
failures identify requirements that block the pipeline.

For an intentionally untuned run that does not require Denoise:

```bash
./Tests/Verify-Dependencies.sh --without-denoise
./Tests/Compile-Build-Divine-Bubo.sh --without-denoise
```

Untuned measurements are useful for diagnosis, not for comparison with controlled
results.
