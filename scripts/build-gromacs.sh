#!/usr/bin/env bash
# build-gromacs.sh - configure, build and install GROMACS with HIP for AMDGPU.
#
# Usage: build-gromacs.sh [dev|stable] [--reconfigure] [--clean]
#
#   dev     (default) compile device code with the custom LLVM at $LLVM_BUILD.
#           Installs to $GMX_INSTALL_ROOT/dev-llvm-<llvmhash>-<date> and
#           repoints the $GMX_INSTALL_ROOT/dev-current symlink.
#   stable  compile with ROCm's bundled clang. Installs to
#           $GMX_INSTALL_ROOT/$STABLE_BUILD (the benchmark baseline).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/config.sh"

FLAVOR="dev"
RECONFIGURE=0
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    dev|stable)    FLAVOR="$arg" ;;
    --reconfigure) RECONFIGURE=1 ;;
    --clean)       CLEAN=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

[ -d "$GMX_SRC" ] || { echo "error: GROMACS sources missing at $GMX_SRC — run clone-sources.sh first" >&2; exit 1; }

# Shared HIP compile flags (from the captured dev CMake cache).
HIP_FLAGS="--rocm-path=$ROCM_ROOT --offload-arch=$GPU_ARCH -fPIC -ffast-math -munsafe-fp-atomics -fdenormal-fp-math=ieee -fcuda-flush-denormals-to-zero -Wno-unused-command-line-argument -Wno-pass-failed"

if [ "$FLAVOR" = "dev" ]; then
  [ -x "$LLVM_BUILD/bin/clang++" ] || { echo "error: custom clang++ missing at $LLVM_BUILD/bin — run build-llvm.sh first" >&2; exit 1; }
  HIP_COMPILER="$LLVM_BUILD/bin/clang++"
  BUILD_DIR="$GMX_BUILD_DIR"
  LLVM_HASH="$(git -C "$LLVM_DIR" rev-parse --short HEAD)"
  [ -n "$(git -C "$LLVM_DIR" status --porcelain)" ] && LLVM_HASH="${LLVM_HASH}-dirty"
  INSTALL_NAME="dev-llvm-${LLVM_HASH}-$(date +%Y%m%d-%H%M)"
else
  HIP_COMPILER="$ROCM_ROOT/lib/llvm/bin/clang++"
  [ -x "$HIP_COMPILER" ] || { echo "error: ROCm clang++ missing at $HIP_COMPILER" >&2; exit 1; }
  BUILD_DIR="$GMX_BUILD_DIR_STABLE"
  INSTALL_NAME="$STABLE_BUILD"
fi

INSTALL_PREFIX="$GMX_INSTALL_ROOT/$INSTALL_NAME"

echo "=== GROMACS build ($FLAVOR) ==="
echo "  compiler: $HIP_COMPILER"
echo "  build:    $BUILD_DIR"
echo "  install:  $INSTALL_PREFIX"

[ "$RECONFIGURE" -eq 1 ] && rm -f "$BUILD_DIR/CMakeCache.txt"

if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
  echo "=== configuring ==="
  cmake -S "$GMX_SRC" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DGMX_GPU=HIP \
    -DCMAKE_HIP_COMPILER="$HIP_COMPILER" \
    -DCMAKE_HIP_COMPILER_ROCM_ROOT="$ROCM_ROOT" \
    -DCMAKE_HIP_FLAGS="$HIP_FLAGS" \
    -DGMX_HIP_TARGET_ARCH="$GPU_ARCH" \
    -DCMAKE_HIP_ARCHITECTURES="$GPU_ARCH" \
    -DGPU_TARGETS="$GPU_ARCH" \
    -DCMAKE_PREFIX_PATH="$ROCM_ROOT" \
    -DGMX_MPI=OFF \
    -DGMX_OPENMP=ON \
    -DGMX_BUILD_OWN_FFTW=OFF \
    -DGMX_DOUBLE=OFF \
    -DGMX_SIMD=AVX2_256 \
    -DGMX_USE_RDTSCP=ON \
    -DHIPCC_HAS_TARGET_ARCH_gfx1201=TRUE \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX"
elif [ "$FLAVOR" = "dev" ]; then
  # Incremental builds reuse CMakeCache but INSTALL_NAME gets a fresh
  # timestamp each run. Keep CMAKE_INSTALL_PREFIX in sync so install and
  # the dev-current symlink target the same directory.
  CACHED_PREFIX=$(grep -E '^CMAKE_INSTALL_PREFIX:PATH=' "$BUILD_DIR/CMakeCache.txt" | cut -d= -f2-)
  if [ "$CACHED_PREFIX" != "$INSTALL_PREFIX" ]; then
    echo "=== updating install prefix ==="
    echo "  was: $CACHED_PREFIX"
    echo "  now: $INSTALL_PREFIX"
    cmake -S "$GMX_SRC" -B "$BUILD_DIR" -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX"
  fi
fi

if [ "$CLEAN" -eq 1 ]; then
  ninja -C "$BUILD_DIR" clean
  # HIP intermediate artifacts left behind by -save-temps style builds
  ( cd "$BUILD_DIR" && rm -f ./*.bc ./*.o ./*.s ./*.resolution.txt ./*.hipfb ./*.out ./*.img ./*.hipi 2>/dev/null || true )
fi

echo "=== building + installing (-j$NINJA_JOBS) ==="
ninja -j"$NINJA_JOBS" -C "$BUILD_DIR" install

if [ "$FLAVOR" = "dev" ]; then
  mkdir -p "$GMX_INSTALL_ROOT"
  ln -sfn "$INSTALL_PREFIX" "$GMX_INSTALL_ROOT/dev-current"
  echo "  dev-current -> $INSTALL_NAME"
fi

echo ""
echo "Installed: $INSTALL_PREFIX"
echo "  run with: scripts/gmxrun $INSTALL_NAME <system> <tag>"
