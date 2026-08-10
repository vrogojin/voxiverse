# COSMOS far-skin vertex-colour BLOCK-EXACT law (FP_SKIN_BLOCK_COLOR)

Fable design, 2026-08-10. Driven by the user directive (verbatim, already quoted in
`docs/COSMOS-SKIN-BLOCK-EXACT-DESIGN.md`):
> "Colors MUST correspond exactly to the original block textures only. Biomes define block
> textures, block textures define pixel colors for FAR skin."

## 0. Read this first — the ground already covered (do not re-derive, do not re-fix)

Two prior designs already attacked this exact directive. Both are **shipped, default-off,
byte-identical-off**:

1. **`FP_SKIN_BLOCK_EXACT`** (`docs/COSMOS-SKIN-BLOCK-EXACT-DESIGN.md`) — the **fine-map / tile-bake**
   tier (`facet_tex_baker.gd` GDScript P0 + `bake_far_tile` C++ P1, patch `0011-cosmos-parallel-tile-bake.patch`)
   is **already fully block-exact**: `texel_index = far_color_index_of_block(top_block_id(g,biome,t,x,z))`,
   both GDScript and C++ byte-equal by construction (shared `deco_far_idx` LUT). This is the whole-planet
   fine map + the shell's textured skin you see up close and from most orbital altitudes.
