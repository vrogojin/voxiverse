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

# FP-FIXED-FRAME: preload the FrameAdapter (not the global class_name) so this core script parses without depending
# on the editor class-cache (the FLM/FLB convention). Used as the type of `_frame` below.
const _FrameAdapterCls := preload("res://src/world/frame_adapter.gd")

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
const PLAYER_HEIGHT := 1.8                # capsule height; feet at origin, head top this far up
const PLAYER_WEIGHT := 700.0              # N (~70 kg) pressed down onto a piece we stand on
const CEILING_EPS := 0.001               # keep the head a hair below the ceiling face (no clip)

var world: WorldManager                   # injected by Main before _ready
var inventory: Inventory                   # injected by Main before add_child; may be null (standalone)
var flying := false
## Input gate. While true the player cannot move, look, break or place — Main holds
## this during the load-time shader pre-warm (RENDER-STREAMING-SPIKES) so the hidden
## warm-up pile in front of the camera is never disturbed, then clears it when the
## ShaderPrewarm reports finished. Gates both _physics_process and _unhandled_input.
var frozen := false

# COSMOS FP-FIXED-FRAME (docs/COSMOS-FIXED-FRAME-DESIGN.md §2.3): the coordinate-frame adapter that bridges the
# player's canonical LATTICE frame (its LOCAL transform under WorldManager's ActiveFrame) and the GLOBAL/absolute
# frame the physics server + renderer consume. Every physics-boundary conversion below routes through it. Fetched
# from `world` in _ready; never null (a transparent identity adapter when the fixed frame is off / in Phase 1), so
# all the maps are numeric no-ops → byte-identical to today. Phase 2 rotates the frame with zero call-site change.
var _frame: _FrameAdapterCls

var _camera: Camera3D
var _ray: RayCast3D
var _capsule: CapsuleShape3D
var _body_shape: CollisionShape3D        # the player's capsule collider (disabled while flying)
var _pitch := 0.0
var _aimed: Dictionary = {}
var _horiz_vel := Vector3.ZERO            # this frame's horizontal move velocity

# ── REMOTE-DRIVE INTENT SEAM (docs/COSMOS-REMOTE-CONTROL-DESIGN.md §4.2) ─────────────────────────
# The ONLY hook the RemoteControl executor drives the rover through: it injects INTENT at the exact
# level a human does (the WASD/Shift/Space polls in _move), so commanded motion flows through the
# IDENTICAL analytic wall/floor/ceiling/collision pipeline — real locomotion, never a teleport. All
# fields are zero/false in normal play and the executor never exists while RemoteBridge.CONTROL_ENABLED
# is false, so this is a byte-identical no-op today.
var remote_drive := false                 # true only while a move step runs → _move uses remote_input/run
var remote_input := Vector3.ZERO          # body-local wish, SAME shape as the WASD `input` vector
var remote_run := false                   # substitutes the KEY_SHIFT poll
var remote_jump := false                  # one-shot latch, consumed by the grounded/fly jump branch (§4.6)
var remote_yaw_rate := 0.0                # rad/s the executor is applying this tick (seam indicator; the
                                          # executor owns the exact rotate_y for seam-immune remaining-degrees)
var remote_exec: Node = null              # the RemoteControl executor; ticked from _physics_process (§4.3)

