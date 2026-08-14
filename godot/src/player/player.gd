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
# COSMOS ORBIT-FRAME (docs/COSMOS-ORBIT-FRAME-DESIGN.md §7): the pure inertial-attitude kernel. DEAD unless
# CubeSphere.ORBIT_ATTITUDE (same FLM/FLB preload convention — the machine below never leaves SURFACE off-flag).
const _CosmosAttitudeCls := preload("res://src/cosmos/cosmos_attitude.gd")

@export var walk_speed := 5.5
@export var run_speed := 9.5
@export var fly_speed := 16.0
@export var jump_velocity := 8.0
@export var gravity := 9.8
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

# DEV/TEST freeze_player latch (dev-instrument tooling): pins the player by suppressing ONLY its motion integration
# (skip _move — gravity, dev-fly drift, orbital coast) while the rest of the tick runs, so a capture hold is
# genuinely stationary yet the executor/streaming/camera are never starved. Default false ⇒ the _physics_process
# branch is never taken (byte-identical normal play); only set through remote_freeze_player under a live control
# grant. Distinct from `frozen` (the one-shot boot-prewarm freeze main.gd owns).
var _dev_freeze_player := false

# DEV/TEST fall-through guard latch (dev-instrument tooling): armed by a dev teleport / set_alt / freeze-release
# so the ensuing settle/drop can never leave the player BELOW the analytic surface (the live "buried at alt −18,
# floor 26 blocks under the terrain" from a stale fast-regime-crossing floor query). Default false ⇒ the
# _physics_process branch is never taken (byte-identical normal play); disarmed once the player lands cleanly.
var _dev_land_guard := false
# Feet more than this many blocks below the analytic surface ⇒ the dev guard clamps them up (below-floor tolerance).
const DEV_LAND_EPS := 0.5

# COSMOS FALL-THROUGH FIX (FP_TP_FLOOR_WELD) — the dev GEO-teleport landing weld. `_dev_teleport_geo` resolves the
# owner facet + surface, drops the player from altitude, and arms the fall-through guard. But a facet crossing that
# fires MID-FALL (live) reframes position into a neighbour lattice, so surface_y/floor_under then read the neighbour's
# deep column and the guard never catches (the player sinks to the deep fill). While `_tp_land_active` (armed ONLY by
# `_dev_teleport_geo`, and only meaningful under FP_TP_FLOOR_WELD), `_physics_process` re-asserts the owner facet and
# SUPPRESSES crossings so the floor stays on the resolved owner column. Default false ⇒ never welded (byte-identical
# normal play — the latch is set by no other path). Cleared when the guard disarms (a clean landing) or on a new reposition.
var _tp_land_active := false
var _tp_owner_fid := -1
var _tp_land_frames := 0   # FP_TP_FLOOR_WELD: 1 while a dev-teleport surface floor-hold is armed (0 = released)
var _tp_land_x := 0.0       # FP_TP_FLOOR_WELD: the teleport column the surface floor-hold is pinned to
var _tp_land_z := 0.0

# COSMOS STREAM-SETTLE (feat/voxiverse-stream-settle): the teleport/fast-travel "settling" latch. A dev teleport to
# a fresh far facet re-anchors the near field but the voxel view has NOT streamed/meshed there yet — so instead of
# dropping the player into un-streamed void (the live "player in space, buried on land" symptom) we HOLD them
# hovering at the analytic surface_y (no fall, control held) until the near-coverage probe says their column is
# meshed, or a hard cap elapses. Only engaged by _dev_reposition on a GROUND teleport when the world can actually
# answer the coverage probe (FACETED + module); default false ⇒ byte-identical normal play + FLAT dev teleports.
var _settle_active := false
var _settle_elapsed := 0.0
# Hard cap: release the settle after this many seconds even if coverage never arrives, so a teleport can NEVER hang.
const SETTLE_CAP_S := 6.0
# Only engage the settle when the placement is within this many blocks of the surface (a ground teleport). A higher
# placement is an intended hover (e.g. set_alt to altitude for a capture) and must NOT be force-landed.
const SETTLE_ENGAGE_BAND := 12.0

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

# G-REENTRY FIX A (2026-07-19 live de-orbit blowup) — the facet frame the lattice `position` is EXPRESSED in.
# The crossing protocol is two-phase (world_manager.maybe_cross_facet commits TerrainConfig.set_active_facet,
# THEN the caller applies the returned reframed pose via apply_reframe) with a long fallible pipeline between
# the two (redesignate / pool / far ring / restream). Any abort in that pipeline — or any future rogue
# set_active_facet — leaves the ACTIVE frame flipped while `position` still holds the OLD facet's lattice
# numbers; reinterpreting them in the new facet's decorrelated frame (offsets up to ±32768) is a one-frame
# teleport of |Δframe| blocks (11081 live at re-entry; the SN2 finite-difference then reads Δp/dt ≈ 642074 b/s
# and the free-fall re-seed adopts it — the "escape" latch). _heal_frame_desync() makes frame/pose consistency
# an INVARIANT: every physics frame starts by re-expressing the pose if the active facet changed without us.
var _pos_fid := -1

# COSMOS FALL-THROUGH INCIDENT PROBE (docs/COSMOS-FLOOR-SURFACE-FALLTHROUGH-DESIGN.md §4, FP_FALLTHRU_PROBE,
# FablePhys design) — live proof-of-mechanism telemetry, not a fix. `_fallthru_tele` is the additive dict the
# probe fills on a live incident, merged into `nav_telemetry()`'s return (the SAME RemoteBridge additive-merge
# point `_nav_tele` uses) so a live fall self-diagnoses without any remote_bridge.gd change. `_fallthru_probe_last_ms`
# rate-limits recording to 1/s so a persistent stuck fall can't spam the bridge/console. Both inert (empty dict /
# unread) unless CubeSphere.FP_FALLTHRU_PROBE.
var _fallthru_tele: Dictionary = {}
var _fallthru_probe_last_ms := -1000000

# COSMOS-ORBITAL-O1O4 O4c (docs/COSMOS-ORBITAL-O1O4-DESIGN.md §3.5 / SPACE-NAV §8): the SOI dominant body — the
# body whose local dynamics (spin frame, GM_dyn, feel-gravity, drag, terrain) the player reads. `_dominant_body()`
# is THE single accessor and returns this; it is "earth" always with CubeSphere.SOI_SWAP off (byte-identical), and
# under the flag is refreshed each physics tick from the active facet (surface/walk/land ⇒ FacetAtlas.body_name_of_fid)
# or, while coasting, from the SOI test on the carried BCI position (CosmosNav.soi_dominant, with the swap
# re-expression applied to `_coast_p/v_bci`). Every generalized "earth"→_dominant_body() site downstream reads it.
var _dom_body := "earth"
# Earth walk-feel baseline captured in _ready (after the M1 feel hook): gravity/jump the per-body feel scales from.
# _apply_body_feel(body) sets gravity = base·(g_body/g_earth), jump = base·√(g_body/g_earth) — preserving JUMP
# HEIGHT while HANG TIME scales ~1/√g (Moon ×2.5). Earth ⇒ ratio 1 ⇒ the shipped 9.8/8.0 (byte-neutral).
var _feel_earth_g := 9.8
var _feel_earth_jump := 8.0

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
# SN-FIX #3 (SN_NO_CEILING_BOUNCE) — the F-OFF free-fall state. When F is off ABOVE the atmosphere ceiling the
# player free-falls in the planet-centred (inertial) BCI frame under GM_dyn/r² (no surface-rotation drag); the
# BCI velocity is integrated here and seeded — on the flight→fall handoff — from the last SN2 finite-difference
# BCI velocity so there is NO velocity jump. Below the ceiling the shipped surface-feel walk gravity takes over
# (the fall's radial velocity is handed to velocity.y for continuity). DEAD with the flag off.
var _fall_v_bci := PackedFloat64Array()
var _fall_have_v := false
# COSMOS UP-VECTOR FACET-DESYNC FIX (FP_UPVECTOR_FACET_HEAL, docs/COSMOS-PLAYER-UPVECTOR-FACET-DESYNC-DESIGN.md
# §2): captured each `_move` tick from the SAME landing-clamp test already computed there (`position.y <=
# floor_y`) — zero extra cost. Consumed once per physics frame as the `grounded` hint into `maybe_cross_facet`'s
# strip resolver; unread (dead) with the flag off.
var _grounded := false
# COSMOS-PERF FALL-COLLAPSE FIX (FP_FREEFALL_RAILS) — the carried BCI fall POSITION for the closed-form (RAILS)
# free-fall coast. Like the orbit coast's `_coast_p_bci`, the closed-form path carries [p,v] in the BCI frame
# across frames (advanced by ONE universal-variable step/frame) instead of reconstructing p from the f32 lattice
# `position` each frame — so the per-frame integration is O(1) and touches no lattice state. Re-seeded (cleared)
# on every fresh fall entry (below), so a new fall reconstructs it once from the current lattice pose. DEAD
# (never read) with FP_FREEFALL_RAILS off — the shipped Verlet coast carries only `_fall_v_bci`.
var _fall_p_bci := PackedFloat64Array()
# G-LANDING FIX (SN_FOFF_RADIAL_FALL) — one-shot latch set by the EXPLICIT F flight-off toggle. The next
# free-fall seed keeps only the RADIAL component of the flight velocity (quit-flying = commit to landing);
# automatic regime transitions never set it, so their SN-R1 velocity continuity is untouched. DEAD (never
# consumed) with the flag off.
var _foff_radial := false
# COSMOS SPACE-NAV §7.4 (ORBIT_COAST) — the O free-coast state. `_orbit_coasting` is set by the O toggle in
# LOW/HIGH orbit; while true, each physics frame integrates `_coast_v_bci` under GM_dyn/r² gravity (the shared
# Kepler coast, seeded tangential by O) and re-projects to the lattice `position` — a stable circular seed holds
# radius (the fix for "orbits then hangs"). The coast mirrors `_coast_v_bci` into `_dev_v_bci` each tick so the
# nav machine reads the true orbital velocity AND an exit to the dev-flight controller is velocity-continuous
# (SN-R1). DEAD (never set) with ORBIT_COAST off ⇒ the shipped O velocity-command path is byte-identical.
var _orbit_coasting := false
var _coast_v_bci := PackedFloat64Array()
# SN-ODECAY FIX (G-ODECAY, verify_odecay.gd): the coast's BCI POSITION carried in f64 across ticks, MIRRORING
# `_coast_v_bci`. The original coast reconstructed p from the body-FIXED f32 `position` each tick and re-projected
# with the SAME t, rotating p by one tick of planet spin (ω·dt) relative to the un-rotated f64 velocity — this
# desynchronised the (p,v) pair and PUMPED orbital eccentricity (periapsis drops each orbit until the surface
# handoff arrests the player on the far side: the live "arcs to the opposite side and stops"). Carrying [p,v] in
# f64 and writing `position` as a DISPLAY-ONLY projection removes the round-trip. Empty ⇒ unseeded (reconstruct once).
var _coast_p_bci := PackedFloat64Array()
# SN-ODECAY station-keeping cooldown (s): the O free-coast periodically adds a small PROGRADE Δv when the orbit
# nears the atmosphere (CosmosDevFlight.station_keep_dv), so a decaying orbit re-lifts instead of spiralling in.
# Counts down each coast tick; a correction fires + resets it. DEAD off ORBIT_COAST ⇒ byte-identical.
var _coast_boost_cd := 0.0

# COSMOS ORBIT-FRAME (docs/COSMOS-ORBIT-FRAME-DESIGN.md §3) — the inertial-attitude state machine. ALL DEAD
# (mode pinned ATT_SURFACE, camera never emancipated) unless CubeSphere.ORBIT_ATTITUDE AND _nav != null, so the
# input/camera/window_camera_transform branches all fall through to the shipped surface FPS path (byte-identical).
# SURFACE = shipped clamped-euler (rotation.y + _pitch). SPACE = the BCI quaternion _att_q (facet-decoupled,
# 6DOF). RECOVER = the landing slerp back to a gravity-aligned surface pose (Phase C; Phase A hands back instantly).
const ATT_SURFACE := 0
const ATT_SPACE := 1
const ATT_RECOVER := 2                          # (Phase C) the smooth landing-recovery blend state
var _att_mode := ATT_SURFACE
var _att_q := Quaternion.IDENTITY              # the camera basis in the BCI (inertial) frame (SPACE)
var _att_recover_b_start := Basis()            # RECOVER (Phase C): the frozen SCENE basis at the leave-SPACE instant
var _att_recover_yaw := 0.0                     # RECOVER: the target surface yaw (mouse-drivable during the blend)
var _att_recover_pitch := 0.0                   # RECOVER: the target surface pitch (clamped ±1.5)
var _att_recover_alpha := 0.0                   # RECOVER: the 0→1 blend parameter (ramps over ORBIT_T_REC)

var _camera: Camera3D
var _ray: RayCast3D
var _capsule: CapsuleShape3D
var _body_shape: CollisionShape3D        # the player's capsule collider (disabled while flying)
var _pitch := 0.0
var _aimed: Dictionary = {}
var _horiz_vel := Vector3.ZERO            # this frame's horizontal move velocity

# COSMOS PLAYER-UPVECTOR-FACET-DESYNC FIX §5.2 (FP_CAMERA_RADIAL_LEVEL) — the post-`_attitude_handback` ease
# ramp (0→1 over CAM_RL_EASE_S s). Starts at 1.0 (no ramp needed at boot/spawn — already in ATT_SURFACE with no
# prior space attitude to hand back from); reset to 0.0 by `_attitude_handback`, advanced in `_move`'s roll
# write. Unread with the flag off.
var _cam_rl_ease := 1.0
# §5.3 — the last-applied SIGNED roll angle (rad, `_CAM_RL_SIGN * phi`), cached so `window_camera_transform()`
# can mirror the displayed pose without paying a second floor query every call (it has no access to `_move`'s
# `terrain_floor` local). 0.0 (no roll) until the first `_move` tick under the flag; stays 0.0 forever off-flag.
var _cam_rl_last_phi := 0.0

# COSMOS-PERF FALL-ALTRATE (FP_FALL_CAMFAR_HOLD): throttle state for the altitude-ramped camera near/far planes.
# _camfar_prev_d/_usec derive the radial speed; _camfar_apply_msec throttles the re-apply to ≤ 1/FALL_THROTTLE_MS
# during a fast descent. All −1 sentinels (no prior sample) ⇒ the first call always applies. DEAD off the flag.
var _camfar_prev_d := -1.0
var _camfar_prev_usec := -1
var _camfar_apply_msec := -1

# COSMOS-PERF FALL-TIMING (FP_FALL_TIMING) — per-frame CPU-segment timers, DIAGNOSTIC. `_ft` holds the window MAX
# µs per segment key (t_move_us / t_coast_us / t_stream_us / t_nav_us / t_att_us / t_pushbodies_us / t_aim_us and,
# pushed in from main._process / CosmosSky, t_scaledbody_us / t_farring_us / t_sky_us) plus n_coast_calls. Written
# ONLY under the flag (the segment wrappers are gated), so off the dict stays empty ⇒ fall_timing() returns {} ⇒
# byte-identical telemetry. Cleared each telemetry window (on read by fall_timing) ⇒ NEVER-OOM (bounded key set).
var _ft := {}

# ── REMOTE-DRIVE INTENT SEAM (docs/COSMOS-REMOTE-CONTROL-DESIGN.md §4.2) ─────────────────────────
# The ONLY hook the RemoteControl executor drives the rover through: it injects INTENT at the exact
# level a human does (the WASD/Shift/Space polls in _move), so commanded motion flows through the
# IDENTICAL analytic wall/floor/ceiling/collision pipeline — real locomotion, never a teleport. All
# fields are zero/false in normal play and the executor never exists while RemoteBridge.CONTROL_ENABLED
# is false, so this is a byte-identical no-op today.
var remote_drive := false                 # true only while a move step runs → _move uses remote_input/run
var remote_input := Vector3.ZERO          # body-local wish, SAME shape as the WASD `input` vector
var remote_run := false                   # substitutes the KEY_SHIFT poll
var _remote_cruise_until_usec := 0         # DEV remote-cruise self-expiring deadline (usec); 0 ⇒ inert (byte-identical)
var _remote_cruise_dir := 1                # +1 forward, -1 reverse (remote cruise direction)
var remote_jump := false                  # one-shot latch, consumed by the grounded/fly jump branch (§4.6)
var remote_yaw_rate := 0.0                # rad/s the executor is applying this tick (seam indicator; the
                                          # executor owns the exact rotate_y for seam-immune remaining-degrees)
# COSMOS SPACE-FLY (docs/COSMOS-SPACEFLY-DESIGN.md) — the ROLL seam. rad/s the executor is applying this tick,
# OR'd into the KEY_Q/KEY_E poll in _attitude_tick's ATT_SPACE branch (the ONLY place roll is read). Zero in
# normal play and while no roll step runs; the executor never exists off CONTROL_ENABLED, so byte-identical.
var remote_roll_rate := 0.0
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
	# COSMOS-ORBITAL-O1O4 O4c: capture the Earth walk-feel baseline (post the M1 hook) so per-body feel scaling on
	# a dominant-body swap (Moon ⇒ 1/6 g, floaty jumps) is exact and reversible. No behaviour change here — off
	# SOI_SWAP _apply_body_feel is never called and these fields are never re-read.
	_feel_earth_g = gravity
	_feel_earth_jump = jump_velocity

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

## COSMOS REMOTE VIEW-STATE (dev-instrument): report the SURFACE camera facing so a view can be remembered + restored
## exactly — body yaw + camera pitch (deg, the set_initial_look parametrization) plus the world-space forward vector.
## Returns {} when the camera rig is absent so the telemetry stream stays byte-identical without it.
func view_telemetry() -> Dictionary:
	if _camera == null:
		return {}
	var fwd := (-_camera.global_transform.basis.z).normalized()
	return {
		"cam_yaw_deg": snappedf(rad_to_deg(rotation.y), 0.01),
		"cam_pitch_deg": snappedf(rad_to_deg(_pitch), 0.01),
		"look_world": "(%f, %f, %f)" % [fwd.x, fwd.y, fwd.z],
	}

