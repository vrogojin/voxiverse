class_name FacetDetailAtlas
extends RefCounted
## COSMOS TEXTURED-LOD T1b (docs/COSMOS-TEXTURED-LOD-DESIGN.md §2R.1) — the shared block-FACE detail atlas the far
## terrain wears under FP_BLOCK_DETAIL. A single DETAIL_LAYERS×DETAIL_TEXELS² RGBA8+mip Texture2DArray built ONCE at
## setup from the SAME BlockTextures.TILES PNGs the near voxels render with, so the far world shows the real grass-top
## pattern / stone speckle / sand grain — not the box-averaged biome colour. Shared by every facet (near-zero per-facet
## cost); the far ring's id_map (FacetTexBaker, per-texel FarPalette.detail_pattern) selects WHICH layer each macro
## texel samples, and the colour page supplies the hue.
##
## MEAN-NORMALIZATION (§2R.2, the degradation theorem). Each layer is additively centred so its per-channel mean = 0.5.
## The shader does face_col = col · detail · 2.0, so where a texel equals the layer mean (0.5) face_col = col exactly,
## and as distance mips the layer back toward its mean the block faces fade into EXACTLY today's colour map — no
## distance uniforms, no branches, per-fragment free. Centring (v − mean + 0.5) preserves the tile's PATTERN at full
## contrast (only the brightness is neutralised — the hue comes from the colour page), so the real texture survives.
##
## GRID BORDER (§2R.3, now OPT-IN behind CubeSphere.FP_DETAIL_GRID — §2U.2 live correction 2: "there should be NO grid").
## Historically a DETAIL_BORDER-texel darkened ring was baked into every layer BEFORE centring, drawing a mega-block grid
## line on the far terrain. The user rejected drawn grid lines, so by DEFAULT (FP_DETAIL_GRID == false) the tiles are
## built RAW — the mean-normalized block face edge-to-edge, no border, pixel-exact with the near atlas. When
## FP_DETAIL_GRID == true the historical ring is restored (toggleable, not deleted): on a 26-block backstop cell the
## texel grid IS the geometry grid, so texture and geometry edges coincide. _darken_border is a no-op when the flag is off.
##
## Layer index == the stored id (FarPalette pattern + 1); layer 0 is an unused neutral (id 0 = un-baked, never sampled
## — the shader gates detail on mid > 0). Materials with no CC0 tile (water/lava) get a flat-0.5 patterned-border layer
## (⇒ face_col = col, i.e. the plain colour, still grid-lined). NEVER-OOM: fixed DETAIL_LAYERS × DETAIL_TEXELS², built
## once; total_bytes() reports the ledger.

const DETAIL_LAYERS := 16                 # >= FarPalette.DETAIL_PATTERNS + 1 (id 0..12 used), padded to a round count
const DETAIL_TEXELS := 64                 # per-layer edge (design §2R.1); PNGs are 128² → NEAREST-halved to 64²
const DETAIL_BORDER := 2                  # darkened grid-line ring width, in texels
const BORDER_MUL := 0.5                   # how much the border ring is darkened before centring

## FarPalette pattern index → BlockTextures.TILES stem (the near-block face). "" ⇒ a flat neutral layer (no CC0 tile).
## Indexed by pattern, so stored id = pattern + 1 selects layer (pattern + 1) which is this stem's centred image.
const PATTERN_TILE := [
	"grass",           # P_GRASS
	"stone",           # P_STONE
	"sand",            # P_SAND
	"snow_block",      # P_SNOW
	"dirt",            # P_DIRT
	"leaf",            # P_LEAF
	"gravel",          # P_GRAVEL
	"mud",             # P_MUD
	"ice",             # P_ICE
	"jungle_leaves",   # P_JUNGLE
	"",                # P_WATER (no tile → neutral)
	"",                # P_LAVA  (no tile → neutral)
]

const DIR := "res://assets/textures/pack"

## Build the shared detail Texture2DArray (DETAIL_LAYERS × DETAIL_TEXELS² RGBA8 + mips). Layer 0 + pad layers are the
## flat-0.5 neutral; layer (pattern+1) is the pattern's centred, grid-bordered face. Pure + deterministic.
static func build() -> Texture2DArray:
	var imgs: Array[Image] = []
	imgs.resize(DETAIL_LAYERS)
	imgs[0] = _neutral_layer()                                   # id 0 slot — never sampled (mid > 0 gate)
	for p in range(PATTERN_TILE.size()):
		imgs[p + 1] = _build_layer(String(PATTERN_TILE[p]))
	for i in range(PATTERN_TILE.size() + 1, DETAIL_LAYERS):
		imgs[i] = _neutral_layer()                                # pad → neutral (never indexed)
	var tex := Texture2DArray.new()
	tex.create_from_images(imgs)
	return tex

