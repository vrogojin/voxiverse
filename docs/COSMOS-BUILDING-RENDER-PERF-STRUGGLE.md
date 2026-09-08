# VOXIVERSE — Custom-Building (Village) Rendering Performance Struggle

> **Purpose.** A self-contained brief for multi-model reasoning (Claude + Codex + others) on the ONE
> unsolved performance problem that dominates the live web build: **rendering player-scale custom buildings
> (village houses) on the planet surface makes the game jerky the instant they appear — from orbit, on
> descent, and on the ground.** Everything else (terrain, trees, sky, orbit) is smooth. This doc captures
> the architecture, the measurements, and every method tried, so a fresh model can propose a *better
> rendering architecture* rather than re-derive the ground truth.
>
> **Last updated:** 2026-09-01 (overnight autonomous session).
> **Live site:** https://voxiverse.game-host.org (Godot 4.4.1 → Web/WASM, WebGL2 **gl_compatibility**, threaded,
> COOP/COEP). **Renderer constraint:** gl_compatibility (GLES3-class), single-threaded GPU submission, WASM.

---

## 0. The decisive symptom (user-observed, high-confidence)

- **Orbit / descent, alt ≈ 500 blocks:** perfectly smooth and comfortable **until the first far-rendered
  village house appears**, then immediately jerky, and stays jerky while houses are in view.
- **With villages disabled entirely (`FP_STRUCT_*` off): "blazingly fast."**
- **On the ground / walking through a village:** jerky (same tier, closer).
- The jerk is a **threshold**, not a ramp: it switches on with the first far house.

This isolates the cost to **one subsystem: the far-structure render tier** (`FacetFarStructures`), because at
altitude the near voxel field is suspended, so nothing else village-related is active. The user's own
hypothesis — *"our architecture with buildings rendering must be very wrong and inefficient"* — is the
working assumption this doc is meant to test.

---

## 1. World model (context a reasoner needs)

- Faceted **cube-sphere planet** (`FACETED=true ⇒ FLAT_WORLD=true`). Earth radius ≈ 6371 blocks. The world is
  a **heightmap** (no 3-D caves): bedrock → surface per column, analytic.
- **Two render paths, one behaviour.** Near terrain uses the Zylann **`godot_voxel`** C++ module
  (`VoxelTerrain` + `VoxelMesherBlocky`, greedy-meshed cubes) streamed around the player. Distant terrain
  uses **GDScript far tiers** (a "far ring" shell mesh + a smooth-relief mesh + far-tree cards + far-structure
  mesh). Analytic physics reads the heightmap directly, never the mesh.
- **Villages** are procedural (`StructureGen`): `VILLAGE_CHANCE=0.5` per `STRUCT_V=192`-block cell, houses per
  `STRUCT_HCELL=32`-block sub-cell (`STRUCT_HPV=6` houses/axis/village). A house is a small hollow box
  (walls/floor/roof, footprint ~5–9 blocks, height ≤ `STRUCT_H_MAX`). Earth facets only.

There are **TWO independent ways a building is drawn**, by distance:

| Tier | Who draws it | How | When |
|---|---|---|---|
| **NEAR** | `godot_voxel` module | House voxels are emitted by the C++ generator (`resolve_cell` → `struct_claim_at`) as ordinary terrain blocks, then greedy-meshed with the rest of the chunk. | Inside `near_render_radius()` (faceted **128 blocks**, `FP_NEAR_RADIUS_DIET` lowers it). |
| **FAR** | `FacetFarStructures` (GDScript) | A **decimated cube-voxel model** per house, **all merged into ONE `ArrayMesh`**, rendered by ONE `MeshInstance3D` with a custom `voxi_shade` ShaderMaterial. | Band `[near_render_radius(), STRUCT_FAR_MAX=2400]`, and off-surface in a shell band. |

**The jerk is the FAR tier.** (At alt 500 the near field is suspended; the user sees the jerk begin exactly
when FAR houses appear.)

---

## 2. The FAR-structure render architecture (the suspect)

File: `godot/src/world/facet_far_structures.gd` (class `FacetFarStructures`, a `RefCounted` owned/stepped by
the single `FacetFarRing`). Design doc: `docs/COSMOS-STRUCTURES-DESIGN.md §7`.

