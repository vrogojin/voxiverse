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

# COSMOS SPACE-NAV SN2 (docs/COSMOS-SPACE-NAV-DESIGN.md §4/§10): preloaded kernels for the gated nav-frame
# machine (same FLM/FLB convention — preload, not the global class-name). DEAD unless CubeSphere.SN_NAV_MODES.
const _CosmosNavCls := preload("res://src/cosmos/cosmos_nav.gd")
const _OrbitalStateCls := preload("res://src/cosmos/orbital_state.gd")
const _DVCls := preload("res://src/cosmos/dvec3.gd")
const _EphCls := preload("res://src/cosmos/cosmos_ephemeris.gd")
const _FacetAtlasCls := preload("res://src/cosmos/facet_atlas.gd")
# COSMOS SPACE-NAV SN5 (docs/COSMOS-SPACE-NAV-DESIGN.md §7): the dev-flight velocity-command controller (pure
# static). DEAD unless CubeSphere.SN_DEVNAV drives it in-game; the trajectory MATH is headless-gated
# (verify_dev_flight — G-SN-DEVFLIGHT). Same FLM/FLB preload convention.
const _DevFlightCls := preload("res://src/cosmos/cosmos_dev_flight.gd")
# COSMOS SPACE-NAV SN5b (§7.3): the dev-nav overlay set (compass + guides). Lazy-built on F, freed on toggle.
const _DevNavOverlayCls := preload("res://src/player/dev_nav_overlay.gd")

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

# COSMOS SPACE-NAV SN2 (docs/COSMOS-SPACE-NAV-DESIGN.md §4/§5): the nav-frame machine. `_nav` is NULL unless
# CubeSphere.SN_NAV_MODES ⇒ the whole feed is dead (flag-off byte-identical). The machine READS the player's
# body-centred BCI state each physics tick (derived from the shipped lattice `position` via the SN1 frame
# maps) and re-expresses the HUD velocity — it never writes pos/vel (the §5.4 theorem). `_nav_tele` is the
# additive RemoteBridge telemetry dict (nav_mode/frame_v/|v_bci|), surfaced via nav_telemetry().
# LIVE-ONLY-VALIDATED (honest, per SN1's precedent): the KERNEL + machine are headless-gated (verify_nav), but
# this in-game BCI derivation is validated only in a live session — the flag ships false until then.
var _nav: RefCounted = null
var _nav_clock := 0.0                         # local nav time (s); reused main's ORBITAL_SKY clock is not required
var _nav_prev_fix := PackedFloat64Array()     # previous body-fixed world position (finite-difference velocity)
var _nav_have_prev := false
var _nav_tele: Dictionary = {}
var _nav_last_v_bci := PackedFloat64Array()   # last derived BCI velocity (seeds dev-flight for a seamless handoff)

# COSMOS SPACE-NAV SN5 (docs/COSMOS-SPACE-NAV-DESIGN.md §7): dev-nav state. `_dev_nav` (F under SN_DEVNAV) turns
# dev-nav ON (rides `flying` — noclip + the mode-appropriate controller). In PLANETARY the shipped lattice fly
# path is used UNCHANGED (§7.2); in the orbital modes the velocity-command controller (CosmosDevFlight) owns the
# BCI velocity `_dev_v_bci` and re-projects the kinematic BCI position back to the lattice `position` each tick.
# All DEAD with SN_DEVNAV off (F stays the shipped bare fly toggle → byte-identical). LIVE-ONLY-VALIDATED: the
# in-game feel + the BCI↔lattice re-projection at altitude are a morning-session check; the controller MATH is
# headless-proven by G-SN-DEVFLIGHT.
var _dev_nav := false
var _dev_v_bci := PackedFloat64Array()         # the controller's BCI velocity state (kinematic; owned while orbital)
var _dev_have_v := false                        # false until seeded on the first orbital tick (from _nav_last_v_bci)
var _dev_active := false                         # true on ticks the orbital controller drove position (feeds _nav_tick)
var _dev_p_bci := PackedFloat64Array()          # last BCI position (stashed for the O/G key handlers)
var _dev_overlay: Control = null                # the SN5b overlay set (compass + guides); null unless dev-nav on
# SN-FIX #3 (SN_NO_CEILING_BOUNCE): the explicit orbital-commit latch. Under the flag the auto mode→dev-flight
# handoff is deferred (kinematic lattice fly is kept through the atmosphere→orbit band so a climb is not
# decelerated at the ceiling); the orbital velocity-command controller engages only after the pilot EXPLICITLY
# commits with the O "release-to-orbit" verb. Cleared on dev-nav toggle and whenever the mode is PLANETARY.
# DEAD (always false) with the flag off ⇒ the shipped auto-handoff is byte-identical.
var _dev_orbital_commit := false

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

	# COSMOS SPACE-NAV SN2: build the nav-frame machine ONLY under the flag (else it stays null ⇒ dead).
	if CubeSphere.SN_NAV_MODES:
		_nav = _CosmosNavCls.NavState.new()

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
	# SN-FIX #2 (FP_CROSS_KEEP_HEADING): the position reframe above is what keeps position CONTINUOUS across the
	# seam — it is untouched. The horizontal heading + velocity twist by `yaw_delta` (which re-aligns them to B's
	# lattice frame) is factored into the pure `reframe_twist` so the gate drives both flag states. Flag off ⇒ the
	# shipped twist (byte-identical); flag on ⇒ heading + velocity are preserved (the pilot's world heading stays,
	# the ground's dihedral tilt is carried separately by the ActiveFrame/camera).
	var tw := reframe_twist(rotation.y, velocity, yaw_delta, CubeSphere.FP_CROSS_KEEP_HEADING)
	rotation.y = tw[0]
	velocity = tw[1]

