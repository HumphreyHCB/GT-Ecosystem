# GT Ecosystem

The component repositories are pinned as Git submodules under `repos/`.

Clone the complete ecosystem with:

```bash
git clone --recurse-submodules \
    https://github.com/HumphreyHCB/GT-Ecosystem.git
```

For an existing clone, initialise the component repositories with:

```bash
git submodule update --init --recursive
```

Each submodule is pinned to a tested commit. The branch recorded in
`.gitmodules` identifies the upstream branch used when deliberately updating
that component; normal checkout continues to use the pinned commit.
