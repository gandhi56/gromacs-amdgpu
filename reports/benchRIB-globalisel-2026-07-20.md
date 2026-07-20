# GROMACS benchRIB: AMDGPU GlobalISel & new-reg-bank-select evaluation

- **Date:** 2026-07-20
- **GPU:** AMD Instinct MI210 (`gfx90a`, CDNA2, 104 CUs, 64 KB LDS/CU, 32 waves/CU peak)
- **GROMACS:** 2026.3 HIP-enablement fork @ `7f24a2dbf3`, mixed precision, VkFFT
- **System:** benchRIB (2.13 M atoms, 4 fs, all-bonds constrained -> update on CPU)
- **Task residency:** `-nb gpu -pme gpu -pmefft gpu`; update/constraints on CPU
- **Baseline reference:** `reports/benchRIB-baseline-2026-07-19.md` (SelectionDAG, ROCm clang 19)

## 0. TL;DR

Enabling the AMDGPU **GlobalISel** selector, and additionally the **new reg-bank
select + reg-bank legalize** passes (`-new-reg-bank-select`), both **regress**
benchRIB end-to-end by ~7% versus the SelectionDAG baseline, and are
statistically tied with each other. The two kernels that dominate runtime
(`pmeSplineAndSpreadKernel` ~55%, `nbnxmKernel` ~33%) get markedly slower;
several mid-size PME kernels improve, but not enough to matter.

| build | selector / reg-bank | compiler | ns/day | vs baseline |
|---|---|---|---|---|
| `stable-rocm6.4.1` | SelectionDAG | ROCm clang 19 | **11.316** | — |
| `stable-rocm6.4.1-gisel` | GlobalISel + generic `RegBankSelect` | ROCm clang 19 | 10.464 | **−7.5%** |
| `…-gisel-newrbs` | GlobalISel + `amdgpu-regbankselect`/`-legalize` | LLVM 24 (dev) | 10.484 | **−7.3%** |

ms/step: 30.54 (baseline) -> 33.03 (gisel) -> 32.97 (newrbs).

## 1. Configurations

### 1a. `stable-rocm6.4.1-gisel` — GlobalISel, generic RegBankSelect
- Compiler: ROCm 6.4.1 clang 19 (`/opt/rocm/lib/llvm/bin/clang++`).
- Device flags (host x86 TUs unaffected): `-Xarch_device -mllvm=-global-isel -Xarch_device -mllvm=-global-isel-abort=2`.
- Built via `scripts/build-gromacs.sh stable --global-isel`.
- **Zero** GlobalISel fallbacks: clang 19's GISel selects every device function through the generic `RegBankSelect`.

### 1b. `…-gisel-newrbs` — GlobalISel + new AMDGPU reg-bank passes
- Compiler: **`/home/angandhi/llvm-project`** LLVM 24 @ `6ddd5735799e` (clang resource dir `clang/23`). The `.work` LLVM clone and ROCm clang 19 do **not** carry this option — only this checkout does.
- Device flags: as above **plus** `-Xarch_device -mllvm=-new-reg-bank-select`.
- Built via `scripts/build-gromacs.sh dev --new-reg-bank-select` (with `LLVM_DIR`/`LLVM_BUILD` pointed at `/home/angandhi/llvm-project`).

`-new-reg-bank-select` is a `cl::opt<bool>` (default off) in
`llvm/lib/Target/AMDGPU/AMDGPUTargetMachine.cpp`; when set, `addRegBankSelect()`
runs `createAMDGPURegBankSelectPass()` + `createAMDGPURegBankLegalizePass()`
instead of the generic `RegBankSelect`:

```cpp
bool GCNPassConfig::addRegBankSelect() {
  if (NewRegBankSelect) {
    addPass(createAMDGPURegBankSelectPass());
    addPass(createAMDGPURegBankLegalizePass());
  } else {
    addPass(new RegBankSelect());
  }
  return false;
}
```

## 2. End-to-end performance (untraced, 40 000 steps)

