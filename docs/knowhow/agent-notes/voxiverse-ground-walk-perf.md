---
name: voxiverse-ground-walk-perf
description: 2026-08-30 ground-walk jerkiness near villages (worst_ms median 150/max 378, ~7fps moving) ROOT = far-tier (far-trees+far-structures) rebuild churn every 2 blocks + credit-starvation; draws are a symptom; chunk-baking already done; flicker = SAME root; attribution blocked → FP_WORST_FRAME_ATTR instr
metadata:
  node_type: memory
  type: project
---

2026-08-30. After the de-orbit fix shipped (PR #83, 7 flags, [[voxiverse-deorbit-shell-reemit]]), user reported
poor perf + "terrific jerkiness on the ground, especially near villages" + LOD-ladder tree/house FLICKER, and
hypothesized: too many render calls? can't we bake non-terrain (villages/player-blocks) into the chunk-render loop
like Minecraft? Launched 3 parallel agents (Fable architecture + Sonnet attribution + Sonnet flicker). Live baseline:
walking near a village worst_ms median **150 / p90 238 / max 378 ms** (~7fps moving vs 38fps at rest), draws 63-152,
worst frame vox_gen=151.

SYNTHESIS (3 docs: COSMOS-GROUND-RENDER-ARCH-DESIGN, -GROUND-WALK-PERF-ATTRIBUTION, -LOD-FLICKER-DESIGN):
1. CHUNK-BAKING (user's idea) is ALREADY DONE for NEAR geometry: trees incl. leaves, village houses, and player
   edits are ALL worldgen/edit voxels IN the godot_voxel chunk mesh (terrain_config.gd:1425-1481/1433, edits via
   bulk_inject→VoxelTool→worker re-mesh). The separate MeshInstances are EXCLUSIVELY FAR impostors beyond voxel
   residency (128→2400 blk) + VoxelBody debris — can't voxelize without widening the near field (2 web workers,
   NEVER-OOM forbids). So "bake into chunks" = a NO-OP.
2. DRAWS ARE A SYMPTOM, not the cause: 171 draws ≈ 2-5ms on WebGL2 (relevant to the AT-REST 38fps ceiling only);
   30-75× too small for 150ms walking frames. Our draw count is LOWER than Minecraft (100s-2000 section draws).
3. THE REAL WALKING COST = far-tier REBUILD churn on movement: far-trees ~50-60ms FULL rebuild re-armed EVERY 2
   BLOCKS walked (cube_sphere.gd:1090-1093), far-structures merged-mesh re-upload every 2 blocks
   (facet_far_structures.gd:29,444-453), + the uninstrumented main-thread mesh-apply/upload burst in
   VoxelEngine::process (post-FP_CPPGEN apply-bound, [[voxiverse-postport-applybound]]). Attribution: named buckets
   (t_move 19.8+t_stream 18.9+phys 28.6+st_bms 12.8+smooth_v2 11.8) sum to only ~93ms of the 378ms; **~285ms (75%)
   UNATTRIBUTED**; vox_gen 151 < CTRL_BACKLOG_MAX 300 ⇒ gen SUPPLY exonerated.
4. FLICKER = SAME ROOT: the far-tier near↔far handoff is a HARD opaque swap (houses have NO alpha/dither channel);
   its completing rebuild is CREDIT-GATED (_stream_credit_ok) which is STARVED WHILE WALKING (chunk-gen competes)
   → double-render up to ~0.75s / hard-pop on essentially every boundary crossing. FP_STRUCT_NEAR_HOLD fixed only
   the inside-r0 descent gap, NOT the [r0,r0+64] walking annulus.
5. THE CHEAP LEVERS ARE ALREADY ON: FP_INFLIGHT_GATE + FP_FT_MOVE_HYST + FP_MOVE_PROBE_CACHE + FP_STREAM_TICK_ONCE
   + FP_CTRL_ADAPTIVE are ALL in the deployed cheats flag set (the attribution agent didn't know the deploy set, so
   its "flip FP_INFLIGHT_GATE" is MOOT — it's on and walking is still 150ms). Existing mitigations insufficient.

ATTRIBUTION CEILING (fought all session): 1Hz telemetry fields are a MIX of window-maxima (worst_ms, vt_total_ms) and
250ms-later/last-value snapshots (phys_ms, draws, vox_gen, st_bms) — they DON'T co-occur with the worst frame, so the
285ms burst can't be split (far-tier rebuild vs near-apply) from current telemetry. FIX = FP_WORST_FRAME_ATTR
(byte-off, NO engine rebuild): snapshot stats AT the moment remote_bridge.gd's _win_worst finds a new window max.
Being implemented on branch feat/voxiverse-ground-perf-instr. PLAN: instrument → deploy → walk-near-village A/B →
DEFINITIVELY attribute the 285ms (far-tier rebuild vs near VoxelEngine apply) → then a UNIFIED far-tier fix (perf +
flicker are one subsystem): move-churn diet (split membership-delta from camera-delta so walking never re-commits the
merged far meshes; decouple far-tier rebuild from small walk moves) + credit-INDEPENDENT bidirectional bounded
probe+streak handoff (flicker Lever A) + cross-fade (FP_FT_NEARCULL_XFADE trees + new FP_STRUCT_XFADE dither channel
for houses) + HYST_W dead-band. [[voxiverse-postport-applybound]] [[voxiverse-forest-fps-root]]
[[voxiverse-motion-phys-root]] [[voxiverse-walk-perf-root-cause]]

IMPL STATE (2026-08-30, branch feat/voxiverse-fartier-walk commit e097c3d, off feat/voxiverse-ground-perf-instr
which carries FP_WORST_FRAME_ATTR a934466). Fable design = docs/COSMOS-FARTIER-WALK-DESIGN.md. Opus impl split the
work honestly by what's headless-validatable: **SHIPPED (byte-off, FLAT 6042/0, verify_fartier_walk 27/0 off /29/0
on, verify_structures 80/0 + verify_far_trees 7/0 additive):** (1) rebuild-rate telemetry wf_ftr_rb/wf_st_rb
(behind FP_WORST_FRAME_ATTR) — measures the CURRENT churn baseline with fix flags OFF too; (2) FP_STRUCT_WALK_CALM
= the big perf win, replaces the 2-block camera re-arm in _inputs_changed with a band FINGERPRINT (_band_fp = XOR
of each in-ring structure's _root_hash × _band_code, computed free in _probe_pass) → re-commit only on real
membership/band change (expected structures −90%+ re-commits); (3) FP_FT_WALK_CALM = trees re-arm threshold raised
12→16 blk (SAFE SUBSET only — same staleness class as shipped FP_FT_MOVE_HYST, NOT the 8× claim); (4)
FP_STRUCT_HANDOFF_HYST = ±STRUCT_HYST_W Schmitt dead-band in _band_code. **DEFERRED (declared consts, EMPTY bodies —
the flicker cross-fades):** FP_FT_NEARCULL_XFADE (tree guard→alpha animator + per-frame cam_pos shader fade) +
FP_STRUCT_XFADE (house COLOR.a screen-door discard + credit-independent streak refactor of _cull_emit). Impl
correctly refused: their no-gap/no-double invariants hinge on gl_compat GPU per-fragment dither that CAN'T be proven
headless, and the _cull_emit refactor risks the shipped G-ST-HOLD/NEAR_HOLD path. Those need LIVE GPU validation =
natural follow-up AFTER the perf A/B, not a blocker. The FP_FT_WALK_CALM pixel-identity margin-widening also needs
that deferred tree shader fade (Step A) — hence threshold-only for now. PLAN NOW: adversarial review (running) of
the band-fingerprint completeness (does every membership/leave/band-cross change flip _band_fp? XOR-cancel holes?
Schmitt latch? — must not reintroduce the "houses disappeared" class FP_STRUCT_NEAR_HOLD just fixed) → deploy perf+
telemetry build via [[voxiverse-deploy-cheats-pipeline]] (CLITE_FLAGS env) → 4-arm walk-near-village A/B (baseline=
FP_WORST_FRAME_ATTR only / +Lever1 / +Schmitt / all) → attribute the 285ms via wf_ftr_rb/wf_st_rb + wf_* split →
if far-tier confirmed, ship Lever 1 + build the deferred flicker cross-fades with live GPU A/B.

LIVE A/B RESULT (2026-08-30) — NEGATIVE for Lever 1 + REFRAME. Deployed baseline (FP_WORST_FRAME_ATTR only) vs
perf (+FP_STRUCT_WALK_CALM+FP_FT_WALK_CALM+FP_STRUCT_HANDOFF_HYST) via [[voxiverse-deploy-cheats-pipeline]], user
walked the same village both arms (wf_* telemetry). (1) **FP_STRUCT_WALK_CALM DID NOT WORK**: structure re-commit
rate 17.9/min OFF → 22.0/min ON (walk-noise, NOT the designed ~90% cut). The band-fingerprint flips on nearly every
step — the design's premise "band-crossings are rare while walking" is WRONG (houses continuously cross the
distance bands as the player moves, so _band_fp changes constantly). Negative result; do NOT ship Lever 1 as-is.
(2) **THE REAL JERKINESS IS THE FLOOR, NOT VILLAGES** (user: "jerkiness is everywhere, even far from villages" —
CORRECT). worst_ms (window-worst, 1Hz) on STEADY frames (no far-tier re-commit at all) = median **69ms in BOTH
arms** = pervasive ~1Hz periodic hitch everywhere. The village re-commit spikes (239-302ms) are real but only ~20%
of frames — a spike ON TOP of an already-jerky 69ms floor. Earlier "237 vs 68ms re-commit correlation" was real but
over-indexed on the 20% spikes; killing them can't fix the pervasive feel. (3) FLOOR COMPOSITION (steady frames):
wf_vox_gen=0, wf_vox_mesh=0, wf_pool_active=0 → NOT gen, NOT near-mesh, workers idle. Reliable recurring per-frame
buckets = smooth_v2_commit ~10ms (FacetFarRing far-terrain smooth tier) + phys ~10ms, both present EVERYWHERE. ~38ms
of the 69ms is unmetered (convoy/GC/rAF). CAVEAT: wf_st_bms is a STICKY window-MAX marker (reads ~120-147ms because
one big village wake-bake happened once + the peek never resets) — do NOT read it as per-frame; the FP_WORST_FRAME_ATTR
peeks for st_bms/smooth_v2 are max-so-far not at-instant, a real instrumentation flaw for floor attribution. NEXT =
user's idea: NO-VILLAGES arm (strip FP_STRUCT_* family OFF via deploy_novillage.sh — FP_STRUCT_GEN gates the house
voxels in terrain_config.gd:1427/1445) → if the 69ms floor PERSISTS, villages exonerated as the pervasive cause and
chase smooth_v2/phys/far-ring/the ~1Hz convoy hitch; if it VANISHES, structures cause even the floor (fix the bake,
not the re-commits).

