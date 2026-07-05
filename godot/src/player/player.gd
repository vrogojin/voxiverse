class_name Player
extends CharacterBody3D
## First-person controller for the grass test env (DESIGN §1).
##
## WASD + run + jump + gravity, mouse-look with browser pointer-lock (Esc frees,
## click re-captures), and a fly/noclip toggle (F). A look-at interaction ray
## reports the voxel the player is aiming at, feeding the thermometer and future
## material inspection.
##
## The world is a pure heightmap, so ground handling is analytic (sample the
## surface height under the player) rather than physics trimesh collision — this
## is cheap, web-friendly, and works identically for both rendering paths. Keys
## are read by physical keycode so no InputMap configuration is required.

signal aimed_voxel_changed(info: Dictionary)

@export var walk_speed := 5.5
@export var run_speed := 9.5
@export var fly_speed := 16.0
@export var jump_velocity := 8.0
@export var gravity := 22.0
@export var eye_height := 1.7
@export var mouse_sensitivity := 0.0025
@export var reach := 8.0
## Short block-breaking reach: only the immediately adjacent blocks (the one in
## front and the ones a step under/around the player) are within range — you
## cannot snipe distant terrain. Eye is 1.7 m up, so this must exceed ~2 m to let
## you break the block under your own feet.
@export var break_reach := 4.0
## The player's push STRENGTH, in Newtons — a fixed force applied to any loose
## block cluster the player walks into. Because acceleration = force / mass, a
## single-block piece (light) shoves easily while a heavy pile barely creeps; the
## block masses come from the physics layer, so mass genuinely matters here.
@export var push_force := 1200.0

const WOOD_LAYER_MASK := 1 << 1           # voxel bodies live on collision layer 2
const PLAYER_RADIUS := 0.4                # capsule radius; the wall-block probe reach
const PLAYER_WEIGHT := 700.0              # N (~70 kg) pressed down onto a piece we stand on

var world: WorldManager                   # injected by Main before _ready
var inventory: Inventory                   # injected by Main before add_child; may be null (standalone)
var flying := false
## Input gate. While true the player cannot move, look, break or place — Main holds
## this during the load-time shader pre-warm (RENDER-STREAMING-SPIKES) so the hidden
## warm-up pile in front of the camera is never disturbed, then clears it when the
## ShaderPrewarm reports finished. Gates both _physics_process and _unhandled_input.
var frozen := false

var _camera: Camera3D
var _ray: RayCast3D
var _capsule: CapsuleShape3D
var _pitch := 0.0
var _aimed: Dictionary = {}
var _horiz_vel := Vector3.ZERO            # this frame's horizontal move velocity
var _highlight: AimHighlight              # brightened face on the block we aim at

func _ready() -> void:
	# Build the camera rig in code to keep scenes minimal and robust.
	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.position = Vector3(0, eye_height, 0)
	# Generous far plane so terrain across the full stream range is never clipped;
	# fog hides the boundary well before the edge.
	_camera.far = float(TerrainConfig.RENDER_RADIUS_BLOCKS) * 2.2
	_camera.fov = 75.0
	add_child(_camera)

	# RayCast3D is present per DESIGN; the authoritative hit test is the analytic
	# voxel DDA in WorldManager (the fallback world has no physics colliders).
	_ray = RayCast3D.new()
	_ray.name = "InteractionRay"
	_ray.target_position = Vector3(0, 0, -reach)
	_ray.enabled = true
	_camera.add_child(_ray)

	# Capsule collider: the player is an immovable (kinematic) obstacle the wooden
	# blocks collide with, and it is reused as the query shape for shoving blocks.
	_capsule = CapsuleShape3D.new()
	_capsule.height = 1.8
	_capsule.radius = 0.4
	var shape := CollisionShape3D.new()
	shape.shape = _capsule
	shape.position = Vector3(0, 0.9, 0)
	add_child(shape)
	# Player on layer 4; collide only with the wooden blocks (layer 2).
	collision_layer = 1 << 2
	collision_mask = WOOD_LAYER_MASK

	# Aim highlight: a world-space brightened face on whatever block we'd break or
	# build against. top_level (set in its _ready) keeps it independent of us.
	_highlight = AimHighlight.new()
	_highlight.name = "AimHighlight"
	add_child(_highlight)

	_capture_mouse()