## COSMOS REMOTE VIEW-STATE restore (dev-instrument): set the SURFACE facing to an ABSOLUTE (yaw,pitch) in degrees —
## the exact inverse of view_telemetry's cam_yaw_deg/cam_pitch_deg. Reuses the shipped set_initial_look param path.
## Reached only via the CONTROL_ENABLED-gated teleport op (yaw_deg/pitch_deg), so it is inert in normal play.
func remote_set_view(yaw_deg: float, pitch_deg: float) -> void:
	set_initial_look(deg_to_rad(yaw_deg), deg_to_rad(pitch_deg))

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
	# G-REENTRY FIX A: `position` is now expressed in the CURRENT active facet's lattice — record it so
	# _heal_frame_desync() can prove (and restore) frame/pose consistency every physics frame.
	_pos_fid = TerrainConfig.active_facet()
	# SN-FIX #2 (FP_CROSS_KEEP_HEADING): the position reframe above is what keeps position CONTINUOUS across the
	# seam — it is untouched. The horizontal heading + velocity twist by `yaw_delta` (which re-aligns them to B's
	# lattice frame) is factored into the pure `reframe_twist` so the gate drives both flag states. Flag off ⇒ the
	# shipped twist (byte-identical); flag on ⇒ heading + velocity are preserved (the pilot's world heading stays,
	# the ground's dihedral tilt is carried separately by the ActiveFrame/camera).
	# COSMOS FS2-V2 (§5): pass the frame-aware flag + whether the fixed frame is active so KEEP_HEADING does not
	# double-twist the world heading under the fixed frame (the shipped +yaw_delta twist already preserves it).
	var tw := reframe_twist(rotation.y, velocity, yaw_delta, CubeSphere.FP_CROSS_KEEP_HEADING,
		CubeSphere.FP_TWIST_FRAME_AWARE, _frame.enabled())
	rotation.y = tw[0]
	velocity = tw[1]

## SN-FIX #2 (FP_CROSS_KEEP_HEADING) — the pure crossing heading/velocity twist decision, factored out for the
## gate (no node state). `keep_heading` off ⇒ the shipped twist about UP by `yaw_delta`; on ⇒ heading + velocity
## are returned UNCHANGED (world heading preserved across the crossing). Returns [new_yaw, new_velocity].
static func reframe_twist(cur_yaw: float, cur_vel: Vector3, yaw_delta: float, keep_heading: bool,
		frame_aware: bool = false, frame_fixed: bool = false) -> Array:
	# COSMOS FS2-V2 (docs/COSMOS-FACET-SEAMS-V2.md §5): FRAME-AWARE twist. Under the fixed frame the player's WORLD
	# state is frame_basis(fid)·local_state, so preserving it across a crossing needs local_B = crossing_basis(A,B)·
	# local_A. crossing_basis(A,B) = frame_basis(B)⁻¹·frame_basis(A); its horizontal (about-UP) action is a rotation
	# by −yaw_delta (yaw_delta = atan2(ex.z, ex.x) of A's +X in B, and Basis(UP,θ)·x̂ has atan2(z,x) = −θ). So the
	# WORLD-heading-and-velocity-preserving twist is −yaw_delta, NOT +yaw_delta (the shipped/legacy +yaw_delta
	# DOUBLE-twists under the fixed frame: measured 2·|yaw_delta| heading error at a 58° seam — the live glitch).
	# Verified empirically (verify_facet_seams G-CROSS-HEADING) against the real frame_basis: −yaw_delta ⇒ Δ≈0,
	# +yaw_delta ⇒ Δ≈2·yaw_delta. Applies REGARDLESS of keep_heading (heading MUST track the velocity twist, else
	# facing and motion decouple). Default off (frame_aware=false) ⇒ skipped, byte-identical to the shipped form.
	if frame_aware and frame_fixed:
		return [wrapf(cur_yaw - yaw_delta, -PI, PI), cur_vel.rotated(Vector3.UP, -yaw_delta)]
	if keep_heading:
		return [cur_yaw, cur_vel]
	return [wrapf(cur_yaw + yaw_delta, -PI, PI), cur_vel.rotated(Vector3.UP, yaw_delta)]

## G-REENTRY FIX A (the live re-entry teleport) — frame/pose consistency as an INVARIANT, not a protocol hope.
## If the active facet changed since `position` was last expressed (a crossing pipeline that aborted between
## world_manager's set_active_facet and our apply_reframe, or any other actor flipping the active facet), the
## lattice pose is STALE: reading it in the new facet's decorrelated frame is a |Δframe|-block teleport (the
## live 11081-block atmosphere-entry jump; 25.7k in the headless reproduction). Heal it LOSSLESSLY by applying
## the exact committed-crossing math (reframe_position64 + the crossing-basis yaw twist via apply_reframe) —
## the same world point, heading and velocity re-expressed, so the heal itself is position/velocity-continuous
## (SN-R1). One int compare per frame in the healthy case. Proven by G-REENTRY-CONTINUOUS (fid-desync gate).
func _heal_frame_desync() -> void:
	if not CubeSphere.FACETED:
		return
	var fid := TerrainConfig.active_facet()
	if fid < 0:
		return                                              # no active frame to express in — keep the stamp we have
	if _pos_fid < 0 or _pos_fid == fid:
		_pos_fid = fid
		return
	var from := _pos_fid
	var np: Array = _FacetAtlasCls.reframe_position64(from, fid, position.x, position.y, position.z)
	var ex: Vector3 = _FacetAtlasCls.crossing_basis(from, fid) * Vector3(1.0, 0.0, 0.0)
	apply_reframe(Vector3(np[0], np[1], np[2]), atan2(ex.z, ex.x))   # also re-stamps _pos_fid = fid
	print("[Player] frame desync healed: pose re-expressed %d -> %d (aborted crossing pipeline?)" % [from, fid])

func _capture_mouse() -> void:
	# Web quirk (Godot #102209): after Esc the pointer won't re-lock unless we
	# cycle through VISIBLE first. Harmless on desktop.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## The camera's world transform — the ShaderPrewarm places its hidden warm-up pile in
## front of it. Falls back to the player transform before the camera rig is built.
func camera_global_transform() -> Transform3D:
	return _camera.global_transform if _camera != null else global_transform

## FP_SKY_PLANET_CENTRE: the planet's render-frame centre (the floating-origin / scaled-body offset). CosmosSky
## subtracts this from the camera origin so its altitude/up/sun-elevation/light math is planet-relative even above
## the re-anchor, where the camera stays near the scene origin and the planet is offset. ZERO before the ring exists.
func planet_render_centre() -> Vector3:
	return world.planet_render_centre() if world != null else Vector3.ZERO

# --- COSMOS PLAYER-UPVECTOR-FACET-DESYNC FIX §5.1/§5.2 (FP_CAMERA_RADIAL_LEVEL) — pure roll math ---------------

## §5.1 — the fixed sign that makes `Basis(local +Z, s·phi)` (applied IN THE PRE-ROLL BASIS'S OWN LOCAL FRAME,
## i.e. B0 * Basis(ẑ, θ)) satisfy the post-condition `r̂'·u_r == 0 ∧ û'·u_r > 0` — derived, not tuned. Basis(axis,
## angle) is right-handed: rotating B0 by θ about its own local +Z gives r̂' = cosθ·r̂0 + sinθ·û0,
## û' = cosθ·û0 − sinθ·r̂0. With a = u_r·r̂0, b = u_r·û0 (so phi_raw = atan2(a,b)), solving cosθ·a + sinθ·b = 0
## for θ = −phi_raw gives r̂'·u_r = 0 exactly, and û'·u_r = sqrt(a²+b²) > 0 (the OTHER root, θ = −phi_raw + π,
## flips û'·u_r negative — excluded). So s = −1. Pinned by verify_camera_radial_level.gd's analytic arm — do not
## flip without re-deriving (the derivation is the comment above, not a magic number).
const _CAM_RL_SIGN := -1.0

## §5.1 — the RAW (unblended) screen-space lean of the radial up relative to the pre-roll camera basis:
## atan2(u_r·r̂0, u_r·û0). Pure; independently re-derivable via the projection-form construction
## (û' = normalize(u_r − (u_r·f̂)f̂), r̂' = û' × f̂) — see `_CAM_RL_SIGN`'s derivation.
static func cam_rl_phi_raw(u_r: Vector3, r0: Vector3, u0: Vector3) -> float:
	return atan2(u_r.dot(r0), u_r.dot(u0))

## §5.2 — altitude blend w(alt): C1 (smoothstep), exact 0 at/below CAM_RL_ALT_LO (ground reads true — the
## near-floor bound the heal's domain relies on), exact 1 at/above CAM_RL_ALT_HI.
static func cam_rl_w(alt: float) -> float:
	return smoothstep(CubeSphere.CAM_RL_ALT_LO, CubeSphere.CAM_RL_ALT_HI, alt)

## §5.2 — pitch blend v(pitch) = cos²(pitch): 1 looking level (full leveling), → ~0.005 near the ±1.5 rad pitch
## clamp — kills both the mid-altitude floor-cant objection looking down and the atan2 near-±90° ill-conditioning.
static func cam_rl_v(pitch: float) -> float:
	return cos(pitch) * cos(pitch)

## §5.1/§5.2 — the full blended, UNSIGNED-direction roll magnitude (the caller applies `_CAM_RL_SIGN`):
## w(alt)·v(pitch)·ease·phi_raw. Pure; `ease` folds in the §5.2 post-`_attitude_handback` ramp.
static func cam_rl_phi(u_r: Vector3, r0: Vector3, u0: Vector3, alt: float, pitch: float, ease: float) -> float:
	return cam_rl_w(alt) * cam_rl_v(pitch) * ease * cam_rl_phi_raw(u_r, r0, u0)

## COSMOS R2.2 (Design Z): the WINDOW-space camera transform (what the camera is in pre-COSMOS window space)
## — body yaw+position × the pitch+eye camera-local. Main maps this into the static epoch render frame via
## WorldManager.m5_epoch_camera and writes it back with set_render_camera. Computed from the input state
## (yaw via global_transform, _pitch) NOT from _camera.global (which we override), so there is no feedback loop.
func window_camera_transform() -> Transform3D:
	# COSMOS ORBIT-FRAME (§3.3): in SPACE/RECOVER the displayed camera is the inertial 6DOF pose, not the euler
	# reconstruction — this ONE seam is what makes dev-flight wishes, the SN5b compass, aim and the prewarm all
	# consume the 6DOF attitude with no further edits (§5). Flag off / SURFACE ⇒ the shipped euler transform,
	# byte-identical. The origin is the SAME eye-height offset in both branches (only the basis differs).
	if CubeSphere.ORBIT_ATTITUDE and _att_mode != ATT_SURFACE:
		return Transform3D(_attitude_scene_basis(), global_transform * Vector3(0, eye_height, 0))
	var cam_local := Transform3D(Basis(Vector3(1, 0, 0), _pitch), Vector3(0, eye_height, 0))
	# COSMOS PLAYER-UPVECTOR-FACET-DESYNC FIX §5.3 (FP_CAMERA_RADIAL_LEVEL): mirror the SAME roll `_move`'s tail
	# applies, from the CACHED value (this function has no access to `_move`'s `terrain_floor` local, and must
	# not pay a second floor query on every call — prewarm/dev-look consumers only read the forward axis anyway,
	# which the roll never touches). 0.0 off-flag / non-SURFACE ⇒ the shipped cam_local exactly.
	if CubeSphere.FP_CAMERA_RADIAL_LEVEL and _att_mode == ATT_SURFACE:
		cam_local = Transform3D(cam_local.basis * Basis(Vector3(0, 0, 1), _cam_rl_last_phi), cam_local.origin)
	return global_transform * cam_local

## COSMOS ORBIT-FRAME (§3.2/§3.5): the current DISPLAYED scene (render) basis. SPACE composes R_z(−θ)·Basis(q_bci);
## RECOVER (Phase C) is the eased slerp toward the gravity-aligned surface pose in the CURRENT active facet frame —
## b_active updates across a crossing while the frozen b_start stays scene-constant, so the blend re-references
## automatically (§6.2). θ is read fresh from the f64 nav clock (no basis accumulation ⇒ no f32 drift).
func _attitude_scene_basis() -> Basis:
	var theta := _EphCls.spin_angle(_dominant_body(), _nav_clock)
	if _att_mode == ATT_SPACE:
		return _CosmosAttitudeCls.scene_basis(_att_q, theta)
	# RECOVER: express the frozen scene start in the current facet lattice, slerp to the surface target.
	var b_active := _attitude_active_basis()
	var b_lat_start_q := (b_active.transposed() * _att_recover_b_start).orthonormalized().get_rotation_quaternion()
	return _CosmosAttitudeCls.recover_blend(b_active, b_lat_start_q, _att_recover_yaw, _att_recover_pitch, _att_recover_alpha)

## The active facet's lattice basis in scene coords (b_active), or identity off-facet. Used by the attitude seam.
func _attitude_active_basis() -> Basis:
	var fid := TerrainConfig.active_facet()
	return _FacetAtlasCls.frame_basis(fid) if fid >= 0 else Basis()

## COSMOS ORBIT-FRAME (§3.2) — advance the SURFACE/SPACE/RECOVER machine one physics tick. The trigger is the
## COMMITTED nav mode (PLANETARY ⇔ h < 384±32 with the 2-s dwell — reused so the attitude inherits exactly the
## nav hysteresis and can never flap faster than the HUD). It writes ONLY the camera node's global transform in
## SPACE/RECOVER and hands back the surface euler on landing — it NEVER touches position/velocity (the pilot's
## position mechanics — hover drift, free-fall, dev-flight — compose untouched). Only reached under the flag.
func _attitude_tick(delta: float) -> void:
	var committed_planetary := int(_nav.mode) == _CosmosNavCls.PLANETARY
	var theta := _EphCls.spin_angle(_dominant_body(), _nav_clock)
	match _att_mode:
		ATT_SURFACE:
			# Leave PLANETARY ⇒ go inertial. Seed q_bci from the CURRENT displayed (child-camera) basis so the
			# view does not pop (C0), then emancipate the camera and write the space pose.
			if not committed_planetary:
				_att_q = _CosmosAttitudeCls.seed_bci(_camera.global_transform.basis, theta)
				_att_mode = ATT_SPACE
				_camera.top_level = true
				_write_attitude_camera()
		ATT_SPACE:
			# Q/E roll (held keys — a continuous rate, so polled here not in _unhandled_input). SPACE-FLY: the
			# executor's remote_roll_rate (rad/s) is OR'd in as a rate offset so a scripted `roll` step twists the
			# BCI attitude through the SAME apply_roll a human's Q/E does. Zero in normal play (byte-identical).
			var roll := 0.0
			if Input.is_key_pressed(KEY_Q): roll += 1.0
			if Input.is_key_pressed(KEY_E): roll -= 1.0
			if remote_roll_rate != 0.0 and CubeSphere.ORBIT_ROLL_RATE > 0.0:
				roll += remote_roll_rate / CubeSphere.ORBIT_ROLL_RATE   # express the rad/s seam in apply_roll's ±1 rate units
			if roll != 0.0:
				_att_q = _CosmosAttitudeCls.apply_roll(_att_q, roll, delta, CubeSphere.ORBIT_ROLL_RATE)
			# Return to PLANETARY (or a fast fall reaching the ground inside the dwell) ⇒ recover the surface pose.
			if committed_planetary or _attitude_ground_contact():
				_attitude_leave_space(theta)
			else:
				_write_attitude_camera()
		ATT_RECOVER:
			# Phase C: re-leaving PLANETARY mid-recovery ⇒ re-seed q_bci from the DISPLAYED (blended) basis so the
			# jump back to SPACE is continuous. Otherwise ramp α over ORBIT_T_REC and hand back at α ≥ 1.
			if not committed_planetary:
				_att_q = _CosmosAttitudeCls.seed_bci(_camera.global_transform.basis, theta)
				_att_mode = ATT_SPACE
				_write_attitude_camera()
			else:
				_att_recover_alpha += (delta / CubeSphere.ORBIT_T_REC) if CubeSphere.ORBIT_T_REC > 0.0 else 1.0
				if _att_recover_alpha >= 1.0:
					_attitude_handback(_att_recover_yaw, _att_recover_pitch)
				else:
					_write_attitude_camera()

## Leave SPACE for the surface: derive the gravity-aligned surface (yaw*, pitch*) from the current displayed
## basis. Under ORBIT_LAND_RECOVER (Phase C) begin a smooth slerp (the ATT_RECOVER state); else hand back
## INSTANTLY (Phase A — yaw/pitch continuous, any roll snaps to 0, documented).
func _attitude_leave_space(theta: float) -> void:
	var b_scene := _CosmosAttitudeCls.scene_basis(_att_q, theta)
	var tp := _CosmosAttitudeCls.recover_target(_attitude_active_basis(), b_scene)
	if CubeSphere.ORBIT_LAND_RECOVER:
		_att_recover_b_start = b_scene
		_att_recover_yaw = tp.x
		_att_recover_pitch = tp.y
		_att_recover_alpha = 0.0
		_att_mode = ATT_RECOVER
		_write_attitude_camera()                            # α=0 shows the frozen basis exactly (continuity)
	else:
		_attitude_handback(tp.x, tp.y)

## Hand the surface FPS parametrization back: write rotation.y/_pitch, un-emancipate the camera to its shipped
## child pose, return to SURFACE. The child basis b_active·R_y(yaw)·R_x(pitch) equals the displayed basis at
## α=1, so there is no jump at the hand-back frame (Phase C); Phase A drops any residual roll here.
func _attitude_handback(yaw: float, pitch: float) -> void:
	rotation.y = yaw
	_pitch = clampf(pitch, -1.5, 1.5)
	_camera.top_level = false
	_camera.transform = Transform3D(Basis(Vector3(1, 0, 0), _pitch), Vector3(0, eye_height, 0))
	_att_mode = ATT_SURFACE
	# COSMOS PLAYER-UPVECTOR-FACET-DESYNC FIX §5.2 (FP_CAMERA_RADIAL_LEVEL): a handback can land at high altitude
	# (w≈1) where the roll would otherwise apply up to 2.6° on the very next frame — ease it in instead of
	# popping. This function only ever runs under CubeSphere.ORBIT_ATTITUDE (the sole driver of `_att_mode`
	# leaving ATT_SURFACE), so the write is already naturally gated; harmless (unread) with the roll flag off.
	_cam_rl_ease = 0.0

## Write the emancipated camera's global transform to the current SPACE/RECOVER pose (the M5_REAL top_level
## mechanism). The pose (basis + eye origin) is exactly window_camera_transform() in these modes, so aim + any
## camera-derived wish stay consistent through the one seam.
func _write_attitude_camera() -> void:
	_camera.global_transform = window_camera_transform()