func _ready() -> void:
	# COSMOS FP-FIXED-FRAME: fetch the coordinate-frame adapter from the world (a transparent identity adapter when
	# the fixed frame is off, so all conversions below are numeric no-ops). Fall back to a fresh identity adapter
	# for a standalone player (no world) so the physics-boundary maps never dereference null.
	_frame = world.frame_adapter() if world != null else _FrameAdapterCls.new()

	# COSMOS M1 (§6.2): per-body gravity feel. `gravity`/`jump_velocity` are Earth-tuned feel
	# constants (NOT 9.81); on another body they scale by g_body/9.81 so jump height and fall cadence
	# track real surface gravity while preserving today's Earth feel. The analytic floor/wall/ceiling
	# queries need NO change — "down" is always −Y in window space (the §3.3 theorem), so the chart is
	# curved only in the render (§3.4), never in the query space. FLAT_WORLD skips this (byte-identical
	# flat play); on Earth the factor is exactly 1.0, so a curved Earth keeps today's numbers too.
	if not CubeSphere.FLAT_WORLD:
		var s := CubeSphere.SURFACE_GRAVITY / CubeSphere.SURFACE_GRAVITY   # g_body/9.81; Earth = 1.0
		gravity *= s
		jump_velocity *= sqrt(s)

	# Build the camera rig in code to keep scenes minimal and robust.
	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.position = Vector3(0, eye_height, 0)
	# Generous far plane so terrain across the full stream range is never clipped;
	# fog hides the boundary well before the edge. With the far field enabled the plane
	# must reach past R_FAR (LOD-DESIGN §3.5) so the distant rings are not frustum-clipped;
	# disabled → today's near-only value.
	# COSMOS FACETED §5.2: the far ring wraps the whole planet (~2R) around the active facet, so the camera far
	# must reach it; otherwise the shipped FarTerrain / near-only value.
	if CubeSphere.FACETED:
		_camera.far = FacetFarRing.CAMERA_FAR
		# TIER-DEPTH P3 (§3.3): raise the near plane 0.05 → 0.25 (5× depth precision — precision scales linearly with
		# near) so the per-tier depth bias holds past ~1 km. 0.25 is far inside the 0.4-radius capsule, so no near-clip.
		# Flag off → near stays Godot's default 0.05 (byte-identical).
		if CubeSphere.FP_TIER_DEPTH_BIAS:
			_camera.near = TierPlace.CAMERA_NEAR
		# SPACE-NAV SN3 (§5.4): the altitude-continuous frustum. At ground (h = 0) these are EXACTLY the shipped
		# 0.05 / 9000 (byte-identical initial); the SN3 driver (main._process) ramps them per frame with altitude.
		# Overrides the depth-bias 0.25 with the design's 0.05 near floor. DEAD unless FP_SCALED_BODY is on.
		if CosmosScale.on():
			_camera.near = CosmosScale.camera_near(0.0)
			_camera.far = CosmosScale.camera_far(FacetAtlas.R_BLOCKS, FacetAtlas.R_BLOCKS)
	else:
		_camera.far = FarTerrain.FAR_CAMERA_FAR if FarTerrain.ENABLED else float(TerrainConfig.RENDER_RADIUS_BLOCKS) * 2.2
	_camera.fov = 75.0
	add_child(_camera)
	# COSMOS R2.2 (Design Z): the near + far render STATIC in the epoch frame and the camera moves THROUGH
	# them (main writes _camera.global each frame via set_render_camera). So the camera lives in world/epoch
	# space, NOT parented to the window-space body — make it top_level so its transform is world-relative and
	# setting it never inverts the (window-space) parent. FLAT / bend paths keep the child camera (byte-identical).
	if not CubeSphere.FLAT_WORLD and CubeSphere.M5_REAL:
		_camera.top_level = true

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
	_body_shape = CollisionShape3D.new()
	_body_shape.shape = _capsule
	_body_shape.position = Vector3(0, 0.9, 0)
	add_child(_body_shape)
	# Player on layer 4; collide only with the wooden blocks (layer 2).
	collision_layer = 1 << 2
	collision_mask = WOOD_LAYER_MASK

	# Screen-centre crosshair (a small "+"). We deliberately do NOT highlight the
	# aimed face any more — a fixed reticle reads cleaner and never occludes the
	# block we are about to break/build against.
	var crosshair := Crosshair.new()
	crosshair.name = "Crosshair"
	add_child(crosshair)

	_capture_mouse()

## Set the initial facing (yaw about Y) and camera pitch. Call after the player
## is in the tree (the camera is built in _ready).
func set_initial_look(yaw: float, pitch: float) -> void:
	rotation.y = yaw
	_pitch = clampf(pitch, -1.5, 1.5)
	if _camera != null:
		_camera.rotation.x = _pitch

## COSMOS FACETED §6.1 — re-frame the player across a seam onto the neighbour facet. `new_pos` is the f64-exact
## reframed position (WM computes it via FacetAtlas.reframe_position64); `yaw_delta` is the horizontal twist of
## the dihedral. The player stays UPRIGHT (+Y up in both flat facet frames) — physics snaps the yaw; the visual
## dihedral crest is eased by the camera (FP3b). Velocity + heading rotate about UP only, so gravity stays −Y.
func apply_reframe(new_pos: Vector3, yaw_delta: float) -> void:
	# FP-FIXED-FRAME §2.2 step 7 (Phase 2): with the fixed frame ON the player rides the ActiveFrame (@ T_to after
	# the crossing flipped it), so `new_pos` — B's lattice from reframe_position64 — is its LOCAL pose. Assigning
	# `position` makes its GLOBAL = T_to·new_pos, which equals the pre-crossing T_from·old_pos to f64 (continuous,
	# no teleport). Frame OFF ⇒ `global_position` exactly as before (byte-identical). The yaw twist + velocity
	# rotate stay in the LOCAL (lattice) frame about UP — unchanged; the dihedral tilt is carried by ActiveFrame.
	if _frame.enabled():
		position = new_pos
	else:
		global_position = new_pos
	rotation.y = wrapf(rotation.y + yaw_delta, -PI, PI)
	velocity = velocity.rotated(Vector3.UP, yaw_delta)

func _capture_mouse() -> void:
	# Web quirk (Godot #102209): after Esc the pointer won't re-lock unless we
	# cycle through VISIBLE first. Harmless on desktop.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## The camera's world transform — the ShaderPrewarm places its hidden warm-up pile in
