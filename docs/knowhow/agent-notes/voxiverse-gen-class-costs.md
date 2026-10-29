---
name: voxiverse-gen-class-costs
description: "MEASURED per-class web gen costs (2026-07-17 T1) — surface 560ms/46%, underground 338ms/51%, web factor ×25 not ×10; R1/R7 correct-but-rejected; L5 C++ generator port promoted to THE plan, R3 skin follows it"
metadata: 
  node_type: memory
  type: project
---

Measured 2026-07-17 (T1 telemetry, SW-1 route, real laptop, N=6 workers) — supersedes every
"web ≈ ×10 native" and "surface block ≈ 5–15 ms" number in earlier docs/memories:

- Per-class wall ms/block (contention incl.): air 7.9 (53.3% of blocks, 2% of time) ·
  underground bulk-qualified 17.5 (5.8%, 1%) · underground gate-failed **337.7** (26.6%, **51%**) ·
  surface-crossing **559.8** (14.4%, **46%**). Web/native factor ≈ **×25** (337.7/13.7).
- R1 FP_COLBULK + R7 FP_STAMP (commits a6374c0, d448035, f1d1642): correct (R7 byte-equality
  gate green 6035/0, falsification-tested — 43,635 mismatches caught on sabotage), but
  **rejected by the integrated SW-1 ship rule** (M4 −13% vs −50% target; M1 +14% worse,
  M2 −17% worse; ON-build worst freeze 11.2 s UNEXPLAINED — root-cause before reconsidering).
  R1 moved its class only −28% (fillable fraction much smaller than modeled). Flags OFF in-tree.
- Verdict (docs/COSMOS-STREAM-SCHED-DESIGN.md §2.3a/§2.6): both dominant classes are
  per-cell-GDScript-interpreter-bound; no script-side order-of-magnitude lever exists.
  **L5(a) — whole `_generate_block` inner path as a C++ generator in the module patch set —
  is THE plan** (expect supply 30–35 → ~300+ blocks/s), fenced by an N-block C++==GDScript
  byte-equality gate. **R3 skin deferred to first post-L5 item** (skin samples column_profile —
  the exact function L5 ports; pre-L5 a 256-disc costs ~3–5 s, post-L5 ~free). R2/R9 demand
  shapers stay valid either way.

Related: [[voxiverse-web-perf-architecture]], [[voxiverse-perf-next-architecture]],
[[voxiverse-neighbour-underground-direction]].
