extends SceneTree
## COSMOS FACET-COLOUR-SEAM gate (docs/COSMOS-FACET-COLOUR-SEAM-DESIGN.md §3.1, flag CubeSphere.FP_FAR_COLOR_UNIFIED).
## Proves that FarPalette._biome_tints(true) — the recomputed savanna/forest/jungle biome tints — equals, within a
## small tolerance, the EXPECTED (mean) colour of the block-exact fine-map law (facet_tex_baker.gd's `_pbm_compute`
## GDScript branch: TerrainConfig.top_block_id + TreeGen top-down decoration → FarPalette.far_color_index_of_block →
## frozen_colors()), and that the flag OFF reproduces the shipped hand-tuned lerps byte-exact.
##
## Runs with the SHIPPED default flags (no sed-toggle needed, per the design's §3.1 gate note): `_biome_tints` is a
## pure function of a bool param, so this gate drives BOTH branches directly without touching CubeSphere.
## FP_CLIMATE_BIOMES stays OFF too — TreeGen._species_for's savanna/jungle arms are gated behind that flag (only
## meaningful once climate biomes ship), so this gate transcribes those two match arms LOCALLY (`_species_for_biome`,
## same hash calls/salts/thresholds as tree_gen.gd:105-125 — the same "verbatim shipped-law transcription" pattern
## verify_climate.gd's `_shipped_biome` already uses in this repo) rather than requiring a second compiled config.
## Every other step (existence gate, base position, canopy SHAPE, ground block) drives the REAL TreeGen/TerrainConfig
## statics directly.
##
## Gates:
##   G-FCU-OFF   — FP_FAR_COLOR_UNIFIED defaults false; `_biome_tints(false)` == the shipped hand-tuned lerps,
##                 transcribed verbatim, AND == what a real `ensure_ready()` (default flags) actually populates.
##   G-FCU-MEAN  — for each of {savanna, forest, jungle, taiga}: the mean colour of ≥4096 synthesized columns
##                 through the exact fine-bake law is within 4/255 per channel of `_biome_tints(true)`'s tint.
##
## RUN:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_far_color_unified.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const TC := preload("res://src/world/terrain_config.gd")
const TG := preload("res://src/world/tree_gen.gd")
const FP := preload("res://src/world/far/far_palette.gd")

const _GY := 40             # arbitrary base surface well above sea level (mirrors verify_climate.gd's G-B1-TREES gy=40)
const _T := 0.5              # warm temperate climate value: surface_temperature(40, 0.5) > 0 -> no snow-cap override
const _N_SIDE := 512         # 512x512 columns/biome (262144 >> 4096); spans ~102x102 tree-grid cells / ~20x20 patches
const _TOL := 4.0 / 255.0

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_far_color_unified (COSMOS FACET-COLOUR-SEAM §3.1, FP_FAR_COLOR_UNIFIED) ===")
	TC._ensure_noise()
	TC._ensure_ids()
	TG.warm_up()
	FP.ensure_ready()
	FP.ensure_far_index_ready()   # far_color_index_of_block is worker-safe (no self-warm) — the LUT must be built here first
	print("  CubeSphere.FP_FAR_COLOR_UNIFIED = %s (compile-time; gate drives both branches via _biome_tints)" % str(CubeSphere.FP_FAR_COLOR_UNIFIED))

	_gate_off()
	_gate_mean(TC.B_SAVANNA, "savanna")
	_gate_mean(TC.B_FOREST, "forest")
	_gate_mean(TC.B_JUNGLE, "jungle")
	_gate_mean(TC.B_TAIGA, "taiga")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- G-FCU-OFF: flag off reproduces the shipped lerps byte-exact ----------