## Set the initial facing (yaw about Y) and camera pitch. Call after the player
## is in the tree (the camera is built in _ready).
func set_initial_look(yaw: float, pitch: float) -> void:
	rotation.y = yaw
	_pitch = clampf(pitch, -1.5, 1.5)
	if _camera != null:
		_camera.rotation.x = _pitch

func _capture_mouse() -> void:
	# Web quirk (Godot #102209): after Esc the pointer won't re-lock unless we
	# cycle through VISIBLE first. Harmless on desktop.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## The camera's world transform — the ShaderPrewarm places its hidden warm-up pile in
## front of it. Falls back to the player transform before the camera rig is built.
func camera_global_transform() -> Transform3D:
	return _camera.global_transform if _camera != null else global_transform

func _unhandled_input(event: InputEvent) -> void:
	if frozen:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -1.5, 1.5)
		_camera.rotation.x = _pitch
	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			_capture_mouse()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_try_break()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_try_place()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			# Minecraft direction: wheel-down moves the selector RIGHT. Each tick
			# arrives as a pressed+released pair; we act on pressed only (the branch
			# already filters to event.pressed), so one step per physical notch.
			if inventory != null:
				inventory.scroll(1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if inventory != null:
				inventory.scroll(-1)
	elif event is InputEventKey and event.pressed and not event.echo:
		# 1-9 select the matching hotbar slot (KEY_1..KEY_9 are consecutive).
		if event.keycode >= KEY_1 and event.keycode <= KEY_9:
			if inventory != null:
				inventory.select_slot(event.keycode - KEY_1)
			return
		match event.keycode:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_F:
				flying = not flying
				velocity = Vector3.ZERO

func _physics_process(delta: float) -> void:
	if frozen or world == null:
		return
	_move(delta)
	world.update_streaming(global_position)
	_push_bodies(delta)
	_update_aim()
	_update_highlight()

func _move(delta: float) -> void:
	# Horizontal intent in the player's yaw frame.
	var input := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): input.z -= 1.0
	if Input.is_key_pressed(KEY_S): input.z += 1.0
	if Input.is_key_pressed(KEY_A): input.x -= 1.0
	if Input.is_key_pressed(KEY_D): input.x += 1.0
	var wish := (transform.basis * Vector3(input.x, 0, input.z))
	wish.y = 0.0
	if wish.length() > 0.0:
		wish = wish.normalized()

	var running := Input.is_key_pressed(KEY_SHIFT)
	if flying:
		var speed := fly_speed * (2.0 if running else 1.0)
		var vy := 0.0
		if Input.is_key_pressed(KEY_SPACE): vy += 1.0
		if Input.is_key_pressed(KEY_CTRL): vy -= 1.0
		global_position += (wish + Vector3(0, vy, 0)) * speed * delta
		_horiz_vel = wish * speed
		velocity = Vector3.ZERO
		return

	var speed := run_speed if running else walk_speed
	_horiz_vel = wish * speed
	# Terrain has no collider, so terrain WALLS are enforced analytically here: the
	# player must be STOPPED by an upward step (never climbed, never teleported), yet
	# still able to slide along it. Test each axis independently — probe one radius
	# ahead plus the intended delta and zero that component if solid terrain overlaps
	# the player's vertical span there. Descending/flat ground has air ahead at feet
	# level (not blocked), so movement stays free; only upward steps block, so going
	# up requires a JUMP (intended — no auto-step).
	var feet_y := global_position.y
	var delta_move := wish * speed * delta
	# Test each axis at the leading edge, AND at both perpendicular corners of the
	# capsule (± radius), so a wall touching only one corner (or reached by a
	# diagonal move) still stops us instead of letting the capsule clip through it.
	if delta_move.x != 0.0:
		var lead_x := global_position.x + signf(delta_move.x) * PLAYER_RADIUS + delta_move.x
		if world.blocked(lead_x, global_position.z, feet_y) \
				or world.blocked(lead_x, global_position.z - PLAYER_RADIUS, feet_y) \
				or world.blocked(lead_x, global_position.z + PLAYER_RADIUS, feet_y):
			delta_move.x = 0.0
	if delta_move.z != 0.0:
		var lead_z := global_position.z + signf(delta_move.z) * PLAYER_RADIUS + delta_move.z
		if world.blocked(global_position.x, lead_z, feet_y) \
				or world.blocked(global_position.x - PLAYER_RADIUS, lead_z, feet_y) \
				or world.blocked(global_position.x + PLAYER_RADIUS, lead_z, feet_y):
			delta_move.z = 0.0
	# The surviving delta goes THROUGH the physics engine so we still collide with the
	# wooden blocks (walk into a standing pillar and you're blocked; loose pieces also
	# block us, but _push_bodies shoves them aside so we advance). One slide pass lets
	# us glide along a wood wall instead of sticking to it. The player's collision_mask
	# is wood-only, so terrain is unaffected (handled by the analytic test above).
	_move_horizontal(delta_move)

	# Analytic gravity + floor. floor_under() scans down from the feet, so we can
	# descend into pits/shafts and enter tunnels we've dug instead of being snapped
	# back to the original surface.
	velocity.y -= gravity * delta
	global_position.y += velocity.y * delta
	var terrain_floor := world.floor_under(global_position.x, global_position.z, global_position.y)
	var floor_y := terrain_floor

	# Stand ON a detached voxel body directly under the feet instead of falling
	# through it (and, below, press our weight into it so it does not squirt out).
	# Short physics ray straight down from just above the feet, wood layer only.
	var piece: VoxelBody = null
	var piece_point := Vector3.ZERO
	var space := get_world_3d().direct_space_state
	var rq := PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0, 0.05, 0), global_position + Vector3(0, -0.6, 0))
	rq.collision_mask = WOOD_LAYER_MASK
	rq.collide_with_bodies = true
	rq.exclude = [get_rid()]
	var rhit := space.intersect_ray(rq)
	if not rhit.is_empty() and rhit.get("collider") is VoxelBody:
		var piece_top: float = (rhit["position"] as Vector3).y
		# Only stand on it when its top is at/above the terrain floor; otherwise the
		# terrain wins and we ignore a piece that is really below the ground.
		if piece_top >= terrain_floor:
			piece = rhit["collider"] as VoxelBody
			piece_point = rhit["position"]
			floor_y = maxf(terrain_floor, piece_top)

	if global_position.y <= floor_y:
		global_position.y = floor_y
		velocity.y = 0.0
		if Input.is_key_pressed(KEY_SPACE):
			velocity.y = jump_velocity

	# While actually resting on the piece (not jumping off it), press the player's
	# weight DOWN into the body at the CONTACT OFFSET (not its centre): a light piece
	# can tip and a heavy one resists, so it holds us up instead of being launched.
	if piece != null and global_position.y <= floor_y + 0.05 and velocity.y <= 0.0:
		piece.apply_force(Vector3(0, -PLAYER_WEIGHT, 0),
			piece_point - piece.global_transform.origin)

