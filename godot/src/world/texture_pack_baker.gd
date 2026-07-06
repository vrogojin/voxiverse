@tool
class_name TexturePackBaker
extends RefCounted
## Turns the CC0 16x16 base tiles (assets/textures/pack/src/) into the enhanced
## tiles the engine actually loads (assets/textures/pack/<name>.png).
##
## THE LOOK the product owner asked for: reads as blocky 16x16 pixel-art, but each
## source "pixel" is expanded into an FxF block of higher-resolution output pixels
## carrying deterministic sub-pixel detail — a green pixel gets internal light/dark
## variation, a near-black pixel becomes textured dark NOISE rather than a flat fill.
## The hard 16x16 silhouette is preserved because colour blocks come straight from
## the (nearest-sampled) source pixel; only intra-pixel brightness is modulated.
##
## Deterministic (fixed SEED) so a re-bake is reproducible, and the detail noise is
## TILEABLE over the output size, so the fallback mesher (which tiles one texture
## per world-metre) shows no seam between neighbouring voxel faces. Runs headless in
## the custom editor:  godot --headless --path godot -s res://src/tools/bake_textures.gd
##
## Base tiles are CC0 (see assets/textures/pack/LICENSE.txt); see docs/TEXTURES.md.

const FACTOR := 8                       # 16 px -> 128 px output (F*F sub-pixels/pixel)
const SEED := 0xB10C
const AMP := 0.18                       # multiplicative brightness variation (keeps hue)
const DARKLIFT := 0.13                  # additive noise lifted into dark pixels
const ALPHA_CUTOFF := 0.5               # src alpha below this counts as "hole"

const SRC_DIR := "res://assets/textures/pack/src"
const OUT_DIR := "res://assets/textures/pack"

## One enhanced tile: out file name, source tile, whether to keep source alpha
## (transparent blocks like glass), and the opaque backing colour used where an
## opaque block's source has holes (e.g. leaf cut-outs) so the block stays solid.
static func _spec() -> Array:
	return [
		# out name    src tile              keep_alpha  backing
		# --- frozen core ---
		{"out": "grass", "src": "grass_top",     "keep_alpha": false, "backing": Color(0.24, 0.42, 0.18)},
		{"out": "dirt",  "src": "dirt",          "keep_alpha": false, "backing": Color(0.36, 0.25, 0.15)},
		{"out": "stone", "src": "stone_generic", "keep_alpha": false, "backing": Color(0.50, 0.50, 0.52)},
		{"out": "wood",  "src": "oak_log_side",  "keep_alpha": false, "backing": Color(0.45, 0.32, 0.18)},
		{"out": "leaf",  "src": "oak_leaves",    "keep_alpha": false, "backing": Color(0.09, 0.20, 0.08)},
		# --- world-tier stones (WGC §3.3): closest CC0 tile per material ---
		{"out": "bedrock",         "src": "gabbro",         "keep_alpha": false, "backing": Color(0.34, 0.34, 0.34)},
		{"out": "deepslate",       "src": "slate",          "keep_alpha": false, "backing": Color(0.28, 0.28, 0.30)},
		{"out": "granite",         "src": "granite",        "keep_alpha": false, "backing": Color(0.58, 0.40, 0.33)},
		{"out": "diorite",         "src": "diorite",        "keep_alpha": false, "backing": Color(0.74, 0.74, 0.75)},
		{"out": "andesite",        "src": "rhyolite",       "keep_alpha": false, "backing": Color(0.50, 0.50, 0.52)},
		{"out": "tuff",            "src": "schist",         "keep_alpha": false, "backing": Color(0.43, 0.44, 0.41)},
		{"out": "calcite",         "src": "marble",         "keep_alpha": false, "backing": Color(0.88, 0.88, 0.86)},
		{"out": "dripstone_block", "src": "limestone",      "keep_alpha": false, "backing": Color(0.49, 0.39, 0.33)},
		{"out": "sandstone",       "src": "sandstone",      "keep_alpha": false, "backing": Color(0.86, 0.81, 0.64)},
		{"out": "obsidian",        "src": "obsidian",       "keep_alpha": false, "backing": Color(0.06, 0.04, 0.10)},
		{"out": "amethyst_block",  "src": "amethyst",       "keep_alpha": false, "backing": Color(0.53, 0.38, 0.75)},
		# --- soils / surface ---
		{"out": "mud",         "src": "mud",       "keep_alpha": false, "backing": Color(0.24, 0.23, 0.24)},
		{"out": "sand",        "src": "sand",      "keep_alpha": false, "backing": Color(0.86, 0.83, 0.63)},
		{"out": "gravel",      "src": "gravel",    "keep_alpha": false, "backing": Color(0.51, 0.50, 0.49)},
		{"out": "snow_block",  "src": "snow",      "keep_alpha": false, "backing": Color(0.96, 0.99, 0.99)},
		# --- cryo (ice_glacier used opaque; the ice MATERIAL applies alpha, WGC §5.1) ---
		{"out": "ice",         "src": "ice_glacier", "keep_alpha": false, "backing": Color(0.49, 0.68, 1.00)},
		# --- tree species (nearest CC0 species tile) ---
		{"out": "spruce_log",    "src": "pine_log_side",       "keep_alpha": false, "backing": Color(0.29, 0.21, 0.13)},
		{"out": "spruce_leaves", "src": "pine_leaves",         "keep_alpha": false, "backing": Color(0.15, 0.24, 0.14)},
		{"out": "birch_log",     "src": "beech_log_side",      "keep_alpha": false, "backing": Color(0.78, 0.75, 0.66)},
		{"out": "birch_leaves",  "src": "beech_leaves",        "keep_alpha": false, "backing": Color(0.28, 0.42, 0.16)},
		{"out": "jungle_log",    "src": "eucalyptus_log_side", "keep_alpha": false, "backing": Color(0.34, 0.27, 0.15)},
		{"out": "jungle_leaves", "src": "eucalyptus_leaves",   "keep_alpha": false, "backing": Color(0.16, 0.36, 0.07)},
		{"out": "acacia_log",    "src": "maple_log_side",      "keep_alpha": false, "backing": Color(0.43, 0.40, 0.36)},
		{"out": "acacia_leaves", "src": "maple_leaves",        "keep_alpha": false, "backing": Color(0.28, 0.42, 0.11)},
		# --- glass (translucent: KEEP source alpha so the pane reads see-through) ---
		{"out": "glass",         "src": "glass",              "keep_alpha": true,  "backing": Color(1, 1, 1)},
	]

