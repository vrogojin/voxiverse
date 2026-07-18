extends SceneTree
## COSMOS CLIMATE-BIOMES B1 gate (docs/COSMOS-CLIMATE-BIOMES-DESIGN.md §6/§7, flag CubeSphere.FP_CLIMATE_BIOMES).
## Proves the Whittaker temperature×moisture classifier, the appended B_SAVANNA/B_JUNGLE biomes, the new
## acacia/jungle/cactus tree species and the FarPalette globe bands — WITHOUT depending on the flag being on
## (the classifier `_whittaker_biome` and the tree SHAPE functions are pure statics, testable in either config).
##
## Gates:
##   G-B1-DET    — `_whittaker_biome` and `biome_at` are pure functions of position (same input ⇒ same output).
##   G-B1-BANDS  — pole→equator the biome climate-rank is monotone non-decreasing (snowy→taiga→temperate→
##                 warm→hot); no snowy at the equator, no jungle/desert at the pole (outside mountains).
##   G-B1-TABLE  — the Whittaker table matches the design §6.1 cells at representative (t,h) points; AND when the
##                 flag is OFF, `_biome` == the shipped first-match chain over a sweep (the byte-identical proof).
##   G-B1-TREES  — jungle/acacia/cactus shapes stay within MAX_ABOVE_SURFACE and canopy radius ≤ 2 (the one-tree-
##                 per-grid-cell invariant); species are deterministic; desert/badlands stay tree-free except the
##                 flag-on desert cactus.
##   G-B1-PAL    — every biome id (incl. B_SAVANNA/B_JUNGLE) returns a valid FarPalette colour; frozen_colors
##                 stays 14 entries (the C++ FarColor contract is untouched — savanna/jungle fall back to grass
##                 on the C++ skin path until the enum extends).
##
## RUN:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_climate.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const TC := preload("res://src/world/terrain_config.gd")
const TG := preload("res://src/world/tree_gen.gd")
const FP := preload("res://src/world/far/far_palette.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

## Climate warmth rank of a biome (SNOWY coldest … BADLANDS/JUNGLE hottest) — the monotonicity yardstick.
func _rank(biome: int) -> int:
	match biome:
		TC.B_SNOWY: return 0
		TC.B_TAIGA: return 1
		TC.B_PLAINS, TC.B_FOREST, TC.B_SWAMP: return 2
		TC.B_DESERT, TC.B_SAVANNA: return 3
		TC.B_BADLANDS, TC.B_JUNGLE: return 4
	return -1

## The shipped (pre-B1) first-match biome chain, transcribed verbatim from terrain_config.gd for the
## flag-off byte-identity proof (G-B1-TABLE). If this drifts from _biome's OFF path the gate fails.
func _shipped_biome(c: float, t: float, h: float, g: int, mtn: float) -> int:
	if c < -0.32:
		return TC.B_OCEAN
	if c < 0.25 and g >= TC.SEA_LEVEL - 2 and g <= TC.SEA_LEVEL + 2:
		return TC.B_BEACH
	if mtn > TC.MOUNTAIN_BIOME_T:
		return TC.B_MOUNTAINS
	if t > 0.45 and h < -0.45:
		return TC.B_BADLANDS
	if t > 0.45 and h < 0.0:
		return TC.B_DESERT
	if t > 0.15 and h > 0.5:
		return TC.B_SWAMP
	if t < -0.55:
		return TC.B_SNOWY
	if t < -0.15:
		return TC.B_TAIGA
	if h > 0.1:
		return TC.B_FOREST
	return TC.B_PLAINS

func _initialize() -> void:
	print("=== verify_climate (COSMOS CLIMATE-BIOMES B1 — Whittaker classifier + savanna/jungle + trees + palette) ===")
	print("  CubeSphere.FP_CLIMATE_BIOMES = %s" % str(CubeSphere.FP_CLIMATE_BIOMES))
	TC._ensure_noise()
	TC._ensure_ids()
	TG.warm_up()
	FP.ensure_ready()
	_gate_det()
	_gate_bands()
	_gate_table()
	_gate_trees()
	_gate_pal()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- G-B1-DET: biome is a pure function of position ----------
func _gate_det() -> void:
	print("  --- G-B1-DET: classifier + biome_at are deterministic (pure functions) ---")
	var stable := true
	for i in range(400):
		var t := -1.0 + 0.005 * float(i)
		for hj in range(9):
			var h := -1.0 + 0.25 * float(hj)
			if TC._whittaker_biome(t, h) != TC._whittaker_biome(t, h):
				stable = false
	_ok(stable, "G-B1-DET: _whittaker_biome(t,h) is repeatable over a 400×9 sweep")
	var pos_stable := true
	for k in range(200):
		var x := (k * 613) % 4096 - 2048
		var z := (k * 977) % 4096 - 2048
		if TC.biome_at(x, z) != TC.biome_at(x, z):
			pos_stable = false
	_ok(pos_stable, "G-B1-DET: biome_at(x,z) is repeatable over 200 scattered columns (no RNG state)")

# ---------- G-B1-BANDS: pole→equator monotone climate bands ----------
func _gate_bands() -> void:
	print("  --- G-B1-BANDS: pole→equator biome rank is monotone non-decreasing (no snowy@equator / jungle@pole) ---")
	# Fixed-latitude (noise=0) temperature sweep in every moisture column: rising t must never cool the biome.
	var mono := true
	for hj in range(-8, 9):
		var h := 0.1 * float(hj)
		var prev := -1
		for i in range(0, 401):
			var t := -1.0 + 0.005 * float(i)
			var r := _rank(TC._whittaker_biome(t, h))
			if r < prev:
				mono = false
			prev = r
	_ok(mono, "G-B1-BANDS: climate rank monotone non-decreasing in t across all moisture columns")
	# On the sphere: t = _latitude_temperature(|dz|), so dz 1→0 (pole→equator) is a warming ramp.
	var pole_t := TC._latitude_temperature(1.0, 0.0)
	var eq_t := TC._latitude_temperature(0.0, 0.0)
	_ok(pole_t < -0.55, "G-B1-BANDS: pole latitude temperature is frozen (t=%.2f < -0.55)" % pole_t)
	_ok(eq_t > 0.45, "G-B1-BANDS: equator latitude temperature is hot (t=%.2f > 0.45)" % eq_t)
	# Pole is SNOWY for every moisture; equator is a hot-class biome for every moisture; neither inverts.
	var pole_ok := true
	var eq_ok := true
	for hj in range(-8, 9):
		var h := 0.1 * float(hj)
		if TC._whittaker_biome(pole_t, h) != TC.B_SNOWY:
			pole_ok = false
		var eqb := TC._whittaker_biome(eq_t, h)
		if eqb == TC.B_SNOWY or eqb == TC.B_TAIGA:
			eq_ok = false
	_ok(pole_ok, "G-B1-BANDS: the pole is SNOWY at every moisture (never jungle/desert)")
	_ok(eq_ok, "G-B1-BANDS: the equator is never snowy/taiga at any moisture")
	# Latitude ramp itself: a great-circle pole→equator biome-rank sequence is monotone.
	var ramp_mono := true
	var prev_r := -1
	for s in range(0, 51):
		var dz := 1.0 - 0.02 * float(s)           # 1 (pole) → 0 (equator)
		var t := TC._latitude_temperature(dz, 0.0)
		var r := _rank(TC._whittaker_biome(t, 0.2))
		if r < prev_r:
			ramp_mono = false
		prev_r = r
	_ok(ramp_mono, "G-B1-BANDS: a pole→equator latitude ramp gives a monotone biome-rank band sequence")

# ---------- G-B1-TABLE: Whittaker cells + flag-off byte-identity ----------
func _gate_table() -> void:
	print("  --- G-B1-TABLE: table cells match the design, and OFF ⇒ _biome == the shipped chain ---")
	# Representative cell probes (t, h) → expected biome per design §6.1.
	var cells := [
		[0.7, -0.6, TC.B_BADLANDS], [0.7, -0.2, TC.B_DESERT], [0.7, 0.2, TC.B_SAVANNA], [0.7, 0.6, TC.B_JUNGLE],
		[0.3, -0.6, TC.B_DESERT], [0.3, -0.2, TC.B_SAVANNA], [0.3, 0.2, TC.B_FOREST], [0.3, 0.7, TC.B_SWAMP],
		[0.0, -0.2, TC.B_PLAINS], [0.0, 0.3, TC.B_FOREST],
		[-0.3, 0.0, TC.B_TAIGA], [-0.8, 0.0, TC.B_SNOWY],
	]
	var cell_ok := true
	for c in cells:
		if TC._whittaker_biome(float(c[0]), float(c[1])) != int(c[2]):
			cell_ok = false
			print("    cell (t=%.2f,h=%.2f) => %d, expected %d" % [c[0], c[1], TC._whittaker_biome(float(c[0]), float(c[1])), int(c[2])])
	_ok(cell_ok, "G-B1-TABLE: all %d representative Whittaker cells classify as designed" % cells.size())
	# Flag-off byte-identity: _biome's OFF branch must equal the shipped chain over a dense sweep. (When the flag
	# is ON, _biome routes to the Whittaker table by design — skip, and say so.)
	if CubeSphere.FP_CLIMATE_BIOMES:
		_ok(true, "G-B1-TABLE: FP_CLIMATE_BIOMES ON — byte-identity-to-shipped skipped (world intentionally differs)")
	else:
		var identical := true
		var mism := 0
		for ci in range(-10, 11):
			var c := 0.1 * float(ci)
			for ti in range(-10, 11):
				var t := 0.1 * float(ti)
				for hi in range(-10, 11):
					var h := 0.1 * float(hi)
					for gg in [-8, 0, 6, 40]:
						for mm in [0.0, 0.5]:
							if TC._biome(c, t, h, gg, mm) != _shipped_biome(c, t, h, gg, mm):
								identical = false
								mism += 1
		_ok(identical, "G-B1-TABLE: OFF ⇒ _biome == shipped chain over a %d-point sweep (byte-identical; %d mismatches)" % [21 * 21 * 21 * 4 * 2, mism])

# ---------- G-B1-TREES: new species bounded + deterministic ----------
func _gate_trees() -> void:
	print("  --- G-B1-TREES: jungle/acacia/cactus shapes bounded (height ≤ MAX_ABOVE_SURFACE, radius ≤ 2) ---")
	var gy := 40                              # an arbitrary base surface well above sea level
	var max_h := 0
	var max_r := 0
	var det := true
	var species := [TG.SP_JUNGLE, TG.SP_ACACIA, TG.SP_CACTUS]
	for sp in species:
		for gx in range(0, 40):
			for gz in range(0, 40):
				for dy in range(1, TG.MAX_ABOVE_SURFACE + 4):     # scan a bit past the bound to catch overshoot
					var y := gy + dy
					for dx in range(-3, 4):
						for dz in range(-3, 4):
							var b := _shape(sp, gx, gz, dx, y, dz, gy)
							if b != BlockCatalog.AIR:
								max_h = maxi(max_h, y - gy)
								max_r = maxi(max_r, maxi(absi(dx), absi(dz)))
								if _shape(sp, gx, gz, dx, y, dz, gy) != b:
									det = false
	_ok(max_h <= TG.MAX_ABOVE_SURFACE, "G-B1-TREES: tallest new-species block is %d ≤ MAX_ABOVE_SURFACE (%d)" % [max_h, TG.MAX_ABOVE_SURFACE])
	_ok(max_r <= 2, "G-B1-TREES: widest new-species canopy radius is %d ≤ 2 (stays inside its grid cell)" % max_r)
	_ok(det, "G-B1-TREES: new-species shapes are deterministic (repeatable per position)")
	# Cactus is a strict 1×1 column (no canopy).
	var cactus_column := true
	for gx in range(0, 20):
		for gz in range(0, 20):
			for dy in range(1, 6):
				for dx in range(-2, 3):
					for dz in range(-2, 3):
						if (dx != 0 or dz != 0) and TG._cactus_block(gx, gz, dx, gy + dy, dz, gy) != BlockCatalog.AIR:
							cactus_column = false
	_ok(cactus_column, "G-B1-TREES: cactus is a strict 1×1 column (nothing off the trunk axis)")
	# Species selection: desert/badlands are tree-free with the flag OFF; ON, desert may host cactus, badlands never.
	var desert_off_free := true
	var badlands_free := true
	for gx in range(0, 60):
		for gz in range(0, 60):
			if TG._species_for(TC.B_BADLANDS, gx, gz) != TG.SP_NONE:
				badlands_free = false
			var ds := TG._species_for(TC.B_DESERT, gx, gz)
			if not CubeSphere.FP_CLIMATE_BIOMES and ds != TG.SP_NONE:
				desert_off_free = false
			if CubeSphere.FP_CLIMATE_BIOMES and ds != TG.SP_NONE and ds != TG.SP_CACTUS:
				desert_off_free = false
	_ok(badlands_free, "G-B1-TREES: badlands is always tree-free")
	_ok(desert_off_free, "G-B1-TREES: desert is tree-free (flag OFF) / cactus-only (flag ON)")

func _shape(sp: int, gx: int, gz: int, dx: int, y: int, dz: int, gy: int) -> int:
	match sp:
		TG.SP_JUNGLE: return TG._jungle_block(gx, gz, dx, y, dz, gy)
		TG.SP_ACACIA: return TG._acacia_block(gx, gz, dx, y, dz, gy)
		TG.SP_CACTUS: return TG._cactus_block(gx, gz, dx, y, dz, gy)
	return BlockCatalog.AIR

# ---------- G-B1-PAL: every biome has a far colour; C++ contract intact ----------
func _gate_pal() -> void:
	print("  --- G-B1-PAL: every biome id returns a valid far colour; frozen_colors stays 14 (C++ contract) ---")
	var all_valid := true
	for biome in range(0, TC.B_JUNGLE + 1):
		var col := FP.biome_base(biome, 0.2)
		if col.a <= 0.0:
			all_valid = false
			print("    biome %d returned a transparent colour" % biome)
	_ok(all_valid, "G-B1-PAL: biome_base returns an opaque colour for every id 0..%d (incl. savanna/jungle)" % TC.B_JUNGLE)
	# Savanna/jungle are distinct from plain grass (the bands are visible), and from each other.
	var grass := FP.biome_base(TC.B_PLAINS, 0.2)
	var sav := FP.biome_base(TC.B_SAVANNA, 0.2)
	var jun := FP.biome_base(TC.B_JUNGLE, 0.2)
	_ok(grass != sav and grass != jun and sav != jun, "G-B1-PAL: savanna/jungle/plains are three distinct far colours")
	_ok(FP.frozen_colors().size() == 14, "G-B1-PAL: frozen_colors stays 14 entries (C++ FarColor enum untouched)")
	# color_for routes through biome_base for a dry-land vertex — savanna/jungle resolve there too.
	_ok(FP.color_for(20, TC.B_JUNGLE, 0.6, false) == jun, "G-B1-PAL: color_for(dry jungle vertex) == the jungle band colour")
