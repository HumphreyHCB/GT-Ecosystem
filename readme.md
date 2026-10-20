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
downloads the pinned boot JDK and `mx`, initializes the top-level submodules,
builds the AWFY benchmark JAR and its JNI library, and verifies hardware
Hotspots collection and the rest of the setup.

Then run the complete pipeline:

```bash
./Tests/Compile-Build-Divine-Bubo.sh
```

All paths in `Tests/config.config` are relative to that file, so the checkout
can live anywhere. To inspect a machine without changing it, run:

```bash
./Tests/Verify-Dependencies.sh
```