## front of it. Falls back to the player transform before the camera rig is built.
func camera_global_transform() -> Transform3D:
	return _camera.global_transform if _camera != null else global_transform

## COSMOS R2.2 (Design Z): the WINDOW-space camera transform (what the camera is in pre-COSMOS window space)
## — body yaw+position × the pitch+eye camera-local. Main maps this into the static epoch render frame via
## WorldManager.m5_epoch_camera and writes it back with set_render_camera. Computed from the input state
## (yaw via global_transform, _pitch) NOT from _camera.global (which we override), so there is no feedback loop.
func window_camera_transform() -> Transform3D:
	var cam_local := Transform3D(Basis(Vector3(1, 0, 0), _pitch), Vector3(0, eye_height, 0))
	return global_transform * cam_local

## COSMOS R2.2: place the DISPLAYED camera at the given (epoch-frame) transform. Physics/aim stay window.
func set_render_camera(t: Transform3D) -> void:
	if _camera != null:
		_camera.global_transform = t

## SPACE-NAV SN3 (docs/COSMOS-SEAMLESS-SCALES-DESIGN.md §5.4): ramp the camera near/far with altitude so the
## climb to orbit stays C0 (no frustum pop) and the far plane always reaches the horizon tangent. h = radial
## altitude, d = |camera − body_centre| (blocks). At h = 0 / d = R these are the shipped 0.05 / 9000. Called
## per frame by main._process under FP_SCALED_BODY only; DEAD (never called) with the flag off.
func apply_scaled_camera_planes(h: float, d: float) -> void:
	if _camera != null:
		_camera.near = CosmosScale.camera_near(h)
		_camera.far = CosmosScale.camera_far(d, FacetAtlas.R_BLOCKS)

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
				# Fly is a GUARANTEED escape hatch: while airborne the capsule is
				# disabled so no loose body can collide with (and therefore shove or
				# wedge) the player. Re-enabled on landing. See _move_horizontal.
				if _body_shape != null:
					_body_shape.disabled = flying

func _physics_process(delta: float) -> void:
	if frozen or world == null:
		return
	# REMOTE-DRIVE (§4.3): snapshot the pre-locomotion LATTICE position so the executor measures pure
	# _move() displacement — uncontaminated by the reanchor/flip/cross corrections that follow. Captured
	# here and forwarded to physics_tick at the END of the frame (once the crossing yaw_delta is known).
	var _pre_move_pos := position
	_move(delta)
	var _tick_move_delta := position - _pre_move_pos
	_tick_move_delta.y = 0.0
	# FP-FIXED-FRAME (§2.3): world queries are LATTICE — the player's canonical pose is its LOCAL transform (== global
	# when the frame is off / at identity). update_streaming feeds the collider/pool/streamer, all lattice consumers.
	world.update_streaming(position)
	# COSMOS M2 (§3.2): re-anchor the floating origin when we walk far from it. The returned shift
	# is an EXACT integer translation the world already applied to its render nodes; subtracting it
	# here keeps the player's WORLD position continuous (no teleport). Vector3.ZERO in FLAT_WORLD, so
	# this is a byte-identical no-op today.
	var reanchor_shift := world.maybe_reanchor(global_position)
	if reanchor_shift != Vector3.ZERO:
		global_position -= reanchor_shift
	# COSMOS M3 (§4.5): once we cross far enough past a face edge, flip the home face onto the
	# neighbour and hard-restream. The flip keeps our window position unchanged (no teleport) and
	# edits are global-keyed, so nothing moves or is lost. Vector3.ZERO/no-op in FLAT_WORLD.
	# COSMOS-FRAME-ORIENTATION §5.1: under the pinned window orientation (M_win) the scene frame does
	# NOT rotate across a flip — the window axes are continuous — so there is nothing to counter-rotate
	# (Fix A #71 reverted: its D4 extraction now lives in chart.flip's M_win accumulation).
	world.maybe_flip_home_face(global_position)
	# COSMOS FACETED §6.1: walking past an active-facet ridge re-frames the player onto the neighbour facet.
	# Dormant until FP3b removes the FP2 ridge wall (which stops the player before the crossing threshold); the
	# reframe is position-exact + upright (physics snaps yaw, camera eases the dihedral). FLAT/non-faceted: skip.
	var _reframe_yaw := 0.0
	if CubeSphere.FACETED:
		# FP-FIXED-FRAME (§2.3): own_dist/ridge detection is active-lattice math → pass the LATTICE (local) position.
		var cross := world.maybe_cross_facet(position)
		if not cross.is_empty():
			apply_reframe(cross["new_pos"], cross["yaw_delta"])
			# REMOTE-DRIVE (§4.4): forward the seam's yaw twist so the executor rotates its along-heading
			# accumulator vector identically — distance walked stays continuous across the crossing.
			_reframe_yaw = float(cross["yaw_delta"])
	# COSMOS M5c (docs/COSMOS-M5C-CORNER.md §5): the corner anomaly seal. If the player entered the R_b
	# cylinder about a cube vertex (or, defensively, a double-out column), relocate/eject them via the bisector
	# teleport / seam glue — position, velocity and heading-relative yaw. Flag- and chart-gated no-op otherwise;
	# runs in window space (the M5_REAL displayed camera follows next frame).
	if not CubeSphere.FLAT_WORLD and CubeSphere.M5C_CORNER:
		var reloc := world.m5c_corner_check(global_position, velocity)
		if not reloc.is_empty():
			global_position = reloc["pos"]
			velocity = reloc["vel"]
			rotation.y += float(reloc["yaw_delta"])
	_push_bodies(delta)
	_update_aim()
	# REMOTE-DRIVE (§4.3): tick the executor AFTER the origin/frame corrections (so the crossing yaw_delta
	# is known) but with the PRE-correction locomotion delta captured at the top. No-op in normal play
	# (remote_exec is null — the executor only exists under a live control grant, flag-gated OFF today).
	if remote_exec != null and is_instance_valid(remote_exec) and remote_exec.has_method("physics_tick"):
		remote_exec.call("physics_tick", delta, _tick_move_delta, _reframe_yaw)

