---
name: voxiverse-village-bake-memo
description: "2026-08-31 village descent bake spike ROOT + FP_STRUCT_GATE_MEMO fix (6.3x, byte-identical, shipped)"
metadata: 
  node_type: memory
  type: project
  modified: 2026-09-02T06:32:56.410Z
---

**Village "descent is jerky" ROOT + fix (SHIPPED 6dfb0b2, live).** The far-structure bake
`StructDecimator.decimate` (facet_far_structures.gd `_ensure_bake`) samples
`WorldManager.structure_cell_at → StructureGen.claim_at` ONCE PER FINE CELL over the whole
house bbox (O(volume), ~11.6k cells / 26 houses). claim_at's cost is dominated by
`has_village` (a 4×4 `column_top` cliff stencil + biome + hashes) and `house_info`
(re-calls has_village + 4 column_top + slope) — both pure functions of (vx,vz)/(hx,hz),
near-CONSTANT within one house bbox, recomputed thousands of times per bake.

**Fix = `FP_STRUCT_GATE_MEMO`** (cube_sphere.gd): memoize has_village per (vx,vz) + house_info
per (hx,hz) in the per-fid GenCtx (`svmemo`/`shmemo`, alongside the existing column_top memo).
has_village/house_info split into thin memoized front doors + `_*_compute` bodies
(structure_gen.gd). Pure work elision — the far model is byte-IDENTICAL (memoized == recomputed).

**Controlled bench (`src/tools/bench_struct_bake.gd`, run flag-off then flag-on, same 26 houses):**
byte-identical output (solid=5989, tris=27564); `_ensure_bake` **38→6 ms/house (6.3×)**;
decimate 34→2 ms/house (17×); bake_lattice/lat→world unchanged (~0.8/2.4 ms). Native debug
editor numbers; WASM-release proportional. Gates: FLAT verify_feature exit 0 (byte-off);
verify_structures 80/0 with flag ON.

**LESSON — don't trust uncontrolled live st_bms A/B.** Live load-in `wf_st_bms` was 150 (no-fix)
vs 186 (fix) = LOOKED worse, but confounded: different reload baked ~2× more houses (vox_gen
2168 vs 1008) + one-time first-bake StructureGen.warm_up. Window-max over an uncontrolled
load-in is noise. The controlled headless bench (same bboxes, flag A/B) is the ground truth.

**FAR-VILLAGE ORBIT JERK — the REAL root (2026-08-31, user A/B: "far villages = jerky, no villages = blazing fast").**
The felt jerkiness (orbit AND ground/descent) is the FAR-STRUCTURE tier RENDER, not the near field, not the bake.
ROOT: FacetFarStructures re-concatenates + re-uploads the WHOLE merged village mesh (≤ STRUCT_FAR_TRIS_MAX=80k tris,
add_surface_from_arrays on the MAIN thread) every STRUCT_DELTA_MOVE=2.0 blocks of camera motion — at orbit the camera
moves »2 blk/frame ⇒ re-upload EVERY frame of unchanged 80k-tri village mesh = the hitch. FIX = FP_STRUCT_WALK_CALM
(+ FP_STRUCT_HANDOFF_HYST): rebuild gated on _band_fp membership-change, not raw camera delta (facet_far_structures.gd
:286). Gate verify_fartier_walk 27/0 with flag ON. Shipped live 2026-08-31 16:32 for user validation (near diet=64
kept). If still jerky ⇒ the merged-mesh REBUILD itself (not frequency) is the cost ⇒ off-thread the concat/commit or
shrink STRUCT_FAR_TRIS_MAX. This is why my near-radius diet / village-bake-memo helped descent-gen but NOT the felt
orbit jerk — WRONG LAYER (near vs far-structure render). LESSON: at orbit the near field is suspended, so orbit-jerk
isolates the FAR tier; the user's villages-on/off A/B was the decisive signal.

**FAR-VILLAGE COST = PRIMS, not merge/probe (2026-09-01 overnight, live-measured over 81 far-villages @ alt 706
frozen).** worst_ms 45 med / 274 max; prims 1.06M WITH villages vs ~820k without = villages add ~240k prims,
PINNED at STRUCT_FAR_TRIS_MAX=80k tris (=240k prims). NO rebuild churn while still (st_rb Δ0). The merge/rebuild
concat+commit = only ~2ms (bench, NOT the jerk); _probe_pass is throttled by STRUCT_STEP_MS (not per-frame). So the
village jerk = the +240k PRIMS (GPU) + bake-on-entry (st_bms 44.5, memoized+staged). LEVER (user-authorized reduced
detail): coarser STRUCT_TARGET_RES (16→8 = -74% tris, →4 = -93%) + matching lower STRUCT_FAR_TRIS_MAX cap → SAME
villages shown, far fewer prims (res8/cap24k = village prims 240k→72k). Deployed live 2026-09-01 21:55 via STR=8
SFT=24000 env in deploy_cheats.sh (NOT yet a committed flag — env-value hack; formalize to FP_STRUCT_COARSE_FAR
byte-off flag if user OKs the visual). MEASUREMENT BLOCKER: reload respawns at a DIFFERENT location each time
(st_live 81 vs 0), and telem pos=bci ≠ teleport-xyz facet-lattice, so a same-position build-A/B is hard; village
prim reduction is DETERMINISTIC from the cap so validated at mesh level. Live build now: walk_calm + near diet64 +
coarse-village res8/cap24k. Base far render (~820k prims, no villages) user says is "blazingly fast". LESSON: near
field suspended at orbit ⇒ orbit-jerk isolates far tier; villages-on/off was the decisive user A/B.

