class_name PortalSurface
extends Node3D
## One source frame's rendered portal (PORTALS §3.5.5): a quad on visual layer 2 (the
## player sees it), an energy "fill" quad on layer 3 (portal cameras see it → a portal
## seen through a portal shows energy, recursion depth 0), and — only while ACTIVE — a
## SubViewport whose off-axis window-frustum Camera3D renders the destination view that
## the quad samples. The manager drives every surface; a surface holds no logic loop.
##
## INACTIVE (far/off-screen/out-of-budget) → the quad wears the shared energy material and
## the SubViewport is UPDATE_DISABLED (or freed); ACTIVE → the quad wears the per-portal
## portal shader sampling the live view.

## The ONE portal shader resource, shared by every surface (one Compatibility pipeline).
static var _shader: Shader = null
## The ONE shared energy material (fills, inactive quads, the §5 kill-switch surface).
static var _energy: StandardMaterial3D = null

## Destination streaming (PORTALS §3.5.6): a small-radius VoxelViewer parked at the
## destination so the far-side blocks actually stream in and render behind the opening
## (the owner's required "show the real other-side blocks" visual). Module path only —
## instantiated via ClassDB so this file still loads when godot_voxel is absent.
const DEST_VIEW_DISTANCE := 64
## Seconds a deactivated surface keeps its SubViewport + destination viewer before freeing
## them, so peeking repeatedly doesn't thrash the stream / reallocate the FBO.
const LINGER_SEC := 10.0

var _src: PortalFrame
var _dst: PortalFrame
var _quad: MeshInstance3D                     # layer 2 — live view (player camera only)
var _fill: MeshInstance3D                     # layer 3 — energy fill (portal cameras only)
var _subviewport: SubViewport = null           # created lazily on first activation
var _camera: Camera3D = null
var _dest_viewer: Node = null                  # VoxelViewer parked at the destination (module path)
var _portal_mat: ShaderMaterial
var _active := false
var _linger_left := 0.0                        # deactivation grace countdown

## Build the quad + fill (both at the source frame's transform) and the per-portal
## material. Starts INACTIVE (energy look). The SubViewport is created lazily on first
## activation so an unlinked/never-seen portal never allocates an FBO.
func configure(src: PortalFrame, dst: PortalFrame) -> void:
	_src = src
	_dst = dst
	var mesh := QuadMesh.new()
	mesh.size = Vector2(float(src.width), float(src.height))
	var xf := src.global_transform()
	_portal_mat = make_portal_material()

	_quad = MeshInstance3D.new()
	_quad.name = "Quad"
	_quad.mesh = mesh
	_quad.transform = xf
	_quad.layers = 1 << 1                      # visual layer 2 (player camera cull_mask = 1|2)
	_quad.material_override = energy_material() # inactive until activated
	add_child(_quad)

	_fill = MeshInstance3D.new()
	_fill.name = "Fill"
	_fill.mesh = mesh                          # shared mesh resource; coincident (no camera sees both)
	_fill.transform = xf
	_fill.layers = 1 << 2                      # visual layer 3 (portal camera cull_mask = 1|3)
	_fill.material_override = energy_material()
	add_child(_fill)

func is_active() -> bool:
	return _active

## Activate: create/size the SubViewport target (once), swap the quad to the live portal
## material, and start rendering. `size_px` is set ONCE here (resizing reallocates the FBO).
func activate(size_px: Vector2i) -> void:
	if _active:
		return
	_active = true
	_linger_left = 0.0                         # re-activation cancels a pending free
	_ensure_subviewport(size_px)
	_ensure_dest_viewer()
	_quad.material_override = _portal_mat
	if _subviewport != null:
		_subviewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

## Deactivate: back to the energy look, stop the SubViewport pass (kept allocated for a
## grace period; `free_viewport()` releases it after the linger).
func deactivate() -> void:
	if not _active:
		return
	_active = false
	_quad.material_override = energy_material()
	if _subviewport != null:
		_subviewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_linger_left = LINGER_SEC                   # start the grace countdown (viewport + viewer freed after)

## Advance the deactivation linger; free the SubViewport + destination viewer when it
## expires. Driven by the manager for INACTIVE surfaces (no per-surface loop). No-op while
## active or already freed.
func tick_idle(delta: float) -> void:
	if _active or _linger_left <= 0.0:
		return
	_linger_left -= delta
	if _linger_left <= 0.0:
		free_viewport()
		_free_dest_viewer()

## Release the SubViewport FBO + camera entirely (called after the deactivation linger to
## reclaim the web frame budget). Safe to call repeatedly.
func free_viewport() -> void:
	if _subviewport != null:
		_subviewport.queue_free()
		_subviewport = null
		_camera = null