**Data model**
- `_baked: Dictionary` — per-house baked model keyed by `(root, rev)`: `{verts: PackedVector3Array (ring-local
  world coords), colors: PackedColorArray, tris, bytes}`. Cached; an unchanged house never re-decimates.
- The bake pipeline (`struct_decimator.gd`): `decimate(bbox)` → coarse occupancy+majority-colour grid →
  `bake_lattice()` → **face-culled cube mesh** (interior faces removed) → each vert mapped
  `FacetAtlas.lattice_to_world64()` into ring-local coords.
- **`STRUCT_TARGET_RES=16`**: `coarse_pitch()` returns 1 (i.e. **full 1:1 voxel resolution**) for any house
  whose extent ≤ 16 blocks — so **far houses are NOT decimated at all by default**; they are full cube
  models. (This is the single biggest waste we found — see §4.)

**Render model (THE ARCHITECTURE IN QUESTION)**
- **ONE merged `ArrayMesh`** for the whole in-band set of houses (`_mesh`, `_mi: MeshInstance3D`, child of the
  ring). **NOT a `MultiMesh`** — deliberately, because gl_compatibility has a `MultiMesh` colour-slot aliasing
  trap that bit the far-trees (`[[voxiverse-far-trees-colorfix]]`).
- **Rebuild = re-concatenate every cached house's verts/colors into one big array + `add_surface_from_arrays`**
  (`_rebuild`, `_commit_mesh`, facet_far_structures.gd:455-509). One draw call.
- Custom **`voxi_shade` `ShaderMaterial`** (`make_material()`, :108) with a `planet_centre` uniform refreshed
  per step for radial normals; a second **`_shell_material`** (unlit vertex-colour) swaps in for the
  off-surface "zone B" shell band (`FP_STRUCT_SHELL_BAND`).
- **NEVER-OOM caps:** merged mesh triangle-capped at **`STRUCT_FAR_TRIS_MAX=80000`** (nearest-first fill);
  baked store byte-capped at `STRUCT_BYTES_MAX=8 MB`.

**Rebuild triggers (throttled)** — `_rebuild` runs at most every **`STRUCT_STEP_MS=250 ms`**, and only when an
input drifted: camera moved ≥ `STRUCT_DELTA_MOVE=2.0` blocks, registry rev-sum changed (build/damage/remove),
edit revision changed, or the near-handoff cull is mid-transition.

**Near-handoff cull** — the shared `NearPresence.covered` predicate hides a far house once the near field
provably meshed it (`STRUCT_HIDE_STREAK`), restores it otherwise (`FP_STRUCT_NEAR_HOLD`).

**Key constants** (`cube_sphere.gd`): `STRUCT_FAR_MAX=2400`, `STRUCT_STEP_MS=250`, `STRUCT_FAR_TRIS_MAX=80000`,
`STRUCT_TARGET_RES=16`, `STRUCT_V=192`, `STRUCT_HCELL=32`.

---

## 3. Measurements (live, telemetry-instrumented)

**Telemetry is via a remote-control relay** (`?remote=<token>` URL). ⚠️ **Observer effect:** the relay injects
a ~200–450 ms/sec main-thread hitch, so **`worst_ms`/frame-time over the relay is unreliable** — the user's
**bare-URL** feel and the **observer-robust counters** (`wf_prims`, `wf_draws`, `wf_vox_gen`, `wf_st_bms`,
`wf_st_rb`, `st_live`) are the ground truth.

**Stationary hold over 81 far-villages (frozen, alt 706, res16/cap80k baseline):**
- **`wf_prims` = 1.06M with villages vs ~820k without → villages add ~240k prims**, pinned at the 80k-tri cap
  (80k tris ≈ 240k verts/prims). `wf_draws` ≈ 55–58 (villages are ONE extra draw — draw count is NOT the
  problem).
- `wf_st_rb` Δ0, `wf_ftr_rb` Δ0 while stationary → **no rebuild churn when still.**
- `wf_t_stream_us` ≈ 13.7 ms/frame (far-ring/skin/tex update tail; spikes to ~35 ms); `wf_st_bms` = 44.5 ms
  (one-time village **bake** latch as they entered); `wf_smooth_v2_commit_ms` ≈ 20 ms latch.

**Descent-landing near-gen scales with near-radius² (near field, separate axis):** peak `wf_vox_gen`
128→3953, 96→2190, 64→900 (matches (r/128)²). This is the *near* cost; `FP_NEAR_RADIUS_DIET=64` cut it −77%
but did NOT fix the felt (orbit) jerk — because the jerk is FAR, not near.

