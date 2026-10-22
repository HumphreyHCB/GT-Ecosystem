# Research scope and evidence

## What this repository demonstrates

The default pipeline is a compact, executable demonstration of the core research
mechanisms. It builds the modified JVM/compiler stack, confirms that BuboL emits
cycle data, generates a calibrated slowdown for Mandelbrot and Bounce, verifies the
whole-program change, and compares BuboL loop measurements with VTune.

Its automated scope is intentionally smaller than the published evaluations:

| Dimension | Current default pipeline | Broader research evidence |
| --- | --- | --- |
| End-to-end benchmarks | Mandelbrot, Bounce | Divining: all 14 AWFY benchmarks; BuboL: five AWFY benchmarks plus LoopBenchmarks |
| Compiler smoke tests | Bounce, Sieve | Integration check only |
| Sampling profiler automation | Async-profiler marker visibility | Divining: Async-profiler, JFR, JProfiler, YourKit; BuboL: Async and JFR |
| Hardware baseline | Intel VTune | VTune-based published evaluation on Intel hardware |
| Reported comparison | Requested vs achieved Divine slowdown; BuboL vs VTune per loop | Multi-run method- and loop-level profiler analyses |

Therefore, the pipeline should be described as a **reproducibility slice**, not as
the complete experimental campaign.

## Divining profiler accuracy

The OOPSLA 2025 work introduces controlled machine-code slowdown as a practical way
to approximate a profiler ground truth. The system profiles compiled basic blocks,
inserts calibrated slowdown instructions after major compiler decisions, and asks
whether a profiler reports the known change in the correct source region.

The paper evaluates all 14 Are We Fast Yet benchmarks: Bounce, CD, DeltaBlue,
Havlak, Json, List, Mandelbrot, NBody, Permute, Queens, Richards, Sieve, Storage,
and Towers. Target overheads of 50%, 100%, and 150% achieved cross-benchmark medians
of 50.0%, 100.0%, and 146.8% respectively.

The performance-behavior experiment uses Async-profiler, JFR, JProfiler, and
YourKit. Across the benchmark set, method run-time proportions remain strongly
correlated between normal and slowed executions. The targeted-change experiment
also demonstrates that attribution quality differs between profilers and can fail
when compiler debug information does not map generated instructions cleanly back to
source locations.

These results support the methodology behind this ecosystem, but the default two-
benchmark command does not rerun all four profiler integrations.

## Late compiler-stage instrumentation

The MPLR 2024 work motivates Bubo (named BuboC in the thesis): instrumentation
inserted late in compilation can avoid changing major optimisation decisions and
produce a more realistic view of the optimised program than bytecode
instrumentation. It establishes the design direction that BuboL later applies at
loop granularity and even later in the LIR pipeline.

Across the AWFY benchmarks, the prototype's reported median run-time overhead is
23.3%, far below the instrumentation-based profilers evaluated in that study. It
also attributes cycles to the method fragments that remain in an optimised
compilation unit, accounting for inlining rather than assuming the bytecode method
structure survives unchanged.

This distinction matters: BuboL is not simply a conventional Java agent moved into
this repository. Its measurements depend on the modified compiler and native-cycle
probes, which is why the OpenJDK and Graal stages are part of the reproducibility
pipeline.

## BuboL evaluation

The thesis evaluates BuboL with Sieve, NBody, Mandelbrot, Json, and Bounce, as well
as the loop-focused LoopBenchmarks suite. The accuracy analysis retains loops that
contribute at least 2% of run time and excludes unsupported non-inlined-call cases.

Using VTune's change in loop time as the baseline, the reported overall median
absolute differences are:

| Profiler | Median difference from loop baseline |
| --- | ---: |
| BuboL | 1.7% |
| Async-profiler | 12.1% |
| JFR | 18.0% |

For the benchmark subset used in the accuracy and observer-effect evaluation,
BuboL's median CPU-time overhead is reported as 18.6%. The thesis also identifies
important limitations: tight, frequently activated, or vector-heavy loops can show
larger probe effects or run-to-run variance; nested-loop measurements can include
the cost of inner probes; and reliable loop/source attribution depends on compiler
metadata and matching.

The default pipeline currently publishes BuboL versus VTune for Mandelbrot and
Bounce. Async-profiler is used in the Graal stage to validate marker visibility, not
as the complete loop-accuracy comparison reported in the thesis.

## Meaning of “ground truth” here

The project does not claim direct access to a perfect ground truth. Modern hardware
cannot be measured without an observer effect, and hardware-counter sampling can
itself be affected by skid and other biases.

The operational baseline is an **approximated ground truth**:

1. use hardware-derived measurements to estimate time in machine-code regions;
2. deliberately apply a controlled slowdown;
3. verify that the overall program and dominant basic blocks change as expected;
4. test whether another profiler detects and attributes that known change.

Agreement with VTune is therefore evidence under this methodology and hardware
configuration, not proof that every individual counter sample is exact.

## References

- Humphrey Burchell and Stefan Marr. *Divining Profiler Accuracy: An Approach to
  Approximate Profiler Accuracy through Machine Code-Level Slowdown*. Proceedings
  of the ACM on Programming Languages 9, OOPSLA2, Article 402, 2025.
  [https://doi.org/10.1145/3763180](https://doi.org/10.1145/3763180)
- Humphrey Burchell, Octave Larose, and Stefan Marr. *Towards Realistic Results
  for Instrumentation-Based Profilers for JIT-Compiled Systems*. MPLR 2024.
  [https://doi.org/10.1145/3679007.3685058](https://doi.org/10.1145/3679007.3685058)
- Humphrey H. C. Burchell. *Reclaiming Profiler Ground Truth: Determining and
  Improving the Accuracy of CPU Profilers in the Presence of Dynamic Compilation*.
  PhD thesis, University of Kent, 2026. See especially Chapters 5, 6, and 8.