## SN-FIX #2 (FP_CROSS_KEEP_HEADING) — the pure crossing heading/velocity twist decision, factored out for the
## gate (no node state). `keep_heading` off ⇒ the shipped twist about UP by `yaw_delta`; on ⇒ heading + velocity
## are returned UNCHANGED (world heading preserved across the crossing). Returns [new_yaw, new_velocity].
static func reframe_twist(cur_yaw: float, cur_vel: Vector3, yaw_delta: float, keep_heading: bool) -> Array:
	if keep_heading:
		return [cur_yaw, cur_vel]
	return [wrapf(cur_yaw + yaw_delta, -PI, PI), cur_vel.rotated(Vector3.UP, yaw_delta)]

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
				# COSMOS SPACE-NAV SN5 (§7.1): under SN_DEVNAV, F toggles DEV-NAV (the mode-appropriate flight
				# controller + overlays) instead of the bare fly toggle. Flag OFF ⇒ the ELSE branch is the shipped
				# fly toggle BYTE-IDENTICALLY (nothing about dev-nav is touched). See _toggle_dev_nav.
				if CubeSphere.SN_DEVNAV:
					_toggle_dev_nav()
				else:
					flying = not flying
					velocity = Vector3.ZERO
					# Fly is a GUARANTEED escape hatch: while airborne the capsule is
					# disabled so no loose body can collide with (and therefore shove or
					# wedge) the player. Re-enabled on landing. See _move_horizontal.
					if _body_shape != null:
						_body_shape.disabled = flying
			KEY_O, KEY_G, KEY_R:
				# COSMOS SPACE-NAV SN5b (§7.4): the dev-nav toggles. Live ONLY while dev-nav is engaged (F);
				# otherwise inert (they carry no shipped binding). Flag off / not dev-nav ⇒ no-op.
				if CubeSphere.SN_DEVNAV and _dev_nav and _nav != null:
					_dev_toggle_key(event.keycode)

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
			# SN-FIX #2: under FP_CROSS_KEEP_HEADING the heading is NOT twisted (see apply_reframe), so the
			# executor's along-heading accumulator must NOT rotate either — forward a zero twist to stay consistent.
			_reframe_yaw = 0.0 if CubeSphere.FP_CROSS_KEEP_HEADING else float(cross["yaw_delta"])
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
	# COSMOS SPACE-NAV SN2: advance the nav-frame machine (gated — `_nav` is null with the flag off, so this
	# is a single null-check per tick and nothing else). It only READS the derived BCI state (§5.4 theorem).
	if _nav != null:
		_nav_tick(delta)

