# COSMOS — Far-ring full coverage (the see-through gap fix)

**Status:** design, flag-gated, A/B-able live. Default OFF ⇒ current behaviour byte-for-byte.
**Flag:** `CubeSphere.FP_FARRING_FULL_COVER` (new), default `false`.
**Files:** `godot/src/world/facet_far_ring.gd`, `godot/src/world/world_manager.gd:2054`
(`_facet_ring_sync_exclusion`), `godot/src/cosmos/cube_sphere.gd` (flag).
**Supersedes/extends:** `docs/COSMOS-RENDER-SIMPLIFY-DESIGN.md §2.5` (the active-facet
`ACTIVE_BACKSTOP_SINK` backstop) — that idea covers only the *active* facet; this design
extends the sunk backstop to the **active facet + every live-pool-excluded facet**, which is
where the visible hole actually is.

---

## 1. Root cause (cite file:line)

The faceted far layer is `FacetFarRing` (`facet_far_ring.gd`), a single merged whole-planet
coarse mesh (one `MeshInstance3D`, `CELLS = 4` heightmap cells per facet edge — `:19`) placed
by ONE rigid transform (`_placement_xform`, `:84`) into the active facet's render frame. It is
the universal backdrop behind the near blocky terrain and the pool.

**What it actually draws** is decided by `_front_visible(fid, nrm)` (`:214-220`):

```
fid == _active_fid            → NOT drawn   (:215-216  "near voxel world already covers it")
_excluded.has(fid)            → NOT drawn   (:217-218  live-pool neighbours ∪ LOD-covered)
cd·nrm >= BACK_CULL (0.0)     → drawn iff front hemisphere (:219-220)
```

`_excluded` is the **live pool neighbour set**, pushed every spawn/retire/crossing by
`world_manager.gd:2054 _facet_ring_sync_exclusion` → `set_pool_excluded` (`:110-117`):
`pool_neighbour_fids()` (∪ `lod_covered_fids()` only when `_near_lod_on()`).

So the far-ring draws every front-hemisphere facet **EXCEPT** the active facet and the 1–`FP2_LIVE_CAP`(=2) live-pool neighbours (`POOL_MAX_NEIGHBOURS = 4` hard cap). **Those excluded
facets have no far-LOD quad at all.**