## Ground-contact safety trigger (§3.2): while NOT flying, a fast free-fall can reach the surface inside the 2-s
## nav dwell — recover before the player stands on terrain with a space attitude. Flying (dev-nav) never counts
## (you recover when the nav mode commits PLANETARY, not while actively flying).
func _attitude_ground_contact() -> bool:
	if flying or world == null:
		return false
	# COSMOS-PERF FALL: floor_under() hits a slow path at high altitude (the near field is ALT_REGIME-frozen and
	# not resident, so the analytic floor query regenerates) — measured ~86-175 ms/frame, the ENTIRE fall-fps
	# collapse (t_att_us). Ground contact is physically impossible far above the tallest terrain, so skip the
	# per-frame floor query until the player is within reach of the surface. The threshold sits far above any
	# terrain+datum relief, so the recovery still fires with huge margin on the approach. Byte-identical off.
	# A player-placed TOWER can rise ABOVE this gate (natural terrain maxes ~112 + trees, but a placed tower
	# can reach ~352 > FALL_ATT_GATE_Y). Skipping the floor query then leaves the camera in a space attitude
	# after landing ON the tower. Mirror FP_FLOOR_BOUNDED's `_placed_top` consult: raise the gate by the
	# column's PLACED high-water so the recovery still fires within reach of a tall tower's top. With no
	# placement the column's placed_top is a deep-negative sentinel ⇒ the RHS is hugely negative ⇒ the test
	# collapses to `position.y > FALL_ATT_GATE_Y` (byte-identical to before on natural terrain).
	if CubeSphere.FP_FALL_ATT_GATE and position.y > CubeSphere.FALL_ATT_GATE_Y \
			and position.y > float(world.placed_top(int(floor(position.x)), int(floor(position.z)))) + CubeSphere.FALL_ATT_GATE_Y:
		return false
	return position.y <= world.floor_under(position.x, position.z, position.y, _pos_fid) + 0.05

## COSMOS R2.2: place the DISPLAYED camera at the given (epoch-frame) transform. Physics/aim stay window.
func set_render_camera(t: Transform3D) -> void:
	if _camera != null:
		_camera.global_transform = t

## SPACE-NAV SN3 (docs/COSMOS-SEAMLESS-SCALES-DESIGN.md §5.4): ramp the camera near/far with altitude so the
## climb to orbit stays C0 (no frustum pop) and the far plane always reaches the horizon tangent. h = radial
## altitude, d = |camera − body_centre| (blocks). At h = 0 / d = R these are the shipped 0.05 / 9000. Called
## per frame by main._process under FP_SCALED_BODY only; DEAD (never called) with the flag off.
func apply_scaled_camera_planes(h: float, d: float) -> void:
	if _camera == null:
		return
	var new_far := CosmosScale.camera_far(d, FacetAtlas.R_BLOCKS)
	# COSMOS-PERF FALL-ALTRATE (FP_FALL_CAMFAR_HOLD): off ⇒ the shipped every-frame write (byte-identical).
	if not CubeSphere.FP_FALL_CAMFAR_HOLD:
		_camera.near = CosmosScale.camera_near(h)
		_camera.far = new_far
		return
	# Throttle the ramp during fast vertical motion: derive the radial speed from the last d sample, then hold the
	# last-applied planes unless (a) motion is slow/steady (converge exactly), (b) FALL_THROTTLE_MS has elapsed, or
	# (c) the far plane must GROW (a climb — never hold a far plane smaller than the ring needs, or it clips).
	var now_usec := Time.get_ticks_usec()
	var vspeed := 0.0
	if _camfar_prev_usec >= 0:
		vspeed = FallThrottle.radial_speed(_camfar_prev_d, d, float(now_usec - _camfar_prev_usec) / 1.0e6)
	_camfar_prev_d = d
	_camfar_prev_usec = now_usec
	var now_msec := Time.get_ticks_msec()
	var ms_since := (now_msec - _camfar_apply_msec) if _camfar_apply_msec >= 0 else 0x7fffffff
	var must_grow := new_far > _camera.far + 1.0
	if must_grow or FallThrottle.should_reapply(true, vspeed, ms_since):
		_camera.near = CosmosScale.camera_near(h)
		_camera.far = new_far
		_camfar_apply_msec = now_msec

## COSMOS-ORBITAL-SHELL H-B telemetry: the LIVE camera far plane (blocks). At orbit distance d the far ring's limb
## sits at √(d²−R²) from the camera; if far < that the limb-ward part of the visible disc is CLIPPED (the far side
## reads blank even though the shell emitted it). Read-only; the remote bridge streams it alongside the shell state.
func camera_far() -> float:
	return _camera.far if _camera != null else 0.0

func _unhandled_input(event: InputEvent) -> void:
	if frozen:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# COSMOS ORBIT-FRAME (§3.4): in SPACE the mouse composes CAMERA-LOCAL quaternion increments (yaw + UNLIMITED
		# pitch) on the BCI attitude; in RECOVER it drives the surface recovery target (clamped). Flag off / SURFACE
		# ⇒ the shipped clamped-euler handler BYTE-IDENTICALLY (the machine never leaves SURFACE with the flag off).
		if CubeSphere.ORBIT_ATTITUDE and _att_mode == ATT_SPACE:
			_att_q = _CosmosAttitudeCls.apply_look(_att_q, event.relative.x, event.relative.y, mouse_sensitivity)
		elif CubeSphere.ORBIT_ATTITUDE and _att_mode == ATT_RECOVER:
			# Phase C: during the landing blend the mouse drives the surface recovery TARGET (clamped) so the pilot
			# never loses look control; the slerp target moves continuously, the displayed basis stays C0.
			_att_recover_yaw = wrapf(_att_recover_yaw - event.relative.x * mouse_sensitivity, -PI, PI)
			_att_recover_pitch = clampf(_att_recover_pitch - event.relative.y * mouse_sensitivity, -1.5, 1.5)
		else:
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
					if not flying:
						_foff_radial = true                  # G-LANDING: explicit flight-off = land-commit latch
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
	# G-REENTRY FIX A: restore frame/pose consistency FIRST, before any consumer (movers, floor, nav)
	# reads `position` — a half-committed crossing from LAST frame must never be interpreted this frame.
	_heal_frame_desync()
	# REMOTE-DRIVE (§4.3): snapshot the pre-locomotion LATTICE position so the executor measures pure
	# _move() displacement — uncontaminated by the reanchor/flip/cross corrections that follow. Captured
	# here and forwarded to physics_tick at the END of the frame (once the crossing yaw_delta is known).
	var _pre_move_pos := position
	# FP_FALL_TIMING: time the whole _move (the free-fall coast lives inside it — split out as t_coast_us). Off ⇒
	# the flag test is the only added work (no timer call, no key). See fall_timing().
	var _ft_on := CubeSphere.FP_FALL_TIMING
	var _ft_t := 0
	# DEV/TEST freeze_player: pin the player for a stationary capture by suppressing ONLY the player's own MOTION
	# INTEGRATION (skip _move — gravity, dev-fly drift, orbital coast, locomotion) and zeroing velocity. The REST of
	# the tick still runs — the RemoteControl executor's physics_tick (so look/turn/move/jump ops still send their
	# done record instead of timing out and deadlocking the relay queue), the origin/frame corrections, the
	# streaming/bake kick, and the camera. `position` stays invariant across ticks (nothing else writes it while
	# held). Default off ⇒ the else-branch runs verbatim (byte-identical normal play); set only via remote_freeze_player.
	if _dev_freeze_player:
		velocity = Vector3.ZERO
	elif _settle_active:
		# COSMOS STREAM-SETTLE: while settling after a teleport, SUPPRESS motion integration (no fall) and hold the
		# player at the analytic surface until the near field has meshed their column (or the cap). Consults the
		# world's near-coverage probe each tick. Only ever active after a dev teleport on a coverage-capable world.
		_settle_step(delta, world.near_column_meshed(position))
	else:
		if _ft_on: _ft_t = Time.get_ticks_usec()
		_move(delta)
		if _ft_on: _ft_max("t_move_us", Time.get_ticks_usec() - _ft_t)
	var _tick_move_delta := position - _pre_move_pos
	_tick_move_delta.y = 0.0
	# FP-FIXED-FRAME (§2.3): world queries are LATTICE — the player's canonical pose is its LOCAL transform (== global
	# when the frame is off / at identity). update_streaming feeds the collider/pool/streamer, all lattice consumers.
	if _ft_on: _ft_t = Time.get_ticks_usec()
	world.update_streaming(position)
	if _ft_on: _ft_max("t_stream_us", Time.get_ticks_usec() - _ft_t)
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
	if CubeSphere.FACETED and CubeSphere.FP_TP_FLOOR_WELD and _tp_land_active and _dev_land_guard:
		# COSMOS FALL-THROUGH FIX (FP_TP_FLOOR_WELD): a dev geo-teleport landing is in progress — WELD to the resolved
		# owner facet and SUPPRESS crossings so floor_under / _dev_land_clamp keep reading the owner column and catch the
		# fall at the true surface (never a neighbour's deep seafloor). Re-asserting each frame defeats any actor that
		# tried to flip the active frame on the teleport jump. Dev-only (the latch is set solely by _dev_teleport_geo);
		# gated on the armed guard so the weld can never outlive the landing. Off-flag ⇒ this whole branch is skipped.
		TerrainConfig.set_active_facet(_tp_owner_fid)
		_pos_fid = _tp_owner_fid
	elif CubeSphere.FACETED:
		# COSMOS FALL-THROUGH FIX (FP_DESCENT_FACET_RESYNC): a genuine (non-flying) descent/landing over a FAR region
		# can leave the active facet DESYNCED from the true sub-camera facet — a fast/high flight drifts many facets
		# while adjacent crossings are cooldown/containment-deferred and the high-flyer pool freeze suppresses resync.
		# floor_under / surface_y then read the STALE facet's piecewise-FLAT datum plane, which — extended thousands of
		# blocks past its ridge domain — sinks far below the sphere (measured surface_y ≈ −28 at a far spot with trees),
		# so the fall lands on the deep lie / falls through. When NOT flying (a real fall the floor must catch), resync
		# the active facet onto the true facet_of_dir owner (a direct O(1) redesignation, the _alt_reentry_restore path)
		# BEFORE maybe_cross_facet so the floor this frame is the owner's real surface. NON-ADJACENT desyncs only (the
		# adjacent hysteresis crossing is never fought). Off-flag ⇒ this whole block is skipped ⇒ byte-identical.
		if CubeSphere.FP_DESCENT_FACET_RESYNC and not flying and not _dev_nav:
			var resync := world.resync_subcamera_facet(position)
			if not resync.is_empty():
				apply_reframe(resync["new_pos"], resync["yaw_delta"])
		# FP-FIXED-FRAME (§2.3): own_dist/ridge detection is active-lattice math → pass the LATTICE (local) position.
		# COSMOS UP-VECTOR FACET-DESYNC FIX (FP_UPVECTOR_FACET_HEAL, docs/COSMOS-PLAYER-UPVECTOR-FACET-DESYNC-
		# DESIGN.md §2): hint args for the strip resolver — h_speed from the already-integrated lattice velocity
		# (free), grounded from `_move`'s own landing-clamp capture, additionally gated `not flying and not
		# _dev_nav` (the flying branch never updates `_grounded`, so it could read stale-true otherwise). Unread
		# by `maybe_cross_facet` unless FP_UPVECTOR_FACET_HEAL is on.
		var h_speed := Vector2(velocity.x, velocity.z).length()
		var cross := world.maybe_cross_facet(position, h_speed, _grounded and not flying and not _dev_nav)
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
	# DEV/TEST fall-through guard (dev-instrument tooling): after a dev teleport / freeze-release drop, catch a
	# landing that a stale fast-regime-crossing floor query put BELOW the real surface. Armed ONLY by the dev
	# actuators (which exist only under a live CONTROL_ENABLED grant); `_dev_land_guard` is false in normal play
	# ⇒ this is never entered ⇒ byte-identical. Runs AFTER the origin/frame corrections so `position` + the active
	# facet are final for the frame (surface_y reads the settled facet's column).
	if _dev_land_guard:
		_dev_land_clamp()
	if _ft_on: _ft_t = Time.get_ticks_usec()
	_push_bodies(delta)
	if _ft_on: _ft_max("t_pushbodies_us", Time.get_ticks_usec() - _ft_t)
	if _ft_on: _ft_t = Time.get_ticks_usec()
	_update_aim()
	if _ft_on: _ft_max("t_aim_us", Time.get_ticks_usec() - _ft_t)
	# REMOTE-DRIVE (§4.3): tick the executor AFTER the origin/frame corrections (so the crossing yaw_delta
	# is known) but with the PRE-correction locomotion delta captured at the top. No-op in normal play
	# (remote_exec is null — the executor only exists under a live control grant, flag-gated OFF today).
	if remote_exec != null and is_instance_valid(remote_exec) and remote_exec.has_method("physics_tick"):
		remote_exec.call("physics_tick", delta, _tick_move_delta, _reframe_yaw)
	# COSMOS-ORBITAL-O1O4 O4c: resolve the dominant gravitational body (SOI/facet-driven) BEFORE the nav tick so
	# every "earth"→_dominant_body() consumer this frame reads one consistent value. No-op (not even called) off
	# SOI_SWAP ⇒ _dom_body stays "earth" and the whole feed is byte-identical.
	if CubeSphere.SOI_SWAP:
		_refresh_dominant_body()
	# COSMOS SPACE-NAV SN2: advance the nav-frame machine (gated — `_nav` is null with the flag off, so this
	# is a single null-check per tick and nothing else). It only READS the derived BCI state (§5.4 theorem).
	if _nav != null:
		if _ft_on: _ft_t = Time.get_ticks_usec()
		_nav_tick(delta)
		if _ft_on: _ft_max("t_nav_us", Time.get_ticks_usec() - _ft_t)
	# COSMOS ORBIT-FRAME (§3.2): advance the inertial-attitude machine AFTER the nav tick, so it reads the
	# freshest COMMITTED nav mode + the just-advanced clock. DEAD unless the flag AND the nav machine are live —
	# off-flag the machine never leaves SURFACE, the camera node is never emancipated, so this is byte-identical.
	if CubeSphere.ORBIT_ATTITUDE and _nav != null:
		if _ft_on: _ft_t = Time.get_ticks_usec()
		_attitude_tick(delta)
		if _ft_on: _ft_max("t_att_us", Time.get_ticks_usec() - _ft_t)

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
	# G-REENTRY FIX D (dwell starvation — the corroborated "stuck low_orbit at 160k"): the NavState dwell is
	# UX time ("the raw mode held 2 s") and must accumulate REAL elapsed seconds, not the clamped integrator
	# dt. Under multi-second frames the clamped dt (≤ 1/30 per frame) starves the dwell — ~10 frames in 147 s
	# accrued 0.3 s live, so the raw DEEP_SPACE reclassification never committed. Pass the real frame delta,
	# capped at NAV_DWELL_DT_MAX so one absurd hitch frame cannot single-handedly commit a transient flap.
	# A normal 60-fps frame (raw == 1/60 < 1/30) passes both identically — byte-neutral common case.
	var dwell_dt := minf(delta, _CosmosNavCls.NAV_DWELL_DT_MAX) if delta > 0.0 else 0.0
	delta = _CosmosNavCls.clamp_nav_dt(delta)
	var w: Array = _FacetAtlasCls.lattice_to_world64(fid, position.x, position.y, position.z)
	var p_fix := _DVCls.v(w[0], w[1], w[2])                 # body-fixed (planet-pinned) world position, f64
	_nav_clock += delta * _EphCls.TIME_WARP
	var v_fix := _DVCls.v(0.0, 0.0, 0.0)
	if _nav_have_prev and delta > 0.0:
		# Bounded reciprocal (fd_inv_dt = 1/max(delta, MIN_FD_DT)) so a near-zero delta cannot blow up v_fix.
		v_fix = _DVCls.scale(_DVCls.sub(p_fix, _nav_prev_fix), _CosmosNavCls.fd_inv_dt(delta))
	# COSMOS-ORBITAL-O1O4 O4c: the dominant body drives the spin frame + GM_dyn for the BCI derivation, the nav
	# machine, and the telemetry. _dominant_body() == "earth" off SOI_SWAP ⇒ byte-identical; on the Moon (active
	# facet a Moon fid) it is "moon" ⇒ the whole nav readout is expressed in the Moon's frame with no other change.
	var body := _dominant_body()
	var bci: Array = _OrbitalStateCls.fixed_to_bci(body, _nav_clock, p_fix, v_fix)
	var p_bci: PackedFloat64Array = bci[0]
	# COSMOS SPACE-NAV SN5: when the dev-flight controller drove position THIS frame it OWNS the velocity —
	# use its BCI velocity instead of the finite difference (which would just re-derive it, less precisely).
	# Off dev-flight (SN2-only, or PLANETARY) this is exactly the shipped bci[1] finite-difference path.
	var v_bci: PackedFloat64Array = _dev_v_bci if (_dev_active and _dev_have_v) else bci[1]
	# G-REENTRY FIX B: the finite difference is Δp/dt of whatever position DID — including a discontinuity
	# (crossing abort, injected teleport). Sanitize before ANY consumer (nav machine, telemetry, the
	# _nav_last_v_bci seed the free-fall/dev-flight re-seed from): garbage falls back to the last-good
	# velocity (velocity-continuous), so a position jump can never become adopted motion (the 642074 latch).
	v_bci = _CosmosNavCls.sane_v(v_bci, _nav_last_v_bci)
	_nav.tick(body, p_bci, v_bci, _nav_clock, dwell_dt)     # FIX D: dwell advances by REAL (capped) frame time
	_nav_prev_fix = p_fix
	_nav_have_prev = true
	_nav_last_v_bci = v_bci                                  # seed for the next orbital dev-flight handoff (SN5)
	_dev_p_bci = p_bci                                       # stash for the O/G key handlers (SN5b)
	_nav_tele = _CosmosNavCls.telemetry(_nav, body, p_bci, v_bci, _nav_clock)
	# SN5b: refresh the compass strip from the camera forward re-expressed in BCI (spin axis = BCI +Z).
	if _dev_overlay != null and _dev_overlay.is_built():
		var rmag := _DVCls.length(p_bci)
		if rmag > 0.0:
			var rhat := _DVCls.scale(p_bci, 1.0 / rmag)
			var fwd := _dev_dir_to_bci(fid, _nav_clock, -window_camera_transform().basis.z)
			var heading := _DevNavOverlayCls.compass_heading(_DVCls.v(0.0, 0.0, 1.0), rhat, fwd)
			_dev_overlay.update_hud(heading, _CosmosNavCls.NAV_NAMES[int(_nav.mode)])
		# FP_DEVNAV_GUIDE_FRAME: ride the guide root on the planet's live render placement (floating-origin +
		# scaled-body) so the axis/equator/facet-border guides sit ON the rendered planet, not the world origin.
		if CubeSphere.FP_DEVNAV_GUIDE_FRAME and world != null and _dev_overlay.has_method("set_guides_transform"):
			_dev_overlay.set_guides_transform(world.planet_render_transform())

