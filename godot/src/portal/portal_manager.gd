class_name PortalManager
extends Node3D
## Owns "the portals": the link registry, the linker-tool interaction, per-cell edit
## teardown, and (Stage 3+) the see-through render surfaces. A global class created by
## Main under the ENABLED gate and injected with the world/player/toast (PORTALS §3.4).
## Lives entirely OUTSIDE both render paths as its own node graph, exactly like
## FarTerrain — automatically path-agnostic.
##
## Two-step tool: use the linker on one obsidian frame to ARM it, on a second to LINK
## the pair, on a linked frame to UNLINK it. Editing a linked frame's obsidian ring or
## filling its interior tears the link down (via WorldManager.cell_edited).

## Master gate (FarTerrain pattern): false → Main creates no PortalManager, zero
## behaviour change anywhere. True today.
const ENABLED := true

## Grant a portal starter kit (obsidian + the linker) at spawn. Obsidian has no worldgen
## source yet, so the demo needs it to be buildable; the const documents and isolates
## this deliberate bend of the "start empty, break-first" rule (PORTALS §3.1).
const GRANT_STARTER_KIT := true

## Sanity cap on simultaneously-linked PAIRS.
const MAX_LINKS := 16

# --- render budget (PORTALS §3.5.6 / §5.2) -------------------------------------
## Master render kill switch (§5.2 rung 5): false → surfaces keep the energy material
## permanently (Spigot-style portals); linking, teardown and teleport still work. The
## feature never blocks the ship.
const RENDER_PORTALS := true
## Simultaneously-RENDERED portals. Web default 1 (each active SubViewport is a full extra
## scene pass); 2 is a desktop luxury.
const MAX_ACTIVE := 1
## Metres from the player eye to a source frame centre within which a portal may activate.
const ACTIVATE_DIST := 24.0
## Extra metres a currently-active portal stays active before deactivating (anti-flicker).
const DEACTIVATE_HYSTERESIS := 4.0
## SubViewport pixels per interior metre; per-axis target = clamp(size_m·this, 64, MAX_TARGET_PX).
const PX_PER_BLOCK := 96
const MAX_TARGET_PX := 768
## |(eye − centre)·normal| below this ⇒ the player is edge-on; don't activate (degenerate).
const EDGE_ON_EPS := 0.05

## Per-instance render gate. Verify sets this false: no SubViewport/quad nodes are ever
## created, yet every registry/teardown/link invariant still runs headless (PORTALS §3.0).
var render_enabled := true

var world: WorldManager                       # injected by setup(); THE cell query + edit signal source
var player = null                              # injected Player (or null / a test mock) — duck-typed camera/eye source
var toast: ToastHUD = null                     # injected; may be null (verify) — tool feedback

var _armed: PortalFrame = null                 # the arm→link two-step's first frame (transient UI state)
var _links: Dictionary = {}                    # key(Vector4i) -> {frame: PortalFrame, other: Vector4i, surface: PortalSurface|null}
var _cell_index: Dictionary = {}               # Vector3i -> Vector4i owning link key (ring ∪ interior cells of LIVE links)

## Inject dependencies and subscribe to the world's per-cell edit signal (the teardown
## hook). `player` and `toast` may be null (headless verify).
func setup(p_world: WorldManager, p_player = null, p_toast: ToastHUD = null) -> void:
	world = p_world
	player = p_player
	toast = p_toast
	if world != null and not world.cell_edited.is_connected(_on_cell_edited):
		world.cell_edited.connect(_on_cell_edited)
	# Only drive the per-frame activation loop when actually rendering (verify sets
	# render_enabled = false → the registry/teardown run headless with no _process).
	set_process(render_enabled and RENDER_PORTALS)

# --- per-frame activation + view update (PORTALS §3.5.6) -----------------------

## A second active portal renders every OTHER frame (§5.2 rung 2) — dead while MAX_ACTIVE
## is 1, but the lever is wired for a desktop/2-portal budget.
const HALF_RATE_SECOND := true

var _frame := 0                                # render frame counter (half-rate phase)

