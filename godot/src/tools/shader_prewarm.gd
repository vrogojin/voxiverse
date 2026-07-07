class_name ShaderPrewarm
extends Node3D
## Load-time shader/material PIPELINE pre-warm for the GL Compatibility renderer
## (RENDER-STREAMING-SPIKES). Runs once, during a brief "Loading…" overlay, BEFORE
## the player gets control.
##
## WHY THIS EXISTS — the root cause:
##   The live web build runs the GL Compatibility renderer (ANGLE → Direct3D11 on
##   weak Intel HD GPUs). That renderer compiles each distinct shader/material
##   PIPELINE synchronously ON THE MAIN THREAD the FIRST time that pipeline is
##   actually DRAWN. Godot 4.4 has NO precompile-at-load for Compatibility (it
##   exists only for Forward+/Mobile via ubershaders; proposal
##   godotengine/godot-proposals#12119 to add it to Compatibility is still open).
##   So every distinct StandardMaterial3D variant the world uses — opaque-textured,
##   opaque solid-swatch, translucent alpha-prepass (CULL_BACK), translucent
##   CULL_DISABLED (water), emissive — compiles its pipeline the first time it
##   scrolls into view during gameplay, and ANGLE's GLSL→HLSL→D3D translation makes
##   each compile hundreds of ms → the 800–950 ms one-off frame spikes players hit
##   while exploring.
##
## THE ONLY MECHANISM AVAILABLE for Compatibility: actually DRAW one instance of
##   every material/mesh-format combination for a few frames while a full-screen
##   opaque overlay hides them, so ANGLE does ALL the compiles up front (one hidden
##   load stall) instead of scattered through exploration. Freeing the warm-up
##   nodes afterwards leaves the pipelines resident in the driver cache.
##
## ROBUSTNESS PRINCIPLE — we do NOT reason about which variants share a pipeline.
##   We warm a guaranteed SUPERSET by reusing the REAL builders the game uses, so
##   vertex formats and material feature-sets match BY CONSTRUCTION:
##     * one CUBE per non-AIR BlockCatalog id, meshed exactly the way VoxelBody
##       builds its exposed-face mesh (SurfaceTool, PRIMITIVE_TRIANGLES, per-vertex
##       normal + uv + colour), surfaced with BlockMaterials.get_for(id); and
##     * one SHAPED mesh per TerrainConfig.emitted_modifiers() modifier built via
##       ShapeMesh.build (the same ARRAY_VERTEX/NORMAL/TEX_UV/INDEX layout the
##       module library + VoxelBody use), applied with an opaque, a translucent and
##       an emissive material so those variants on the shaped vertex format are
##       covered too.
##
## VISIBILITY — the pipelines only compile when the meshes are actually DRAWN by the
##   real gameplay camera under the real environment (fog is enabled in main.gd and
##   participates in the Compatibility pipeline). So the warm-up instances are placed
##   in a tight grid ~2 m directly in front of the player's camera, small (0.2 m), so
##   none are frustum-culled and all are past the near plane — then a full-screen
##   opaque overlay covers the pile (and the terrain streaming in) from the user.
##
## THE MODULE-FORMAT GAP → a second phase. The grid above warms every material on the
##   GDScript/VoxelBody vertex format (which IS the format of gameplay debris meshes),
##   but the live build draws TERRAIN through the godot_voxel module's own
##   VoxelMesherBlocky vertex format — a DISTINCT Compatibility pipeline the grid cannot
##   reproduce. The module meshes async on the (web-capped) single voxel thread and
##   usually finishes the first chunks only AFTER the grid frames, so that pipeline used
##   to compile in gameplay (the ~568 ms first-chunk stall). Rather than guess the
##   module's exact vertex format, PHASE 2 warms the REAL thing by construction: after
##   freeing the grid it HOLDS the overlay while the streamed near view meshes + renders
##   behind it (polling WorldManager.initial_view_meshed → VoxelTerrain.is_area_meshed as
##   an early-out, within a floor/cap window), so the module pipeline compiles hidden,
##   then lifts. See WARMUP_FRAMES / the TERRAIN_* constants and _process().

signal finished