## COSMOS SPACE-NAV SN2 (docs/COSMOS-SPACE-NAV-DESIGN.md §4/§5): advance the nav-frame machine from the
## player's shipped LATTICE `position`. Derives the body-centred BCI [pos,vel] via the SN1 frame maps (world
## coords are body-FIXED — the planet is pinned — so p_bci = R_z(θ)·p_fix; velocity is a finite difference of
## the body-fixed world position mapped through fixed→bci), classifies with the 2-s dwell, and stores the
## HUD/telemetry re-expression. Reads only; never writes pos/vel. Earth-only (the Moon is SN6). No-op off the
## faceted planet (the nav machine's frame is the cosmos planet). LIVE-ONLY-VALIDATED — see the field comment.
func _nav_tick(delta: float) -> void:
	if not CubeSphere.FACETED:
		return
	var fid := TerrainConfig.active_facet()
	if fid < 0:
		return
	# G-SN-NOSPIRAL: clamp the per-frame dt fed to the nav path so a post-hitch huge frame (a 16-s recovery
	# frame was seen live) can never feed a runaway dt into the clock advance, the finite difference, or any
	# integration downstream. 1/30 s ⇒ a normal 60-fps tick (dt = 1/60) is UNCHANGED (byte-neutral common case).
	delta = _CosmosNavCls.clamp_nav_dt(delta)
	var w: Array = _FacetAtlasCls.lattice_to_world64(fid, position.x, position.y, position.z)
	var p_fix := _DVCls.v(w[0], w[1], w[2])                 # body-fixed (planet-pinned) world position, f64
	_nav_clock += delta * _EphCls.TIME_WARP
	var v_fix := _DVCls.v(0.0, 0.0, 0.0)
	if _nav_have_prev and delta > 0.0:
		# Bounded reciprocal (fd_inv_dt = 1/max(delta, MIN_FD_DT)) so a near-zero delta cannot blow up v_fix.
		v_fix = _DVCls.scale(_DVCls.sub(p_fix, _nav_prev_fix), _CosmosNavCls.fd_inv_dt(delta))
	var bci: Array = _OrbitalStateCls.fixed_to_bci("earth", _nav_clock, p_fix, v_fix)
	var p_bci: PackedFloat64Array = bci[0]
	# COSMOS SPACE-NAV SN5: when the dev-flight controller drove position THIS frame it OWNS the velocity —
	# use its BCI velocity instead of the finite difference (which would just re-derive it, less precisely).
	# Off dev-flight (SN2-only, or PLANETARY) this is exactly the shipped bci[1] finite-difference path.
	var v_bci: PackedFloat64Array = _dev_v_bci if (_dev_active and _dev_have_v) else bci[1]
	_nav.tick("earth", p_bci, v_bci, _nav_clock, delta)
	_nav_prev_fix = p_fix
	_nav_have_prev = true
	_nav_last_v_bci = v_bci                                  # seed for the next orbital dev-flight handoff (SN5)
	_dev_p_bci = p_bci                                       # stash for the O/G key handlers (SN5b)
	_nav_tele = _CosmosNavCls.telemetry(_nav, "earth", p_bci, v_bci, _nav_clock)
	# SN5b: refresh the compass strip from the camera forward re-expressed in BCI (spin axis = BCI +Z).
	if _dev_overlay != null and _dev_overlay.is_built():
		var rmag := _DVCls.length(p_bci)
		if rmag > 0.0:
			var rhat := _DVCls.scale(p_bci, 1.0 / rmag)
			var fwd := _dev_dir_to_bci(fid, _nav_clock, -window_camera_transform().basis.z)
			var heading := _DevNavOverlayCls.compass_heading(_DVCls.v(0.0, 0.0, 1.0), rhat, fwd)
			_dev_overlay.update_hud(heading, _CosmosNavCls.NAV_NAMES[int(_nav.mode)])

## COSMOS SPACE-NAV SN2: the additive nav telemetry (nav_mode/frame_v/|v_bci|/nav_frame) for the RemoteBridge.
## Empty dict when the machine is off (flag-off) ⇒ the guarded bridge merge adds nothing (byte-identical).
func nav_telemetry() -> Dictionary:
	return _nav_tele

## SN-FIX #1 (SN_HUD_NAV): the current nav-mode NAME for the HUD — the SAME string the RemoteBridge nav_mode
## telemetry uses. "—" when the nav machine is off (SN_NAV_MODES false ⇒ `_nav` is null). Pure read.
func nav_mode_name() -> String:
	if _nav == null:
		return "—"
	return _CosmosNavCls.NAV_NAMES[int(_nav.mode)]