2. **`FP_FAR_COLOR_UNIFIED`** (`docs/COSMOS-FACET-COLOUR-SEAM-DESIGN.md` §3.1, `cube_sphere.gd:537-550`) —
   an **approximation**, not a fix of the same kind. Its own doc comment names the exact residual gap:
   > "`FacetSmoothV2` / block-LOD rings / the shell's own vertex colour... today `color_for`'s biome tints
   > are hand-tuned lerps... while the fine map paints the ACTUAL top block."
   `FP_FAR_COLOR_UNIFIED` makes `color_for`'s four blend tints (`_savanna/_forest/_jungle/_taiga`) equal the
   **statistical mean** of the block-exact law per biome (`far_palette.gd` `_biome_tints`, derived from
   `TreeGen`'s own density constants) — closing the facet-to-facet **seam** between tiers, but every column
   inside a `color_for` tier still gets **one flat colour per biome**, not its own block's colour. A savanna
   facet under `FP_FAR_COLOR_UNIFIED` is a *better-matched* uniform tan-green, not per-column
   grass/sand/rock variation.

**The genuine remaining gap — what this design closes** — is exactly the three consumer groups
`FP_FAR_COLOR_UNIFIED`'s own comment names: every live call site of `FarPalette.color_for(g, biome, t,
clamped_sea)` outside the already-block-exact fine map. Confirmed by grep, all in **pure GDScript, zero
C++ colour involvement**:

| # | File | Function | Line(s) | Tier |
|---|------|----------|---------|------|
| 1 | `facet_far_ring.gd` | `_planar_grid_arrays(fid, cells)` | 2273 | limb path (gated) |
| 2 | `facet_far_ring.gd` | `_ensure_cached(fid,...)` | 3087 | shipped shell planar-corner cache |
| 3 | `facet_far_ring.gd` | `_ensure_backstop_cached(fid,...)` | 3297 | legacy-bilerp fallback branch |
| 4 | `facet_far_ring.gd` | `_ensure_backstop_cached_env(fid)` | 3373 | envelope backstop |
| 5 | `facet_far_ring.gd` | `_ensure_backstop_cached_env_weld(fid)` | 3428 | envelope backstop, FS1-welded |
| 6 | `facet_far_ring.gd` | `_env_weld_grid(fid, cells,...)` (static) | 3505 | envelope backstop, dense |
| 7 | `facet_far_ring.gd` | `_weld_node(cd, s, t, pos, col)` | 4154, called from 2247/3021/3142/3165/3275 | FS1-weld shared helper, 5 callers |
| 8 | `facet_smooth_v2.gd` | `build_tile(fid, cells, gen)` (static) | 86 | V2 relief annulus |
| 9 | `facet_block_lod_ring.gd` | `_build_facet_arrays(fid,...)` | 481 | block-LOD (ring; orbit/global reuse this via `lvl_override`, confirmed by the P2 comment at `facet_block_lod_ring.gd:445-447`) |

Checked and **out of scope, matching existing precedent**:
- `facet_block_lod_ring.gd:179`, `facet_block_lod_orbit.gd:109`, `facet_block_lod_global.gd:78` — these
  three calls pass throwaway args (`int(p.x), int(p.y), p.w, false`) purely to force `FarPalette`/
  `BlockCatalog`/`ClimateModel` lazy-init on the **main thread** before async work starts (see the doc
  comment at `facet_block_lod_ring.gd:171`). Not a colour output. No change.
- `facet_skin_tier.gd:628` — `FarPalette.color_for(g, biome, pr.w, w)` inside its own bake path; this file
  is `FacetSkinTier`, the `FP_SKIN_TIER` heightfield tier, currently **not constructed** at runtime per
  `verify_feature`'s 6042/0 pin (task #60 "F1: re-enable skin tier" is still pending). Leaving it on
  `color_for` costs nothing live today; wire it identically to `facet_block_lod_ring.gd` **only when** F1
  re-enables the tier (one extra line, same pattern — noted, not required now).
- `surface_shot.gd:56,68` — `docs/COSMOS-SKIN-BLOCK-EXACT-DESIGN.md` §"color_for KEEP" explicitly deferred
  this ("V2 shot tint pages"); this design keeps the same scoping call for consistency. `surface_shot.gd:53`
  in fact *already* calls `TerrainConfig.top_block_id` for its own separate `top_far_index` path — the
  `color_for` calls at 56/68 are a distinct legacy tint-page path, not touched here.

## 1. The fix: one law, three GDScript-only call groups, **zero engine rebuild**

Because every one of the 9 sites above computes its colour **entirely in GDScript** (`FarPalette.color_for`
is a GDScript static func; the C++ side only supplies `g`/`biome`/`temp`/`dir`/`pos` via `facet_profile` /
`bake_smooth_tile` / the block-LOD pyramid — never a colour), **this closes the entire remaining gap with a
pure-GDScript patch.** This corrects the brief's Q2 premise: there is no new C++ `far_color`/LUT to design.
The C++ block-exact machinery the brief describes (`skin_block_exact` config bool, `deco_far_idx`
LUT, `top_block_id` C++ mirror) **already exists** — it is `FP_SKIN_BLOCK_EXACT` / patch `0011`, and it
already covers the one tier that *does* compute colour in C++ (the fine-map tile bake). Nothing there needs
touching or duplicating.

### 1.1 New primitives (`far_palette.gd`)

```gdscript
## FP_SKIN_BLOCK_COLOR: the worker-safe block-exact colour for a top_block_id — quantised to the SAME
## frozen 14-entry palette (frozen_colors()) the fine map / tile-bake tier already draws from, via the
## SAME precomputed block_id -> index LUT (_block_idx, built main-thread once by ensure_far_index_ready()).
## Pure array reads only — safe to call from a WorkerThreadPool task (facet_far_ring/facet_smooth_v2/
## facet_block_lod_ring's builders all run off-thread; _top_color()/mean_color_of() is NOT worker-safe —
## see the CRITICAL comment on ensure_far_index_ready() — so this is the quantised sibling, not _top_color).
static func color_for_block(block_id: int) -> Color:
	var idx := far_color_index_of_block(block_id)     # pure array read, prewarmed main-thread
	var j := idx * 3
	return Color(_fc_rgb[j], _fc_rgb[j + 1], _fc_rgb[j + 2])
