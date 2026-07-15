# COSMOS-M5C-CORNER — the walkable-land-corner seal: bedrock pillar + anomaly teleport

Status: implementable spec (Fable, 2026-07-12), task #77. **Supersedes COSMOS-M5-ADR §4**
(the keystone-monument design): the keystone is replaced by a bedrock PILLAR (§2) and the
"unreachable by monument" argument is replaced by the ANOMALY TELEPORT (§5) + a universal
seam-GLUE rule (§6) + a corrected eager-flip lemma (§7). The §5.3 sea-corner design stays
rejected as the corner *solution*; its **edit-lock clause is reused** (§3, `CORNER_LOCK_R = 8`,
cube_sphere.gd:31) and its fallback clause becomes the §8 energy barrier. `CORNER_SEA_R = 48`
(cube_sphere.gd:30) remains pinned-but-unconsumed — nothing here uses it.

Prerequisites, all shipped: #74 `M_win` (COSMOS-FRAME-ORIENTATION), #69 canonical corner fold
(`fold_cell_canonical`, cube_sphere.gd:459), R2/Design-Z real-baked geometry
(COSMOS-REAL-GEOMETRY-STUDY; `M5_REAL`, cube_sphere.gd:129), the wedge spawn/camera guards
(main.gd:153 `_find_flat`, world_manager.gd:928 `m5_epoch_camera`).

Locked constraints honoured: spawn stays on the polar face-4 corner; FLAT_WORLD stays
byte-identical (every hook is `_chart != null`-guarded and additionally behind the new
`M5C_CORNER` flag, default **false**); never-OOM (zero new per-frame allocations, no new
volumes, one small static mesh per visible pillar via ordinary worldgen); worker-thread
determinism (everything in the generation path is a pure function of global position under
the frozen-epoch contract — no mutable statics).

---

## 0. Executive summary

The 3-face cube vertex is a cone point with a 90° angle deficit; the flat window realizes it
as the home quadrant + two strips (the unrolled 270° cone) + a 90° "wedge" quadrant that has
no physical existence (double-out columns; render-culled in both layers under M5_REAL). M5c
makes the corner *playable and sealed* with five pieces:

1. **Bedrock pillar** (§2): a ~3-cell-radius unbreakable bedrock monument at each of the 8
   vertices, generated as a pure function of the column direction d̂ — identical from every
   face/epoch/worker (§8.2-clean).
2. **Edit lock** (§3): all edits refused in every column within `CORNER_LOCK_R = 8` raw cells
   of a vertex (all heights), plus the shipped double-out refusal.
