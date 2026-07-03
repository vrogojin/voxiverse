class_name GrassMaterial
extends RefCounted
## Builds the shared StandardMaterial3D surface materials (grass and snow).
##
## Unshaded so the world reads as evenly, flatly lit regardless of light setup
## (DESIGN §1: ambient/omnidirectional only, no sun, no shadows). The albedo
## texture tiles once per metre — the fallback mesher and module both emit UVs
## in world-metre units, so a 1 m voxel face shows exactly one texture tile.

const TEXTURE_PATH := "res://assets/textures/grass.png"
const SNOW_TEXTURE_PATH := "res://assets/textures/snow.png"

## Grass surface material.
static func build() -> StandardMaterial3D:
	return _build(TEXTURE_PATH, Color(0.30, 0.55, 0.24))

## Snow surface material.
static func build_snow() -> StandardMaterial3D:
	return _build(SNOW_TEXTURE_PATH, Color(0.92, 0.95, 1.0))

static func _build(texture_path: String, fallback_color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 1, 1)
	# Double-sided: the world reads correctly no matter the triangle winding
	# (bulletproofs the web build against a culling mix-up) and lets noclip view
	# terrain from below. Cheap here because the material is unshaded.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var tex := load(texture_path) as Texture2D
	if tex != null:
		mat.albedo_texture = tex
		# Crisp voxel look; repeat so per-metre UVs tile seamlessly.
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
		mat.texture_repeat = true
	else:
		# Fallback tint if the asset is missing for any reason.
		mat.albedo_color = fallback_color

	# A hair of vertex-colour tinting support for future per-voxel look changes.
	mat.vertex_color_use_as_albedo = true
	return mat
