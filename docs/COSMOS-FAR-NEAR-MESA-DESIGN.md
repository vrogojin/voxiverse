# COSMOS FAR/NEAR MESA — the #113 residual: far-ring grey blob over a hot-biome mesa base (root cause + fix design)

**Symptom (live, user-reported, post-#113):** on the ground (alt 13, `offsurf=False`) at telemetry
pos `7671,-115,13673`, active facet **1754**, hot badlands/mesa biome (ground 79 °C, maroon
terrain), a large FEATURELESS GREY smooth oval renders OVER the near mountain terrain.
Key telemetry at the spot: **`sh_applied_r = 0`** — the #113 applied-cover ladder
(`FP_APPLIED_PROBE_SLAB`, live-enabled, confirmed in the served pck) is NOT firing here, so the
`FP_FARRING_FULL_COVER` dense backstop is in the zone-B "TRUE chord − 1.5" state everywhere and
its 26-block treads ride over the realized near tops of the concavity — the same protrusion
arithmetic as #113 §1 fact 5, at a new location.

**Verdict up front (measured in the REAL engine, twice, on facet 1754):** the #113 probe clamp
fixed the wrong bound tightly enough to pass at its own repro spot and nowhere lower. The probe
demands the FULL meshed slab (voxel y ∈ [−64, 130) ⇒ **mesh-block rows −2..4**, 32³ blocks) at
every radius — but the engine only ever loads the mesh-block rows
**[c−4, c+3]** around the viewer's row `c = floordiv(player_y, 32)` (view 128 ⇒ 4 blocks;
`Box3i::from_center_extents` is one block SHORT on the + side). The full slab therefore fits
**only for `c ∈ {1, 2}`, i.e. player lattice y ∈ [32, 95]**:

| player row `c` (lattice y) | engine-loadable rows | slab rows −2..4 covered? | ladder |
|---|---|---|---|
| 0 (y 0..31 — beaches, valley floors, **mesa bases**) | −4..3 (clipped −2..3) | **row 4 (y 128..159) never loads** | **dead, `sh_applied_r`=0** |
| 1 (y 32..63 — the #113 grass base, y=34) | −3..4 | all 7 ✓ | alive (why #113 shipped "healed") |
| 2 (y 64..95) | −2..5 | all 7 ✓ | alive |
| 3+ (y ≥ 96 — high peaks) | −1..6 | **row −2 (y −64..−33) never loads** | dead |

The mesa-base valley floor here is lattice y ≈ 10–17 (telemetry alt 13; measured badlands/
savanna/desert valley floors 6–20 on facet 1754) ⇒ `c = 0` ⇒ the probe's very first step
(r = 16) is false forever ⇒ `_applied_r` pinned at 0 ⇒ zone C empty ⇒ zone-B chord treads over
concave relief = the grey oval. **Same dead-latch class as #89/#113/FP_NB_WELD: a coverage probe
that demands blocks the engine can never load is unsatisfiable forever.** Third instance; §3
fixes the class, not just the spot.

---

## 1. Measured facts

Probes ran against the **served pck** (`build/web/index.pck`, this worktree = the live bind
mount; flags dumped: `FP_APPLIED_PROBE_SLAB/FP_FARRING_APPLIED_COVER/UNCOVERED_TRUE/FULL_COVER/
BLOCKY_FARRING/NB_FULLRES/NB_WELD/VIEWER_RELIEF_REACH/SMOOTH_V2_NEARFILL/ORBIT_RELIEF_SURFACE_HIDE
all true`; `streamed_ellipsoid_params=(128,0,128)`, `meshed_slab_y=(−64,130)`,
`TierPlace.applied_cover_on()=true`). Scripts: scratchpad `probe_mesa{1..5}.gd`,
`probe_mesa_e{1,2,3,4,5}.gd`; driver = `docker/engine/bin/godot.linuxbsd.editor.x86_64
--headless --main-pack build/web/index.pck -s <probe>`.

1. **The engine's loadable set is a mesh-block BOX, not the analytic ellipsoid, and it is
   asymmetric.** `voxel_terrain.cpp:1288-1296`: `state.mesh_box = Box3i::from_center_extents(
   mesh_block_pos, (h, v, h)).clipped(bounds_in_mesh_blocks)` with
   `h = v = ceildiv(min(viewer_distance, max_view_distance), mesh_block_size)`;
   `box3i.h:26-28`: `from_center_extents(c, e) = Box3i(c − e, 2e)` ⇒ block range **[c−e, c+e−1]**
   — one block short upward. Mesh blocks are **32³** (`module_world.gd:393`), view 128 ⇒ e = 4.
   `is_area_meshed` (`voxel_terrain.cpp:2072-2079`) requires EVERY mesh block of the box to
   exist and be `is_loaded` — blocks outside the viewer box never load, exactly like blocks
   outside bounds (the #113/FP_NB_WELD fact).

2. **Real-engine measurement (E2/E3, WorldManager + module terrain + the real FacetFarRing on
   facet 1754, valley column (8638.5, 14413.5), surface 10.3, `c=0`, settled
   `pool_view(active)=128`):** per-row `is_area_meshed` of the player column:
   `row−2..row3 = T, row4 = F` — **stable from frame ~200 through 1500+, permanently**; the
   #113-clamped probe (`_applied_box_meshed_slab`) false at r = 16..112, all of them; ladder 0.
   With `max_view_distance` forced to 96 (e = 3): `row3 = F` too — the row-window law scales
   exactly as the arithmetic predicts. Raising the viewer to lattice y 40 (`c=1`) turns
   `row4 = T` (all 7 rows loaded); at y 100 (`c=3`) `row−2 = F` (bottom short) — the whole
   table above is measured, not derived. (Harness caveats, disclosed: the ring's
   `_cull_cover_query`/`_seam_cover_query` wire only via the player streaming-update path
   (`world_manager.gd:1215-1232`), so the E-harness drove `_applied_box_meshed_slab` directly;
   an airborne-first pose stalls harness streaming — grounded-first poses were used for every
   cited number.)

3. **Why the mesa/badlands base specifically.** `_applied_box_meshed_slab`
   (`facet_far_ring.gd:1637-1676`) intersects [ly−128, ly+128] with `meshed_slab_y()` = (−64,130):
   for ANY on-ground ly ≤ 64 the clamped band is the full slab, whose top voxels 128..129 live in
   row 4. A player at `c=0` (ly ≤ 31) can never have row 4 loaded (fact 1) ⇒ first ladder step
   false ⇒ `_applied_probe_step` (`:1692-1706`) can never grow past 0. Facet 1754 is
   B_MOUNTAINS-dominated with hot badlands(2)/desert(3)/savanna(11) pockets; 105 concave
   candidates (valley floor ≤ 20 with ≥ 45-block relief within 40 blocks) measured in-domain —
   the mesa-base class puts a `c=0` player right under tall concave relief, where zone-B chord
   treads overshoot the realized near tops by the #113-measured +5..+50 blocks. Grass plains at
   the same `c=0` height don't show it because flat zone-B hides ~1 block under the tops —
   the degraded mode is invisible without concavity, exactly as #113 §1 fact 7 recorded.

4. **The #113 A/B fingerprint confirms the window law.** At the grass base (ly=34, `c=1`) the
   ladder ran but settled at **64**, not the h-cap 96/112 — consistent with the cross-border
   remainder: at r = 80 the probe box first overflows the second domain edge (~79 blocks away,
   the #113 doc's own corner geometry) and that ridge's W1 foot lands near the neighbour's
   polygon corner ⇒ `pool_seam_meshed_weld` returns false by its corner-safe rule
   (`module_world.gd:2092-2093`) ⇒ growth stops. Secondary, disclosed residual (§3.5) — it caps
   a live ladder, it does not zero it; the mesa repro reproduces 0 at an interior column with
   no border involvement (fact 2).

5. **Why the #113 gate was green while this was live.** `verify_applied_slab.gd`'s synthetic
   coverage callable models `meshed ⇔ AABB ⊆ slab × domain±2` — bounds semantics only. The
   engine's second constraint — the viewer row window with its `from_center_extents` asymmetry —
   was not in the model, so the gate proved the ladder satisfiable in a world where every
   in-bounds block is loadable. Same lesson as #89: gate models must include the engine's
   loadable-set law, or drive the real engine (the E2/E3 harness now exists for that).

Falsified along the way: (a) "hot-biome/mesa relief exceeds MAX_SURFACE_Y so the #113 clamp is
too low" — MAX_SURFACE_Y=116 bounds all generation; the slab top is right, the VIEWER can't
reach it from low ground; (b) "the streamed ellipsoid corner argument" — the engine streams a
box, not the analytic ellipsoid (fact 1; the (r,O,H) ellipsoid is only the far-ring's zone-A/B
approximation); (c) "neighbour not pool-resident (FP_NB_FULLRES gap)" — the repro needs no
neighbour at all; (d) "a biome/regime gate suppresses the ladder" — `applied_cover_on()` is
flag-derived, true live, biome-blind.

**Pre-existing verdict:** the applied-ladder code was last touched by #113's `FP_APPLIED_PROBE_SLAB`
(commit 0916305, PR #50); the recent `FP_LEAF_CUTOUT` (db916fd, ced9090) and
`FP_FAR_TREES_COLORFIX` (3e88e7a) touch the near-leaf material/discard and far-tree instance
colours only — no far-ring coverage, no streaming, no probe code. The far-trees P0–P3 commits add
tree emission bands to `facet_far_ring.gd` but do not touch `_applied_*`/`_blend_uncovered`.
This is a straightforward **#113 residual**: the slab clamp repaired one unsatisfiable conjunct
of the probe; the viewer row window is the next one, live at every `c=0`/`c≥3` column since
`FP_FARRING_APPLIED_COVER` shipped.

---

## 2. Root cause, one paragraph (file:line)

`_applied_box_meshed_slab` (`facet_far_ring.gd:1637`, the #113 body) clamps the probe box
vertically to `TerrainConfig.meshed_slab_y()` (`terrain_config.gd:270`) = voxels [−64, 130) =
32³-mesh-rows [−2..4], and asks `is_area_meshed` (via `_cull_cover_query` →
`module_world.skin_near_meshed`, `module_world.gd:2536`) for the whole band at every radius.
The engine loads only rows [c−4, c+3] around the viewer row c (`voxel_terrain.cpp:1288-1296` +
`box3i.h:26`, view 128, mesh blocks 32 — `module_world.gd:393`), so the band is loadable only
for c ∈ {1,2} (player y 32..95). The live repro stands at y ≈ 10–17 (c=0): row 4 (y 128..159,
holding slab voxels 128..129 — tree/snow decoration headroom, `MAX_SURFACE_Y 116 + max(tree 14,
snow 4)`) is permanently unloadable ⇒ the probe's first step is false forever ⇒ `_applied_r` = 0
(`facet_far_ring.gd:1692-1706`) ⇒ `_blend_uncovered` (`:3391`) resolves every in-ellipsoid vertex
through zone B (TRUE chord − 1.5) ⇒ the dense backstop's 26-block treads protrude over the
concave mesa base. Measured, not inferred: §1 fact 2.

---

## 3. Fix design — `FP_APPLIED_VIEW_BAND` (probe only what the viewer can load; height-band zone C)

`const FP_APPLIED_VIEW_BAND := false` in `cube_sphere.gd`, beside `FP_APPLIED_PROBE_SLAB`
(`:1745-1757`). Byte-identical off (§3.6). Principle unchanged from #113: don't touch the
three-zone arbitration; fix the dead INPUT — and this time compensate the un-probed part
explicitly so the claim stays sound at ANY live view distance.

### 3.1 One derivation site for the loadable row band

`module_world.meshed_band_y(ly: float) -> Vector2` (beside `skin_near_meshed`,
`module_world.gd:~2536`): mirrors the engine law verbatim — `bs = 32` (the value this file sets,
`:393`), `c = floori(ly / bs)`, `e = ceildiv(min(viewer_view_distance(), pool_view(active)), bs)`
⇒ voxel band `[(c − e)·bs, (c + e)·bs)` intersected with `meshed_slab_y()`. The
`streamed_ellipsoid_params` pattern: the far ring consumes it through a wired callable
(`WorldManager` hands `Callable(_module_world, "meshed_band_y")` beside the existing cover/seam
wiring, `world_manager.gd:1222-1232`), so the probe and the engine can never quietly disagree
again. Invalid callable (GDScript fallback) ⇒ flag path inert ⇒ shipped behaviour.

### 3.2 `_applied_box_meshed_slab` (facet_far_ring.gd:1637) — flag-gated band clamp

With the flag on, step (1) becomes: intersect [ly−h, ly+h] with `meshed_slab_y()` **and with the
loadable band from §3.1**; empty ⇒ false. Everything else — the horizontal domain clamp, the
cross-border W1 remainder, the no-over-claim conventions — stays byte-for-byte the #113 body.
(Horizontal is deliberately NOT band-clamped: a horizontally clamped box under an unclamped
claimed radius would over-claim; vertically the height-banded zone C of §3.3 compensates, which
is what makes the vertical clamp sound.)

At the repro: band = rows [−2..3] = y [−64, 128) ⇒ satisfiable ⇒ ladder grows to the horizontal
cap (96–112 interior). At view 96 it self-adapts (band [−64, 96)); at c=3 summits the band drops
row −2 (probing y [−32, ...)) — satisfiable everywhere, at every live view distance, because the
probe now asks for exactly what the engine can deliver.

### 3.3 Height-banded zone C — the soundness compensation

Claiming "cover applied within r" while having verified only y < band_top would over-claim any
column whose SURFACE lies above band_top (its blocks may be unloaded — sinking far cover there
would carve a visible hole in a tall wall). So zone C becomes height-banded:

- `_applied_probe_step` (`:1692`) records `_applied_band = meshed_band_y(ly)` alongside a
  passing `_applied_r` (and `_async_applied_band` snapshots beside `_async_applied_r = _applied_r`,
  `:1894`, for the worker).
- `_applied_covered` (`:3360`) gains `applied_top := 1.0e9` (default ⇒ byte-identical): a vertex
  is zone-C-eligible only if its TRUE surface lattice height ≤ `applied_top − 1` (1-block guard).
- `_blend_uncovered` (`:3391`) passes the band top and reads the vertex's true height from a new
  `_btrue_h_cache[fid]` (PackedFloat32Array, one lattice height per grid node, built beside
  `_ensure_backstop_true_cached` (`:3313`) from the same welded worldgen profile — pure,
  worker-safe, ~1.2 KB/fid, pruned with the other caches — NEVER-OOM).

Effect at the mesa: valley cells (h≈10) and wall cells (h 45–66 < 128) are verified ⇒ zone C ⇒
sunk under the meshed near mesh (the #89-proven no-protrusion regime) ⇒ **grey oval gone**. A
vertex whose surface exceeds the band top (only possible when the live view is shaded below
~113, e.g. band top 96 vs a 116 summit) stays zone B — TRUE−1.5 at-height cover over blocks the
engine genuinely hasn't loaded, which is exactly the correct degraded mode. No configuration
draws less than today ⇒ **no see-through can reopen; zone C still DRAWS sunk geometry
(FULL_COVER), zone B still draws the chord.**

### 3.4 Telemetry

`"sh_applied_band": _applied_band.y` (flag-gated key beside `sh_applied_r`,
`facet_far_ring.gd:3095`) — the band that let the ladder live, so the next silent re-death is
readable off live telemetry instead of costing a third investigation.

### 3.5 Disclosed residuals (not scheduled)

- **W1 corner cap** (§1 fact 4): near a facet corner the cross-border remainder can stop growth
  early (grass base: 64). With the ladder otherwise alive the un-covered annulus keeps zone B —
  measured worst +4.7 blk at ≥110 blk range (#113 §2.4) — cosmetic. If it ever matters: per-ridge
  blocked-side zone-B masking (the box grows past a failing ridge but cells beyond that ridge
  stay zone B) — one plane test per cell at emit.
- Near-voxel tree crowns above the band top (y ≥ 128 canopies seen from a `c=0` valley) are
  unloadable today regardless of this fix; far-tree cards cover them. Phase-2 alternative that
  fixes BOTH residual classes at the engine level: `FP_VIEWER_SLAB_ANCHOR` — pin the grounded
  viewer's vertical anchor so its row window always covers the slab (offset the existing
  A2/approach-anchor lever so the effective viewer row ∈ {1,2}; the loaded box then equals the
  bounds-clipped slab at every pose, ends vertical restream churn on climbs, and makes even the
  shipped #113 probe satisfiable). Not this task: it changes live streaming behaviour globally
  and needs its own perf A/B.
- The zone-A/B `_uncovered` law (`:3341`) still uses the analytic (r,O,H) ellipsoid as its
  approximation of the streamed set (box, in truth). Shipped, #89-proven visually; untouched.

### 3.6 Byte-off proof

Flag false ⇒ `_applied_box_meshed_slab` takes the shipped #113 branch (the new intersection is
inside `if CubeSphere.FP_APPLIED_VIEW_BAND`); `_applied_covered`/`_blend_uncovered` defaults
(`applied_top = 1e9`) make the height condition vacuously true; `_btrue_h_cache` is built only
under the flag; the stats key is emitted only under the flag; `meshed_band_y` exists but is
uncalled. All real callers pass no new arguments ⇒ byte-identical emit, probe, telemetry.

### 3.7 Injection points (exact)

| File | Change |
|---|---|
| `godot/src/cosmos/cube_sphere.gd` | `+ const FP_APPLIED_VIEW_BAND := false` (beside `:1757`) |
| `godot/src/world/voxel_module/module_world.gd` | `+ func meshed_band_y(ly)` (§3.1, beside `:2536`) |
| `godot/src/world/world_manager.gd` | wire `set_band_query(...)` beside `:1222-1232` |
| `godot/src/world/facet_far_ring.gd` | `_applied_box_meshed_slab` band clamp (`:1637`); `_applied_probe_step` band record (`:1692`); async snapshot (`:1894`); `_applied_covered` `applied_top` (`:3360`); `_blend_uncovered` height gate (`:3391`); `_btrue_h_cache` builder (beside `:3313`); stats key (`:3095`) |
| `godot/src/tools/verify_applied_band.gd` | new gate (§4) |

Perf/memory: probe stays ≤ 2 `is_area_meshed` + ≤ 4 W1 strips per cadence tick; +1 float compare
per vertex on the worker; +~1.2 KB/fid height cache on backstop fids only; **zero new draw calls,
zero new meshes** — this only re-selects which of the two existing height laws each vertex takes.

---

## 4. Gate plan (`src/tools/verify_applied_band.gd`, headless)

- **G-VB-LAW (the engine-model pin — the gate #113 lacked):** synthetic coverage callable that
  models the FULL loadable set: `AABB ⊆ slab × domain±2` **∩ rows [c−e, c+e−1]** (the
  `from_center_extents` asymmetry included). Assert the SHIPPED `_applied_box_meshed_slab` is
  false at ly = 10 and ly = 100 and true at ly = 40 (pins the root cause + the #113 blind spot
  reproducibly, no engine needed).
- **G-VB-SAT:** flag on, same callable: probe true at ly = 10 (band-clamped); driving
  `_applied_probe_step(on=true)` grows 16→112 in 7 calls; flipping the callable drops to 0 in ONE
  call (shrink-instantly intact); `_applied_band` recorded (top = 128 at ly=10/view 128; = 96 at
  view 96).
- **G-VB-ZONEC (protrusion + soundness):** `_blend_uncovered` fixture over the measured facet-1754
  window (8638.5, 14413.5): with band top 128 — valley (h≈10) and wall (h 45–66) vertices take
  zone C (sunk ≤ realized near tops at every sampled column); a synthetic h=130 vertex stays
  zone B; with band top 96 — wall vertices ≥ 96 stay zone B (the hole-proof). Degraded pin:
  flag-off zone-B corner-MIN treads protrude at the same window (worst ≥ +5) so a future silent
  ladder re-death fails loudly.
- **G-VB-OFF:** byte-off parity — FLAT `verify_feature.gd` unchanged; both probe bodies driven
  side-by-side agree with the flag off; no `sh_applied_band` key off.
- **G-VB-ENGINE (heavy, optional CI):** the E2/E3 harness distilled — real WorldManager +
  module terrain on facet 1754, grounded valley pose, assert `row4` unmeshed at settle and the
  flag-on probe true (keeps the gate model honest against future engine bumps). Scripts already
  exist in scratchpad (`probe_mesa_e2/e3.gd`) and are the template.

## 5. Live A/B (remote, at the repro spot pos 7671,−115,13673 / facet 1754)

0. **BEFORE (one dump):** `sh_applied_r` (expect 0) + `pool_view`/viewer view (expect 128 — any
   lower value is ALSO handled by the band law, but record it) + screenshot of the oval.
1. Deploy flag-on. **AT THE SPOT:** `sh_applied_r` 0 → 96–112 within ~8 cadence ticks,
   `sh_applied_band = 128`, grey oval GONE, near mountain terrain continuous to the horizon.
2. Climb the mesa (player y crosses 32 and, on a summit, 96): ladder stays alive through both
   row transitions (the shrink-instantly law may dip one tick at a row flip — must re-grow, not
   latch at 0).
3. Regression sweeps: the #113 grass-base spot (sh_applied_r ≥ 64, no grey plane); the #112
   border-slope walk both ways (no near-render/fall-through change — far-ring-only fix); fresh
   teleport (streaming window still fully covered — grey-smooth zone-B interim must remain);
   ascend > 256 (G3 relief returns, #110 hide untouched).

## 6. Honest verdict

Root cause is **measured** (real engine, served pck, repro facet, stable over thousands of
frames, and the row-window law reproduced at four player heights) — not inferred from source
alone. The one number I could not recover offline is the player's exact in-facet position (the
scene→lattice transform depends on runtime spin state; §5 step 0 costs one telemetry dump and
cannot change the mechanism: `sh_applied_r = 0` requires the first probe step to fail, and the
only biome-independent, persistent, interior-column way that happens is the row window — which
the E-runs reproduce at exactly the telemetry's altitude class). The fix makes the probe demand
exactly the engine's loadable set (single derivation site), compensates the un-verified band by
construction (height-banded zone C — never draws less than today), self-adapts to any live view
distance, and is byte-off. The W1 corner cap and the analytic-ellipsoid zone-A/B approximation
remain, disclosed, with measured bounds.
