# COSMOS FACET COLOUR SEAM — root cause + minimal fix design

**Defect (live, user-observed):** in FAR render mode (orbit / high altitude), two adjacent facets
show inconsistent colour — a visible colour seam along the shared facet edge.

**Verdict up front:** this is **not** an intra-tier bake seam and **not** a per-facet-centre
lighting bug. It is a **facet-aligned TIER-FRONTIER law mismatch**: the far surface at altitude is
a patchwork of per-facet tiers (smooth-V2 annulus, blocky block-LOD facets, fine-map shell), whose
residency boundaries are facet edges *by construction* — and the tiers disagree on (a) the **colour
law** (biome blend-tints vs the block-exact palette) and (b) the **lighting law** (per-cell relief
normals vs the planet-radial normal). Wherever two adjacent facets are owned by different tiers,
the whole-facet colour/brightness jumps exactly at the shared edge.

---

## 1. The three suspicions, adjudicated against the code

### 1.1 Suspicion 1 — per-facet bake sampling direction: REAL but sub-texel (dismissed as the cause)

The colour bakes do use the per-facet planarized corners, not the P0 canon:

- `facet_tex_baker.gd:326-331` (`sample_fine`), `:432-438` (`sample_fine_shot`), `:1821-1824`
  (band dispatch) and `:1851-1856` (fine-map dispatch) all derive the bake footprint from
  `FacetAtlas.facet_planar_corner(fid, ci)` → `world_to_lattice64`, then bilerp param → lattice
  (`:1937-1938`, `:1969-1970`).