## SN-FIX #1 (SN_HUD_NAV): the player's radial altitude in blocks for the HUD. On the faceted planet it is
## |world(lattice)| − R_BLOCKS (the same h the nav machine classifies on); off the faceted planet (FLAT) it is
## the lattice y (height above the ground plane). Pure read; no state.
func radial_altitude() -> float:
	if CubeSphere.FACETED:
		var fid := TerrainConfig.active_facet()
		if fid >= 0:
			var w: Array = _FacetAtlasCls.lattice_to_world64(fid, position.x, position.y, position.z)
			return sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]) - _FacetAtlasCls.R_BLOCKS
	return position.y

## COSMOS SPACE-NAV SN5 (§7.1): F toggled dev-nav. Dev-nav rides `flying` (noclip): entering disables the
## capsule (the shipped fly escape-hatch semantics), leaving re-enables it. The controller's velocity seed is
## dropped so the first orbital tick re-seeds from the live SN2 velocity. Only reachable under SN_DEVNAV.
func _toggle_dev_nav() -> void:
	_dev_nav = not _dev_nav
	flying = _dev_nav
	velocity = Vector3.ZERO
	_dev_have_v = false
	_dev_active = false
	_dev_orbital_commit = false                              # SN-FIX #3: entering/leaving dev-nav is never mid-orbit
	if _body_shape != null:
		_body_shape.disabled = flying
	# SN5b (§7.3): lazily build the overlay set on entry, free it on exit (NEVER-OOM — nothing retained off).
	if _dev_nav:
		if _dev_overlay == null:
			_dev_overlay = _DevNavOverlayCls.new()
			add_child(_dev_overlay)
			_dev_overlay.build(self, _FacetAtlasCls.R_BLOCKS)
	elif _dev_overlay != null:
		_dev_overlay.free_overlays()
		_dev_overlay.queue_free()
		_dev_overlay = null

## True iff dev-nav is engaged (F under SN_DEVNAV). Read by the overlays (SN5b) and the HUD.
func dev_nav_active() -> bool:
	return _dev_nav

## SN-FIX #3 (SN_NO_CEILING_BOUNCE) — the ORBITAL dev-flight handoff decision, factored out so the gate drives
## it directly (pure, no state). Returns true iff the velocity-command controller should own this fly tick.
## Flag OFF: exactly the shipped test — any orbital mode hands off (byte-identical). Flag ON: an orbital mode
## hands off ONLY once the pilot has explicitly committed (O verb) — so climbing through the atmosphere ceiling
## keeps the shipped kinematic lattice fly (climb velocity preserved, no ramp/deceleration = no bounce).
static func orbital_handoff(mode: int, orbital_commit: bool, no_ceiling_bounce: bool) -> bool:
	if mode == _CosmosNavCls.PLANETARY:
		return false
	if no_ceiling_bounce:
		return orbital_commit
	return true

