# COSMOS-FACETED-IMPL — building the faceted planet: FP1→FP5 implementation spec

Status: IMPLEMENTATION SPEC (Fable, 2026-07-12). Parent:
`docs/COSMOS-FACETED-PLANET-STUDY.md` (the feasibility study — measured numbers,
staged plan §11, reuse map §8). FP0 (the visual spike, `faceted_spike.gd` +
`cosmos_facet.gd` + `verify_cosmos_facet.gd`) is shipped and user-approved. This
document turns study stages FP1–FP5 into directly implementable milestones: exact
math, exact file:function touch-points, gates, sizes, and per-stage risk. Where the
study says *what*, this says *how, precisely*.

Render model context: `docs/COSMOS-REAL-GEOMETRY-STUDY.md` (R2: static rigid
geometry + camera; reused here **rooted at the facet**, §5.2 below).

---

## 0. The two load-bearing invariants

**I1 — FLAT_WORLD byte-identity.** Every faceted hook is behind the new
`CubeSphere.FACETED` toggle (default `false`). With it off, no new branch is ever
taken; the shipped flat game is bit-for-bit unchanged. Faceted mode runs **with
`FLAT_WORLD = true`** — the whole smooth-warp stack (chart, M_win, fold, D4, bend,
M5, M5c) stays dormant because every one of its hooks keys on
`not CubeSphere.FLAT_WORLD`. There is no interaction surface between the two
systems: FACETED never creates a `CosmosChart`, so `WorldManager._chart == null`
and every `col_*` wrapper takes its flat branch.

**I2 — a facet IS the flat world.** The single substitution faceted mode makes is
the **profile source**: `TerrainConfig.column_profile(x, z, pcache)`
(`terrain_config.gd:492`) is the one choke point through which the module worker,
the analytic physics (`height_at` → `analytic_column_profile`), the GroundCollider
light-queries (`surface_modifier`/`slope_run_of`/`snow_stack_at` — all profile
stencils), TreeGen's biome gate, snow, and the sim layer resolve a column. Faceted
mode adds one branch there that computes the profile from the facet cell's true
sphere direction d̂ instead of 2D noise. Everything downstream —
`resolve_cell`, smoothing/slope stencils (they read neighbours as plain `x±1`
through the same choke), trees, ore/strata/bedrock hashes, sea fill, snow,
break/place/collapse, GroundCollider, the DDA, both meshers, inventory, HUDs — is
the **shipped flat-engine code, untouched**. No fold, no M_win, no D4, no wedge,
no `GenCtx.face` semantics: a facet's lattice has no seams inside it.

Consequences worth stating because they delete work: `WorldManager.cell_value_at`
(`world_manager.gd:265`) needs (almost) no change — its `_chart == null` path calls
`TerrainConfig.generated_cell(x,y,z)` which calls `column_profile` which routes.
`generated_cell` itself is untouched. The fallback mesher, GroundCollider,
PerVoxelEnvironment, SnowfallSystem, StructuralSolver: untouched. The module
worker needs ~5 lines (a frozen `gen_facet`, §4.4).

---

## 1. Toggles, constants, and the demo body

### 1.1 New toggles (all in `godot/src/cosmos/cube_sphere.gd`, next to `FLAT_WORLD`)

```gdscript
const FACETED := false        # FP1+: the faceted-planet engine. REQUIRES FLAT_WORLD == true.
const FACET_TWIST := false    # FP5: optimized twist-field grid orientation (naive = cube-face frames)
```

Startup assert (in `WorldManager._ready`, dev builds): `assert(not CubeSphere.FACETED
or CubeSphere.FLAT_WORLD)`. `FACETED_SPIKE` (the FP0 demo, currently `true` on this
branch) must be set back to `false` for FP1; the three flags are mutually
exclusive in intent — `FACETED_SPIKE` wins in `main.gd` (it returns early), then
`FACETED`, then the shipped game.

### 1.2 The atlas config (new file `godot/src/cosmos/facet_atlas.gd`, see §2)

```gdscript
const K := 8                     # faceting resolution: 6·K² facets (earth target 16; FP1 demo 8)
const R_BLOCKS := 1024.0         # planet radius in blocks (earth target 6371.0; FP1 demo 1024)
const MARGIN_CELLS := 8          # lattice cells kept beyond the facet polygon (streaming slack)
const STRIP_CELLS := 2           # per-side seam strip width (study §6; used FP2+)
const SPAWN_EDGE_MIN := 48       # spawn scan stays ≥ this many cells from the facet boundary
```

**FP1 demo body: K = 8, R = 1024.** Mid-face facet ≈ R·π/(2K) ≈ **201 blocks**
across (smallest, at the corner quadrants, ≈ 143). Ridge turns ≈ 10.4–11.8°
(chunky and clearly faceted — good for validating), sag ≈ 3.3 blocks, seam steps
p50 ≈ 1.6 / max ≈ 5.7 (earth-k8 numbers × 1024/6371). One facet ≈ a 200×200 flat
world → streams in seconds. The earth deploy later flips two constants (K=16,
R=6371) — nothing else in the design depends on them. Worldgen samples noise at
`d̂·R_BLOCKS` (§3.1), so the demo body has proportionally compressed features;
that is fine and disclosed.

Facet id: `fid = (face·K + a)·K + b`, `face ∈ [0,6)`, `(a,b) ∈ [0,K)²`.
6K² = 384 facets at K=8, 1536 at K=16.

---

## 2. The FacetAtlas kernel — exact math

