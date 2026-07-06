# Benchmark systems

Each subdirectory of `$SYSTEMS_DIR` (default `.work/runs/_systems/`) holds one
prebuilt input as `topol.tpr`. `gmxrun`, `kernel-bench`, and `bench-llvm-commit`
reference systems by directory name.

## `beclin1` (shipped in this repo, built locally)

`beclin1-blm.pdb` and the four MDP templates under `beclin1/mdp/` are tracked in
git. Build the `beclin1-em`, `beclin1-nvt`, and `beclin1-npt` systems from them:

```bash
scripts/prep-beclin1            # needs a working GROMACS build (see top-level README)
```

This writes `topol.tpr` into `$SYSTEMS_DIR/beclin1-{em,nvt,npt}/`.

## `benchMEM` / `benchRIB` (fetched, not committed)

These are the standard GROMACS GPU benchmark systems from the Max Planck
Institute. Their `.tpr` files are large and not redistributed here — download
them once and drop each `topol.tpr` into `$SYSTEMS_DIR/<name>/`:

```bash
mkdir -p "${SYSTEMS_DIR:-.work/runs/_systems}"/benchMEM
cd "${SYSTEMS_DIR:-.work/runs/_systems}"/benchMEM
# from https://www.mpinat.mpg.de/grubmueller/bench
#   benchMEM.zip  -> benchMEM.tpr, rename to topol.tpr
#   benchRIB.zip  -> benchRIB.tpr, rename to topol.tpr
```

After placing `topol.tpr`, run e.g.:

```bash
scripts/gmxrun stable-rocm7.12 benchMEM baseline
```