## COSMOS SPACE-NAV SN2: the additive nav telemetry (nav_mode/frame_v/|v_bci|/nav_frame) for the RemoteBridge.
## Empty dict when the machine is off (flag-off) ⇒ the guarded bridge merge adds nothing (byte-identical).
## FP_FALLTHRU_PROBE (§4) additively merges its own incident record on top when one is live — `_fallthru_tele`
## is empty (the common/flag-off case), so this is a single `is_empty()` check + the shipped return.
func nav_telemetry() -> Dictionary:
	if _fallthru_tele.is_empty():
		return _nav_tele
	return _nav_tele.merged(_fallthru_tele)

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

## CLIMATE W3 (cloudfix): the camera position in the ACTIVE FACET's LATTICE frame (local coords) — the frame
## the weather grid indexes by (PerVoxelEnvironment._dir_of_pos folds the lattice column via FacetAtlas.cell_dir).
## The player rides the ActiveFrame so its LOCAL transform IS the lattice pose; the camera sits eye_height up the
## local +Y. WeatherFX samples precip/humidity/convection here while placing the FX geometry in scene space.
func camera_lattice_origin() -> Vector3:
	return Vector3(position.x, position.y + eye_height, position.z)

## SN-FIX #1b (SN_HUD_NAV, 2026-07-18 live-pilot request): the player's current speed in blocks/s for the HUD.
## Prefers the nav machine's body-centred-inertial |v_bci| (`_nav_tele`, the same value the RemoteBridge streams),
## and falls back to the CharacterBody3D lattice speed when the nav machine is off (SN_NAV_MODES false ⇒ empty
## `_nav_tele`). Pure read; no state.
func nav_speed_bci() -> float:
	# G-LANDING HUD FIX (2026-07-20 live pilot: a LANDED player read "spd 14.5" forever — the ω×r spin carrier,
	# because raw |v_bci| never reads 0 on a rotating planet). Prefer the MODE-appropriate frame speed the nav
	# machine already computes (`frame_v` = CosmosNav.hud_velocity): PLANETARY ⇒ surface (body-fixed) speed —
	# carrier-subtracted, 0 when standing; LOW/HIGH ⇒ |v_bci| exactly as before; DEEP ⇒ heliocentric. Falls back
	# to |v_bci| then the lattice speed when the machine is off. HUD-only (the RemoteBridge telemetry keeps BOTH
	# frame_v and v_bci fields unchanged).
	if _nav_tele.has("frame_v"):
		return float(_nav_tele["frame_v"])
	if _nav_tele.has("v_bci"):
		return float(_nav_tele["v_bci"])
	return velocity.length()

## SN-FIX #1b (SN_HUD_NAV): the LOCAL circular-orbit speed reference v_circ = √(GM_dyn/r) at the player's current
## radius r = R_BLOCKS + radial_altitude() — so the pilot can read how close their speed is to a stable orbit
## (≈260 b/s at the surface). Reads GM_dyn (SPACE-NAV §3, the local-dynamics scale — NOT the sky's GM_game) for the
## home body. Pure math; 0 at/below the centre. Cheap (one sqrt).
func orbit_v_circ() -> float:
	var r := _FacetAtlasCls.R_BLOCKS + radial_altitude()
	if r <= 0.0:
		return 0.0
	return sqrt(CosmosGravity.gm_dyn(_dominant_body()) / r)

## COSMOS-ORBITAL-O1O4 O4c (§3.5 / SPACE-NAV §8) — THE dominant-body accessor. Returns the body whose local
## dynamics (spin frame via CosmosEphemeris, GM_dyn/gravity via CosmosGravity, drag/re-entry via OrbitalState,
## and the terrain the player walks) every generalized call site reads. With CubeSphere.SOI_SWAP OFF it returns
## "earth" UNCONDITIONALLY — so all the "earth"→_dominant_body() plumbing below is BYTE-IDENTICAL to the shipped
## literals (the G-O4C-OFF keystone). Under the flag it returns `_dom_body`, refreshed each tick by
## _refresh_dominant_body() (active-facet body on the surface; SOI-tested during a coast). Cheap (a field read).
func _dominant_body() -> String:
	return _dom_body if CubeSphere.SOI_SWAP else "earth"

## COSMOS-ORBITAL-O1O4 O4c — update `_dom_body` for THIS tick (called before _nav_tick under SOI_SWAP). Two
## sources, by regime:
##   • COASTING (a real orbit, `_orbit_coast_move` owns the carried BCI position): the coast performs the SOI
##     test + swap re-expression itself (it must re-express `_coast_p/v_bci`), so this is a NO-OP for it.
##   • SURFACE / WALK / LAND (on an active facet): the facet's body IS the dominant body — a Moon fid ⇒ "moon".
##     A change (Earth↔Moon) re-applies the per-body walk feel (gravity/jump). This is what makes standing/
##     walking/landing on the Moon read Moon gravity + Moon terrain with no other call-site change.
## No-op off SOI_SWAP (never called). Pure bookkeeping — never touches pos/vel.
func _refresh_dominant_body() -> void:
	if _orbit_coasting and _coast_p_bci.size() == 3:
		return                                              # the coast owns the swap (see _orbit_coast_move)
	var fid := TerrainConfig.active_facet()
	if fid < 0:
		return
	var fb := _FacetAtlasCls.body_name_of_fid(fid)
	if fb != _dom_body:
		_dom_body = fb
		_apply_body_feel(fb)

## COSMOS-ORBITAL-O1O4 O4c / SPACE-NAV §8.4 — apply `body`'s walking feel gravity. gravity = the shipped Earth
## baseline scaled by the real surface-gravity ratio (CosmosGravity.feel_g); jump_velocity scaled by its √ so
## JUMP HEIGHT (h = v²/2g) is preserved while HANG TIME lengthens ~1/√g — the Moon's ×2.5 float out of the box.
## Earth ⇒ ratio 1 ⇒ exactly the _ready values (a no-op, so an Earth→Earth "change" never perturbs feel). The
## analytic floor/wall/ceiling queries need NO change: "down" is −Y in the lattice on every body (§3.3 theorem).
func _apply_body_feel(body: String) -> void:
	var g_earth := CosmosGravity.feel_g("earth")
	if g_earth <= 0.0:
		return
	var ratio := CosmosGravity.feel_g(body) / g_earth
	gravity = _feel_earth_g * ratio
	jump_velocity = _feel_earth_jump * sqrt(ratio)

## COSMOS SPACE-NAV SN5 (§7.1): F toggled dev-nav. Dev-nav rides `flying` (noclip): entering disables the
## capsule (the shipped fly escape-hatch semantics), leaving re-enables it. The controller's velocity seed is
## dropped so the first orbital tick re-seeds from the live SN2 velocity. Only reachable under SN_DEVNAV.
func _toggle_dev_nav() -> void:
	_dev_nav = not _dev_nav
	flying = _dev_nav
	velocity = Vector3.ZERO
	if not _dev_nav:
		_foff_radial = true                                  # G-LANDING: explicit flight-off = land-commit latch
	_dev_have_v = false
	_dev_active = false
	_dev_orbital_commit = false                              # SN-FIX #3: entering/leaving dev-nav is never mid-orbit
	_orbit_coasting = false                                  # ORBIT_COAST (§7.4): toggling dev-nav ends any free-coast
	_coast_p_bci = PackedFloat64Array()                      # SN-ODECAY: drop the carried BCI pos (re-entry re-seeds)
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

## SN-FIX (2026-07-18 live-pilot FIX-B, SN_NO_CEILING_BOUNCE) — the LATTICE-frame hover drift for the kinematic
## fly (the "detach from the planet spin" fix). Lifts the lattice pose to the body-fixed world (lattice_to_world64),
## asks the nav kernel for the body-fixed hover drift (0 in PLANETARY; −ω⃗×p_fix in LOW_ORBIT+ — CosmosNav.
## hover_drift_fixed), then rotates that world velocity back into the lattice frame (frame_basis is orthonormal ⇒
## inverse == transpose, the same rotation world_to_lattice64 applies to positions). Result: a LATTICE velocity
## that, added each tick, makes a zero-input hover hold the nav-frame rest — surface-following in the atmosphere,
## inertial (surface spins beneath) in orbit. Pure + fid-parameterised so the gate drives it with no live scene.
## Off-facet (fid < 0) ⇒ zero (no body-fixed reference — the caller is already in its off-facet fallback anyway).
static func hover_drift_lattice(fid: int, mode: int, pos: Vector3) -> Vector3:
	if fid < 0:
		return Vector3.ZERO
	var w: Array = _FacetAtlasCls.lattice_to_world64(fid, pos.x, pos.y, pos.z)
	# O4c: this is a STATIC (gate-driven) helper, so the body comes from the facet, not the instance accessor —
	# the facet's body IS the dominant body when hovering over it. Gated so off SOI_SWAP it is exactly "earth"
	# (a Moon fid only exists under MULTI_BODY, which SOI_SWAP requires) — byte-identical to the shipped literal.
	var body := _FacetAtlasCls.body_name_of_fid(fid) if CubeSphere.SOI_SWAP else "earth"
	var drift_fix := _CosmosNavCls.hover_drift_fixed(mode, body, _DVCls.v(w[0], w[1], w[2]))
	return _FacetAtlasCls.frame_basis(fid).transposed() * Vector3(drift_fix[0], drift_fix[1], drift_fix[2])

## SN-FIX #3 (SN_NO_CEILING_BOUNCE) — the F-MODE kinematic fly: gravity-off, full 6-DOF in the FULL look
## direction (camera basis incl. pitch), constant speed at ALL altitudes. Forward (input.z=−1) maps to the
## camera look (−cam.z, pitched); Space/Ctrl add the camera up axis. The camera basis is in the lattice/window
## orientation, so the resulting direction is a LATTICE direction (position is lattice). No velocity state that
## gravity could act on ⇒ crossing the atmosphere ceiling never decelerates the climb.
func _kinematic_look_fly(delta: float, input: Vector3, running: bool) -> void:
	var speed := fly_speed * (2.0 if running else 1.0)
	var vy := 0.0
	if remote_drive:
		vy = input.y
	else:
		if Input.is_key_pressed(KEY_SPACE): vy += 1.0
		if Input.is_key_pressed(KEY_CTRL): vy -= 1.0
	# COSMOS ORBIT-FRAME Phase B (§5(a)): in SPACE (or the RECOVER blend) fly the FULL inertial camera basis
	# re-expressed in the active facet lattice, with Space/Ctrl on CAMERA-local ±Y (microgravity has no world
	# vertical). The nav-frame carrier drift composes UNCHANGED (a zero-input hover still holds the BCI rest).
	# Flag off / SURFACE ⇒ the shipped body-yaw+pitch construction below, byte-identical.
	if CubeSphere.ORBIT_6DOF_FLY and _att_mode != ATT_SURFACE:
		var afid := TerrainConfig.active_facet()
		if afid >= 0:
			var b_lat_cam := _CosmosAttitudeCls.lat_cam_basis(_FacetAtlasCls.frame_basis(afid), _attitude_scene_basis())
			var dir6 := b_lat_cam * Vector3(input.x, vy, input.z)   # forward = look, strafe = camera X, vy = camera Y
			if dir6.length() > 0.0:
				dir6 = dir6.normalized()
			var carrier6 := hover_drift_lattice(afid, int(_nav.mode), position) if _nav != null else Vector3.ZERO
			position += (dir6 * speed + carrier6) * delta
			_horiz_vel = Vector3(dir6.x, 0.0, dir6.z) * speed
			velocity = Vector3.ZERO
			return
	# FP-FIXED-FRAME: `position` is a LATTICE pose, so the fly direction MUST be a LATTICE direction. The player
	# body's `transform.basis` is the local (lattice) YAW basis; the camera PITCH (_pitch about local X) adds the
	# look-up/down component → forward flies where you look. Space/Ctrl (vy) are straight LATTICE up/down.
	# (The prior code used window_camera_transform() = GLOBAL basis on a lattice position, so the facet's world
	# tilt scrambled the axes — Space went sideways/underground. transform.basis keeps it all in-frame.)
	var look_local := Basis(Vector3(1, 0, 0), _pitch) * Vector3(input.x, 0.0, input.z)   # strafe + forward(incl pitch)
	var dir := transform.basis * look_local + Vector3(0.0, vy, 0.0)
	if dir.length() > 0.0:
		dir = dir.normalized()
	# SN-FIX (2026-07-18 live-pilot FIX-B): the nav-frame carrier drift about the CURRENT hover point, integrated
	# ON TOP of the look-fly input velocity. In PLANETARY it is zero (the lattice hover already tracks the spinning
	# surface — fly over the ground, unchanged). In LOW_ORBIT+ it is −ω⃗×p in the lattice, so a zero-input hover
	# holds a BCI-inertial point and the body-fixed surface rotates beneath at the spin rate — the pilot "observes
	# from a steady point how the planet is spinning". A velocity (no position jump), so crossing the LOW_ORBIT
	# boundary (nav hysteresis at 384) is a seamless frame detach, not a teleport. `_nav != null` always holds here.
	var carrier := hover_drift_lattice(TerrainConfig.active_facet(), int(_nav.mode), position) if _nav != null else Vector3.ZERO
	position += (dir * speed + carrier) * delta
	_horiz_vel = Vector3(dir.x, 0.0, dir.z) * speed
	velocity = Vector3.ZERO

## SN-FIX #3 (SN_NO_CEILING_BOUNCE) — the F-OFF gravity regime, factored for the gate. Free-fall (planet-centred
## GM_dyn/r² frame) applies iff the flag is on, we are NOT flying, and the radial altitude is at/above the
## atmosphere ceiling. Below the ceiling ⇒ false ⇒ the shipped surface-feel walk gravity/frame. Pure.
static func free_fall_regime(is_flying: bool, alt: float, no_ceiling_bounce: bool) -> bool:
	return no_ceiling_bounce and not is_flying and alt >= CubeSphere.ATMO_TOP

## SN-FIX #3 — the flight→fall velocity seed (continuity): the free-fall starts from the last SN2 finite-difference
## BCI velocity so there is NO jump at F-off. A missing/short vector rests (zero). Pure.
## G-REENTRY FIX B (belt+suspenders on top of the _nav_tick sanitizer): a garbage seed (NaN or beyond
## CosmosNav.FD_SPEED_MAX — the finite-difference of a position teleport) rests instead of being adopted,
## so the free-fall can never launch the player on a discontinuity artifact (the live 642074 escape latch).
static func fall_seed(last_v_bci: PackedFloat64Array) -> PackedFloat64Array:
	if last_v_bci.size() == 3 and _CosmosNavCls.v_is_sane(last_v_bci):
		return PackedFloat64Array([last_v_bci[0], last_v_bci[1], last_v_bci[2]])
	return PackedFloat64Array([0.0, 0.0, 0.0])

## G-LANDING (SN_FOFF_RADIAL_FALL) — the RADIAL projection of a fall seed: v_radial = (v·r̂)·r̂ with r̂ = p/|p|
## (BCI). Applied ONLY when the pilot EXPLICITLY toggles flight off (the `_foff_radial` latch): quitting flight
## commits to a fall toward the planet centre — the tangential/orbital component is dropped so the descent
## lands instead of coasting sideways for minutes ("gravity not properly reinstantiated" live report). Both
## radial signs are preserved (an upward component still decelerates under gravity — no impulse toward the
## planet is injected, only the sideways coast is removed). Degenerate p ⇒ the seed unchanged. Pure static.
static func fall_seed_radial(seed: PackedFloat64Array, p_bci: PackedFloat64Array) -> PackedFloat64Array:
	if seed.size() != 3 or p_bci.size() != 3:
		return seed
	var r := _DVCls.length(p_bci)
	if r <= 0.0:
		return seed
	var rhat := _DVCls.scale(p_bci, 1.0 / r)
	return _DVCls.scale(rhat, _DVCls.dot(seed, rhat))