## COSMOS SPACE-NAV SN5 (§7.2): the ORBITAL-mode dev-flight step. Reads the current lattice `position`, lifts it
## to the BCI frame, runs the velocity-command controller (CosmosDevFlight — the SN-R1-seamless kernel proven by
## G-SN-DEVFLIGHT), and re-projects the new kinematic BCI position back to the lattice `position`. The controller
## OWNS `_dev_v_bci` while orbital (seeded from the last SN2 velocity on entry ⇒ seamless from the PLANETARY
## lattice fly). LIVE-ONLY-VALIDATED: the BCI↔lattice re-projection is only meaningful while the player is
## roughly over the active facet (a morning-session check); the controller math itself is headless-proven.
func _dev_flight_move(delta: float, input: Vector3, running: bool) -> void:
	# G-SN-NOSPIRAL: clamp the dt so a post-hitch huge frame cannot fling the kinematic BCI position by
	# v·dt with a runaway dt (nor feed one to the controller). Byte-neutral for a normal 60-fps tick.
	delta = _CosmosNavCls.clamp_nav_dt(delta)
	var fid := TerrainConfig.active_facet()
	if fid < 0:
		# Off-facet safety: fall back to the shipped lattice fly for this tick (never strand the player).
		var vy0 := 0.0
		if not remote_drive:
			if Input.is_key_pressed(KEY_SPACE): vy0 += 1.0
			if Input.is_key_pressed(KEY_CTRL): vy0 -= 1.0
		var wish0 := (transform.basis * Vector3(input.x, 0, input.z))
		wish0.y = 0.0
		if wish0.length() > 0.0:
			wish0 = wish0.normalized()
		position += (wish0 + Vector3(0, vy0, 0)) * fly_speed * (2.0 if running else 1.0) * delta
		velocity = Vector3.ZERO
		return
	var t := _nav_clock
	# lattice → body-fixed world → BCI position (the SN1 frame maps; body coords are planet-pinned).
	var w: Array = _FacetAtlasCls.lattice_to_world64(fid, position.x, position.y, position.z)
	var p_fix := _DVCls.v(w[0], w[1], w[2])
	var p_bci: PackedFloat64Array = _OrbitalStateCls.fixed_to_bci("earth", t, p_fix, _DVCls.v(0.0, 0.0, 0.0))[0]
	var mode := int(_nav.mode)
	# Seed the controller's velocity on the first orbital tick from the last SN2-derived BCI velocity (seamless
	# handoff from the PLANETARY lattice fly); if none is available yet, rest in the current frame (carrier).
	if not _dev_have_v:
		if _nav_last_v_bci.size() == 3:
			_dev_v_bci = PackedFloat64Array([_nav_last_v_bci[0], _nav_last_v_bci[1], _nav_last_v_bci[2]])
		else:
			_dev_v_bci = _CosmosNavCls.carrier_velocity(mode, "earth", p_bci, _DVCls.v(0.0, 0.0, 0.0), t)
		_dev_have_v = true
	# Camera basis (window/lattice orientation) → BCI axis columns for the fully camera-relative wish.
	var cb := window_camera_transform().basis
	var cam_x := _dev_dir_to_bci(fid, t, cb.x)
	var cam_y := _dev_dir_to_bci(fid, t, cb.y)
	var cam_z := _dev_dir_to_bci(fid, t, cb.z)
	# Vertical (Space/Ctrl) — camera-relative up/down, matching the shipped fly verbs.
	var vy := 0.0
	if remote_drive:
		vy = input.y
	else:
		if Input.is_key_pressed(KEY_SPACE): vy += 1.0
		if Input.is_key_pressed(KEY_CTRL): vy -= 1.0
	var wish_bci := _DevFlightCls.wish_dir(cam_x, cam_y, cam_z, Vector3(input.x, vy, input.z))
	var cap := _DevFlightCls.speed_cap(mode, "earth", p_bci, t, running)
	var out: Array = _DevFlightCls.step(mode, "earth", p_bci, _dev_v_bci, t, delta, wish_bci, cap)
	var p_new: PackedFloat64Array = out[0]
	_dev_v_bci = out[1]
	# BCI → body-fixed → lattice, and write it back as the player's canonical position.
	var pf_new: PackedFloat64Array = _OrbitalStateCls.bci_to_fixed("earth", t, p_new, _dev_v_bci)[0]
	var lat: Array = _FacetAtlasCls.world_to_lattice64(fid, pf_new[0], pf_new[1], pf_new[2])
	position = Vector3(lat[0], lat[1], lat[2])
	_horiz_vel = Vector3.ZERO
	velocity = Vector3.ZERO
	_dev_active = true                                       # tells _nav_tick the controller owns velocity this frame

## COSMOS SPACE-NAV SN5: map a LATTICE direction to a BCI direction — frame_basis(fid) lifts it to the body-fixed
## world frame, then the SN1 fixed→bci position map (R_z(θ)) rotates it into the inertial frame. Pure rotation
## (no ω⃗×p term for a direction): the position component of fixed_to_bci is exactly R_z(θ)·d.
func _dev_dir_to_bci(fid: int, t: float, d_lat: Vector3) -> PackedFloat64Array:
	var wd := _FacetAtlasCls.frame_basis(fid) * d_lat
	return _OrbitalStateCls.fixed_to_bci("earth", t, _DVCls.v(wd.x, wd.y, wd.z), _DVCls.v(0.0, 0.0, 0.0))[0]