## Move horizontally against the wooden blocks with a single slide, so pillars are
## solid obstacles. Uses move_and_collide (not move_and_slide) to keep the vertical
## axis fully analytic (floor_under handles descent/tunnels, which the terrain has
## no collider for).
func _move_horizontal(motion: Vector3) -> void:
	var coll := move_and_collide(motion)
	if coll != null:
		var slide := coll.get_remainder().slide(coll.get_normal())
		move_and_collide(slide)

## Resolve the exact block the player is pointing at within break_reach, using the
## SAME "nearest of (physics-ray-hits-wood, analytic-DDA-hits-terrain)" contest
## that breaking uses — so the highlight and the break always agree. A physics ray
## finds a wooden block; the analytic voxel DDA finds terrain; whoever is nearer
## wins, so pointing at a pillar targets the pillar and pointing at the ground
## targets the ground.
##
## Returns a Dictionary describing the winner:
##   {"kind": "wood",    "body": VoxelBody, "cell": Vector3i, "normal": Vector3i, "xform": Transform3D}
##   {"kind": "terrain", "body": null,      "cell": Vector3i, "normal": Vector3i, "xform": Transform3D}
##   {"kind": "none",    "body": null,      "cell": Vector3i.ZERO, "normal": Vector3i.ZERO, "xform": identity}
## `normal` is the struck FACE's unit axis in the TARGET's LOCAL frame (the world
## frame for terrain): it drives the face highlight and is the direction to place
## a new block (target cell + normal). `xform` is the WORLD transform that drops a
## unit cube exactly on the block:
##   * terrain — a pure translation to the cell corner (block occupies [c, c+1]);
##   * wood    — the body's global_transform composed with that translation, so a
##               tumbling/rotating body carries the cube with it.
func _current_target() -> Dictionary:
	var origin := _camera.global_position
	var dir := -_camera.global_transform.basis.z

	# Wooden block (physics ray vs the voxel-body colliders).
	var wood_dist := INF
	var wood_body: VoxelBody = null
	var wood_cell := Vector3i.ZERO
	var wood_normal := Vector3i.ZERO
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * break_reach)
	q.collision_mask = WOOD_LAYER_MASK
	q.collide_with_bodies = true
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if not hit.is_empty() and hit.get("collider") is VoxelBody:
		wood_body = hit["collider"]
		wood_dist = origin.distance_to(hit["position"])
		wood_cell = wood_body.cell_at_hit(hit["position"], hit["normal"])
		# Convert the world-space hit normal into the body's local frame and snap
		# it to the dominant signed axis — the face of the LOCAL cell cube struck.
		var hit_n := hit["normal"] as Vector3
		var nl := (wood_body.global_transform.basis.inverse() * hit_n).normalized()
		wood_normal = _dominant_axis(nl)

	# Terrain (analytic voxel DDA in world space; DDA already reports the face).
	var terr_dist := INF
	var terr_cell := Vector3i.ZERO
	var terr_normal := Vector3i.ZERO
	var info := world.aimed_voxel(origin, dir, break_reach)
	if info.get("hit", false):
		terr_dist = origin.distance_to(info["position"])
		terr_cell = info["voxel"]
		terr_normal = info["normal"]

	# Nearest wins; ties go to wood (it is physically in front of the terrain).
	if wood_body != null and wood_dist <= terr_dist:
		var xf := wood_body.global_transform * Transform3D(Basis(), Vector3(wood_cell))
		return {"kind": "wood", "body": wood_body, "cell": wood_cell, "normal": wood_normal, "xform": xf}
	if terr_dist < INF:
		var xf := Transform3D(Basis(), Vector3(terr_cell))
		return {"kind": "terrain", "body": null, "cell": terr_cell, "normal": terr_normal, "xform": xf}
	return {"kind": "none", "body": null, "cell": Vector3i.ZERO, "normal": Vector3i.ZERO, "xform": Transform3D()}

