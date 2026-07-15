# patches

GROMACS source tweaks applied on top of the pinned commit in
[versions.env](../versions.env) by `clone-sources.sh`. Each is a `git diff`
against `$GMX_SRC` and is applied idempotently (skipped if already present).

_No patches currently._ The baseline is clean upstream LLVM + the pinned GROMACS
commit, so optimizations can be developed from scratch. Add new `*.patch` files
here (git diffs against `$GMX_SRC`) to capture in-tree GROMACS source changes.