```

Placed directly below `far_color_index_of_block` (after `far_palette.gd:~300`, next to the other
`_fc_rgb`-reading accessors). No new state — `_fc_rgb`/`_block_idx` are already built and resident
(`ensure_far_index_ready`, already called at baker/skin setup prewarm today).

**Why quantised to 14, not the continuous texture mean (`_top_color`/`mean_color_of`):** all 9 call sites
run on a `WorkerThreadPool` task (`facet_far_ring.gd:1802/1830` `_async_build_worker`,
`facet_smooth_v2.gd:434` `_build_worker`, `facet_block_lod_ring.gd:163`'s greedy-mesh worker — confirmed by
grep). `far_palette.gd`'s own `ensure_far_index_ready` doc comment is explicit: `_top_color` "routes through
`BlockTextures.mean_color_of`, which `load()`s a PNG... the first time per tile — that MUST NOT run on the
offloaded... worker (it stalls/faults)." `far_color_index_of_block` is the established worker-safe
sibling (pure `PackedInt32Array` index read over data resolved main-thread); `color_for_block` above reuses
it and adds one more pure array read (`_fc_rgb`, also main-thread-built). This is not a compromise for its
own sake — it is the identical trade the fine-map tile-bake already made (its GDScript AND C++ paths both
emit an *index* into the same 14-entry palette, never a raw texture-mean `Color`, for the same worker-safety
reason). Consequence: `FP_SKIN_BLOCK_COLOR`'s colours will be visually **identical in hue-class** to the
fine map's (same 14 swatches — water/ice/lava/snow/sand/gravel/red_sand/mud/podzol/grass/leaf/stone/taiga/
forest), which is a *feature* here: it removes the residual seam between this fix and the already-shipped
`FP_SKIN_BLOCK_EXACT` fine map, something `FP_FAR_COLOR_UNIFIED`'s continuous blend tints could not
guarantee.

### 1.2 The x,z resolution (brief's Q1) — `FacetAtlas.world_to_lattice64`, already the shipped tool

`profile_at_dir`/`facet_profile` give `(g, biome, t)` from a raw unit direction or `(fid,x,z)` — but 8 of
the 9 sites sample by **continuous world-space direction/point** (`dx,dy,dz` from a bilerp, or a welded
`d: Vector3`), not integer lattice `(x,z)`. `top_block_id`'s only per-column dependency is `_biome_top`'s
`B_TAIGA` podzol-hash speckle (`_hash01_3d(x,0,z,_SALT_PODZOL)`, `terrain_config.gd:2276`) — everything else
in `top_block_id` is a pure function of `(g,biome,t)`. So a *representative* lattice `(x,z)` is enough; it
need not be exact to the sub-block.

`facet_tex_baker.gd:325-329` already solved exactly this for the fine-map bake: it round-trips a **world
point** through `FacetAtlas.world_to_lattice64(fid, wx, wy, wz) -> [lat_x, lat_y, lat_z]` (the inverse of
`cell_dir`) to get an integer `(lx, lz)` for any world-space sample point on that facet. **Reuse the exact
same call, no new primitive.** Every site already computes (or can trivially derive) a world point at the
`g`-independent radius `R_BLOCKS`:

- Sites 2/3 (2273, 3087, 3297) already compute `bx, by, bz` (the bilerp world point) before normalizing to
  `dx,dy,dz` — feed `bx,by,bz` straight into `world_to_lattice64`.
- Site 4 (3373) also computes `bx,by,bz` in the same loop (confirmed) — same treatment.
- Sites 5/6/7 (3428, 3505, 4154/`_weld_node`) work from a welded unit direction `d: Vector3` (no `bx,by,bz`
  in scope) — compute `wx := d.x * FacetAtlas.R_BLOCKS; wy := d.y * FacetAtlas.R_BLOCKS; wz := d.z *
  FacetAtlas.R_BLOCKS` first (f32 precision is fine — this only feeds a speckle hash, not placement).
- Site 8 (`facet_smooth_v2.gd:86`) has only `b_dir[vi]` (C++-baked direction) and `r_datum := FacetAtlas.r_of(fid)`
  (already read at `:59`) — same `d * r_datum` treatment.
- Site 9 (`facet_block_lod_ring.gd:481`) is the **simplest**: `lx`/`lz` (facet-local lattice ints) are
  **already local variables** in the enclosing loop (`facet_block_lod_ring.gd:471-472`,
  `lx := dmin.x + cx*_pitch + half`) — no round-trip needed at all, pass them straight through.

```gdscript
static func _rep_xz(fid: int, wx: float, wy: float, wz: float) -> Vector2i:
	var l := FacetAtlas.world_to_lattice64(fid, wx, wy, wz)
	return Vector2i(int(round(l[0])), int(round(l[2])))
