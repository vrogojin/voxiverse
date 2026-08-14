# COSMOS FAR/NEAR GRASS-BASE — residual far-over-near protrusion at the mountain base: root cause + fix design (task #113)

**Symptom (live, user-reported, post-#110):** at the GRASS BASE of a mountain (facet 578, NAV
`13015,34,8142`, alt 33, ATT surface, `smooth_v2_res = 40`, vox backlog 0 — fully streamed) a
large FLAT smooth-GREY surface draws OVER the green near blocks, with a jagged block-silhouette
occlusion boundary (`fp2-0.jpg` / `fp2-1.jpg`). #110's `FP_ORBIT_RELIEF_SURFACE_HIDE` fixed the
snowy-SUMMIT case; this is a different pose and, it turns out, a different tier.

**Verdict up front:** the grey protruder is the **far-ring DENSE BACKSTOP
(`FP_FARRING_FULL_COVER`, blocky 26-block treads under `FP_BLOCKY_FARRING`) emitted in the
zone-B "TRUE chord − 1.5" state of the `FP_FARRING_UNCOVERED_TRUE` + `FP_FARRING_APPLIED_COVER`
three-zone law — because the applied-cover ladder is DEAD: `_applied_box_meshed`'s probe AABB
spans y ∈ [player−128, player+128], which can NEVER fit inside the voxel terrain's
bounds-clamped slab y ∈ [−64, 130], and `is_area_meshed` does not clip to bounds** (the proven
`FP_NB_WELD` fact, `module_world.gd:2035`). `_applied_r` has therefore been pinned at 0 since
`FP_FARRING_APPLIED_COVER` shipped — "zone C is empty … degraded but correct"
(`facet_far_ring.gd:3301-3302`) — which IS correct on flat/convex terrain (it is exactly what
fixed the #89 trench) but is WRONG over **concave** relief: at a mountain base the 26-block
TRUE chord rides above the realized near tops, so the un-sunk grey backstop tread wins the depth
test over real green blocks. G3 is exonerated (hidden on-surface, single `_mi`); the #107
SmoothV2 near-fill is re-exonerated at THIS window when measured owning-facet-correct.

Same dead-latch bug class as `FP_NB_WELD`'s `pool_seam_meshed` (docs/COSMOS-NB-JUNCTION-WELD):
a coverage probe whose box exceeds the terrain's bounds is unsatisfiable forever.

---

## 1. Measured facts (headless probes against the SERVED pck — live flag values baked in)

Probes (scratchpad, `probe_grassbase{,2,3,4}.gd`, run as
`docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --main-pack build/web/index.pck -s <probe>`):

1. **Live flags (pck flag-dump):** `FP_ORBIT_RELIEF_SURFACE_HIDE=true`,
   `FP_SMOOTH_V2_NEARFILL=true` (sink 6), `FP_FARRING_FULL_COVER=true`,
   `FP_FARRING_UNCOVERED_TRUE=true`, `FP_FARRING_APPLIED_COVER=true`, `FP_BLOCKY_FARRING=true`,
   `FP_FARRING_ACTIVE_NOBLACK=true`, `FP_NB_FULLRES=true`, `FP_SLOPE_MANIFEST_HEAL=true`.
   `streamed_ellipsoid_params = (r=128, O=0, H=128)`; `TierPlace.backstop_sink() = 11.73` (env_all);
   `TierPlace.ENV_EPS_G = 1.5`; `BACKSTOP_CELLS = 16` (417/16 ≈ 26-block cells);
   `APPLIED_PROBE_MAX = 112`, `UNSINK_MARGIN_BLOCKS = 24`.

2. **G3 exonerated at this pose.** `shell_offsurface()` = `_cam_set and not _emit_floored_last`
   (`facet_far_ring.gd:2933`); at alt 33 the emit is floored ⇒ off-surface false ⇒
   `step()` writes `_mi.visible = false` every frame (`facet_orbit_relief.gd:650-651`). G3 owns
   exactly ONE visible node (`_mi`, created `facet_orbit_relief.gd:506-510`) — there is no
   second mesh to leak. #110's hide is complete; the hide gap hypothesis is refuted.

3. **The facet border cuts through the repro.** Facet 578's t=1 edge runs z ≈ 8124–8140
   (corners v01=(12936.5, 8140.3), v11=(13341.3, 8124.3)); the player at z=8142 stands
   **~5 blocks from the border**; the visible mountain flank NW is on neighbour facet 579,
   whose full-res near blocks exist only since `FP_NB_FULLRES` (#102). Facet 579 is a pool
   neighbour ⇒ in `_excluded` ⇒ a DENSE BACKSTOP facet under the same three-zone law
   (`_is_backstop` = active ∪ `_excluded`, `facet_far_ring.gd:301-307`).

4. **SmoothV2 near-fill (#107) re-exonerated — owning-facet-correct.** A first in-578-lattice
   pass showed 18 % / worst +44.7 "protrusion", but every such column lies past the border where
   facet 578's lattice extension is not what is rendered — a probe artifact (the same trap the
   #110 doc's FLAT-branch caveat records). Recomputed per OWNING facet (facet_of_dir → that
   facet's node grid, datum, and lattice): **1/1681 columns over, worst +0.48 blk** — the
   sink-6 tile stays under the near mesh at the grass base too. Not the protruder.

5. **The dense-backstop zone-B surface IS above the near tops here.** Owning-facet-correct,
   window ±80 around the player: with the ladder healthy (`applied_r = 112`) only a far rim
   would protrude (38 samples, worst +4.71 at ~110 blk); with the ladder dead (`applied_r = 0`,
   all zone B = TRUE − 1.5) **56.5 % of columns protrude, mean +5.3, worst +50.9 blk**.
   BLOCKY-exact (treads = per-cell corner-MIN of the welded TRUE chord − 1.5,
   `_emit_cached`/`facet_far_ring.gd:3959-3964` + `_blend_uncovered:3315`): **41 of 80 cells
   within 130 blk protrude; worst tread +9.08 blk at cell (3,15) of facet 578, 31 blk from the
   player, over column (13012, 8137)** — a 26×26 flat grey plate up to 9 blocks above the green
   blocks, 31 blocks from the camera: the screenshots' plane, position, size and morphology.

6. **The applied-cover ladder is provably dead.** `_applied_box_meshed`
   (`facet_far_ring.gd:1591-1596`) builds `AABB` y ∈ [l1 − h, l1 + h] with
   `h = params.z = 128` and calls `_cull_cover_query(_active_fid, aabb)` →
   `module_world.skin_near_meshed` (`module_world.gd:2532-2540`), which passes the AABB RAW to
   `VoxelTerrain.is_area_meshed`. Every terrain is bounds-clamped to
   y ∈ [`BEDROCK_FLOOR` = −64, `MAX_SURFACE_Y` 116 + max(tree 14, snow 4) = 130]
   (`_apply_bounds`, `module_world.gd:1942-1951`). For the box to fit: l1 ≥ 64 AND l1 ≤ 2 —
   **contradiction at every altitude**. `is_area_meshed` treats out-of-bounds blocks as
   un-meshed (never clips — `module_world.gd:2035`, the FP_NB_WELD proof), so the probe returns
   false for every r, always: `_applied_probe_step` (`facet_far_ring.gd:1612-1626`) can never
   grow `_applied_r` past 0. Both emit paths DO plumb the live/frozen `_applied_r` correctly
   (`facet_far_ring.gd:3729-3731`, `:3936-3942`) — the value itself is the dead input.
   (Why the #89 gates were green: `verify_near_far_height.gd` drives `_applied_probe_step` with
   the `on` override + a synthetic coverage callable — engine `is_area_meshed` bounds semantics
   were never in the loop.)

7. **Why grass-base-specific (and why #110's summit A/B looked clean).** Zone B ≈
   "equal-altitude far": TRUE chord − 1.5. On flat ground chord ≈ fine ⇒ hides ~1 blk under the
   tops (this degraded mode is exactly what collapsed the #89 trench — nobody could see it was
   degraded). On **convex** relief (summit) the chord under-shoots the peak ⇒ still hidden ⇒
   after #110 hid G3, the summit read clean. On **concave** relief (the slope-to-flat mountain
   BASE) linear interpolation over 26-block cells overshoots the fine surface, while the
   realized near tops sit a further ~0.6–3.6 blk below the profile (top-face −0.64 +
   SHARP-SLOPE carve, #110 doc fact 2; `FP_SLOPE_MANIFEST_HEAL` renders the carved plane) —
   net: the measured +5…+50 excess. The border adjacency (fact 3) additionally puts brand-new
   `FP_NB_FULLRES` green blocks under facet 579's backstop, which pre-#102 had nothing near to
   conflict with — this is why the class surfaced only now.

8. **Colour fingerprint.** The blob columns are biome 9 = `B_MOUNTAINS` (stone) / 8 = plains;
   the dense backstop's env-path vertex colour is the vertex's own direct biome sample
   (26-blk pitch — `_ensure_backstop_cached_env`, `facet_far_ring.gd:3371-3379`) ⇒ flat
   featureless stone-grey plates. Matches the screenshots; V2 tiles would show 8-block-cell
   colour variation.

Falsified along the way: G3 hide gap (fact 2); second G3 node (fact 2); #107 near-fill
protrusion (fact 4); "far-ring is blocky hence visually distinct ⇒ not this bug" (#110 residual
risk (i) — it IS this bug: blocky treads at close range read as one big smooth plane).

## 2. Fix design — `FP_APPLIED_PROBE_SLAB` (make the applied-cover ladder satisfiable)

`const FP_APPLIED_PROBE_SLAB := false` in `cube_sphere.gd`, beside `FP_FARRING_APPLIED_COVER`
(`:1684-1699`).

**Principle:** don't touch the three-zone height law (its zone-C/zone-B arbitration is correct
and #89-proven); fix the dead INPUT so zone C actually exists. Probe only what a terrain can
ever mesh: clamp the probe box to the meshable slab, and prove the cross-border remainder on the
pool neighbour that owns it.

### 2.1 Shared slab derivation (single-source law)

`TerrainConfig.meshed_slab_y() -> Vector2` — returns
`(BEDROCK_FLOOR, MAX_SURFACE_Y + max(TreeGen.MAX_ABOVE_SURFACE, SNOW_FILL_MAX_CELLS))`, i.e.
(−64, 130). `module_world._apply_bounds` (`module_world.gd:1946-1948`) switches to it
(value-identical — same formula, one derivation site, the `streamed_ellipsoid_params` pattern
so ring and mesher can never quietly disagree).

### 2.2 `_applied_box_meshed` (facet_far_ring.gd:1591) — flag-gated clamped body

With the flag on:
1. **Vertical:** intersect [l1 − h, l1 + h] with `meshed_slab_y()` (always non-empty — the
   player column is inside the slab).
2. **Horizontal, active side:** intersect [l0 ± r]×[l2 ± r] with the active facet's domain slab
   `FacetAtlas.dom_min/dom_max(_active_fid) ± 2` (the `_apply_bounds` +2 seam strip). Probe the
   clamped box via the existing `_cull_cover_query(_active_fid, …)`.
3. **Horizontal, neighbour remainder:** if the un-clamped box extends past the active domain,
   for each pool-neighbour fid whose domain the box overlaps (≤ 2 in practice), require
   `module_world`'s **bounds-safe W1 seam-strip probe** (the `FP_NB_WELD` machinery,
   `module_world.gd:2048+`) to pass for that neighbour — reframed at the player, at the
   player's y, exactly as W1 already does. Any overlapped neighbour failing ⇒ probe false.
4. All-false / invalid callable ⇒ false (shipped convention).

Flag off ⇒ the shipped 5-line body verbatim (byte-identical; `_applied_r` stays 0 exactly as
today).

`_applied_probe_step` is untouched: grow ≤ 1 step/tick to `APPLIED_PROBE_MAX = 112`,
**shrink-instantly on a failed re-verify** — the no-over-claim discipline that bounds every
staleness argument below.

### 2.3 Why this cannot reintroduce see-through, and cannot regress #107/#110/#111/#112

- **See-through while streaming:** zone C emits the envelope-min − 11.73 — geometry is still
  DRAWN (FULL_COVER), merely sunk. The failure mode of an over-claimed zone C is the old #89
  cosmetic trench for ≤ 1 cadence tick (shrink-instantly reverts it), never a hole. The W1
  neighbour condition makes even that transient rare (it fails while a neighbour's seam strip
  is unmeshed — exactly when we WANT zone B's equal-altitude cover).
- **#107 near-fill:** untouched (different tier; measured under near everywhere — fact 4).
- **#110:** G3 hide untouched; off-surface behaviour untouched (`_applied_r` only ever consults
  the floored/backstop emit; ascent > 256 re-shows G3 exactly as shipped).
- **#111/#112:** render/collision of the near field untouched — this is far-ring-only.
- **#89 trench:** zone B remains the law between applied and streamed+margin; with the ladder
  live the annulus is 112→152 where the near mesh thins out anyway — measured worst there
  +4.71 at ~110 blk (rim, sub-pixel at that range).

Perf/memory: zero new caches; ≤ +2 W1 strip probes per cadence tick (was ≤ 2 `is_area_meshed`
calls); ladder converges 0→112 in 7 ticks.

### 2.4 Disclosed residuals (not scheduled)

- Zone-B annulus (112..152) keeps TRUE−1.5 over concave relief: measured ≤ +4.71 blk at
  ≥ 110 blk range. Phase-2 hardening if ever visible: zone-B height = per-cell corner-MIN (the
  `FP_BLOCKY_FARRING` argument, already the mixed-cell law) or raise `APPLIED_PROBE_MAX` to
  cover r+margin.
- `_noblack_near_meshed` (`facet_far_ring.gd:1557-1569`, YHALF=96) is unsatisfiable by the SAME
  slab argument (surface y − 96 < −64) ⇒ `FP_FARRING_ACTIVE_NOBLACK`'s covered-probe is dead and
  `_noblack_unsink_fid` latches the active fid — currently HARMLESS because
  `FP_FARRING_UNCOVERED_TRUE` supersedes the position pick (`facet_far_ring.gd:3919-3921`,
  `:3727-3731`), but it should be folded into the same slab-clamp law if noblack is ever run
  without UNCOVERED_TRUE.

## 3. Gate plan (`src/tools/verify_applied_cover_slab.gd`, headless)

- **G-ACS-OFF (byte-identity + root-cause pin):** flag off ⇒ FLAT `verify_feature.gd` 6042/0
  unchanged; with a bounds-semantics-faithful synthetic callable (returns true iff AABB ⊆ the
  slab × domain — mirrors engine `is_area_meshed` never-clip), assert the SHIPPED
  `_applied_box_meshed(16, 128, col)` is false at player y 34 AND y 110 (documents the dead
  ladder so the root cause stays reproducible).
- **G-ACS-SAT (ladder lives):** flag on, same callable: probe true at both y's; driving
  `_applied_probe_step(on = true)` grows `_applied_r` 16→112 in 7 calls; flipping the callable
  false drops it to 0 in ONE call (shrink-instantly law intact).
- **G-ACS-LAW (the protrusion pin, from §1 facts 5):** facet 578 grass-base window,
  owning-facet-correct (facet_of_dir per sample):
  (a) zone-C heights (envelope − backstop_sink) ≤ realized near tops at every sampled column —
  healthy ladder ⇒ no protrusion, including border cell (3,15) / column (13012, 8137);
  (b) pin the degraded state: zone-B corner-MIN treads protrude at ≥ 30 % of cells within
  130 blk with worst ≥ +5 (a silent future re-death of the ladder fails loudly);
  (c) V2 near-fill ≤ near tops + 1 everywhere (guards the #107/#110 exonerations);
  (d) `shell_offsurface() == false` fixture ⇒ G3 `_mi.visible == false` (guards #110).
- **LIVE-EYEBALL-REQUIRED:** repro-spot A/B (flag on): grey plane gone at alt 33; walk across
  the 578/579 border both ways (the #112 spot) — no render change to near blocks, no
  fall-through change; a fresh-teleport streaming window still shows grey-smooth cover while
  `backlog > 0` (#107 cover + zone-B interim — must remain); ascend > 256 ⇒ G3 relief returns.

## 4. Injection points (exact)

| File | Change |
|---|---|
| `godot/src/cosmos/cube_sphere.gd` | `+ const FP_APPLIED_PROBE_SLAB := false` (beside `:1696`) |
| `godot/src/world/terrain_config.gd` | `+ static func meshed_slab_y()` (§2.1) |
| `godot/src/world/voxel_module/module_world.gd` | `_apply_bounds` consumes `meshed_slab_y()` (value-identical) |
| `godot/src/world/facet_far_ring.gd` | `_applied_box_meshed` flag-gated clamped body + neighbour W1 remainder (§2.2, `:1591-1596`) |
| `godot/src/tools/verify_applied_cover_slab.gd` | new gate (§3) |

Optional telemetry (recommended, 1 line): add `"sh_applied_r": _applied_r` to the far-ring
stats dict (`facet_far_ring.gd:~2995`) so the live ladder is finally observable — the absence
of this counter is why the dead state went unnoticed for two shipped fixes.
