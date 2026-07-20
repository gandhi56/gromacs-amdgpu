# GROMACS benchRIB baseline + rocprofv3 bottleneck report

- **Date:** 2026-07-19 (updated 2026-07-20 with machine-scheduler analysis, section 4)
- **GPU:** AMD Instinct MI210 (`gfx90a`, CDNA2, 104 CUs, 64 KB LDS/CU, 32 waves/CU peak)
- **Toolchain:** ROCm 6.4.1 stable clang (`/opt/rocm/lib/llvm/bin/clang++`)
- **GROMACS:** 2026.3 HIP-enablement fork @ `7f24a2dbf3`, mixed precision, VkFFT
- **System:** benchRIB (2.13 M atoms, 4 fs, all-bonds constrained -> update on CPU)
- **Task residency:** `-nb gpu -pme gpu -pmefft gpu`; update/constraints on CPU (update groups disabled: incompatible virtual site)

## 1. Baseline performance (untraced)

| Metric | Value |
|---|---|
| Performance | **11.316 ns/day** |
| ms/step | 30.54 |
| Matom*steps/s | 69.95 |

Run: `.work/runs/stable-rocm6.4.1__benchRIB__baseline/` (10000 steps, reset at 5000; PME tuning settled at grid 240^3, coulomb cutoff 1.0).

## 2. GPU kernel time breakdown (rocprofv3, 1000 steps, `-notunepme`)

Total traced GPU time 29,709 ms.

| Category | Kernel | ms/call | % GPU time |
|---|---|---|---|
| pme_spread | `pmeSplineAndSpreadKernel<4,...>` | 16.39 | **55.2%** |
| nbnxm | `nbnxmKernel<...ElecType2,VdwType2...>` | 10.05 | **34.4%** |
| pme_gather | `pmeGatherKernel<4,...>` | 1.36 | 4.6% |
| fft | `VkFFT_main` | 0.19 (x6/step) | 3.8% |
| reduce/other | reduce, prune, solve, memory | - | ~2% |

Two kernels account for **~90%** of GPU time. Run: `.work/runs/stable-rocm6.4.1__benchRIB__kernel-baseline/kernel_result.json`.

## 3. Hardware-counter deep dive (rocprof-compute, MI210)

Reports: `.work/runs/stable-rocm6.4.1__benchRIB__compute/analyze_{pmeSpline,nbnxm}.txt`.
(Some ratio metrics from the v2 collector are noisy due to counter multiplexing over a short run; the resource/occupancy/wave-cycle counters below are stable.)

### pmeSplineAndSpreadKernel  (55% of GPU time)

| Metric | Value | Interpretation |
|---|---|---|
| VGPR / SGPR | 28 / 32 | low register pressure |
| Scratch/workitem | 0 | **no spills** |
| LDS/workgroup | 33,280 B (WG=512) | **occupancy-limited: 1 WG/CU -> ~8/32 waves (25%)** |
| Wave cycles | ~703 k | - |
| Dependency wait | ~405 k (**~58% of wave cycles**) | **latency-bound** |
| Issue wait | ~226 k (~32%) | issue-starved |
| VALU utilization | 40% | not compute-saturated |
| VALU active threads | 40.2 / 64 (63%) | lane divergence / partial waves |
| LDS bank conflicts | ~0.02 /access | negligible |
| Occupancy limiter (SPI) | Insufficient CU LDS 14%, SIMD VGPR 11% | LDS-first |

### nbnxmKernel  (34% of GPU time)

| Metric | Value | Interpretation |
|---|---|---|
| VGPR / SGPR | 64 / 64 | **VGPR limits occupancy** |
| Scratch/workitem | 0 | **no spills** |
| LDS/workgroup | 2,048 B (WG=64) | not LDS-limited |
| Wave cycles | ~771 k | - |
| Dependency wait | ~440 k (**~57% of wave cycles**) | **latency-bound** |
| Issue wait | ~237 k (~31%) | issue-starved |
| VALU utilization | 48% | heavy VALU (14.3k instr/wave) but not saturated |
| VALU active threads | 35.5 / 64 (56%) | strong divergence (cutoff culling) |
| vL1D / L2 hit | 97% / 59% | good L1, moderate L2 |
| Occupancy limiter (SPI) | Insufficient SIMD VGPR 14%, CU LDS 17% | VGPR-first |

## 4. Machine-scheduler deep dive (pmeSplineAndSpreadKernel)