## Rendered frames the warm-up PILE (the in-front grid) is kept alive. It is all drawn on the FIRST
## frame, so its compiles happen at once; the margin covers a driver that defers a few. The pile is
## freed at WARMUP_FRAMES — but on a MODULE build the overlay is then HELD through a second phase (see
## below) until the real streamed terrain has drawn behind it, so its pipeline compiles hidden too.
const WARMUP_FRAMES := 12

## PHASE 2 — TERRAIN-MESHED HOLD (module builds; the ~568 ms first-chunk stall fix). The grid pile warms
## every material on the GDScript/VoxelBody vertex format, but the live build draws terrain through the
## godot_voxel module's OWN VoxelMesherBlocky format — a DISTINCT GL-Compatibility pipeline the pile
## cannot cover. The module meshes async on the (web-capped) single voxel thread and usually finishes
## the first chunks only AFTER WARMUP_FRAMES, so that pipeline used to compile in gameplay (the 568 ms
## spike). So after freeing the pile we KEEP the overlay up (module builds only) for a bounded window
## that lets the near view mesh + render + compile behind it, then lift:
##   * We POLL the module for the near view being meshed (WorldManager.initial_view_meshed →
##     VoxelTerrain.is_area_meshed) as an EARLY-OUT — but we do NOT rely on it alone, because it can't
##     be validated headlessly (meshing is render-gated) and could report a vacuous early true.
##   * A FLOOR (TERRAIN_MIN_HOLD_SEC) guarantees enough real frames pass for the compile to happen
##     hidden even if the poll returns true immediately; a CAP (TERRAIN_MAX_WAIT_SEC) guarantees the
##     loader never hangs if the poll never confirms. So the module hold is a predictable
##     [FLOOR, CAP] window, adaptive within it. Fallback / non-module builds skip the hold entirely
##     (their vertex format is already warmed by the grid pile).
const TERRAIN_MIN_HOLD_SEC := 1.5      # floor: minimum module-build hold, so the near view meshes+compiles hidden
const TERRAIN_MAX_WAIT_SEC := 4.0      # cap: lift even if is_area_meshed never confirms — never hang the loader

## Warm-up cube edge length (m). Small so the whole superset fits inside the frustum
## a couple of metres ahead of the camera.
const CUBE_SIZE := 0.2

## In-front placement of the grid and its spacing (m).
const GRID_DISTANCE := 2.0
const GRID_SPACING := 0.35

## Frustum-safe half-extent (m) of the pile in the camera plane at GRID_DISTANCE.
## The camera FOV is 75° VERTICAL (Player sets _camera.fov = 75.0, KEEP_HEIGHT), so at
## 2 m the visible half-height is 2·tan(37.5°) ≈ 1.53 m. We keep the whole pile within
## ±1.1 m on BOTH the right and up axes: comfortably inside the vertical frustum, and
## inside the horizontal frustum for any aspect ≥ ~0.6 (even a portrait-ish web canvas).
## Anything drawn outside the frustum is CULLED and never compiles its pipeline — which
## would silently leave a rare variant's spike in gameplay — so this bound is a
## correctness guarantee, not a cosmetic one. Overlap at high counts is fine (the pile is
## hidden behind the overlay; overlapping instances are still each drawn + compiled).
const GRID_SAFE_EXTENT := 1.1

## Sky colour (matches main.gd SKY_COLOR / the fog), so the overlay reads as the
## world horizon rather than a black flash.
const SKY_COLOR := Color(0.62, 0.74, 0.86)

# The 6 axis face directions, in the same order VoxelBody meshes its cube faces.
const _DIRS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

var _instances: Array[MeshInstance3D] = []   # spawned warm-up meshes
var _cube_ids: Array[int] = []                # block ids that got a warm-up cube (diagnostic)
var _shaped_mods: Dictionary = {}             # modifier -> true, shaped meshes spawned (diagnostic)
var _overlay: CanvasLayer = null              # full-screen "Loading…" cover
var _on_done: Callable = Callable()           # main.gd re-enables the player here
var _frame := 0                               # rendered-frame counter
var _finished := false
var _watch_terrain := false                   # PHASE 2 enabled? set by begin() (real boot), not by spawn_warmups()
var _wait_time := 0.0                          # accumulated seconds in the terrain-meshed hold
var _watch_world: Node = null                  # WorldManager to poll for initial_view_meshed (PHASE 2)
var _warm_center := Vector3.ZERO               # camera world position the near-view AABB is built around

