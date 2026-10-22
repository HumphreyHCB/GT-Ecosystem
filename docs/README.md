# GT Ecosystem documentation

This directory separates operating instructions from the research claims behind
the system. New users should read the documents in this order:

1. [Installation and system requirements](INSTALLATION.md)
2. [Running and configuring the pipeline](USAGE.md)
3. [Reading and interpreting results](RESULTS.md)

For implementation and research context:

- [Architecture and data flow](ARCHITECTURE.md) explains how OpenJDK, Graal,
  Divining, BuboL, VTune, and Async-profiler fit together.
- [Research scope and evidence](RESEARCH-SCOPE.md) distinguishes the checked-in
  demonstration from the broader published evaluation.
- [Troubleshooting](TROUBLESHOOTING.md) maps common symptoms to likely causes and
  recovery commands.
- [Future work](FUTURE-WORK.md) describes the path towards vendor-neutral hardware
  counters, AMD support, broader benchmark coverage, and fuller profiler adapters.

The canonical entry point is `Tests/Compile-Build-Divine-Bubo.sh`. Stage scripts
under `Tests/Stages/` are implementation details and expect pipeline state to have
already been created by that entry point.