## Continuous rendering (UPDATE_ALWAYS) — the default for the primary active portal.
func set_continuous() -> void:
	if _active and _subviewport != null:
		_subviewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

## Manual rendering (UPDATE_DISABLED between explicit `pulse()`s) — the half-rate path for
## a 2nd active portal on the web budget.
func set_manual() -> void:
	if _active and _subviewport != null and _subviewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS:
		_subviewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

## True iff a destination VoxelViewer is currently parked (module path, active).
func has_dest_viewer() -> bool:
	return _dest_viewer != null

func _ensure_dest_viewer() -> void:
	if _dest_viewer != null:
		return
	# Module path only. Instantiated by string via ClassDB (like module_world.attach_viewer)
	# so this file loads cleanly when godot_voxel is absent — the fallback path shows fog.
	if not ClassDB.class_exists("VoxelViewer"):
		return
	var v: Node = ClassDB.instantiate("VoxelViewer")
	if v == null:
		return
	_dest_viewer = v
	if v.has_method("set_view_distance"):
		v.call("set_view_distance", DEST_VIEW_DISTANCE)
	else:
		v.set("view_distance", DEST_VIEW_DISTANCE)
	v.set("requires_collisions", false)
	add_child(v)
	(v as Node3D).global_position = _dst.center()

func _free_dest_viewer() -> void:
	if _dest_viewer != null:
		_dest_viewer.queue_free()
		_dest_viewer = null

## Force one render of the current view (SubViewport UPDATE_ONCE) — the half-rate pulse
## path (Stage 4). No-op when inactive / no viewport.
func pulse() -> void:
	if _active and _subviewport != null:
		_subviewport.render_target_update_mode = SubViewport.UPDATE_ONCE

## Per-frame: aim the window-frustum camera from the player eye. Only the eye position and
## near/offset change (the basis does not track the player's look) — one transform update.
func update_view(eye: Vector3, far: float) -> void:
	if not _active or _camera == null:
		return
	var p := PortalMath.window_camera(eye, _src, _dst, far)
	_camera.global_transform = p["transform"]
	_camera.set_frustum(p["size"], p["offset"], p["near"], far)
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_portal_mat.set_shader_parameter("flip_u", p["flip_u"])

## True if the quad centre is on the given side function — helper for edge-on tests done
## by the manager; here we expose the source frame for the manager's policy.
func source_frame() -> PortalFrame:
	return _src

func _ensure_subviewport(size_px: Vector2i) -> void:
	if _subviewport == null:
		_subviewport = SubViewport.new()
		_subviewport.name = "PortalViewport"
		# Shared-world RTT recipe (Godot viewports doc): render the MAIN scene's World3D.
		_subviewport.own_world_3d = false
		var w3d := get_viewport().find_world_3d() if get_viewport() != null else null
		if w3d != null:
			_subviewport.world_3d = w3d
		_subviewport.msaa_3d = Viewport.MSAA_DISABLED
		_subviewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		_subviewport.use_debanding = false
		_subviewport.positional_shadow_atlas_size = 0    # no shadows in this scene
		_subviewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(_subviewport)
		_camera = Camera3D.new()
		_camera.name = "PortalCamera"
		# Portal cameras see world (layer 1) + energy fills (layer 3), NEVER live quads
		# (layer 2) → a portal seen through a portal shows energy, recursion depth 0.
		_camera.cull_mask = (1 << 0) | (1 << 2)
		_camera.current = true
		_subviewport.add_child(_camera)
		_portal_mat.set_shader_parameter("view_tex", _subviewport.get_texture())
	_subviewport.size = size_px

# --- shared resources ----------------------------------------------------------

## A fresh per-portal ShaderMaterial sharing the ONE portal shader (Compatibility has no
## instance uniforms, so per-portal state — view_tex, flip_u — rides a material instance).
static func make_portal_material() -> ShaderMaterial:
	if _shader == null:
		_shader = load("res://assets/portal.gdshader") as Shader
	var m := ShaderMaterial.new()
	m.shader = _shader
	return m

## The ONE shared energy material: unshaded violet with a mild glow, double-sided. Used
## for fills, inactive quads, and the §5 kill-switch surface.
static func energy_material() -> StandardMaterial3D:
	if _energy == null:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(0.45, 0.2, 0.85)
		m.emission_enabled = true
		m.emission = Color(0.45, 0.2, 0.85)
		m.emission_energy_multiplier = 0.6
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_energy = m
	return _energy