## Kick off the warm-up: spawn the superset pile in front of `player`'s camera, raise
## the "Loading…" overlay, and begin the frame countdown. `on_done` (and the
## `finished` signal) fire once every pipeline has been drawn and the pile+overlay are
## torn down — main.gd re-enables the player there.
func begin(player: Node3D, on_done: Callable = Callable()) -> void:
	_on_done = on_done
	_watch_terrain = true                     # real boot → run PHASE 2 (hold for the streamed terrain)
	transform = Transform3D.IDENTITY          # instances are placed in WORLD coords below
	var cam := _camera_xform(player)
	_warm_center = cam.origin                  # near-view AABB centre for PHASE 2's is_area_meshed poll
	if player != null:
		_watch_world = player.get("world") as Node    # WorldManager (main.gd injects it); null-safe
	spawn_warmups(cam)
	_raise_overlay()
	set_process(true)

## Enumerate and spawn the warm-up superset as MeshInstance3D children, laid out in a
## grid `GRID_DISTANCE` m in front of `place_xform` (the camera transform). Returns the
## number spawned; also stored for `warmup_instance_count()`. Pure node construction —
## works headless (no GPU needed to BUILD the meshes; drawing them is what compiles the
## pipelines, and that only matters on a real device).
func spawn_warmups(place_xform: Transform3D) -> int:
	BlockCatalog.ensure_ready()
	# (mesh, material) pairs to draw. Order is irrelevant — every entry gets its own
	# instance in the grid.
	var jobs: Array = []

	# 1) One CUBE per non-AIR block id, meshed the VoxelBody way, surfaced with the
	#    real per-id material — covers every opaque/translucent/emissive CUBE variant.
	for id in range(1, BlockCatalog.count()):
		var mat := BlockMaterials.get_for(id)
		if mat == null:
			continue                          # AIR only; defensive
		jobs.append([_build_cube_mesh(mat), mat])
		_cube_ids.append(id)

	# 2) One SHAPED mesh per emitted modifier, on an opaque + a translucent + an
	#    emissive material, so the shaped vertex format is warmed for every look. The
	#    opaque set alone covers every emitted modifier (the invariant verify checks).
	for mat in _shaped_materials():
		for modifier in TerrainConfig.emitted_modifiers():
			jobs.append([_build_shape_mesh(modifier, mat), mat])
			_shaped_mods[modifier] = true

	_place_grid(jobs, place_xform)
	return _instances.size()

## The warm-up instances spawned (for verification / diagnostics).
func warmup_instance_count() -> int:
	return _instances.size()

## Block ids that got a warm-up cube (diagnostic / verification).
func warmed_cube_ids() -> Array[int]:
	return _cube_ids

## Shape modifiers that got a warm-up shaped mesh (diagnostic / verification).
func warmed_shape_modifiers() -> PackedInt32Array:
	var out := PackedInt32Array()
	for m: int in _shaped_mods.keys():
		out.append(m)
	return out

## Number of warm-up MeshInstance3D children still live (drops to 0 after teardown).
func live_mesh_instance_count() -> int:
	var n := 0
	for c in get_children():
		if c is MeshInstance3D:
			n += 1
	return n

# --- frame countdown / teardown ------------------------------------------------

