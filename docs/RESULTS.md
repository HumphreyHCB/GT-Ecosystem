# Reading and interpreting results

## Where to start

Every invocation prints its run directory at startup and again in the final report:

```text
Tests/Runs/<YYYY_MM_DD_HH_MM_SS>_<pid>/
```

Read outputs in this order:

1. `results/summary.txt` - pass/fail status, duration, selected stages, and output
   index.
2. `results/plots/divine-slowdown.svg` - requested and achieved whole-program
   slowdown for each configured benchmark.
3. `results/plots/bubol-loop-slowdown.svg` - VTune and BuboL slowdown for every
   qualifying loop.
4. `results/stages/<stage>/summary.txt` - concise stage and benchmark details.
5. CSV files for exact values.
6. `results/pipeline.log` and copied stage logs when diagnosing a failure.

## Directory layout

```text
Runs/<start-time>_<pid>/
├── pipeline/
│   ├── build/                 generated scheduler classes
│   ├── logs/pipeline.log      complete orchestration log
│   ├── report.events          internal report event stream
│   └── stages/                complete inter-stage inputs and working data
└── results/
    ├── summary.txt            human-readable run overview
    ├── summary.json           machine-readable run overview
    ├── pipeline.log           published copy of the complete log
    ├── data/
    │   ├── divine-slowdown.csv
    │   └── bubol-loop-slowdown.csv
    ├── plots/
    │   ├── divine-slowdown.svg
    │   └── bubol-loop-slowdown.svg
    └── stages/
        ├── openjdk/summary.txt
        ├── graal/...
        ├── divine/<benchmark>/...
        └── bubol/<benchmark>/...
```

The `pipeline/` tree is backend state. Files there may be compiler replays, temporary
workspaces, scheduler inputs, or intermediate VTune-derived data. Use `results/` for
normal inspection and external analysis.

## Divine results

`data/divine-slowdown.csv` contains:

| Column | Meaning |
| --- | --- |
| `benchmark` | Configured AWFY benchmark name |
| `expected_slowdown_ratio` | Requested total run-time multiplier |
| `achieved_slowdown_ratio` | Slowdown average divided by normal average |
| `normal_average_us` | Harness average without inserted slowdown |
| `slowdown_average_us` | Harness average with the slowdown file enabled |

For example, an expected value of `2.0` and achieved value of `2.04` mean that the
slowed replay took 2.04 times the normal run time. This is a 104% overhead, but only
a 2% difference from the requested 2x ratio.

The stage's accepted interval is calculated from `SlowdownTolerancePercent`. With a
2x target and 15% tolerance, the accepted range is 1.7x to 2.3x.

The Divine plot is a validation of controlled slowdown. It is not itself a profiler
accuracy comparison: it demonstrates that the requested performance change was
created successfully.

## BuboL loop results

`data/bubol-loop-slowdown.csv` contains one row per qualifying loop:

| Column | Meaning |
| --- | --- |
| `benchmark` | Benchmark containing the loop |
| `comp_id` | Compiler compilation identifier used during matching |
| `method` | Compiled method associated with the loop |
| `loop_id` | BuboL loop identifier within the compilation |
| `runtime_share_pct` | Loop's contribution to measured execution time |
| `vtune_slowdown_pct` | Loop slowdown derived from VTune block timings |
| `bubol_slowdown_pct` | Loop slowdown derived from BuboL cycles |
| `absolute_difference_pct_points` | Absolute difference between the two slowdowns |

Only rows marked as qualifying by the analyser are published into the combined CSV
and SVG. By default, a loop must contribute at least 2% of execution time. This
reduces the risk of treating noise in very small loops as a meaningful accuracy
result.

The SVG uses the VTune value as **expected** and the BuboL value as **achieved**.
Closer bars indicate closer agreement. The difference is in percentage points, not
a relative percentage: VTune 100% and BuboL 96% differ by 4 percentage points.

The pipeline validates the median absolute difference over qualifying loops against
`BuboLMaxMedianDifferencePoints`. Individual loops can still be outliers; inspect
the CSV rather than relying only on the stage pass/fail result.

## Benchmark summaries and diagnostics

For each benchmark, the published stage directory can contain:

- `summary.txt` and `summary.json` - expected/achieved ratios and averages;
- `Final_<benchmark>.json` - generated basic-block slowdown configuration;
- `MarkerPhase_BuboIncluded.json` - mapping adjusted for BuboL-generated code;
- `Normal.log` and `Slowdown.log` - pure Divine replay logs;
- `Normal-BuboL.log` and `Slowdown-BuboL.log` - BuboL replay and cycle output;
- `CFG-BuboL.log` - compiler CFG and loop-membership diagnostics;
- `VTune-Slowdown-Blocks.txt` - scheduler-produced VTune block comparison; and
- `BuboL-VTune-Loop-Comparison.csv` - full per-loop analyser output, including
  qualification metadata.

## Failed and partial runs

The report renderer runs even when an earlier stage fails. Consequently, plots and
CSV files can exist but contain no completed data. Treat `summary.txt` or
`summary.json` status as authoritative before interpreting a plot.

The symbols in the terminal and summary mean:

- `PASSED` / `✔`: the selected stage and its validations completed;
- `FAILED` / `✘`: the stage stopped at a failed command or validation; and
- `NOT_RUN` / `○`: an earlier failure prevented that selected stage from starting.

## Responsible interpretation

A successful pipeline run proves that the checked-out components worked together
on that host and that its configured validation thresholds were met. It does not by
itself reproduce every profiler, benchmark, repeat, or statistical analysis in the
published studies.

For research-quality comparison:

- retain exact component commits and `summary.json`;
- repeat measurements rather than relying on one run;
- inspect swap, shielding, governor, and Turbo warnings;
- compare distributions or medians across runs; and
- investigate loop outliers individually, especially small tight vector loops.