func _gate_off() -> void:
	print("  --- G-FCU-OFF: FP_FAR_COLOR_UNIFIED defaults false; OFF branch byte-exact to shipped ---")
	_ok(not CubeSphere.FP_FAR_COLOR_UNIFIED, "G-FCU-OFF: FP_FAR_COLOR_UNIFIED defaults false")
	# Shipped hand-tuned lerps, transcribed verbatim from far_palette.gd's pre-§3.1 ensure_ready (the byte-identity
	# proof, same pattern as verify_climate.gd's _shipped_biome).
	var shipped_taiga: Color = FP._grass.lerp(FP._podzol, 0.20)
	var shipped_forest: Color = FP._grass.lerp(FP._leaf, 0.35)
	var shipped_savanna: Color = FP._grass.lerp(FP._sand, 0.40)
	var shipped_jungle: Color = FP._grass.lerp(FP._top_color(BlockCatalog.id_of(&"jungle_leaves")), 0.55)
	var off: Array[Color] = FP._biome_tints(false)
	_ok(off[0] == shipped_taiga, "G-FCU-OFF: _biome_tints(false) taiga == shipped grass.lerp(podzol, 0.20)")
	_ok(off[1] == shipped_forest, "G-FCU-OFF: _biome_tints(false) forest == shipped grass.lerp(leaf, 0.35)")
	_ok(off[2] == shipped_savanna, "G-FCU-OFF: _biome_tints(false) savanna == shipped grass.lerp(sand, 0.40)")
	_ok(off[3] == shipped_jungle, "G-FCU-OFF: _biome_tints(false) jungle == shipped grass.lerp(jungle_leaves, 0.55)")
	# A real ensure_ready() run (default compiled flags) must have populated exactly this OFF branch.
	_ok(FP._taiga == shipped_taiga and FP._forest == shipped_forest and FP._savanna == shipped_savanna and FP._jungle == shipped_jungle,
		"G-FCU-OFF: ensure_ready() (default flags) actually populated the shipped OFF tints")

# ---------- G-FCU-MEAN: the ON tint matches the fine-bake law's expected colour ----------
func _gate_mean(biome: int, label: String) -> void:
	print("  --- G-FCU-MEAN (%s): fine-bake-law mean vs _biome_tints(true) ---" % label)
	var mean := _fine_mean(biome)
	var on: Array[Color] = FP._biome_tints(true)
	var tint: Color = on[_tint_index(biome)]
	var dr := absf(mean.r - tint.r)
	var dg := absf(mean.g - tint.g)
	var db := absf(mean.b - tint.b)
	print("    %s: fine-mean=(%.4f,%.4f,%.4f) unified-tint=(%.4f,%.4f,%.4f) delta=(%.4f,%.4f,%.4f) (tol %.4f)" %
		[label, mean.r, mean.g, mean.b, tint.r, tint.g, tint.b, dr, dg, db, _TOL])
	_ok(dr <= _TOL and dg <= _TOL and db <= _TOL,
		"G-FCU-MEAN: %s fine-bake mean within 4/255 of the unified tint per channel" % label)

func _tint_index(biome: int) -> int:
	# _biome_tints returns [taiga, forest, savanna, jungle].
	if biome == TC.B_FOREST: return 1
	if biome == TC.B_SAVANNA: return 2
	if biome == TC.B_JUNGLE: return 3
	return 0   # TC.B_TAIGA

# ---------- The fine-bake law, reproduced from facet_tex_baker.gd's _pbm_compute (FP_SKIN_BLOCK_EXACT branch) ----------

func _fine_mean(biome: int) -> Color:
	var sr := 0.0
	var sg := 0.0
	var sb := 0.0
	var n := 0
	for x in range(0, _N_SIDE):
		for z in range(0, _N_SIDE):
			var c := _fine_column_color(biome, x, z)
			sr += c.r
			sg += c.g
			sb += c.b
			n += 1
	return Color(sr / float(n), sg / float(n), sb / float(n), 1.0)