## Drive all surfaces: the nearest MAX_ACTIVE that pass distance/edge-on/cap (compute_active_set)
## AND lie in the camera frustum ACTIVATE + render; the rest deactivate and linger toward a
## SubViewport/viewer free. The 2nd active surface half-rates. Off when render disabled / no links.
func _process(delta: float) -> void:
	if not render_enabled or not RENDER_PORTALS or player == null or _links.is_empty():
		return
	var cam: Camera3D = player.camera_node()
	if cam == null:
		return
	var eye: Vector3 = cam.global_transform.origin
	var far: float = cam.far
	_frame += 1
	var active_now := {}
	for key: Vector4i in _links.keys():
		var s = _links[key]["surface"]
		if s != null and s.is_active():
			active_now[key] = true
	var want := {}
	for key: Vector4i in compute_active_set(eye, active_now):
		want[key] = true
	var rendered := 0
	for key: Vector4i in _links.keys():
		var surf = _links[key]["surface"]
		if surf == null:
			continue
		var src: PortalFrame = _links[key]["frame"]
		# The distance/cap/edge-on decision (compute_active_set) is ANDed with the live
		# camera frustum test here (frustum needs a real camera → not in the pure helper).
		var keep: bool = want.has(key) and cam.is_position_in_frustum(src.center())
		if keep:
			if not surf.is_active():
				surf.activate(_target_px_for(src))
			surf.update_view(eye, far)
			# Half-rate the 2nd+ active surface; the primary renders continuously.
			if rendered >= 1 and HALF_RATE_SECOND:
				if _frame % 2 == 0:
					surf.pulse()
				else:
					surf.set_manual()
			else:
				surf.set_continuous()
			rendered += 1
		else:
			if surf.is_active():
				surf.deactivate()
			surf.tick_idle(delta)

## PURE activation selection (PORTALS §3.5.6, headless-testable): the link keys that pass
## the distance range (ACTIVATE_DIST, + DEACTIVATE_HYSTERESIS for a currently-active one),
## the edge-on reject, and the MAX_ACTIVE cap, in nearest-first order. `active_now` = keys
## currently active (for hysteresis). The live `_process` additionally ANDs the camera
## frustum test; this function is the deterministic core the verify drives with synthetic
## eyes. Surfaces need not exist (reads only frames), so it runs with render_enabled=false.
func compute_active_set(eye: Vector3, active_now: Dictionary = {}) -> Array:
	var ranked: Array = []
	for key: Vector4i in _links.keys():
		var src: PortalFrame = _links[key]["frame"]
		ranked.append({"d": eye.distance_to(src.center()), "key": key, "src": src})
	ranked.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	var out: Array = []
	for r: Dictionary in ranked:
		if out.size() >= MAX_ACTIVE:
			break
		var key: Vector4i = r["key"]
		var src: PortalFrame = r["src"]
		var limit := ACTIVATE_DIST + (DEACTIVATE_HYSTERESIS if active_now.has(key) else 0.0)
		if float(r["d"]) > limit:
			continue
		var c := src.center()
		var n_s := src.global_transform().basis.z
		if absf((eye - c).dot(n_s)) <= EDGE_ON_EPS:
			continue                              # edge-on → degenerate view, skip
		out.append(key)
	return out

# --- walk-through teleport (PORTALS §3.6) --------------------------------------
## Optional walk-through: apply the pair isometry to the player when their eye crosses a
## linked frame's opening. Everything above ships without it (portals as windows).
const TELEPORT_ENABLED := true
const CROSS_RANGE := 4.0                        # only test frames within this many metres
const TELEPORT_LOCKOUT := 0.25                  # seconds crossing tests are disabled after a teleport
const REARM_DIST := 0.5                         # must be this far from the destination plane to re-arm
const PLAYER_RADIUS := 0.4                      # matches Player.PLAYER_RADIUS (opening inflation)
const MAX_STEP_UP := 2                          # cells to probe along the exit dir for standing room

var _prev_eye := Vector3.ZERO
var _have_prev_eye := false
var _lockout_left := 0.0
var _rearm_frame: PortalFrame = null            # the destination frame just exited (rearm-distance guard)