func _move(delta: float) -> void:
	# Horizontal intent in the player's yaw frame.
	# REMOTE-DRIVE SEAM (§4.2): while a move step runs the executor's commanded body-local wish
	# REPLACES the WASD polls for this tick — the SAME `input` vector, so everything below is identical.
	var input := Vector3.ZERO
	if remote_drive:
		input = remote_input
	else:
		if Input.is_key_pressed(KEY_W): input.z -= 1.0
		if Input.is_key_pressed(KEY_S): input.z += 1.0
		if Input.is_key_pressed(KEY_A): input.x -= 1.0
		if Input.is_key_pressed(KEY_D): input.x += 1.0
	var wish := (transform.basis * Vector3(input.x, 0, input.z))
	wish.y = 0.0
	if wish.length() > 0.0:
		wish = wish.normalized()

	var running := remote_run if remote_drive else Input.is_key_pressed(KEY_SHIFT)
	if flying:
		var speed := fly_speed * (2.0 if running else 1.0)
		var vy := 0.0
		if remote_drive:
			vy = input.y                        # a remote `move` in fly mode is horizontal (input.y == 0)
		else:
			if Input.is_key_pressed(KEY_SPACE): vy += 1.0
			if Input.is_key_pressed(KEY_CTRL): vy -= 1.0
		# FP-FIXED-FRAME: `wish` is a LATTICE direction (local basis · input), so fly in the LATTICE (local) frame.
		position += (wish + Vector3(0, vy, 0)) * speed * delta
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
	# FP-FIXED-FRAME (§2.3): the analytic walls are axis-aligned LATTICE probes → run them on the LOCAL (lattice)
	# position. `delta_move` is a lattice displacement (`wish` is a lattice direction). Byte-identical off / at identity.
	var feet_y := position.y
	var delta_move := wish * speed * delta
	# Test each axis at the leading edge, AND at both perpendicular corners of the
	# capsule (± radius), so a wall touching only one corner (or reached by a
	# diagonal move) still stops us instead of letting the capsule clip through it.
	if delta_move.x != 0.0:
		var lead_x := position.x + signf(delta_move.x) * PLAYER_RADIUS + delta_move.x
		if world.blocked(lead_x, position.z, feet_y) \
				or world.blocked(lead_x, position.z - PLAYER_RADIUS, feet_y) \
				or world.blocked(lead_x, position.z + PLAYER_RADIUS, feet_y):
			delta_move.x = 0.0
	if delta_move.z != 0.0:
		var lead_z := position.z + signf(delta_move.z) * PLAYER_RADIUS + delta_move.z
		if world.blocked(position.x, lead_z, feet_y) \
				or world.blocked(position.x - PLAYER_RADIUS, lead_z, feet_y) \
				or world.blocked(position.x + PLAYER_RADIUS, lead_z, feet_y):
			delta_move.z = 0.0
	# The surviving delta goes THROUGH the physics engine so we still collide with the
	# wooden blocks (walk into a standing pillar and you're blocked; loose pieces also
	# block us, but _push_bodies shoves them aside so we advance). One slide pass lets
	# us glide along a wood wall instead of sticking to it. The player's collision_mask
	# is wood-only, so terrain is unaffected (handled by the analytic test above).
	#
	# Only call move_and_collide when there is real motion to apply. move_and_collide
	# performs depenetration recovery even for a ZERO move, so calling it while the
	# analytic test has fully blocked us (delta_move == 0) would let a loose body that
	# has drifted into the capsule shove us — the seed of the rubber-band trap. When
	# terrain blocks us we simply stay put.
	if delta_move.length_squared() > 0.0:
		_move_horizontal(delta_move, wish)

	# Analytic gravity + floor. floor_under() scans down from the feet, so we can
	# descend into pits/shafts and enter tunnels we've dug instead of being snapped
	# back to the original surface.
	# FP-FIXED-FRAME (§2.3): `velocity` stays our own LATTICE bookkeeping (never fed to move_and_slide), so gravity
	# integration and the vertical floor/ceiling scans all run on the LOCAL (lattice) y — byte-identical at identity.
	velocity.y -= gravity * delta
	var prev_head_y := position.y + PLAYER_HEIGHT   # head BEFORE this frame's rise
	position.y += velocity.y * delta

	# Analytic CEILING (SWEPT + shape-aware): while rising, the head must not pass into
	# a solid cell overhead (jump under a low ceiling and you bonk it, like a wall stops
	# horizontal motion). We SCAN every cell the head sweeps through this frame — from
	# prev_head_y up to the new head — mirroring floor_under's per-cell scan so a fast
	# rise during a frame hitch cannot TUNNEL a thin ceiling (point-sampling only the
	# endpoint would jump a 1-block ceiling at ~0.2 s frames). The scan uses the shape-
	# aware occupied span (WorldManager._occ_span), so a top-anchored slab stops the head
	# at its true underside — matching the floor/wall shape contract, not a material-only
	# point test. Clamp the feet so the head sits just below that underside and kill the
	# upward velocity. Descending/flat motion (velocity.y <= 0) is skipped, so standing
	# and open-sky jumps behave exactly as before.
	if velocity.y > 0.0:
		var new_head_y := position.y + PLAYER_HEIGHT
		var ceiling_y := _ceiling_under(prev_head_y, new_head_y)
		if new_head_y > ceiling_y:
			position.y = ceiling_y - PLAYER_HEIGHT - CEILING_EPS
			velocity.y = 0.0

	var terrain_floor := world.floor_under(position.x, position.z, position.y)
	var floor_y := terrain_floor

	# Stand ON a detached voxel body directly under the feet instead of falling
	# through it (and, below, press our weight into it so it does not squirt out).
	# Short physics ray straight down from just above the feet, wood layer only.
	var piece: VoxelBody = null
	var piece_point := Vector3.ZERO
	var space := get_world_3d().direct_space_state
	# FP-FIXED-FRAME (§2.3): the stand-on ray runs in GLOBAL/physics space, so map the LATTICE feet endpoints out
	# through the frame (T·(p±ŷ)); byte-identical at identity.
	var rq := PhysicsRayQueryParameters3D.create(
		_frame.l2g_point(position + Vector3(0, 0.05, 0)),
		_frame.l2g_point(position + Vector3(0, -0.6, 0)))
	rq.collision_mask = WOOD_LAYER_MASK
	rq.collide_with_bodies = true
	rq.exclude = [get_rid()]
	var rhit := space.intersect_ray(rq)
	if not rhit.is_empty() and rhit.get("collider") is VoxelBody:
		# Convert the GLOBAL hit back to LATTICE (T⁻¹·hit) to compare its height against the lattice terrain floor;
		# piece_point stays GLOBAL for the apply_force contact offset below (physics space).
		var piece_top: float = _frame.g2l_point(rhit["position"]).y
		# Only stand on it when its top is at/above the terrain floor; otherwise the
		# terrain wins and we ignore a piece that is really below the ground.
		if piece_top >= terrain_floor:
			piece = rhit["collider"] as VoxelBody
			piece_point = rhit["position"]
			floor_y = maxf(terrain_floor, piece_top)

	if position.y <= floor_y:
		position.y = floor_y
		velocity.y = 0.0
		# REMOTE-DRIVE SEAM (§4.6): the one-shot remote_jump latch is consumed exactly as KEY_SPACE the
		# first grounded tick — real lift-off through the same jump_velocity, cleared so it fires once.
		if Input.is_key_pressed(KEY_SPACE) or remote_jump:
			velocity.y = jump_velocity
			remote_jump = false

	# While actually resting on the piece (not jumping off it), press the player's
	# weight DOWN into the body at the CONTACT OFFSET (not its centre): a light piece
	# can tip and a heavy one resists, so it holds us up instead of being launched.
	# FP-FIXED-FRAME (§2.3): apply_force is GLOBAL/physics space — the weight direction is the facet-local down
	# (−T.basis.y = l2g_dir of local −ŷ), and the contact offset is a global delta; byte-identical at identity.
	if piece != null and position.y <= floor_y + 0.05 and velocity.y <= 0.0:
		piece.apply_force(_frame.l2g_dir(Vector3(0, -PLAYER_WEIGHT, 0)),
			piece_point - piece.global_transform.origin)