- `facet_atlas.gd:418-424` documents exactly why planar corners disagree at a shared edge
  (each facet's own planarized projection), and `far_density.gd:10-17, 41-44` records the P0 fix
  that re-routed `node_at` through the shared canon `FacetAtlas.facet_corner_dirs` (:425-436).

So the two facets *do* sample slightly different world points along the shared edge — the exact
class the team lead suspected. **But the magnitude is bounded and sub-texel.** The planarization
displaces a corner by the sagitta (≈ 6.8 blocks at R=6371, K=24) *along the facet normal*; the
tangential component of that displacement — the only part that moves the sampled world point — is
≈ 6.8 · sin(2.65°) ≈ **0.31 blocks** per facet (2.65° = the half-diagonal angle of a 417-block
facet), so the worst cross-edge disagreement is ≈ 0.6 blocks, opposite senses. Compare texel
pitches: fine map = 417/128 ≈ 3.3 blocks/texel, band = 1 block/texel; and the bake already rounds
lattice coords to integers (±0.5 block quantization, `:1969-1970`). A ≤ 0.6-block sampling skew can
flip a *discrete* `FarPalette` classification only where a biome/sea/snow boundary passes within
0.6 blocks of the shared edge — a sparse 1-texel stipple, **not** a facet-length colour seam.
Recommendation: leave it (see §4.3) — measured, disclosed, not the defect.

### 1.2 Suspicion 2 — discrete classification at the boundary: same bound

`FarPalette.far_color_index` / `detail_pattern` (far_palette.gd:168-189, :272-285) are
nearest-colour classifiers over the frozen palette; they amplify the §1.1 skew into hard index
flips, but only within the same ≤ 1-texel corridor. Additionally, the fine map's own addressing is
seam-free by construction: the shader indexes it in **face-uniform param space**
(`_FLAT_ALBEDO_META_FINE`, facet_far_ring.gd:4380-4383 — `v_uv = ((a+s)/K,(b+t)/K)` from the
welded mesh, `texelFetch` + `filter_nearest`, facet_far_ring.gd:4345), the bake fills texel
centres in the same param space (facet_tex_baker.gd:1965-1970), and quadrant sub-page boundaries
(`_fine_commit`, :1730-1741) are `texelFetch`-addressed, so no bilinear filtering ever crosses (or
fails to cross) a layer boundary. Dismissed as the observed cause.

### 1.3 Suspicion 3 — per-facet lighting centre: AFFIRMATIVELY ABSENT in the far shell

Every `FP_SHELL_ABSOLUTE` shell variant derives its shading normal as
`n = normalize(wp − centre)` with `centre = (MODEL_MATRIX · vec4(0,0,0,1)).xyz`
(facet_far_ring.gd:4084-4085, :4118-4119, :4181-4182) — the exact planet centre, per-fragment,
not a per-facet centre. The FP_NIGHT_TERRAIN_CENTRE class bug (near shader's `normalize(v_wp)`
assuming centre = origin) does **not** exist here. The `FacetSmoothV2` shader does the same
(facet_smooth_v2.gd:256-258). The block-LOD tiers explicitly share "ONE shade law … radial-normal
shell shade·tint" (facet_block_lod_orbit.gd:16-20). Per-facet-centre lighting is not the cause.

---

## 2. The actual root cause: facet-aligned tier frontiers with mismatched laws

### 2.1 Why every frontier is a facet edge

At high altitude the visible surface is partitioned **per facet** between:

1. **FacetSmoothV2 annulus** — resident set = hop-BFS annulus `hop ∈ [V2_HOP_B=2 .. V2_HOP_H(_REACH)=3/4]`
   over `FacetAtlas.seam_neighbour` around the active facet (facet_smooth_v2.gd:171-194,
   cube_sphere.gd:1168-1186). Pure per-facet residency; drawn always — there is **no off-surface
   hide** (`setup_instance` at facet_far_ring.gd:470-471, stepped unconditionally at :1240-1241).
2. **Blocky far-ring / block-LOD megablock facets** — suppressed per facet where V2 is resident
   (`FP_SMOOTH_V2_EXCL_BLKLOD`, facet_far_ring.gd:2686, :1725-1731).
3. **The shell + whole-planet fine map** — everywhere underneath / beyond
   (`_FLAT_ALBEDO_META_FINE`, facet_far_ring.gd:4374-4405).

Residency, suppression, and promotion are all keyed on `fid`. So *any* law disagreement between
two tiers manifests exactly as "two adjacent facets show inconsistent colour, discontinuity along
the shared facet edge" — the user's observation, verbatim.

### 2.2 Mismatch A — TWO COLOUR LAWS (day AND night)

**Law 1 (block-exact), used by the fine map** (`FP_SKIN_BLOCK_EXACT`): texel colour index =
`far_color_index_of_block(top_block_id(g,biome,t,x,z))`, trees composited per column via
`TreeGen.top_decoration` (facet_tex_baker.gd:1976-1993; same law in the C++ `bake_far_tile`,
byte-equal by gate). Crucially, `_biome_top` returns **`BlockCatalog.GRASS` for B_SAVANNA,
B_FOREST, B_JUNGLE and B_PLAINS** (terrain_config.gd:2238-2255, the default `_` arm) — so on the
fine map those biomes read **grass-green** with sparse canopy-coloured texels.

**Law 2 (biome blend-tints), used by every `color_for` tier**: `FarPalette.color_for` →
`biome_base` returns the *compensation* tints (far_palette.gd:61-71, :90-116):
`_savanna = _grass.lerp(_sand, 0.40)` (**tan**), `_forest = _grass.lerp(_leaf, 0.35)`,
`_jungle = _grass.lerp(jungle_leaves, 0.55)`, `_taiga = _grass.lerp(_podzol, 0.20)`.
Consumers: FacetSmoothV2 tiles (facet_smooth_v2.gd:86), block-LOD rings
(facet_block_lod_ring.gd:481), orbit/global tiers (facet_block_lod_orbit.gd:109,
facet_block_lod_global.gd:78), and the shell's own vertex colours.

**Consequence:** a savanna facet is TAN on a `color_for` tier and GREEN on the fine-map shell; a
jungle facet is deep-green vs bright-grass-plus-speckle; forest differs by the 0.35 leaf blend vs
actual canopy coverage. The colour difference is *whole-facet* and *systematic*, bounded by the
shared facet edge — a blatant colour seam. Because it is baked/vertex COLOUR (both sides then get
the same `v_st` radial shade·tint), **it persists day AND night**.

### 2.3 Mismatch B — TWO LIGHTING LAWS (day/terminator only)

Under `FP_SMOOTH_V2_LIT` (cube_sphere.gd:1180), V2 cells shade with their **own geometric face
normal** (provoking-vertex flat shade, facet_smooth_v2.gd:108-120, shader tail :275-283:
`n = normalize((MODEL_MATRIX · vec4(NORMAL,0)).xyz)`), while every neighbouring tier — shell,
block-LOD, TierPlace — shades with the **relief-blind planet-radial** normal (§1.3). At any sun
angle off-zenith, sloped terrain inside the V2 annulus reads brighter/darker than the *identical*
terrain across the hop boundary → a brightness seam along the annulus's inner (hop 2) and outer
(hop 3/4) facet edges. This component **vanishes at night** (both laws collapse to `night_floor`)
and **flips with sun azimuth**.

### 2.4 Mismatch C — transient fill frontiers (converges; no new fix)

While the fine map is mid-fill (`_fine_baked` sweep, facet_tex_baker.gd:1704-1741; note
`FP_FINE_BAKE_SURFACE_PAUSE` pauses new fine dispatch on-surface, :1836-1844), an un-baked facet
falls back to the pale base/vertex colour next to a baked neighbour. Likewise g0-palette vs g1-shot
base pages (:58-68) — only visible where fine is un-baked. These converge in ~30-60 s at orbit and
already have the universal-fine-fallback mitigation (facet_far_ring.gd:4374-4379). Discriminator:
if the user's seam fades after a minute in orbit, it was this; no further work.

### 2.5 Discriminator for the user (the team lead's day/night question)

- Seam persists at **night**, strongest in savanna/jungle/forest latitude bands, colour (hue)
  differs → **Mismatch A** (colour law).
- Seam is a **brightness** step that disappears at night / flips side with sun azimuth, hugging
  the 2-hop..4-hop ring around the sub-player facet → **Mismatch B** (lighting law).
- Seam **fades after ~1 minute** at orbit → Mismatch C (transient fill; already mitigated).

---

## 3. Fix design (flag-gated, byte-identical off, NEVER-OOM)

### 3.1 `FP_FAR_COLOR_UNIFIED` — one far colour law (fixes Mismatch A)

**Idea:** make `color_for`'s biome tints equal, by construction, to the **expected value of the
block-exact law** for that biome — then every `color_for` tier and the fine map agree on the mean
colour of any region, and the tier frontier becomes invisible in colour. One place, zero
per-vertex cost, fixes V2 + all block-LOD tiers + shell vertex colours simultaneously.

**Change (far_palette.gd, `ensure_ready`, under the flag):** derive the four blend tints from the
same block-exact sources the fine map classifies to, weighted by the biome's *actual* deterministic
tree coverage instead of the hand-tuned lerp factors:

```
_savanna = _grass.lerp(acacia_canopy_mean, SAVANNA_TREE_COVER)   # ≈ 0.02-0.05, from TreeGen density
_forest  = _grass.lerp(_leaf,              FOREST_TREE_COVER)
_jungle  = _grass.lerp(jungle_leaves_mean, JUNGLE_TREE_COVER)
_taiga   = unchanged (already the exact 20% podzol hash mean, matches block-exact statistically)
```

`_grass`/`_leaf` etc. already route through `_top_color` → `BlockTextures.mean_color_of` under
`FP_SKIN_TEXTURE_MEAN` (far_palette.gd:40-43), so both laws draw from the same tile-mean colour
source. The `*_TREE_COVER` consts are named, derived once from the TreeGen per-biome density
constants (documented next to them), not eyeballed. Flag off ⇒ `ensure_ready` computes the shipped
lerps verbatim (byte-identical; FLAT verify_feature 6042/0 — `color_for` is exercised there).
NEVER-OOM: a few `Color` values, zero allocations.

**Files touched:** `far_palette.gd` (the four tint lines under the flag), `cube_sphere.gd` (the
`const FP_FAR_COLOR_UNIFIED := false` + doc block). Nothing else — every consumer picks it up
through `color_for`.

**Gate (falsifiable), `verify_far_color_unified.gd` G-FCU:** for each of
{savanna, forest, jungle, taiga}: synthesize ≥ 4096 columns of that biome through the *fine-bake
law itself* (the exact `_pbm_compute` GDScript branch: `top_block_id` + `top_decoration` →
`far_color_index*` → `frozen_colors()` colour), average them, and assert
`|mean − color_for(g, biome, t, false)| ≤ 4/255` per channel with the flag on; assert the shipped
tints byte-exact with it off. Plus FLAT 6042/0 off.

### 3.2 `FP_V2_LIT_EDGE_FEATHER` — feather the lighting law at the annulus boundary (fixes Mismatch B)

**Idea:** the V2 relief-lit normal is correct *inside* the annulus; the seam exists only because
the law changes abruptly at a facet edge. So feather: for tiles whose seam-neighbour across an
edge is **not** in the V2 want-set, ramp the provoking-cell normal from the cell face normal back
to the radial `dir` over the last `FEATHER_CELLS` (≈ 6 of 52) cell rows before that edge. The
boundary row then shades **exactly radial** — identical to the blocky/shell neighbour — and the
frontier is invisible by construction; interior relief lighting is untouched.

**Change (facet_smooth_v2.gd):** `build_tile(fid, cells, gen, radial_edges := 0)` gains a 4-bit
mask (E/W/N/S edges whose `FacetAtlas.seam_neighbour(fid, slot)` ∉ want — computed by the
dispatcher in `step()` from `_want`, pure, main-thread). Inside the existing `FP_SMOOTH_V2_LIT`
block (:114-120), after computing `fn`, apply
`fn = fn.slerp(nrm_radial, w)` where `w` ramps 0→1 over the masked edge's feather band (use the
already-known `gi/gj` vs `cells`). Flag off ⇒ mask never computed/passed, `build_tile` body
byte-identical. NEVER-OOM: one int per dispatch.