New file `godot/src/cosmos/facet_atlas.gd` (`class_name FacetAtlas extends
RefCounted`, all-static, mirroring `CubeSphere`'s discipline). It extends the
shipped `CosmosFacet` math (`cosmos_facet.gd` — `vertex_dir`, `facet_corners`,
`facet_normal`, the gate helpers stay as-is and are reused). **All kernel math in
f64** — GDScript scalar floats are 64-bit; never route a direction or an anchor
through `Vector3` (f32) before the final placement transform. This is the same
DVec3 discipline `cube_sphere.gd` already enforces.

### 2.1 Planarization (study §3.1 — FP0 skipped this; FP1 must not)

FP0's `facet_pos_at` bilinearly interpolates the 4 true-sphere corners, which are
**not coplanar** (sag ≤ ~3.3 blocks at demo scale, 6 at earth k=16) — a bilinear
patch of non-coplanar points is a hyperbolic paraboloid, not a plane. The engine
facet must be exactly planar. For facet `fid` with true corners
`c0..c3 = vertex_dir(face, a+{0,1,1,0}, b+{0,0,1,1}, K) · R` (f64, CCW):

```
m  = (c0 + c1 + c2 + c3) / 4                      # centroid
n̂  = normalize( (c2 − c0) × (c3 − c1) )           # mean-plane normal (cross of diagonals)
if n̂ · m < 0: n̂ = −n̂                              # orient OUTWARD (radial side)
ci' = ci − ((ci − m) · n̂) n̂                        # corners projected onto the plane
```

The cross-of-diagonals plane through the centroid is the symmetric best fit: the
four corner deviations come in equal-magnitude ± pairs (≤ sag/2 each). Gate
G-A2 asserts `|((ci − m)·n̂)| ≤ sag_max/2 + ε` and that `n̂` deviates from
`facet_normal` (the FP0 centre radial) by < 1°.

### 2.2 The facet frame — the rigid Transform3D

```
ê_u = normalize(c1' − c0')          # local +X: the grid i direction, in-plane
ŷ   = n̂                             # local +Y: up = the facet plane normal
ê_w = ê_u × n̂                        # local +Z: FORCED right-handed (X × Y = Z)
```

`Basis(ê_u, n̂, ê_u × n̂)` is orthonormal with det = +1 **by construction** — never
derive ê_w from the c3 edge (per-face `FACE_U/FACE_V` handedness varies; a det = −1
basis breaks winding and godot_voxel). The grid j direction may thus point along
**−ê_w** on some faces; this is invisible (see §3.2: sampling and placement share
one map, so no mirror is observable) — the only artifact is which local-z sign the
facet polygon occupies, and the polygon is computed, not assumed (§2.4).

FP5's twist field (§8) later inserts an in-plane rotation:
`ê_u ← R(n̂, φ_fid)·ê_u` before the cross product. FP1–FP4: `φ = 0`.

The lattice→planet map (f64; the ONE map both sampling and placement use):

```
W_fid(x, y, z) = c0' + (x − O.x)·ê_u + y·n̂ + (z − O.z)·ê_w        (blocks)
```

and its f32 `Transform3D` `T_fid = Transform3D(Basis(ê_u, n̂, ê_w), c0' − O.x·ê_u − O.z·ê_w)`
for node placement (FP2+; FP1 renders in the local frame and never needs it).
Local y is the altitude channel: **y = r, the facet plane is the r = 0 datum**
(sea level = `SEA_LEVEL = 0` sits at the plane, exactly as window-y = r in the
curved engine). The plane is a chord — its interior is up to sag-inside the true
sphere; that flattening IS the design (the curvature re-housed at the seams as
the datum step).

### 2.3 The decorrelation offset O (per facet, deterministic)

Without it, every facet's position-hashed content (bedrock dither, ore/strata
lattices, tree hashes, banding, podzol — everything `_hash01_3d` and the 2D
detail noises key on `(x, z)`) would repeat at identical local coordinates on all
6K² facets. Fix: each facet's lattice window lives at a unique offset in the
abstract flat plane — a pure translation, decided **now** because it defines the
facet cell coordinate system that edit keys and persistence will use forever:

```
O.x = int(floor(TerrainConfig._hash01_3d(fid, 11, 0, 751) · 65536.0)) − 32768
O.z = int(floor(TerrainConfig._hash01_3d(fid, 23, 0, 757) · 65536.0)) − 32768
```

(| O | ≤ 32768: at coord ~33k, f32 position ULP ≈ 0.002 blocks — safely inside
player-physics tolerance; do NOT widen this range.) The facet's lattice domain is
the axis-aligned cell bbox of the local polygon (§2.4) **translated by O**;
`W_fid` (§2.2) subtracts O so lattice cell `(O.x, ·, O.z)` sits at the planarized
anchor corner `c0'`. Salts 751/757 join the `_SALT_*` table in
`terrain_config.gd:190`.

### 2.4 The facet polygon and lattice domain

Local 2D corners: `qi = ((ci' − c0')·ê_u, (ci' − c0')·ê_w)` (f64 pairs; q0 =
(0,0)). Lattice domain (ints):

```
dom_min = Vector2i(O.x + floor(min qi.x) − MARGIN_CELLS, O.z + floor(min qi.y) − MARGIN_CELLS)
dom_max = Vector2i(O.x + ceil(max qi.x) + MARGIN_CELLS, O.z + ceil(max qi.y) + MARGIN_CELLS)
```

