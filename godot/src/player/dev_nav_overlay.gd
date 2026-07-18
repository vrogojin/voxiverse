extends Control
class_name DevNavOverlay
## COSMOS SPACE-NAV SN5 (docs/COSMOS-SPACE-NAV-DESIGN.md §7.3) — the dev-nav OVERLAY set. A Control-layer HUD
## (compass strip + per-body labels via draw_line/draw_string — NO materials) plus a Node3D bag of UNSHADED
## vertex-colour LINE MESHES (spin-axis, equator ring, facet borders, orbit line). **NO lit spatial shaders
## anywhere** (the P3 lesson): the 3-D guides use a StandardMaterial3D in SHADING_MODE_UNSHADED with
## vertex-colour albedo — the same safe class as the far-ring's unshaded rebuild path, NOT a bespoke lit shader.
##
## Lazy-built on the first F (dev-nav on), reused, and FREED on toggle off. NEVER-OOM: every mesh is bounded
## (equator ≤ 129 verts, orbit ≤ 257, axis 2, ≤ 9 facet-border loops × 4 edges) and the total is asserted
## ≤ OVERLAY_CAP_BYTES = 64 KB by G-SN-DEVNAV. DEAD unless CubeSphere.SN_DEVNAV (the player never creates it).
##
## HONEST split: `compass_heading` (the pure heading function) + the byte cap + the build/free lifecycle are
## HEADLESS-GATED (verify_dev_nav — G-SN-DEVNAV). The LEGIBILITY / aesthetics of every overlay (how the compass
## reads, guide placement in the live camera) are LIVE-ONLY (morning session). The guides are placed in the
## BODY-FIXED frame; refreshing them against the live render frame at altitude is part of the morning check.

const DV := preload("res://src/cosmos/dvec3.gd")

## NEVER-OOM hard cap (§9): the whole overlay set — meshes + control — must fit here.
const OVERLAY_CAP_BYTES := 65536
const EQUATOR_SEGMENTS := 128       # equator ring resolution (129 verts closed)
const ORBIT_SAMPLES := 256          # heliocentric-orbit line resolution (257 verts)
const _BYTES_PER_VERT := 28         # PackedVector3Array (12) + PackedColorArray (16) per line vertex

# Colours (unshaded vertex albedo) — legibility tuned live.
const COL_AXIS := Color(0.5, 0.7, 1.0)
const COL_EQUATOR := Color(1.0, 0.85, 0.3)
const COL_BORDER := Color(0.4, 1.0, 0.6)
const COL_ORBIT := Color(1.0, 0.5, 0.8)

var _built := false
var _line_root: Node3D = null       # world-space parent for the 3-D guides (top_level)
var _meshes: Array = []             # the MeshInstance3D guides (for free + byte accounting)
var _line_mat: StandardMaterial3D = null
var _heading_deg := 0.0             # current compass heading (updated per frame; drawn by _draw)
var _nav_label := ""                # current NavMode name (drawn top-centre)

# ---------------------------------------------------------------------------------------
# The PURE compass heading function (§7.3) — gate-pinned (east-at-equator == 90°, pole degeneracy handled).
# north = normalize(ẑ − (ẑ·r̂)r̂); east = normalize(ẑ × r̂); heading = atan2(f·east, f·north) with f = the
# camera forward projected to the tangent plane. `spin_axis`/`rhat`/`forward` are DVec3 (BCI). Returns degrees
# in [0, 360). At a pole (r̂ ∥ ẑ ⇒ north degenerate) it returns 0 (heading is undefined there).
# ---------------------------------------------------------------------------------------
static func compass_heading(spin_axis: PackedFloat64Array, rhat: PackedFloat64Array, forward: PackedFloat64Array) -> float:
	var north := DV.sub(spin_axis, DV.scale(rhat, DV.dot(spin_axis, rhat)))
	var nl := DV.length(north)
	if nl < 1.0e-9:
		return 0.0                                      # at the pole: heading undefined
	north = DV.scale(north, 1.0 / nl)
	var east := _cross(spin_axis, rhat)
	var el := DV.length(east)
	if el < 1.0e-9:
		return 0.0
	east = DV.scale(east, 1.0 / el)
	var f := DV.sub(forward, DV.scale(rhat, DV.dot(forward, rhat)))   # forward in the tangent plane
	if DV.length(f) < 1.0e-9:
		return 0.0
	var h := atan2(DV.dot(f, east), DV.dot(f, north))
	return rad_to_deg(wrapf(h, 0.0, TAU))

static func _cross(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	return DV.v(a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])

# ---------------------------------------------------------------------------------------
# Lifecycle — lazy build / free. `world_parent` is the Node3D the guides attach to (top_level, so world-space).
# ---------------------------------------------------------------------------------------

