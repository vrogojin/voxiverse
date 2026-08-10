extends SceneTree
## FP_SKIN_TEXTURE_MEAN headless gate — G-STM.
##
## Falsifies:
##   (A) BlockTextures.mean_color_of(id) — the pure per-block colour function:
##       - a TILE-LESS block (no TILES entry, e.g. water) falls back to the flat BlockCatalog swatch EXACTLY.
##       - a TILED block returns a plausible Color (RGB in [0,1], alpha forced to 1.0).
##       - idempotent: two calls for the same id return the IDENTICAL Color (the per-stem cache).
##       - two DIFFERENT tiles (grass vs stone) are not forced to the same mean (sanity the sampler actually reads
##         per-stem, not a shared accidental constant).
##   (B) FarPalette._top_color routing (CubeSphere.FP_SKIN_TEXTURE_MEAN) — flag OFF (the current default/build) ⇒
##       FarPalette.frozen_colors() is BYTE-IDENTICAL to the shipped BlockCatalog.color_of(...) derivation (no
##       BlockTextures involvement at all when off).
##   (C) DISCRIMINATION — calling BlockTextures.mean_color_of directly (bypassing the flag, exactly what _top_color
##       would return if the flag were on) differs from the flat swatch for a real photographic tile (grass), so
##       the flag has genuine visual effect once flipped on — not a vacuous no-op.
##
## RUN:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_skin_texture_mean.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const CS := preload("res://src/cosmos/cube_sphere.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

## Color has no built-in distance_to (unlike Vector3) — Euclidean distance over RGB only (alpha ignored, matching
## the semantics every caller here wants: "does this colour visually differ").
func _col_dist(a: Color, b: Color) -> float:
	return Vector3(a.r, a.g, a.b).distance_to(Vector3(b.r, b.g, b.b))

func _initialize() -> void:
	print("=== verify_skin_texture_mean (FP_SKIN_TEXTURE_MEAN: G-STM) ===")
	_gate_off()
	_gate_mean_fn()
	_gate_discriminates()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- (B) flag OFF ⇒ FarPalette is byte-identical to the shipped color_of derivation ----------
func _gate_off() -> void:
	print("  --- (B) OFF: FarPalette.frozen_colors() == the shipped BlockCatalog.color_of(...) derivation ---")
	_ok(not CS.FP_SKIN_TEXTURE_MEAN, "(B) fixture precondition: FP_SKIN_TEXTURE_MEAN is off in this build")
	BlockCatalog.ensure_ready()
	var water := BlockCatalog.color_of(BlockCatalog.id_of(&"water"))
	var ice := BlockCatalog.color_of(BlockCatalog.id_of(&"ice"))
	var lava := BlockCatalog.color_of(BlockCatalog.id_of(&"lava"))
	var snow := BlockCatalog.color_of(BlockCatalog.id_of(&"snow_block"))
	var sand := BlockCatalog.color_of(BlockCatalog.id_of(&"sand"))
	var gravel := BlockCatalog.color_of(BlockCatalog.id_of(&"gravel"))
	var red_sand := BlockCatalog.color_of(BlockCatalog.id_of(&"red_sand"))
	var mud := BlockCatalog.color_of(BlockCatalog.id_of(&"mud"))
	var podzol := BlockCatalog.color_of(BlockCatalog.id_of(&"podzol"))
	var grass := BlockCatalog.color_of(BlockCatalog.GRASS)
	var leaf := BlockCatalog.color_of(BlockCatalog.LEAF)
	var stone := BlockCatalog.color_of(BlockCatalog.STONE)
	var taiga := grass.lerp(podzol, 0.20)
	var forest := grass.lerp(leaf, 0.35)
	var expected := PackedColorArray([water, ice, lava, snow, sand, gravel, red_sand, mud, podzol, grass, leaf, stone, taiga, forest])
	var got := FarPalette.frozen_colors()
	_ok(got.size() == expected.size(), "(B) frozen_colors() has the expected entry count (%d)" % expected.size())
	var all_eq := true
	for i in range(mini(got.size(), expected.size())):
		if got[i] != expected[i]:
			all_eq = false
			print("  FAIL:   (B) index %d differs: got %s expected %s" % [i, got[i], expected[i]])
	_ok(all_eq, "(B) every frozen_colors() entry is byte-identical to the shipped swatch derivation")

# ---------- (A) BlockTextures.mean_color_of pure properties ----------
func _gate_mean_fn() -> void:
	print("  --- (A) mean_color_of: tile-less passthrough + valid range + idempotent cache ---")
	var water_id := BlockCatalog.id_of(&"water")
	_ok(BlockTextures.path_for(water_id) == "", "(A) fixture precondition: water has no TILES entry")
	var water_mean := BlockTextures.mean_color_of(water_id)
	var water_swatch := BlockCatalog.color_of(water_id)
	_ok(water_mean == water_swatch, "(A) a tile-less block (water) falls back to the flat swatch EXACTLY")

	var stone_id := BlockCatalog.STONE
	_ok(BlockTextures.path_for(stone_id) != "", "(A) fixture precondition: stone has a TILES entry")
	var stone_mean := BlockTextures.mean_color_of(stone_id)
	_ok(stone_mean.r >= 0.0 and stone_mean.r <= 1.0 and stone_mean.g >= 0.0 and stone_mean.g <= 1.0
		and stone_mean.b >= 0.0 and stone_mean.b <= 1.0, "(A) a tiled block's mean colour is in [0,1] per channel")
	_ok(absf(stone_mean.a - 1.0) < 1.0e-6, "(A) a tiled block's mean colour has alpha forced to 1.0")

	var stone_mean_2 := BlockTextures.mean_color_of(stone_id)
	_ok(stone_mean == stone_mean_2, "(A) mean_color_of is idempotent (per-stem cache returns the identical Color)")

	var grass_mean := BlockTextures.mean_color_of(BlockCatalog.GRASS)
	_ok(_col_dist(stone_mean, grass_mean) > 0.01,
		"(A) two different tiles (grass vs stone) sample DIFFERENT means, Δ=%.3f (not a shared accidental constant)"
		% _col_dist(stone_mean, grass_mean))

# ---------- (C) discrimination: the mean genuinely differs from the flat swatch for a real tile ----------
func _gate_discriminates() -> void:
	print("  --- (C) DISCRIMINATES: a real photographic tile's mean differs from its flat catalog swatch ---")
	var grass_id := BlockCatalog.GRASS
	var grass_mean := BlockTextures.mean_color_of(grass_id)
	var grass_swatch := BlockCatalog.color_of(grass_id)
	_ok(_col_dist(grass_mean, grass_swatch) > 0.02,
		"(C) grass tile mean differs from the flat swatch, Δ=%.3f (FP_SKIN_TEXTURE_MEAN ON would have visible effect)"
		% _col_dist(grass_mean, grass_swatch))