## Each RENDERED frame advances the state machine. PHASE 1 (frames 1..WARMUP_FRAMES): the grid pile is
## drawn every frame, so its pipeline compiles happen on the first frame; free the pile at the budget.
## PHASE 2 (module builds only, _watch_terrain): keep the overlay up while the streamed near view
## meshes + renders behind it — lifting early once WorldManager.initial_view_meshed confirms, within
## the [TERRAIN_MIN_HOLD_SEC, TERRAIN_MAX_WAIT_SEC] window so the compile frame lands hidden and the
## loader never hangs. Non-module builds and the headless verify's spawn_warmups path (no _watch_terrain)
## keep the original lifecycle: free at WARMUP_FRAMES, finish the next frame.
func _process(delta: float) -> void:
	if _finished:
		return
	_frame += 1
	# PHASE 1 — grid warm.
	if _frame < WARMUP_FRAMES:
		return
	if _frame == WARMUP_FRAMES:
		_free_meshes()                        # pile compiles done → drop it (also stops it inflating draws)
		return
	# _frame > WARMUP_FRAMES.
	if not _watch_terrain:
		_finish()                             # verify / no-world path: original lifecycle
		return
	# PHASE 2 — terrain-meshed hold (module builds only). The path selection is DEFERRED, so check
	# using_module HERE (not in begin()). Fallback / no-module builds need no hold — the grid already
	# warmed their vertex format — so finish immediately (the original lifecycle).
	if _watch_world == null or not bool(_watch_world.get("using_module")):
		_finish()
		return
	# Module build: hold within a bounded [FLOOR, CAP] window, lifting early once the near view is
	# meshed (so its render+compile frame lands hidden), else at the cap so we never hang.
	_wait_time += delta
	var meshed := true
	if _watch_world.has_method("initial_view_meshed"):
		meshed = bool(_watch_world.call("initial_view_meshed", _warm_center))
	if (meshed and _wait_time >= TERRAIN_MIN_HOLD_SEC) or _wait_time >= TERRAIN_MAX_WAIT_SEC:
		_finish()

## Free (and detach) the warm-up meshes. Detaching via remove_child makes the child
## count drop synchronously (queue_free itself defers to frame end).
func _free_meshes() -> void:
	for mi in _instances:
		if is_instance_valid(mi):
			remove_child(mi)
			mi.queue_free()
	_instances.clear()

func _finish() -> void:
	_finished = true
	if _instances.size() > 0:
		_free_meshes()
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
		_overlay = null
	set_process(false)
	finished.emit()
	if _on_done.is_valid():
		_on_done.call()
	queue_free()

# --- overlay -------------------------------------------------------------------

## Full-screen opaque "Loading…" cover on a high CanvasLayer: an opaque SKY_COLOR
## ColorRect filling the viewport plus a centred label. Hides the warm-up pile AND the
## terrain streaming in behind it.
func _raise_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.name = "PrewarmOverlay"
	_overlay.layer = 128                      # above every gameplay HUD
	var rect := ColorRect.new()
	rect.color = SKY_COLOR
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.add_child(rect)
	var label := Label.new()
	label.text = "Loading…"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.add_child(label)
	add_child(_overlay)

# --- geometry builders ---------------------------------------------------------

## The camera's world transform (Player exposes it). Falls back to the player's own
## transform, then identity, so the warm-up still spawns in headless/standalone runs.
func _camera_xform(player: Node3D) -> Transform3D:
	if player != null and player.has_method("camera_global_transform"):
		return player.call("camera_global_transform")
	if player != null:
		return player.global_transform
	return Transform3D.IDENTITY

## Representative materials to warm on the SHAPED vertex format: an opaque one (grass —
## always present), plus the first translucent and first emissive block ids found (each
## skipped if the catalog ships none). One material × every emitted modifier is enough
## to warm the shaped opaque pipeline; the extra two cover the shaped translucent /
## emissive looks.
func _shaped_materials() -> Array[Material]:
	# Array[Material] (not StandardMaterial3D): BlockMaterials.get_for returns a bend ShaderMaterial
	# when the COSMOS planet is on (CubeSphere.FLAT_WORLD false); both are Materials to warm.
	var mats: Array[Material] = []
	var opaque := BlockMaterials.get_for(BlockCatalog.GRASS)
	if opaque != null:
		mats.append(opaque)
	var translucent_id := _first_id_matching("translucent")
	if translucent_id > 0:
		mats.append(BlockMaterials.get_for(translucent_id))
	var emissive_id := _first_id_matching("emissive")
	if emissive_id > 0:
		mats.append(BlockMaterials.get_for(emissive_id))
	return mats

## First non-AIR block id whose render_def has `flag` true, else -1.
func _first_id_matching(flag: String) -> int:
	for id in range(1, BlockCatalog.count()):
		if bool(BlockCatalog.render_def_of(id).get(flag, false)):
			return id
	return -1