```
(a tiny helper next to `color_for_block`, or inlined at each site — either is fine; inlining avoids a
cross-file call in a hot loop, matching the file's existing style of inlining `_bilerp` math rather than
wrapping it.)

`world_to_lattice64` is already proven worker-safe by precedent: `facet_smooth_v2.gd`'s `build_tile`
(itself worker-dispatched) already calls `FacetAtlas.r_of(fid)` and `FacetAtlas.facet_corner_dirs(fid)` —
reads of the same frozen `FacetAtlas` static frame arrays `world_to_lattice64` reads (`_frame`/`_off`,
`facet_atlas.gd:411-416`). No new worker-safety class.

### 1.3 The per-site edit (mechanical, under `CubeSphere.FP_SKIN_BLOCK_COLOR`)

**IMPLEMENTED** (deviates from the sketch below in one respect, for the better — see the note at the end):
instead of an inline `if/else` duplicated at every call site, the swap law lives in ONE place,
`far_palette.gd`, as two public functions:

```gdscript
## The core law once (x,z) is known. `on` defaults to the compiled const (every production call site is
## unaffected); it is an explicit param ONLY so a gate can drive both branches in one run without
## sed-toggling — the SAME idiom FarPalette._biome_tints(unified: bool) already established.
static func skin_color_at(fid: int, lx: int, lz: int, g: int, biome: int, t: float, on := CubeSphere.FP_SKIN_BLOCK_COLOR) -> Color:
	if on:
		var top_id := TerrainConfig.top_block_id(g, biome, t, lx, lz)
		return color_for_block(top_id)
	return color_for(g, biome, t, g < TerrainConfig.SEA_LEVEL)

## For callers that only have a world-space sample point, not an integer lattice column.
static func skin_color(fid: int, wx: float, wy: float, wz: float, g: int, biome: int, t: float, on := CubeSphere.FP_SKIN_BLOCK_COLOR) -> Color:
	if not on:
		return color_for(g, biome, t, g < TerrainConfig.SEA_LEVEL)
	var l := FacetAtlas.world_to_lattice64(fid, wx, wy, wz)
	return skin_color_at(fid, int(round(l[0])), int(round(l[2])), g, biome, t, on)