## Cache the player eye each physics frame and teleport when it crosses a linked frame's
## opening. Analytic (no Area3D) — exact at any frame rate. Inert when teleport is off, no
## player (headless verify), during the lockout, or while still within REARM_DIST of the
## last exit plane (the ping-pong guard).
func _physics_process(delta: float) -> void:
	if not TELEPORT_ENABLED or player == null:
		return
	if _lockout_left > 0.0:
		_lockout_left -= delta
	var eye: Vector3 = player.head_position()
	if not _have_prev_eye:
		_prev_eye = eye
		_have_prev_eye = true
		return
	var p0 := _prev_eye
	_prev_eye = eye
	# Rearm-distance guard: don't re-teleport until clear of the destination plane.
	if _rearm_frame != null:
		var rn := _rearm_frame.global_transform()
		if absf((eye - rn.origin).dot(rn.basis.z)) >= REARM_DIST:
			_rearm_frame = null
	if _lockout_left > 0.0 or _rearm_frame != null or _links.is_empty():
		return
	var cx := crossed_link(p0, eye)
	if cx["found"]:
		_teleport_through(cx["s"], cx["d"])

## The first LINKED frame the segment p0→p1 crosses (through its opening), with its
## partner. Pure (iterates only `_links`, so an UNLINKED frame is never a teleport source).
## Returns {found: bool, s: PortalFrame, d: PortalFrame}.
func crossed_link(p0: Vector3, p1: Vector3) -> Dictionary:
	for key: Vector4i in _links.keys():
		var s: PortalFrame = _links[key]["frame"]
		if p0.distance_to(s.center()) > CROSS_RANGE and p1.distance_to(s.center()) > CROSS_RANGE:
			continue
		if PortalMath.segment_crosses_frame(p0, p1, s, PLAYER_RADIUS)["hit"]:
			var other: Vector4i = _links[key]["other"]
			return {"found": true, "s": s, "d": _links[other]["frame"]}
	return {"found": false, "s": null, "d": null}

## Compute the post-teleport player state for crossing S→D (PURE, testable): apply the
## isometry to the feet position / yaw / velocity, then nudge along D's exit direction up to
## MAX_STEP_UP cells to find standing room. Returns {ok, position, yaw, velocity}; ok=false
## (refuse — the player just walks through the quad) when no standing room exists.
func compute_teleport(s: PortalFrame, d: PortalFrame, feet: Vector3, yaw: float, vel: Vector3) -> Dictionary:
	var t := PortalMath.isometry(s, d)
	var new_pos: Vector3 = t * feet
	var exit_dir := d.global_transform().basis.z    # +front of D (horizontal unit)
	var chosen := Vector3.INF
	for step in range(0, MAX_STEP_UP + 1):
		var cand := new_pos + exit_dir * float(step)
		if _standing_room(cand):
			chosen = cand
			break
	if chosen == Vector3.INF:
		return {"ok": false, "position": feet, "yaw": yaw, "velocity": vel}
	return {
		"ok": true,
		"position": chosen,
		"yaw": wrapf(yaw + PortalMath.yaw_of(t.basis), -PI, PI),
		"velocity": t.basis * vel,
	}

## Apply a teleport S→D to the live player (arrival nudge/refusal via compute_teleport).
## Returns true iff the player moved. Sets the lockout + rearm guard and resets the eye
## segment so the jump itself is not re-detected as a crossing.
func _teleport_through(s: PortalFrame, d: PortalFrame) -> bool:
	var res := compute_teleport(s, d, player.global_position, player.rotation.y, player.velocity)
	if not res["ok"]:
		return false
	player.global_position = res["position"]
	player.rotation.y = res["yaw"]
	player.velocity = res["velocity"]
	_lockout_left = TELEPORT_LOCKOUT
	_rearm_frame = d
	_have_prev_eye = false                           # re-establish the segment next frame (no self-cross)
	return true