## The unit axis (as a signed Vector3i) of `v`'s largest-magnitude component —
## snaps an approximate face normal to one of the 6 cube faces.
func _dominant_axis(v: Vector3) -> Vector3i:
	var ax := absf(v.x)
	var ay := absf(v.y)
	var az := absf(v.z)
	if ax >= ay and ax >= az:
		return Vector3i(1 if v.x >= 0.0 else -1, 0, 0)
	if ay >= az:
		return Vector3i(0, 1 if v.y >= 0.0 else -1, 0)
	return Vector3i(0, 0, 1 if v.z >= 0.0 else -1)

## Left-click: break the block resolved by _current_target() and collect it into
## the hotbar. Pointing at a wood body breaks that body's cell; pointing at the
## ground digs terrain (trees and placed blocks are terrain). We pass our own
## position as the breaker so any detached loose piece gets a slight kick away.
func _try_break() -> void:
	var target := _current_target()
	match String(target["kind"]):
		"wood":
			var body := target["body"] as VoxelBody
			var cell: Vector3i = target["cell"]
			var id := body.cell_block_id(cell)      # capture BEFORE breaking
			body.break_cell(cell, global_position)  # kick away from us
			if id > 0 and inventory != null:
				inventory.add(id, 1)                # surplus silently lost (full-hotbar rule)
		"terrain":
			var cell: Vector3i = target["cell"]
			var id := world.break_terrain(cell, global_position)
			if id > 0 and inventory != null:
				inventory.add(id, 1)