## SN-FIX #3 — one free-fall tick: integrate the planet-centred point-mass gravity (GM_dyn/r², velocity-Verlet
## via OrbitalState) in the BCI frame and re-project to the lattice `position`. Seeded on entry from the last
## flight velocity (continuous). NO surface-rotation drag (BCI is inertial). Off-facet ⇒ a straight-down lattice
## fallback so the player is never stranded. LIVE-ONLY: the feel of the fall; the gravity math is G-SN-FALLGRAV.
func _free_fall_move(delta: float) -> void:
	# COSMOS-PERF FALL-COLLAPSE FIX B (FP_COAST_FULL_DT): cover the FULL real frame delta with N uniform substeps of
	# ≤ MAX_NAV_DT each (anti time-dilation) instead of clamping-and-dropping. Off ⇒ N=1 substep of clamp_nav_dt(delta)
	# — byte-identical to the shipped G-SN-NOSPIRAL clamp-and-drop. The one-time seed below runs ONCE, not per substep.
	var _fd_full := CubeSphere.FP_COAST_FULL_DT
	var _fd_n := _CosmosNavCls.coast_substep_count(delta) if _fd_full else 1
	var _fd_h := _CosmosNavCls.coast_substep_dt(delta) if _fd_full else _CosmosNavCls.clamp_nav_dt(delta)
	var fid := TerrainConfig.active_facet()
	if fid < 0:
		# Off-facet safety: fall straight down in the lattice (never strand the player above a retired facet). Do
		# NOT set _fall_have_v here — leaving it false keeps _fall_v_bci unseeded so a later on-facet tick seeds it
		# cleanly (from _nav_last_v_bci) instead of feeding an empty array to OrbitalState.make.
		for _si in _fd_n:
			velocity.y -= gravity * _fd_h
			position.y += velocity.y * _fd_h
		return
	if not _fall_have_v:
		_fall_v_bci = fall_seed(_nav_last_v_bci)             # seamless seed from the flight velocity
		# G-LANDING (SN_FOFF_RADIAL_FALL): the pilot EXPLICITLY quit flight (F latch) ⇒ commit to landing —
		# keep only the radial component so the fall goes DOWN, not into a sideways coast. Automatic regime
		# entries never set the latch ⇒ their seed stays fully continuous (SN-R1). Flag off ⇒ latch unread.
		if CubeSphere.SN_FOFF_RADIAL_FALL and _foff_radial:
			var wsd: Array = _FacetAtlasCls.lattice_to_world64(fid, position.x, position.y, position.z)
			var psd: PackedFloat64Array = _OrbitalStateCls.fixed_to_bci(_dominant_body(), _nav_clock,
				_DVCls.v(wsd[0], wsd[1], wsd[2]), _DVCls.v(0.0, 0.0, 0.0))[0]
			_fall_v_bci = fall_seed_radial(_fall_v_bci, psd)
		_foff_radial = false
		_fall_have_v = true
		# FP_FREEFALL_RAILS: clear the carried BCI fall position so the closed-form coast re-seeds it ONCE from the
		# current lattice pose on this fresh fall entry (the carried [p,v] must not leak across separate falls). Only
		# touched under the flag ⇒ the shipped Verlet path (which never reads _fall_p_bci) is byte-identical.
		if CubeSphere.FP_FREEFALL_RAILS:
			_fall_p_bci = PackedFloat64Array()
	# COSMOS-PERF FALL-COLLAPSE FIX (FP_FREEFALL_RAILS): the CLOSED-FORM (RAILS) free-fall coast — carry the BCI [p,v]
	# and advance it by ONE universal-variable two-body step over the whole real frame delta (O(1)/frame, ZERO Verlet
	# substeps, no time-dilation, exact). This is THE fall-collapse fix (the Verlet substep loops below are the spiral).
	# Off ⇒ the shipped FP_COAST_BATCH / per-substep Verlet chain verbatim (byte-identical). Takes precedence when on.
	# FP_FALL_TIMING: time the coast integrator (t_coast_us) + count the substeps (n_coast_calls — a runaway inner
	# loop would show here). t_move_us − t_coast_us = the rest of _move. Off ⇒ the flag test only (byte-identical).
	var _ft_on := CubeSphere.FP_FALL_TIMING
	var _ft_t := 0
	if _ft_on: _ft_t = Time.get_ticks_usec()
	var _n_coast := 0
	if CubeSphere.FP_FREEFALL_RAILS:
		_coast_freefall_rails(delta, _dominant_body())
		_n_coast = 1
	# COSMOS-PERF FALL-COLLAPSE FIX (FP_COAST_BATCH): batch the N substeps into ONE lattice↔BCI re-projection + N cheap
	# BCI steps (vs N per-substep re-projections + N allocations — the live ~150 ms/frame fall collapse). Off ⇒ the
	# shipped per-substep chain verbatim (byte-identical). N=1 (FP_COAST_FULL_DT off) makes both paths identical.
	elif CubeSphere.FP_COAST_BATCH:
		_fall_v_bci = _coast_batch(_fd_h, _fd_n, _fall_v_bci, _dominant_body())
		_n_coast = _fd_n
	else:
		for _si in _fd_n:
			_fall_v_bci = _coast_step(_fd_h, _fall_v_bci, _dominant_body())   # shared Kepler coast under the dominant body (O4c: Moon-aware)
		_n_coast = _fd_n
	if _ft_on:
		_ft_max("t_coast_us", Time.get_ticks_usec() - _ft_t)
		_ft_max("n_coast_calls", _n_coast)
	velocity = Vector3.ZERO                                  # velocity.y is re-seeded on the surface handoff

## COSMOS SPACE-NAV §7.4 (ORBIT_COAST) + SN-FIX #3 (free-fall) — the SHARED Kepler coast integrator. ONE tick of
## planet-centred point-mass gravity (GM_dyn/r² via OrbitalState velocity-Verlet, substep-capped) in the BCI frame
## from the seed velocity `v_bci`, re-projecting the new BCI position back to the lattice `position`, and RETURNING
## the new BCI velocity. Pure free coast (no thrust/drag). PRECONDITION: on an active facet (fid >= 0 — the caller
## handles the off-facet fallback). This is the ONE code path both the free-fall (seeded straight-down) and the O
## orbit (seeded tangential) share — gravity alone decides straight fall vs stable orbit vs ellipse/escape.
func _coast_step(delta: float, v_bci: PackedFloat64Array, body: String) -> PackedFloat64Array:
	var fid := TerrainConfig.active_facet()
	var t := _nav_clock
	var w: Array = _FacetAtlasCls.lattice_to_world64(fid, position.x, position.y, position.z)
	var p_fix := _DVCls.v(w[0], w[1], w[2])
	var p_bci: PackedFloat64Array = _OrbitalStateCls.fixed_to_bci(body, t, p_fix, _DVCls.v(0.0, 0.0, 0.0))[0]
	var os = _OrbitalStateCls.make(body, p_bci, v_bci)
	os.step(delta, _DVCls.v(0.0, 0.0, 0.0))                 # pure free coast (no thrust/drag)
	# G-REENTRY FIX C: never adopt a broken/unbounded integration — NaN reverts to the pre-step state and a
	# radius beyond the body's SOI clamps onto it (outward radial velocity stripped). The player can then
	# never ride this path to garbage altitudes where per-frame work explodes (the live 27 s frames at 35·R).
	var safe := _CosmosNavCls.clamp_bci_state(os.pos, os.vel, p_bci, v_bci, _CosmosNavCls.soi_radius(body))
	var pf_new: PackedFloat64Array = _OrbitalStateCls.bci_to_fixed(body, t, safe[0], safe[1])[0]
	var lat: Array = _FacetAtlasCls.world_to_lattice64(fid, pf_new[0], pf_new[1], pf_new[2])
	position = Vector3(lat[0], lat[1], lat[2])
	return safe[1]

## COSMOS-PERF FALL-COLLAPSE FIX (FP_COAST_BATCH) — the BATCHED free-fall coast: the whole substep batch behind ONE
## lattice↔BCI re-projection. Structurally the N-substep `_coast_step` loop with the lattice_to_world64/fixed_to_bci
## pulled out ABOVE the loop and bci_to_fixed/world_to_lattice64 pulled out BELOW it, so the N cheap BCI Verlet steps
## (CosmosNav.coast_batch_bci — reuses ONE OrbitalState, clamps per step) run with NO lattice work and ONE allocation
## regardless of N. Numerically equal to the per-substep chain within the f32 `position` round-trip the batch removes
## (strictly more accurate). ONE lattice_to_world64 + ONE world_to_lattice64 + ONE OrbitalState.make per call — the
## perf invariant the gate G-COAST-BATCH asserts by mirroring this exact structure and counting the conversions/makes.
func _coast_batch(delta: float, n: int, v_bci: PackedFloat64Array, body: String) -> PackedFloat64Array:
	var fid := TerrainConfig.active_facet()
	var t := _nav_clock
	var w: Array = _FacetAtlasCls.lattice_to_world64(fid, position.x, position.y, position.z)   # ONE lattice→world
	var p_bci: PackedFloat64Array = _OrbitalStateCls.fixed_to_bci(body, t, _DVCls.v(w[0], w[1], w[2]), _DVCls.v(0.0, 0.0, 0.0))[0]   # ONE world→BCI
	var out := _CosmosNavCls.coast_batch_bci(body, p_bci, v_bci, delta, n, _CosmosNavCls.soi_radius(body))   # N cheap BCI steps, ONE make
	var pf_new: PackedFloat64Array = _OrbitalStateCls.bci_to_fixed(body, t, out[0], out[1])[0]   # ONE BCI→world
	var lat: Array = _FacetAtlasCls.world_to_lattice64(fid, pf_new[0], pf_new[1], pf_new[2])   # ONE world→lattice
	position = Vector3(lat[0], lat[1], lat[2])
	return out[1]

## COSMOS-PERF FALL-COLLAPSE FIX (FP_FREEFALL_RAILS) — the CLOSED-FORM (RAILS) free-fall coast. Carries the BCI
## fall [p,v] in f64 across frames (like the orbit coast's `_coast_p_bci`/`_coast_v_bci`) and advances it by ONE
## universal-variable two-body step over the WHOLE real frame delta (CosmosNav.coast_kepler_bci → propagate_uv):
## O(1) per frame — NO OUTER coast-substep loop, NO INNER Verlet substeps (those dt-scaled loops are the ~5 fps
## fall-collapse spiral), no time-dilation, and exact for the two-body problem. The universal-variable form is
## robust on the RADIAL (h≈0) fall a classical Kepler-element propagation is singular on. Structurally the orbit
## coast's `_coast_batch_kepler`, but with the closed-form step in place of the N-Verlet batch: ZERO
## lattice_to_world64 in steady state (carries [p,v]; seeds `_fall_p_bci` from the lattice ONCE per fall) + ONE
## world_to_lattice64 for the display/stream/collision `position` + ONE propagate_uv, regardless of frame dt.
## Precondition: on an active facet (fid >= 0 — the caller handles the off-facet fallback). Gate G-FREEFALL-RAILS.
func _coast_freefall_rails(delta: float, body: String) -> void:
	var fid := TerrainConfig.active_facet()
	var t := _nav_clock
	# Seed the carried BCI fall position ONCE from the current lattice pose (cleared on each fresh fall entry). This
	# is the ONLY lattice_to_world64 the closed-form fall does, and only on the first frame of a fall.
	if _fall_p_bci.size() != 3:
		var w0: Array = _FacetAtlasCls.lattice_to_world64(fid, position.x, position.y, position.z)
		_fall_p_bci = _OrbitalStateCls.fixed_to_bci(body, t, _DVCls.v(w0[0], w0[1], w0[2]), _DVCls.v(0.0, 0.0, 0.0))[0]
	# ONE closed-form universal-variable step over the whole (catch-up-capped) real delta — O(1), no substeps. The
	# clamp_bci_state NaN/SOI guard (once per frame — identical safety to the Verlet coast) is folded into coast_kepler_bci.
	var out := _CosmosNavCls.coast_kepler_bci(body, _fall_p_bci, _fall_v_bci, delta, _CosmosNavCls.soi_radius(body))
	_fall_p_bci = out[0]
	_fall_v_bci = out[1]
	# ONE BCI→lattice re-projection for rendering / streaming / collision (display only — never read back).
	var pf_new: PackedFloat64Array = _OrbitalStateCls.bci_to_fixed(body, t, _fall_p_bci, _fall_v_bci)[0]
	var lat: Array = _FacetAtlasCls.world_to_lattice64(fid, pf_new[0], pf_new[1], pf_new[2])
	position = Vector3(lat[0], lat[1], lat[2])

## COSMOS SPACE-NAV §7.4 (ORBIT_COAST) — one physics tick of the O free-coast: integrate the shared Kepler coast
## from `_coast_v_bci` (seeded tangential by the O toggle) and write the lattice `position`. A stable circular seed
## HOLDS radius; an off-circular seed evolves into an ellipse / decay / escape. The coast mirrors its BCI velocity
## into `_dev_v_bci` (and marks `_dev_active`) so the nav machine classifies on the true orbital velocity and any
## later exit to the dev-flight controller is velocity-continuous. Off-facet ⇒ hold (never strand). LIVE-ONLY: the
## feel of orbiting; the orbit math (holds radius / ellipse / escape) is G-OCOAST.
func _orbit_coast_move(delta: float) -> void:
	# COSMOS-PERF FALL-COLLAPSE FIX B (FP_COAST_FULL_DT): integrate the FULL real frame delta in N ≤ MAX_NAV_DT substeps
	# (anti time-dilation). Off ⇒ N=1 substep of clamp_nav_dt(delta) — byte-identical to the shipped clamp-and-drop.
	# The SOI-swap test + station-keeping bookkeeping below run ONCE per frame (over the final carried state); the
	# station-keeping cooldown decrements by the REAL integrated span (`_fd_h * _fd_n`, == clamp_nav_dt(delta) off).
	var _fd_full := CubeSphere.FP_COAST_FULL_DT
	var _fd_n := _CosmosNavCls.coast_substep_count(delta) if _fd_full else 1
	var _fd_h := _CosmosNavCls.coast_substep_dt(delta) if _fd_full else _CosmosNavCls.clamp_nav_dt(delta)
	var fid := TerrainConfig.active_facet()
	if fid < 0:
		velocity = Vector3.ZERO
		return
	# SN-ODECAY FIX: integrate the CARRIED f64 BCI [p,v] (no per-tick f32 position read-back — the eccentricity
	# pump). Defensive seed: if `_coast_p_bci` is unseeded (the O handler seeds it from `_dev_p_bci`), reconstruct
	# it ONCE from the current lattice `position` (the pre-fix first-tick value).
	if _coast_p_bci.size() != 3:
		var w0: Array = _FacetAtlasCls.lattice_to_world64(fid, position.x, position.y, position.z)
		_coast_p_bci = _OrbitalStateCls.fixed_to_bci(_dominant_body(), _nav_clock, _DVCls.v(w0[0], w0[1], w0[2]), _DVCls.v(0.0, 0.0, 0.0))[0]
	# COSMOS-PERF FALL-COLLAPSE FIX (FP_COAST_BATCH): batch the N substeps into ONE re-projection + N cheap BCI steps
	# (vs N per-substep re-projections + N allocations). The carried [p,v] path is BIT-identical batched (never reads
	# `position` back). Off ⇒ the shipped per-substep loop verbatim (byte-identical); N=1 makes both paths identical.
	if CubeSphere.FP_COAST_BATCH:
		var out := _coast_batch_kepler(_fd_h, _fd_n, _coast_p_bci, _coast_v_bci, _dominant_body())
		_coast_p_bci = out[0]
		_coast_v_bci = out[1]
	else:
		for _si in _fd_n:
			var out := _coast_step_kepler(_fd_h, _coast_p_bci, _coast_v_bci, _dominant_body())
			_coast_p_bci = out[0]
			_coast_v_bci = out[1]
	# COSMOS-ORBITAL-O1O4 O4c (§3.5) — the SOI dominant-body SWAP. After the integration tick, test whether the
	# carried BCI point (in the current body's frame) has crossed a sphere-of-influence boundary; if the deepest
	# SOI now belongs to a different body, RE-EXPRESS the carried [p,v] into that body's BCI frame (an exact,
	# physics-preserving translation through the heliocentric frame — OrbitalState.reexpress_soi) and adopt it.
	# ±SOI_HYST guards against boundary flapping. Physics is untouched (the player's real motion is identical);
	# only the origin the next tick integrates from — and the walk/land feel — change. No-op off SOI_SWAP.
	# LIVE-ONLY residue: the lattice `position` re-projection + landing-facet migration across the 384 k-block
	# transfer is a real fly, not headless-provable — the swap STATE math here is what G-SOI-SWAP proves.
	if CubeSphere.SOI_SWAP:
		var newb := _CosmosNavCls.soi_dominant(_dom_body, _coast_p_bci, _nav_clock, CubeSphere.SOI_HYST)
		if newb != _dom_body:
			var re := _OrbitalStateCls.reexpress_soi(_dom_body, newb, _nav_clock, _coast_p_bci, _coast_v_bci)
			_coast_p_bci = re[0]
			_coast_v_bci = re[1]
			_dom_body = newb
			_apply_body_feel(newb)
	# SN-ODECAY station-keeping (DEV assist): when the orbit nears the atmosphere, periodically add a small prograde
	# Δv so it re-lifts instead of decaying in. Self-limiting (caps at circular speed) ⇒ never boosts to escape.
	# FIX B: decrement by the REAL integrated span this frame (== clamp_nav_dt(delta) with the flag off — byte-identical).
	_coast_boost_cd -= _fd_h * float(_fd_n)
	if _coast_boost_cd <= 0.0:
		var dv := _DevFlightCls.station_keep_dv(_dominant_body(), _coast_p_bci, _coast_v_bci)
		if _DVCls.length(dv) > 0.0:
			_coast_v_bci = _DVCls.add(_coast_v_bci, dv)
			_coast_boost_cd = _DevFlightCls.STATION_KEEP_COOLDOWN
	_dev_v_bci = PackedFloat64Array([_coast_v_bci[0], _coast_v_bci[1], _coast_v_bci[2]])
	_dev_have_v = true                                       # SN-R1: the dev-flight seed mirrors the coast velocity
	_horiz_vel = Vector3.ZERO
	velocity = Vector3.ZERO
	_dev_active = true                                       # tells _nav_tick the coast owns the BCI velocity this frame

## COSMOS SPACE-NAV §7.4 (ORBIT_COAST) — SN-ODECAY FIX. The Kepler coast step that carries the BCI [p,v] pair in
## f64 ACROSS ticks and writes the lattice `position` as a DISPLAY-ONLY projection (never read back). Distinct from
## the shared `_coast_step` (which reconstructs p from `position` every tick — correct for the short, near-radial
## free-fall, but for a long tangential orbit the SAME-t fixed↔BCI round-trip rotates p by one tick of planet spin
## relative to the f64 velocity and pumps eccentricity). Pure central free coast (no thrust/drag). Precondition:
## on an active facet (fid >= 0 — the caller guards). Returns [p_bci_new, v_bci_new]. Proven by G-ODECAY.
func _coast_step_kepler(delta: float, p_bci: PackedFloat64Array, v_bci: PackedFloat64Array, body: String) -> Array:
	var fid := TerrainConfig.active_facet()
	var t := _nav_clock
	var os = _OrbitalStateCls.make(body, p_bci, v_bci)
	os.step(delta, _DVCls.v(0.0, 0.0, 0.0))                 # pure free coast (no thrust/drag)
	# G-REENTRY FIX C: same integration guard as _coast_step — NaN reverts, beyond-SOI clamps (see there).
	var safe := _CosmosNavCls.clamp_bci_state(os.pos, os.vel, p_bci, v_bci, _CosmosNavCls.soi_radius(body))
	# DISPLAY-ONLY: project the new BCI position back to the lattice for rendering/streaming/collision. This value
	# is NEVER read back into the integrator (that read-back was the pump) — the carried BCI pair is the truth.
	var pf_new: PackedFloat64Array = _OrbitalStateCls.bci_to_fixed(body, t, safe[0], safe[1])[0]
	var lat: Array = _FacetAtlasCls.world_to_lattice64(fid, pf_new[0], pf_new[1], pf_new[2])
	position = Vector3(lat[0], lat[1], lat[2])
	return [safe[0], safe[1]]

## COSMOS-PERF FALL-COLLAPSE FIX (FP_COAST_BATCH) — the BATCHED orbit coast: the whole substep batch carried in the
## BCI frame with ONE display-only lattice write. Because `_coast_step_kepler` carries [p,v] and NEVER reads
## `position` back (the display projection is thrown away and overwritten), the per-substep loop's only per-tick
## outputs are the carried [p,v] and the display `position` — so batching is BIT-identical: N cheap BCI Verlet steps
## (CosmosNav.coast_batch_bci, ONE OrbitalState) then ONE bci_to_fixed + world_to_lattice64 for the final display
## position. ZERO lattice_to_world64 (the orbit never reconstructs from `position`) + ONE world_to_lattice64 + ONE
## OrbitalState.make per call, regardless of N. Returns [p_bci', v_bci']. Gate G-COAST-BATCH.
func _coast_batch_kepler(delta: float, n: int, p_bci: PackedFloat64Array, v_bci: PackedFloat64Array, body: String) -> Array:
	var fid := TerrainConfig.active_facet()
	var t := _nav_clock
	var out := _CosmosNavCls.coast_batch_bci(body, p_bci, v_bci, delta, n, _CosmosNavCls.soi_radius(body))   # N cheap BCI steps, ONE make
	var pf_new: PackedFloat64Array = _OrbitalStateCls.bci_to_fixed(body, t, out[0], out[1])[0]   # ONE BCI→world (display only)
	var lat: Array = _FacetAtlasCls.world_to_lattice64(fid, pf_new[0], pf_new[1], pf_new[2])   # ONE world→lattice (display only)
	position = Vector3(lat[0], lat[1], lat[2])
	return out

