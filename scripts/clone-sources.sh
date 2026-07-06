#!/usr/bin/env bash
# clone-sources.sh - fetch the LLVM and GROMACS forks at their pinned commits
# into $SRC_DIR, then apply any local patches under patches/.
#
# Idempotent: existing checkouts are fetched + reset to the pinned ref rather
# than re-cloned. Safe to re-run after bumping versions.env.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/config.sh"
# shellcheck source=/dev/null
. "$HERE/versions.env"

PATCH_DIR="$HERE/patches"

# checkout <remote> <branch> <ref> <dest>
checkout() {
  local remote="$1" branch="$2" ref="$3" dest="$4"
  if [ ! -d "$dest/.git" ]; then
    echo "=== cloning $remote ($branch) -> $dest ==="
    git clone --branch "$branch" "$remote" "$dest"
  else
    echo "=== updating $dest ==="
    git -C "$dest" remote set-url origin "$remote"
    git -C "$dest" fetch origin "$branch"
  fi
  echo "--- checking out $ref ---"
  git -C "$dest" checkout --quiet "$ref"
  git -C "$dest" submodule update --init --recursive
}

mkdir -p "$SRC_DIR"

checkout "$LLVM_REMOTE" "$LLVM_BRANCH" "$LLVM_REF" "$LLVM_DIR"
checkout "$GMX_REMOTE"  "$GMX_BRANCH"  "$GMX_REF"  "$GMX_SRC"

# --- apply local patches on top of the pinned GROMACS commit ---
# These capture in-tree source tweaks that are not yet upstream (e.g. the
# PME spline k=3 peel). Patches are applied idempotently.
if compgen -G "$PATCH_DIR/*.patch" >/dev/null; then
  for p in "$PATCH_DIR"/*.patch; do
    echo "=== applying patch $(basename "$p") ==="
    if git -C "$GMX_SRC" apply --check "$p" 2>/dev/null; then
      git -C "$GMX_SRC" apply "$p"
      echo "  applied"
    elif git -C "$GMX_SRC" apply --reverse --check "$p" 2>/dev/null; then
      echo "  already applied, skipping"
    else
      echo "  WARNING: patch does not apply cleanly; skipping" >&2
    fi
  done
fi

echo ""
echo "Sources ready:"
echo "  LLVM:    $LLVM_DIR    @ $(git -C "$LLVM_DIR" rev-parse --short HEAD)"
echo "  GROMACS: $GMX_SRC @ $(git -C "$GMX_SRC" rev-parse --short HEAD)"
