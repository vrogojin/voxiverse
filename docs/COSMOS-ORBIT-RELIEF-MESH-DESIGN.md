# COSMOS G3 — real far-terrain 3D relief MESH from orbit (FP_ORBIT_RELIEF)

Fable design, 2026-08-10. User verdict after the live A/B of the shading-only fix (`FP_SKIN_RELIEF_SHADE` +
`FP_RELIEF_REEMIT`): **rejected** — "still looks flat, no sense in shaded relief." The ask is real geometry:
mountains that rise and valleys/cliffs that drop, visible in silhouette on the limb and on descent, not a
darker patch of colour on an otherwise flat radial shell. This is G3 from
`docs/COSMOS-FAR-GEOMETRY-PREBAKE-DESIGN.md`'s outline, turned into a concrete, implementable spec.

## 0. What already exists (reused, not rebuilt)

- **`GlobalReliefData` (G2, `FP_GLOBAL_RELIEF_DATA`)** — the whole-planet i16 height DEM, already SHIPPED and
  proven live (`g2_baked=3456` confirmed): `CELLS=32` cells/facet edge, `NODES_PER_EDGE=33`,
  `NODES_PER_FACET=1089`. Height accessor: **`height_at(fid, i, j) -> int`** (blocks, `i,j ∈ [0,32]`; 0 if not
  ready/baked/out of range — never garbage). Baked facet-by-facet under a governed pacer (≤1 facet/frame,
  `BG_FRAME_BUDGET_MS`-gated) via `bake_smooth_tile` (patch 0012) or the `FarDensity.node_at` GDScript oracle —
  **this is the ONE place allowed to touch worldgen**; it already happened, is already paced, and is orthogonal
  to G3. `global_relief_data.gd` needs **zero changes** for G3.