## COSMOS SPACE-NAV §7.4 (ORBIT_COAST) — is there a thrust/movement input this tick (the coast-exit trigger)? WASD
## (input.x/z) or the vertical verb (Space/Ctrl, or the remote `input.y`). Pure read of the already-polled input.
func _coast_thrust_input(input: Vector3) -> bool:
	if input.x != 0.0 or input.z != 0.0:
		return true
	if remote_drive:
		return absf(input.y) > 0.0
	return Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_CTRL)

## SN-FIX #3 — the free-fall → surface handoff: the LATTICE vertical velocity (velocity.y) equivalent of the
## current BCI fall velocity, so the surface-feel gravity continues from the true downward speed (continuous at
## the ceiling). Uses the SN1 frame maps; near the facet centre the lattice normal is the radial, so this is the
## fall's descent rate. Returns the current velocity.y unchanged if no fall velocity / off-facet.
func _fall_exit_vy() -> float:
	var fid := TerrainConfig.active_facet()
	if fid < 0 or _fall_v_bci.size() != 3:
		return velocity.y
	var t := _nav_clock
	var w: Array = _FacetAtlasCls.lattice_to_world64(fid, position.x, position.y, position.z)
	var body := _dominant_body()
	var p_bci: PackedFloat64Array = _OrbitalStateCls.fixed_to_bci(body, t, _DVCls.v(w[0], w[1], w[2]), _DVCls.v(0.0, 0.0, 0.0))[0]
	var vf: PackedFloat64Array = _OrbitalStateCls.bci_to_fixed(body, t, p_bci, _fall_v_bci)[1]
	var v_lat := _FacetAtlasCls.frame_basis(fid).transposed() * Vector3(vf[0], vf[1], vf[2])
	return v_lat.y

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
	var body := _dominant_body()                            # O4c: dev-flight expresses over the dominant body
	var p_bci: PackedFloat64Array = _OrbitalStateCls.fixed_to_bci(body, t, p_fix, _DVCls.v(0.0, 0.0, 0.0))[0]
	var mode := int(_nav.mode)
	# Seed the controller's velocity on the first orbital tick from the last SN2-derived BCI velocity (seamless
	# handoff from the PLANETARY lattice fly); if none is available yet, rest in the current frame (carrier).
	if not _dev_have_v:
		if _nav_last_v_bci.size() == 3:
			_dev_v_bci = PackedFloat64Array([_nav_last_v_bci[0], _nav_last_v_bci[1], _nav_last_v_bci[2]])
		else:
			_dev_v_bci = _CosmosNavCls.carrier_velocity(mode, body, p_bci, _DVCls.v(0.0, 0.0, 0.0), t)
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
	var cap := _DevFlightCls.speed_cap(mode, body, p_bci, t, running)
	var out: Array = _DevFlightCls.step(mode, body, p_bci, _dev_v_bci, t, delta, wish_bci, cap)
	var p_new: PackedFloat64Array = out[0]
	_dev_v_bci = out[1]
	# BCI → body-fixed → lattice, and write it back as the player's canonical position.
	var pf_new: PackedFloat64Array = _OrbitalStateCls.bci_to_fixed(body, t, p_new, _dev_v_bci)[0]
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
	return _OrbitalStateCls.fixed_to_bci(_dominant_body(), t, _DVCls.v(wd.x, wd.y, wd.z), _DVCls.v(0.0, 0.0, 0.0))[0]

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
			# O — circular-orbit release (LOW/HIGH). Under ORBIT_COAST (§7.4) O engages a REAL Keplerian free-coast
			# (gravity-integrated each frame — a stable orbit HOLDS, fixing "orbits then hangs"); O again leaves it.
			# Flag off ⇒ the shipped velocity-command release (which decays to rest with no ongoing input — the bug).
			if mode == _CosmosNavCls.LOW_ORBIT or mode == _CosmosNavCls.HIGH_ORBIT:
				if CubeSphere.ORBIT_COAST:
					var body := _dominant_body()
					if _orbit_coasting:
						# O again → leave the coast. Seed the dev-flight velocity-command from the CURRENT coast
						# velocity (SN-R1 — no jump) and commit so the controller owns flight from here.
						_orbit_coasting = false
						_dev_v_bci = PackedFloat64Array([_coast_v_bci[0], _coast_v_bci[1], _coast_v_bci[2]])
						_dev_have_v = true
						_dev_orbital_commit = true
						_coast_p_bci = PackedFloat64Array()     # SN-ODECAY: drop the carried BCI pos so a re-entry re-seeds
					else:
						# O → enter the free-coast. Seed v = v_circ·t̂ with t̂ = the YAW-heading tangent (the BODY
						# basis forward, PITCH IGNORED — pitch never tilts the orbit plane). Gravity does the rest.
						var look_yaw := _dev_dir_to_bci(fid, t, _DevFlightCls.coast_seed_look_lattice(transform.basis)) if fid >= 0 else _DVCls.v(0.0, 1.0, 0.0)
						_coast_v_bci = _DevFlightCls.release_circular(body, _dev_p_bci, look_yaw, _dev_v_bci if _dev_have_v else _DVCls.v(0.0, 0.0, 0.0))
						# SN-ODECAY FIX: seed the carried f64 BCI position from `_dev_p_bci` — the EXACT point
						# release_circular made the velocity circular for, so the integrated orbit starts perfectly circular.
						_coast_p_bci = PackedFloat64Array([_dev_p_bci[0], _dev_p_bci[1], _dev_p_bci[2]])
						_orbit_coasting = true
						_dev_v_bci = PackedFloat64Array([_coast_v_bci[0], _coast_v_bci[1], _coast_v_bci[2]])
						_dev_have_v = true
						_dev_orbital_commit = true
				else:
					var look := _dev_dir_to_bci(fid, t, -window_camera_transform().basis.z) if fid >= 0 else _DVCls.v(0.0, 1.0, 0.0)
					_dev_v_bci = _DevFlightCls.release_circular(_dominant_body(), _dev_p_bci, look, _dev_v_bci if _dev_have_v else _DVCls.v(0.0, 0.0, 0.0))
					_dev_have_v = true
					# SN-FIX #3: O is the explicit "commit to orbital flight" verb — latch it so the velocity-command
					# controller now owns flight (under SN_NO_CEILING_BOUNCE; the latch is inert with the flag off).
					_dev_orbital_commit = true
		KEY_G:
			# G — geostationary snap (HIGH only): teleport to r_geo at the current longitude, v = ω⃗×p. Over a body
			# with no stationary orbit (r_geo > SOI) the snap returns empty ⇒ "none" (no-op here).
			if mode == _CosmosNavCls.HIGH_ORBIT and fid >= 0:
				var snap := _DevFlightCls.geostationary_snap(_dominant_body(), _dev_p_bci)
				if snap.size() == 2:
					var p_new: PackedFloat64Array = snap[0]
					var v_new: PackedFloat64Array = snap[1]
					var pf: PackedFloat64Array = _OrbitalStateCls.bci_to_fixed(_dominant_body(), t, p_new, v_new)[0]
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
		_fall_have_v = false                                # flying ⇒ not falling; next F-off re-seeds the free-fall
		# DEV-FLIGHT CRUISE MODE (CubeSphere.CRUISE_MODE): while dev-flying IN SPACE (radial alt > ATMO_TOP), HOLDING C
		# flies the camera LOOK dir at an exponential distance-scaled speed; release C ⇒ instant stop (kinematic, no
		# residual drift). Flag OFF ⇒ C never polled ⇒ byte-identical. Uses radial_altitude() (nearest/dominant body).
		# DEV remote-cruise: remote_cruise_active() lets the CONTROL_ENABLED executor drive cruise for a timed hold
		# (a human can't send a C keypress). Off ⇒ remote_cruise_active() is always false ⇒ this reduces to the
		# shipped `not remote_drive` + physical-C predicate exactly (byte-identical).
		if CubeSphere.CRUISE_MODE and (remote_cruise_active() or not remote_drive):
			var cruise_alt := radial_altitude()
			# C = forward cruise, B = REVERSE cruise (fly backward along the look dir). Either engages; when only B
			# (or the remote reverse dir) is held, the look_dir is negated below.
			var fwd_held := Input.is_key_pressed(KEY_C) or (remote_cruise_active() and _remote_cruise_dir >= 0)
			var rev_held := Input.is_key_pressed(KEY_B) or (remote_cruise_active() and _remote_cruise_dir < 0)
			var c_held := fwd_held or rev_held
			if CubeSphere.cruise_engaged(true, cruise_alt > CubeSphere.ATMO_TOP, c_held):
				# FP_CRUISE_LOOKDIR: fly along the camera view in space. `position` is a LATTICE pose, so the look
				# dir MUST be a LATTICE direction — the camera basis re-expressed in the active facet lattice (the
				# SAME construction _kinematic_look_fly uses). Using the GLOBAL window_camera_transform() basis here
				# scrambles the axes under the facet's world tilt (flies the wrong way). ATT_SURFACE or flag off ⇒
				# the shipped body-yaw+pitch path (byte-identical), which is already in-frame on the surface.
				var look_dir: Vector3
				var cr_afid := TerrainConfig.active_facet()
				if CubeSphere.FP_CRUISE_LOOKDIR and CubeSphere.ORBIT_6DOF_FLY and _att_mode != ATT_SURFACE and cr_afid >= 0:
					var b_lat_cam := _CosmosAttitudeCls.lat_cam_basis(_FacetAtlasCls.frame_basis(cr_afid), _attitude_scene_basis())
					look_dir = b_lat_cam * Vector3(0.0, 0.0, -1.0)
				else:
					var look_local := Basis(Vector3(1, 0, 0), _pitch) * Vector3(0.0, 0.0, -1.0)
					look_dir = (transform.basis * look_local)
				if rev_held and not fwd_held:
					look_dir = -look_dir                     # B / remote-reverse: cruise backward along the view
				if look_dir.length() > 0.0:
					look_dir = look_dir.normalized()
				var cruise_v := CubeSphere.cruise_speed(cruise_alt)
				position += look_dir * cruise_v * delta
				_horiz_vel = Vector3(look_dir.x, 0.0, look_dir.z) * cruise_v
				velocity = Vector3.ZERO                      # kinematic fly; release ⇒ instant stop (no residual)
				return
		var use_devnav := _dev_nav and _nav != null
		# COSMOS SPACE-NAV §7.4 (ORBIT_COAST): the O free-coast. While coasting, gravity integrates the orbit each
		# frame (a stable circular seed HOLDS radius — the fix for "orbits then hangs"). EXIT: (b) any thrust/movement
		# input hands off to the dev-flight velocity-command (SN-R1: `_dev_v_bci` already mirrors the coast velocity
		# ⇒ no jump); (c) dropping into the atmosphere (PLANETARY) hands off to the shipped surface/dev path. On exit
		# we fall through to the handoff below with `_dev_orbital_commit` set. Flag off ⇒ `_orbit_coasting` is never
		# true ⇒ this whole block is skipped (byte-identical).
		if CubeSphere.ORBIT_COAST and use_devnav and _orbit_coasting:
			if int(_nav.mode) == _CosmosNavCls.PLANETARY or _coast_thrust_input(input):
				_orbit_coasting = false
				_dev_orbital_commit = true                  # commit the mirrored coast velocity to the controller
			else:
				_orbit_coast_move(delta)
				return
		# SN-FIX #3 (SN_NO_CEILING_BOUNCE): `orbital_handoff` gates the O-COMMITTED orbital controller. Flag off ⇒
		# it is the shipped `mode != PLANETARY` test (byte-identical auto-handoff). Flag on ⇒ it also requires the
		# explicit O commit (`_dev_orbital_commit`), so the O velocity-command controller (a follow-up) runs ONLY
		# after the pilot commits — its per-mode caps + SN-R1 continuity are untouched.
		if use_devnav and orbital_handoff(int(_nav.mode), _dev_orbital_commit, CubeSphere.SN_NO_CEILING_BOUNCE):
			_dev_flight_move(delta, input, running)
			return
		# SN-FIX #3: F-MODE MODEL — under the flag, dev-nav fly is a GRAVITY-OFF kinematic fly in the FULL look
		# direction (camera forward incl. pitch), at ALL altitudes. No controller ramp, no deceleration crossing
		# the atmosphere ceiling: the "bounce" is gone and looking up + forward climbs straight into orbit.
		if use_devnav and CubeSphere.SN_NO_CEILING_BOUNCE:
			_dev_have_v = false                             # drop the seed so a later O-commit re-seeds cleanly
			if int(_nav.mode) == _CosmosNavCls.PLANETARY:
				_dev_orbital_commit = false
			_kinematic_look_fly(delta, input, running)
			return
		# Shipped lattice fly: the bare fly toggle (SN_DEVNAV off), or dev-nav PLANETARY with SN_NO_CEILING_BOUNCE
		# off. Drop the controller's velocity seed so the next ORBITAL entry re-seeds from the fresh SN2 velocity.
		if _dev_nav:
			_dev_have_v = false
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

	# SN-FIX #3 (SN_NO_CEILING_BOUNCE): F-OFF gravity is WHERE-aware. ABOVE the atmosphere ceiling the player is in
	# the planet-centred (inertial) frame — free-fall under GM_dyn/r² toward the planet centre, NO surface-rotation
	# drag (that frame switch is the nav machine's carrier ω⃗×p → 0). BELOW the ceiling the shipped surface-feel
	# gravity/frame takes over; the fall's radial velocity is handed to velocity.y so the transition is continuous.
	# Flag off / FLAT ⇒ skipped ⇒ the shipped walk is byte-identical.
	if CubeSphere.SN_NO_CEILING_BOUNCE and CubeSphere.FACETED and free_fall_regime(flying, radial_altitude(), true):
		_free_fall_move(delta)
		return
	# G-LANDING (SN_FOFF_RADIAL_FALL) latch hygiene: reaching the surface-walk regime FULFILS any pending
	# land-commit — clear the one-shot latch so an F-off made on the ground can never leak into a much-later
	# AUTOMATIC free-fall seed (whose SN-R1 velocity continuity must stay untouched). Inert bookkeeping off-flag.
	_foff_radial = false
	if _fall_have_v:
		# Leaving free-fall (dropped below the ceiling): seed velocity.y from the BCI fall velocity so the surface
		# walk's gravity continues from the true downward speed — a continuous flight→fall→surface handoff.
		velocity.y = _fall_exit_vy()
		_fall_have_v = false

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
	# FP_FALL_TIMING P0 (docs/COSMOS-MOTION-PHYS-DESIGN.md §6, task #129 P2b): bracket JUST the 6 blocked() wall probes so
	# t_probe_us splits the walking t_move cost between the block_id_at/cell_value_at probes (cacheable — FP_MOVE_PROBE_CACHE)
	# and move_and_collide/depenetration (not). Decision rule §6.4: probe ≥5ms ⇒ ship the cache; <3ms ⇒ the cost is the
	# physics call, cache can't reach the bar. Byte-off (only under _ft_on).
	var _pt := Time.get_ticks_usec() if CubeSphere.FP_FALL_TIMING else 0
	if delta_move.x != 0.0:
		var lead_x := position.x + signf(delta_move.x) * PLAYER_RADIUS + delta_move.x
		if world.blocked(lead_x, position.z, feet_y, _pos_fid) \
				or world.blocked(lead_x, position.z - PLAYER_RADIUS, feet_y, _pos_fid) \
				or world.blocked(lead_x, position.z + PLAYER_RADIUS, feet_y, _pos_fid):
			delta_move.x = 0.0
	if delta_move.z != 0.0:
		var lead_z := position.z + signf(delta_move.z) * PLAYER_RADIUS + delta_move.z
		if world.blocked(position.x, lead_z, feet_y, _pos_fid) \
				or world.blocked(position.x - PLAYER_RADIUS, lead_z, feet_y, _pos_fid) \
				or world.blocked(position.x + PLAYER_RADIUS, lead_z, feet_y, _pos_fid):
			delta_move.z = 0.0
	if CubeSphere.FP_FALL_TIMING:
		_ft_max("t_probe_us", Time.get_ticks_usec() - _pt)
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
	# SN-BRAKE (§6): atmospheric DESCENT braking. Below ATMO_TOP a fast re-entry (the F-off free-fall velocity
	# handed to velocity.y at 384) decelerates toward ATMO_BRAKE_TERMINAL under the density-profiled SN1 drag,
	# so the descent never outruns terrain streaming (the fix for the ~141 m/s landing generation storm).
	# DESCENT-ONLY (velocity.y < 0) so a jump's rise is untouched; per-body via _dominant_body() (no hardcoded
	# Earth); the drag impulse is sign-clamped so drag alone can slow the fall to rest but never flips it upward
	# (semi-implicit stability under a big post-hitch dt). Density ≈ 0 at 384 ⇒ continuous with the space
	# free-fall (which owns h ≥ 384 with NO drag). Flag off / FLAT / airless ⇒ no term ⇒ byte-identical.
	if CubeSphere.SN_ATMO_BRAKING and CubeSphere.FACETED and velocity.y < 0.0:
		var a_brake := _OrbitalStateCls.atmo_brake_accel(_dominant_body(), radial_altitude(), velocity.y)
		var dvy := a_brake * delta
		if dvy > -velocity.y:                                # never decelerate past a standstill from drag alone
			dvy = -velocity.y
		velocity.y += dvy
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

	# FP_FALL_TIMING: split out the per-frame landing floor query (t_floor_us) — the re-entry residual the
	# FP_FLOOR_MEMO cache targets (cold-generator scans in _move). Off ⇒ the flag test only (byte-identical).
	var _ft_on2 := CubeSphere.FP_FALL_TIMING
	var _ft_t2 := 0
	if _ft_on2: _ft_t2 = Time.get_ticks_usec()
	var terrain_floor := world.floor_under(position.x, position.z, position.y, _pos_fid)
	if _ft_on2: _ft_max("t_floor_us", Time.get_ticks_usec() - _ft_t2)
	# COSMOS FALL-THROUGH INCIDENT PROBE (FP_FALLTHRU_PROBE, §4): diagnostic-only, right after the landing query
	# so it observes exactly what this frame's landing decision saw. Off ⇒ one flag compare (byte-identical).
	_fallthru_probe_check(terrain_floor)
	# COSMOS FALL-THROUGH FIX (FP_TP_FLOOR_WELD): after a dev geo-teleport, the analytic column scan floor_under
	# can disagree with the analytic surface_y at the SAME facet/column (measured: floor_under −12.1 vs surface_y
	# +11.9 at lat8/lon2 — a datum/column-scan mismatch), so the falling player tunnels the true grass surface and
	# lands on the deep fill. Facet is correct (own_dist ≫ −HYST, no crossing) so the prior facet-weld did nothing.
	# Fix: for a brief landing window, floor the descent at surface_y (the shared-heightmap law the mesh follows) so
	# the teleport lands ON the surface. Dev-only (_tp_land_frames armed solely by _dev_teleport_geo); off-flag ⇒ skip.
	if CubeSphere.FP_TP_FLOOR_WELD and _tp_land_frames > 0:
		if absf(position.x - _tp_land_x) <= 3.0 and absf(position.z - _tp_land_z) <= 3.0:
			terrain_floor = maxf(terrain_floor, world.surface_y(position.x, position.z, _pos_fid))
		else:
			_tp_land_frames = 0   # walked away from the teleport column — release (floor_under is correct there)
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

	_grounded = position.y <= floor_y   # FP_UPVECTOR_FACET_HEAL hint capture (see the var's own doc); unread off-flag
	if _grounded:
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

	# COSMOS PLAYER-UPVECTOR-FACET-DESYNC FIX §5.3 (FP_CAMERA_RADIAL_LEVEL, docs/COSMOS-PLAYER-UPVECTOR-FACET-
	# DESYNC-DESIGN.md) — the ONE flag-gated per-frame camera-display write. Placed AFTER the crossing/resync/
	# heal block above (§5.5: the active facet is post-commit/post-heal, so phi reads the healed basis — never
	# the full facet-step error) and AFTER `terrain_floor` above (this frame's terrain-relative altitude
	# reference, §5.2 — NOT radial altitude, so a mountaintop stand reads w≈0). Rebuilds the pre-roll basis from
	# the INPUT STATE, never from `_camera` (the same feedback-loop guard `window_camera_transform` documents).
	# Off ⇒ this whole block does not exist; the shipped event-driven camera writes (set_initial_look, the mouse
	# handler, _attitude_handback) remain the only camera-local writers ⇒ byte-identical.
	if CubeSphere.FP_CAMERA_RADIAL_LEVEL and _att_mode == ATT_SURFACE and _camera != null:
		_cam_rl_ease = minf(1.0, _cam_rl_ease + delta / CubeSphere.CAM_RL_EASE_S)
		var _rl_b0 := global_transform.basis * Basis(Vector3(1, 0, 0), _pitch)
		var _rl_ur := (global_position - planet_render_centre()).normalized()
		var _rl_alt := position.y - terrain_floor
		var _rl_phi := cam_rl_phi(_rl_ur, _rl_b0.x, _rl_b0.y, _rl_alt, _pitch, _cam_rl_ease)
		_cam_rl_last_phi = _CAM_RL_SIGN * _rl_phi
		_camera.transform = Transform3D(
			Basis(Vector3(1, 0, 0), _pitch) * Basis(Vector3(0, 0, 1), _cam_rl_last_phi),
			Vector3(0, eye_height, 0))

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
	# DEV-FLY DESYNC FIX (Option 1): turning fly OFF while dev-nav is engaged must route through the real
	# dev-nav teardown, else `_dev_nav` stays stuck true while `flying` goes false — after which the idempotent
	# remote_set_dev_nav(true) re-arm is a no-op (reports success) and thrust silently takes the walk path (no lift).
	# Keeps the invariant `_dev_nav ⇒ flying` so the next remote_set_dev_nav(true) re-engages cleanly.
	if not on and _dev_nav:
		_toggle_dev_nav()
		return
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

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# COSMOS SPACE-FLY DEV/TEST ACTUATORS (docs/COSMOS-SPACEFLY-DESIGN.md). The scriptable-flight surface the
# RemoteControl executor drives so the ORCHESTRATOR can fly test missions headlessly. Each ROUTES THROUGH
# THE SAME gated space-nav path a human's F/O/G/R/Q/E keystrokes take (`_toggle_dev_nav`, `_dev_toggle_key`,
# the `_attitude_tick` roll poll, the `remote_input` thrust seam) — NO new flight math, NO parallel state.
# All are safe no-ops when their gates are off (dev-nav not engaged, nav machine absent), so a call from a
# harness or the executor before the space-nav flags are enabled simply reports `false`/`{}` and changes
# nothing. The executor never exists off RemoteBridge.CONTROL_ENABLED ⇒ byte-identical in normal play.
# ══════════════════════════════════════════════════════════════════════════════════════════════════

