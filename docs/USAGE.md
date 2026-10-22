# Running and configuring the pipeline

## Complete run

Run from the repository as the normal experiment user:

```bash
./Tests/Compile-Build-Divine-Bubo.sh
```

The script prompts once for sudo at startup when Denoise is enabled. It then runs
unattended, restores CPU settings after each measurement, and invalidates the sudo
timestamp when the pipeline finishes normally.

Use `-v` to stream detailed subprocess output:

```bash
./Tests/Compile-Build-Divine-Bubo.sh -v
```

Without `-v`, detailed output is retained in `results/pipeline.log`, and the final
20 lines are printed automatically after a failure.

## Command-line options

| Option | Meaning |
| --- | --- |
| `-c FILE`, `--config FILE` | Use another configuration file |
| `-v`, `--verbose` | Stream detailed output as well as recording it |
| `-f`, `--full-rebuild` | Clean the selected compiler builds first |
| `--test-only` | Test an existing GraalVM; must be combined with `--stages graal` |
| `--without-denoise` | Run measurements without CPU-noise controls |
| `-s LIST`, `--stages LIST` | Run a comma-separated stage subset in pipeline order |
| `--from STAGE` | Run one stage and every later stage |

Valid stages are `openjdk`, `graal`, `divine`, and `bubol`.

## Common workflows

```bash
# Clean and rebuild everything, then run all experiments.
./Tests/Compile-Build-Divine-Bubo.sh --full-rebuild

# Reuse compiler builds but regenerate Divine and BuboL measurements.
./Tests/Compile-Build-Divine-Bubo.sh --stages divine,bubol

# Start at Graal and continue through all measurement stages.
./Tests/Compile-Build-Divine-Bubo.sh --from graal

# Exercise an existing GraalVM without rebuilding either compiler.
./Tests/Compile-Build-Divine-Bubo.sh --test-only --stages graal

# Run one-off diagnostics without controlled CPU settings.
./Tests/Compile-Build-Divine-Bubo.sh --without-denoise --stages graal
```

Each invocation is isolated. A later run never consumes files from an earlier
`Tests/Runs/` directory.

## Configure component paths

The default configuration is `Tests/config.config`. Paths in its `[Dir]` section
are relative to the configuration file, not the shell's current working directory.
Absolute paths and external component checkouts are supported.

Use a separate file to preserve a machine-specific configuration outside Git:

```bash
cp Tests/config.config /data/gt-machine.config
$EDITOR /data/gt-machine.config
./Tests/Compile-Build-Divine-Bubo.sh --config /data/gt-machine.config
```

Important paths are:

| Key | Purpose |
| --- | --- |
| `FallbackJavaBuild` | Boot JDK used by scheduler tools |
| `LabsOpenJDK` | Modified OpenJDK source |
| `Graal` | Modified Graal source |
| `GTSlowdownSchedular` | Divining scheduler and VTune processing |
| `BuboExperiments` | Supporting experiment data/code checked by preflight |
| `AWFYSource` | Java AWFY source used to build the benchmark JAR |
| `AWFYBenchmarksJar` | Generated benchmark JAR |
| `AsyncProfilerLibrary` | Native Async-profiler agent |
| `RunRoot` | Parent of timestamped run directories |

## Configure benchmarks

The `[Run]` benchmark list drives both the Divine and BuboL stages:

```ini
[Run]
Benchmarks=Mandelbrot,Bounce
Denoise=true
BuboLMinRuntimeSharePercent=2
BuboLMaxMedianDifferencePoints=25
```

Every listed name requires a matching section:

```ini
[Benchmark.Mandelbrot]
Iterations=300
ExtraArgument=750
ExpectedSlowdownRatio=2
SlowdownTolerancePercent=15
```

- `Iterations` is passed to the AWFY harness.
- `ExtraArgument` is the benchmark-specific workload size.
- `ExpectedSlowdownRatio=2` requests a total run time of approximately twice the
  normal run time.
- `SlowdownTolerancePercent=15` accepts results from 1.7x to 2.3x for a 2x target.
- `BuboLMinRuntimeSharePercent` excludes unstable, insignificant loops from the
  final accuracy comparison.
- `BuboLMaxMedianDifferencePoints` is the maximum accepted median absolute
  difference between BuboL and the VTune loop baseline.

Adding a name to the list is only the configuration step. A reliable new benchmark
also requires validation that:

1. the AWFY harness accepts the chosen arguments and reaches a stable compiled
   state;
2. the scheduler creates one non-empty compiler replay and slowdown file;
3. the target ratio is achievable within the configured tolerance;
4. BuboL-to-CFG-to-VTune loop matching is unambiguous;
5. qualifying loops are significant and do not contain unsupported non-inlined
   calls; and
6. repeated controlled runs are stable.

The default Mandelbrot and Bounce configuration is the tested end-to-end
demonstration. Broader benchmark support is documented as future engineering work,
not implied merely by the parser accepting another section.

## Standalone Denoise operations

```bash
# Install and functionally verify Denoise.
./Tests/Setup-Denoise.sh install

# Verify CPU-state changes and restoration.
./Tests/Setup-Denoise.sh verify

# Run an arbitrary command with the same controls.
./Tests/Setup-Denoise.sh run -- ./my-benchmark --arguments
```

Denoise records the original Turbo, governor, and relevant perf state before a run
and restores it on success, failure, or handled interruption. Core shielding may be
unavailable on a cgroup-v2 host; the wrapper reports this and continues with the
remaining controls.
