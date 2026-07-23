class_name FacetTexBaker
extends RefCounted
## COSMOS LOD-TEXTURE Phase 1 (docs/COSMOS-LOD-TEXTURE-DESIGN.md §1.1/§6 Phase 1) — the per-facet baked
## "satellite" far texture (BASE MAP only). Owned by WorldManager, created ONLY under FP_FACET_TEX && FACETED
## (mirrors the FacetSkinTier gated-construction pattern). Flag OFF ⇒ this object is never instantiated, so no
## textures / staging Images ever exist (byte-identical, zero bytes).
##
## THE BAKE (§1.1, "CPU composite from the one-generator sampler, then box-average downscale"). Per facet:
##   1. Sample a fine BAKE_SRC×BAKE_SRC grid of the facet's surface via VoxelGeneratorCosmos.sample_columns —
##      the SAME C++ call FacetSkinTier uses (one call per row-slice). Each fine texel = the real top block's
##      catalog colour at that column (FarPalette.color_for through the one-sampler law), i.e. the exact pixels
##      a top-down render of the meshed blocks would produce, without those blocks being resident.
##   2. Box-average the fine grid down to BASE_TEXELS×BASE_TEXELS (2×2 fine texels per stored texel). This is
##      the literal "downscale the real image" of the design (a 50×50 quarry survives; a single block averages
##      out). DEVIATION-NOTE: the design cites Image.resize(INTERPOLATE_BILINEAR); an explicit box average is
##      used instead — it IS the design's stated intent ("box average of the real block colours") and makes
##      the bake headless-deterministic and the G-FT-BAKE box-average assertion exact (ε = 8-bit quantization
##      only), where a bilinear 2× kernel would not be an exact box average.
##   3. Blit the 16² texel block into the facet's rect [a·16..a·16+16)×[b·16..b·16+16) of its cube-FACE page.
## A cube face's 24×24 facets share ONE continuous 384² page, so within-face bilinear filtering across facet
## boundaries is correct continuity — ~99% of potential per-facet texture seams do not exist by construction.
##
## THE STORE (§1.2). 6 face pages → a Texture2DArray of 6 layers of (K·BASE_TEXELS)² = 384² RGBA8 + mipmaps.
## Facet (face,a,b)'s texels align 1:1 with the far ring's ARRAY_TEX_UV = ((a+s)/K,(b+t)/K), so the shader's
## texture(base_map, vec3(uv, face)) samples exactly this bake.
##
## NEVER-OOM (§4, base-tier-only ≈ 8.2 MB). Every buffer is fixed-size at creation: 6 layers, 384², RGBA8.
## Nothing grows with playtime/edits/travel (Phase 1 has no edits, no close-up tier). total_bytes() reports the
## ledger. On the live gl_compat/ANGLE path the Texture2DArray + per-layer update() is the one item that cannot
## be verified headless (design R6) — the single-ImageTexture fallback is a localized swap (base_texture()/the
## page store are the only touch points) if the live smoke fails.

const BASE_TEXELS := 16              # stored texels per facet edge → ground pitch ≈ 26 blocks (§1.2)
const BAKE_SRC := 32                 # fine sample columns per facet edge (2× BASE_TEXELS → exact 2×2 box average)
const DOWNS := BAKE_SRC / BASE_TEXELS # box-average factor (2)

var _k := 0                          # FacetAtlas.K (24) — page = _k·BASE_TEXELS
var _page := 0                       # per-face page edge in texels (384)
var _pages: Array = []               # 6 face Images (RGBA8, mipmaps) — the CPU staging + re-blit source
var _tex: Texture2DArray = null      # the 6-layer GPU base map (bound into the ring's base_map uniform)
var _sampler: Callable               # (fid, PackedInt64Array) -> {heights,biomes,water,colors} (one-sampler law)
var _sampler_obj: Object = null      # STRONG ref to the compiled generator (a Callable does NOT keep it alive)
var _baked: Dictionary = {}          # fid -> true (facets composited into their page this session)

# --- lifecycle -----------------------------------------------------------------------------------

