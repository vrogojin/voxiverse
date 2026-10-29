---
name: voxiverse-streaming-supply-demand
description: "2026-07-17 SETTLED — walk jank is supply<demand (23-35 blocks/s vs ~90-100 needed, 130ms/block = ~10x WASM penalty); NOT allocator/apply/draws/workers. User's direction = cut+reorder demand (surface-first, priority, drop/re-prioritize). KEY LESSON: never judge perf on stats conditioned on the streaming state."
metadata: 
  node_type: memory
  type: project
---

**THE MEASURED TRUTH (real user laptop, 2026-07-17).** Streaming jank is a **supply < demand** problem, permanently:
- Supply **23-35 blocks/s** (N=3→6 workers). Walking demand **~90-100 blocks/s gross**. Neither config keeps up — the backlog never clears while walking.
- **~130 ms/block** per worker (N=3) / 173 ms (N=6) vs **13.7 ms native** ⇒ **~10× WASM/GDScript penalty**. This is the real ceiling. Upstream godot_voxel's own position: "GDScript generators are not scalable."
- Browser reports `hardwareConcurrency ≈ 8` (~4 physical + SMT) — **the browser is on the USER'S LAPTOP, not the 24-core dev host.** Never use dev-host `load`/`ps` as evidence about the game.

**RULED OUT BY MEASUREMENT (do not re-litigate):**
- "2-worker ceiling" — STALE (module_world.gd:18-25 comment is wrong; FP-M1b superseded it; real N=6 via ratio 0.7×hw).
- **Apply budget / mesh upload** — `vox_mesh`/`vox_main`/`vox_gpu` read 0 at p50/p90/MAX; apply is an `ITimeSpreadTask` capped 6ms; VoxelTerrain `_process` breakdown 0.02-0.08ms. Uploads run INLINE in `mesh_add_surface` (not deferred to flush) and drain↔worst r=−0.47 has the WRONG SIGN for per-upload stalls.
- **dlmalloc convoy (H-A)** — mimalloc built + VERIFIED linked (BUILD-INFO `web_malloc:mimalloc` + 6 symbols in godot.wasm); moved only worst p50 −23%; drain/phys/fps flat ⇒ demoted to minor. Patch `docker/engine/patches/godot/0002-web-malloc-option.patch` exists, default dlmalloc = inert; **PARKED pending a heap gate**, not reverted.
- **More workers** — measured: doesn't help (adds contention, adds nothing).
- Draws (149-188 in BOTH 60fps and 127ms states — the atlas already fixed that ceiling), movement (moving with gen≤5 ≡ standing), CPU contention on the dev host (wrong machine).

**⚠️ THE BIG LESSON — HOW I SHIPPED A REGRESSION:** I conditioned every stat on `vox_gen>200` ("frame quality WHILE streaming"). Capping workers 6→3 improved that a lot (worst p50 80.5→38.9, fps p10 15.4→34.4) so I shipped it — **and the user reported "longer and more frequent freezes."** Cause: N=3 cut throughput 33%, so streaming LASTS LONGER and while walking the backlog never clears. **Total experienced jank = (jank per frame) × (time spent janky).** I optimised term 1 and worsened term 2. Also: cross-session comparisons were invalid (activity mix differed wildly: 6.4% vs 26.6% vs 29.8% of windows streaming). **ALWAYS judge on INTEGRATED metrics over a fixed controlled route** — % windows worst_ms>100, unconditional fps p10, time-to-cover-256-blocks, backlog growth — never on conditioned snapshots, never across uncontrolled sessions. Reverted to ratio 0.7 (N=6).

**USER'S DESIGN DIRECTION (2026-07-17) — cut+reorder DEMAND, don't chase supply:** (1) fill terrain with **surface shells** first to satisfy the eye; (2) only the chunk immediately around the player is FULLY generated; (3) **lazy scheduler** — low-priority chunks stream only after immediate neighbours; (4) **when moving fast, DROP/re-target in-flight tasks** → chunk under player → chunks being LOOKED at → chunks immediately around → resume lazy; continuously re-prioritize the queue. **HARD CONSTRAINT: must visually cover 256 blocks around the player, fast.** (5) lazy underground depth = `FP_BULK_UNDERGROUND`, already shipped. Fable designing (`docs/COSMOS-STREAM-SCHED-DESIGN.md`) incl. inventing further tricks; **Opus to implement from the doc**.