## set_dev_nav (F): drive dev-nav to a definite ON/OFF state (idempotent — a human F is a toggle). Guarded by
## SN_DEVNAV exactly as the KEY_F handler: with the flag off, dev-nav does not exist, so this reports false and
## does nothing (the harness then knows the space-nav build is not the one running). Returns the resulting state
## == requested on success, false otherwise.
func remote_set_dev_nav(on: bool) -> bool:
	if not CubeSphere.SN_DEVNAV:
		return false
	if _dev_nav != on:
		_toggle_dev_nav()                          # the exact human-F path (fly on/off, overlay, seed reset)
	elif on and not flying:
		# DEV-FLY DESYNC FIX (Option 2, self-heal): repair a `flying`=false / `_dev_nav`=true desync left by a
		# prior remote_set_fly(false)/override so the orchestrator's re-arm reliably re-engages lift.
		flying = true
		if _body_shape != null:
			_body_shape.disabled = true
	return _dev_nav == on

## nav verb (O/G/R): the dev-nav mode toggles. verb ∈ orbit(O) | geostation(G) | detach(R). Guarded EXACTLY as
## the KEY_O/G/R handler (SN_DEVNAV && dev-nav engaged && the nav machine live && a BCI state exists), so it is a
## no-op returning false whenever a human keypress would also be inert. Returns true iff the verb was dispatched.
func remote_nav_verb(verb: String) -> bool:
	if not (CubeSphere.SN_DEVNAV and _dev_nav and _nav != null):
		return false
	var keycode := 0
	match verb:
		"orbit": keycode = KEY_O
		"geostation": keycode = KEY_G
		"detach": keycode = KEY_R
		_: return false
	if _dev_p_bci.size() != 3:
		return false                               # no BCI state yet — the same guard _dev_toggle_key applies
	_dev_toggle_key(keycode)
	return true

## thrust seam (WASD + Space/Ctrl held): arm the body-local wish (x=strafe, y=vertical, z=forward, same shape as
## the WASD/vertical polls) + run for THIS and every following tick until zeroed. In dev-nav this feeds the fly /
## dev-flight / coast-exit paths identically to a held key. The executor sets this at a thrust step's start and
## zeroes it (via remote_stop_thrust) at the step's deadline — a timed hold. No-op unless a caller sets it.
func remote_set_thrust(wish: Vector3, run: bool) -> void:
	remote_input = wish
	remote_run = run
	remote_drive = true

## Release the thrust seam (the executor calls this at a thrust step's end; mirrors RemoteControl._zero_intent).
func remote_stop_thrust() -> void:
	remote_drive = false
	remote_input = Vector3.ZERO
	remote_run = false

## DEV remote-cruise (remote `thrust` step with cruise:true) — the scripted-test analogue of HOLDING C, which a
## remote drive cannot press. Engages supercruise for `seconds` along the current camera look dir via a
## self-expiring deadline, so the cruise branch runs each tick WITHOUT remote_drive (which would gate cruise off).
## Only reachable through the CONTROL_ENABLED executor; `_remote_cruise_until_usec` stays 0 otherwise, so
## remote_cruise_active() is always false and the cruise branch is byte-identical to shipped.
func remote_set_cruise(seconds: float, reverse: bool = false) -> void:
	_remote_cruise_until_usec = Time.get_ticks_usec() + int(maxf(0.0, seconds) * 1.0e6)
	_remote_cruise_dir = -1 if reverse else 1

## True while a remote cruise deadline is live (drives the cruise engage predicate alongside the physical C key).
func remote_cruise_active() -> bool:
	return _remote_cruise_until_usec > 0 and Time.get_ticks_usec() < _remote_cruise_until_usec

## roll seam (Q/E held): rad/s applied to the BCI attitude in _attitude_tick's SPACE branch. Zeroed by the
## executor at the roll step's deadline. No-op unless ORBIT_ATTITUDE is engaged and the camera is emancipated.
func remote_set_roll(rate: float) -> void:
	remote_roll_rate = rate

## DEV TIME-CHEAT (remote `set_time`, docs/COSMOS-REMOTE-CONTROL-DESIGN.md) — set the celestial time-of-day so
## the player's CURRENT surface position sits at a chosen local solar time. `local_hours` ∈ [0,24] (12 = local
## noon, Sun highest); if `sun_elev_deg` is finite it instead lands the Sun at that elevation above the local
## horizon. Folds a persistent f64 offset into the ONE celestial clock the whole ephemeris reads (sun + moon +
## planets + spin/day-night all move together — no per-body special-case). Returns false (a no-op) when there is
## no clock (ORBITAL_SKY/climate off), mirroring remote_nav_verb's inert-guard so a scripted set fails loudly.
## The planet is pinned at scene identity with its centre at the world origin (the fixed-frame keystone), so the
## player's world position IS its body-fixed surface vector; the ephemeris body-fixed frame is that scene frame.
func remote_set_time(local_hours: float, sun_elev_deg: float = NAN) -> bool:
	if world == null:
		return false
	var clock: CosmosEphemeris.CosmosClock = world.cosmos_clock()
	if clock == null:
		return false
	# COSMOS set_time FLOATING-ORIGIN FIX: the planet centre is at planet_render_centre() (NOT world origin) once the
	# floating origin re-anchors on a long cruise / at high altitude — so raw global_position is NOT the body-fixed
	# surface vector there (set_time then solves the local hour angle from a wrong longitude → wrong time of day far
	# from spawn). Subtract the render centre exactly as the sky's cam_rel does (FP_SKY_PLANET_CENTRE), so set_time
	# tracks the player's TRUE longitude everywhere. At spawn planet_render_centre()==0 ⇒ unchanged.
	var up_bf := global_position - planet_render_centre()
	if up_bf.length() < 1.0e-6:
		return false
	var t_eff := clock.now()                         # solve relative to the current (possibly already-offset) phase
	var delta: float
	if is_finite(sun_elev_deg):
		delta = _EphCls.offset_for_sun_elev(CosmosSky.OBSERVER, up_bf, t_eff, sun_elev_deg)
	else:
		delta = _EphCls.offset_for_local_hours(CosmosSky.OBSERVER, up_bf, t_eff, local_hours)
	clock.add_offset(delta)
	return true

## DEV NADIR-LOCK (orbit screenshot framing): aim the frozen camera straight at world.planet_render_centre() so
## an automated orbit screenshot centres the planet at ANY altitude — a plain pitched `look` is unreliable because
## the orbital attitude is inertial. Direct camera set (holds while frozen, nothing rewrites it) + seed the space
## attitude quaternion so window_camera_transform reproduces the basis on unfreeze. pitch_off_deg: +up (planet
## drops toward the bottom of frame). No-op before the far ring exists. CONTROL_ENABLED-gated via the executor.
func remote_look_planet(pitch_off_deg: float = 0.0) -> void:
	if _camera == null or world == null:
		return
	var c := _camera.global_transform.origin
	var p := planet_render_centre()
	if p == Vector3.ZERO or c.distance_to(p) < 1.0e-3:
		return
	var dir := (p - c).normalized()
	var up_hint := _camera.global_transform.basis.y
	if absf(dir.dot(up_hint.normalized())) > 0.999:
		up_hint = _camera.global_transform.basis.x
	var look_t := _camera.global_transform.looking_at(c + dir, up_hint)
	if pitch_off_deg != 0.0:
		look_t.basis = Basis(look_t.basis.x.normalized(), deg_to_rad(pitch_off_deg)) * look_t.basis
	look_t.basis = look_t.basis.orthonormalized()
	_camera.global_transform = look_t
	if CubeSphere.ORBIT_ATTITUDE and _att_mode == ATT_SPACE:
		var theta := _EphCls.spin_angle(_dominant_body(), _nav_clock)
		_att_q = _CosmosAttitudeCls.seed_bci(look_t.basis, theta)

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# DEV/TEST INSTRUMENTATION ACTUATORS (dev-instrument tooling) — teleport / set_alt / freeze_time /
# freeze_player. The comfortable-analysis surface the RemoteControl executor drives so the orchestrator can
# place the camera PRECISELY and hold a STABLE frame for autonomous visual capture (no fly-overshoot, no
# altitude drift, no 45-min day/night creep). Each is CONTROL_ENABLED-gated (the executor only exists under a
# grant) and the freeze latches default OFF ⇒ byte-identical in normal play. teleport/set_alt derive surface
# height from the ANALYTIC column law (world.surface_y — the shared heightmap, NEVER the voxel buffer) and
# route through the SAME safe reposition (_dev_reposition), which re-seeds fid/pose/BCI CONSISTENTLY so the
# known re-entry teleport blowup (fid/pose desync + finite-difference velocity latch) cannot occur.
# ══════════════════════════════════════════════════════════════════════════════════════════════════

## SAFE REPOSITION (the anti-blowup core). Place the player at `lattice_pos` expressed in facet `fid`'s lattice
## frame and re-seed EVERY piece of state the crossing/re-entry machinery relies on, so no consumer this frame
## or next can interpret the jump as motion or read a stale frame:
##   1. commit active facet = fid, WRITE position, STAMP _pos_fid = fid ⇒ _heal_frame_desync() sees pose/frame
##      consistency (a no-op) — the 11081-block "stale-frame teleport" (G-REENTRY FIX A) is structurally impossible.
##   2. zero velocity + DROP the finite-difference history (_nav_have_prev = false) so _nav_tick RESTS one frame
##      instead of computing Δp/dt across the jump (the 642074 v_bci latch, G-REENTRY FIX B) — then re-derives fresh.
##   3. clear every carried BCI / coast / dev-flight / free-fall latch so the controllers re-seed from the NEW
##      lattice pose (no stale [p,v] pair keeps driving the old orbit and ignoring the teleport).
##   4. kick streaming so the near field + far ring + block-LOD re-place around the new spot (the same per-frame
##      call the engine drives; the huge one-frame jump is rejected by update_streaming's velocity-predict clamp).
func _dev_reposition(fid: int, lattice_pos: Vector3) -> void:
	# FP_TP_FLOOR_WELD: drop any stale geo-teleport weld (a fresh reposition supersedes it; _dev_teleport_geo re-arms it).
	_tp_land_active = false
	if fid >= 0:
		TerrainConfig.set_active_facet(fid)
	position = lattice_pos
	_pos_fid = TerrainConfig.active_facet()                 # frame/pose consistent ⇒ _heal_frame_desync() no-op
	velocity = Vector3.ZERO
	# Drop the finite-difference + every carried BCI/coast/free-fall/dev-flight latch (the re-entry latch guards).
	_nav_have_prev = false
	_nav_prev_fix = PackedFloat64Array()
	_nav_last_v_bci = PackedFloat64Array()
	_dev_active = false
	_dev_have_v = false
	_dev_v_bci = PackedFloat64Array()
	_dev_p_bci = PackedFloat64Array()
	_orbit_coasting = false
	_coast_p_bci = PackedFloat64Array()
	_coast_v_bci = PackedFloat64Array()
	_fall_p_bci = PackedFloat64Array()
	_fall_v_bci = PackedFloat64Array()
	_foff_radial = false
	# Arm the fall-through guard so the ensuing settle/drop is caught at the surface (never below), and disarm the
	# fly/coast so a re-derived ground query applies (a dev teleport lands you on the ground, not in a flight state).
	_dev_land_guard = true
	if world != null:
		# COSMOS STREAM-SETTLE: re-anchor the near field onto the NEW sub-player facet NOW (redesignate the near pool +
		# far ring + block-LOD + ActiveFrame + re-apply the S1 approach anchor), so the meshed near bubble follows the
		# teleport instead of stranding on the old facet. No-op / byte-identical off FACETED. MUST precede update_streaming
		# so the same-frame streaming kick targets the re-designated facet.
		world.dev_reanchor_near(position)
		world.update_streaming(position)
		# COSMOS FALL-THROUGH FIX (FP_DEV_TP_REFRAME) — BACKSTOP to the _dev_facet_column facet_of_dir fix: `fid` is now
		# the contained TRUE owner, so update_streaming's crossing scan should not fire here. If any actor still flips the
		# ACTIVE frame to a NEIGHBOUR while `position` holds the OWNER (fid) lattice coords, the surface_y read below would
		# resolve the neighbour's terrain at those coords (a different sphere direction, often deep) → the feet clamp onto
		# the seafloor. Re-assert the owner frame before the surface read. Dev-only (CONTROL_ENABLED); off ⇒ byte-identical.
		if CubeSphere.FP_DEV_TP_REFRAME and fid >= 0 and TerrainConfig.active_facet() != fid:
			TerrainConfig.set_active_facet(fid)
			_pos_fid = fid
		# FLOOR-SETTLE: re-derive the FRESH analytic surface at the target (the active facet is set above; set_active_facet
		# cleared any per-column memo on a facet change, and surface_y is recomputed each call — no stale height). If the
		# placement is AT/BELOW the surface, clamp the feet exactly onto it, grounded — a ground teleport never lands
		# inside/below terrain. A placement ABOVE the surface (set_alt to altitude) is left as-is; the guard catches its fall.
		var sy := world.surface_y(position.x, position.z)
		# COSMOS STREAM-SETTLE: a NEW placement supersedes any prior settle hold (so a high set_alt after a ground
		# teleport is never re-trapped at the surface). Re-engaged below only for a genuine ground placement.
		_settle_active = false
		if position.y < sy + DEV_LAND_EPS:
			position.y = sy
			velocity = Vector3.ZERO
			_fall_have_v = false
			_dev_land_guard = false                         # already settled on the ground — nothing to catch
		# COSMOS STREAM-SETTLE: engage the hover-until-meshed hold ONLY for a GROUND placement (within SETTLE_ENGAGE_BAND
		# of the surface) AND only when the world can actually answer the near-coverage probe (FACETED + module). A HIGHER
		# placement is an intended hover (e.g. set_alt to altitude for a capture) and is left untouched — never force-landed.
		# On FLAT / the fallback path the immediate clamp above is final (byte-identical shipped behaviour — no settle).
		if position.y < sy + SETTLE_ENGAGE_BAND \
				and world.has_method("near_coverage_available") and world.near_coverage_available():
			_settle_begin(sy)

