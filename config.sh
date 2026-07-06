# shellcheck shell=bash
# config.sh - single source of truth for all paths used by the
# gromacs-amdgpu performance harness.
#
# Every value uses ": ${VAR:=default}" so it can be overridden from the
# environment. Defaults live inside this repo under .work/ so a fresh clone
# is fully self-contained. To reuse the historical system-wide layout:
#
#   export GMX_INSTALL_ROOT=/opt/gromacs
#   export RUNS_DIR=/var/lib/gromacs-runs
#
# Then source this file (scripts do this automatically).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

# --- work dir (all heavy, regenerable artifacts live here; gitignored) ---
: "${WORK_DIR:=$REPO_ROOT/.work}"

# --- source checkouts ---
: "${SRC_DIR:=$WORK_DIR/src}"
: "${LLVM_DIR:=$SRC_DIR/llvm-project}"
: "${LLVM_BUILD:=$LLVM_DIR/build}"
: "${GMX_SRC:=$SRC_DIR/gromacs}"

# --- gromacs build tree + install roots ---
: "${GMX_BUILD_DIR:=$WORK_DIR/build/gromacs-dev}"
: "${GMX_BUILD_DIR_STABLE:=$WORK_DIR/build/gromacs-stable}"
: "${GMX_INSTALL_ROOT:=$WORK_DIR/installs}"   # replaces /opt/gromacs

# --- simulation run outputs + prebuilt system inputs ---
: "${RUNS_DIR:=$WORK_DIR/runs}"               # replaces /var/lib/gromacs-runs
: "${SYSTEMS_DIR:=$RUNS_DIR/_systems}"

# --- toolchain / hardware ---
: "${ROCM_ROOT:=/opt/rocm/core-7.12}"
: "${GPU_ARCH:=gfx1201}"
: "${STABLE_BUILD:=stable-rocm7.12}"          # name of the ROCm-clang baseline build
: "${NINJA_JOBS:=8}"
: "${OMP_THREADS:=16}"

export WORK_DIR SRC_DIR LLVM_DIR LLVM_BUILD GMX_SRC \
       GMX_BUILD_DIR GMX_BUILD_DIR_STABLE GMX_INSTALL_ROOT \
       RUNS_DIR SYSTEMS_DIR ROCM_ROOT GPU_ARCH STABLE_BUILD \
       NINJA_JOBS OMP_THREADS

# Optional secrets / overrides (e.g. DISCORD_WEBHOOK_URL) from an ignored .env
if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$REPO_ROOT/.env"
  set +a
fi