```

Every call site becomes a ONE-LINE swap of `FarPalette.color_for(g, biome, t, g < SEA_LEVEL)` for
`FarPalette.skin_color(fid, wx, wy, wz, g, biome, t)` (or `skin_color_at(fid, lx, lz, g, biome, t)` where an
integer lattice column is already local — site 9). Pattern (`facet_far_ring.gd:3087`, representative of
sites 2/3/4):
```gdscript
var node_col := FarPalette.skin_color(fid, bx, by, bz, g, int(prof.y), prof.w)
```
Sites 5/6/7 (weld-direction sites) and site 8 substitute `wx,wy,wz := d.x*R, d.y*R, d.z*R` (R = `R_BLOCKS`
or `r_datum`) for `bx,by,bz`. Site 9 (`facet_block_lod_ring.gd:481`) calls `skin_color_at(fid, lx, lz, ...)`
directly with the already-local `lx,lz` (no `world_to_lattice64` round-trip). Site 1 (`_weld_node`, called
from 5 places) needs one signature change:

```gdscript
# before:
func _weld_node(cd: PackedFloat64Array, s: float, t: float, pos: PackedVector3Array, col: PackedColorArray) -> void:
# after:
func _weld_node(fid: int, cd: PackedFloat64Array, s: float, t: float, pos: PackedVector3Array, col: PackedColorArray) -> void:
```
and its 5 call sites (`facet_far_ring.gd:2247, 3021, 3142, 3165, 3275`) gain a leading `fid` argument — all
5 enclosing functions (`_weld_chord_arrays_n(fid,cells)`, `_weld_chord_arrays(fid)`,
`_ensure_backstop_chord_cached(fid)`, `_ensure_backstop_true_cached(fid)`, `_ensure_backstop_cached(fid,...)`)
already have `fid` as their own parameter, so this is a pure plumb-through, zero new state.

**Why centralized instead of per-file `if/else`:** `facet_smooth_v2.gd` (site 8) needs the identical law
and is a SEPARATE file from `facet_far_ring.gd` — a private `_skin_color` helper in one file is not callable
from the other without breaking the codebase's own privacy convention (leading-underscore = internal). Promoting
the law to `FarPalette` (already the single home for `color_for`/`biome_base`/`sea_color`) avoids duplicating
the branch logic in three files and gives `verify_skin_block_color.gd` one law to gate, not three copies.

### 1.4 Q5 answer — route the WHOLE thing through `top_block_id`, not just the land tail

`color_for`'s `clamped_sea`/snow branches are **not** kept alongside a block-exact land path — `top_block_id`
already resolves sea (ice/lava/water) and snow internally (mirrors exactly what `FP_SKIN_BLOCK_EXACT`'s
`facet_tex_baker.gd:2043-2044` already does: `far_color_index_of_block(TerrainConfig.top_block_id(g,
int(prof.y), prof.w, lx, lz))`, no separate `clamped_sea` test at that call site at all). Justification:
this is the established, already-gated, already-live pattern — matching it trivially keeps the ON branch
byte-identical in *approach* to the fine map (same law, same LUT, same 14 colours), and keeps the diff at
each site to "compute `top_id`, call `color_for_block`" instead of re-deriving a parallel sea/snow branch
that would immediately duplicate logic `top_block_id` already owns.

## 2. Flag (`cube_sphere.gd`, insert directly after `FP_FAR_COLOR_UNIFIED`, i.e. after `cube_sphere.gd:550`)

```gdscript
## FP_SKIN_BLOCK_COLOR (docs/COSMOS-SKIN-BLOCK-COLOR-DESIGN.md) — extends FP_SKIN_BLOCK_EXACT's block-exact
## colour law (far_color_index_of_block(top_block_id(...))) to the THREE color_for consumer groups
## FP_FAR_COLOR_UNIFIED could only approximate: the far-ring shell/backstop/envelope tiers (facet_far_ring.gd,
## 7 call sites), the FacetSmoothV2 relief annulus (facet_smooth_v2.gd:86), and block-LOD (facet_block_lod_ring.gd:481,
## shared by the orbit/global tiers). Pure GDScript — no engine rebuild; the C++ block-exact machinery
## (skin_block_exact / deco_far_idx, patch 0011) already covers the one tier that computes colour in C++ (the
## fine map) and needs no change. Per-column x,z for the taiga-podzol hash speckle resolved via
## FacetAtlas.world_to_lattice64 (the SAME inverse-lattice tool facet_tex_baker.gd already uses) from each
## site's existing world-space sample point; colour resolved via FarPalette.color_for_block, the WORKER-SAFE
## quantised sibling of _top_color (these builders all run on WorkerThreadPool — _top_color/mean_color_of is
## not safe there, see far_palette.gd's ensure_far_index_ready comment). Default false ⇒ every site's else
## branch calls color_for exactly as shipped (byte-identical; FLAT verify_feature.gd unmoved). Requires
## FP_SKIN_BLOCK_EXACT-style semantics but NOT the flag itself (independent — can ship without it, though the
## deploy config baking both keeps every far tier visually consistent). NEVER-OOM: zero new bytes (reuses
## _block_idx / _fc_rgb, already resident). Gate: verify_skin_block_color.gd (G-SBC).
const FP_SKIN_BLOCK_COLOR := false
```

## 3. Gate — `godot/src/tools/verify_skin_block_color.gd` (new file)

Model directly on `verify_far_color_unified.gd`'s G-FCU-OFF/G-FCU-MEAN structure and
`verify_far_smooth.gd`'s `_gate_v2_colour` (G-V2-COLOUR) call pattern, both already read above.

**G-SBC-OFF** (byte-off, mirrors G-FCU-OFF): assert `not CubeSphere.FP_SKIN_BLOCK_COLOR` (default), then for
a sample of ≥ 200 columns spanning all 9 sites' code paths (drive each function directly — they are
GDScript, callable headless without a live scene, exactly as `verify_far_smooth.gd` already drives
`FacetSmoothV2.build_tile` and `facet_far_ring.gd`'s cache builders directly per its existing gates), assert
the emitted colour is **byte-identical** to a same-input `FarPalette.color_for(g, biome, t, g <
TerrainConfig.SEA_LEVEL)` call. This is the flag-off half of every site's `if/else` — a plain regression
pin, not a new law to verify. Plus the standing `verify_feature.gd` FLAT count unmoved (this flag is never
constructed under FLAT).

**G-SBC-ON-DISCRIMINATES** (mirrors the "non-vacuous falsify" discipline `verify_far_smooth.gd`'s
G-V2-COLOUR already applies): pick a facet/tile straddling a **mixed** biome the flag-off path homogenizes —
a savanna region with both open-grass and acacia-tree columns, a taiga tile with podzol/grass speckle, a
mountain facet with both bare-stone peak and dirt-filled lower slopes. Assert: (a) with the flag OFF, every
sampled node in that region gets the SAME `color_for` biome-tint colour (proving the baseline really is
flat); (b) with the flag ON, at least two distinct `frozen_colors()` indices appear among the sampled nodes
(proving `top_block_id`'s per-column classification is actually reaching the vertex colour, not just being
computed and discarded).

**G-SBC-PARITY** (fine-map agreement — kills the residual tier seam): for a set of directions common to both
a `color_for_block`-driven site (e.g. `facet_smooth_v2.gd`'s `build_tile`) and the fine-map bake
(`facet_tex_baker.gd`'s `_gd_ref`/`sample_fine`, or `verify_tile_bake.gd`'s existing `_gd_ref` oracle),
assert the two resolve to the **same `frozen_colors()` index** for the same `(g,biome,t,x,z)` — both routes
now terminate in the identical `far_color_index_of_block(top_block_id(...))` call, so this should be an
exact index match, not a tolerance band (unlike G-FCU-MEAN's `≤4/255` statistical check — this law is
deterministic, not a blend).

**G-SBC-WORKER-SAFE** (documents the design decision as a falsifiable check, not just a comment): grep-assert
(a static source check, same technique `verify_facet_seams.gd`/other gates already use for law-shape
assertions) that no call to `FarPalette._top_color(` or `BlockTextures.mean_color_of(` appears inside
`facet_far_ring.gd`, `facet_smooth_v2.gd`, or `facet_block_lod_ring.gd` under the new branches — i.e. the ON
path only ever calls `color_for_block`/`far_color_index_of_block`, never the texture-loading path.

## 4. NEVER-OOM (brief's Q4)

Zero new resident bytes. `color_for_block` and the per-site `_rep_xz` derivation allocate nothing beyond a
few locals (`Vector2i`, a 3-float `Array` from `world_to_lattice64`) — no new arrays, no new caches, no new
LUT. `_block_idx` (`PackedInt32Array`, `BlockCatalog.count()` entries ≈ a few hundred × 4 B ≈ 1-2 KB) and
`_fc_rgb` (14×3 floats ≈ 168 B) are **already resident**, built once by the existing
`ensure_far_index_ready()` prewarm the fine-map/tile-bake path already triggers at setup. This design adds
no new prewarm call, no new config dict field, no new patch — it is strictly a consumer of state that
already exists and is already paid for.

## 5. Rollout order and why this is *cheaper* than the brief assumed

1. `FP_SKIN_BLOCK_COLOR` is a **single PR, GDScript-only, no `scripts/build.sh` rebuild** (contra the
   brief's Q2, which expected a ~24-minute engine rebuild for a new C++ LUT + config bool). The reason: this
   flag's 9 sites never called into C++ for colour in the first place — only `g`/`biome`/`temp`/`dir` cross
   the C++ boundary, and the block-exact colour law is applied entirely on the GDScript side, symmetrically
   with how `facet_tex_baker.gd`'s own GDScript-only P0 branch (`FP_SKIN_BLOCK_EXACT` before patch 0011
   landed) worked before its C++ mirror was added for the *tiled/fast* bake path specifically.
2. Land `FP_SKIN_BLOCK_COLOR` alone first, gate green, eyeball at orbit (does the savanna/taiga/mountain
   vertex-colour tiers now show per-column variation matching the fine map, not a flat tint) — this is the
   directive's literal ask ("each far pixel... its respective surface block's... colour").
3. Because `FP_SKIN_BLOCK_COLOR`'s ON colours are now **exactly** `far_color_index_of_block(top_block_id(...))`
   — the same law `FP_SKIN_BLOCK_EXACT`'s fine map already uses — `FP_FAR_COLOR_UNIFIED` becomes redundant
   *for any tier this flag also covers* once both are on (both converge on the same per-column truth rather
   than `FP_FAR_COLOR_UNIFIED`'s statistical proxy). Not a reason to remove `FP_FAR_COLOR_UNIFIED` (it still
   matters for anything this flag doesn't reach, and for flag-combination A/B safety), but worth noting in
   the deploy config comment when both are baked on together.
4. Deploy config (export bake): `FP_SKIN_BLOCK_EXACT ∧ FP_SKIN_BLOCK_COLOR ∧ FP_SKIN_TEXTURE_MEAN` together
   give ONE block-exact colour law across every far tier — fine map, shell/backstop/envelope, V2 annulus,
   block-LOD — closing the directive fully, not just for the tiers `FP_SKIN_BLOCK_EXACT` alone reached.