## Build the overlay set (idempotent). Creates the compass Control (self) + the 3-D line-mesh guides under a
## top_level Node3D child of `world_parent`. `body_radius` sizes the axis/equator; `spin_axis` is the BCI +Z.
func build(world_parent: Node, body_radius: float) -> void:
	if _built:
		return
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_line_mat = StandardMaterial3D.new()
	_line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED       # NO lit spatial shader (P3 lesson)
	_line_mat.vertex_color_use_as_albedo = true
	_line_root = Node3D.new()
	_line_root.name = "DevNavGuides"
	_line_root.top_level = true
	world_parent.add_child(_line_root)
	# Spin-axis line (±1.5R along +Z through the body centre) and the equator ring (r = 1.02R in the XY plane).
	_add_line(_axis_verts(body_radius), COL_AXIS, false)
	_add_line(_ring_verts(body_radius * 1.02), COL_EQUATOR, true)
	_built = true

## Replace the facet-border loops (active + ring-1). `loops` is an Array of PackedVector3Array (each a closed
## polyline in world space). Rebuilt only on a facet crossing (bounded ≤ 9 loops); reuses the material.
func set_facet_borders(loops: Array) -> void:
	if not _built:
		return
	for v in loops:
		_add_line(v, COL_BORDER, true)

## Update the per-frame HUD scalars (compass heading + NavMode name). Cheap; triggers a Control redraw.
func update_hud(heading_deg: float, nav_name: String) -> void:
	_heading_deg = heading_deg
	_nav_label = nav_name
	queue_redraw()

## Free every overlay node (on dev-nav off). Idempotent; returns to the pre-build byte footprint (0).
func free_overlays() -> void:
	for m in _meshes:
		if is_instance_valid(m):
			m.queue_free()
	_meshes.clear()
	if _line_root != null and is_instance_valid(_line_root):
		_line_root.queue_free()
	_line_root = null
	_line_mat = null
	_built = false
	queue_redraw()

## The total retained overlay bytes (line-mesh vertex arrays) — asserted ≤ OVERLAY_CAP_BYTES by G-SN-DEVNAV.
func bytes_estimate() -> int:
	var total := 0
	for m in _meshes:
		if is_instance_valid(m) and m.mesh is ArrayMesh:
			total += int(m.get_meta("vert_bytes", 0))
	return total

func is_built() -> bool:
	return _built

# ---------------------------------------------------------------------------------------
# Geometry builders (pure). All in the BODY-FIXED frame (the planet is pinned) — the guides are static in-scene.
# ---------------------------------------------------------------------------------------
func _axis_verts(r: float) -> PackedVector3Array:
	return PackedVector3Array([Vector3(0, 0, -1.5 * r), Vector3(0, 0, 1.5 * r)])

func _ring_verts(r: float) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for i in range(EQUATOR_SEGMENTS + 1):
		var a := TAU * float(i) / float(EQUATOR_SEGMENTS)
		pts.append(Vector3(r * cos(a), r * sin(a), 0.0))
	return pts

func _add_line(verts: PackedVector3Array, col: Color, strip: bool) -> void:
	if verts.size() < 2 or _line_root == null:
		return
	var cols := PackedColorArray()
	cols.resize(verts.size())
	cols.fill(col)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_LINE_STRIP if strip else Mesh.PRIMITIVE_LINES, arrays)
	am.surface_set_material(0, _line_mat)
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.set_meta("vert_bytes", verts.size() * _BYTES_PER_VERT)
	_line_root.add_child(mi)
	_meshes.append(mi)

# ---------------------------------------------------------------------------------------
# The Control HUD (§7.3): the top-centre compass strip + the NavMode label. Pure draw_* — no materials.
# ---------------------------------------------------------------------------------------
func _draw() -> void:
	if not _built:
		return
	var w := size.x
	var font := ThemeDB.fallback_font
	var fs := 14
	# NavMode label, top-centre.
	if _nav_label != "":
		var lbl := _nav_label.to_upper()
		var lw := font.get_string_size(lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, Vector2(w * 0.5 - lw * 0.5, 22), lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.8, 0.9, 1.0))
	# Compass strip: a horizontal band with a moving tick scale centred on the heading; cardinal letters.
	var cy := 40.0
	var half := 200.0
	var cx := w * 0.5
	draw_line(Vector2(cx - half, cy), Vector2(cx + half, cy), Color(1, 1, 1, 0.35), 1.0)
	# Ticks every 15°, cardinals every 90°; the strip spans ±90° of heading around centre (2 px/deg).
	for d in range(-90, 91, 15):
		var hd := wrapf(_heading_deg + float(d), 0.0, 360.0)
		var x := cx + float(d) * (half / 90.0)
		var tall := 8.0 if int(round(hd)) % 90 == 0 else 4.0
		draw_line(Vector2(x, cy - tall), Vector2(x, cy + tall), Color(1, 1, 1, 0.6), 1.0)
	# Centre marker + numeric heading.
	draw_line(Vector2(cx, cy - 12), Vector2(cx, cy + 12), Color(1, 0.9, 0.3), 2.0)
	var htxt := "%03d°" % int(round(_heading_deg))
	draw_string(font, Vector2(cx - 14, cy + 28), htxt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 0.9, 0.3))
