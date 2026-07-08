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
var player: Node = null                        # injected; may be null (verify) — camera/eye source (Stage 3+)
var toast: ToastHUD = null                     # injected; may be null (verify) — tool feedback

var _armed: PortalFrame = null                 # the arm→link two-step's first frame (transient UI state)
var _links: Dictionary = {}                    # key(Vector4i) -> {frame: PortalFrame, other: Vector4i, surface: PortalSurface|null}
var _cell_index: Dictionary = {}               # Vector3i -> Vector4i owning link key (ring ∪ interior cells of LIVE links)

## Inject dependencies and subscribe to the world's per-cell edit signal (the teardown
## hook). `player` and `toast` may be null (headless verify).
func setup(p_world: WorldManager, p_player: Node = null, p_toast: ToastHUD = null) -> void:
	world = p_world
	player = p_player
	toast = p_toast
	if world != null and not world.cell_edited.is_connected(_on_cell_edited):
		world.cell_edited.connect(_on_cell_edited)
	# Only drive the per-frame activation loop when actually rendering (verify sets
	# render_enabled = false → the registry/teardown run headless with no _process).
	set_process(render_enabled and RENDER_PORTALS)

# --- per-frame activation + view update (PORTALS §3.5.6) -----------------------

## Rank the live surfaces by distance to their source frame, ACTIVATE the nearest
## MAX_ACTIVE that are in front of the player (within ACTIVATE_DIST + hysteresis, inside
## the camera frustum, not edge-on), deactivate the rest, and refresh each active
## surface's window-frustum camera. Off entirely when render is disabled or nothing links.
func _process(_delta: float) -> void:
	if not render_enabled or not RENDER_PORTALS or player == null or _links.is_empty():
		return
	var cam: Camera3D = player.camera_node()
	if cam == null:
		return
	var eye: Vector3 = cam.global_transform.origin
	var far: float = cam.far
	var ranked: Array = []
	for key: Vector4i in _links.keys():
		var entry: Dictionary = _links[key]
		var surf = entry["surface"]
		if surf == null:
			continue
		var src: PortalFrame = entry["frame"]
		ranked.append({"d": eye.distance_to(src.center()), "surf": surf, "src": src})
	ranked.sort_custom(func(a, b): return a["d"] < b["d"])
	var active_count := 0
	for r: Dictionary in ranked:
		var surf = r["surf"]
		var src: PortalFrame = r["src"]
		var keep := false
		if active_count < MAX_ACTIVE:
			var limit := ACTIVATE_DIST + (DEACTIVATE_HYSTERESIS if surf.is_active() else 0.0)
			if float(r["d"]) <= limit:
				var c := src.center()
				var n_s := src.global_transform().basis.z
				var edge_on := absf((eye - c).dot(n_s)) <= EDGE_ON_EPS
				if not edge_on and cam.is_position_in_frustum(c):
					keep = true
		if keep:
			if not surf.is_active():
				surf.activate(_target_px_for(src))
			surf.update_view(eye, far)
			active_count += 1
		elif surf.is_active():
			surf.deactivate()

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
