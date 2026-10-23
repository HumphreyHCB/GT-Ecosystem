# GT Ecosystem

GT Ecosystem is the reproducibility and integration repository for two related
approaches to understanding profiler accuracy on JIT-compiled Java programs:

- **Divining slowdown** inserts calibrated machine-code instructions into Graal
  basic blocks. It creates a known performance change that a profiler should be
  able to observe and attribute correctly.
- **BuboL** instruments loops late in Graal's LIR pipeline and measures their CPU
  cycles directly. The ecosystem compares the slowdown BuboL observes for each
  significant loop with a VTune-derived baseline.

The repository pins the compiler, scheduler, benchmarks, and experiments as Git
submodules, installs the host dependencies, builds the modified OpenJDK and GraalVM,
runs the experiments under controlled CPU settings, validates the measurements,
and publishes a compact results directory with summaries, CSV data, and plots.

> **Current automation scope**
>
> The default end-to-end pipeline demonstrates **Mandelbrot** and **Bounce**.
> Graal's compiler smoke tests additionally use **Bounce** and **Sieve**, and use
> Async-profiler to confirm that compiler markers are visible. The final BuboL
> accuracy plot compares BuboL with the VTune baseline; it is not a reproduction
> of the complete multi-profiler study.
>
> The underlying research was evaluated on broader benchmark and profiler sets.
> See [Research scope](docs/RESEARCH-SCOPE.md) before drawing conclusions from
> the smaller automated demonstration.

## Quick start

The supported automated setup targets a clean Rocky Linux or compatible RHEL-family
x86-64 machine with an Intel CPU.

```bash
git clone https://github.com/HumphreyHCB/GT-Ecosystem.git
cd GT-Ecosystem

./Tests/Install-Dependencies.sh
./Tests/Compile-Build-Divine-Bubo.sh
```

Run both scripts as your normal login user, **not** by placing `sudo` before the
command. They request elevated privileges only for system installation and CPU
controls. The pipeline asks for the sudo password once at startup and can then run
unattended.

The final terminal report points to:

```text
Tests/Runs/<start-time>_<pid>/results/
```

Start with `summary.txt`, then open the two SVG plots. See
[Reading the results](docs/RESULTS.md) for the meaning of every generated file.

## Pipeline at a glance

| Stage | Purpose | Principal output |
| --- | --- | --- |
| OpenJDK | Builds the modified JVM and a Graal builder JDK | OpenJDK images |
| Graal | Builds the modified GraalVM and exercises clean, GT, BuboL, and marker configurations | Build and smoke-test logs |
| Divine | Calibrates per-basic-block slowdown with VTune and checks whole-program slowdown | Expected versus achieved slowdown per benchmark |
| BuboL | Repeats the slowdown experiment with loop instrumentation and compares significant loops with VTune | Per-loop slowdown comparison |

OpenJDK and Graal are built without Denoise. Measurement runs use ReBench Denoise
to disable Turbo, select the performance governor, raise priority, and use CPU
shielding where supported. Original CPU settings are restored after each run.

## Documentation

- [Documentation index](docs/README.md)
- [Installation and system requirements](docs/INSTALLATION.md)
- [Running and configuring the pipeline](docs/USAGE.md)
- [Architecture and data flow](docs/ARCHITECTURE.md)
- [Reading and interpreting results](docs/RESULTS.md)
- [Research scope and evidence](docs/RESEARCH-SCOPE.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Future work](docs/FUTURE-WORK.md)

## Repository boundaries

This repository owns the orchestration, configuration, validation, and reporting
scripts. Component implementations remain in the repositories pinned below
`repos/`. Normal pipeline operation does not modify those submodules.

Do not initialise submodules recursively. `BuboExperiments` contains an unused
Capstone gitlink that is not part of this build:

```bash
git submodule sync
git submodule update --init --checkout --jobs "$(nproc)"
```

Each gitlink pins a tested commit. The branch names in `.gitmodules` document the
upstream development branches; they do not make normal checkout follow branch
heads automatically.

## Research references

- Humphrey Burchell and Stefan Marr. *Divining Profiler Accuracy: An Approach to
  Approximate Profiler Accuracy through Machine Code-Level Slowdown*. OOPSLA 2025.
  [DOI: 10.1145/3763180](https://doi.org/10.1145/3763180)
- Humphrey Burchell, Octave Larose, and Stefan Marr. *Towards Realistic Results
  for Instrumentation-Based Profilers for JIT-Compiled Systems*. MPLR 2024.
  [DOI: 10.1145/3679007.3685058](https://doi.org/10.1145/3679007.3685058)
- Humphrey H. C. Burchell. *Reclaiming Profiler Ground Truth: Determining and
  Improving the Accuracy of CPU Profilers in the Presence of Dynamic Compilation*.
  PhD thesis, University of Kent, 2026.