## One column of the exact `_pbm_compute` FP_SKIN_BLOCK_EXACT branch (facet_tex_baker.gd:1976-1993): tree/edit
## decoration wins (far_color_index_of_block(deco)); else the actual top block (far_color_index_of_block(top_block_id)).
func _fine_column_color(biome: int, x: int, z: int) -> Color:
	var deco := _decoration_for(biome, x, z)
	var fi: int
	if deco != BlockCatalog.AIR:
		fi = FP.far_color_index_of_block(deco)
	else:
		var top := TC.top_block_id(_GY, biome, _T, x, z)
		fi = FP.far_color_index_of_block(top)
	return FP.frozen_colors()[fi]

## Mirrors TreeGen.top_decoration (tree_gen.gd:208-224): the existence gate (has_tree, tree_gen.gd:130-138) is the
## REAL production hashes/consts; species is resolved via `_species_for_biome` (below) instead of
## `TerrainConfig.biome_at` so the biome under test is FORCED rather than looked up from real world position (the
## fine map's own tree_gen.gd:172 does `_species_for(TerrainConfig.biome_at(bx,bz), gx, gz)` — same call, forced
## biome argument). The top-down scan + per-species SHAPE functions are the real TreeGen statics, unmodified.
func _decoration_for(biome: int, x: int, z: int) -> int:
	var gx := floori(float(x) / float(TG.G))
	var gz := floori(float(z) / float(TG.G))
	var px := floori(float(gx) / float(TG.P))
	var pz := floori(float(gz) / float(TG.P))
	if TG._hash01(px, pz, 11) >= TG.PATCH_CHANCE:
		return BlockCatalog.AIR
	if TG._hash01(gx, gz, 22) >= TG.TREE_CHANCE:
		return BlockCatalog.AIR
	var species := _species_for_biome(biome, gx, gz)
	if species == TG.SP_NONE:
		return BlockCatalog.AIR
	var b := TG._base_pos(gx, gz)
	var dx := x - b.x
	var dz := z - b.y
	for y in range(_GY + TG.MAX_ABOVE_SURFACE, _GY, -1):
		var id := _shape_block(species, gx, gz, dx, y, dz, _GY)
		if id != BlockCatalog.AIR:
			return id
	return BlockCatalog.AIR

## Verbatim transcription of TreeGen._species_for's FOREST/TAIGA/JUNGLE/SAVANNA arms (tree_gen.gd:105-125) — same
## hash calls, same salts (88 forest oak/birch split, 124 acacia thinning), same thresholds (0.70, ACACIA_DENSITY).
## Doesn't need CubeSphere.FP_CLIMATE_BIOMES compiled on: the real function gates SAVANNA/JUNGLE behind that flag
## (only meaningful once climate biomes ship); this gate targets what those biomes' canopy coverage IS under it.
func _species_for_biome(biome: int, gx: int, gz: int) -> int:
	match biome:
		TC.B_FOREST:
			return TG.SP_OAK if TG._hash01(gx, gz, 88) < 0.70 else TG.SP_BIRCH
		TC.B_TAIGA:
			return TG.SP_SPRUCE
		TC.B_JUNGLE:
			return TG.SP_JUNGLE
		TC.B_SAVANNA:
			return TG.SP_ACACIA if TG._hash01(gx, gz, 124) < TG.ACACIA_DENSITY else TG.SP_NONE
	return TG.SP_NONE

func _shape_block(species: int, gx: int, gz: int, dx: int, y: int, dz: int, gy: int) -> int:
	match species:
		TG.SP_OAK: return TG._oak_block(gx, gz, dx, y, dz, gy, BlockCatalog.WOOD, BlockCatalog.LEAF)
		TG.SP_BIRCH: return TG._oak_block(gx, gz, dx, y, dz, gy, TG._BIRCH_LOG, TG._BIRCH_LEAF)
		TG.SP_SPRUCE: return TG._spruce_block(gx, gz, dx, y, dz, gy)
		TG.SP_JUNGLE: return TG._jungle_block(gx, gz, dx, y, dz, gy)
		TG.SP_ACACIA: return TG._acacia_block(gx, gz, dx, y, dz, gy)
	return BlockCatalog.AIR