**Headless bench (`src/tools/bench_struct_bake.gd`, 26 real houses on fid 0):**
- Merged-mesh **rebuild (concat + `add_surface_from_arrays`) = ~2 ms native for 82k verts → NOT the jerk.**
- `_ensure_bake` (decimate+bake) = 38 ms/house res16 → 6 ms/house with the gate-hash memo (see §4).
- **Tri count scales hard with `STRUCT_TARGET_RES`:** res16 = 27564 tris, res8 = 7240 (−74%), res4 = 1904
  (−93%) for the same 26 houses.

**Conclusion from data:** with villages **stationary and already baked**, the far-village cost is **(a) ~240k
extra prims of full-res cube geometry** rendered every frame under a **custom fragment shader**, plus **(b)
the one-time bake spike** as they enter. Draw calls, rebuild concat, and probe passes are all cheap/throttled.
The **threshold symptom** (jerk begins with the first far house) is consistent with **the merged cube-mesh +
its shader becoming a persistent per-frame GPU/fragment load** the moment it is non-empty. **We have NOT been
able to definitively split GPU-fragment-bound vs main-thread over the relay** (observer effect) — resolving
that split is the #1 open question (§7).

---

## 4. Everything tried (this session + prior), with outcomes

Discipline: every feature is a byte-off `const FP_* := false` in `cube_sphere.gd`; a headless FLAT gate
(`verify_feature.gd`) must stay **6042 passed / 0 failed** with flags off; deploy seds chosen flags ON.

### Shipped this session (all live, byte-off, gate-green)
1. **`FP_STRUCT_GATE_MEMO`** (`6dfb0b2`) — the far bake (`decimate`) re-computed `has_village` (a 4×4
   `column_top` cliff stencil) + `house_info` **per voxel**; memoized per grid-cell in the `GenCtx`.
   **Bake 38→6 ms/house (6.3×), byte-identical output.** Helped the *bake spike*, not the steady render.
2. **`FP_STRUCT_WALK_CALM`** (+ `FP_STRUCT_HANDOFF_HYST`) — the shipped tier re-uploaded the whole merged mesh
   every 2 blocks of camera motion; gated it on a membership-fingerprint instead. **User confirmed this
   restored motion speed** (decoupled the far-village mesh from camera motion). Did NOT remove the jerk.
3. **`FP_STRUCT_COARSE_FAR`** (`d5d0490`) — coarser far-house decimation (`STRUCT_COARSE_RES=8`) + matching
   lower cap (`STRUCT_COARSE_TRIS_MAX=24000`) ⇒ *same villages shown, ~70% fewer village prims* (240k→72k).
   Live; **user reports still jerky** at res8 → the prim reduction alone was insufficient (or the cost is not
   purely the prim count / not GPU-fill).
4. **`FP_NEAR_RADIUS_DIET=64`** (`46c11a7`) — near voxel-field radius 128→64 (−77% descent-landing gen).
   Kept per user; helps descent, irrelevant to the orbit far-village jerk.

### Measured-and-rejected / inconclusive
- **`FP_REENTRY_BACKLOG_GATE`** (near-field view-regrow gen throttle) — dominated by run-to-run variance;
  the biggest flood (surface-entry) is structurally exempt. Not shipped.
- **Near-radius diet as the fix** — falsified as the felt cause (orbit has no near field yet is jerky).
- **Prior far-render cycles** (context, not this session): far-ring churn (`FP_UNSINK_DRIFT_CALM`), shell
  re-emit prewarm/staging (`FP_SHELL_PREWARM_DESCENT` etc.), prebake pacing — all shipped, all about *terrain*
  far-render, none about *buildings*.

### The architectural point we could NOT get past
Even with (1)+(2)+(3) — cheap bake, no motion re-upload, 70% fewer prims — **the far-village render is still
jerky the moment houses appear.** That is the signal that the *approach itself* (a merged, main-thread-rebuilt
`ArrayMesh` of per-house cube voxels under a custom shader) may be the wrong tool, not a tuning problem.

---

## 5. Why the current building-render architecture is suspect (the crux)

