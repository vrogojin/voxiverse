class_name SurfaceShot
extends RefCounted
## COSMOS TEXTURED-LOD §2V.1 — the ONE source function of the real-shot skin pyramid (docs/COSMOS-TEXTURED-LOD-
## DESIGN.md §2V "One source function"). `surface_shot(fid, x, z)` returns, for a single lattice column, the
## per-column record `{block_id, tint, shade}` that BOTH the band shot (V2) and the page rebake (V3) downscale/
## store. It is the analytic COMPOSITE the near daylight material would show top-down (§2V.0 (B)): the exposed
## top material — terrain via the EXISTING classifier chain (FarPalette.color_for → detail_pattern), decorations
## composited on top via TreeGen.top_decoration — times its vertex tint, times the SUN-INDEPENDENT depth cues.
##
##   block_id : the detail-PATTERN id (1..DETAIL_PATTERNS; 0 reserved un-baked) the base/band already store, of
##              the EXPOSED top block. Bare terrain classifies its top-block colour; a column TreeGen decorates
##              classifies the canopy/trunk block's colour instead (the leaf reads as P_LEAF, etc.).
##   tint     : the exposed top block's per-vertex colour (v_col) — the same tint the near mesh applies.
##   shade    : the SUN-INDEPENDENT photographic depth cues the id×tiles trick lacked (§2V.1), in [0,1]:
##              analytic AO / hillshade from neighbour column height deltas (cliff-base darkening), canopy
##              ground-shadow under trees, water-depth darkening. SUN shading is NEVER baked here — it is applied
##              live by the unified lighting law (§2V.3). `shade` therefore holds ONLY static cues (single-owner
##              rule, §2V.6 F4) so it never double-darkens with dynamic sun/moon lighting.
##
## Pure + deterministic (only TerrainConfig / TreeGen / FarPalette / BlockCatalog — no randi/Time), so a given
## (facet-context, x, z) always yields the same record on every render path. `fid` names the facet the shot is
## for; the terrain + tree math resolves against the facet carried by `pcache` (a GenCtx scoped to a facet) or,
## when `pcache` is null, the active facet — the caller sets that to `fid` so both agree.
##
## §2V PREP: this module is FOUNDATION only. Nothing in the running engine calls it yet (byte-identical, inert);
## the V2/V3 baker paths fan out on top of it behind their own FP_ flags.

# --- analytic shade tuning (sun-independent) -----------------------------------------------------------------
const SHADE_FLOOR := 0.15          # a shadowed column never goes fully black (a photo keeps detail in shadow)
const AO_SLOPE_K := 0.045          # hillshade: darkening per block of total central-difference slope |∂g|
const AO_SLOPE_MAX := 0.45
const AO_CONCAVE_K := 0.030        # extra darkening where the column sits BELOW its neighbours (cliff / pit base)
const AO_CONCAVE_MAX := 0.35
const WATER_DEPTH_K := 0.030       # darkening per block the sea floor lies below sea level (deep water reads dark)
const WATER_DEPTH_MAX := 0.55
const CANOPY_SHADOW := 0.07        # ground-shadow darkening per cardinal neighbour that is a tree canopy / trunk
const CANOPY_SHADOW_MAX := 0.28

## The exposed top column's FLAT-COLOUR palette index (into FarPalette.frozen_colors, 0..13) for lattice column
## (x, z) — what the FP_SKIN_FLATCOLOR band + whole-planet fine tiers store. Classifies the top COLOUR directly
## via far_color_index (the same nearest-palette rule the base/skin path at facet_tex_baker:1315 uses), NOT the
## broken `far_color_index_of_block(detail_pattern(col)+1)` chain the fine bake used before — that fed a detail-
## PATTERN id into a block-ID LUT, so open water classified to MUD, sand to STONE, etc. (grass matched only by
## coincidence). Computed WITHOUT the sun-independent AO shade (the L8 tiers discard it), so ~5-6× cheaper than
## surface_shot — the decisive speedup on a low-core browser. far_color_index must be prewarmed on main (the
## baker does, ensure_far_index_ready) so this stays worker-safe (pure _fc_rgb read).
static func top_far_index(x: int, z: int, pcache = null) -> int:
	var prof := TerrainConfig.column_profile(x, z, pcache)   # Vector4(g, biome, continent, temperature)
	var g := int(prof.x)
	var tree_id := TreeGen.top_decoration(x, z, pcache)
	if CubeSphere.FP_SKIN_BLOCK_EXACT:
		# far colour = the ACTUAL top block's texture mean (tree block, else the surface block) — matches the near field.
		var bid := tree_id if tree_id != BlockCatalog.AIR else TerrainConfig.top_block_id(g, int(prof.y), prof.w, x, z)
		return FarPalette.far_color_index_of_block(bid)
	var clamped_sea := g < TerrainConfig.SEA_LEVEL
	var terr_col := FarPalette.color_for(g, int(prof.y), prof.w, clamped_sea)
	var top_col: Color = BlockCatalog.color_of(tree_id) if tree_id != BlockCatalog.AIR else terr_col
	return FarPalette.far_color_index(top_col)

