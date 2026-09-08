class_name StructCardKit
extends RefCounted
## COSMOS STRUCT-IMPOSTOR (docs/COSMOS-STRUCT-IMPOSTOR-DESIGN.md §3-§4) — the PURE, static kit for the far-village
## impostor-card tier (FP_STRUCT_CARDS). Kept OUT of FacetFarStructures so the verify_ gates drive it hermetically
## (no ring / no MultiMesh). Two responsibilities:
##  1. Archetype canonicalization (§3): map a house's (roof, wall_h, gable_h) → one of 10 canonical archetype rows,
##     and back to the canonical bake dims, so the tile atlas captures the silhouette space with 10 rows (not 16).
##  2. Atlas generation (§4): CPU-rasterize each archetype's 8 horizontal azimuth views + 1 top view into a
##     288×320 RGBA8 atlas, derived from StructureGen._template_block VERBATIM (single source of truth with the near
##     voxel house — the tile can never drift from the generator/palette; the far-tree atlas precedent, §4.1).
##
## Everything here is a pure function of the generator + palette (+ the FP_FT_TEXMEAN_COLOR palette flag), so the
## atlas is byte-stable for a frozen generator and needs no import pipeline. Only ever CONSTRUCTED under
## FP_STRUCT_CARDS (setup_instance builds the atlas), but the class itself is flag-free (the gates exercise it directly).

const SG := preload("res://src/world/structure_gen.gd")

# Atlas geometry — column = view (0..7 side azimuths, 8 = top), row = archetype (0..9). 288 × 320 RGBA8 = 368,640 B.
const TILE := 32                         # texels per tile (== CubeSphere.STRUCT_CARD_TILE)
const AZIMUTHS := 8                      # side azimuth views (45° sectors)
const COLS := AZIMUTHS + 1               # 8 side + 1 top
const ROWS := 10                         # canonical archetypes (== CubeSphere.STRUCT_CARD_ARCHES)
const PAD := 3.0                         # tile edge pad (texels) — no opaque pixel touches the border (filter_nearest safe)

# =====================================================================================================================
# §3.2 Archetype canonicalization
# =====================================================================================================================

## Map a house's silhouette params to its canonical archetype row [0,10). Flat (roof==0) splits on wall_h only
## (0..1); gabled (roof==1) splits on (wall_h, gable_h) (2..9). Total + injective over the reachable param space.
static func arch_index(roof: int, wall_h: int, gable_h: int) -> int:
	if roof == 0:
		return wall_h - SG.WALL_MIN                          # 0..1
	return 2 + (wall_h - SG.WALL_MIN) * 4 + (gable_h - 2)     # 2..9

## The canonical bake params for archetype `a` (the inverse of arch_index): {roof, wall_h, gable_h, w, d}. Canonical
## w = 8 (mid-range); canonical d = 8 (flat) or 2·gable_h+1 (gabled, odd ⇒ a 1-cell ridge row). §3.2.
static func arch_params(a: int) -> Dictionary:
	if a < 2:
		return {"roof": 0, "wall_h": SG.WALL_MIN + a, "gable_h": 0, "w": 8, "d": 8}
	var j := a - 2
	var wall_h := SG.WALL_MIN + int(j / 4)                   # 3 or 4
	var gable_h := 2 + (j % 4)                               # 2..5
	return {"roof": 1, "wall_h": wall_h, "gable_h": gable_h, "w": 8, "d": 2 * gable_h + 1}

## The topmost local y (over base) the archetype's roof reaches — its vertical extent above the floor course.
static func _roof_top_ly(roof: int, wall_h: int, gable_h: int) -> int:
	return wall_h + (gable_h if roof == 1 else 1)

# =====================================================================================================================
# §4.1 Canonical cell enumeration — the solid cells of archetype `a`, via StructureGen._template_block VERBATIM.
# =====================================================================================================================

## Solid template cells of archetype `a` in the canonical frame (base at origin, door on −x): an Array of Vector4i
## (lx, y, lz, id) with id > 0. Enumerates the bbox x∈[0,w), z∈[0,d), y∈[1, 1+rtop] with cg=0 (the carve branch
## never fires — no terrain in the canonical frame), so the tiles derive from the SAME code the near voxel house does.
static func canonical_cells(a: int) -> Array:
	var p := arch_params(a)
	var w: int = p["w"]
	var d: int = p["d"]
	var roof: int = p["roof"]
	var wall_h: int = p["wall_h"]
	var gable_h: int = p["gable_h"]
	var rtop := _roof_top_ly(roof, wall_h, gable_h)
	var hi := {
		"base": Vector3i(0, 0, 0),
		"w": w, "d": d, "wall_h": wall_h, "door": 0, "roof": roof, "gable_h": gable_h,
	}
	var out: Array = []
	for lx in range(w):
		for lz in range(d):
			for y in range(1, 2 + rtop):
				var id := SG._template_block(hi, lx, y, lz, 0)
				if id > 0:
					out.append(Vector4i(lx, y, lz, id))
	return out

# =====================================================================================================================
# §4 Atlas generation — CPU-rasterize the 9-view × 10-archetype tile grid.
# =====================================================================================================================