**REAL ROOT CAUSE FOUND + FIXED — Stage 0b `FP_STRUCT_REG_EPOCH` (2026-09-01, PR #84, commit 36b9b8c).**
The felt village jerk (2Hz spike at alt 500, threshold at first far house) was NOT the render/GPU cost —
it was the CONTROL LOOP. `FacetFarStructures.step()` ran O(N-houses) main-thread work EVERY ~250ms step
BEFORE the delta gate could conclude "nothing changed": `StructGenIndex.records()` (struct_gen_index.gd:57)
`.duplicate()`-copies every house dict every call (~1.5-4k records) + rev-sum loop + `_probe_pass` allocating
a fresh `lattice_to_world64` Array per house. The rebuild was gated; computing the gate's INPUTS was not.
Invisible to wf_st_rb (counts only `_rebuild`). PWM'd to ~2Hz by stream-credit duty; wakes at FT_SHELL_HIDE_ALT
=600. This is why 5 prior product-side fixes (gate-memo/coarse/walk-calm/shader-lite/near-diet) ALL missed —
they optimized the COUNTED work; the cost was the one uncounted loop. (walk-calm even made the stationary
prelude HEAVIER.) Found by a 3-model review (Fable traced it to file:line; Codex+web-research corroborated the
architecture); VERIFIED in code before trusting. FIX (mirrors far-trees' O(1)-gate-before-O(N)-work,
facet_far_trees.gd:802): version the registry (StructGenIndex._version + StructureTracker.version XOR-mixed in
WorldManager.structure_registry_version), snapshot + precompute packed `_centres` only on version drift, O(1)
short-circuit when version+camera+annulus quiescent. Added wf_st_step_us counter (was the missing counter).
LIVE-VERIFIED: wf_st_step_us=0 stationary (was ~20-50ms); user "significantly less jerky". Gates FLAT 6042/0,
verify_structures 86/0, verify_fartier_walk 32/0 (all OFF+ON, bit-identical mesh). TRANSFERABLE LAW: **a delta
gate is only as cheap as computing its own inputs** — applies to every delta-gated tier (trees got it right,
structures inverted it). RESIDUAL after 0b = the STEADY vertex tax (80k-tri merged cube mesh, ~848k prims) =
Stage 2 (FP_STRUCT_CARDS impostor tier, Fable-designed, in progress). LESSON: instrument the UN-GATED work, not
just the gated. See docs/COSMOS-BUILDING-RENDER-PERF-STRUGGLE.md + CODEX-BUILDING-RENDER-ANALYSIS-1.md.

**STAGE 2 SHIPPED — FP_STRUCT_CARDS impostor tier (2026-09-01, commits d5d3620 + f9ee2bb, live).** Far GEN
houses beyond STRUCT_CARD_MIN=320 render as directional impostor cards (one MultiMesh, 4 tris/house, ~8k tris
vs 80k cube) — the far-tree card pattern. Fable-designed (docs/COSMOS-STRUCT-IMPOSTOR-DESIGN.md), Opus-impl,
Fable+Codex adversarial review found + fixed 1 P0 (card shader read VERTEX as local under render_mode
world_vertex_coords — VERTEX arrives WORLD-space ~planet-radius → planet-scale streaks; fix: reconstruct local
from UV/UV2, only WRITE VERTEX; verified vs tree shader which never modifies VERTEX) + P1s (atan(-sa,ca) sector
handedness, cap-u mirror, atlas-pad remap for the 0.81×/float pop, cube-cap not stopping card scan, damaged
houses→cube sink, off-flag alloc). Gate #10 G-ST-CARD-SHADER = CPU twin of the vertex math (catches the P0/sector
headless). Gates FLAT 6042/0, verify_structures 127/0 ON, verify_fartier_walk 37/0 ON. User: houses render OK
from 500, "much much better," residual small jerk. LESSON: control plane clean (REG_EPOCH/handoff/byte-off) —
two-reviewer coverage (Fable=shader math, Codex=correctness edges) each caught the other's blind spots.

**STAGE 3 IN PROGRESS — altitude-band boundary (2026-09-02).** User: rising past ~600 villages VANISH + descending
re-adds them with a jerk. ROOT (code+measured): FT_SHELL_HIDE_ALT=600 zone-O hides cards (facet_far_structures.gd
_apply_shell_visibility), fade 520-600, but FP_STRUCT_LOD roof-skin replacement is DECLARED-UNIMPLEMENTED (cube_sphere.gd
:1298) → villages vanish into nothing; + a ~1136ms emit spike at ~577 as a wide village set enters (no card-emit
staging, unlike cube BAKE_STAGE). Fix contract = BOTH (extend card band higher + smooth handoff), engine rebuilds OK,
free rein, remote live. Fable designing docs/COSMOS-CARD-BAND-HANDOFF-DESIGN.md: raise STRUCT_CARD_HIDE_ALT (cards
cheap) + roof-skin-or-screen-cull handoff + buffer-resident-across-boundary (no re-emit) + staged card emit + cross-fade.
Then Opus impl → Fable+Codex review → live A/B.

Shipped ON live via CLITE_FLAGS in deploy_cheats.sh (with the profiling stack +
FP_STRUCT_BAKE_STAGE + FP_WORST_FRAME_ATTR). Steady walking near a village was already cheap
(median 40 ms, Δ2 recommits/80 blk); the village cost is the BAKE when houses enter range on
descent/approach — exactly what this diets. See [[voxiverse-ground-walk-perf]],
[[voxiverse-deploy-cheats-pipeline]], [[voxiverse-structures-design]].