1. **Full-res cube voxels for tiny far objects.** `STRUCT_TARGET_RES=16` means a house within 16 blocks is
   rendered at **1:1 voxel resolution** — hundreds of triangles for something that is a few pixels tall at
   alt 500–2400. The far-tree tier solved the analogous problem with **flat stippled cards/impostors**, not
   voxel geometry. Buildings never got that treatment; they are still "real" (decimated) cube meshes.
2. **One giant merged mesh, rebuilt on the main thread.** Any membership change re-concatenates and re-uploads
   the whole band (bounded by walk_calm/step-throttle, but still a periodic main-thread GPU upload of up to
   80k tris). Even at ~2 ms/concat, the `add_surface_from_arrays` + GPU re-upload is a main-thread stall the
   moment it fires.
3. **Custom `voxi_shade` fragment shader over ~240k prims** on gl_compatibility WASM — a plausible steady
   fragment-fill or shader-cost that "turns on" exactly at the threshold. **Unverified** (no GPU timer; relay
   masks frame time).
4. **The bake still samples O(volume) per house** (`decimate` votes every fine cell), so a *batch* of houses
   entering the band at orbital sweep speed is a recurring bake burst (memo softened it 6×, staging spreads it).
5. **No true impostor/instancing/atlas path for buildings.** The far-tree pipeline (cards + fine-map canopy)
   proves impostors work on this renderer; buildings never adopted it.

---

## 6. Candidate redesigns to evaluate (for the multi-model reasoning)

Ranked by expected leverage × fit to the gl_compatibility/WASM constraint. **None implemented yet.**

- **A. Impostor billboards for far buildings** (mirror the far-tree card system). Replace each house's cube
  mesh with 1–2 camera-facing textured quads (a baked "house sprite" atlas, per style/roof). Cuts far-village
  prims from ~240k to a few hundred quads. Highest leverage; the renderer already does this for trees.
- **B. Bake once → static, never rebuild.** Far houses are world-static; build a persistent per-facet mesh
  ONCE when a facet's villages first enter, keep it resident, and hide/show via `visible`/culling instead of
  re-merging. Removes all main-thread rebuild/upload churn. (Risk: `visible=false` does not free gl_compat
  draw cost the same way; needs verification.)
- **C. `MultiMesh` with per-instance transform, colour baked into the shared mesh** — revisit the gl_compat
  colour-slot trap ([[voxiverse-far-trees-colorfix]]) that made P0 avoid MultiMesh; if solvable, one house
  archetype mesh × N instances is far cheaper to upload and can be GPU-culled.
- **D. Off-thread the bake+merge** (engine/WASM worker) — build verts on a worker, hand the main thread only
  the final buffer. Removes the bake/merge main-thread spikes (but not GPU fill).