## Build the impostor atlas: 288×320 RGBA8 (column = view, row = archetype), transparent background, filter_nearest.
static func build_atlas() -> ImageTexture:
	SG.warm_up()                                            # ensure the house material ids exist (main thread)
	var img := Image.create(COLS * TILE, ROWS * TILE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for a in range(ROWS):
		var cells := canonical_cells(a)
		if cells.is_empty():
			continue
		for k in range(AZIMUTHS):
			_raster_side_tile(img, k * TILE, a * TILE, cells, k)
		_raster_top_tile(img, AZIMUTHS * TILE, a * TILE, cells)
	return ImageTexture.create_from_image(img)

## §4.2 side view k: orthographic azimuth α_k = k·45° about the vertical, elevation 0. Painter's algorithm (far
## first) over the projected (u = cell·right, v = cell.y) with the ground row at tile BOTTOM (v flipped). The tile
## content fills the pad-inset span [minu,maxu]×[minv,maxv]; the shader scales the quad to the instance's projected
## width so the tile maps edge-to-edge at the sampled azimuth.
static func _raster_side_tile(img: Image, ox: int, oy: int, cells: Array, k: int) -> void:
	var ang := float(k) * (PI / 4.0)
	var sa := sin(ang)
	var ca := cos(ang)
	# right = (−sin α, 0, cos α); dir (toward camera) = (−cos α, 0, −sin α). Painter: sort by depth ascending (far first).
	var order := cells.duplicate()
	order.sort_custom(func(p, q):
		var cp: Vector4i = p
		var cq: Vector4i = q
		var dp := -float(cp.x) * ca - float(cp.z) * sa
		var dq := -float(cq.x) * ca - float(cq.z) * sa
		return dp < dq)
	var minu := 1e9; var maxu := -1e9; var minv := 1e9; var maxv := -1e9
	for c in cells:
		var cv: Vector4i = c
		var u := -float(cv.x) * sa + float(cv.z) * ca
		var v := float(cv.y)
		minu = minf(minu, u); maxu = maxf(maxu, u)
		minv = minf(minv, v); maxv = maxf(maxv, v)
	var du := maxf(maxu - minu, 1.0)
	var dv := maxf(maxv - minv, 1.0)
	# inner = pad-inset drawable region; the block splat extends +blk from its top-left, so scale positions over
	# (inner − blk) to keep every splatted texel inside [PAD, TILE−PAD) — no opaque pixel touches the tile border.
	var inner := float(TILE) - 2.0 * PAD
	var blk := int(ceil(inner / maxf(du, dv))) + 1
	var span := maxf(inner - float(blk), 1.0)
	for c in order:
		var cv: Vector4i = c
		var u := -float(cv.x) * sa + float(cv.z) * ca
		var v := float(cv.y)
		var fu := (u - minu) / du
		var fv := (v - minv) / dv
		var px := int(PAD + fu * span)
		var py := int(PAD + (1.0 - fv) * span)              # ground (min v) at tile BOTTOM
		var colr := _st_color_of(cv.w)
		colr.a = 1.0
		_fill_rect(img, ox + px, oy + py, blk, colr)

## §4.2 top view: for each (lx, lz) column paint the TOPMOST solid template block's colour (the top_decoration law,
## restricted to the canonical house). u along +x̂, v along +ẑ (no flip). Fills the pad-inset span edge-to-edge.
static func _raster_top_tile(img: Image, ox: int, oy: int, cells: Array) -> void:
	var top: Dictionary = {}                                # Vector2i(lx,lz) -> Vector4i (max-y solid cell)
	for c in cells:
		var cv: Vector4i = c
		var key := Vector2i(cv.x, cv.z)
		var cur: Variant = top.get(key)
		if cur == null or cv.y > (cur as Vector4i).y:
			top[key] = cv
	if top.is_empty():
		return
	var minx := 1e9; var maxx := -1e9; var minz := 1e9; var maxz := -1e9
	for k in top.keys():
		var kk: Vector2i = k
		minx = minf(minx, float(kk.x)); maxx = maxf(maxx, float(kk.x))
		minz = minf(minz, float(kk.y)); maxz = maxf(maxz, float(kk.y))
	var dx := maxf(maxx - minx, 1.0)
	var dz := maxf(maxz - minz, 1.0)
	var inner := float(TILE) - 2.0 * PAD
	var blk := int(ceil(inner / maxf(dx, dz))) + 1
	var span := maxf(inner - float(blk), 1.0)
	for k in top.keys():
		var kk: Vector2i = k
		var cv: Vector4i = top[k]
		var fu := (float(kk.x) - minx) / dx
		var fv := (float(kk.y) - minz) / dz
		var px := int(PAD + fu * span)
		var py := int(PAD + fv * span)
		var colr := _st_color_of(cv.w)
		colr.a = 1.0
		_fill_rect(img, ox + px, oy + py, blk, colr)

static func _fill_rect(img: Image, x0: int, y0: int, sz: int, c: Color) -> void:
	for yy in range(y0, y0 + sz):
		if yy < 0 or yy >= img.get_height():
			continue
		for xx in range(x0, x0 + sz):
			if xx < 0 or xx >= img.get_width():
				continue
			img.set_pixel(xx, yy, c)

## §4.1: resolve a house cell's far colour — the texture MEAN under FP_FT_TEXMEAN_COLOR (matches the near textured
## blocks at the handoff, mirroring _ft_color_of), else the shipped flat BlockCatalog swatch.
static func _st_color_of(id: int) -> Color:
	if CubeSphere.FP_FT_TEXMEAN_COLOR:
		return BlockTextures.mean_color_of(id)
	return BlockCatalog.color_of(id)