## Move horizontally against the wooden blocks with a single slide, so pillars are
## solid obstacles. Uses move_and_collide (not move_and_slide) to keep the vertical
## axis fully analytic (floor_under handles descent/tunnels, which the terrain has
## no collider for).
##
## RUBBER-BAND TRAP GUARANTEE (must hold at ANY frame rate): move_and_collide performs
## depenetration recovery when the capsule starts a move already overlapping a body. A
## loose VoxelBody the player is pushing drifts into the capsule between ticks — more so
## at low FPS, where the rigid body gets several physics sub-steps per rendered frame —
## so that recovery can eject the player BACKWARD. Holding the key then drives the player
## straight back in, producing an infinite forward/back rubber-band. To make that
## impossible: horizontal motion may advance, slide, or STOP, but it may never net-oppose
## the movement intent `wish`. If the resolved displacement points against `wish`, we
## revert to where this tick began — the worst case is a clean stop, never a shove.
func _move_horizontal(motion: Vector3, wish: Vector3) -> void:
	# FP-FIXED-FRAME (§2.3): move_and_collide + the slide operate in GLOBAL/physics space, so map the LATTICE
	# motion and wish out through the frame (T.basis·motion / T.basis·wish). The rubber-band dot-check then
	# compares the GLOBAL displacement against the GLOBAL wish, and the revert restores the GLOBAL start x/z.
	# All maps are the identity when the frame is off / at identity → byte-identical.
	var motion_g := _frame.l2g_dir(motion)
	var wish_g := _frame.l2g_dir(wish)
	var start := global_position
	var coll := move_and_collide(motion_g)
	if coll != null:
		var slide := coll.get_remainder().slide(coll.get_normal())
		move_and_collide(slide)
	if wish_g.length_squared() > 0.0:
		var moved := global_position - start
		moved.y = 0.0
		# A pure sideways slide has a ~0 along-wish component (kept); only a clearly
		# backward net displacement is a rubber-band eject, which we undo. The epsilon
		# tolerates float noise and legitimate corner slides.
		if moved.dot(wish_g) < -0.001:
			global_position.x = start.x
			global_position.z = start.z