| build | ns/day | Δ vs baseline | Δ vs gisel | run dir |
|---|---|---|---|---|
| baseline (DAG, clang 19) | 11.316 | — | — | `stable-rocm6.4.1__benchRIB__baseline` |
| gisel (clang 19) | 10.464 | −7.5% | — | `stable-rocm6.4.1-gisel__benchRIB__gisel` |
| newrbs (LLVM 24) | 10.484 | −7.3% | +0.2% | `dev-llvm-6ddd5735799e-20260720-1239-gisel-newrbs__benchRIB__newrbs` |

`-new-reg-bank-select` is within noise of plain GlobalISel end-to-end.

## 3. Per-kernel breakdown (rocprofv3 kernel trace, 1000 steps)

Average per-call kernel duration; `newrbs` compared to both baselines.
`*` = the two kernels that dominate GPU time.

| kernel | share | base (µs) | gisel (µs) | newrbs (µs) | newrbs vs base | newrbs vs gisel |
|---|---|---|---|---|---|---|
| pmeSplineAndSpread* | ~55% | 16393.2 | 18790.4 | 18664.2 | **+13.9%** | −0.7% |
| nbnxm (force, noprune)* | ~33% | 10045.7 | 12965.7 | 12825.6 | **+27.7%** | −1.1% |
| pmeGather | ~5% | 1362.6 | 1321.6 | 1232.7 | −9.5% | −6.7% |
| pmeSolve (true) | small | 176.1 | 187.2 | 137.7 | −21.8% | −26.5% |
| pmeSolve (false) | small | 97.5 | 81.8 | 82.5 | −15.4% | +0.8% |
| VkFFT_main | ~4% | 185.7 | 143.5 | 144.7 | −22.1% | +0.9% |
| transformXToXq | ~0.7% | 208.9 | 199.4 | 247.8 | +18.6% | +24.3% |
| nbnxm (force, prune) | small | 10723.5 | 14828.8 | 15268.7 | +42.4% | +3.0% |
| pruneOnly (first) | small | 3643.9 | 3853.3 | 3746.3 | +2.8% | −2.8% |
| reduceKernel | ~0.6% | 184.5 | 184.7 | 184.6 | +0.0% | −0.1% |

Runs: `stable-rocm6.4.1-gisel__benchRIB__kernel-gisel`,
`dev-llvm-…-newrbs__benchRIB__kernel-newrbs`.

Takeaways:
- **new-regbank helps a few mid-size PME kernels** (`pmeGather` −6.7%, `pmeSolve(true)` −26.5% vs old-regbank GISel) but they are too small to move ns/day.
- On the hot `nbnxmKernel` it is **within ~1%** of the generic RegBankSelect GISel path.
- Both GISel builds are far worse than DAG on the two hot kernels.

## 4. Fallbacks — the flag never reached the #1 hot kernel

Building `newrbs` emitted **1597** `-Wbackend-plugin` "Instruction selection used
fallback path" warnings: the new reg-bank legalizer cannot handle many kernels
and they revert to SelectionDAG. Unique kernels that fell back:

| kernel family | fallbacks |
|---|---|
| `nbfeKernel` (free energy) | 896 |
| `nbnxmKernel` (various energy/prune variants) | 448 |
| `nbfeForeignKernel` | 224 |
| `pmeSplineAndSpreadKernel` | 16 |
| `nbnxmKernelPruneOnly` | 8 |
| `lincsKernel` | 4 |
| `rocprim lookback_scan` | 1 |

Crucially, **the exact benchRIB-hot PME-spread variant fell back to DAG**:
`pmeSplineAndSpreadKernel<4,true,true,true,true,1,false,(ThreadsPerAtom)0,64>`
(`_Z24pmeSplineAndSpreadKernelILi4ELb1ELb1ELb1ELb1ELi1ELb0EL14ThreadsPerAtom0ELi64EE`).
So ~55% of GPU time in the `newrbs` build **did not use** the new reg-bank path.
By contrast:
- the hot `nbnxmKernel<true,false,false,(ElecType)2,(VdwType)2,1,(PairlistType)4>` did **not** fall back -> uses the new path;
- `pmeGatherKernel` did **not** fall back -> uses the new path.