## Build this epoch's sampler (compiled VoxelGeneratorCosmos frozen for `active_fid`, else the GDScript oracle
## — byte-equal by G-CG-COLUMNS) and allocate the 6 empty face pages. Mirrors FacetSkinTier.setup.
func setup(active_fid: int) -> void:
	_k = FacetAtlas.K
	_page = _k * BASE_TEXELS
	_sampler_obj = FacetSkinTier._build_cpp_gen(active_fid)
	if _sampler_obj != null:
		_sampler = Callable(_sampler_obj, "sample_columns")
	else:
		push_warning("FacetTexBaker: VoxelGeneratorCosmos absent — using the GDScript oracle sampler (slow).")
		_sampler = Callable(FacetSkinTier, "gd_sample")
	_pages.resize(6)
	for f in range(6):
		var img := Image.create(_page, _page, true, Image.FORMAT_RGBA8)
		img.fill(Color(0.0, 0.0, 0.0, 1.0))
		_pages[f] = img

## Synchronous prewarm of the currently-emitted facet set (§6 Phase 1). Bakes each facet's base map into its
## page, then uploads the whole 6-layer array once. Masked by the same ShaderPrewarm hold as the ring's initial
## _rebuild_full (WorldManager calls this at setup with the ring's visible_fids()).
func prewarm(fids: PackedInt32Array) -> void:
	for fid in fids:
		bake_facet(int(fid))
	_rebuild_texture()

# --- the bake (§1.1) -----------------------------------------------------------------------------

## The fine BAKE_SRC×BAKE_SRC grid of top-block colours for facet `fid`, sampled via sample_columns one row
## at a time (fi → s, fj → t, matching the far ring's UV = ((a+s)/K,(b+t)/K)). Public so the gate re-samples
## the SAME grid the bake box-averages (G-FT-BAKE) — the sampler is pure, so two calls are byte-identical.
func sample_fine(fid: int) -> PackedColorArray:
	# The facet's 4 lattice (x,z) corners: its param (s,t)=00,10,11,01 corners mapped through the exact
	# world_to_lattice64, so a fine param maps to the lattice column sample_columns wants (cell_dir agrees).
	var lc := PackedVector2Array()
	lc.resize(4)
	for ci in range(4):
		var w := FacetAtlas.facet_planar_corner(fid, ci)
		var l := FacetAtlas.world_to_lattice64(fid, w[0], w[1], w[2])
		lc[ci] = Vector2(float(l[0]), float(l[2]))
	var fine := PackedColorArray()
	fine.resize(BAKE_SRC * BAKE_SRC)
	var packed := PackedInt64Array()
	packed.resize(BAKE_SRC)
	for fj in range(BAKE_SRC):
		var t := (float(fj) + 0.5) / float(BAKE_SRC)
		for fi in range(BAKE_SRC):
			var s := (float(fi) + 0.5) / float(BAKE_SRC)
			var lx := _bilerp(lc[0].x, lc[1].x, lc[2].x, lc[3].x, s, t)
			var lz := _bilerp(lc[0].y, lc[1].y, lc[2].y, lc[3].y, s, t)
			packed[fi] = _pack_xz(int(round(lx)), int(round(lz)))
		var res: Dictionary = _sampler.call(fid, packed)
		var cols: PackedColorArray = res["colors"]
		for fi in range(BAKE_SRC):
			fine[fj * BAKE_SRC + fi] = cols[fi]
	return fine

## Composite facet `fid`'s base map into its cube-face page: box-average the fine grid down to BASE_TEXELS²
## and blit into the facet's rect [a·16..)×[b·16..). Idempotent (a re-bake overwrites the same rect bit-exactly
## → G-FT-BAKE determinism). Does NOT upload — prewarm()/the gate call _rebuild_texture() after a batch.
func bake_facet(fid: int) -> void:
	var d := _decode(fid)
	var face: int = d[0]
	var a: int = d[1]
	var b: int = d[2]
	var fine := sample_fine(fid)
	var img: Image = _pages[face]
	var ox := a * BASE_TEXELS
	var oy := b * BASE_TEXELS
	var inv := 1.0 / float(DOWNS * DOWNS)
	for ty in range(BASE_TEXELS):
		for tx in range(BASE_TEXELS):
			var r := 0.0
			var g := 0.0
			var bl := 0.0
			for sy in range(DOWNS):
				var row := (ty * DOWNS + sy) * BAKE_SRC + tx * DOWNS
				for sx in range(DOWNS):
					var c: Color = fine[row + sx]
					r += c.r
					g += c.g
					bl += c.b
			img.set_pixel(ox + tx, oy + ty, Color(r * inv, g * inv, bl * inv, 1.0))
	_baked[fid] = true