**Why that is a hole.** The near voxel field is a disk of radius `near_render_radius()` about
the *player* — shipped faceted = **128 blocks** (`terrain_config.gd` `CURVED_RENDER_RADIUS_BLOCKS`,
256 only under `FP_FULLRES_256`). A facet is `(π/2·R)/K = (π/2·3072)/24 ≈ **201 blocks** edge
(`facet_atlas.gd:12-13`), so centre-to-corner ≈ **142 blocks**. Even standing dead-centre on the
active facet, the corners (142) fall outside the 128 near disk; off-centre it is worse, and the
excluded neighbour facet(s) in the crossing direction add another ~200-block excluded sector.
Result: an **annular see-through band** from ~128 blocks out to the first *non-excluded* facet.

**Why you see "the opposite inner side of the globe."** The ring material is `CULL_DISABLED`
(`:415`) and the whole planet is one bowl of front-hemisphere facets curving away below the
player. The excluded active+neighbour facets punch a hole at the top of the bowl; the near disk
plugs only its centre 128 blocks. Through the annular gap the camera sees the **far rim of the
same front-hemisphere bowl** — the inner faces of the coarse quads on the opposite side of the
hole. It is not a culling/winding bug and not the back hemisphere; it is precisely the excluded
active+neighbour facets having no quad. (`docs/COSMOS-RENDER-SIMPLIFY-DESIGN.md §2.5` reaches the
same conclusion for the active facet; the live-pool neighbours widen it.)

**Does the near terrain reach far enough to hide the ring where they overlap?** No — there is a
genuine **radius gap**: near ends at 128, the active facet's own quad is excluded out to its
~142–201-block edge, so 128→edge is covered by *nothing* on the active facet, and 0→~128-into-a-
neighbour on each excluded neighbour.

---

## 2. The fix — draw ALL front-hemisphere facets, sink the ones under the near field

Per the user's model: **every front-hemisphere facet renders a far-LOD quad, overdrawn by the
near blocky terrain where they overlap.** Under `FP_FARRING_FULL_COVER`:

- `_front_visible` **stops excluding** the active facet and the `_excluded` (live-pool) set —
  they are drawn like any other front-hemisphere facet. Back-hemisphere cull stays (`§5`).
- Those formerly-excluded facets are emitted **sunk radially inward** by `BACKSTOP_SINK` blocks
  so the opaque near voxels sit strictly *in front* of them (no z-fight, no poke-through), and
  the former gap is filled by coarse far-LOD hills that match the near surface shape.

The sink is applied **per emitted vertex**, only to sunk facets, at emit time — the cached
absolute position is radial, so `p_sunk = p − p.normalized()·BACKSTOP_SINK`. No new cache, no
change to non-sunk facets. `_front_visible` returns true for these facets; a companion
`_is_backstop(fid)` (`fid == _active_fid or _excluded.has(fid)`) tells `_emit_cached` /
`_async_build_worker` whether to sink.

### 2.1 Which facets are sunk vs full
- **Sunk (backstop):** active facet + `_excluded` set (the near disk / pool overlaps them).
- **Full relief (unchanged):** every other front-hemisphere facet — these are the visible
  horizon and MUST keep their exact shipped geometry so the silhouette is byte-identical.

Because the sink is decided by `_is_backstop(fid)` at emit time, a facet transitioning
excluded→distant across a crossing automatically drops the sink on the next rebuild (no stale
sunk geometry baked into `_pos_cache`, which is keyed by fid and shared by both roles).

---

## 3. Sink depth (reasoned vs terrain relief) + backstop resolution

The sink must satisfy two opposing constraints **in the overlap band only** (0→near_radius on
the active facet; 0→band on each neighbour) — beyond the near edge there is no near terrain to
poke through, so the sink there is merely a benign uniform dip:

1. **No poke-through:** the coarse backstop must stay below the near blocky surface wherever
   near terrain exists, else a coarse-coloured triangle stabs up through the fine terrain.
2. **Small boundary step:** at the near edge the backstop is `BACKSTOP_SINK` below where near
   ends; too deep = a visible cliff ring. Keep it a few blocks (at planet distance, invisible).

**Why a small constant sink alone is not enough at `CELLS = 4`.** Both layers derive from the
SAME `g` heights (`TerrainConfig.profile_at_dir`), and the backstop passes exactly through `g`
at its sample columns. The error is *between* samples: at `CELLS = 4` a cell is ≈ **50 blocks**.
Terrain relief: hills ±3 (`HILLS_AMPLITUDE`), detail ±1, and **mountains up to
`MOUNTAIN_AMPLITUDE = 92` blocks** (`terrain_config.gd:101`; analytic max relief 112, `:216`).
On a steep mountain flank the near surface can dip **~15–25 blocks below the 50-block chord**
between two far samples. A 1.5-block sink (RENDER-SIMPLIFY's active-only value) would poke badly
in mountains.

**Two levers, use both:**

- **`BACKSTOP_CELLS` — raise the backstop resolution of the sunk facets** from 4 to **16**
  (cell ≈ 12.5 blocks). Chord error scales ~linearly with cell size, so the worst flank dip
  drops to ~4–7 blocks. This is the principled move: match the backstop density to the near
  terrain it must hide behind. Cost is trivial (§5). Non-backstop facets keep `CELLS = 4`.
- **`BACKSTOP_SINK` ≈ 6 blocks** (default). Clears: facet chord sagitta (~1.6 blocks at facet
  centre — the planar corners sit below the sphere), relief quantization, and the residual
  ~4–7-block flank dip at `BACKSTOP_CELLS = 16`, with a small margin. At R = 3072 / camera_far
  9000, a 6-block step at ≥128 blocks subtends < 0.05° — not visible.

**Both are constants the gate tunes.** If the mountain-spawn sweep (§6) still pokes, the levers
are independent: raise `BACKSTOP_CELLS` to 32 (cell ≈ 6 blocks, dip ~2–4) and keep sink 6, OR
raise sink. Prefer resolution over sink so the boundary step stays small. Recommended start:
`BACKSTOP_CELLS = 16`, `BACKSTOP_SINK = 6.0`.

> Note: `_ensure_cached` currently builds one `(CELLS+1)²` grid per facet. A per-role cell count
> means a backstop facet needs its own denser cache. Keep it simple: cache backstop facets at
> `BACKSTOP_CELLS` in a **separate dict** (`_bpos_cache`/`_bcol_cache`) built lazily by
> `_ensure_backstop_cached(fid)`; `_emit_cached` picks the dense+sunk arrays when `_is_backstop`,
> the shipped grid otherwise. Zero cost/cache with the flag off (never populated).

---

## 4. Composition with the existing machinery

- **`FP_FARRING_ASYNC_REBUILD` (`:159 _async_build_worker`)** — the worker emits `visible_fids()`
  into a `SurfaceTool` and computes global smooth normals off-thread. FULL_COVER only changes
  (a) which fids `visible_fids()`/`_front_visible` returns (now incl. active + excluded), and
  (b) whether `_emit_cached` sinks a given facet. Both are pure reads of `_bpos_cache`/`_pos_cache`
  frozen for the worker's lifetime (same happens-before contract as today). **The sink and the
  dense backstop caches must be warmed on the main thread before dispatch** — extend `_warm_front`
  (`:197`) to also `_ensure_backstop_cached` the backstop fids so the worker only ever reads.
- **`FP_FARRING_FAST_REBUILD` (`:268 _build_fast`)** — the memcpy path uses `_tri_pos_cache`
  (pre-triangulated, non-sunk). A sunk facet cannot ride that memcpy. Simplest: under FULL_COVER,
  backstop facets fall back to the per-vertex `_emit_cached` path (a handful of facets — §5),
  non-backstop facets keep the memcpy. Both flags are experimental/default-off; document the
  compose rule, no deep integration needed.
- **The atlas (Atlas Stage 1/2, `FP_ATLAS_MATERIAL`)** — atlas work is on the **near** opaque
  cube meshes in `module_world`. The far-ring has its **own** `StandardMaterial3D`
  (`_make_material :412`, `vertex_color_use_as_albedo`, `CULL_DISABLED`). Untouched, orthogonal.
- **Removed near-LOD (`FP_NO_NEAR_LOD`)** — with no LOD, `_facet_ring_sync_exclusion`
  (`world_manager.gd:2063-2068`) already collapses `_excluded` to live-pool neighbours only.
  FULL_COVER then draws those (sunk) instead of leaving holes — strictly better; no interaction
  to special-case.
- **Fixed frame / re-anchor (`FP_FIXED_FRAME`)** — the backstop is part of the same absolute-coord
  merged mesh, so `_placement_xform` (`:84`) and `shift_anchor` (`:92`) carry it exactly as they
  carry the rest of the ring. No new frame wiring.
- **Crossing (`set_active :75` / `set_pool_excluded :110`)** — unchanged. The deferred/budgeted
  `_process` rebuild (`:124`) re-emits the new excluded set; the freshly-excluded neighbour becomes
  a sunk backstop, the just-left facet drops its sink — both on the next off-frame rebuild. During
  the ≤1–2 stale frames the old merged mesh still covers the region (no new blank).

---

## 5. Planet self-occlusion, back hemisphere, cost, NEVER-OOM

- **Keep the back-hemisphere cull** (`BACK_CULL = 0.0`, `:220`). Back facets sit behind the
  planet centre; today they only ever showed *through* the gap, which the backstop now closes,
  so drawing them would be pure waste (~+55k tris of hidden overdraw). Do not lower `BACK_CULL`.
- **Draw/tri cost.** Front hemisphere ≈ 3456/2 ≈ **1728 facets already drawn** as one mesh
  (≈ 55k tris at 32 tris/facet). FULL_COVER adds back the active + excluded facets: **1–5 facets**.
  At `BACKSTOP_CELLS = 16` that is 5 × (16²·2 = 512) ≈ **2.6k extra tris** (< 5% of the far mesh;
  the absolute whole-planet cap is 6·K²·32 = 110k). One draw call (still one merged mesh).
- **Overdraw is neutral-to-favourable.** The sunk quads under the near disk are depth-rejected by
  the opaque near voxels (early-z), ~free. The gap-fill pixels (128→edge) were *already* drawing
  the planet interior through the hole; now they draw the nearer backstop, and the backstop
  **occludes** the interior facets behind it, letting early-z reject them. Net fill ≈ neutral,
  likely slightly lower.
- **NEVER-OOM.** No new allocation *category*: still ONE merged, front-hemisphere-bounded mesh.
  The extra bytes are the dense backstop caches for ≤ (1 active + 4 pool-cap) = 5 facets at
  `BACKSTOP_CELLS = 16` → 5 × 17²·(12 B pos + 16 B col) ≈ **40 KB**, bounded and constant. The
  merged GPU mesh grows by ~2.6k tris. Both bounded independent of walk distance.

---

## 6. Flag gate + headless gates

**Flag:** `const FP_FARRING_FULL_COVER := false` in `cube_sphere.gd`, requires `FACETED`.
Flipped ON at export after the live A/B (the established sed-at-export pattern). OFF ⇒
`_front_visible` excludes active+`_excluded` exactly as today, no backstop cache, FLAT stays
6035/0.

Extend a faceted gate (`verify_faceted.gd` / a new `verify_farring_cover.gd`):

- **G-FRC-COVER (no excluded front-hemisphere facet):** with `FP_FARRING_FULL_COVER` on, after
  `force_rebuild()`, assert **every** front-hemisphere facet (`cd·nrm ≥ 0`) is in the emitted set
  — i.e. no `_front_visible == false` for a front facet except pure back-hemisphere. Directly
  encodes "no hole." With the flag off, assert the complement (active + `_excluded` absent) so the
  byte-identical claim is checked too.
- **G-FRC-NOPOKE (backstop stays below near surface):** for a **spawn sweep** that MUST include a
  mountain-foothill spawn (worst chord error), for each sunk facet, for each *near* column within
  `near_render_radius()` (sample per-block, not just at far vertices), assert the backstop surface
  height at that column (bilinear-interpolated backstop y, minus `BACKSTOP_SINK`) is `<` the near
  blocky surface `g` there. This is the tuning oracle for `BACKSTOP_SINK`/`BACKSTOP_CELLS`.
- **G-FRC-BOUND (NEVER-OOM):** assert `triangle_count()` ≤ front-hemisphere bound and the backstop
  cache size ≤ the 5-facet bound — no growth with walk distance.
- **Async parity (extend G-L1-FARRING-ASYNC):** the async worker's emitted arrays are bit-identical
  to the synchronous `force_rebuild` under FULL_COVER (same sink applied both paths).

---

## 7. Risks

- **z-fight at grazing angles:** killed by the radial sink (backstop is `BACKSTOP_SINK` blocks
  behind near in depth). At near-tangent viewing the near terrain's own lip occludes the step;
  gate G-FRC-NOPOKE proves the backstop never rises to the near surface.
- **Poke-through in extreme mountains:** the real risk. Mitigated by `BACKSTOP_CELLS = 16` +
  sink 6; if the mountain-spawn sweep fails, raise `BACKSTOP_CELLS` to 32 (cell ≈ 6 blocks) before
  raising sink, so the boundary step stays small. The gate is the guard.
- **Horizon look:** unchanged — non-backstop facets keep exact shipped geometry, so the silhouette
  is byte-identical; only the former annular gap now shows coarse hills a few blocks lower.
- **Boundary step at the near edge:** `BACKSTOP_SINK` blocks; subtends < 0.05° at ≥128 blocks —
  cosmetically negligible. If field-visible, blend the sink to 0 across a 1-cell band at the near
  edge (refinement, not needed for v1).
