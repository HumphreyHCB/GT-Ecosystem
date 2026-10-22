# Future work

The current pipeline is a working Intel/VTune-backed reproducibility slice. The
highest-value future work is to separate the research method from the particular
hardware profiler, broaden reliable benchmark coverage, and automate the wider
profiler comparisons already evaluated manually in the research.

## Vendor-neutral hardware-counter backend

The Ground Truth Scheduler currently consumes Intel VTune output. That couples the
pipeline to Intel processors supported by the pinned VTune release and prevents the
same automation from running on AMD hardware.

A replacement should define a small hardware-measurement interface rather than
embedding one tool's report format throughout the scheduler. A backend would need
to provide, for each compiled code region:

- module/JIT code identity and address ranges;
- sampled instruction or basic-block counts/times;
- event configuration and sampling period;
- symbol/debug metadata needed for Graal block matching;
- collection diagnostics, lost-sample counts, and multiplexing information; and
- a machine-readable provenance record.

The first alternative backend should target Linux `perf_event_open`, potentially
using `perf`, `libperf`, PAPI, or libpfm4 for event discovery and encoding. This
would expose hardware counters through the kernel PMU interface on both Intel and
AMD while allowing the existing VTune backend to remain as a reference.

This is not just a report-parser replacement. The new backend must be experimentally
validated for:

1. instruction skid and event precision;
2. reliable association between JIT code and samples;
3. availability and equivalence of events across Intel and AMD PMUs;
4. counter multiplexing and overflow behavior;
5. sampling overhead and observer effect; and
6. agreement of calibrated slowdown with wall-clock behavior.

Once these requirements are met, the same high-level Divining and BuboL workflow
could run on AMD x86-64 without requiring VTune. The documentation and result
manifest should always name the backend, CPU model, kernel, events, and precision
mode so that results from different machines are not compared blindly.

## Architecture and microarchitecture portability

Hardware-counter portability does not by itself make slowdown portable. The current
instruction sequences and anti-stalling heuristics were evaluated for Intel x86
microarchitectures. AMD support needs its own validation of instruction throughput,
dependency chains, front-end effects, and frequency behavior.

A later phase could add AArch64 support, but would require a target-specific Graal
LIR implementation, slowdown instruction study, counter backend, marker encoding,
and a fresh validation that compilation and execution behavior remain preserved.

## Broader reliable benchmark automation

The OOPSLA evaluation covers all 14 AWFY benchmarks, while the default pipeline
currently demonstrates Mandelbrot and Bounce end to end. Expanding the configuration
list alone is insufficient. Each benchmark should gain a checked-in, justified
profile containing:

- deterministic workload arguments and warmup/iteration counts;
- expected compilation units and replay stability checks;
- method/basic-block/loop matching assertions;
- calibrated runtime-share and duration thresholds;
- handling for multiple compilation units and non-inlined calls;
- repeated-run variance bounds; and
- a documented reason for any excluded loop or method.

A sensible progression is:

1. add Sieve, NBody, and Json to match the BuboL AWFY evaluation set;
2. integrate LoopBenchmarks as a first-class suite rather than one AWFY name;
3. add the remaining AWFY benchmarks used by Divining; and
4. investigate larger suites such as Renaissance or DaCapo once compiler replay,
   run time, and diagnosis are manageable.

Fast compiler smoke tests should remain separate from long statistical experiments.

## Full profiler adapters

Async-profiler currently verifies compiler-marker visibility in the automated Graal
stage. The wider research evaluates Async-profiler, JFR, JProfiler, and YourKit for
method-level slowdown, and Async/JFR for loop accuracy.

Future adapters should provide a common lifecycle:

1. configure and launch the profiler;
2. run normal and controlled-slowdown replays;
3. export an immutable raw profile;
4. map profiler-specific frames/samples to the common method or loop identity;
5. calculate expected versus observed change; and
6. publish exact values and exclusions alongside BuboL and the hardware baseline.

Commercial profiler adapters must keep licensing and unattended-operation concerns
outside the open bootstrap path.

## Statistical reporting and provenance

The default pipeline validates one completed run and presents direct comparisons.
Research automation should support repeated trials and publish medians, dispersion,
confidence intervals or robust uncertainty summaries, and explicit outlier policy.

Every run should also record a provenance manifest containing:

- all ecosystem and component commit IDs;
- dirty-worktree status;
- CPU model, microcode, topology, governor, Turbo, and SMT state;
- memory and swap state;
- kernel, OS, JDK, Graal, VTune/backend, and profiler versions;
- exact commands and effective configuration; and
- whether core shielding was active.

This would make cross-machine and longitudinal comparisons safer.

## BuboL engineering

Further BuboL work suggested by the thesis includes:

- model and subtract probe self-cost, especially in nested loops;
- reduce register-allocation side effects and extra MOV blocks;
- support loops containing non-inlined calls with reliable context attribution;
- use a lightweight sampling pass to select significant loops before instrumenting;
- preserve richer compiler/source mappings for transformed loops;
- extend profiling to other optimised program regions; and
- explore a hybrid design combining precise late-stage timing windows with sampling
  inside those windows.

The guiding requirement remains the same: improvements must be evaluated for both
measurement accuracy and the observer effect they introduce.
