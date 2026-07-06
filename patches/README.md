# patches

GROMACS source tweaks applied on top of the pinned commit in
[versions.env](../versions.env) by `clone-sources.sh`. Each is a `git diff`
against `$GMX_SRC` and is applied idempotently (skipped if already present).

- `0001-pme-spline-k3-peel.patch` — peels the `k=3` iteration of the PME spline
  computation in `pme_gpu_calculate_splines_hip.h`, collapsing the central term
  algebraically to save FP ops the optimizer cannot recover.