## A unit-cube ArrayMesh meshed EXACTLY the way VoxelBody._rebuild emits its exposed
## faces (SurfaceTool, PRIMITIVE_TRIANGLES, per-vertex normal + uv + colour), so the
## warm-up vertex format matches the game's meshes. `mat` is set on surface 0.
func _build_cube_mesh(mat: Material) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for d in _DIRS:
		_emit_cube_face(st, d)
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	if mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, mat)
	return mesh

## Emit one exposed face of the unit cube [0,1]³ on side `d` — the same winding, normal
## and UV layout as VoxelBody._emit_face, plus a per-vertex colour so the vertex format
## carries the colour attribute the fallback mesher's materials consume.
func _emit_cube_face(st: SurfaceTool, d: Vector3i) -> void:
	var v: Array[Vector3]
	if d.x > 0:
		v = [Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(1, 0, 1)]
	elif d.x < 0:
		v = [Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0), Vector3(0, 0, 0)]
	elif d.y > 0:
		v = [Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)]
	elif d.y < 0:
		v = [Vector3(0, 0, 1), Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1)]
	elif d.z > 0:
		v = [Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1)]
	else:
		v = [Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 0, 0)]
	var n := Vector3(d)
	var uv := [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)]
	var col := Color(1, 1, 1)
	for idx in [0, 1, 2, 0, 2, 3]:
		st.set_normal(n)
		st.set_uv(uv[idx])
		st.set_color(col)
		st.add_vertex(v[idx])

## A shaped-cell ArrayMesh built from ShapeMesh.build — the SAME ARRAY layout the module
## library (module_world._make_shape_model) and VoxelBody consume, so the shaped vertex
## format is warmed. `mat` is set on surface 0.
func _build_shape_mesh(modifier: int, mat: Material) -> ArrayMesh:
	var geom := ShapeMesh.build(modifier)
	var mesh := ArrayMesh.new()
	var surf := []
	surf.resize(Mesh.ARRAY_MAX)
	surf[Mesh.ARRAY_VERTEX] = geom["verts"]
	surf[Mesh.ARRAY_NORMAL] = geom["normals"]
	surf[Mesh.ARRAY_TEX_UV] = geom["uvs"]
	surf[Mesh.ARRAY_INDEX] = geom["indices"]
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surf)
	if mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, mat)
	return mesh

## Lay the (mesh, material) jobs out in a tight grid `GRID_DISTANCE` m in front of
## `place_xform`, spread on the camera's right/up plane so none are frustum-culled, each
## scaled to CUBE_SIZE. Because our own transform is identity, an instance's LOCAL
## transform is its WORLD transform (so this is correct without needing to be in-tree).
func _place_grid(jobs: Array, place_xform: Transform3D) -> void:
	var n := jobs.size()
	if n == 0:
		return
	var cols := int(ceil(sqrt(float(n))))
	var rows := int(ceil(float(n) / float(cols)))
	# Clamp spacing so the pile never exceeds ±GRID_SAFE_EXTENT on either axis, no matter
	# the instance count — otherwise the outer rows/cols fall outside the frustum, get
	# culled, and their pipelines never compile (see GRID_SAFE_EXTENT).
	var col_spacing := minf(GRID_SPACING, 2.0 * GRID_SAFE_EXTENT / float(maxi(cols - 1, 1)))
	var row_spacing := minf(GRID_SPACING, 2.0 * GRID_SAFE_EXTENT / float(maxi(rows - 1, 1)))
	var forward := (-place_xform.basis.z).normalized()
	var right := place_xform.basis.x.normalized()
	var up := place_xform.basis.y.normalized()
	var center := place_xform.origin + forward * GRID_DISTANCE
	for i in n:
		var col := i % cols
		var row := i / cols
		var offset := right * (float(col) - float(cols - 1) * 0.5) * col_spacing \
			+ up * (float(row) - float(rows - 1) * 0.5) * row_spacing
		var pos := center + offset
		var mi := MeshInstance3D.new()
		mi.mesh = jobs[i][0]
		# Surface material already set on the mesh; also set the override so a mesh whose
		# surface material was somehow dropped still draws with the intended pipeline.
		mi.set_surface_override_material(0, jobs[i][1])
		add_child(mi)
		mi.transform = Transform3D(Basis().scaled(Vector3(CUBE_SIZE, CUBE_SIZE, CUBE_SIZE)), pos)
		_instances.append(mi)