## The lowest solid underside the player's head sweeps into as it rises from
## `from_head_y` to `to_head_y` this frame, or INF if the swept range is clear. Probes
## the footprint centre AND the four corners (± PLAYER_RADIUS in x and z) — the same
## corner spirit as the horizontal wall checks, so a ceiling covering only one corner
## still stops the head — and takes the LOWEST underside across them. Each column is a
## swept, shape-aware scan (WorldManager.ceiling_scan): mirroring floor_under it walks
## every cell in the head's vertical range (no tunneling) and reads the true occupied
## span (top-anchored slabs stop at their underside). No trimesh collision.
func _ceiling_under(from_head_y: float, to_head_y: float) -> float:
	# FP-FIXED-FRAME (§2.3): ceiling_scan is a LATTICE query, and the y-bounds come from the lattice position — so
	# probe on the LOCAL (lattice) x/z too (== global at identity → byte-identical).
	var px := position.x
	var pz := position.z
	var r := PLAYER_RADIUS
	var lo := world.ceiling_scan(px, pz, from_head_y, to_head_y)
	lo = minf(lo, world.ceiling_scan(px - r, pz - r, from_head_y, to_head_y))
	lo = minf(lo, world.ceiling_scan(px - r, pz + r, from_head_y, to_head_y))
	lo = minf(lo, world.ceiling_scan(px + r, pz - r, from_head_y, to_head_y))
	lo = minf(lo, world.ceiling_scan(px + r, pz + r, from_head_y, to_head_y))
	return lo

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
	# FP-FIXED-FRAME (§2.3): the camera origin/dir are GLOBAL/absolute — used directly for the wood physics ray.
	# The terrain DDA is a LATTICE query, so convert origin/dir into the lattice frame for world.aimed_voxel. The
	# two hit distances are rigid-invariant (a rigid T preserves lengths), so the wood-vs-terrain contest compares
	# them directly. All maps are the identity when the frame is off / at identity → byte-identical.
	var origin := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	var origin_lat := _frame.g2l_point(origin)
	var dir_lat := _frame.g2l_dir(dir)

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

	# Terrain (analytic voxel DDA in LATTICE space; DDA already reports the face).
	var terr_dist := INF
	var terr_cell := Vector3i.ZERO
	var terr_normal := Vector3i.ZERO
	var info := world.aimed_voxel(origin_lat, dir_lat, break_reach)
	if info.get("hit", false):
		terr_dist = origin_lat.distance_to(info["position"])   # lattice-space distance; rigid-invariant vs wood_dist
		terr_cell = info["voxel"]
		terr_normal = info["normal"]

	# Nearest wins; ties go to wood (it is physically in front of the terrain).
	if wood_body != null and wood_dist <= terr_dist:
		# wood_body.global_transform is already GLOBAL → the cube xform is global.
		var xf := wood_body.global_transform * Transform3D(Basis(), Vector3(wood_cell))
		return {"kind": "wood", "body": wood_body, "cell": wood_cell, "normal": wood_normal, "xform": xf}
	if terr_dist < INF:
		# The terrain cube xform is LATTICE → map it to GLOBAL so a (top_level) highlight consumes an absolute pose.
		var xf := _frame.l2g_xform(Transform3D(Basis(), Vector3(terr_cell)))
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