## COSMOS FALL-THROUGH INCIDENT PROBE (docs/COSMOS-FLOOR-SURFACE-FALLTHROUGH-DESIGN.md §4, FP_FALLTHRU_PROBE) —
## live proof-of-mechanism telemetry, NOT a fix: fires when this frame's landing floor sits far (> 3 blocks) below
## the RAW (unguarded — the same numbers a wrong-phase caller would see) analytic surface, the fall-through
## signature. Rate-limited to 1/s (a stuck/persistent fall would otherwise spam every physics tick). Records
## exactly the diagnostic set §4 asks for: the column, the active facet, the player's own pose stamp, the true
## facet_of_dir owner of that world direction, own_dist to all 4 seam slots under BOTH candidate facets (using the
## SAME raw lattice numbers — no reframe, this is a diagnostic dump of what the funnels actually saw), and the
## surrounding motion/mode state. Self-diagnosing per the design: active_fid != _pos_fid (or oscillation across
## records) with the column interior under the pose-consistent fid and garbage/far under the stale one NAMES the
## entry class from one live fall. Merged into `nav_telemetry()` (no remote_bridge.gd change needed). Off ⇒ the
## flag test is the only added work (byte-identical; called from `_move` right after the landing floor query).
func _fallthru_probe_check(terrain_floor: float) -> void:
	if not CubeSphere.FP_FALLTHRU_PROBE or world == null:
		return
	var raw_surface := world.surface_y(position.x, position.z)   # deliberately unguarded: what a live wrong-phase caller sees
	if terrain_floor >= raw_surface - 3.0:
		return
	var now_ms := Time.get_ticks_msec()
	if now_ms - _fallthru_probe_last_ms < 1000:
		return
	_fallthru_probe_last_ms = now_ms
	var active_fid := TerrainConfig.active_facet()
	var xi := int(floor(position.x))
	var zi := int(floor(position.z))
	var owner := -1
	if active_fid >= 0:
		var w: Array = _FacetAtlasCls.lattice_to_world64(active_fid, position.x, position.y, position.z)
		owner = _FacetAtlasCls.facet_of_dir(CubeSphere.DVec3.new(w[0], w[1], w[2]))
	var od_active := PackedFloat64Array()
	var od_posfid := PackedFloat64Array()
	for slot in 4:
		od_active.append(_FacetAtlasCls.own_dist(active_fid, slot, position.x, position.y, position.z) if active_fid >= 0 else 0.0)
		od_posfid.append(_FacetAtlasCls.own_dist(_pos_fid, slot, position.x, position.y, position.z) if _pos_fid >= 0 else 0.0)
	_fallthru_tele = {
		"ft_col": Vector2i(xi, zi),
		"ft_active_fid": active_fid,
		"ft_pos_fid": _pos_fid,
		"ft_owner_fid": owner,
		"ft_own_dist_active": od_active,
		"ft_own_dist_posfid": od_posfid,
		"ft_floor": terrain_floor,
		"ft_surface": raw_surface,
		"ft_feet_y": position.y,
		"ft_vy": velocity.y,
		"ft_cross_cooldown": world._cross_cooldown,
		"ft_flying": flying,
		"ft_dev_nav": _dev_nav,
		"ft_tp_land_active": _tp_land_active,
		"ft_settle_active": _settle_active,
	}
	print("[FP_FALLTHRU_PROBE] col=(%d,%d) active=%d pos_fid=%d owner=%d floor=%.2f surface=%.2f Δ=%.2f feet_y=%.2f vy=%.2f cooldown=%d flying=%s dev_nav=%s tp_land=%s settle=%s" % [
		xi, zi, active_fid, _pos_fid, owner, terrain_floor, raw_surface, terrain_floor - raw_surface,
		position.y, velocity.y, world._cross_cooldown, str(flying), str(_dev_nav), str(_tp_land_active), str(_settle_active)])

## DEV/TEST fall-through guard — clamp the player up onto the FRESH analytic surface when a dev teleport / freeze
## drop left the feet below it. Uses world.surface_y (the shared heightmap analytic law, NEVER the voxel buffer)
## so it is immune to the stale fast-regime-crossing floor_under that buried the player live. Inert while flying /
## dev-flying (legitimate sub-surface flight is untouched) and when the feet are at/above the surface (so a normal
## descent is unaffected — it only ever fires when genuinely below the ground). Disarms after one clean landing.
func _dev_land_clamp() -> void:
	if world == null or flying or _dev_nav or _dev_freeze_player:
		return                                              # inert while flying / dev-flying / held (freeze stays invariant)
	# COSMOS FALL-THROUGH ROOT (FP_QUERY_FRAME_GUARD §2.1): this runs AFTER this frame's crossing attempt
	# (maybe_cross_facet / FP_TP_FLOOR_WELD / FP_DESCENT_FACET_RESYNC), so an aborted/rogue set_active_facet this
	# frame can leave TerrainConfig.active_facet() ahead of `_pos_fid` until next frame's _heal_frame_desync — the
	# exact cross-frame window §1.2 identifies. Pass the stamp so a wrong-phase call still reads the true column.
	var sy := world.surface_y(position.x, position.z, _pos_fid)
	if position.y < sy - DEV_LAND_EPS:
		position.y = sy                                     # snap the feet onto the true surface top
		if velocity.y < 0.0:
			velocity.y = 0.0                                # kill the downward fall (grounded)
		# Settle the fall / carried BCI latches so nav re-derives at rest on the ground.
		_fall_have_v = false
		_fall_v_bci = PackedFloat64Array()
		_fall_p_bci = PackedFloat64Array()
		_dev_land_guard = false                             # landed cleanly — disarm
		_tp_land_active = false                             # FP_TP_FLOOR_WELD: landing done — release the owner-facet weld

## COSMOS STREAM-SETTLE: enter the hover-until-meshed "settling" state after a ground teleport/fast-travel. Holds the
## player pinned at the analytic surface `sy` (no fall, motion integration suppressed) so they are never dropped into
## an un-streamed column while the re-anchored near field ramps in. Released by _settle_step once the coverage probe
## passes or the hard cap elapses. Zeroes velocity + drops the free-fall latch so nothing carries motion across.
func _settle_begin(_sy: float) -> void:
	_settle_active = true
	_settle_elapsed = 0.0
	velocity = Vector3.ZERO
	_fall_have_v = false

## COSMOS STREAM-SETTLE: advance the settling hold one physics tick. `covered` is the near-coverage probe result
## (world.near_column_meshed) — supplied by the caller so this is unit-drivable headlessly (the gate scripts coverage
## arriving after N ticks). While held: pin the feet at the FRESH analytic surface_y, zero velocity (control held, no
## fall). RELEASE when the column is meshed OR the hard cap (SETTLE_CAP_S) elapses — snap onto the surface, ARM the
## fall-through guard (catch any residual below-surface drop as the last blocks apply), and clear the latch. No-op
## when not settling. Returns true on the tick it releases (test-visible).
func _settle_step(delta: float, covered: bool) -> bool:
	if not _settle_active:
		return false
	_settle_elapsed += delta
	var sy := world.surface_y(position.x, position.z) if world != null else position.y
	position.y = sy                                         # hover pinned at the surface (never fall while un-meshed)
	velocity = Vector3.ZERO
	if covered or _settle_elapsed >= SETTLE_CAP_S:
		position.y = sy                                    # snap onto the surface top, grounded
		velocity = Vector3.ZERO
		_fall_have_v = false
		_dev_land_guard = true                             # arm the guard so the release lands ON the surface, not through it
		_settle_active = false
		return true
	return false

## teleport (dev): place the player at an absolute pose. `mode` == "xyz" ⇒ `a`,`b`,`c` are ACTIVE-FACET LATTICE
## coords (the frame `position` lives in — the same frame set_alt / snapshots operate in; kept in the CURRENT
## facet, so no facet change and no desync). `mode` == "geo" ⇒ `a` = lat_deg, `b` = lon_deg, `c` = alt (blocks
## above the LOCAL analytic surface); the facet is resolved from the world direction and the surface height from
## world.surface_y. Returns true on success, false when there is no world.
func remote_teleport(mode: String, a: float, b: float, c: float) -> bool:
	if world == null:
		return false
	if mode == "geo":
		return _dev_teleport_geo(a, b, c)
	_dev_reposition(TerrainConfig.active_facet(), Vector3(a, b, c))
	return true

## teleport geodetic: lat/lon (world body-fixed geographic — +Y is the pole; lon measured around +Y from +X
## toward +Z) → a surface column; place `alt` blocks above its ANALYTIC surface (world.surface_y). The facet is
## resolved by scanning the Earth facets for the one whose polygon contains the mapped column, so the pose lands
## in a self-consistent facet frame. Returns false if no facet contains the direction (should not happen for a
## unit sphere) or there is no world.
func _dev_teleport_geo(lat_deg: float, lon_deg: float, alt: float) -> bool:
	if world == null:
		return false
	var lat := deg_to_rad(clampf(lat_deg, -90.0, 90.0))
	var lon := deg_to_rad(lon_deg)
	var dir := Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))   # unit world direction (+Y pole)
	var col := _dev_facet_column(dir)
	if col.is_empty():
		return false
	var fid: int = int(col["fid"])
	var xf := float(int(col["x"])) + 0.5
	var zf := float(int(col["z"])) + 0.5
	TerrainConfig.set_active_facet(fid)                     # surface_y reads the ACTIVE facet's column
	var sy := world.surface_y(xf, zf)
	_dev_reposition(fid, Vector3(xf, sy + alt, zf))
	# COSMOS FALL-THROUGH FIX (FP_TP_FLOOR_WELD): if the placement is above the surface and will free-fall (the guard
	# is armed and no meshed-hover settle took over), WELD the ensuing landing to this resolved owner facet so a
	# mid-fall crossing cannot flip the frame out from under the fall-through guard. Dev-only; no-op off-flag / when
	# the reposition already settled the player onto the ground (small alt) or engaged the hover settle.
	_tp_owner_fid = fid
	_tp_land_active = _dev_land_guard and not _settle_active
	# FP_TP_FLOOR_WELD: arm the surface_y floor-hold PINNED TO THIS COLUMN. floor_under is persistently wrong here
	# (not transient), so hold the descent floor at surface_y while the player stays near the teleport column, and
	# release the moment they walk away (where floor_under is correct). Cleared by the proximity check in _move.
	_tp_land_frames = 1
	_tp_land_x = xf
	_tp_land_z = zf
	return true

## Resolve the world direction `dir` to {fid, x, z} (the Earth facet + integer lattice column containing it), or
## {} if none matches. Scans only the Earth body's facets; first containing polygon wins. Dev-only (O(6·k²)).
##
## COSMOS FALL-THROUGH FIX (FP_DEV_TP_REFRAME) — THE root cure for the lat 8/lon 2 buried-at-alt-−17 teleport.
## The shipped scan below picks the FIRST facet whose grown (grow=0.5) polygon contains the column. That growth
## accepts a column up to ~½ cell PAST a facet's ridge (measured: own_dist ∈ (−0.6, −HYST) for 288 columns in
## this atlas), so the placement is judged "past the ridge" by maybe_cross_facet — which uses the seam-plane
## own_dist, NOT the grown polygon. The player then RE-crosses to the neighbour every physics frame, and the
## post-teleport fall/settle re-reads surface_y on the crossed (deep, un-reframed) neighbour column → sinks into
## the seafloor and stays (a ONE-shot re-assert can't hold, since it re-fires each frame). Resolving the owner by
## DIRECTION via facet_of_dir (the SAME cube-sphere classifier the ridges agree with — G-M2-DIR round-trips it to
## every facet) instead returns the TRUE owner, whose landing is contained in all four ridges (own_dist ≥ −HYST),
## so no spurious crossing ever fires and surface_y stays on the correct column throughout the fall. Same surface
## height (direction-pure), just the self-consistent facet. Dev-only (CONTROL_ENABLED); flag off ⇒ the grow=0.5
## scan verbatim (byte-identical).
func _dev_facet_column(dir: Vector3) -> Dictionary:
	var d := dir.normalized()
	var w := d * _FacetAtlasCls.R_BLOCKS
	if CubeSphere.FP_DEV_TP_REFRAME:
		var owner := _FacetAtlasCls.facet_of_dir(CubeSphere.DVec3.new(d.x, d.y, d.z))
		if owner >= 0:
			var lo: Array = _FacetAtlasCls.world_to_lattice64(owner, w.x, w.y, w.z)
			return {"fid": owner, "x": floori(lo[0]), "z": floori(lo[2])}
	var base := _FacetAtlasCls.fid_base(0)                  # Earth = body index 0
	var n := _FacetAtlasCls.body_facet_count(0)
	for fid in range(base, base + n):
		var l: Array = _FacetAtlasCls.world_to_lattice64(fid, w.x, w.y, w.z)
		var xi := floori(l[0])
		var zi := floori(l[2])
		if _FacetAtlasCls.in_polygon(fid, xi, zi, 0.5):
			return {"fid": fid, "x": xi, "z": zi}
	return {}

## set_alt (dev): teleport straight to `alt` blocks above the CURRENT sub-player ANALYTIC surface, keeping the
## current facet + lattice x,z EXACTLY (zero horizontal move). The most-used framing op. Returns true on success.
func remote_set_alt(alt: float) -> bool:
	if world == null:
		return false
	var sy := world.surface_y(position.x, position.z)
	_dev_reposition(TerrainConfig.active_facet(), Vector3(position.x, sy + alt, position.z))
	return true

## freeze_time (dev): pause/resume the ONE celestial clock the whole ephemeris reads (sun/moon/planets/spin/
## day-night all stop together for a stable capture). set_time still folds an offset while frozen (the phase
## holds); resume continues from the held time. Returns false (a no-op) when there is no clock (ORBITAL_SKY off),
## mirroring remote_set_time's inert-guard so a scripted freeze fails loudly rather than silently.
func remote_freeze_time(on: bool) -> bool:
	if world == null:
		return false
	var clock: CosmosEphemeris.CosmosClock = world.cosmos_clock()
	if clock == null:
		return false
	clock.set_frozen(on)
	return true

## freeze_player (dev): pin the player — no gravity, no dev-fly drift, no orbital coast — so a hold is genuinely
## stationary for a clean frame. Suppresses ONLY the player's motion integration while on (position invariant
## across ticks); the rest of the tick keeps running. Zeroes velocity. RELEASING (on=false) re-arms the
## fall-through guard so a drop from altitude in a non-flying state lands on the surface, not through it. Inert
## unless a caller sets it.
func remote_freeze_player(on: bool) -> void:
	_dev_freeze_player = on
	velocity = Vector3.ZERO
	if not on and not flying and not _dev_nav:
		_dev_land_guard = true                              # the ensuing free-fall must land ON the surface (guard catches)

## COSMOS SPACE-FLY self-verification telemetry — the fields a scripted flight ASSERTS each mechanic on:
## altitude, |v_circ| reference, orbit radius, dominant body, dev-nav/coast/ground state, attitude mode. ADDITIVE
## + guarded: returns {} when the nav machine is off (SN_NAV_MODES false ⇒ `_nav` null), so the bridge merge adds
## nothing and the shipped telemetry is byte-identical. With the space-nav flags on it streams alongside nav_mode/
## v_bci (nav_telemetry) so ONE telemetry line fully describes the flight state. Pure read; no side effects.
func space_telemetry() -> Dictionary:
	if _nav == null:
		return {}
	var alt := radial_altitude()
	var body := _dominant_body()
	return {
		"alt": snappedf(alt, 0.1),
		"v_circ": snappedf(orbit_v_circ(), 0.01),
		"orbit_r": snappedf(_FacetAtlasCls.R_BLOCKS + alt, 0.1),
		"body": body,
		"dev_nav": _dev_nav,
		"coasting": _orbit_coasting,
		"flying": flying,
		"on_ground": _space_on_ground(),
		"att": _space_att_name(),
	}

## VACUUM HUD (FP_HUD_VACUUM_TEMP): public read of the analytic on-surface state — the SAME predicate the
## RemoteBridge telemetry reports as `on_ground` (via space_telemetry → _space_on_ground). The thermometer
## uses it to keep GROUND temp a real number while the pilot stands on a body, blanking it ("--") only when
## in space AND off any surface. Pure read; no state.
func is_on_surface() -> bool:
	return _space_on_ground()

## True iff standing on terrain (not flying, feet at/near the analytic floor) — the harness's `landed` predicate
## combines this with nav_mode == planetary. Cheap floor probe; false while flying.
func _space_on_ground() -> bool:
	if flying or world == null:
		return false
	return position.y <= world.floor_under(position.x, position.z, position.y, _pos_fid) + 0.05

## The attitude-machine state name for telemetry (surface | space | recover). "surface" when ORBIT_ATTITUDE is off.
func _space_att_name() -> String:
	match _att_mode:
		ATT_SPACE: return "space"
		ATT_RECOVER: return "recover"
		_: return "surface"

# ── COSMOS-PERF FALL-TIMING (FP_FALL_TIMING) diagnostic instrument ───────────────────────────────
## Record the running per-window MAX for one segment key (µs). Called only from the flag-gated segment wrappers
## (and from ft_record for main/sky-pushed segments), so with the flag off nothing ever writes ⇒ `_ft` stays empty.
func _ft_max(key: String, us: int) -> void:
	if us > int(_ft.get(key, 0)):
		_ft[key] = us

## Cross-node push seam: main._process (scaled-body / far-ring) and CosmosSky._process (sky recompute) time their
## own segment and forward the µs here so ALL fall-timing keys travel out through the one fall_timing() telemetry
## merge. Self-gated on the flag so an errant caller off-flag can never add a key (byte-identical off).
func ft_record(key: String, us: int) -> void:
	if not CubeSphere.FP_FALL_TIMING:
		return
	_ft_max(key, us)

## Fall-timing telemetry: the just-elapsed window's per-segment MAX µs, then RESET for the next window. Empty (⇒
## merges nothing ⇒ byte-identical) whenever the flag is off — nothing ever populated `_ft`. RemoteBridge merges
## this into each 4-Hz telemetry record exactly like space_telemetry (additive + empty-dict-guarded).
func fall_timing() -> Dictionary:
	if _ft.is_empty():
		return {}
	var out: Dictionary = _ft.duplicate()
	_ft.clear()
	return out
