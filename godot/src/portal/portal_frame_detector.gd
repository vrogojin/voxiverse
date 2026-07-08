class_name PortalFrameDetector
extends RefCounted
## Pure/static obsidian-frame detection (PORTALS §3.3). Reads the world ONLY via
## `world.block_id_at(cell)` — the one composed cell query (CLAUDE.md rule 1) — so
## generated terrain, player edits and trees are all valid frame material sources
## automatically (only obsidian passes the material test; obsidian exists only as placed
## edits today, but the detector does not care where a cell's material comes from).
##
## `detect(world, seed_cell)` finds the closed obsidian rectangle whose ring the
## `seed_cell` obsidian block belongs to (from any ring block, including corners), or
## null. `still_valid(world, frame)` re-checks a stored frame's interior-air + ring-
## obsidian invariant (the manager's teardown/link gate). Never a hidden second notion
## of "what's a frame" — both share `_rect_ok`.

const AIR := 0

## Obsidian material id, resolved live (never cached across calls — BlockCatalog is a
## session table a test may reset; the lookup is a cheap dict probe and detection runs
## only on tool clicks).
static func obsidian_id() -> int:
	return BlockCatalog.id_of(&"obsidian")

## Detect the frame the obsidian `seed_cell` rings, or null. Tries both vertical
## orientations; from each of the seed's in-plane AIR neighbours (the 8 tangent/up
## neighbours — orthogonal covers edge seeds, diagonal covers CORNER seeds) it drops to
## the interior floor, slides to the left column, measures w×h, and validates the full
## rectangle. Cost O(MAX_W·MAX_H) per candidate ≤ ~64 composed queries — trivial, and
## only on tool clicks. Returns the first valid frame found.
static func detect(world: Object, seed_cell: Vector3i) -> PortalFrame:
	var obs := obsidian_id()
	if obs <= AIR:
		return null
	if world.block_id_at(seed_cell) != obs:
		return null
	for axis: int in [PortalFrame.AXIS_X, PortalFrame.AXIS_Z]:
		var t := Vector3i(0, 0, 1) if axis == PortalFrame.AXIS_X else Vector3i(1, 0, 0)
		var up := Vector3i(0, 1, 0)
		# Candidate interior seeds: the 8 in-plane neighbours of the seed that are air.
		for a: int in [-1, 0, 1]:
			for b: int in [-1, 0, 1]:
				if a == 0 and b == 0:
					continue
				var c := seed_cell + t * a + up * b
				if world.block_id_at(c) != AIR:
					continue
				var frame := _try_from_interior(world, axis, t, up, c, obs)
				if frame != null:
					return frame
	return null

## From an air interior cell `c`, drop to the interior floor, slide to the left column,
## measure the rectangle, bounds-check, and validate. Returns the PortalFrame or null.
static func _try_from_interior(world: Object, axis: int, t: Vector3i, up: Vector3i, c: Vector3i, obs: int) -> PortalFrame:
	var down := Vector3i(0, -1, 0)
	# 1) DROP: walk down through air (≤ MAX_H) until the cell BELOW is obsidian (the floor).
	var bottom := c
	var steps := 0
	while world.block_id_at(bottom + down) == AIR:
		bottom += down
		steps += 1
		if steps > PortalFrame.MAX_H:
			return null                             # column too tall / not floored on obsidian
	if world.block_id_at(bottom + down) != obs:
		return null                                 # bottom row not resting on obsidian
	# 2) SLIDE: walk -tangent through air (≤ MAX_W) until the cell to the LEFT is obsidian.
	var left := bottom
	var wsteps := 0
	while world.block_id_at(left - t) == AIR:
		left -= t
		wsteps += 1
		if wsteps > PortalFrame.MAX_W:
			return null
	if world.block_id_at(left - t) != obs:
		return null                                 # left column not abutting obsidian
	var interior_min := left
	# 3) MEASURE: +tangent while air → w (far side must be obsidian); +Y while air → h.
	var w := 0
	while world.block_id_at(interior_min + t * w) == AIR:
		w += 1
		if w > PortalFrame.MAX_W:
			return null
	if w < PortalFrame.MIN_W or w > PortalFrame.MAX_W:
		return null
	if world.block_id_at(interior_min + t * w) != obs:
		return null
	var h := 0
	while world.block_id_at(interior_min + up * h) == AIR:
		h += 1
		if h > PortalFrame.MAX_H:
			return null
	if h < PortalFrame.MIN_H or h > PortalFrame.MAX_H:
		return null
	if world.block_id_at(interior_min + up * h) != obs:
		return null
	# 4) VALIDATE the full rectangle (all interior air, all ring obsidian incl. corners).
	var frame := PortalFrame.new(axis, interior_min, w, h)
	if not _rect_ok(world, frame, obs):
		return null
	return frame

## True iff `frame`'s interior is all AIR and its ring is all OBSIDIAN (steps 4a/4b).
## Shared by detection and `still_valid` so there is exactly one definition of a valid
## frame. `obs` is passed to avoid a redundant catalog lookup on the hot path.
static func _rect_ok(world: Object, frame: PortalFrame, obs: int) -> bool:
	for cell in frame.interior_cells():
		if world.block_id_at(cell) != AIR:
			return false
	for cell in frame.ring_cells():
		if world.block_id_at(cell) != obs:
			return false
	return true

## Re-validate a STORED frame against the current world (the manager's link gate and
## edit-teardown check, PORTALS §3.3/§3.4.3). True iff the rectangle still holds.
static func still_valid(world: Object, frame: PortalFrame) -> bool:
	var obs := obsidian_id()
	if obs <= AIR:
		return false
	return _rect_ok(world, frame, obs)