`in_polygon(fid, x, z, grow)` = point `((x−O.x)+0.5, (z−O.z)+0.5)` inside the
quad q0..q3 dilated by `grow` cells (4 half-plane dots; the quad is convex).
FP1 does not mask (§4.6); FP2+ use `in_domain = in_polygon(fid, x, z,
STRIP_CELLS)`.

### 2.5 Seams, welded rings, ridge planes (built FP2)

For each of the 12K² seams (facet pair A,B sharing a grid edge; adjacency is by
shared grid-vertex pairs — reuse `CubeSphere.edge_remap` inside the builder only,
never at runtime): the two facets planarize the same true edge endpoints
differently. The **welded ring** is their average, a straight f64 segment:

```
r0 = (proj_A(e0) + proj_B(e0)) / 2 ;  r1 = (proj_A(e1) + proj_B(e1)) / 2
```

(`proj_X` = projection onto facet X's plane, §2.1; `e0,e1` = the shared true
corners). The **ridge plane** (the ownership boundary, study §6.3):

```
t̂ = normalize(r1 − r0);  ĥ = normalize(n̂_A + n̂_B);  m̂ = normalize(t̂ × ĥ)
if m̂ · (m_A − r0) < 0: m̂ = −m̂            # orient toward A's centroid
own_A(p) := m̂ · (p − r0) ≥ 0               # one plane test; B is the strict complement
```

Per-seam atlas record: `(fid_A, fid_B, r0, r1, m̂, Δ_AB)` where
`Δ_AB = T_B⁻¹ · T_A` (composed in f64, stored as Transform3D) — the FP3 crossing
transform. Dihedral θ = acos(n̂_A·n̂_B).

### 2.6 Storage, warm-up, purity

Atlas data = per-facet `(c0', ê_u, n̂, ê_w, O, q0..q3, dom_min/max)` + per-seam
records: ~30 f64 per facet ≈ **90 KB at K=8, 380 KB at K=16 + seams ≈ same
again** — trivially inside never-OOM (< 1 MB total, one-shot, no per-voxel data).
Stored as PackedFloat64Array columns indexed by fid.

`FacetAtlas.warm_up()` builds everything **once on the main thread**;
`module_world.setup()` calls it right after `TerrainConfig.warm_up()`
(`module_world.gd:204`), and `WorldManager._ready` calls it in the FACETED branch
(fallback/headless path). After warm-up the arrays are immutable — the exact
read-only-after-freeze discipline the noise singletons already use (WGC §7.4), so
voxel workers may read them. There is no mutable static in the facet path at all;
generation is a pure function of `(SEED, fid, x, z)` — *stronger* than the curved
frozen-epoch contract (no window state exists).

### 2.7 Edit keys and region keys (used FP3+; defined now, frozen forever)

```
lx = x − dom_min.x ;  lz = z − dom_min.z          # 0 ≤ lx,lz < 4096 (12 bits; earth k=16 facets ≈ 700)
key = (fid << 36) | (lx << 24) | (lz << 12) | (y + 2048)      # y ∈ [−2048, 2047]; fid < 2^27
```

FP1/FP2 keep plain `Vector3i` keys (single facet, `_chart == null` path — already
the case). FP3 switches `WorldManager._edit_key` to this packing. Region key for
per-facet persistence: `(fid << 24) | (region_x << 12) | region_z` over 32³
regions of the facet window.

---

## 3. The terrain adapter — facet cell → real planet terrain

### 3.1 `profile_at_dir` — factor the sphere profile out of the curved path

`TerrainConfig._curved_profile_base` (`terrain_config.gd:686`) already computes
the full sphere-domain profile from a direction; it just derives that direction
from a lattice cell. **Extract the direction-parameterized body** (pure
refactor, byte-identical for the curved build):

```gdscript
## The sphere-domain column profile at unit direction d (f64 scalars), radius rr blocks.
## Body = _curved_profile_base after LatticeNav.dir_of: noise3d at d·rr, latitude climate,
## mountain factor, _height_c3, _biome. Pure (SEED + frozen noises only).
static func profile_at_dir(dx: float, dy: float, dz: float, rr: float) -> Vector4
```

`_curved_profile_base` becomes `return profile_at_dir(d.x, d.y, d.z,
float(CubeSphere.radius_for(CubeSphere.HOME_BODY)))`. Gate G-F1c re-runs the
curved verifies to pin the extraction.