**KEY ENABLER the user didn't know:** terrain has **NO collision meshes** — physics is fully ANALYTIC (`generate_collisions=false`; `block_id_at`/`floor_under`/`blocked` read TerrainConfig directly). **The mesh is PURELY visual**; collision/breaking/walking are correct even where nothing is meshed. So surface-only fill costs nothing in collision terms — strictly cheaper than assumed. Corollary already proven: "fall-through when running" was always a VISUAL mesh-lag artifact, never physics.

**⚠️ THE COST MODEL IS NOW MEASURED IN THE FIELD (2026-07-17, T1 per-class timer, SW-1 route, real laptop) — AND IT OVERTURNS THE DESIGN'S ASSUMPTION:**

| class | design ASSUMED | **MEASURED (baseline)** | share of total gen time |
|---|---|---|---|
| air/cheap | 30% | **53.3%** @ 7.9 ms | 2% |
| underground bulk-qualified | 25% | **5.8%** @ 17.5 ms | 1% |
| underground gate-failed | 25% @ 13.7 ms | **26.6%** @ **337.7 ms** | **51%** |
| **surface-crossing** | 20% @ **5-15 ms** | **14.4%** @ **559.8 ms** | **46%** |

**Surface-crossing blocks cost ~560 ms — ~40× the design's 5-15 ms estimate — and are ~46% of all generation time with NOTHING targeting them.** Total route gen time 423 s. Both dominant classes are 243-560 ms/block ⇒ this is the **~10× WASM/GDScript per-cell-generator penalty**, not an algorithmic/scheduling problem. **You cannot bulk-fill or re-schedule your way out of it — the lever is L5: port the worldgen inner loop (resolve_cell/column_profile/slope_run_of) to C++** inside the existing patch set (6 patches already ship; toolchain proven). Upstream godot_voxel agrees: "GDScript generators are not scalable"; VoxelGeneratorGraph ≈ C++ speed.

**R1 (FP_COLBULK, column-granular bulk) + R7 (FP_STAMP, blob scatter) — BUILT, GATES GREEN, REJECTED BY MEASUREMENT.** Both are CORRECT: FLAT 6035/0 with both ON (R7 makes underground **byte-identical** — it even retires the FP_BULK_UNDERGROUND appearance loss), verify_stamp/verify_colbulk green, and I FALSIFIED the equality gate (sabotaged `stamp_on:=false` ⇒ 43,635 mismatches caught ⇒ the gate has teeth). But SW-1 A/B: M4 only −13% (kill metric needed −50%), M1 25.4→**28.9%** worse, fps p10 9.6→**8.0** worse, one 11.2 s freeze. **Rejected by the §7 ship rule.** Why: R1 targets the gate-failed class and moved it 337.7→243.3 ms (−28%, NOT the predicted 5-14×); −28% on ~half the work ≈ −14% total ≈ the −13% M4 moved (self-consistent). Commits kept, flags OFF: a6374c0, d448035 (R1), f1d1642 (R7). **Do not re-litigate without new evidence.**

**PROCESS NOTE (cost me ~3 verification cycles):** implementation agents went idle WITHOUT reporting four times, twice with a BROKEN authoritative gate committed as if green. **Always re-run the gates yourself; never trust an agent's silence or its own gate.** Conversely I was WRONG to call verify_colbulk's oracle "too weak" — it correctly counted water as see-through and covered shorelines/mountains; the real story was that FLAT's coast test is a strict truth-mirror over ALL cells that ANY bulk-fill violates by construction (FP_BULK_UNDERGROUND escapes only by sampling luck, not correctness). **Falsify every gate before trusting its green.**

**BEST UNEXPLOITED LEVERS (from the measured cost model, docs/COSMOS-GEN-EFFICIENCY-DESIGN.md):** a land column ≈319 µs = column_profile ~2% + slope ~1.6% + **underground resolve_cell ~76%** (84 cells × 2.9 µs) + surface ~22%. So: (a) `FP_BULK_UNDERGROUND` only bulk-fills blocks ENTIRELY below the surface — **surface blocks still resolve every cell**, so a per-column sub-surface early-out INSIDE surface blocks is likely the cheapest big win; (b) a **heightfield skin** off `facet_profile` needs ZERO resolve_cell (~2% of column cost) ⇒ potentially ~50× cheaper per unit area for the 256-block visual tier. Related: [[voxiverse-walk-perf-root-cause]], [[voxiverse-web-perf-architecture]], [[voxiverse-never-oom-web]], [[voxiverse-neighbour-underground-direction]].