## True iff the player can stand at `pos` (feet + head cell both non-solid). Because
## floor/walls are pure functions of TerrainConfig + edits, this is safe even into
## not-yet-meshed terrain — the ground holds before the meshes appear (PORTALS §1.3).
func _standing_room(pos: Vector3) -> bool:
	if world == null:
		return true
	var feet := Vector3i(int(floor(pos.x)), int(floor(pos.y)), int(floor(pos.z)))
	return not world.cell_solid(feet) and not world.cell_solid(feet + Vector3i(0, 1, 0))

## True iff crossing tests are currently suppressed by the post-teleport lockout.
func teleport_locked() -> bool:
	return _lockout_left > 0.0

## The SubViewport target size for a frame: portal-sized, clamped to [64, MAX_TARGET_PX].
func _target_px_for(frame: PortalFrame) -> Vector2i:
	return Vector2i(
		clampi(frame.width * PX_PER_BLOCK, 64, MAX_TARGET_PX),
		clampi(frame.height * PX_PER_BLOCK, 64, MAX_TARGET_PX))

# --- tool interaction (PORTALS §3.4.2) -----------------------------------------

## The linker tool used against the currently-aimed target (`Player._current_target()`
## shape: {kind, cell, ...}). One item, no modes: arm / disarm / link / unlink.
func use_linker(target: Dictionary) -> void:
	if String(target.get("kind", "none")) != "terrain":
		_say("Aim at an obsidian frame block")
		return
	var cell: Vector3i = target.get("cell", Vector3i.ZERO)
	if world == null or world.block_id_at(cell) != _obsidian_id():
		_say("Aim at an obsidian frame block")
		return
	var frame := PortalFrameDetector.detect(world, cell)
	if frame == null:
		_say("Not a valid frame (closed obsidian rectangle, interior 1x2 … 8x8)")
		return
	var k := frame.key()
	if _links.has(k):
		unlink(k)
		_say("Portal unlinked")
		return
	if _armed == null:
		_armed = frame
		_say("Frame armed — use the linker on a second frame")
		return
	if _armed.key() == k:
		_armed = null
		_say("Frame disarmed")
		return
	if link(_armed, frame):
		_say("Portals linked")
	_armed = null

## Link two frames (the registry primitive; also the direct test entry point). Returns
## true on success. Revalidates both, enforces MAX_LINKS, and STEALS cleanly: if either
## frame is already linked, its old link is torn down first. Registers both directions
## and indexes all ring∪interior cells; creates the render surfaces when render_enabled.
func link(a: PortalFrame, b: PortalFrame) -> bool:
	if a == null or b == null:
		return false
	var ka := a.key()
	var kb := b.key()
	if ka == kb:
		return false                          # a frame cannot link to itself
	if world == null or not PortalFrameDetector.still_valid(world, a) or not PortalFrameDetector.still_valid(world, b):
		_say("Frame no longer valid")
		return false
	# Count links that would remain AFTER any steal of a/b, so a re-link never spuriously
	# trips the cap. A brand-new pair adds one link; refuse it past MAX_LINKS.
	var stealing := _links.has(ka) or _links.has(kb)
	if not stealing and _links.size() / 2 >= MAX_LINKS:
		_say("Too many portals")
		return false
	if _links.has(ka):
		unlink(ka)
	if _links.has(kb):
		unlink(kb)
	var sa: Node = _make_surface(a, b)
	var sb: Node = _make_surface(b, a)
	_links[ka] = {"frame": a, "other": kb, "surface": sa}
	_links[kb] = {"frame": b, "other": ka, "surface": sb}
	_index_frame(a, ka)
	_index_frame(b, kb)
	return true

## Tear down the link owning `key` in BOTH directions: free both surfaces, drop both
## registry entries, and purge every indexed cell of both frames. Idempotent.
func unlink(key: Vector4i) -> void:
	if not _links.has(key):
		return
	var entry: Dictionary = _links[key]
	var other_key: Vector4i = entry["other"]
	_teardown_entry(key)
	if _links.has(other_key):
		_teardown_entry(other_key)
	# The armed frame may have just been invalidated by whatever caused this unlink; a
	# stale armed pointer is harmless (revalidated at link time) so it is left as-is.

