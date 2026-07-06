#!/usr/bin/env bash
# build-llvm.sh - configure (if needed) and build the custom LLVM used to
# compile GROMACS device code.
#
# Usage: build-llvm.sh [--reconfigure] [--clean]
#   --reconfigure  wipe the CMake cache and re-run configure
#   --clean        `ninja clean` before building
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/config.sh"

RECONFIGURE=0
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --reconfigure) RECONFIGURE=1 ;;
    --clean)       CLEAN=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

[ -d "$LLVM_DIR/llvm" ] || { echo "error: LLVM sources missing at $LLVM_DIR — run clone-sources.sh first" >&2; exit 1; }

if [ "$RECONFIGURE" -eq 1 ]; then
  rm -f "$LLVM_BUILD/CMakeCache.txt"
fi

if [ ! -f "$LLVM_BUILD/CMakeCache.txt" ]; then
  echo "=== configuring LLVM -> $LLVM_BUILD ==="
  cmake -G Ninja -S "$LLVM_DIR/llvm" -B "$LLVM_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_ASSERTIONS=ON \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_ENABLE_RUNTIMES="compiler-rt" \
    -DLLVM_TARGETS_TO_BUILD="AMDGPU;X86"
fi

[ "$CLEAN" -eq 1 ] && ninja -C "$LLVM_BUILD" clean

echo "=== building LLVM (-j$NINJA_JOBS) ==="
ninja -j"$NINJA_JOBS" -C "$LLVM_BUILD"

echo ""
echo "LLVM built: $LLVM_BUILD/bin/clang++"
echo "  commit: $(git -C "$LLVM_DIR" rev-parse --short HEAD)"
