class_name PortalFrame
extends RefCounted
## A detected obsidian portal FRAME: a closed axis-aligned rectangular ring of obsidian
## on a VERTICAL plane with an all-air interior (PORTALS §3.3). Pure value object — it
## holds only the frame's coordinates; the world is read exclusively through
## `WorldManager.block_id_at` by PortalFrameDetector, never here.
##
## Orientation. Two vertical-plane orientations, named by the plane-NORMAL axis:
##   * AXIS_X: plane normal ±X; the ring spans Z (width, "tangent") × Y (height) at fixed x.
##   * AXIS_Z: plane normal ±Z; the ring spans X (width, "tangent") × Y (height) at fixed z.
## The tangent (width) axis is always horizontal; height is always +Y. Horizontal
## (floor/ceiling) rings are impossible by construction — the reject case in §3.7.

const AXIS_X := 0
const AXIS_Z := 1

## Interior size bounds (interior AIR cells). 1×2 is a doorway (the 0.8 m capsule fits a
## 1-cell opening); 8×8 bounds detection cost, the render target size and the lintel span.
const MIN_W := 1
const MIN_H := 2
const MAX_W := 8
const MAX_H := 8

var axis: int                    # AXIS_X or AXIS_Z (the plane-normal axis)
var interior_min: Vector3i       # min-corner interior AIR cell (canonical key part)
var width: int                   # interior cells along the tangent (horizontal) axis
var height: int                  # interior cells along Y

func _init(p_axis: int = AXIS_Z, p_interior_min: Vector3i = Vector3i.ZERO, p_width: int = 1, p_height: int = 2) -> void:
	axis = p_axis
	interior_min = p_interior_min
	width = p_width
	height = p_height

## THE registry key: (interior_min.x, .y, .z, axis). Two frames are the same iff their
## min-corner interior cell and orientation match — unique because the interior_min +
## (axis, w, h) fully determine the cell set, and a given interior_min/axis admits only
## one maximal air rectangle bounded by obsidian.
func key() -> Vector4i:
	return Vector4i(interior_min.x, interior_min.y, interior_min.z, axis)

## The horizontal unit step (Vector3i) along which width is measured: +Z for AXIS_X,
## +X for AXIS_Z. (The RENDER basis right-vector may point the opposite way for
## handedness — see `global_transform`; this is the cell-layout tangent only.)
func tangent_dir() -> Vector3i:
	return Vector3i(0, 0, 1) if axis == AXIS_X else Vector3i(1, 0, 0)

## The plane-normal unit step (Vector3i), always the POSITIVE axis: +X for AXIS_X,
## +Z for AXIS_Z ("front" — an arbitrary but fixed choice).
func normal_dir() -> Vector3i:
	return Vector3i(1, 0, 0) if axis == AXIS_X else Vector3i(0, 0, 1)

## The w*h interior AIR cells.
func interior_cells() -> Array[Vector3i]:
	var t := tangent_dir()
	var out: Array[Vector3i] = []
	for j in range(height):
		for i in range(width):
			out.append(interior_min + t * i + Vector3i(0, j, 0))
	return out

## The 2*(w+h)+4 obsidian RING cells (all four corners included): the border one cell
## out around the interior rectangle, in the frame plane.
func ring_cells() -> Array[Vector3i]:
	var t := tangent_dir()
	var out: Array[Vector3i] = []
	for j in range(-1, height + 1):
		for i in range(-1, width + 1):
			if i == -1 or i == width or j == -1 or j == height:
				out.append(interior_min + t * i + Vector3i(0, j, 0))
	return out

## True iff `cell` is one of this frame's INTERIOR (air) cells. O(1) — projects the cell
## onto the frame's local (tangent, up, normal) indices rather than scanning the cell list.
## Used by the manager's edit-teardown handler (a block placed inside disrupts the portal).
func is_interior(cell: Vector3i) -> bool:
	var delta := cell - interior_min
	var normal_off := delta.x if axis == PortalFrame.AXIS_X else delta.z
	if normal_off != 0:
		return false
	var ti := delta.z if axis == PortalFrame.AXIS_X else delta.x
	return ti >= 0 and ti < width and delta.y >= 0 and delta.y < height

## The interior centre in WORLD space: the geometric centre of the w×h interior region,
## with the plane coordinate on the MID-PLANE of the single interior cell layer
## (normal-axis coordinate = interior_min.<normal> + 0.5). Origin of `global_transform`.
func center() -> Vector3:
	var t := tangent_dir()
	var n := normal_dir()
	return Vector3(interior_min) + Vector3(t) * (float(width) * 0.5) \
		+ Vector3(0.0, float(height) * 0.5, 0.0) + Vector3(n) * 0.5

## The canonical frame transform (used by quad placement, camera math, teleport; pinned
## in verify). Columns: X = right (tangent), Y = up (+Y), Z = normal (front). To keep the
## Basis orthonormal AND right-handed (Godot requires det=+1 for cameras), AXIS_X uses
## right = -Z (the naive +Z tangent would give a left-handed swap); AXIS_Z is the identity
## basis. `basis.y == UP` and `basis.determinant() == 1` for both (PORTALS §3.3).
func global_transform() -> Transform3D:
	var b: Basis
	if axis == AXIS_X:
		# normal = +X (front), up = +Y, right = -Z (handedness fix)
		b = Basis(Vector3(0, 0, -1), Vector3(0, 1, 0), Vector3(1, 0, 0))
	else:
		# AXIS_Z: right = +X, up = +Y, normal = +Z → identity basis
		b = Basis(Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
	return Transform3D(b, center())