## Free one direction's surface + registry entry + indexed cells (helper for unlink).
func _teardown_entry(key: Vector4i) -> void:
	var entry: Dictionary = _links.get(key, {})
	if entry.is_empty():
		return
	var frame: PortalFrame = entry["frame"]
	var surface: Node = entry.get("surface", null)
	if surface != null and is_instance_valid(surface):
		surface.queue_free()
	# Purge this frame's indexed cells (only those still pointing at this key — a shared
	# cell between overlapping frames would keep the other's entry, though frames never
	# legitimately share cells).
	for c: Vector3i in frame.ring_cells():
		if _cell_index.get(c, null) == key:
			_cell_index.erase(c)
	for c: Vector3i in frame.interior_cells():
		if _cell_index.get(c, null) == key:
			_cell_index.erase(c)
	_links.erase(key)

## Index every ring ∪ interior cell of `frame` to its link `key` (the O(1) edit hook).
func _index_frame(frame: PortalFrame, key: Vector4i) -> void:
	for c: Vector3i in frame.ring_cells():
		_cell_index[c] = key
	for c: Vector3i in frame.interior_cells():
		_cell_index[c] = key

# --- edit teardown (PORTALS §3.4.3) --------------------------------------------

## WorldManager.cell_edited handler: if the edited cell belongs to a live link and the
## edit invalidates the frame (a ring block changed material so the rectangle no longer
## holds) OR fills an interior cell with a solid, tear the link down. A same-material ring
## edit (e.g. snow state bits on the lintel) leaves the frame valid → the link survives.
func _on_cell_edited(cell: Vector3i, packed: int) -> void:
	var key: Variant = _cell_index.get(cell, null)
	if key == null:
		return
	if not _links.has(key):
		_cell_index.erase(cell)               # stale index entry (defensive) — clean and bail
		return
	var frame: PortalFrame = _links[key]["frame"]
	var interior_filled := frame.is_interior(cell) and CellCodec.mat(packed) != BlockCatalog.AIR
	if interior_filled or not PortalFrameDetector.still_valid(world, frame):
		unlink(key)
		_say("Portal destroyed")

# --- render surface hook (fleshed in Stage 3) ----------------------------------

## Create a PortalSurface for the (src → dst) frame, or null when rendering is disabled
## (headless verify). The surface starts INACTIVE (energy look, no SubViewport) — the
## _process loop activates it when the player is near and looking at it.
func _make_surface(src: PortalFrame, dst: PortalFrame) -> Node:
	if not render_enabled:
		return null
	var surf := PortalSurface.new()
	surf.name = "PortalSurface"
	add_child(surf)
	surf.configure(src, dst)
	return surf

# --- registry queries (verify + Stage 3 driving) -------------------------------

## True iff a link owns `key`.
func is_linked(key: Vector4i) -> bool:
	return _links.has(key)

## The partner frame's key for a linked `key`, or a sentinel Vector4i(0,0,0,-1) if unlinked.
func linked_key_of(key: Vector4i) -> Vector4i:
	if _links.has(key):
		return _links[key]["other"]
	return Vector4i(0, 0, 0, -1)

## Number of live linked PAIRS.
func link_count() -> int:
	return _links.size() / 2

## Number of indexed (ring ∪ interior) cells across all live links.
func cell_index_size() -> int:
	return _cell_index.size()

## The link key owning `cell`, or the sentinel if none.
func owning_key(cell: Vector3i) -> Vector4i:
	return _cell_index.get(cell, Vector4i(0, 0, 0, -1))

## The currently-armed frame's key, or the sentinel if none armed.
func armed_key() -> Vector4i:
	return _armed.key() if _armed != null else Vector4i(0, 0, 0, -1)

# --- helpers -------------------------------------------------------------------

func _obsidian_id() -> int:
	return BlockCatalog.id_of(&"obsidian")

## Post a toast if one is wired (null in headless verify).
func _say(text: String) -> void:
	if toast != null:
		toast.show_toast(text)