## Right-click: place the selected hotbar block against the aimed face — either
## TERRAIN (trees/placed blocks are terrain) or a detached VoxelBody, so you can
## build both on the ground and onto a loose piece. The new block goes in the empty
## neighbour cell across the struck face (`cell + normal`). We only pay on success.
##   * terrain — reject cells that would overlap the player; `place_block` rejects
##     occupied cells.
##   * wood    — attach into the body's LOCAL frame via `add_cell`, which rejects an
##     occupied cell. The player-overlap guard is terrain-only: a body cell attaching
##     into the player's space is a rare edge case on a moving/rotating body (the
##     guard's AABB is world-axis-aligned and would not match the body's frame), so
##     we deliberately skip it there and keep the terrain guard intact.
func _try_place() -> void:
	if inventory == null:
		return
	var id := inventory.selected_block_id()
	if id == 0:
		return                                    # empty slot
	var target := _current_target()
	match String(target["kind"]):
		"terrain":
			var base_cell: Vector3i = target["cell"]
			var nrm: Vector3i = target["normal"]
			var place_cell := base_cell + nrm
			if _cell_intersects_player(place_cell):
				return
			if world.place_block(place_cell, id):
				inventory.consume_selected(1)     # only pay on success
		"wood":
			var body := target["body"] as VoxelBody
			var local_cell: Vector3i = target["cell"] + target["normal"]
			if body.add_cell(local_cell, id):
				inventory.consume_selected(1)     # only pay on success

## AABB overlap: player box (center (px, feet+0.9, pz), half-extents
## (PLAYER_RADIUS, 0.9, PLAYER_RADIUS) — i.e. feet up to 1.8 m) vs cell cube
## [c, c+1), with a small epsilon so a block level with our feet plane in the NEXT
## column is still allowed.
func _cell_intersects_player(cell: Vector3i) -> bool:
	const EPS := 0.001
	# FP-FIXED-FRAME (§2.3): `cell` is a LATTICE cell (from the terrain DDA), so test the player's AABB in the
	# LOCAL (lattice) frame — byte-identical at identity.
	var lo := Vector3(cell)
	var hi := lo + Vector3.ONE
	var pmin := position + Vector3(-PLAYER_RADIUS, 0.0, -PLAYER_RADIUS)
	var pmax := position + Vector3(PLAYER_RADIUS, 1.8, PLAYER_RADIUS)
	return pmin.x < hi.x - EPS and pmax.x > lo.x + EPS \
		and pmin.y < hi.y - EPS and pmax.y > lo.y + EPS \
		and pmin.z < hi.z - EPS and pmax.z > lo.z + EPS

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
	# FP-FIXED-FRAME (§2.3): the shape query + push impulse are GLOBAL/physics space — map the LATTICE capsule pose
	# (T·(p + 0.9ŷ)) and the push direction (T.basis·dir) out through the frame; `speed` is frame-invariant. Identity → no-op.
	q.transform = _frame.l2g_xform(Transform3D(Basis(), position + Vector3(0, 0.9, 0)))
	q.collision_mask = WOOD_LAYER_MASK
	q.collide_with_bodies = true
	q.exclude = [get_rid()]
	var dir := _frame.l2g_dir(_horiz_vel.normalized())
	var speed := _horiz_vel.length()
	for h in space.intersect_shape(q, 8):
		var col: Object = h.get("collider")
		if col is RigidBody3D and not (col as RigidBody3D).freeze:
			var body := col as RigidBody3D
			if body.linear_velocity.dot(dir) < speed:
				body.apply_central_impulse(dir * push_force * delta)

func _update_aim() -> void:
	# FP-FIXED-FRAME (§2.3): convert the GLOBAL camera origin/dir into the LATTICE frame for the terrain DDA.
	var origin := _frame.g2l_point(_camera.global_position)
	var dir := _frame.g2l_dir(-_camera.global_transform.basis.z)
	var info := world.aimed_voxel(origin, dir, reach)
	if info != _aimed:
		_aimed = info
		aimed_voxel_changed.emit(info)

func get_aimed() -> Dictionary:
	return _aimed

## LATTICE position of the air voxel at the player's head (for the air thermometer — a per-voxel-environment
## query, which is lattice). FP-FIXED-FRAME (§2.3): local == lattice under ActiveFrame; == global at identity.
func head_position() -> Vector3:
	return position + Vector3(0, eye_height, 0)

## LATTICE position just below the feet — the grass voxel the player stands on (per-voxel-environment query).
func ground_probe_position() -> Vector3:
	return position - Vector3(0, 0.5, 0)