3. **Eager corner-zone flip** (§4): inside `CORNER_ZONE_R = 72` of a vertex the flip
   hysteresis drops from 64 to `FLIP_HYST_CORNER = 5`, so the player re-homes almost
   immediately after any edge crossing near the corner. *(Both constants corrected from the
   ADR's 32/8 — see §7 and §13; the ADR pair does NOT seal the wedge.)*
4. **Anomaly teleport** (§5): a full-height cylinder of radius `R_b = 8` (raw cells) about the
   vertex; a player entering it exits at azimuth `φ + 135° (mod 270°)` on the unrolled cone at
   radius 8.5, speed/height preserved, yaw rotated to keep heading-relative motion. The 135°
   rule is the unique symmetric (bisector) geodesic continuation through the cone point, an
   involution, and reproduces the true great-circle continuation for a head-on entry.
5. **Universal seam glue** (§6): ANY entity (player defensively, debris/projectiles/items
   always) whose column goes double-out is mapped by the exact ±90° seam identification about
   the vertex — the wedge is unreachable by anything, at any radius, at any speed.

One flag selects teleport vs the fallback solid **energy barrier** over the same cylinder (§8).

---

## 1. Frames, notation, and the vertex in window coordinates

All corner math is defined in the **continuous RAW home-face frame**, never directly on
window (x, z) — the window frame rotates with `M_win` and this is the #1 place to write the
bug. Conversions:

- **Window → raw (continuous):** `p = org + M_win·w`, i.e. exactly
  `CosmosTruePlace._raw_of_f` (cosmos_true_place.gd:31). Stage S0 adds the public float twins
  to the chart: `CosmosChart.raw_of_f(x: float, z: float) -> Vector2` and its inverse
  `window_of_f(px, pz) -> Vector2` (`M_win⁻¹·(p − org)`, transpose form, mirroring
  cosmos_chart.gd:67 `raw_of` / :72 `window_of`).
- Continuous raw `px` maps to face parameter `a = 2·px/n − 1` (the `_dir_of` convention,
  cosmos_true_place.gd:62). The face boundary planes are `px ∈ {0, n}`; integer cell `i`
  covers `[i, i+1)`, centre `i + 0.5`.

**The vertex (raw):** the home face's four corner lattice points are
`c = (ci, cj) ∈ {0, n}²` in continuous raw coordinates. The **nearest** corner to a raw point
`p` is `ci = 0 if p.x < n/2 else n`, likewise `cj` — unambiguous everywhere M5c operates
(reach ≪ n/2 = 5008). Which cube vertex k it is: `k` is the index in `CORNER_SIGNS`
(cube_sphere.gd:656) whose direction is `face_cell_to_dir` evaluated just inside that corner;
runtime code never needs k (only generation does, and it derives k from d̂ signs, §2.1).

**The vertex in window coordinates (current epoch):** `w_v = chart.window_of_f(ci, cj)`.
Recomputed from the live chart at every use — it tracks reanchors and flips automatically; no
cached window-space vertex state exists anywhere (frozen-epoch hygiene).

**The corner-canonical frame u′:** with `σ_i := +1 if ci == 0 else −1`,
`σ_j := +1 if cj == 0 else −1`:

```
u  := (p.x − ci, p.z − cj)            # raw offset from the vertex
u′ := (σ_i·u.x, σ_j·u.y)              # canonical: home face is ALWAYS the (+,+) quadrant
```

`σ` preserves norms; `σ_i·σ_j = −1` for two of the four corners (a reflection) — every
formula below is defined in u′-space and mapped back through σ then `M_win⁻¹`, so the
reflection is handled by construction (angles are computed and consumed in u′; final window
vectors are produced explicitly; nothing assumes an orientation of the window frame).

**Quadrants in u′** (defining face B := the neighbour across the i-boundary, face C := the
neighbour across the j-boundary):

| u′ signs | region | meaning |
|---|---|---|
| (+, +) | home quadrant | face A (home) |
| (+, −) | **J-strip** | face C, unrolled across the A–C edge |
| (−, +) | **I-strip** | face B, unrolled across the A–B edge |
| (−, −) | **wedge** | double-out; no physical cell |

**The band angle φ** of a point at offset u′ ≠ 0:

```
φ := wrap_to_[0, 360)( rad2deg(atan2(u′.y, u′.x)) + 90.0 )
```

Ranges (verify these — they are the C1 gate): J-strip `φ ∈ (0°, 90°)`; home
`φ ∈ (90°, 180°)`; I-strip `φ ∈ (180°, 270°)`; wedge `φ ∈ (270°, 360°)`. Boundary rays:
`φ = 90°` is the A–C edge, `φ = 180°` the A–B edge, and — the load-bearing fact —
**`φ = 0°` and `φ = 270°` are two window images of the SAME physical line, the true B–C
edge** (the J-strip unrolls face C rigidly from the A–C edge at 90° down to C's other corner
side, the B–C edge, at 0°; symmetrically the I-strip puts B's copy of it at 270°). The
interval `[0°, 270°]` is therefore exactly the unrolled 270° cone of reality, with the B–C
edge as its glued seam and the wedge as the flat window's 90° of excess.

Inverse (u′ from φ at radius ρ): with `β := deg2rad(φ − 90°)`,
`u′ = ρ·(cos β, sin β)`. Sanity pins: φ=0 → (0,−ρ); φ=90 → (ρ,0); φ=135 → ρ·(√2/2, √2/2)
(the home diagonal); φ=270 → (−ρ, 0).

---

## 2. The bedrock pillar (generation)

### 2.1 Which columns are pillar — the pure-d̂ angular test

Constants (all in cube_sphere.gd, the single kernel source, next to CORNER_SEA_R/LOCK_R):

```
PILLAR_R_CELLS := 3
# per-cell angle along a face midline is exactly (2/n)·(π/4) = π/(2n) (warp is exact there);
# at a corner the local stretch of the equal-angle chart is S ∈ [2/3, 2/√3]
# (COSMOS-PROJECTION-STUDY correction). Scale by S_max so the pillar CONTAINS a
# 3-raw-cell disc in every direction:
THETA_P := PILLAR_R_CELLS * (2.0 / sqrt(3.0)) * PI / (2.0 * float(n))     # ≈ 5.43e-4 rad @ n=10016
```

A generated column with unit direction d̂ (the `d` already computed at
terrain_config.gd:644 in `_curved_profile` — `LatticeNav.dir_of(face, i, j, n)`, i.e. the
canonically-folded direction, so double-out window columns get the SAME test as their
canonical projection) is a **pillar column** iff:

```
# cheap 3-compare prefilter (rejects ~everything mid-face; no acos on the hot path):
near_corner := absf(absf(d.x) − INV_SQRT3) <= 2.0*THETA_P \
           and absf(absf(d.y) − INV_SQRT3) <= 2.0*THETA_P \
           and absf(absf(d.z) − INV_SQRT3) <= 2.0*THETA_P
# exact test (only when the prefilter passes): k from component signs — all components are
# bounded away from 0 here, so the sign vector is well-defined:
ĉ_k := DVec3(sign(d.x), sign(d.y), sign(d.z)) * INV_SQRT3        # == corner_dir(k), no table walk
pillar := near_corner and (d.x*ĉ_k.x + d.y*ĉ_k.y + d.z*ĉ_k.z) >= cos(THETA_P)
```

Prefilter soundness: `|d − ĉ_k| ≤ θ` (chord ≤ angle) implies every component is within θ of
±INV_SQRT3, and θ ≤ THETA_P < 2·THETA_P — no false negatives. Purity: d̂ is a pure f64
function of the global cell (frozen edge tables, no state) → identical across faces, epochs,
window homes, and worker threads (§8.2). Footprint nesting: an angular radius of THETA_P maps
to at most `THETA_P / (S_min·π/(2n)) = 3·(2/√3)/(2/3) ≈ 5.2` raw cells — strictly inside the
`CORNER_LOCK_R = 8` edit disc and the `R_b = 8` anomaly. (Gate C4 pins the footprint.)

### 2.2 Pillar height, material, and the column override

Refactor: extract the current body of `_curved_profile` (terrain_config.gd:640) into
`_curved_profile_base(face, i, j)`; `_curved_profile` becomes base + the flag-gated override.

```
# one flat top per vertex k — pure function of (SEED, k, n):
static func _pillar_top(k: int) -> int:
    var hmax := -0x7fffffff
    for c in CubeSphere.corner_cells(k, n):                     # cube_sphere.gd:669 — 3 cells
        hmax = maxi(hmax, int(_curved_profile_base(c.face, c.i, c.j).x))
    return clampi(hmax + PILLAR_TOP_UP, SEA_LEVEL + PILLAR_TOP_UP, MAX_SURFACE_Y)
```

with `PILLAR_TOP_UP := 6`. Notes: (a) it reads the **base** (pre-pillar) heights of the three
face-corner cells — no recursion; (b) the `SEA_LEVEL + 6` floor makes the monument poke out
of a sea corner (dry-planet-general, still content-pure); (c) the `MAX_SURFACE_Y` (=116,
terrain_config.gd:160) clamp preserves the module generator's proven height bound. Cost: 3
extra base-profile evaluations per pillar column (~90 columns per planet, only when streamed)
— negligible; do NOT memoize in a static (worker purity outranks 3 noise calls).

Override in `_curved_profile` (after `d` is computed, gated `CubeSphere.M5C_CORNER`):

```
if pillar:                                    # §2.1 test on the already-computed d
    var base := _curved_profile_base(face, i, j)
    return Vector4(float(_pillar_top(k)), float(B_PILLAR), base.z, base.w)   # keep real c, t
```

**`B_PILLAR := 10`** — one new biome enum value (after B_MOUNTAINS, terrain_config.gd:181).
Consumers to touch (exhaustive):

1. `resolve_cell` (terrain_config.gd:794) — FIRST branch:
   `if biome == B_PILLAR: return bedrock_id if y <= g else AIR`. This bypasses strata, ores,
   trees, snow (blanket + fill), sea fill (the top is above SEA_LEVEL by construction), and
   smoothing — the pillar is full cubes of bedrock from the world floor to the flat top.
   `bedrock_id := BlockCatalog.id_of(&"bedrock")` (already exists — the world-floor gradient
   uses it, terrain_config.gd:43).
2. TreeGen: the species/spawn gate must return no-tree for `B_PILLAR` (locate the biome
   switch in tree_gen.gd; a one-line case). Defence in depth — resolve_cell's early-out
   already never emits tree cells for pillar columns; this stops trees whose CANOPY would
   overhang from a neighbouring column being rooted ON the pillar column.
3. The surface/cap **modifier** paths (`col_surface_modifier` / `col_surface_cap_modifier` /
   the slope-run predicate, terrain_config.gd:533/542/1157 region): return 0 / no-slope for a
   `B_PILLAR` column — the pillar renders as sheer full cubes (no ramps to climb, no
   directional shapes to fold-rotate). Neighbouring non-pillar columns may still emit slopes
   against the pillar wall; that is fine (they are outside the anomaly by ≥ 2.8 cells).
4. The far builder's biome→colour map (far_mesh_builder / far_terrain): `B_PILLAR` → the
   bedrock grey. The far layer reads `height_at` + biome, so the pillar spike appears in the
   LOD horizon automatically.
5. `PerVoxelEnvironment` surface-temperature keying: treat `B_PILLAR` as `B_MOUNTAINS`
   (one map entry; the HUD thermometer then reads sanely at the monument).

Unbreakability = generation (bedrock) + the §3 edit refusal (which covers the whole 8-cell
disc ⊇ the ≤5.2-cell pillar, all heights, including collapse writes — `_write_cell` is the
single choke point). Render == collision is automatic: both paths read
`generated_block`/`block_id_at` for the same cells (gate C4).

FLAT_WORLD: `_curved_profile` is only reached when `FLAT_WORLD = false`
(terrain_config.gd:436/509) → byte-identical. Flag off: the override is skipped → curved
build byte-identical to today (gate C9).

---

## 3. Edit policy — the CORNER_LOCK_R refusal

Predicate (WorldManager helper, curved-gated, flag-gated):

```
func is_corner_locked_column(x: int, z: int) -> bool:
    if _chart == null or not CubeSphere.M5C_CORNER:
        return false
    var p := _chart.raw_of_f(float(x) + 0.5, float(z) + 0.5)    # CELL-CENTRE continuous raw
    var ci := 0.0 if p.x < float(_chart.n) * 0.5 else float(_chart.n)
    var cj := 0.0 if p.y < float(_chart.n) * 0.5 else float(_chart.n)
    var dx := p.x - ci; var dz := p.y - cj
    return dx*dx + dz*dz <= float(CubeSphere.CORNER_LOCK_R * CubeSphere.CORNER_LOCK_R)
```

Cell-centre convention: cell (0,0) sits 0.707 from the vertex — the disc covers the ~52
nearest columns per vertex, home + strips alike (each strip is a rigid isometry, so raw
Euclidean distance is the correct chart metric across the fold). All heights refused (the
predicate is per-column).

Wiring: early return in `break_terrain` (world_manager.gd:591 — return 0 before the snow
branch) and `place_block` (:626 — return false before validation), so the player gets correct
feedback and no structural pass runs; PLUS the same predicate added to the existing guard in
`_write_cell` (:671–675, alongside the shipped double-out `CORNER_EDIT_LOCK` refusal) so
collapse/snowfall/sim writes are covered at the choke point. The shipped double-out refusal
stays as-is (it is not flag-gated; it ships today).

---

## 4. The eager corner-zone flip

Constants (cube_sphere.gd): `CORNER_ZONE_R := 72`, `FLIP_HYST_CORNER := 5`.
**Both differ from ADR §4.1 (32 / 8) — the ADR pair provably fails to seal the wedge; §7 and
§13 give the counterexample and the derivation.**

Implementation:

1. `CosmosChart.flip_needed` (cosmos_chart.gd:193) gains an optional hysteresis parameter:
   `func flip_needed(local: Vector3, hyst: int = FLIP_HYST) -> bool` (body unchanged, `hyst`
   replacing the constant).
2. `WorldManager.maybe_flip_home_face` (world_manager.gd:1057) computes the corner distance
   once per call and selects the hysteresis:

```
var h := CosmosChart.FLIP_HYST
if CubeSphere.M5C_CORNER and _chart != null:
    var p := _chart.raw_of_f(player_pos.x, player_pos.z)
    var ci := 0.0 if p.x < float(_chart.n) * 0.5 else float(_chart.n)
    var cj := 0.0 if p.y < float(_chart.n) * 0.5 else float(_chart.n)
    _corner_dist = Vector2(p.x - ci, p.y - cj).length()          # stash for the §5 check
    if _corner_dist <= float(CubeSphere.CORNER_ZONE_R):
        h = CubeSphere.FLIP_HYST_CORNER
if not _chart.flip_needed(player_pos, h):
    return false
```

Every flip so triggered is a **single-edge isometry**: at trigger time the crossed-axis
overshoot is in `(h, h + s]` (s = one frame's horizontal travel) and `chart.flip`
(cosmos_chart.gd:205) refuses double-out (`fold_cell` face −1, the shipped `{ok:false}` path
at world_manager.gd:1061-1062 — which stays, now effectively unreachable for the player per
§7). `M_win` accumulates the crossed edge's D4 exactly as today; a full lap around the vertex
is 3 single-edge flips whose composition is the honest 90° holonomy (gate C6; this is correct
curvature — do not "fix" it).

Flip-storm control: hysteresis 5 still exceeds any strafe zigzag amplitude; a circling player
pays the same 3 flips/lap as with 64. The 72-boundary itself is harmless: hysteresis choice
flips 5↔64 with position, but face-flips are one-way per crossing (flipping *early* is never
wrong — the flip is an exact isometry at any overshoot ≥ 1).

**Spawn interaction (required change):** today's spawn lands at a single-out column (e.g.
window (0.5, −15.5) → raw j ≈ −15 < 0, overshoot 15). Under eager hysteresis that fires a
flip + hard restream on the first physics frame. To keep the observed spawn on face 4:
`main._find_flat` (main.gd:153), when `M5C_CORNER` and curved, **prefers** columns whose raw
coords are in-range on the home face (both `raw_of(x,z)` components in `[0, n)`) — same
prefer-over pattern as the shipped wedge skip (main.gd:171-176); the scan box `[−16,16]²`
around the corner always contains native candidates (the (+,+) quadrant). Spawn constraint
honoured: still the corner, still face 4, no boot flip.

---

## 5. The anomaly cylinder + bisector teleport (player)

### 5.1 Region and trigger

Constants: `R_b := CubeSphere.CORNER_LOCK_R = 8` (trigger radius, raw cells, Euclidean about
the vertex point), `R_x := R_b + 0.5 = 8.5` (exit radius), `EPS_PHI := 4.0` degrees (seam-ray
clamp, ≈ 0.59 cells of fold clearance at R_x).

The anomaly is the **full-height** cylinder: trigger = `corner_dist < R_b` at ANY y (world
floor to ceiling). Full height is what closes every bypass: no flying over (the world ceiling
bounds the top), no digging under (the trigger fires underground too; the §3 lock forbids
digging inside anyway), no squeezing through the ground annulus between the ≤5.2-cell pillar
and the 8-cell boundary (reaching it means crossing the trigger surface first). The pillar is
the solid core; the annulus terrain is decorative (never stood on).

Check order, in `Player._physics_process` (player.gd:192): `_move` → `maybe_reanchor` →
`maybe_flip_home_face` → **`world.m5c_corner_check(self)`** (new; flag- and chart-gated
no-op). The check reuses the corner distance stashed by §4 when available. Optional
robustness (specify, cheap): also trigger if the segment (previous position → current)
crosses the disc in the raw xz-plane — closes tunnelling at pathological frame steps; at
realistic speeds the disc (16 cells across) cannot be stepped over.

### 5.2 The teleport map (normative)

All in u′-space (§1), computed by pure statics in a new `cosmos_corner.gd`
(`class_name CosmosCorner`, chart-free — takes raw coords + n; WorldManager does the
window↔raw conversion at the boundary). Inputs: raw position p (continuous), the nearest
corner (ci, cj, σ_i, σ_j), entry height `y_in`, window horizontal velocity `v_h`, vertical
velocity `v_y`.

```
u′      := (σ_i·(p.x − ci), σ_j·(p.z − cj))
φ_in    := wrap_to_[0,360)( rad2deg(atan2(u′.y, u′.x)) + 90 )        # ∈ [0, 270] outside the wedge
φ_out   := clampf( fposmod(φ_in + 135.0, 270.0), EPS_PHI, 270.0 − EPS_PHI )
β_out   := deg2rad(φ_out − 90.0)
u′_out  := R_x · Vector2(cos(β_out), sin(β_out))
p_out   := (ci + σ_i·u′_out.x,  cj + σ_j·u′_out.y)                    # back to raw
w_out   := chart.window_of_f(p_out.x, p_out.y)                        # back to window (M_win⁻¹)
r̂_out   := (chart.window_of_f(p_out.x + σ_i·cos(β_out), p_out.y + σ_j·sin(β_out)) − w_out)
           .normalized()                                              # outward radial, window frame
```

(`r̂_out` via the difference of two mapped points is deliberate: it routes the direction
through the SAME σ/M_win pipeline as the position — no separately-derived rotation matrix to
get wrong; M_win is orthonormal so the result is unit to f64.)

Player state application (player.gd):

```
d̂_in  := v_h.normalized()  if |v_h| > 0.01  else −(window inward radial at entry)   # they were heading in
Δψ    := Vector3(d̂_in.x, 0, d̂_in.y).signed_angle_to(Vector3(r̂_out.x, 0, r̂_out.y), Vector3.UP)
rotation.y += Δψ                                                     # heading-relative view preserved
global_position = Vector3(w_out.x, y_out, w_out.y)
velocity.y unchanged;  horizontal speed |v_h| re-aimed along r̂_out   # v_out = |v_h|·r̂_out + v_y·ŷ
y_out := maxf(y_in, float(world.effective_height(floor cell of w_out) + 1) + 0.01)   # de-embed
```

Notes: `signed_angle_to` about `Vector3.UP` makes the yaw delta sign convention-proof (gate
C7 asserts `d̂_in.rotated(UP, Δψ) ≈ r̂_out`). Re-aiming the full horizontal speed along the
outward radial (discarding the tangential component's direction) is **intentional**: it is
deterministic, ejects the player (no boundary-sliding re-trigger loop), and conserves speed;
a grazing entry is not momentum-true — accepted, disclosed. The exit at `R_x > R_b` plus
outward velocity prevents same-frame re-trigger. Exiting in a strip leaves overshoot up to
8.5 > FLIP_HYST_CORNER → the ordinary §4 flip re-homes on the next physics frame (this is the
designed "zero holonomy interaction": the teleport itself never touches chart/M_win/org).
Under `M5_REAL` no rebake occurs — the teleport is exactly the "camera moves through the
static epoch-baked world" case; `m5_epoch_camera` stays finite because the exit is never in
the wedge (gate C10). VFX (screen flash / particle burst at both ends) is a presentation stub
in this milestone — the conservation rules are what make the cut readable.

Defensive branch (shared with §6): if the player's column is somehow double-out (extreme
frame step, restored save), apply the §6 glue FIRST (it is total at any radius), then the
anomaly test on the glued position. §7 makes this practically unreachable; the code path
exists so no state is ever unhandled.

### 5.3 Proofs

**(a) Involution T² = id.** On azimuths, T: φ ↦ (φ + 135) mod 270 on the cone [0, 270);
T²(φ) = (φ + 270) mod 270 = φ. Radially: exit at R_x; a straight radial re-entry crosses the
trigger at the same azimuth, so T² restores the azimuth exactly and the radius to within
(R_x − R_b) = 0.5. The EPS_PHI clamp perturbs only the two ε-bands at the seam rays (by
≤ EPS_PHI); gate C7 asserts exact involution outside the bands and bounded deviation inside.

**(b) 135° is THE bisector — the ±45° ambiguity is resolved deterministically and
symmetrically.** The cone angle is Θ = 270°. A geodesic hitting the apex may leave anywhere
in the Θ-fan; the deficit (90°) makes the continuation ambiguous by ±45° about the symmetric
choice. The symmetric ("straightest") continuation is the one making equal angles on both
sides of the incoming ray: exit azimuth = φ_in + Θ/2 = φ_in + 135°. And on THIS cone the two
half-turn candidates coincide: +135 ≡ −135 (mod 270) — there is exactly one symmetric
continuation, so the rule is canonical, not a convention.

**(c) A head-on entry along the corner bisector exits exactly along the true B–C edge.**
Window bookkeeping: entry from the home quadrant along the face-A corner diagonal has
position azimuth φ_in = 135° (the u′ home diagonal, §1 pin); φ_out = 270 mod 270 = 0 —
the J-strip seam ray, which §1 showed is the window image of the true B–C edge; the exit
velocity points outward along it. Sphere geometry (why that is the physically-true
continuation): take the spawn corner ĉ = (1,−1,1)/√3 (faces A=4 (+Z), B=0 (+X), C=3 (−Y)).
The plane Π through the origin with normal (1,1,0)/√2 is a cube mirror plane (swaps +X ↔ −Y,
fixes +Z): ĉ·(1,1,0) = 0 so ĉ ∈ Π; the face-A corner-diagonal tangent at ĉ lies in
span(ĉ, ẑ) ⊂ Π (ẑ·(1,1,0) = 0); and the whole B–C cube edge {(1,−1,t)} projects into Π
(x + y = 0). A great circle is the intersection of its plane with the sphere: the circle
entering ĉ along A's diagonal lies in Π, and Π's continuation past ĉ is precisely the B–C
edge fan. The same argument holds at every corner by symmetry (relabel axes). So the bisector
rule's flagship case reproduces the exact great-circle continuation — the validation the
memory design demanded. (Gate C3 checks both halves: the window exit lands on the seam ray,
AND the world-space entry/exit rays are coplanar through the vertex direction.)

---

## 6. The universal seam glue (non-flipping objects + defensive player)

Entities that do not flip the chart (VoxelBody debris, projectiles, dropped items — and the
player as a §5.2 defensive fallback) get the **global rule: any entity whose column goes
double-out is glued back through the B–C seam, wherever it is** — at ANY radius from the
vertex, because the wedge quadrant extends to all radii and a fast object can cross a seam
ray far outside R_b.

The map is the exact deck transformation identifying the two seam rays (φ = 0⁻ ≡ φ = 270,
§1): a ±90° rotation about the vertex in u′-space, radius/height/speed preserving:

```
# entity at raw p with double-out column (fold_cell face == −1):
u′, φ as in §5.2                      # φ ∈ (270°, 360°) — the wedge band
if φ >= 315.0:                        # entered across the φ=0 ray (from the J-strip / face C)
    u′_new := ( u′.y, −u′.x)          # rotation −90°: φ → φ − 90  ∈ (225, 270)  → I-strip (face B)
else:                                 # entered across the φ=270 ray (from the I-strip / face B)
    u′_new := (−u′.y,  u′.x)          # rotation +90°: φ → φ + 90 (mod 360) ∈ (0, 45] → J-strip (face C)
```

Position back through σ / window as in §5.2. Velocity AND (for the player fallback) yaw are
rotated by `Δψ := signed_angle(old window radial, new window radial, UP)` — the glue
preserves the radius, so radial-to-radial IS the applied rotation, and computing it from the
two final window vectors makes it exact under any σ reflection and any M_win (the abstract
angle is ∓90° conjugated by σ/M_win; never hand-derive that sign — gate C8 pins it).

Why this is correct (and why it is NOT the 135° bisector): the two seam rays are the same
physical line; an object crossing φ = 0 heading into the wedge is, in reality, crossing the
B–C edge from face C onto face B, whose window image continues from φ = 270 inward — the
−90° rotation maps the (unphysical) wedge continuation onto exactly that image, at every
radius. The bisector rule is only for trajectories through the apex region and is player-only
(a gameplay device); applying it to a seam-crossing object at radius 200 would teleport it
135° around the planet corner — wrong. The 315° split resolves the (measure-zero) deep-wedge
ambiguity deterministically (nearest seam wins). Residual: for an entity caught δ into the
wedge (δ ≤ one frame of travel), the glued position differs from the true geodesic
continuation by O(δ · corner shear) ≪ a cell — gate C8 bounds it via
`world_point_of(column before) ≈ world_point_of(column after)`.

Runtime check placement: WorldManager, in the same pass that services awake bodies (the
active-body registry, world_manager.gd:405-500) — for each AWAKE body each physics frame:
one `raw_of_f` + two range tests; apply the glue to `global_position` and `linear_velocity`
(through `PhysicsServer3D`/body state as VoxelBody exposes it). Dormant bodies cannot move
and need no check. Cost: zero when nothing is awake; a handful of flops per awake body
otherwise (never-OOM: no allocations). Under `M5_REAL` the glue is visually near-seamless:
the two glue-related window positions bake to (nearly) the same world point, since the strips
wrap and meet at the true B–C edge (corner-closure theorem).

---

## 7. The wedge-unreachability lemma (corrected)

**Lemma.** With eager hysteresis h_c inside a zone of radius Z about the vertex, outer
hysteresis H = FLIP_HYST = 64, per-frame horizontal travel ≤ s, and Z ≥ H + s: an un-flipped
player column can only become double-out at raw distance ≤ √2·(h_c + s) from the vertex.

*Proof.* Becoming double-out means crossing a seam ray (u′ axis) from a strip (crossing from
the home quadrant passes through a strip or through the vertex point itself, which is inside
the anomaly). At the crossing, the corner distance equals the current overshoot o of the
already-out axis. If o > h_c: the flip predicate held at the previous check unless the player
was outside the zone then; but a seam-ray point with overshoot o ≤ H is at corner distance
o ≤ H ≤ Z − s, so the player entered the zone at least one frame before reaching the ray, the
h_c-check fired, and the flip (single-out at that moment) executed — contradiction. Hence
o ≤ h_c + s at the crossing; one further frame bounds both overshoots by h_c + s, i.e.
distance ≤ √2·(h_c + s). Overshoot > H un-flipped is impossible anywhere (the H-check fires
first, and single-out folds never refuse). ∎

**Constants.** Sealing requires √2·(h_c + s) < R_b = 8, i.e. h_c + s < 5.65. With
s ≤ 0.6 (sprint-fly at 60→20 fps): **h_c = FLIP_HYST_CORNER = 5**. And Z ≥ H + s = 64 + s:
**Z = CORNER_ZONE_R = 72** (8 cells of buffer). *This corrects the ADR §4.1 / memory-sketch
pair (32, 8) twice over:* (i) Z = 32 leaves the seam rays at distance 32–64 outside the zone
— a player with overshoot 40 at (−40, 100) walks −j to (−40, 0⁻) and enters the wedge at
distance 40, un-flipped, far outside the anomaly; (ii) h_c = 8 gives √2·8 = 11.3 > 8 — the
Chebyshev corner of the un-flipped box pokes outside the Euclidean anomaly disc.

**Seal statement.** Player: un-flipped double-out ⇒ distance ≤ √2·(5 + s) ≈ 7.9 < 8 ⇒
already inside the anomaly, whose trigger fired at the R_b crossing (or, at pathological
frame steps, the §5.2/§6 defensive glue catches the double-out state itself — total either
way). Everything else: the §6 glue is total at all radii. Therefore **no entity's column is
ever double-out for more than one frame, the wedge is unreachable by anything, M5_REAL's
culled wedge render is never observable from a reachable state, and the #75 red wedge marker
can retire** (keep it in dev builds until gate C6 has run against a live build).

---

## 8. Fallback: the solid energy barrier (one flag)

`M5C_TELEPORT := true` in cube_sphere.gd. `false` degrades the anomaly to a **solid barrier**
over the SAME full-height cylinder (radius R_b about the vertex): §2 pillar, §3 lock, §4
eager flips, §6 glue, and every §7 invariant keep; only the §5 bisector teleport is replaced
by "you cannot enter":

- Player: in the analytic per-axis wall test in `Player._move` (player.gd:239-249 region),
  a candidate horizontal position whose corner distance < R_b zeroes that axis (consult a
  WorldManager helper `m5c_barrier_blocks(pos: Vector3) -> bool`; curved+flag-gated, reuses
  the §4 corner-distance computation). Full-height ⇒ no flying over (the world ceiling caps
  the column).
- Visual: one translucent emissive cylinder mesh per in-range vertex (a plain MeshInstance3D
  child of the render root, positioned at `w_v` per frame — window-space, so under M5_REAL it
  needs the same per-object placement as other window-space objects; acceptable for a dev
  fallback).
- Objects: unchanged (§6 — debris must still never enter the wedge).

Selection is runtime-cheap: `m5c_corner_check` branches on the flag; both paths share the
trigger predicate. Gate C11 runs the C6 fuzz in barrier mode and asserts the player's corner
distance never goes below R_b.

---

## 9. Flags and byte-identity

New constants in cube_sphere.gd (kernel source, beside the existing corner constants):

```
const M5C_CORNER := false        # master M5c toggle — default OFF: shipped build unchanged
const M5C_TELEPORT := true       # true = §5 anomaly teleport; false = §8 energy barrier
const CORNER_ZONE_R := 72        # eager-flip zone (raw cells about a vertex)   [§4, §7]
const FLIP_HYST_CORNER := 5      # eager hysteresis inside the zone             [§4, §7]
const PILLAR_R_CELLS := 3        # pillar angular radius in cells               [§2.1]
const PILLAR_TOP_UP := 6         # pillar top above max corner-cell base height [§2.2]
```

(THETA_P, R_b = CORNER_LOCK_R, R_x = R_b + 0.5, EPS_PHI live as derived consts where used:
THETA_P in terrain_config's pillar test — it needs n; R_x/EPS_PHI in cosmos_corner.gd.)

Byte-identity matrix (gate C9): FLAT_WORLD=true → no chart → every hook inert (predicates
short-circuit on `_chart == null` BEFORE reading M5C flags). FLAT_WORLD=false +
M5C_CORNER=false → pillar override skipped, hysteresis always 64, no anomaly/glue/lock-radius
checks → byte-identical to the shipped curved build. All generation-path additions read only
frozen state (edge tables, consts, SEED) — worker-safe under the frozen-epoch contract.

---

## 10. Staged implementation plan (for Opus)

Each stage lands separately, headless-gated, and is inert until `M5C_CORNER` flips on
(S0–S2 are inert even WITH the flag on until S3/S4 wire the runtime).

**S0 — kernel constants + pure corner math + chart float accessors.**
Files: `godot/src/cosmos/cube_sphere.gd` (the §9 consts); NEW
`godot/src/cosmos/cosmos_corner.gd` (pure statics, chart-free, raw-space: `nearest_corner`,
`uprime_of`, `phi_of`, `teleport_raw` (§5.2 through p_out + β_out), `glue_raw` (§6),
`in_anomaly`); `godot/src/cosmos/cosmos_chart.gd` (`raw_of_f`, `window_of_f` — float twins of
:67/:72). NEW `godot/src/tools/verify_cosmos_m5c.gd` with gates C1, C2, C3(window half),
C8(algebra) — all pure, flag-independent.

**S1 — pillar generation.**
Files: `godot/src/world/terrain_config.gd` — split `_curved_profile` (:640) into
`_curved_profile_base` + override; `_pillar_top`; `B_PILLAR := 10` (:181 region);
`resolve_cell` (:794) first-branch; modifier suppression (:533/:542/:1157 region);
`godot/src/world/tree_gen.gd` — B_PILLAR no-tree case; the far builder's biome colour map;
`PerVoxelEnvironment` temp keying. Gates: C4, C9-generation. Independently testable headless
(pure worldgen).

**S2 — edit lock radius.**
Files: `godot/src/world/world_manager.gd` — `is_corner_locked_column`; early refusals in
`break_terrain` (:591) and `place_block` (:626); predicate added to the `_write_cell` guard
(:671-675). Gate: C5.

**S3 — eager corner-zone flip + native spawn preference.**
Files: `godot/src/cosmos/cosmos_chart.gd` — `flip_needed(local, hyst := FLIP_HYST)`;
`godot/src/world/world_manager.gd` — hysteresis selection + `_corner_dist` stash in
`maybe_flip_home_face` (:1057); `godot/src/main.gd` — `_find_flat` (:153) native-column
preference. Gates: C6 (flip cadence, single-edge, holonomy — walker without teleport yet),
spawn-native assert.

**S4 — anomaly teleport + universal glue (the runtime seal).**
Files: `godot/src/world/world_manager.gd` — `m5c_corner_check(player)` (trigger + calls into
CosmosCorner + returns the relocation for the player to apply), awake-body glue pass in the
active-body service (:405-500 region); `godot/src/player/player.gd` — call site after
`maybe_flip_home_face` (:210), application of position/velocity/`rotation.y` (:122 yaw
convention), de-embed via `effective_height`; VFX stub. Gates: C6 full fuzz (with teleport),
C7, C8 runtime, C10.

**S5 — barrier fallback.**
Files: `godot/src/player/player.gd` (per-axis barrier block in `_move`),
`godot/src/world/world_manager.gd` (`m5c_barrier_blocks`), the cylinder visual. Gate: C11.

**S6 — docs + retire #75 marker (dev builds keep it until C6 runs live) + `/steelman` +
ADR §4 erratum pointer to this file.**

---

## 11. Headless gates (`verify_cosmos_m5c.gd`, SceneTree pattern of verify_cosmos_m5.gd)

Curved-only (loud-skip exit 2 under FLAT_WORLD, the shipped discipline). C1–C3/C8-algebra run
against the pure CosmosCorner statics regardless of M5C_CORNER; generation/runtime gates
require a flag-on build (the M5c dev branch runs with the flag on; the shipped default-off
build loud-skips them).

- **C1 φ-map algebra:** quadrant classification and φ ranges (§1 table) for all 4 corners ×
  all 4 M_win rotations × both σ parities; u′ round-trip; the §1 sanity pins (φ = 0/90/135/270
  directions) exact to 1e-9.
- **C2 involution:** sweep φ_in ∈ {1°…269°} × radii {2, 5, 7.9}: azimuth(T(T(x))) == azimuth(x)
  to 1e-6 outside the EPS_PHI bands; deviation ≤ EPS_PHI inside; exit radius == R_x always;
  exit never in the wedge band.
- **C3 bisector = B–C continuation:** φ_in = 135 → φ_out clamps to EPS_PHI (seam ray);
  window half: the exit column folds single-out onto face C with the B–C-edge coordinate
  within 1 cell; world half: entry-ray and exit-ray sample points (via
  `chart.world_point_of` / `CubeSphere.world_point`) are coplanar with the vertex direction
  ĉ_k — |triple product| < 1e-6 — for at least 2 corners.
- **C4 pillar:** (a) byte-equality: for 2 vertices, every pillar cell's
  `generated_cell_global` value identical when queried via all 3 incident faces and under 2
  epochs (`set_active_frame` face/M_win variants); (b) footprint: the pillar column set == the
  §2.1 predicate set, contained in raw radius 5.5, containing raw radius 3; (c) one flat top
  == `_pillar_top(k)`, material bedrock full-cubes, zero modifiers, zero tree cells;
  (d) render==collision: `block_id_at`/`cell_solid` agree with `generated_block` over the
  pillar (WorldManager instance, the verify_feature pattern).
- **C5 edit lock:** `break_terrain` → 0, `place_block` → false, `_write_cell` no-op for
  columns at raw distance ≤ 8 (home + strip samples, all heights incl. y = pillar top);
  allowed at distance 9; shipped double-out refusal unchanged.
- **C6 no-double-out fuzz:** a driven walker (pure chart + §4/§5/§6 rules state machine, no
  scene): circles at radii {R_x+0.5, 12, 20, 40, 64, 71} both directions, random zigzags, and
  step sizes up to s = 2.0; assert: player column never double-out for > 0 frames un-handled;
  every `chart.flip` returns ok:true and is single-edge; ≤ 3 flips per lap; after each full
  lap `d4_of(chart.m_win())` advanced by exactly ±1 (90° holonomy — correct, pinned, not
  "fixed"); with teleport on, laps at radius < R_b get relocated and never enter the wedge.
- **C7 conservation:** across teleports: |v_h| preserved to 1e-6; y preserved unless de-embed
  raised it (assert only-raise); `d̂_in.rotated(UP, Δψ) ≈ r̂_out` (yaw delta correctness);
  azimuth involution (C2 re-run through the full player-state path).
- **C8 glue continuity:** seam-crossing samples at radii {3, 8, 40, 200}, both rays, both
  parity corners: radius and |v| preserved exactly; `world_point_of` of the pre-glue column
  (canonical fold) vs post-glue column agree within 1.1 cells; the applied rotation equals
  ∓90° conjugated by σ/M_win (matrix check).
- **C9 byte-identity:** with M5C_CORNER=false: `height_at`/`generated_cell_global` over the
  corner region byte-equal to `_curved_profile_base`-derived values; flip hysteresis
  selection returns 64 everywhere; no M5c predicate reachable. (FLAT_WORLD identity is
  structural — chart-null short-circuits — assert the guards' order once.)
- **C10 M5_REAL camera:** with an epoch installed, teleport/glue exits give
  `place_true(player) != _WEDGE` and a finite `m5_epoch_camera` for every C6 relocation.
- **C11 barrier mode:** C6 fuzz with M5C_TELEPORT=false: corner distance never < R_b; glue
  still active; all other invariants hold.

---

## 12. Risks

1. **Teleport feel (the hard 135° cut)** — the known #1 risk, unchanged from the sketch.
   Mitigations: strict conservation (speed/height/heading-relative yaw), exit-outward
   ejection, anomaly VFX, and the involution (walking back in undoes it — the anomaly reads
   as a consistent *place*, not a glitch). The locked FALLBACK is one flag away (§8) and
   keeps every invariant.
2. **Frame-rotation class bugs** (this project's recurring wound): every angular formula here
   is defined in u′-space and converted by mapping *points* through the σ/M_win pipeline,
   never by hand-composed rotation signs; C1/C8 pin all 4 corners × 4 M_win × both parities.
3. **Flip cadence near the zone boundary / spawn**: eager flips are one-way isometries
   (early ≠ wrong); the spawn native-preference (§4) removes the boot flip. C6 bounds
   flips/lap.
4. **Generation cost**: the pillar prefilter is 3 compares per column on the curved hot path;
   the exact test + `_pillar_top` run only within ~2·THETA_P of a corner. Measure once in the
   S1 headless timing if paranoid; expected noise-level.
5. **De-embed vs conservation**: teleporting a digger/cave-crosser to the exit surface is a
   deliberate, disclosed anomaly behaviour (C7 asserts only-raise).

---

## 13. Corrections made to the memory-sketch design (fidelity notes)

1. **The unreachability constants were wrong — replaced.** The sketch's "h_c ≤ R_b = 8" (and
   ADR §4.1's CORNER_ZONE_R = 32) fail two ways: the un-flipped double-out box is Chebyshev
   (corner √2·h_c = 11.3 > 8 escapes the Euclidean anomaly), and a zone smaller than
   FLIP_HYST = 64 leaves seam-ray segments at distance 32–64 where wedge entry needs no flip
   at all. Corrected: **FLIP_HYST_CORNER = 5, CORNER_ZONE_R = 72**, lemma re-proven (§7).
2. **"Any double-out object gets the anomaly mapping" made precise — and it is NOT the
   bisector.** The correct total rule is the seam GLUE (±90° deck transformation about the
   vertex, §6), valid at every radius; the 135° bisector is player-only, apex-only. Applying
   the bisector to a seam-crossing object at large radius would be physically wrong. The
   player additionally gets the glue as a defensive fallback, which also closes the
   extreme-frame-step gap in the lemma.
3. **Seam-ray exit clamp added (EPS_PHI):** an exact φ_out ∈ {0°, 270°} exit lands on a face
   boundary plane and, for the two n-side corners, classifies double-out (p = n is out of
   range). The clamp costs ≤ 4° (≈ 0.6 cells) and only in the measure-zero seam cases;
   involution holds exactly outside the ε-bands.
4. **"Canonical vertex-direction surface height" made well-defined:** `dir_to_face_cell(ĉ_k)`
   is argmax-ambiguous at the exact corner; replaced by the symmetric
   `max` over the three `corner_cells(k, n)` **base** heights (+ the SEA_LEVEL and
   MAX_SURFACE_Y clamps), which is face-permutation-invariant and recursion-free (§2.2).
5. **Eager spawn side-effect handled:** the shipped spawn column is single-out (raw j ≈ −15);
   naive eager hysteresis would hard-restream on frame 1. `_find_flat` prefers home-native
   columns under the flag (§4) — spawn stays the face-4 corner, no boot flip.