- **`FacetSmoothV2` (`facet_smooth_v2.gd`)** — the closest architectural analog: a view-dependent, hop-BFS-
  resident, single-ArrayMesh relief tier with a small fixed `WorkerThreadPool` slot pool, dwell-based eviction,
  and a fixed-canonical-order `merge_tiles`. **Three of its statics are directly reusable, unmodified**:
  `hop_annulus(active, hop_b, hop_h)` (pure BFS residency, generic over hop bounds), `merge_tiles(tiles)` (race-
  free ascending-fid concatenation), and the `tile_bytes`-shape ledger convention. G3 is a **new sibling class**,
  not a V2 modification — V2's own doc is explicit that it is "a NEW, separate subsystem" from the old ladder;
  the same discipline applies here (G3 must not touch V2's flag/behaviour).
- **The structural difference from V2 (and from the shelved S-ladder) that makes G3 safe to build**: V2's
  `build_tile` calls into live worldgen every tile build (`bake_smooth_tile`/`FarDensity.node_at`, a real
  `profile_at_dir` sample per node) — the S-ladder's warmup convoy was exactly this cost multiplied across many
  tiles per frame. **G3's `build_tile` never samples worldgen at all.** Every input it needs —height
  (`height_at`), position direction (`FacetAtlas.facet_corner_dirs` bilerp, a 12-float64 static-table read, not
  a noise sample) — is either already-baked DEM data or cheap frozen atlas geometry. This is the structural fix,
  not a tuning knob.
- **Weld law (One-Surface Law, already established for FS1/V2)**: a node's world direction is
  `bilerp(FacetAtlas.facet_corner_dirs(fid), i/CELLS, j/CELLS)` (f64 bilerp, f32 cast at the end — the exact law
  `FacetFarRing._weld_unit`/`FacetSmoothV2.build_tile` already use). Two facets sharing a grid edge share the
  same 2 canon corner dirs, so at the shared edge (`s` or `t` = 0 or 1) both facets bilerp to the SAME f32
  direction — **by construction**, not by numerical luck. G2's own bake already derives its heights from this
  same direction (via `corner_dirs` passed into `bake_smooth_tile`/`node_at`), so a G3 node's re-derived
  direction and the direction G2 sampled that height at are the SAME value — the height and the placement agree
  by construction, with zero re-sampling.
- **Radial placement law**: `d * (r_datum + relief)`, `relief = maxf(0, g - SEA_LEVEL) * RELIEF` — the exact
  `_weld_place` law every other far tier uses (`RELIEF := 1.0`, `facet_far_ring.gd:28`).

## 1. The tier: `FacetOrbitRelief` (new file `godot/src/world/facet_orbit_relief.gd`)

A new sibling to `FacetSmoothV2`, NOT a `FacetFarRing` method set (keeps the 4200-line `facet_far_ring.gd` from
growing further, and keeps G3's flag/lifecycle fully separable — exactly the precedent V2 itself set relative to
the old ladder). Owned by `FacetFarRing` (a second small `MeshInstance3D` child, alongside `_smooth_v2`),
constructed and stepped only under `FP_ORBIT_RELIEF`.

### 1.1 Tile pitch — literally G2's own grid, no rescale

`ORBIT_RELIEF_CELLS := GlobalReliefData.CELLS` (32; not a separate constant — a tile IS one facet's DEM, 1:1).
This is deliberate: no interpolation, no rescale-factor bookkeeping (unlike the shell/G2 `g2_scale=8` mapping
`FP_SKIN_RELIEF_SHADE` needed) — every G3 node maps to exactly one G2 node, `height_at(fid, i, j)` directly.

### 1.2 `build_tile(fid, heights, coarse_col, sink_edges) -> Dictionary` — pure, worker-safe, static

**IMPLEMENTED signature** (revised from the sketch below during implementation — see the thread-safety note):

```gdscript
static func build_tile(fid: int, heights: PackedInt32Array, coarse_col: PackedColorArray, sink_edges: int) -> Dictionary:
    var cells := ORBIT_RELIEF_CELLS
    var stride := cells + 1
    var n := stride * stride
    if heights.size() != n:
        return {}   # refusal — malformed/empty snapshot (facet not baked; caller re-tries later, mirrors V2's refusal law)
    var cd := FacetAtlas.facet_corner_dirs(fid)      # write-once atlas data — safe to call from a worker
    var r_datum := FacetAtlas.r_of(fid)
    var pos := PackedVector3Array(); pos.resize(n)
    var nrm := PackedVector3Array(); nrm.resize(n)    # placeholder (== radial dir); overwritten at commit, §1.6
    var col := PackedColorArray(); col.resize(n)
    var g := PackedInt32Array(); g.resize(n)          # kept for G-OR-DATA-EQ / no-protrusion checks
    for j in range(stride):
        for i in range(stride):
            var k := j * stride + i
            var d := _weld_unit(cd, float(i) / float(cells), float(j) / float(cells))  # SAME bilerp as _weld_unit
            var h := heights[k]
            g[k] = h
            var relief := maxf(0.0, float(h - TerrainConfig.SEA_LEVEL)) * FacetFarRing.RELIEF
            pos[k] = d * (r_datum + relief)
            nrm[k] = d
            col[k] = coarse_color(coarse_col, i, j, ORBIT_RELIEF_CELLS / FacetFarRing.CELLS, FacetFarRing.CELLS)  # §1.4
    var idx := _grid_indices(cells, stride)            # plain 2-tri/cell grid, no provoking-vertex trick needed
    var tile := {"pos": pos, "nrm": nrm, "col": col, "g": g, "idx": idx}
    _append_edge_sink(tile, cells, stride, sink_edges)  # §1.5 — the no-protrusion guard, edge-mask-scoped
    return tile
```

`_weld_unit`/`_grid_indices`/`_edge_indices` are literal copies of `FacetFarRing._weld_unit`/`FacetSmoothV2`'s
grid-winding/edge-indexing helpers — no new geometry law, just relocated so G3 has no dependency on the other
tiers' internals (the established convention every small pure helper in this codebase already follows, rather
than reaching into another file's underscore-prefixed methods).

**Thread-safety (the one real implementation refinement beyond the original sketch):** `build_tile` no longer
takes a live `GlobalReliefData`/`_col_cache` reference. `GlobalReliefData` is an ONGOING-write array (the G2
pacer keeps baking new facets live during gameplay, unlike `FacetAtlas`'s write-once-then-read-only tables), so
a worker reading it directly would be a data race. The CALLER (main thread, in `step()`, right before dispatch)
extracts a private snapshot via `GlobalReliefData.height_grid(fid)` (a new small accessor, 1089 `decode_s16`
reads) and `FacetFarRing.col_cache_for(fid)` (a `.duplicate()`) and hands those plain value-type arrays to the
worker instead — no shared live object ever crosses the thread boundary. `FacetAtlas.facet_corner_dirs`/`r_of`
ARE still called directly inside `build_tile` (on the worker) — safe, because the atlas is write-once (built at
`warm_up()`, never mutated during gameplay), the SAME class of data `FacetSmoothV2.build_tile` already reads
from a worker today.

Refusal contract mirrors V2 exactly: `{}` if `heights` is empty/wrong-size (facet not baked / malformed
request) — the caller never commits an empty tile, and the fid stays in the want-order for a later retry (a
facet with no DEM yet simply has no G3 tile; the flat shell underneath is visible there in the meantime, never
a hole).

### 1.3 `_cpp_gen`: none needed

Unlike V2, G3's `build_tile` takes NO generator object at all — it never calls `VoxelGeneratorCosmos`. This
removes an entire class of "module absent → GDScript fallback" branching V2 has to carry; G3 behaves
identically whether or not the module is compiled in, because it never touches it.

### 1.4 Colour — reuse the shell's ALREADY-computed coarse colour, zero new sampling

G2 stores height + (under `FP_SKIN_RELIEF_SHADE`) a shade byte — no biome/temp, so G3 cannot re-derive a
block-exact colour from G2 alone without adding worldgen back in. Instead: **read the coarse CELLS=4 shell's own
`_col_cache[fid]`**, the SAME colour (biome-blend, or block-exact under `FP_SKIN_BLOCK_COLOR`, whichever the
shell already resolved for that facet) that the flat backdrop underneath already shows. A G3 node maps to its
nearest coarse shell node: `ci = clampi(int(round(float(i)/8.0)), 0, 4)`, `cj = clampi(int(round(float(j)/8.0)), 0, 4)`
(8 = `GlobalReliefData.CELLS / FacetFarRing.CELLS`, the SAME exact ratio `FP_SKIN_RELIEF_SHADE`'s `g2_scale`
already established), then `_col_cache[fid][cj * 5 + ci]`. **Pure array read — no `FarPalette` call, no
`top_block_id`, no noise.** Dependency: the shell's `_ensure_cached(fid)` must have already run for `fid` — true
by construction, since the shell's own base-grid residency already spans the WHOLE visible hemisphere (far
broader than G3's own capped tile count, §2), so by the time G3 wants a tile for `fid`, `_col_cache[fid]` is
already there. If it is ever momentarily absent (a boot-race), `_coarse_color` degrades to a neutral swatch
(`Color(0.5, 0.5, 0.5)` — matching the "never a black hole" convention `shade_at`/`far_color_index_of_block`
already use) rather than blocking the tile build.

*(Not required by any G-OR gate below — this section documents the appearance decision so the tier isn't
literally colourless; the gates focus entirely on geometry, matching the user's actual complaint.)*

### 1.5 No-protrusion at the V2/near boundary — the edge-mask sink guard

G2's heights are exact `profile_at_dir` samples at the DEM's own 13-block pitch — not a min-envelope like the
shell's `FP_ENV_ALL` law. Between two DEM samples on a steep slope, the true near surface can rise above the
straight-line interpolation the mesh draws (the exact class of bug `FP_ENV_ALL` fixed for the shell's coarser
CELLS=4 grid) — bounded, since G3 samples ~8× finer than the shell, but not eliminated. **Do not extend G2's
bake to a min-envelope** (that would require re-sampling a footprint per node, re-adding the per-node worldgen
cost this design exists to avoid, inside the SAME governed-pacer bake pass that must stay ≤1 facet/frame).

**IMPLEMENTED (revised from the original sketch's "always sink row j=0" assumption — that row does NOT reliably
face `active_fid`; a facet's local `(i,j)` axes are fixed by its position in the cube-sphere lattice, not by its
relationship to whichever facet happens to be active, so a fixed-row sink would sink the WRONG edge on 3 of 4
facet orientations).** Instead, sink is scoped per EDGE via a 4-bit mask (`FacetSmoothV2.EDGE_WEST/EAST/SOUTH/
NORTH`), computed by the caller (main thread, `edge_sink_mask(fid, want)`) from the CURRENT want-set: for each
of the facet's 4 cardinal `FacetAtlas` seam-neighbours, if that neighbour is NOT also in `want` this build, the
edge facing it is a frontier (bordering V2/near/unclaimed territory) and gets flagged; a neighbour that IS also
resident in G3 means both tiles render that shared edge at the SAME true DEM height, so it is left un-sunk (no
crack — sinking one tile's copy of a shared edge and not the neighbour's would open a visible gap). Flagged
edges sink by `TierPlace.backstop_sink()` (`BACKSTOP_SINK := 6.0` blocks, `FacetFarRing._sunk_positions_amt`'s
exact `p - p̂·sink` law, inlined since that method is an instance method and `build_tile` must stay
static/worker-safe). G3's interior nodes (and any edge bordering another resident G3 tile) are accepted at face
value — the same fidelity tradeoff the shell's own un-enveloped tiers already accept elsewhere, and at that
distance sub-node protrusion is cosmetic, not gameplay-relevant (no collision, nothing walks there). `G-OR-WELD`
asserts both halves: the flagged edge sinks by exactly `backstop_sink()`, and every non-flagged node is
byte-identical to the unsunk build.

### 1.6 Normals — REVISED after a live perf regression: per-tile analytic, off-thread, NO SurfaceTool

**The original plan below was shipped, A/B'd live, and rolled back** ("extremely laggy, can't do much" — root-
caused to `SurfaceTool.create_from + generate_normals()` over the whole merged mesh costing ≈250-367ms/commit
on ~384 tiles/≈418K verts, ON THE MAIN THREAD, repeated every `ORBIT_RELIEF_COMMIT_MS` through the whole
build-up). `G-OR-PACE`'s rate/count checks didn't catch it because they measured commit *frequency*, not commit
*duration* — `G-OR-COMMIT-COST` (§5) now covers that gap.

**IMPLEMENTED fix:** each tile's `build_tile` (already worker-dispatched) computes a REAL per-vertex analytic
normal from its own completed position grid — central-difference tangents (`pos[i+1,j]-pos[i-1,j]`,
`pos[i,j+1]-pos[i,j-1]`, one-sided at the tile's own boundary), cross-producted, oriented outward against the
local radial direction. This is the SAME cross-product + outward-orientation convention `FacetSmoothV2`'s V2-2
(`FP_SMOOTH_V2_LIT`) provoking-vertex normal already uses, just applied to every node (G3's colour is already
smooth/per-vertex, so there is no provoking-vertex constraint to respect). The commit step no longer touches
`SurfaceTool` at all: `FacetSmoothV2.merge_tiles` (reused, race-free ascending-fid order) concatenates the
already-complete pos/nrm/col/idx arrays, and ONE `ArrayMesh.add_surface_from_arrays` call uploads them — no
CPU-side geometry analysis on the main thread. Measured (headless, real 384-tile-equivalent merge): the OLD
path cost 367ms; the NEW path (whole set, unbatched) costs 15ms; the NEW path AS ACTUALLY CALLED (§3's
`ORBIT_RELIEF_COMMIT_TILES`-batched commit, 24 tiles/≈26K verts) costs **<1ms**.

**Disclosed trade-off:** a tile's own boundary normal is a one-sided estimate (no cross-tile smoothing, unlike
`generate_normals`'s "GLOBAL smoothing merges shared vertices across facet seams" property) — a faint normal
kink is possible at a G3-G3 tile edge under grazing light. Cosmetic only, invisible at G3's own orbital viewing
distance, and a strictly better trade than the measured main-thread stall. Positions/heights are UNCHANGED by
this fix — only where normals are computed and how the mesh is assembled moved.

Material: reuse `FacetSmoothV2`'s `FP_SMOOTH_V2_LIT` shader family (real per-vertex `NORMAL`-driven shading,
via the now-public `FacetSmoothV2.make_material()`) rather than the shell's own radial-only `_SHELL_ABS_SHADER`
— G3's normals carry genuine slope information (unlike the flat shell), so a real-normal shader is where that
information actually gets used. This is a shading/material follow-up, not gated here (no `verify_atmo_sky`-
class live-probe gate exists for shader source in this repo — same disclosed limitation V2's own doc carries).

## 2. Coverage / residency — ONE pure law, now covering BOTH the nadir foreground AND the visible silhouette

**REVISED after team-lead review.** The original law below (nearest-to-`emit_axis` only) was found to under-
cover the LIMB: `shell_emit_axis()` is the camera-position cull axis, so a nadir-only ranking reaches only
~28° from nadir at a typical orbital altitude (alt≈1500) while the true horizon tangent is ~36° out — the
outer silhouette band, which is what the orbit camera actually holds on screen (the horizon, not the ground
directly below), would have stayed on the flat shell. A mountain profile reads on the SILHOUETTE; leaving it
smooth would reproduce the exact "still looks flat" failure this design exists to fix.

**IMPLEMENTED coverage law** — one ranking, both bands, no altitude branch:

```
phi(fid)      = angle between fid's centre direction and emit_axis
theta_h       = FacetFarRing.shell_emit_thetah() — the TRUE horizon-tangent angle (distinct from theta_emit,
                which is theta_h PLUS the shell's own relief/slack margin), -1.0 sentinel = no snapshot yet
priority(fid) = phi                              if theta_h < 0   (surface/descent — no horizon concept yet)
              = min(phi, |phi − theta_h|)         otherwise        (orbit — nadir AND the horizon ring both rank high)

want(active_fid, emit_axis, theta_h) =
    the ORBIT_RELIEF_MAX_TILES facets with the SMALLEST priority, among all facets within theta_h of emit_axis
    (the whole visible cap; off-surface) or within a fixed ORBIT_RELIEF_FALLBACK_REACH_RAD (on-surface, no
    horizon to bound by), EXCLUDING active_fid's own V2 footprint (hop 0..v2_hop_h — the caller resolves
    v2_hop_h from FP_SMOOTH_V2_REACH, mirroring how FacetSmoothV2.setup_instance picks its own _hop_h).
```

`priority`'s two-term `min` is the key change: a facet near NADIR (small `phi`) ranks highest, and a facet near
the HORIZON RING (small `|phi − theta_h|`) ALSO ranks highest — only the angularly-MIDDLE band (neither
underfoot nor silhouetted — the least visually consequential region) gets truncated first once the candidate
count exceeds the cap. At high altitude this naturally degrades to covering both ends densely and the middle
sparsely; at the surface (`theta_h < 0`) it reduces exactly to the original nearest-to-axis law (no horizon
concept exists yet, so there is nothing to weight toward), collapsing to a local annulus beyond V2's own hop≤4
as a consequence of the geometry, not a hard-coded "hop 5..12" special case.

**Byte budget raised accordingly.** Memory is not the binding constraint (well inside the 2048 MB ceiling; the
real cost is the rate-capped `generate_normals()` commit, §3) — `ORBIT_RELIEF_MAX_TILES` is raised from the
original 200 to **384** so the cap comfortably covers the WHOLE visible cap at the reference altitude
(alt≈1500, θ_h≈36°: `(1 − cos 36°)/2 × 3456 ≈ 330` facets) without truncating away either band; at higher
altitudes (larger θ_h, more facets in the candidate pool) the priority law truncates gracefully, still favouring
both nadir and limb over the middle. See §4 for the exact byte arithmetic at the new cap.

**Honest limit, disclosed (mirrors the accepted precedent in `docs/COSMOS-BLOCK-LOD-DESIGN.md`: "L5 full globe
158MB infeasible → data floor + near-nadir"):** `ORBIT_RELIEF_MAX_TILES`(384) still cannot cover a full visible
hemisphere (1728 of 3456 facets) from VERY high orbit (θ_h approaching 90°). Beyond the reference altitude the
priority law keeps nadir and the current horizon ring dense and lets the middle band (and, at extreme altitude,
part of the ring itself) fall back to the flat coloured shell underneath — the same accepted tradeoff the
block-LOD design already made for the identical reason; not a new compromise invented for G3.

### 2.1 Recompute cadence — throttled, not per-frame, dwell-absorbed (V2's own churn discipline)

`want` is recomputed on: (a) every facet crossing (`set_active`, mirrors V2 exactly), and (b) a throttled
timer (`ORBIT_RELIEF_AXIS_MS`, proposed 1000ms) while `emit_axis` drifts without a crossing — because unlike V2
(residency depends on `active_fid` alone, crossing-only), G3's set also depends on the continuously-drifting
`emit_axis`. The O(3456) nearest-to-axis scan itself is cheap (3456 dot products, sub-millisecond — the SAME
cost `GlobalReliefData._next_unbaked`'s linear fallback already pays every `step()` call today) — the throttle
exists to bound MESH CHURN (new tile dispatches / evictions as the boundary of the want-set wobbles), not raw
compute. Facets leaving `want` go through the SAME `EVICT_DWELL_STEPS`-style dwell V2 already uses before actual
eviction, absorbing small want-set boundary jitter without thrashing.

## 3. Build/commit pipeline — REVISED after the perf fix (§1.6): batch-capped incremental commit

```
_want: Dictionary            # fid -> true (recomputed per §2.1)
_want_order: Array           # nearest-priority-first (dispatch priority)
_tiles: Dictionary           # fid -> tile dict (BUILT off-thread — not necessarily uploaded yet)
_committed_tiles: Dictionary  # fid -> true: the SUBSET of _tiles already reflected in the live _mi.mesh
_commit_dirty: bool           # PERSISTENT across step() calls — true while _tiles has diverged from _committed_tiles
_leaving: Dictionary          # fid -> dwell steps remaining (V2's EVICT_DWELL_STEPS pattern, verbatim)
_sn / _s_fid / _s_task / _s_result / _s_mutex     # THE SAME worker-slot-pool shape as FacetSmoothV2
```

Per-`step()` (called from `FacetFarRing._process`, alongside `_smooth_v2.step()`):
1. Reap completed worker slots exactly like V2's `step()` (`WorkerThreadPool.is_task_completed` →
   `wait_for_task_completion` → commit into `_tiles` if still wanted → `_commit_dirty = true`, a persistent
   flag, not a per-call local — a rate-cap-blocked commit is never silently dropped, §3.2).
2. Advance dwell evictions exactly like V2 (an eviction also sets `_commit_dirty = true`).
3. Dispatch new builds into free slots, `_want_order` (priority) order, `WorkerThreadPool.add_task` bound to
   `_build_worker` — **`RELIEF_BUILD_SLOTS`** (= `SMOOTH_BUILD_SLOTS`, sharing V2's `OS.get_processor_count()-1`
   budget reasoning; the two tiers' dispatches interleave on the SAME `WorkerThreadPool`, no double-booking).
4. **Commit, rate-capped**: only if `_commit_dirty` AND `now_ms - _last_commit_ms >= ORBIT_RELIEF_COMMIT_MS`
   (500ms). This is the REV7 "apply-bound warmup mesh-commit fix" lesson applied directly: rate-cap the COMMIT,
   not just the per-tile dispatch.

### 3.2 Commit body — batch-capped, no SurfaceTool (the §1.6 perf fix)

`_commit()`: (a) drop any `_committed_tiles` entry no longer in `_tiles` (an eviction synced into the live
mesh); (b) add up to `ORBIT_RELIEF_COMMIT_TILES`(24) newly-built tiles from `_tiles` not yet in
`_committed_tiles`; (c) `FacetSmoothV2.merge_tiles` over the resulting `_committed_tiles` subset (reused
verbatim — race-free, ascending-fid canonical order; each tile's pos/nrm/col/idx were already fully built
off-thread, §1.6 — commit does zero per-tile recomputation, only concatenation); (d) ONE
`ArrayMesh.add_surface_from_arrays(PRIMITIVE_TRIANGLES, arr)` with `arr[ARRAY_NORMAL]` populated from the
already-real per-tile normals — **no `SurfaceTool`, no `generate_normals()`**. Whole-surface commit only —
**never** `mesh_surface_update_vertex_region`/`_attribute_region` (the ANGLE/WebGL2 uncatchable-crash lesson
`facet_smooth_v2.gd`'s own doc states as non-negotiable; G3 inherits the same constraint). `_commit_dirty` is
cleared only once `_committed_tiles.size() == _tiles.size()` (sufficient because `_committed_tiles` is always a
subset of `_tiles`'s key domain by construction, post-eviction-sync) — so a large want-set fills the LIVE mesh
gradually across many rate-capped commits, never one whole-set upload in a single frame. Measured (headless,
§1.6): a real `ORBIT_RELIEF_COMMIT_TILES`-sized commit costs **<1ms**, vs 367ms for the original whole-384-tile
`SurfaceTool` path.

### 3.1 Why build off-thread even though each tile is "cheap"

A single tile's raw build (§1.2: ~1089 bilerp+height-read+placement+colour-lookup operations, no noise) is
genuinely cheap in isolation — but the RESIDENT COUNT is up to ~200 tiles, and a facet crossing or an axis-drift
recompute can want many of them rebuilt in a short window. 200 tiles × even a conservative 0.3ms/tile main-thread
cost = 60ms in one frame — far over `BG_FRAME_BUDGET_MS` (22ms). Off-thread dispatch, capped to `RELIEF_BUILD_SLOTS`
in flight and drained across many `step()` calls (exactly V2's own model), keeps any single frame's main-thread
cost to "reap ≤ slot-count completions + maybe one rate-capped commit" — bounded regardless of how many tiles
the want-set changes at once. This mirrors V2's own reasoning for building off-thread despite `bake_smooth_tile`
itself being "~ms/facet" per its own doc — the aggregate count, not the per-item cost, is what forces off-thread.

## 4. NEVER-OOM — exact byte math, hard cap

Per tile (mirrors `FacetSmoothV2.tile_bytes`'s accounting: pos/nrm 12B each, col 16B, idx 4B; G3 has no uv/uv2):

| Component | Count | Bytes |
|---|---|---|
| Core verts (33²=1089) × (pos 12 + col 16) | 1089 | 30,492 B |
| Core normals (computed only at commit, on the MERGED mesh — see §1.6; charged here as steady-state resident cost, 12B × 1089) | 1089 | 13,068 B |
| Core indices (32²·2 tris·3) | 6144 | 24,576 B |
| Skirt verts (4 edges × 33, mirrors `FacetSmoothV2._append_skirt`) × (pos+nrm+col=40B) | 132 | 5,280 B |
| Skirt indices (4 edges × 32 × 6) | 768 | 3,072 B |
| **Total / tile** | | **≈ 76,488 B ≈ 74.7 KB** |

**REVISED after team-lead review (§2): `ORBIT_RELIEF_MAX_TILES := 384`** ⇒ **≈ 29.4 MB** resident. Memory is not
the binding constraint here (well inside the 2048 MB ceiling; live vmem in the deployed build runs ≈190 MB) —
384 was chosen so the cap comfortably covers the ~330-facet WHOLE visible cap at the reference altitude
(alt≈1500, θ_h≈36°) without truncating away either the nadir or limb band, per §2's priority law. A hard cap,
not a soft target: `want_set`'s selection (§2) is truncated BEFORE dispatch — the tier can never grow past this
regardless of how large the nominal candidate set is (`G-OR-BYTES` proves this even under an all-3456-facet
synthetic burst). `resident_bytes()` (a ledger accessor, mirrors `GlobalReliefData.resident_bytes()`) sums
`_tiles`' actual `tile_bytes()` for live telemetry/gate verification, not the theoretical cap.

## 5. Flag + gates

```gdscript
## FP_ORBIT_RELIEF ("G3", docs/COSMOS-ORBIT-RELIEF-MESH-DESIGN.md) — real far-terrain 3D relief GEOMETRY from
## orbit: mountains rise, valleys/cliffs drop, visible in silhouette on the limb and on descent. Supersedes the
## rejected shading-only approach (FP_SKIN_RELIEF_SHADE/FP_RELIEF_REEMIT — user verdict: "still looks flat").
## A new FacetOrbitRelief tier (facet_orbit_relief.gd), architecturally a sibling of FacetSmoothV2 (reuses its
## hop_annulus/merge_tiles statics verbatim) but reading heights PURELY from the already-baked GlobalReliefData
## DEM (height_at) — ZERO live worldgen sampling at G3 build time, the structural fix for the shelved S-ladder's
## warmup-convoy failure class. Residency: the ORBIT_RELIEF_MAX_TILES(200, ≈14.6MB) facets nearest the current
## shell_emit_axis, excluding active_fid's own V2 hop≤4 footprint — degrades to a wide nadir-centred cap from
## orbit and a local hop-5..12-ish annulus at the surface as a CONSEQUENCE of the same ranking law, no altitude
## branch. Requires FP_GLOBAL_RELIEF_DATA (reads its heights); independent of FP_SKIN_RELIEF_SHADE/
## FP_RELIEF_REEMIT (neither required nor conflicting). Off ⇒ FacetOrbitRelief never constructed, byte-identical
## (FLAT verify_feature.gd unmoved). Gate: verify_orbit_relief.gd (G-OR).
const FP_ORBIT_RELIEF := false
```

- **G-OR-OFF** — flag off: `FacetFarRing` never constructs a `FacetOrbitRelief` instance; FLAT `verify_feature.gd`
  stays 6042/0.
- **G-OR-DATA-EQ** — for a real baked facet, every one of `build_tile`'s 1089 `pos` nodes' recovered height
  (`(pos[k].length() - r_datum) / RELIEF + SEA_LEVEL`, inverting the placement law) equals
  `GlobalReliefData.height_at(fid,i,j)` exactly (integer quanta) — and equals the tile's own stored `g[k]` (the
  height array `build_tile` also keeps). Falsifier: a hand-perturbed `g[k]` must diverge from `height_at`'s
  value beyond tolerance (proves the assertion actually discriminates, the same falsifiability discipline every
  other gate here uses).
- **G-OR-BYTES** — `tile_bytes(build_tile(fid, rd))` matches the §4 arithmetic for a real tile (± the skirt/
  core split); a synthetic `_tiles` dict with `ORBIT_RELIEF_MAX_TILES` fake entries sums to ≤ the 16 MB cap;
  the residency SELECTION law itself (§2) never returns more than `ORBIT_RELIEF_MAX_TILES` entries even when
  fed a synthetic all-3456-nearest scenario (mirrors `verify_relief_reemit.gd`'s G-RR-BOUNDED falsifier shape).
- **G-OR-WELD** — two adjacent real facets both resident: their shared-edge node positions are bit-equal (≤1e-6·
  r_datum, f32 rounding) — the One-Surface Law proof, same technique `verify_facet_seams.gd`/V2's own gates
  already use. No-protrusion: at the hop-5 (innermost) row, every sunk position's radius is strictly ≤ the
  un-sunk `d*(r_datum+relief)` value (the `_append_inner_sink` guard actually fired, not a no-op); at an
  interior (hop ≥6) node, position matches the un-sunk placement exactly (the guard is scoped to the boundary
  row only, not applied tier-wide — falsifiable: an interior node accidentally sunk would fail this).
- **G-OR-PACE** — a `step()` call with a HOT `frame_ms`/immediately-repeated commit dispatches ≤`RELIEF_BUILD_SLOTS`
  new builds and performs ZERO commits inside the `ORBIT_RELIEF_COMMIT_MS` rate-cap window (mirrors G-RR-BOUNDED's
  "immediate second call processes nothing more" falsifier). Pathological burst: mark the ENTIRE `_want_order`
  (a synthetic 3456-fid want-set) as needing dispatch in one `step()` call ⇒ still only `RELIEF_BUILD_SLOTS`
  tasks get `WorkerThreadPool.add_task`'d that call — never a storm.

## 6. Risks, adjudicated

1. **Commit cost at ~200 tiles / 218K vertices through ONE `generate_normals()` call.** Mitigated by the
   `ORBIT_RELIEF_COMMIT_MS` rate-cap (§3, proposed 500ms — deliberately looser than the 250ms cull/relief-shade
   interval) and by the fact that `generate_normals` is a proven C++ path already exercised at comparable or
   larger scale by the shell's own full-front rebuild (`force_rebuild`/`_rebuild_full`, which already handles
   the WHOLE visible facet set, ≫200 facets, on crossings). Residual risk: the FIRST commit after a large want-
   set change (e.g. a fresh crossing into unexplored territory) could still be a big one-shot cost even
   rate-capped to "once per 500ms" — same class of cost the shell's own crossing rebuild already pays and
   already lives with; not a new risk class, no new mitigation invented beyond reusing the existing rate-cap
   discipline.
2. **No-protrusion beyond the hop-5 boundary sink (§1.5).** Accepted, bounded, disclosed — NOT claimed fixed
   tier-wide. If a live A/B shows visible interior popping-through at close viewing distance (unlikely at
   hop≥6's distance, but not proven impossible), the documented follow-up is extending G2's OWN bake to a
   min-envelope over a small dilated footprint (the SAME law `FP_ENV_ALL` already uses for the shell) — a G2
   change, not a G3 one, and explicitly out of scope for this design (it would re-add per-node sampling cost
   to the ALREADY-paced bake pass, a real tradeoff to weigh separately, not bundled into this fix).
3. **Colour reuse (§1.4) depending on `_col_cache[fid]` already existing.** Mitigated by the shell's own base
   grid already covering the whole visible hemisphere (a strictly larger residency set than G3's own capped
   ~200 tiles) before G3 ever wants a tile for any given fid, plus the neutral-swatch fallback if that
   invariant is ever momentarily violated (never a hard failure, matching the "un-baked = shipped look, never
   black" convention this codebase uses everywhere `_col_cache`/`shade_at`/`far_color_index_of_block` are read).

## Files to touch (implementation, not this design pass)

- **New**: `godot/src/world/facet_orbit_relief.gd` (the tier: `build_tile`, `hop`/nearest-axis residency helper,
  worker-slot-pool `step()`, commit).
- **New**: `godot/src/tools/verify_orbit_relief.gd` (G-OR-OFF/DATA-EQ/BYTES/WELD/PACE).
- `godot/src/cosmos/cube_sphere.gd` — `const FP_ORBIT_RELIEF := false` + `ORBIT_RELIEF_MAX_TILES`/
  `RELIEF_BUILD_SLOTS`/`ORBIT_RELIEF_COMMIT_MS`/`ORBIT_RELIEF_AXIS_MS` consts, doc block, placed near
  `FP_GLOBAL_RELIEF_DATA`/`FP_RELIEF_REEMIT`.
- `godot/src/world/facet_far_ring.gd` — construct/own the `FacetOrbitRelief` instance (mirrors `_smooth_v2`'s
  own construction in `setup_instance`), step it from `_process` alongside `_smooth_v2.step()`, forward
  `set_active`/crossings, expose `shell_emit_axis()` (already public) for its residency law.
- `godot/src/world/world_manager.gd` — thread `_relief_data` (already owned there) into the ring's
  `FacetOrbitRelief` construction (it needs the SAME `GlobalReliefData` instance `FP_SKIN_RELIEF_SHADE` reads,
  via the ring's existing `set_relief_data` plumbing — no new WorldManager-level wiring beyond what already
  exists for G2).
- `docs/COSMOS-FAR-GEOMETRY-PREBAKE-DESIGN.md` — fold this design in as the concrete §G3 (currently an outline).