**Files touched:** `facet_smooth_v2.gd` (`build_tile` signature default + the feather lines,
`step()` mask computation), `cube_sphere.gd` (`const FP_V2_LIT_EDGE_FEATHER := false` +
`V2_LIT_FEATHER_CELLS := 6`).

**Gate, in `verify_far_smooth.gd` (G-V2-FEATH):** build one tile with `radial_edges = EAST` under
forced LIT+feather: assert every provoking node in the last cell column has
`nrm[v11] == b_dir[v11]` within 1e-6, and interior (beyond the band) normals byte-equal the
unfeathered build; with the flag off assert the whole tile byte-equal to shipped. Plus FLAT 6042/0.

### 3.3 Explicitly NOT fixed (with reasons)

- **Planar-corner bake footprints** (§1.1): bounded ≤ 0.6 blocks ⇒ ≤ 1-texel stipple; re-routing
  the bake's param→lattice map through `facet_corner_dirs` would change every baked texel (a
  planet-wide re-verify) to remove an invisible artefact. Leave; re-visit only if a gate ever
  shows a facet-length classification run at an edge.
- **Fine-map quadrant/page boundaries**: `texelFetch`+nearest in uniform param space — seam-free
  by construction (§1.2). No change.
- **Shell lighting centre**: already exact (§1.3). No change.

### 3.4 Rollout order

1. `FP_FAR_COLOR_UNIFIED` first — it explains a day-and-night, hue-level "inconsistent COLOUR"
   report, and is the cheaper, wider-reaching fix.
2. `FP_V2_LIT_EDGE_FEATHER` second, after the user's day/night answer confirms a brightness
   component.
3. Both default-off, baked ON at export only after their gates + FLAT 6042/0 pass, per the
   standard flag discipline.