The faceted path samples **continuous d̂** — no `dir_to_face_cell`, no n-grid
snapping (unlike FP0's `_terrain()` helper). This kills the aliasing class
(duplicated/skipped n-grid columns → plateau pairs, doubled trees) before it
exists, and drops the last dependency on `n_for` from the near path.

### 3.2 The d̂ adapter (THE formula)

```
d̂(fid, x, z) = normalize_f64( W_fid(x + 0.5, 0, z + 0.5) )
             = normalize_f64( c0' + (x − O.x + 0.5)·ê_u + (z − O.z + 0.5)·ê_w )
```

implemented as `FacetAtlas.cell_dir(fid, x, z) -> CubeSphere.DVec3` (scalar f64
component math, exactly like `CosmosFacet.vertex_dir`). Column d̂ is taken at the
**plane point** (y = 0) — a facet column is straight along n̂, so all its cells
share one d̂; y enters only as r. Because sampling (this) and placement (§2.2's
`W_fid`/`T_fid`) share the single map, generation and geometry can never disagree
— and the frame-handedness choice of §2.2 is unobservable.

Facet profile:

```gdscript
static func facet_profile(fid: int, x: int, z: int) -> Vector4:
    var d := FacetAtlas.cell_dir(fid, x, z)
    return profile_at_dir(d.x, d.y, d.z, FacetAtlas.R_BLOCKS)
```

Terrain continuity across a future seam is automatic: both facets' strips sample
the same d̂ field (study §6.4) — verified by gate G-F1f.

### 3.3 Wiring into the choke point (`terrain_config.gd`)

1. `GenCtx` (line 563): add `var facet: int = -1`; `_init(p_face, p_facet := -1)`.
2. **`column_profile(x, z, pcache)` (line 492)** — insert the faceted branch
   before the `not FLAT_WORLD` branch:

   ```gdscript
   if CubeSphere.FACETED:
       var fid := _active_facet
       if pcache is GenCtx and pcache.facet >= 0:
           fid = pcache.facet                       # worker: frozen per-generator snapshot
       # memo key: GenCtx → Vector3i(fid, x, z); Dictionary/null → Vector2i (facet fixed per epoch)
       prof = facet_profile(fid, x, z)
   ```
3. `height_at` (line 433): add `if CubeSphere.FACETED: return
   int(analytic_column_profile(x, z).x)` (same shape as the curved branch —
   routes through the shared memo). `analytic_column_profile` (line 792) gains a
   FACETED branch acquiring `_acquire_ctx(_active_face)` with `facet =
   _active_facet` (extend `_acquire_ctx` to stamp `.facet` each call).
4. New statics, mirroring `_active_face`'s discipline exactly:
   `static var _active_facet := -1` + `set_active_facet(fid)` (main-thread-only;
   clears `_shape_memo` and the analytic memo on change — the FP3 crossing calls
   it; FP1 sets it once at startup).
5. `find_spawn` (line 1970): faceted branch → `FacetAtlas.spawn_column()` — same
   radius/angle outward scan, centred on the spawn facet's window centre, radius
   capped at `min_half_extent − SPAWN_EDGE_MIN`, same acceptance predicate
   (`g > SEA_LEVEL + 1`, biome ∈ {plains, forest}). Spawn facet selection (atlas
   warm-up, deterministic): the first fid in id order with `|d̂_centre.z| < 0.5`
   (temperate latitude) whose centre profile passes the same predicate.

Nothing else in `terrain_config.gd` changes. `generated_cell`, `resolve_cell`,
trees, snow, slopes, smoothing: untouched (I2).

---

## 4. FP1 — one playable facet (~1 milestone)

**Definition:** the game boots with `FACETED = true` into a single facet's local
frame: real d̂-sampled planet terrain on a perfectly flat square lattice, stock
gravity −Y, stock Player, both render paths, break/place/collapse, hotbar,
thermometer, snowfall — the flat game, running on facet `spawn_facet()` of the
K=8/R=1024 demo body. No sphere context yet (sky/fog as shipped), no seams, no
neighbour facets. Terrain **extends past the facet polygon** (the lattice keeps
generating; beyond the ridge line it renders the neighbour's terrain flattened
into this facet's plane — geometrically wrong out there, documented, masked in
FP2). Spawn is ≥ 48 cells from every edge so the MVP play area is honest.

### 4.1 Files touched (complete list)

| File | Change | ~size |
|---|---|---|
| `godot/src/cosmos/facet_atlas.gd` | **NEW**: §1.2 consts, §2.1–2.4 + §2.6 (frames, offsets, polygons, warm_up, `cell_dir`, `spawn_column`, `spawn_facet`) — seams/keys deferred to FP2/FP3 | ~250 |
| `godot/src/cosmos/cube_sphere.gd` | `FACETED` + `FACET_TWIST` consts; `FACETED_SPIKE := false` | ~6 |
| `godot/src/world/terrain_config.gd` | §3.1 `profile_at_dir` extraction; §3.3 items 1–5 | ~80 |
| `godot/src/world/voxel_module/module_world.gd` | §4.4: `FacetAtlas.warm_up()` in `setup()`; generator `gen_facet`; loader sets it | ~20 |
| `godot/src/world/world_manager.gd` | `_ready`: FACETED assert + `FacetAtlas.warm_up()` (fallback/headless path) + `set_active_facet(FacetAtlas.spawn_facet())`; far layer gated `FarTerrain.ENABLED and not CubeSphere.FACETED` (§4.5) | ~12 |
| `godot/src/main.gd` | nothing structural — the normal build path already works; only the FACETED_SPIKE flag flip. (`find_spawn`/`_find_flat` route via §3.3 item 5.) | ~2 |
| `godot/src/tools/verify_faceted.gd` | **NEW**: the FP1 gate suite (§4.7) | ~300 |

### 4.2 The facet frame in play

FP1 renders **in the facet local frame**: world coords = lattice coords, the
VoxelTerrain node at identity (exactly like flat — and godot_voxel must never be
rotated, `module_world.gd:332`). `T_fid` is not used at runtime in FP1; it is
built and gate-checked so FP2 can trust it. Gravity: `player.gd` untouched —
`velocity.y -= gravity·δ` at line 290 IS facet gravity (−n̂ in planet terms,
≤ 4.0° from true radial at facet corners; study §7.1). The player spawns at
`(col.x + 0.5, surface_y + 0.1, col.y + 0.5)` with coords ~O ± 100 — the
`main.gd:39` spawn code verbatim.

### 4.3 Analytic path

Fully automatic through §3.3: `cell_value_at` → `generated_cell` →
`column_profile` (faceted branch) → the flat pipeline. `blocked` / `floor_under`
/ `surface_y` / `aimed_voxel` / GroundCollider / collapse: zero changes.

### 4.4 Module worker path (`module_world.gd`)

The generator source (`_make_generator`, line 1590) gains one frozen var and one
branch — the `gen_face` pattern verbatim:

```gdscript
var gen_facet := -1        # FACETED: this epoch's frozen facet id (loader-set; −1 = flat)
# in _generate_block, replacing `pcache = {}` in the flat branch:
if gen_facet >= 0:
    pcache = TerrainConfig.GenCtx.new(0, gen_facet)
else:
    pcache = {}
```

The rest of the flat loop is byte-identical — `column_profile(ox+x, oz+z, pcache)`
routes through the faceted branch reading `ctx.facet` (a frozen per-generator
value; the worker never touches `_active_facet`). Loader (in `setup()` and later
`set_facet`): `if CubeSphere.FACETED: generator.set("gen_facet",
TerrainConfig.active_facet())`. `flat_world` stays `true` in the snapshot (no
fold path). The fallback `ChunkStreamer`/`ChunkMesher` route through WM/
TerrainConfig and need nothing.

### 4.5 Far layer

`FarTerrain` OFF in faceted mode (WM `_ready` gate): as-is it would render the
d̂-sampled heightmap flattened into the local plane out to 3 km — plausible
nearby, increasingly wrong far out. FP2 replaces it with the facet far ring
(§5.2). FP1 keeps the shipped 256-block near field + fog (`main.gd`'s
non-far fog branch triggers automatically since `FarTerrain.ENABLED` is checked —
gate that check too: `FarTerrain.ENABLED and not CubeSphere.FACETED` in
`main.gd:134`).

### 4.6 Explicit FP1 non-goals

No polygon mask (terrain continues past ridge lines), no ridge clamps, no seam
strips, no neighbour/far rendering, no crossing, no `(fid, cell)` edit keys
(single facet ⇒ `Vector3i` keys are already facet-local), no persistence changes.

### 4.7 FP1 gates (`verify_faceted.gd`, headless, exit 0/1)

- **G-F1a — purity/determinism:** for a 3-facet sample (spawn facet + a
  corner-quadrant facet + a face-0 facet), `generated_cell` over a 32³ box equals
  itself on a second pass, equals the worker-style path (fresh
  `GenCtx(0, fid)` per block, mirroring `_generate_block`), and equals a run
  after memo clears. Byte-equality (packed ints).
- **G-F1b — the flat-engine invariant suite on a facet:** run `verify_feature`'s
  invariant families (stackup, mass ordering, inventory, live
  break/place/collapse via a headless WorldManager) with `FACETED = true`.
  Height-pinned flat assertions are re-based on faceted spawn-column values, not
  skipped.
- **G-F1c — byte-identity off-toggle:** `FACETED = false` → full `verify_feature`
  green, plus the curved suite (`verify_cosmos_m1/m2/seam`) green under
  `FLAT_WORLD = false` builds — pins the §3.1 extraction.
- **G-F1d — spawn margin:** spawn column ≥ `SPAWN_EDGE_MIN − 16 = 32` cells from
  every facet polygon edge (covers `_find_flat`'s ±16 wander), on the demo body
  AND on earth (K=16, R=6371) parameters.
- **G-F1e — frame math:** for every facet: basis orthonormal, det = +1, corners'
  plane deviation ≤ sag/2, `n̂·centre_radial ≥ cos 1°`, `W_fid` round-trips
  (`T_fid⁻¹·W_fid(x,y,z) ≈ (x−O.x, y, z−O.z)` to 1e-4), Σ corner defects =
  720.00° (reuse `verify_cosmos_facet` at the engine K).
- **G-F1f — seam-side profile continuity:** for 100 random seam samples, the two
  facets' profiles at the two cells straddling the ridge line agree in `g` to
  ≤ 2 blocks and in biome (phase < 1 block + the datum step is geometric, not
  terrain — this pins the d̂ adapter, not the seam design).

**#1 FP1 risk — f32 leakage into the d̂ path.** One `Vector3` in `cell_dir` or a
`facet_corners()` (f32) reuse where `vertex_dir` (f64) is needed breaks
worker==analytic byte-identity intermittently at large coords. Mitigation: the
kernel API takes/returns scalars + DVec3 only; G-F1a is the tripwire.

---

## 5. FP2 — neighbour ring + far ring + the visual barrier (~1 milestone)

**Definition:** the facet is placed in its planet context: the 8 edge/corner
neighbour facets render as static mid-LOD meshes, the rest of the planet as a
far ring, seams as welded-ring strip meshes ("ridge rock" barrier). Generation
masks to the facet domain; an invisible wall clamps the player at ridge planes.
Still one playable facet.

### 5.1 Atlas: seams (§2.5)

Extend `facet_atlas.gd` with the seam table + `in_domain`/`in_polygon` (§2.4) and
per-facet neighbour lists. Gates: **weld closure** — for every seam, the two
facets' planarized edge endpoints are each ≤ sag/2 from the ring, and around
every grid vertex the incident rings' endpoints coincide (one shared point) —
watertight by construction; Σ defects unchanged.

### 5.2 Rendering: the facet-rooted R2 model

**The render root is the active facet's local frame; the planet is placed around
it** — the inverse of R2's camera-motion formulation, chosen because godot_voxel
cannot be rotated (det==0, `module_world.gd:332`) and physics already lives here.
Everything else is static geometry under rigid transforms (the R2 principle —
nothing chart-shaped near the GPU, zero custom shaders):

- New `godot/src/world/facet_far_ring.gd` (~400 lines; the far analogue —
  `FarPalette` colours, `FAR_MAX_*`-style caps, `make_material()` reuse):
  - **Neighbour meshes** (8): heightmap grids at `NEIGH_PITCH := 4` blocks over
    each neighbour's polygon, heights/colours from `facet_profile` (the same
    adapter — near/neighbour agree by construction), verts **terminating on the
    welded rings**, placed at `T_active⁻¹ · T_neigh` (f64-composed, f32-stored;
    origins ≤ ~2 facet sizes → exact).
  - **Far ring**: the remaining planet as one FP0-style mesh (all facets,
    `CELLS≈6` per facet, ~28k tris at K=8), placed at `T_active⁻¹` (origin
    magnitude ≈ R — f32-safe at 6371), minus the active facet + neighbours'
    footprint. Rebuilt only on crossing (FP3), never per-frame.
  - **Strip meshes**: per visible seam, a prism strip on the welded ring
    (width ≈ 2·STRIP_CELLS, ridge-rock material) covering the near-field mask
    edge and the neighbour-mesh joins.
- `WorldManager._ready`: FACETED branch instantiates `FacetFarRing` instead of
  `FarTerrain`; `update_streaming` forwards `update_center`.
- Memory/draw ceilings (never-OOM): neighbour meshes ≤ 8 × ~5k tris, far ring ≤
  `FAR_MAX_TRIS`, strips ≤ 4·K visible — all capped at build, trim
  outermost-first like `far_terrain.gd:61`.

### 5.3 The generation mask + the wall

- `TerrainConfig` faceted cell entry: in the faceted branch of `column_profile`
  do NOT mask (profiles are legitimately queried outside for neighbour meshes);
  mask at the **cell** level: `WorldManager.cell_value_at`'s `_chart == null`
  path becomes, under FACETED, `if not FacetAtlas.in_domain(active, x, z):
  return AIR` before `generated_cell` (also mirrored in the generator worker's
  column loop: out-of-domain column → skip writes, leave 0). Masking at cell
  level (not profile) avoids the sea-fill-over-void artifact.
- The wall: `WorldManager.blocked()` (line 1717) FACETED prelude — for each seam
  of the active facet, `m̂·(p − r0) < WALL_EPS` (crossing outward) → blocked.
  One-plane tests against ≤ 4 seams; `ceiling_scan`/`floor_under` untouched
  (domain interior). Player never reaches the mask void.

### 5.4 FP2 gates

Weld closure (§5.1); near/neighbour join: for sample columns at the mask edge,
near-field surface height == neighbour-mesh height at the same d̂ ± 1 block;
FPS parity on the live web build (PerfHUD; draw calls ≤ flat + 12); never-OOM
budget delta < 5 MB; G-F1a/b/c re-run green.

**#1 FP2 risk — the mask edge reads as a cliff of exposed voxel side-faces**
under the strip mesh (the near field just *stops* at the domain edge). The strip
prism must be tall/wide enough to cover the tallest exposed profile near old
corners; budget a fit-and-finish pass, and accept FP2 as "visual barrier"
quality, not seam-final (that is FP4).

---

## 6. FP3 — the crossing handoff (~1 milestone)

**Definition:** walking to a ridge re-frames the player into the neighbour facet
and restreams the near field there (M4 pattern); edits get `(fid, cell)` keys;
debris re-frames; the wall is replaced by the handoff. Cross-and-return is
byte-identical.

### 6.1 The handoff (`world_manager.gd`, pattern of `maybe_flip_home_face`:1211)

`maybe_cross_facet(player_pos)` called from `update_streaming`: for the active
facet's seams, signed distance `s = m̂·(p − r0)`; crossing when `s < −HYST`
(HYST := 0.75 blocks, one-sided hysteresis so jitter can't double-fire). Then:

1. `Δ := seam.Δ_AB` (A = old active; precomposed f64, §2.5). Apply **once**:
   `player.global_position = Δ * position`; `player.velocity = Δ.basis *
   velocity`; yaw from `Δ.basis` (the #71 flip-compensation pattern — new
   `Player.apply_reframe(delta: Transform3D)` ~15 lines: position full
   transform, velocity/look basis-only).
2. `TerrainConfig.set_active_facet(B)` (memo + shape-memo clear, §3.3.4).
3. Module: new `module_world.set_facet(fid, old_wrapper_pos)` — sibling of
   `set_home_face` (line 1138): install a fresh generator with `gen_facet = B`,
   then `restream(old_wrapper_pos)` (line 1149) — the shipped M4 machinery:
   near cover, view-distance ramp, `_flip_settling` re-mirror of edits
   (`update_streaming`:237 works verbatim — rename-audit its comments only).
   Fallback path: `_restream()` (line 1338).
4. `FacetFarRing.set_active(B)`: re-place neighbour/far/strip nodes by their new
   relative transforms (rigid re-parent math only; the far-ring mesh rebuild for
   the changed exclusion footprint is deferred/amortized).
5. Debris: iterate `VoxelBody` children (the `m5c_glue_bodies` walk, line 1062);
   any body past a ridge plane gets the same one-shot `Δ` (position + linear/
   angular velocity basis). Enumerable two-frame inventory, R2 discipline.
6. Camera: physics snaps; render eases — a transient counter-rotation
   `R(t̂_B, (1−α)·θ_dihedral)` applied via the existing
   `Player.set_render_camera` (line 147), α: 0→1 over 0.3 s. At 5–11° this
   reads as cresting a fold.

Prefetch: when `s < 64` blocks for any seam, the neighbour's meshes are already
resident (FP2) — additionally warm B's spawn-side data blocks if profiling shows
first-cross hitches (module `preload_area` if available; else accept the ramp).

### 6.2 Edit keys

`WorldManager._edit_key` (line 313) FACETED branch → §2.7 packing with
`fid = facet_of_column(x, z)` — the **owner** facet (domain test; strips resolve
by the ridge-plane sign, so ownership is total and unique). `_edits`,
`placed_cells`, save/load bundles inherit int keys exactly as the curved 43-bit
path does today (`save_edits`/`load_edits` are key-agnostic). Region keys §2.7.

### 6.3 DDA / interaction at ridges

`aimed_voxel` needs no ray transform in FP3: beyond the ridge the active lattice
is masked AIR (FP2), so rays simply exit; cross-facet interaction within reach
(≤ 8 blocks past a 4-cell strip = a ~4-block window) is explicitly deferred to
FP4+ (the strip is no-build anyway; document as a known scope cut).

### 6.4 FP3 gates

- **Cross-and-return byte-identity** (headless): drive a synthetic position
  A→B→A across two different seams; assert every sampled cell value, every edit
  (placed both sides pre-cross), and the player's A-frame position round-trip
  exactly (position to 1e-3 — Δ·Δ⁻¹ in f64).
- **No-hitch live crossing**: walk + sprint across a seam on the deployed web
  build; PerfHUD max frame ≤ 100 ms during the restream window, near cover
  visible throughout (M4's gate re-derived).
- Key-migration completeness: no `Vector3i` key ever enters `_edits` under
  FACETED (assert in `_write_cell`).
- G-F1a re-run on both facets of a crossed seam.

**#1 FP3 risk — restream cadence** (study risk #1): the M4 flip machinery fires
every ~200 blocks (demo) / ~625 (earth) instead of per-face. Mitigations already
in hand: the content delta is 5–11° (no D4 re-orientation, no re-bake — plain
flat chunks), the cover + ramp are shipped code, neighbour meshes hide the swap,
and K is a tunable (earth K=12 if 16 hitches). The honest fallback if godot_voxel
restream cost is unfixable: keep **two** VoxelTerrain instances (active +
crossing-target pre-warmed), swap on cross — flagged, only if the gate fails.
Second risk: a missed re-frame consumer (particles, selection highlight, portal
endpoints) — keep R2's enumerable-inventory gate: enumerate visible non-terrain
nodes, assert each is either facet-local or re-frame-registered.

---

## 7. FP4 — seam gameplay (~1 milestone)

**Definition:** the strip becomes real, walkable, generated terrain: banks graded
with the shipped slope/smoothing families, no-build enforcement, collapse and
collider clamps, terrain/sea reconciliation. The invisible wall is gone; crossing
a ridge is walking over a gentle bank.

### 7.1 Strip terrain (profile-level, pure)

In `facet_profile` (§3.2), for columns with `ring_dist(fid, x, z) ≤ STRIP_CELLS`
(distance in the facet plane to the nearest owned ridge line):

```
y_ring(s)   = lerp(y_r0, y_r1, s)                 # ring datum in THIS facet's local y:
                                                  #   y_ri = (ri − plane_point)·n̂  (atlas, per seam)
w           = 1 − ring_dist / STRIP_CELLS         # 0 at strip edge → 1 at the ridge
g_strip     = int(round(lerp(float(g_terrain), y_ring(s_proj) + RIDGE_CREST, w)))
```

with `RIDGE_CREST := 1` (the strip crowns one block above the shared datum —
sheds water, reads as ridge rock). Both facets ramp to the **same** ring, so the
two sides meet within ±1 quantization block; the dihedral kink at 5–11° over a
4-cell strip is a ≤ 1-block rise — the shipped corner-height smoothing +
sharp-slope pipeline grades it with **no new shapes** (study §4.3). Strip columns
also override the surface material to ridge rock (a `B_*`-independent cap in
`_cap_material` gated on strip membership via the profile's biome slot or a
dedicated strip flag — implementer's choice; keep it in the profile stage so
resolve_cell stays untouched). Sea: strip columns clamp the sea fill to
`min(SEA_LEVEL, y_ring − 1)` so ocean seams terminate in banks/falls inside the
strip (the disclosed toy-physics artifact, study §6.5).

Purity is preserved: `ring_dist`/`y_ring` are atlas data — still a pure function
of `(fid, x, z)`.

### 7.2 Gameplay clamps

- **No-build:** `WorldManager.place_block` (line 633) rejects cells whose column
  is in-strip (`FacetAtlas.in_strip(fid, x, z)`); `break_terrain` rejects strip
  terrain cells (ridge rock unbreakable — cheap and sidesteps
  collapse-at-boundary edge cases).
- **Collapse:** `_collapse_unsupported`'s flood-fill treats in-strip columns as
  *supported boundary* (they terminate the search like region edges do) — a
  cluster can never span a seam.
- **Wall removal:** delete the FP2 `blocked()` prelude; the FP3 handoff +
  walkable banks take over. GroundCollider: zero changes (it reads generation).
- FP2's strip prism mesh shrinks to a thin ring-line cap (the generated strip
  terrain now does the visual work); neighbour meshes terminate against it.

### 7.3 FP4 gates

Seam-walk invariant (headless): along 50 sampled ridge crossings, consecutive
column height deltas ≤ 1 block through the strip on both sides (walkable without
jumping, `STEP_MAX = 0.55` respected via the slope shapes); no-build/no-break
enforced in-strip; collapse never crosses (place a bridge over a seam → break it
→ assert cluster confined); sea-seam columns hold `≤ min-datum` water; live
crossing now wall-less end-to-end. Full verify + G-series re-run.

**#1 FP4 risk — bank quality near the 8 old corners** (datum steps up to
~12 blocks at earth k=16 land exactly where facets are rhombic): the ramp formula
holds (it just gets steeper — the sharp-slope family covers up to its designed
pitch), but the *look* needs the FP5 fit-and-finish pass; scope FP4's gate to
walkability + invariants, not aesthetics.

---

## 8. FP5 — the 8 twist singularities + fit-and-finish + live A/B (~1 milestone)

1. **Twist-field bake** (`FACET_TWIST`): per-facet in-plane grid rotation φ_fid
   (§2.2 hook). Bake (one-shot in `FacetAtlas.warm_up`, or an offline tool
   writing a table): minimize Σ_seams (φ_A − φ_B + ω_AB − 90°·q_AB)² where ω_AB
   is the geometric transport angle across the seam (unfold B's frame across the
   ridge into A's plane, measure ê_u misalignment mod 90°) — trivial-connections
   least squares (study §5.3). Fix the 8 quarter-index singularities at the old
   cube corners (constrain the corner-adjacent loops' holonomy to 90°); solve the
   rest by Gauss–Seidel over the seam graph (6K² unknowns — milliseconds).
   Gates: twist ≤ 1.5° on every seam ≥ 10 facets from a singularity; indices sum
   to +2; Σ defects unchanged. **Disclosed cost: flipping FACET_TWIST regenerates
   facet content** (the hash lattice rotates with the frame) — land it before
   persistence matters, A/B on fresh worlds.
2. **Corner-cluster fit-and-finish:** cap bank pitch near the 8 clusters
   (designed cliff/bank profiles where the step > 6 blocks), and the cosmetic
   **navel monuments** at the 8 singular vertices (static mesh in the far
   ring/neighbour layer — NOT the M5c pillar machinery; that stays deleted).
3. **Gate re-derivation sweep:** retire the T-series/C-gates/wedge enumerations
   from the faceted path's CI expectations; the faceted gate set (G-F1a..f, weld,
   cross, seam-walk, twist) becomes the suite of record for `FACETED`.
4. **Live A/B vs shipped R2+M5c** on the web deploy (earth K=16 build): loads,
   plays, crossings hitch-free, user pass — the study's exit criterion.

**#1 FP5 risk:** the regeneration coupling of φ (above) — mitigated by shipping
naive orientation (φ=0) as the FP1–FP4 default and treating FACET_TWIST as a
world-generation parameter, not a runtime toggle.

---

## 9. Cross-stage summary

| Stage | New | Touched | Gate (exit) | ~size |
|---|---|---|---|---|
| FP1 | `facet_atlas.gd`, `verify_faceted.gd` | terrain_config, module_world, world_manager, cube_sphere, main | G-F1a..f (§4.7) | ~670 lines |
| FP2 | `facet_far_ring.gd`; atlas seams | world_manager (mask+wall), main (fog gate) | weld closure; join ≤1; web FPS parity | ~700 |
| FP3 | — | world_manager (cross, keys), module_world (`set_facet`), player (`apply_reframe`) | cross-and-return byte-identity; no-hitch live | ~460 |
| FP4 | — | terrain_config (strip profile), world_manager (clamps), facet_far_ring (strip cap) | seam-walk/build/break invariants | ~300 |
| FP5 | twist bake, monuments | facet_atlas, facet_far_ring | twist bounds; live A/B user pass | ~350 |

Web/never-OOM ledger (all stages): zero custom shaders, zero per-voxel data,
atlas < 1 MB, neighbour+far meshes capped at build, workers read only
frozen-after-warm-up data, threading model unchanged, COOP/COEP unaffected.

## 10. The three things most likely to be implemented wrong

1. **f32 leaking into the d̂/frame path** (§2, §3.2): any `Vector3` between the
   corner directions and the normalized d̂ (or reusing FP0's f32
   `facet_corners`/`facet_pos_at` in the kernel) silently breaks
   worker==analytic byte-identity and seam continuity at earth scale. The kernel
   is scalar-f64/DVec3 end to end; `Transform3D` appears only as the *last*
   step, for node placement. G-F1a/G-F1e are the tripwires.
2. **Basis handedness and the normal sign** (§2.2): `ê_w` must be `ê_u × n̂`
   (det = +1 forced), `n̂` must be flipped outward (`n̂·m > 0`), and the facet
   polygon must be *computed* from projected corners in that frame — deriving
   ê_w from the c3 edge, or assuming the polygon's z-sign, mirrors or misplaces
   the domain on half the faces (FACE_U/V handedness varies per face).
3. **The one-map rule + offset bookkeeping** (§2.2–2.4, §3.2): sampling
   (`cell_dir`), placement (`W_fid`/`T_fid`), domain tests (`in_polygon`), spawn,
   and edit-key packing must all subtract the same `O` and use the same
   `+0.5` cell-centre convention *by calling the same functions* — a second
   hand-rolled copy of the affine map (e.g. inside the generator source string)
   is where an off-by-O or off-by-half desync will hide. In FP3, the same class
   reappears as Δ applied wrongly: **position takes the full transform;
   velocity/look take the basis only; physics snaps, only the render camera
   eases** (the #71 bug family).