## One centred layer from tile `stem` (or the flat neutral when stem == "" / the PNG is absent); the darkened grid
## border is applied only under FP_DETAIL_GRID (raw edge-to-edge by default). RGBA8, mips generated. Alpha 1 throughout.
static func _build_layer(stem: String) -> Image:
	if stem == "":
		return _neutral_layer()
	var path := "%s/%s.png" % [DIR, stem]
	if not ResourceLoader.exists(path):
		push_warning("FacetDetailAtlas: tile missing %s → neutral layer" % path)
		return _neutral_layer()
	var tex := load(path) as Texture2D
	if tex == null:
		return _neutral_layer()
	var img := tex.get_image()
	if img == null:
		return _neutral_layer()
	img = img.duplicate()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if img.get_width() != DETAIL_TEXELS or img.get_height() != DETAIL_TEXELS:
		img.resize(DETAIL_TEXELS, DETAIL_TEXELS, Image.INTERPOLATE_BILINEAR)
	_darken_border(img)
	_center_to_half(img)
	img.generate_mipmaps()
	return img

## A flat mid-grey (0.5) layer (⇒ face_col = col; used for water/lava/pad). The grid border is applied only under
## FP_DETAIL_GRID (a no-op by default).
static func _neutral_layer() -> Image:
	var img := Image.create(DETAIL_TEXELS, DETAIL_TEXELS, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.5, 0.5, 1.0))
	_darken_border(img)
	_center_to_half(img)
	img.generate_mipmaps()
	return img

## Multiply the outer DETAIL_BORDER-texel ring's RGB by BORDER_MUL (the baked mega-block grid line). Gated on
## CubeSphere.FP_DETAIL_GRID — a NO-OP by default (§2U.2: no grid ⇒ raw edge-to-edge tiles); only paints when opted in.
static func _darken_border(img: Image) -> void:
	if not CubeSphere.FP_DETAIL_GRID:
		return
	var n := DETAIL_TEXELS
	for y in range(n):
		for x in range(n):
			if x < DETAIL_BORDER or x >= n - DETAIL_BORDER or y < DETAIL_BORDER or y >= n - DETAIL_BORDER:
				var c := img.get_pixel(x, y)
				img.set_pixel(x, y, Color(c.r * BORDER_MUL, c.g * BORDER_MUL, c.b * BORDER_MUL, 1.0))

## Additively centre each channel so its mean = 0.5 (the degradation theorem): v' = clamp(v − mean + 0.5, 0, 1).
## Preserves the pattern at full contrast; neutralises only the brightness (hue comes from the colour page).
static func _center_to_half(img: Image) -> void:
	var n := DETAIL_TEXELS
	var sr := 0.0; var sg := 0.0; var sb := 0.0
	for y in range(n):
		for x in range(n):
			var c := img.get_pixel(x, y)
			sr += c.r; sg += c.g; sb += c.b
	var inv := 1.0 / float(n * n)
	var mr := sr * inv; var mg := sg * inv; var mb := sb * inv
	for y in range(n):
		for x in range(n):
			var c := img.get_pixel(x, y)
			img.set_pixel(x, y, Color(
				clampf(c.r - mr + 0.5, 0.0, 1.0),
				clampf(c.g - mg + 0.5, 0.0, 1.0),
				clampf(c.b - mb + 0.5, 0.0, 1.0), 1.0))

## The per-channel mean of a built layer image (gate G-BD-NORM surface). Mip-0 read.
static func layer_mean(img: Image) -> Vector3:
	var n := DETAIL_TEXELS
	var sr := 0.0; var sg := 0.0; var sb := 0.0
	for y in range(n):
		for x in range(n):
			var c := img.get_pixel(x, y)
			sr += c.r; sg += c.g; sb += c.b
	var inv := 1.0 / float(n * n)
	return Vector3(sr * inv, sg * inv, sb * inv)

## The mip-0 staging image for `layer` (gate surface: means / border presence). Rebuilds it deterministically (build()
## is pure), so the gate reads exactly what build() uploaded without holding the array.
static func layer_image(layer: int) -> Image:
	if layer <= 0 or layer > PATTERN_TILE.size():
		return _neutral_layer()
	return _build_layer(String(PATTERN_TILE[layer - 1]))

## The GPU footprint of the shared detail array (fixed): DETAIL_LAYERS × DETAIL_TEXELS² RGBA8 × mip tail (≈×1.333).
static func total_bytes() -> int:
	var layer_px := DETAIL_TEXELS * DETAIL_TEXELS * 4
	return (DETAIL_LAYERS * layer_px * 4) / 3