NO-VILLAGE A/B RESULT (2026-08-30) — DEFINITIVE 3-LAYER attribution. Deployed deploy_novillage.sh (FP_STRUCT_*
family OFF, 210 flags, NO-VILLAGE confirmed), user walked; SUBJECTIVE "still some jerkiness but MUCH better." Telemetry
(no-village steady tail n=197, fresh-load stripped): worst_ms median 73, but **28% of frames fast (<50ms) vs only 1-3%
with villages** → villages a MAJOR contributor, confirmed. THE THREE LAYERS of ground jerkiness, now separated:
(A) **VILLAGES / far-structures** — big contributor (28% vs 1-3% fast frames). Re-commit churn (~18-22/min) + the
sticky 120-147ms wake-bake flood the convoy. The shipped FP_STRUCT_WALK_CALM does NOT fix it (band-fp churns while
walking, re-commit rate unchanged). A DIFFERENT structure fix is needed (throttle/pace the far-structure commit +
bake, or cut per-commit cost), NOT the membership-delta lever.
(B) **NEAR-TERRAIN CHUNK-GEN CONVOY** — the residual floor with villages off: worst_ms spikes ~every 3s, spike frame =
wf_vox_gen 1000-2186 + wf_pool_active=6 (all workers busy) + wf_t_stream_us ~22000 → the ORIGINAL WASM dlmalloc gen
convoy firing as the player walks into new chunks. [[voxiverse-walk-perf-root-cause]] / [[voxiverse-gen-class-costs]]
— deepest, fundamental (mimalloc already REJECTED [[voxiverse-mimalloc-arena-root]]).
(C) **~30ms BASELINE** on hitch frames = wf_smooth_v2_commit ~14ms (FacetFarRing far-terrain smooth-tier main-thread
commit, EVERYWHERE) + wf_phys ~17ms. 0% of frames <33ms in ANY arm = persistent ~1Hz hitch. RANK by tractability:
(C) smooth_v2 pacing = cleanest lever; (A) far-structure commit/bake throttle = big user-visible win, needs real
redesign; (B) gen convoy = deepest, prior-rejected. Live currently serves the no-village build (210 flags) — restore
full build when done. FP_STRUCT_WALK_CALM + fartier-walk branch = documented NEGATIVE result, do NOT merge as the fix.