## Right-click: place the selected hotbar block against the aimed TERRAIN face.
## Placement attaches to terrain only (trees/placed blocks are terrain) — aiming
## at a loose moving body places nothing, since a block glued to empty air beside
## a tumbling body would float. We reject cells that would overlap the player;
## `place_block` rejects occupied cells; we only pay on success.
func _try_place() -> void:
	if inventory == null:
		return
	var id := inventory.selected_block_id()
	if id == 0:
		return                                    # empty slot
	var target := _current_target()
	if String(target["kind"]) != "terrain":
		return                                    # no building against moving rigid bodies
	var base_cell: Vector3i = target["cell"]
	var nrm: Vector3i = target["normal"]
	var place_cell := base_cell + nrm
	if _cell_intersects_player(place_cell):
		return
	if world.place_block(place_cell, id):
		inventory.consume_selected(1)             # only pay on success

## AABB overlap: player box (center (px, feet+0.9, pz), half-extents
## (PLAYER_RADIUS, 0.9, PLAYER_RADIUS) — i.e. feet up to 1.8 m) vs cell cube
## [c, c+1), with a small epsilon so a block level with our feet plane in the NEXT
## column is still allowed.
func _cell_intersects_player(cell: Vector3i) -> bool:
	const EPS := 0.001
	var lo := Vector3(cell)
	var hi := lo + Vector3.ONE
	var pmin := global_position + Vector3(-PLAYER_RADIUS, 0.0, -PLAYER_RADIUS)
	var pmax := global_position + Vector3(PLAYER_RADIUS, 1.8, PLAYER_RADIUS)
	return pmin.x < hi.x - EPS and pmax.x > lo.x + EPS \
		and pmin.y < hi.y - EPS and pmax.y > lo.y + EPS \
		and pmin.z < hi.z - EPS and pmax.z > lo.z + EPS

## Keep the face highlight sitting on whatever block we would break/build this
## frame, or hide it when nothing is in range.
func _update_highlight() -> void:
	var target := _current_target()
	if String(target["kind"]) == "none":
		_highlight.hide_it()
	else:
		_highlight.show_face(target["xform"], target["normal"])

## Shove any dynamic wooden block the player walks into, so blocks can be pushed
## around. Frozen (undisturbed) pillars ignore the query cheaply.
##
## The push is a CONSTANT force (push_force Newtons) applied as an impulse
## `dir * push_force * delta`. It is NOT scaled by mass — since a rigid body
## integrates `impulse / mass`, the same force accelerates a light single block
## hard and a heavy pile barely at all, so a body's block count (mass) decides how
## easily it moves. (The old code multiplied by mass, which cancelled that out and
## made every cluster feel identical.)
##
## Realistic cap: only push a body while its velocity ALONG our push direction is
## still below our own walking speed. A light block accelerates up to that speed
## and then simply rides along in front of us instead of being flung; a heavy pile
## never reaches the cap and just creeps forward.
func _push_bodies(delta: float) -> void:
	if _horiz_vel.length() < 0.1:
		return
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _capsule
	q.transform = Transform3D(Basis(), global_position + Vector3(0, 0.9, 0))
	q.collision_mask = WOOD_LAYER_MASK
	q.collide_with_bodies = true
	q.exclude = [get_rid()]
	var dir := _horiz_vel.normalized()
	var speed := _horiz_vel.length()
	for h in space.intersect_shape(q, 8):
		var col: Object = h.get("collider")
		if col is RigidBody3D and not (col as RigidBody3D).freeze:
			var body := col as RigidBody3D
			if body.linear_velocity.dot(dir) < speed:
				body.apply_central_impulse(dir * push_force * delta)

func _update_aim() -> void:
	var origin := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	var info := world.aimed_voxel(origin, dir, reach)
	if info != _aimed:
		_aimed = info
		aimed_voxel_changed.emit(info)

func get_aimed() -> Dictionary:
	return _aimed

## World position of the air voxel at the player's head (for the air thermometer).
func head_position() -> Vector3:
	return global_position + Vector3(0, eye_height, 0)

## World position just below the feet — the grass voxel the player stands on.
func ground_probe_position() -> Vector3:
	return global_position - Vector3(0, 0.5, 0)
