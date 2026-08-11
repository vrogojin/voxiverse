# COSMOS SEAM-SLOPE WELD — fall-through at a facet border on a slope: root cause & fix design

Status: ROOT-CAUSED by headless measurement (probe `godot/src/tools/probe_seam_slope.gd`, 2026-08-11,
branch `deploy/cheats-eyeball` incl. #111 FP_SLOPE_MANIFEST_HEAL). Fix design behind `FP_SEAM_SLOPE_WELD`
(byte-off). Task #112.

Symptom (live, user): after #111 healed the facet-interior slope carve, the player still FALLS THROUGH
the terrain **at a facet border while on a slope** (repro region: mountain facet 578, NAV ~13038,8156 —
the low-x corner area of seam slot 2, neighbour facet 579). "Otherwise, looks good."

## 1. What was measured (not theorized)

Probe method: for the same **physical world point** on the shared ridge, compute the analytic floor
independently in facet A=578's frame and facet B=579's frame (each frame's own `slope_run` / corner
targets / datum shift / junction mask — by #111's proven per-facet parity this **is** each facet's
rendered surface), convert both to world **radius**, and diff. Plus a world-space walk transect across
the seam with the game's crossing law (commit at `own_dist < −0.1`, `world_manager.gd:101`).

Stations: 4 near-ridge slope columns of fid 578, seam slot 2 (B=579), cols (13020..13072, 8128..8136)
— the user's repro corner. All firing (`_slope_fires_only`), all with the floor cell **junction-banded**
on both sides (`junc=true` — the analytic floor at the seam rides the FAM_JUNCTION clipped-cube ladder,
see §2.3).

Results (blocks; dR = r_A − r_B at the shared ridge point; "jump" = floor discontinuity at the
crossing-commit instant; "sink" = collision floor below the soil-owner facet's surface inside the
pre-commit hysteresis strip `own_dist ∈ (−0.1, 0)`):

| datum flags                  | seam floor step dR | plain-surface step | commit jump | strip sink |
|------------------------------|--------------------|--------------------|-------------|------------|
| FP_RADIAL_DATUM only         | −1.51 .. −1.68     | −1.51 .. −1.68     | ±1.7        | 0          |
| FP_DATUM_BAKE only           | −1.02 .. −1.03     | −2.02              | ±2.0        | **+1.02**  |
| BOTH on (double-datum)       | **−3.02**          | **−4.02**          | ±3.0        | **+2.02**  |

Fires-flip: at station (13072,8132) facet A carves a slope run while facet B does **not**
(`fires=true/false` at the same physical spot) — a whole-carve discontinuity; this station produced the
worst strip sink in every combo.

Walking **downhill across the seam** the commit jump is a floor **drop** of 1.7–3.0 blocks in one
physics tick, inside the visual wedge between the two facets' junction cut-caps — experienced as
falling through the slope at the border. The strip sink additionally buries the player up to 1–2
blocks below the neighbour's visible slope *before* the commit.

## 2. Root cause — three stacked discontinuities, all seam-band + slope specific

### 2.1 The One-Surface Law does not cover the CARVED surface, and its residual is largest here
Adjacent facet planes are each their own planarized projection — they do **not** share the edge
(`facet_atlas.gd:420-422` states this ∝R disagreement explicitly). FS2/FS2′ compensate per column
(`datum_shift` `facet_atlas.gd:447`, `datum_lift` `:471`), but the compensation is applied to each
frame's own integer heightfield (`g` from each frame's own cell centres) and rounded per frame. On a
2–3 blk/cell mountain slope near a facet **corner** (where planarization mismatch peaks — the measured
step grows monotonically along the seam: −1.51 → −1.68), the residual plain-surface step is ~1.5–1.7
blocks — bigger than anything `FLOOR_WELD_EPS = 2.0` was tuned around, and invisible to every existing
gate because each facet is self-consistent (render == floor per frame, #111).

### 2.2 The sharp-slope carve is computed per-frame and disagrees across the seam
`_corner_targets` / `_slope_fires_only` / `_slope_whole_targets` (`terrain_config.gd:1662,1712,1757`)
sample the 3×3 stencil on the facet's OWN (extrapolated) lattice (`FacetAtlas.cell_dir` extrapolates
past the footprint, `facet_atlas.gd:391`; C++ mirror identical, patch 0007 `cell_dir`). Facet A's edge
column and facet B's edge column are different, tilted, half-cell-offset grids over the same physical
ground, and the whole-block target rounding + the B_MOUNTAINS window predicate quantize independently:
measured `Tw` differ by 1–2 per corner, and at one of four stations the **fires predicate flips**
(A carves, B doesn't → up to a full spread-3 surface disagreement).

### 2.3 The seam band renders/collides as a JUNCTION CUBE LADDER whose top is frame-local
Every straddling cell's modifier is wholesale replaced by FAM_JUNCTION —
render: C++ `junction_modify` (patch 0007 ~:1724-1753, `cc_pack(mat, mj, …)` discards the SLOPE
modifier → `cell_to_arid` carve-sentinel → patch 0004 meshes the **unit cube** clipped by the ridge
planes); analytic: `FacetAtlas.junction_modify` at the window exit (`world_manager.gd:1416`,
`facet_atlas.gd:749-771`). Render and collision agree per frame — but the band floor is the **run-top
`hi`** (the ladder), not the carve plane `lo`, so each side presents `hi_F + S_F` at the seam: measured
hi_A=46 vs hi_B=50 (lattice) at station 1. The carve spread (≤ SLOPE_MAX_SPREAD = 3) is thereby ADDED
on top of §2.1's residual — this is why the border fails specifically **on slopes** while flat seams
stay within the long-accepted ≤1-block step.

### 2.4 (Deploy hazard, to be confirmed live) double-datum
`datum_shift` gates only on FP_RADIAL_DATUM and `datum_lift` only on FP_DATUM_BAKE; **nothing prevents
both** being baked. Both-on is self-consistent per facet (generator shifts content by S *and* the
mesher/physics lift by s ≈ S — render still == floor, every parity gate green) but the seam step
**doubles** to −3/−4 blocks (measured). FS2′ was designed as an alternative to FS2's re-index
(docs/COSMOS-FACET-SEAMS-V2.md §2 — "no re-index"), not an addition. **Action: dump the served flag
set** (remote-bridge flag dump) — if both are on, fixing the deploy flag list alone halves the step.

### Why the player's collision diverges from the eye
Inside the hysteresis strip (`own_dist ∈ (−0.1, 0)`) the active facet still is A while the soil owner
is already B (`maybe_cross_facet` commits one-sided at −0.1, `world_manager.gd:2554+`): `floor_under`
answers with A's frame-local band surface, the eye sees B's — measured sink up to +2.02. At the commit
the answer switches frames instantaneously — measured pop 1.7–3.0 blocks. FP_QUERY_FRAME_GUARD (#90)
only re-expresses the *query point*; FP_FLOOR_SURFACE_WELD only welds *up to the same frame's own*
`surface_y` — neither knows the *neighbour frame's* surface, so neither covers this.

## 3. Fix design — `FP_SEAM_SLOPE_WELD` (byte-off)

Principle: **extend the One-Surface Law to the seam band's walk surface, collision-first.** In the band
(|own_dist| ≤ SEAM_WELD_BAND ≈ 1.5 blocks, the junction-strip width) both facets must answer floor
queries with the SAME frame-independent height: the **max over the two adjacent frames of the
frame-pure, junction-aware band surface**. `max` is symmetric ⇒ A and B agree by construction; the
collision floor becomes continuous across the commit and can never sit below either side's rendered
surface (kills both the strip sink and the commit drop; the residual render step remains a sealed,
walk-over ledge — cosmetics unchanged, matching "otherwise looks good").

### 3.1 The exact height both paths must agree on
For frame F at continuous lattice point (x, z) with column (xi, zi):
```
band_surface_F = S_F(xi,zi) [+ lift_F if FP_DATUM_BAKE] +
    ( hi_F                          if the top cell is junction-banded   # the clipped-cube ladder top
      carve_plane_F(x, z)           elif slope_run fires                 # corner-target plane at the footprint
      smoothed_top_F(xi, zi) )      else                                 # today's g+1 / smoothing top
```
computed with a `GenCtx(facet=F)` worker-path context — pure statics, **no `set_active_facet`**, no
memo churn (this is exactly what the probe's `_frame_floor` does minus the scan). Welded floor:
`floor = max(radial(band_surface_A), radial(band_surface_B))` compared in the ACTIVE frame via
`FacetAtlas.reframe_position64` (f64-exact, already the crossing's own map).

### 3.2 Injection points
* `world_manager.gd floor_under` (~:4178) — after the existing scan returns, and only when
  `FP_SEAM_SLOPE_WELD and FACETED and active_fid >= 0` and min-slot `|own_dist| ≤ SEAM_WELD_BAND`
  (one plane dot per ≤4 slots, same cost class as the FACETED wall test in `blocked`): clamp the
  result **up** to the cross-frame `band_surface` max. Exempt `_edit_columns` (dug shafts win, same
  exemption FP_FLOOR_SURFACE_WELD uses, :4239).
* `blocked` / `surface_y` compose through `floor_under` — no separate change.
* `GroundCollider._emit_column` (`ground_collider.gd:566-596`): band columns emit their prisms at the
  welded band surface (a one-call clamp of `h`/run top; rigid bodies then rest on the same weld).
* NO worldgen/mesher change in v1: `resolve_cell`, patch 0004/0007, the ARID tables, and #111's heal
  are untouched — interior byte-identity is structural (the weld only ever fires inside the band, and
  `max(own, own) == own` when the frames agree).

### 3.3 Follow-up (v2, optional, render-side)
Make the seam **look** welded too: emit the junction cut-cap at the welded height (C++ patch 0004
band clamp) or adopt Option A from the investigation — corner targets sampled at true sphere
directions in the band so the carve itself is frame-pure. Defer until v1's feel is confirmed live.

### 3.4 Deploy action (independent of the flag)
Confirm the served datum flag pair; if both FP_RADIAL_DATUM and FP_DATUM_BAKE are baked, drop one
(keep FP_RADIAL_DATUM — the C++ generator mirror is the better-tested path) — this alone halves every
seam step planet-wide.

## 4. Gate plan — `verify_seam_slope_weld.gd` (from the probe)

OFF (byte-identity): flag false ⇒ `floor_under`/`blocked` bit-identical on: the #111 interior pin
(fid 578 (13038,8155), floor == 68 == g+1), a 64-column facet-interior sweep, and the M2 transect
samples (assert equality against a recorded flag-off pass in the same run: compute with the weld path
short-circuited — the flag const — and compare).

ON (the weld contract, on the measured stations of fid 578 slot 2 + the fires-flip station):
* G-SSW-AGREE — for ridge stations: `band_surface` computed from frame A == from frame B after
  reframe, within 1e-3 (the `max` symmetry).
* G-SSW-CONT — M2 transect (both directions): max floor discontinuity per 0.2-block step ≤ 0.6
  (STEP_MAX), including the commit instant. (Measured today: 3.02.)
* G-SSW-NOSINK — strip samples (`own_dist ∈ (−0.1, 0)`): active-frame floor ≥ owner-frame band
  surface − 0.1. (Measured today: deficit up to 2.02.)
* G-SSW-INTERIOR — the #111 pin column and a 32-column interior sweep: floor unchanged vs flag-off
  (no regression of the slope-heal).
* G-SSW-EDIT — a dug shaft inside the band is exempt (mirrors verify_floor_weld's shaft arm).

## 5. Probe reproduction

```
sed -i 's/const FACETED := false/const FACETED := true/; s/const FP_RADIAL_DATUM := false/const FP_RADIAL_DATUM := true/; s/const FP_ANALYTIC_COL_MEMO := false/const FP_ANALYTIC_COL_MEMO := true/; s/const FP_QUERY_FRAME_GUARD := false/const FP_QUERY_FRAME_GUARD := true/; s/const FP_FLOOR_SURFACE_WELD := false/const FP_FLOOR_SURFACE_WELD := true/' godot/src/cosmos/cube_sphere.gd
docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/probe_seam_slope.gd
git checkout godot/src/cosmos/cube_sphere.gd
```
(toggle FP_DATUM_BAKE/FP_RADIAL_DATUM per §1's table; the probe prints per-station g/S/lift/Tw/fires/
junction and the M2 transect with per-step jumps.)