- **E. Aggressive far cull / draw-distance for buildings only** — render houses only within a much smaller
  band than terrain (they're tiny far away anyway). User has NOT authorized a hard draw-distance cap, but a
  *fade* band is on the table. Simplest; reduces both prims and bake churn.
- **F. Resolve the GPU-vs-main split first** (measurement, not a fix) — add a real GPU frame timer or use
  `RenderingServer` viewport GPU time; or A/B "houses baked but shader = unlit flat" vs "voxi_shade" to see if
  the shader is the cost; or render the same tri count as a single flat quad to isolate fragment fill.

---

## 7. Open questions for the reasoning models

1. **Is the far-village jerk GPU-fragment-bound (240k prims × `voxi_shade`) or main-thread (rebuild/upload +
   bake)?** We could not split it over the observer-effect relay. What is the cheapest experiment to decide?
   (Idea: deploy an arm where the merged mesh is committed but the shader is a trivial unlit constant vs an
   arm with the geometry replaced by a single flat quad of equal screen area.)
2. **Given gl_compatibility + WASM + threaded**, is an **impostor/billboard** building tier (option A) clearly
   correct, or is there a reason buildings were kept as voxel meshes that trees were not?
3. **Why does the jerk begin at a hard threshold** (first far house) and persist, if rebuilds are throttled
   and stationary shows zero churn? What steady per-frame cost is proportional to "houses currently emitted"?
4. Is `STRUCT_TARGET_RES=16` (no decimation ≤16-block houses) simply a bug-level oversight — should far houses
   ALWAYS decimate to a fixed small silhouette regardless of size?

---

## 8. Reference (files, flags, methodology)

**Files**
- `godot/src/world/facet_far_structures.gd` — the far-building render tier (the suspect).
- `godot/src/world/struct_decimator.gd` — decimate + bake_lattice (cube-mesh bake).
- `godot/src/world/structure_gen.gd` — village/house procedural generator (also mirrored in C++
  `docker/engine/patches/godot_voxel/0013-cosmos-struct-gen.patch` for the near path).
- `godot/src/world/facet_far_ring.gd` — owns/steps the far tiers; telemetry surface.
- `godot/src/cosmos/cube_sphere.gd` — all `FP_*` flags + `STRUCT_*` consts.
- `godot/src/tools/bench_struct_bake.gd` — headless bake/merge/decimation bench.
- `godot/src/tools/verify_structures.gd` / `verify_fartier_walk.gd` — gates (80/0, 27/0).

**Building-related flags** (all byte-off `false` in source; deploy seds ON): `FP_STRUCT_DETECT`,
`FP_STRUCT_FAR`, `FP_STRUCT_LOD`, `FP_STRUCT_GEN` (near C++ claim), `FP_STRUCT_SHELL_BAND`,
`FP_STRUCT_NEAR_HOLD`, `FP_STRUCT_BAKE_STAGE`, `FP_STRUCT_WALK_CALM`, `FP_STRUCT_HANDOFF_HYST`,
`FP_STRUCT_GATE_MEMO`, **`FP_STRUCT_COARSE_FAR`** (+ `STRUCT_COARSE_RES=8`, `STRUCT_COARSE_TRIS_MAX=24000`).

**Telemetry fields (observer-robust):** `wf_prims`, `wf_draws`, `st_live` (structures currently emitted),
`wf_st_bms` (bake ms), `wf_st_rb`/`wf_ftr_rb` (cumulative rebuild counters), `wf_vox_gen`, `wf_t_stream_us`,
`wf_smooth_v2_commit_ms`. **`worst_ms` is observer-effect-polluted over `?remote` — judge feel bare-URL.**

**Deploy / A-B pipeline** (scratchpad, not committed): `deploy_cheats.sh` seds ~212 `CS_FLAGS` + env `CLITE_FLAGS`
ON → `export-web.sh` → `deploy.sh --no-build` → git-revert → curl-verify. Const values tunable via env
(`NRD`, `STR`→`STRUCT_TARGET_RES`, `SFT`→`STRUCT_FAR_TRIS_MAX`). GDScript-only changes need NO engine rebuild
(~4 min export+deploy); C++/engine changes need `scripts/build.sh` (~15–24 min).

**Measurement gotchas (hard-won):**
- The relay observer effect (~200–450 ms/sec) dominates `worst_ms`; use counters + bare-URL feel.
- Each browser `reload` **respawns at a different location**, and telemetry `pos` is BCI (not teleport-xyz
  facet-lattice), so **same-position build-A/B is hard**; village presence must be re-found each reload
  (rise until `st_live>0`; villages appear in the far band ~alt 350–700 over a village cluster).
- `set_alt` teleports up then the player free-falls; use `freeze_player:true` to hold for a stationary read.
- Control caps: `move.blocks ≤ 128`; `turn` uses `degrees` (not `deg`); one bad step rejects the whole seq.

**Prior context (memory):** `[[voxiverse-village-bake-memo]]`, `[[voxiverse-near-radius-diet]]`,
`[[voxiverse-far-trees-design]]` (the impostor pipeline buildings should probably copy),
`[[voxiverse-far-trees-colorfix]]` (the MultiMesh colour-slot trap), `[[voxiverse-structures-design]]`,
`[[voxiverse-postport-applybound]]` (main-thread apply is the general web bottleneck),
`[[voxiverse-web-perf-architecture]]`.

---

## 9. TL;DR for a fresh model

The game is smooth everywhere **except when player-scale buildings render at a distance**, and it degrades the
instant the first far house appears. Far buildings are drawn as **one merged `ArrayMesh` of full-resolution
decimated cube-voxels under a custom fragment shader, rebuilt on the main thread** — while the analogous
far-**tree** problem was solved with cheap **impostor cards**. We have already made the bake 6× cheaper, stopped
the per-motion re-upload, and cut village prims 70%, and it is **still** jerky — strongly implying the
**cube-mesh-per-building approach is the wrong architecture** and buildings need an impostor / instanced /
static-baked far tier. The single most valuable next step is a clean experiment to decide **GPU-fragment-bound
vs main-thread-bound**, then adopt the far-tree-style impostor path for buildings.
