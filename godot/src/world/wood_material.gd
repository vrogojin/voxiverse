class_name WoodMaterial
extends RefCounted
## Builds the shared wooden-block material used by wood voxels (tree trunks and
## the detached wood+leaf bodies from chopping them).
##
## Unshaded (matching the grass surface — flat ambient look, no sun) with a
## procedurally-generated 64x64 wood-grain texture baked at runtime into an
## ImageTexture. Runtime generation means there is no PNG asset to import, so this
## works identically headless and on the web export. UVs from the voxel-body
## mesher are in world-metre units (1 tile per voxel face), so one block face
## shows exactly one texture tile.

const SIZE := 64
const SEED := 61803

static var _cached: StandardMaterial3D

## Shared wooden-block material (built once, reused by every VoxelBody).
static func build() -> StandardMaterial3D:
	if _cached != null:
		return _cached
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 1, 1)
	# Double-sided so newly-exposed inner faces read correctly no matter the
	# winding after a block is broken away. Cheap here (unshaded).
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = _bake_texture()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mat.texture_repeat = true
	mat.vertex_color_use_as_albedo = true
	_cached = mat
	return mat

static func _bake_texture() -> ImageTexture:
	return ImageTexture.create_from_image(_build_image())

# Deterministic value hash in [0,1] for integer lattice coords.
static func _hash(ix: int, iy: int) -> float:
	var n := (ix * 374761393 + iy * 668265263 + SEED * 362437) & 0xFFFFFFFF
	n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
	n = n ^ (n >> 16)
	return float(n & 0xFFFF) / 65535.0

static func _smooth(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)

static func _value_noise(x: float, y: float) -> float:
	var x0 := int(floor(x))
	var y0 := int(floor(y))
	var tx := _smooth(x - x0)
	var ty := _smooth(y - y0)
	var v00 := _hash(x0, y0)
	var v10 := _hash(x0 + 1, y0)
	var v01 := _hash(x0, y0 + 1)
	var v11 := _hash(x0 + 1, y0 + 1)
	var a := v00 + (v10 - v00) * tx
	var b := v01 + (v11 - v01) * tx
	return a + (b - a) * ty

## A warm brown plank texture: vertical grain lines with a little wander plus fine
## mottle, so wooden blocks read clearly against the grass. Deterministic (SEED).
static func _build_image() -> Image:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y in SIZE:
		for x in SIZE:
			var fx := float(x)
			var fy := float(y)
			# Grain: tight vertical rings that wander slightly along y.
			var wander := _value_noise(fx * 0.12, fy * 0.9) * 3.0
			var grain := sin((fx + wander) * 0.9) * 0.5 + 0.5
			grain = pow(grain, 1.6)                       # sharpen the darker lines
			var mottle := _value_noise(fx * 0.35, fy * 0.35)
			var l := 0.55 + 0.35 * grain + (mottle - 0.5) * 0.25
			l = clampf(l, 0.28, 1.0)
			var r := 92.0 + 78.0 * l
			var g := 56.0 + 60.0 * l
			var b := 30.0 + 34.0 * l
			img.set_pixel(x, y, Color(
				clampf(r, 0, 255) / 255.0,
				clampf(g, 0, 255) / 255.0,
				clampf(b, 0, 255) / 255.0,
				1.0))
	return img