## Bake every tile in the spec. Returns OK if all succeeded.
static func bake_all() -> int:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var result := OK
	for e in _spec():
		var err := _bake_one(e["src"], e["out"], e["keep_alpha"], e["backing"])
		if err != OK:
			push_error("[texture_pack_baker] failed on %s: %d" % [e["out"], err])
			result = err
		else:
			print("[texture_pack_baker] %s.png <- src/%s.png" % [e["out"], e["src"]])
	return result

static func _bake_one(src_name: String, out_name: String, keep_alpha: bool,
		backing: Color) -> int:
	var src := Image.new()
	var src_path := ProjectSettings.globalize_path("%s/%s.png" % [SRC_DIR, src_name])
	var err := src.load(src_path)
	if err != OK:
		return err
	var img := enhance(src, keep_alpha, backing)
	return img.save_png("%s/%s.png" % [OUT_DIR, out_name])

## Upscale `src` by FACTOR and inject deterministic sub-pixel detail. Public so a
## unit/verify pass can enhance an in-memory image without touching disk.
static func enhance(src: Image, keep_alpha: bool, backing: Color) -> Image:
	var sw := src.get_width()
	var sh := src.get_height()
	var ow := sw * FACTOR
	var oh := sh * FACTOR
	var out := Image.create(ow, oh, false, Image.FORMAT_RGBA8)
	for gy in oh:
		for gx in ow:
			var c := src.get_pixel(gx / FACTOR, gy / FACTOR)
			var a := c.a
			if c.a < ALPHA_CUTOFF:
				if keep_alpha:
					out.set_pixel(gx, gy, Color(0, 0, 0, 0))
					continue
				c = backing            # solid block: fill the hole with the backing
				a = 1.0
			if not keep_alpha:
				a = 1.0
			# Detail noise over OUTPUT coords, tileable across the whole tile so the
			# per-metre-tiled fallback path is seamless.
			var n := _fbm(gx, gy, ow, oh)
			var lum := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			var m := 1.0 + AMP * (n - 0.5) * 2.0            # brightness wobble, hue-preserving
			var lift := DARKLIFT * (1.0 - lum) * (_fbm(gx + 811, gy + 419, ow, oh) - 0.3)
			out.set_pixel(gx, gy, Color(
				clampf(c.r * m + lift, 0.0, 1.0),
				clampf(c.g * m + lift, 0.0, 1.0),
				clampf(c.b * m + lift, 0.0, 1.0),
				a))
	return out

# --- tileable value-noise fBm (period = output size) ----------------------------
static func _smooth(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)

# Hash on a lattice that wraps at `period`, so opposite edges match -> seamless.
static func _hash(ix: int, iy: int, period: int) -> float:
	ix = posmod(ix, period)
	iy = posmod(iy, period)
	var n := (ix * 374761393 + iy * 668265263 + SEED * 362437) & 0xFFFFFFFF
	n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
	n = n ^ (n >> 16)
	return float(n & 0xFFFF) / 65535.0

static func _value_noise(x: float, y: float, cells: int, w: int, h: int) -> float:
	# `cells` lattice points across the tile width -> pattern repeats every tile.
	var fx := x / float(w) * cells
	var fy := y / float(h) * cells
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var tx := _smooth(fx - x0)
	var ty := _smooth(fy - y0)
	var v00 := _hash(x0, y0, cells)
	var v10 := _hash(x0 + 1, y0, cells)
	var v01 := _hash(x0, y0 + 1, cells)
	var v11 := _hash(x0 + 1, y0 + 1, cells)
	var a := v00 + (v10 - v00) * tx
	var b := v01 + (v11 - v01) * tx
	return a + (b - a) * ty

# 3 octaves from coarse (per-source-pixel scale) to fine (per-output-pixel). All
# cell counts divide the output size so every octave tiles.
static func _fbm(x: float, y: float, w: int, h: int) -> float:
	var total := 0.0
	var amp := 0.5
	var norm := 0.0
	for cells in [16, 32, 64]:          # 16 == one lattice cell per source pixel
		total += _value_noise(x, y, cells, w, h) * amp
		norm += amp
		amp *= 0.5
	return total / norm