# ══════════════════════════════════════════════════════════════════════════════════════════════════
# REMOTE-DRIVE ACTUATORS (docs/COSMOS-REMOTE-CONTROL-DESIGN.md §4.6 + resolved D5). The executor calls
# these; each ROUTES THROUGH THE SAME WorldManager/inventory pipeline a human uses (reach + gameplay
# rules enforced) — NO new mutation path, NO call-by-name. Dead code unless a live control grant exists.
# ══════════════════════════════════════════════════════════════════════════════════════════════════

## set_fly (§4.6): replicate the KEY_F branch exactly — toggle fly, zero velocity, disable/enable the
## capsule so no loose body can wedge the player while airborne.
func remote_set_fly(on: bool) -> void:
	flying = on
	velocity = Vector3.ZERO
	if _body_shape != null:
		_body_shape.disabled = flying

## look.pitch_deg (§4.5): absolute camera pitch in radians (horizon = 0, up = +), clamped to the same
## ±1.5 rad the mouse-look path uses.
func remote_set_pitch(rad: float) -> void:
	_pitch = clampf(rad, -1.5, 1.5)
	if _camera != null:
		_camera.rotation.x = _pitch

## Current camera pitch (radians) — the executor eases toward the look target from here.
func remote_pitch() -> float:
	return _pitch

## select_slot{n}: the human 1–9 hotbar path. Returns false if there is no inventory.
func remote_select_slot(n: int) -> bool:
	if inventory == null:
		return false
	inventory.select_slot(n)
	return true

## The LATTICE cell at a player-relative integer offset (feet cell + offset) — the `{dx,dy,dz}` target mode.
func _remote_offset_cell(o: Vector3i) -> Vector3i:
	return Vector3i(floori(position.x), floori(position.y), floori(position.z)) + o

func _remote_in_break_reach(cell: Vector3i) -> bool:
	return head_position().distance_to(Vector3(cell) + Vector3(0.5, 0.5, 0.5)) <= break_reach

func _remote_in_reach(cell: Vector3i) -> bool:
	return head_position().distance_to(Vector3(cell) + Vector3(0.5, 0.5, 0.5)) <= reach

## break{target}: `target` is Vector3i (player-relative offset cell) or "aim". Routes through the SAME
## break pipeline `_try_break` uses (WorldManager.break_terrain / VoxelBody.break_cell + collapse +
## inventory). Returns the broken block id (>0) on success, 0 if nothing broke (air / out of reach / rules).
func remote_break(target) -> int:
	if target is Vector3i:
		var cell: Vector3i = _remote_offset_cell(target)
		if not _remote_in_break_reach(cell):
			return 0
		var oid := world.break_terrain(cell, global_position)
		if oid > 0 and inventory != null:
			inventory.add(oid, 1)
		return oid
	# "aim": the SAME nearest-of(wood,terrain) contest + break path as _try_break, returning the id.
	var tgt := _current_target()
	match String(tgt["kind"]):
		"wood":
			var body := tgt["body"] as VoxelBody
			var cell: Vector3i = tgt["cell"]
			var bid := body.cell_block_id(cell)
			body.break_cell(cell, global_position)
			if bid > 0 and inventory != null:
				inventory.add(bid, 1)
			return bid
		"terrain":
			var cell: Vector3i = tgt["cell"]
			var tid := world.break_terrain(cell, global_position)
			if tid > 0 and inventory != null:
				inventory.add(tid, 1)
			return tid
	return 0

## place{block,target}: `block` is a resolved block id (0 → use the selected hotbar slot); `target` is a
## Vector3i offset cell or "aim". Routes through the SAME place pipeline `_try_place` uses
## (player-overlap guard + WorldManager.place_block / VoxelBody.add_cell). Consumes the selected slot when
## the placed id matches it (inventory bookkeeping). Returns true on a successful placement.
func remote_place(block_id: int, target) -> bool:
	if inventory == null:
		return false
	var id := block_id if block_id > 0 else inventory.selected_block_id()
	if id <= 0:
		return false
	if target is Vector3i:
		var cell: Vector3i = _remote_offset_cell(target)
		if not _remote_in_reach(cell):
			return false
		if _cell_intersects_player(cell):
			return false
		if world.place_block(cell, id):
			if inventory.selected_block_id() == id:
				inventory.consume_selected(1)
			return true
		return false
	# "aim": place against the aimed face, exactly as _try_place.
	var tgt := _current_target()
	match String(tgt["kind"]):
		"terrain":
			var base_cell: Vector3i = tgt["cell"]
			var nrm: Vector3i = tgt["normal"]
			var place_cell := base_cell + nrm
			if _cell_intersects_player(place_cell):
				return false
			if world.place_block(place_cell, id):
				if inventory.selected_block_id() == id:
					inventory.consume_selected(1)
				return true
			return false
		"wood":
			var body := tgt["body"] as VoxelBody
			var local_cell: Vector3i = tgt["cell"] + tgt["normal"]
			if body.add_cell(local_cell, id):
				if inventory.selected_block_id() == id:
					inventory.consume_selected(1)
				return true
			return false
	return false