## (Re)generate mipmaps on every page and (re)build the GPU Texture2DArray. Phase 1 builds it once after the
## prewarm batch; the per-layer update_layer path (Phase 2/3) is retained for the incremental case.
func _rebuild_texture() -> void:
	var imgs: Array[Image] = []
	for f in range(6):
		var img: Image = _pages[f]
		img.generate_mipmaps()
		imgs.append(img)
	if _tex == null:
		_tex = Texture2DArray.new()
		_tex.create_from_images(imgs)
	else:
		for f in range(6):
			_tex.update_layer(imgs[f], f)

# --- accessors / gate surface --------------------------------------------------------------------

## The 6-layer base map bound into the far ring's `base_map` uniform (null until the first prewarm/bake batch).
func base_texture() -> Texture2DArray:
	return _tex

## The cube-face layer index of facet `fid` (0..5) — the base-map array layer its texels live in.
func face_of(fid: int) -> int:
	return _decode(fid)[0]

## The stored (RGBA8 mip-0) texel colour at facet `fid`'s local texel (tx,ty) ∈ [0,BASE_TEXELS)². Gate surface
## for G-FT-BAKE / G-FT-PALETTE (reads the page after bake_facet).
func texel_color(fid: int, tx: int, ty: int) -> Color:
	var d := _decode(fid)
	var img: Image = _pages[int(d[0])]
	return img.get_pixel(int(d[1]) * BASE_TEXELS + tx, int(d[2]) * BASE_TEXELS + ty)

func is_baked(fid: int) -> bool:
	return _baked.has(fid)

func baked_count() -> int:
	return _baked.size()

## The TRUE NEVER-OOM footprint (§4): 6 CPU staging pages + the GPU array (+mips ≈ ×1.33). Base-tier-only, so
## ≈ 8.2 MB — the gate asserts it stays under FACET_TEX_BYTES_MAX (20 MB, the all-flags-on ceiling).
const FACET_TEX_BYTES_MAX := 20 * 1024 * 1024
func total_bytes() -> int:
	var page_px := _page * _page * 4          # one RGBA8 page, bytes
	var cpu := 6 * page_px                     # 6 CPU staging Images (kept for re-blit)
	var gpu := (6 * page_px * 4) / 3           # GPU array + mipmap tail (×1.333)
	return cpu + gpu

# --- helpers -------------------------------------------------------------------------------------

## Decode `fid` → [face, a, b, k] in its body's local (face,a,b) indexing (Earth ⇒ base 0, k=K). Mirrors
## FacetAtlas.facet_corner_dirs' decode so UV = ((a+s)/k,(b+t)/k) and the page rect agree with the far ring.
func _decode(fid: int) -> Array:
	var kb := FacetAtlas.k_of(fid)
	var lf := fid - FacetAtlas.fid_base_of(fid)
	var face := int(lf / (kb * kb))
	var rem := lf - face * kb * kb
	var a := int(rem / kb)
	var b := rem - a * kb
	return [face, a, b, kb]

## Bilinear over facet param corners (v00,v10,v11,v01) at (s,t) — the SAME kernel FacetFarRing/_ensure_cached
## uses, so a fine param maps identically to how the mesh maps a grid node.
static func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

## Pack a lattice column (x,z) into the int64 sample_columns expects: x low 32 bits, z high 32 (== skin's).
static func _pack_xz(x: int, z: int) -> int:
	return (x & 0xffffffff) | ((z & 0xffffffff) << 32)