## COSMOS SPACE-NAV SN5b (§7.4): the O/G/R dev-nav toggles. Pure re-uses of the gated kernel math
## (CosmosDevFlight.release_circular / geostationary_snap, CosmosNav.toggle_r_latch). O and G are explicit
## user commands (allowed dev verbs), applied to the controller's BCI state; R flips the classifier's detach
## latch. LIVE-ONLY: the resulting FEEL + the G teleport re-projection at altitude (morning). Only reached
## under SN_DEVNAV while dev-nav is engaged (the key handler guards it).
func _dev_toggle_key(keycode: int) -> void:
	if _dev_p_bci.size() != 3:
		return                                              # no BCI state yet (nav machine hasn't ticked)
	var mode := int(_nav.mode)
	var t := _nav_clock
	var fid := TerrainConfig.active_facet()
	match keycode:
		KEY_R:
			_nav.toggle_r_latch()                           # §7.4 R: latch DEEP_SPACE expression from HIGH_ORBIT
		KEY_O:
			# O — circular-orbit release (LOW/HIGH): set the controller velocity to the circular orbital velocity
			# in the look-tangential direction. (True free-coast handoff to the ORBITAL integrator is live/SN1.)
			if mode == _CosmosNavCls.LOW_ORBIT or mode == _CosmosNavCls.HIGH_ORBIT:
				var look := _dev_dir_to_bci(fid, t, -window_camera_transform().basis.z) if fid >= 0 else _DVCls.v(0.0, 1.0, 0.0)
				_dev_v_bci = _DevFlightCls.release_circular("earth", _dev_p_bci, look, _dev_v_bci if _dev_have_v else _DVCls.v(0.0, 0.0, 0.0))
				_dev_have_v = true
				# SN-FIX #3: O is the explicit "commit to orbital flight" verb — latch it so the velocity-command
				# controller now owns flight (under SN_NO_CEILING_BOUNCE; the latch is inert with the flag off).
				_dev_orbital_commit = true
		KEY_G:
			# G — geostationary snap (HIGH only): teleport to r_geo at the current longitude, v = ω⃗×p. Over a body
			# with no stationary orbit (r_geo > SOI) the snap returns empty ⇒ "none" (no-op here).
			if mode == _CosmosNavCls.HIGH_ORBIT and fid >= 0:
				var snap := _DevFlightCls.geostationary_snap("earth", _dev_p_bci)
				if snap.size() == 2:
					var p_new: PackedFloat64Array = snap[0]
					var v_new: PackedFloat64Array = snap[1]
					var pf: PackedFloat64Array = _OrbitalStateCls.bci_to_fixed("earth", t, p_new, v_new)[0]
					var lat: Array = _FacetAtlasCls.world_to_lattice64(fid, pf[0], pf[1], pf[2])
					position = Vector3(lat[0], lat[1], lat[2])
					_dev_v_bci = v_new
					_dev_have_v = true

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
		# COSMOS SPACE-NAV SN5 (§7.2): under dev-nav, once the nav machine reads an ORBITAL frame (LOW/HIGH/
		# DEEP/INTER) the velocity-command controller takes over — it owns the BCI velocity and re-projects the
		# kinematic BCI position back to the lattice. In PLANETARY the shipped lattice fly below is used UNCHANGED
		# (§7.2 "lattice path unchanged"). Flag off / no nav machine ⇒ `_dev_nav` is false ⇒ this is skipped.
		_dev_active = false
		# SN-FIX #3 (SN_NO_CEILING_BOUNCE): the handoff decision is factored so the gate can drive it. Flag off ⇒
		# `orbital_handoff` is exactly the shipped `mode != PLANETARY` test (byte-identical). Flag on ⇒ it also
		# requires `_dev_orbital_commit`, so crossing the atmosphere ceiling keeps the kinematic lattice fly (the
		# climb velocity is preserved — no controller ramp/deceleration) until the pilot explicitly commits (O).
		if _dev_nav and _nav != null and orbital_handoff(int(_nav.mode), _dev_orbital_commit, CubeSphere.SN_NO_CEILING_BOUNCE):
			_dev_flight_move(delta, input, running)
			return
		# PLANETARY dev-nav (or the flag off) uses the shipped lattice fly below. Drop the controller's velocity
		# seed so the next ORBITAL entry re-seeds from the fresh SN2-derived velocity (a seamless handoff).
		if _dev_nav:
			_dev_have_v = false
			# SN-FIX #3: back in PLANETARY the pilot is not in orbit — clear the commit latch so the next climb
			# again keeps the kinematic fly through the band until they re-commit. No-op with the flag off.
			if int(_nav.mode) == _CosmosNavCls.PLANETARY:
				_dev_orbital_commit = false
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
