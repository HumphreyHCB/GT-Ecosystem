# GT Ecosystem

The component repositories are pinned as Git submodules under `repos/`.

Clone the complete ecosystem with:

```bash
git clone --recurse-submodules \
    https://github.com/HumphreyHCB/GT-Ecosystem.git
```

For an existing clone, initialise the top-level component repositories with:

```bash
git submodule update --init
```

Do not add `--recursive`: BuboExperiments has an unused Capstone gitlink that
is not part of this ecosystem build.

Each submodule is pinned to a tested commit. The branch recorded in
`.gitmodules` identifies the upstream branch used when deliberately updating
that component; normal checkout continues to use the pinned commit.

## Clean Rocky Linux machine

Run the one-time bootstrap from any directory:

```bash
./Tests/Install-Dependencies.sh
```

It installs the Rocky build packages and the known-working Intel VTune 2025.0,
downloads the pinned boot JDK and `mx`, installs ReBench Denoise from its
development source, initializes
the top-level submodules, builds the AWFY benchmark JAR and its JNI library,
and verifies hardware Hotspots collection and the rest of the setup.

Then run the complete pipeline:

```bash
./Tests/Compile-Build-Divine-Bubo.sh
```

Run the pipeline as your normal login user, **not** with `sudo`. It invokes
`sudo` itself only for the Denoise CPU controls. Running the complete pipeline
as root creates root-owned build and result files, while Denoise intentionally
runs the measured JVM as the login user.

Each invocation creates one isolated directory under `Tests/Runs/`:

```text
Runs/<start-time>_<pid>/
├── pipeline/                 private inputs, build files and full logs
└── results/                  stable, user-facing copies and reports
    ├── summary.txt
    ├── summary.json
    ├── pipeline.log
    ├── data/
    │   ├── divine-slowdown.csv
    │   └── bubol-loop-slowdown.csv
    ├── plots/
    │   ├── divine-slowdown.svg
    │   └── bubol-loop-slowdown.svg
    └── stages/               selected diagnostics by stage and benchmark
```

The scripts only consume files in `pipeline/`. Everything in `results/` is a
copy or a derived report, so it is safe to move, inspect or delete.

## Configuration

All paths in `Tests/config.config` are relative to that file. They may point
to the checked-out submodules or to repositories and generated files anywhere
else on the machine. For example:

```ini
[Dir]
Graal=/work/my-graal-instrumentation
GTSlowdownSchedular=/work/my-scheduler
RunRoot=/data/gt-runs
```

The benchmark list and each benchmark's arguments are also configured there:

```ini
[Run]
Benchmarks=Mandelbrot,Bounce

[Benchmark.Mandelbrot]
Iterations=300
ExtraArgument=750
ExpectedSlowdownRatio=2
SlowdownTolerancePercent=15
```

Add another name to `Benchmarks` and add a matching `[Benchmark.NAME]`
section to run it through both Divine modes and include it in the reports.
Use a different configuration without changing the checkout with:

```bash
./Tests/Compile-Build-Divine-Bubo.sh --config /path/to/config.config
```

The pure-Divine chart compares requested and achieved slowdown for every
benchmark. The BuboL chart shows every qualifying loop separately, comparing
VTune's expected slowdown with BuboL's achieved measurement.

## Stable CPU measurements

`Compile-Build-Divine-Bubo.sh` automatically wraps every benchmark with
ReBench Denoise except the first clean-GraalVM smoke test. OpenJDK and Graal
builds, validation steps, and report generation are not wrapped.
During a measurement, Denoise disables Turbo Boost, selects the performance
governor, raises process priority, and uses CPU shielding where the machine's
cgroup mode supports it. The wrapper does not change perf sampling controls,
because VTune needs them, and it restores the original Turbo and governor
settings even when the measurement fails.

The standalone setup and functional test is:

```bash
./Tests/Setup-Denoise.sh install
```

Run any individual command under the same controls with:

```bash
./Tests/Setup-Denoise.sh run -- ./my-benchmark --arguments
```

The setup asks for `sudo` before changing CPU controls. It does not run a
periodic sudo refresher, because even a small background process is undesirable
during performance measurements. Configure a suitably long sudo
`timestamp_timeout` for the experiment account before a long run rather than
installing a passwordless rule. On a cgroup v2 host, ReBench's current `cpuset`
integration may not
support shielding; the script reports that and safely continues with Turbo,
governor, and priority controls. Use `--without-denoise` on the main pipeline
for an intentionally untuned run.

To inspect a machine without changing it, run:

```bash
./Tests/Verify-Dependencies.sh
```