The `stable-rocm6.4.1-gisel` (ROCm clang 19) build had **zero** fallbacks — the generic `RegBankSelect` handles everything.

## 5. Confounds & caveats

1. **Compiler version differs** between the two GISel builds. `newrbs` uses upstream **LLVM 24**; baseline and `gisel` use **ROCm clang 19**. Evidence this matters: `pmeSplineAndSpread` is +13.9% vs baseline in `newrbs` **even though it fell back to SelectionDAG in both** — i.e. that delta is an LLVM-24-vs-19 SelectionDAG codegen regression, *not* a reg-bank effect. A clean A/B of the flag requires holding the compiler fixed (see §7).
2. **Wall time vs ns/day.** The GISel runs show much larger wall time (~1365 s vs 389 s) dominated by PME grid auto-tuning / host setup; `ns/day` is GROMACS's steady-state metric and is the fair comparison.
3. **`-global-isel-abort=2`** (warn + fall back) was used so the build could not fail; this is what produces the fallbacks in §4 rather than hard errors.

## 6. Diagnosis

- The new reg-bank legalizer is **not yet mature** on this fork: it fails to legalize a large fraction of GROMACS device kernels (§4), including the single most important one, so it cannot help the workload today.
- Where it *does* apply, it is roughly neutral on the hot `nbnxmKernel` and a modest win on a few small PME kernels — consistent with the general finding (baseline report §3–4) that these kernels are **latency-/occupancy-bound**, not instruction-selection-bound. Changing the selector/reg-bank strategy does not address the dominant bottleneck (LDS-capped occupancy for PME spread, VGPR-capped occupancy for nbnxm).
- GlobalISel overall (either reg-bank path) produces worse code than SelectionDAG for the two hot, register/LDS-pressured kernels on gfx90a.

## 7. Suggested follow-ups

1. **Isolate the flag from the compiler.** Build a third variant — plain `--global-isel` (generic RegBankSelect) with the **same** `/home/angandhi/llvm-project` LLVM 24 — so the only delta vs `newrbs` is `-new-reg-bank-select`. This removes the LLVM-24-vs-19 confound in §5.1 and yields a clean old-vs-new reg-bank comparison.
2. **Investigate the PME-spread fallback.** Capture *why* `amdgpu-regbanklegalize` bails on the hot spread kernel (`-mllvm -global-isel-abort=1` to get the failing MIR, or `-debug-only=amdgpu-regbanklegalize`). If it is a small set of unhandled opcodes, that is actionable backend work.
3. **Per-kernel ISA diff** (new-regbank vs DAG) for `nbnxmKernel` to see whether the +28% is VGPR/occupancy (matches the baseline-report thesis) or scheduling.
4. Track upstream: in the newer `.work` LLVM clone the new reg-bank passes are already the **default** GISel path (the `-new-reg-bank-select` toggle has been removed), so this evaluation should be repeated as the passes mature.

## Appendix: harness changes

- `scripts/build-gromacs.sh` gained `--global-isel` and `--new-reg-bank-select` (device-scoped via `-Xarch_device`; install/build dirs get `-gisel`/`-gisel-newrbs` suffixes). Dev builds now also pass `--target=x86_64-unknown-linux-gnu -D__AMDGCN_WAVEFRONT_SIZE=64`, required because the upstream clang has no default target triple and predates ROCm 6.4.1's wavefront-size macro rename.
- The `/home/angandhi/llvm-project` clang/lld/llc were rebuilt (binary was stale relative to the source that added `-new-reg-bank-select`). Its own resource dir (`clang/23`) declares the full `__ocml_*` set, so no header shim was needed (unlike the `.work` LLVM 24, whose trimmed `__clang_hip_libdevice_declares.h` drops `__ocml_ceil_f64` et al.).
- Build/run logs: `.work/logs/build-stable-gisel.log`, `.work/logs/build-dev-newrbs.log`, `.work/logs/run-{gisel,newrbs}-{perf,trace}.log`.