Tooling: assertions-enabled `llc` (LLVM 24, AMDGPU-only) built at `.work/llc-asserts/bin/`; per-kernel device IR isolated with `llvm-extract` into `.work/ir/pmeSplineAndSpread.hot.ll`. Trace: `llc -mcpu=gfx90a -O3 -debug-only=machine-scheduler` -> `.work/ir/pme.misched.log` (98,670 lines).

Standalone codegen: **23 VGPR / 30 SGPR, 0 spills, Occupancy 2 waves/EU** (= 8 waves/CU = 1 workgroup, matching the LDS cap). The GCN scheduler confirms it is occupancy-saturated and abandons any attempt to improve it:

```
Starting occupancy is 2.
[PreRARemat] ... no objective to achieve, occupancy is maximal at 2
```

Pick-reason histogram over 1,673 regions: `FIRST` 2822, `ORDER` 1536, `STALL` 683, `TOP` 461, `BOT` 243 — and **zero** `RegExcess`/`RegCritical`/`RegMax`. The scheduler is not register-limited; it has freedom but is constrained by true dependencies.

Critical path: the worst region (**120 cycles**) is a serial chain of ~24 `DS_ADD_F32 ... seq_cst (addrspace 3)` LDS atomic accumulations (the spline spread), joined by `Ord` memory-ordering edges (5-cycle DS latency x 24 ≈ 120). The IR contains 50 `atomicrmw fadd seq_cst`.

### Experiment: can weakening/removing the atomics break the chain? No.

| Variant | max CP | ΣCP (170 regions) | Ord edges |
|---|---|---|---|
| `seq_cst` (baseline) | 120 | 3530 | 1111 |
| `monotonic` (relaxed) | 120 (no change) | 3530 | 1119 |
| non-atomic load/fadd/store | 133 (worse) | 3577 | 2120 |

- `seq_cst -> monotonic` has **no effect**. LLVM models any `atomicrmw` (which cannot be weaker than `monotonic`) as ordered memory (`MachineMemOperand::isUnordered()` is false), so `ScheduleDAGInstrs::buildSchedGraph` serializes consecutive atomics regardless of ordering strength.
- Full privatization to non-atomic load/fadd/store is **worse**: BasicAA cannot disambiguate the computed LDS addresses, so it adds more WAR/WAW ordering edges instead of parallelizing.

**Conclusion:** for PME spread the machine scheduler is already doing all it can. The serialization is bound by (1) LDS-capped occupancy (=2 waves/EU, so no TLP to hide the chain) and (2) memory disambiguation of the spread addresses (atomics are required for cross-thread grid-cell collisions, so the backend cannot legally drop them). **Backend scheduler tuning has a low ceiling for this kernel**; the leverage is algorithmic (privatized accumulation) and occupancy (LDS footprint), not scheduling.

Artifacts: `.work/ir/pmeSplineAndSpread.{hot,relaxed,privatized}.ll`, `.work/ir/pme.{misched,relaxed.misched,privatized.misched}.log`, `.work/ir/pmeSplineAndSpread.misched.s`.

## 5. Diagnosis

Both dominant kernels show the **same signature: latency-bound execution at low occupancy** — dependency-wait cycles are ~57-58% of all wave cycles while VALU utilization is only 40-48%. The GPU is idle waiting on dependency chains, not compute- or memory-bandwidth-saturated.

- `pmeSplineAndSpreadKernel`: occupancy capped by **LDS capacity** (33 KB/WG => 1 WG/CU, 2 waves/EU). Register pressure is low (no remat/regalloc lever). The latency chain is serialized `seq_cst` LDS atomic accumulation that the machine scheduler provably **cannot** reorder (section 4) — neither relaxing the ordering nor privatizing helps. Backend scheduling has a low ceiling; the real levers are raising occupancy (LDS footprint) and restructuring the accumulation, both largely algorithmic.
- `nbnxmKernel`: occupancy capped by **VGPR count (64)**. Shaving VGPRs would let more waves resident and directly hide the 57% dependency stalls — a genuine backend lever (not yet scheduler-analyzed the way PME was).
- No register spilling in any kernel -> spill reduction is **not** the lever here.
- Lane efficiency is 56-63% -> real algorithmic divergence; a limited target for the backend.

## 6. Prioritized AMDGPU compiler-backend next steps

Ranked by expected impact on this workload, updated for the section-4 findings:

1. **VGPR pressure reduction in `nbnxmKernel` (highest-confidence backend lever).**
   Occupancy is VGPR-limited at 64. Target register allocation / rematerialization / live-range splitting to drop below the 64->56->48 occupancy thresholds (gfx90a VGPRs allocate in blocks; more waves/EU directly hide the 57% dependency stall). Validate occupancy with `-amdgpu-waves-per-eu` and confirm no spills are introduced. Recommend running the same `llc -debug-only=machine-scheduler` analysis on `nbnxmKernel_f_noprune.hot.ll` to confirm it is register- (not atomic-) bound before investing.

2. **PME spread: occupancy + accumulation restructuring (mostly algorithmic; backend has low ceiling).**
   Section 4 shows scheduler/atomic-ordering tuning does not help. The wins are (a) reduce the 33 KB LDS footprint to lift occupancy above 2 waves/EU, and (b) privatize accumulation (per-wave LDS staging with plain, AA-disambiguatable stores, then a single reduced flush) so the inner loop is no longer a serial atomic chain. These need GROMACS-side changes; the backend role is to ensure the staged stores are then well-scheduled.

3. **AMDGPU alias analysis for structured LDS accesses (enabler for #2).**
   The privatization probe regressed because BasicAA could not disambiguate base+constant-offset LDS pointers. Improving AA so provably-distinct grid-cell accesses are not over-serialized would unlock the non-atomic accumulation path.

4. **Address / scalar-math offload (medium).**
   SALU work is 2.0-2.2k instr/wave. Push more uniform index/address computation to the scalar unit (uniformity analysis, LICM, strength reduction of grid-index math in spread/gather) to free VALU issue slots.

5. **Cross-lane / packed-math for reductions (medium, nbnxm).**
   The force reduction and partial-wave patterns may benefit from DPP-based cross-lane ops instead of LDS round-trips; check whether the backend emits `v_*_dpp` / `ds_swizzle` for the reduction idioms, and improve selection if not.

### How to validate improvements
Build a custom LLVM (`scripts/build-llvm.sh`), then `scripts/build-gromacs.sh dev`, and A/B against these baselines:
- ns/day: `scripts/bench-llvm-commit --system benchRIB` vs `stable-rocm6.4.1__benchRIB__baseline`.
- per-kernel: `scripts/kernel-bench dev-current benchRIB <tag>` diffs against `stable-rocm6.4.1__benchRIB__kernel-baseline`.
Watch `pmeSplineAndSpreadKernel` and `nbnxmKernel` ms/call and re-check dependency-wait % and (for nbnxm) VGPR/occupancy via rocprof-compute.

For codegen-level iteration, extract device IR with `scripts/emit-device-ir` (point `GMX_BUILD_DIR` at the build to inspect), isolate a kernel with `llvm-extract --recursive --func=<mangled>`, and study the backend with the assertions `llc` at `.work/llc-asserts/bin/llc -mcpu=gfx90a -O3 -debug-only=machine-scheduler`.

## Appendix: environment notes / harness fixes applied

- Machine differs from repo defaults (`gfx1201`/ROCm 7.12). Overrides live in gitignored `.env`: `ROCM_ROOT=/opt/rocm`, `GPU_ARCH=gfx90a`, `STABLE_BUILD=stable-rocm6.4.1`.
- `PATH` prepends `/opt/rocm/bin` in `.env`: the standalone rocprofiler-sdk 7.14 tools in `~/bin` LD_PRELOAD a mismatched `amd_comgr`/`hip` runtime that breaks VkFFT's hiprtc compile under tracing. The ROCm-6.4.1 `rocprofv3`/`rocprof-compute` work correctly.
- rocprofv3 kernel stats aggregate over the whole run; use `-notunepme` (not `-resetstep`) under tracing to avoid the "PME tuning still active" reset error.
- `rocprof-compute` was run directly (not via `gmxrun --profile=compute`) because it rejects `-`/`.` in `-n`; deps installed in `.work/rpc-venv`.
- Machine-scheduler analysis (section 4) needs assertions; no assertion `llc` existed, so one was built (AMDGPU-only, LLVM 24 from `/home/angandhi/llvm-project`) at `.work/llc-asserts/bin/` in ~3.5 min on 64 cores. Device IR was emitted from the stable build via `GMX_BUILD_DIR=.work/build/gromacs-stable scripts/emit-device-ir --isa`; note this IR is from ROCm clang 19 and auto-upgrades under LLVM 24 `llc`.