## THE source record for lattice column (x, z) on facet `fid`. See the file header for the field contract.
static func surface_shot(fid: int, x: int, z: int, pcache = null) -> Dictionary:
	FarPalette.ensure_detail_ready()
	var prof := TerrainConfig.column_profile(x, z, pcache)   # Vector4(g, biome, continent, temperature)
	var g := int(prof.x)
	var biome := int(prof.y)
	var t := prof.w
	var clamped_sea := g < TerrainConfig.SEA_LEVEL
	var terr_col := FarPalette.color_for(g, biome, t, clamped_sea)
	# Composite the exposed decoration: if TreeGen puts a canopy/trunk over this column, THAT block is the top.
	var tree_id := TreeGen.top_decoration(x, z, pcache)
	var is_tree := tree_id != BlockCatalog.AIR
	var top_col: Color = BlockCatalog.color_of(tree_id) if is_tree else terr_col
	var block_id := FarPalette.detail_pattern(top_col) + 1
	var shade := _shade(fid, x, z, g, is_tree, clamped_sea, pcache)
	return {"block_id": block_id, "tint": top_col, "shade": shade}

## The sun-independent analytic shade byte in [SHADE_FLOOR, 1] for column (x, z). 1.0 = a flat, dry, un-shadowed
## interior column (the un-darkened reference); the cues subtract from it. All queries are pure TerrainConfig /
## TreeGen (deterministic), and every neighbour resolves on the SAME facet context via `pcache`.
static func _shade(fid: int, x: int, z: int, g: int, is_tree: bool, clamped_sea: bool, pcache = null) -> float:
	# (a) hillshade / AO from the 4-neighbour column-height stencil (cliff-base & slope darkening).
	var gE := int(TerrainConfig.column_profile(x + 1, z, pcache).x)
	var gW := int(TerrainConfig.column_profile(x - 1, z, pcache).x)
	var gN := int(TerrainConfig.column_profile(x, z + 1, pcache).x)
	var gS := int(TerrainConfig.column_profile(x, z - 1, pcache).x)
	var slope := absi(gE - gW) + absi(gN - gS)              # central-difference gradient magnitude (blocks)
	var concave := (gE + gW + gN + gS) - 4 * g              # >0 ⇒ column below its neighbours (in a hollow)
	var s := 1.0
	s -= minf(float(slope) * AO_SLOPE_K, AO_SLOPE_MAX)
	s -= minf(float(maxi(concave, 0)) * AO_CONCAVE_K, AO_CONCAVE_MAX)
	# (b) water-depth darkening — deeper sea floor reads darker (open water absorbs). Only for submerged columns.
	if clamped_sea:
		s -= minf(float(TerrainConfig.SEA_LEVEL - g) * WATER_DEPTH_K, WATER_DEPTH_MAX)
	# (c) canopy ground-shadow — a GROUND column adjacent to a canopy sits in its penumbra. Tree-top columns ARE
	# the canopy (lit), so they take no ground shadow.
	if not is_tree:
		var near := 0
		if TreeGen.top_decoration(x + 1, z, pcache) != BlockCatalog.AIR: near += 1
		if TreeGen.top_decoration(x - 1, z, pcache) != BlockCatalog.AIR: near += 1
		if TreeGen.top_decoration(x, z + 1, pcache) != BlockCatalog.AIR: near += 1
		if TreeGen.top_decoration(x, z - 1, pcache) != BlockCatalog.AIR: near += 1
		s -= minf(float(near) * CANOPY_SHADOW, CANOPY_SHADOW_MAX)
	return clampf(s, SHADE_FLOOR, 1.0)

## FP_SKIN_SHADE_PACK (docs/COSMOS-SKIN-SHADE-PACK): THE canonical quantiser of `_shade`'s [0.15, 1] value to the
## 18 packed steps (shade_q ∈ [0, 17]; decode = 0.15 + 0.85·q/17). LITERALS ARE LOAD-BEARING: the C++ bake
## (patch 0014 bake_far_tile) spells the IDENTICAL `floor((s - 0.15) / 0.85 * 17.0 + 0.5)` — note `1.0 - 0.15`
## is NOT bit-equal to the literal `0.85` in f64, so both sides must keep the literals, not derive them. Pure +
## inert flag-off (nothing calls it); the packed byte is `1 + far_idx + 14·q` (CubeSphere.SHADE_PACK_LANES).
static func shade_q(s: float) -> int:
	return clampi(int(floor((s - 0.15) / 0.85 * 17.0 + 0.5)), 0, CubeSphere.SHADE_PACK_STEPS - 1)
