class_name VoxelBody
extends RigidBody3D
## A physical, breakable cluster of voxel blocks (the physics sandbox / detached
## terrain chunks — chopped tree trunks+canopies and collapsed soil become these).
##
## A VoxelBody owns a set of local voxel cells (`cells`: Vector3i -> int block_id)
## where cell `c` occupies the unit cube [c, c+1] in body-LOCAL space. From that
## set it builds, in `_rebuild()`:
##   * a MeshInstance3D of only the EXPOSED faces (a face is drawn when the
##     neighbouring cell is empty), one surface per distinct block id, each
##     surface textured with `BlockMaterials.get_for(id)` — wood is NEVER
##     recolored, and
##   * one BoxShape3D collider per cell, so the cluster collides blockily with the
##     ground and with other bodies, and
##   * a mass = sum of `BlockCatalog.mass_of(id)` over its cells.
##
## Breaking (`break_cell`) removes one cell, then recomputes the CONNECTED
## COMPONENTS of what remains: if the cluster fell into several disconnected
## pieces, each piece becomes its own independent VoxelBody, carrying its cells'
## ids. This is the "detach / split one mesh into several separate meshes"
## behaviour — the piece that is no longer resting on the ground drops and can be
## pushed around; a piece still sitting on the ground stays put.
##
## FREEZE model:
##   * A pristine, untouched cluster spawns FROZEN (freeze_mode = STATIC) so thin
##     stacks stand perfectly still instead of toppling on spawn. The first break
##     "activates" any component that has lost ground contact — it unfreezes and
##     becomes fully dynamic.
##   * SANDBOX vs GROUND (§12): a body is "sandbox-dynamic" iff it contains at
##     least one WOOD cell (chopped trunks/canopies stay pushable — the fun
##     sandbox). Every other body (pure grass/dirt/stone, or leaf-only) is a
##     "ground body". A ground body still spawns dynamic and still takes the
##     detach kick, but once it is grounded AND nearly at rest it RE-FREEZES to
##     STATIC (`_physics_process`) so a single soil block can be jumped on or
##     shoved without moving or tipping. If a frozen ground body later loses its
##     support (a neighbour is dug out) it unfreezes and falls again. The one
##     predicate `_grounded()` is authoritative both ways. Wood bodies never
##     auto-freeze.

# A slight, mass-independent momentum given to every piece that detaches because
# of a break with a finite breaker position — "the block hops away from you as
# you knock it loose". A velocity ADD (not an impulse) so a 21-cell canopy and a
# 1-cell chip both drift at the same gentle ~1.2 m/s.
const DETACH_KICK_SPEED := 1.2         # m/s

# A ground body counts as "at rest" (and re-freezes) below these thresholds.
const SETTLE_LINEAR := 0.15            # m/s
const SETTLE_ANGULAR := 0.15           # rad/s
const SUPPORT_PROBE := 0.25            # m: downward ray length under a body's underside

# Dynamics for detached (activated) pieces — see _apply_dynamic_props().
# Angular damping scales with block count so a heavier cluster resists flipping far
# more than a light one: the player leans ~700 N down on a piece it stands on, which
# torques a small piece over — a large slab must shrug that off. Curve (per cell n):
#   angular_damp = min(BASE + PER_CELL*(n-1), MAX)
#   n=1 -> 4.0 (a lone block can still be tipped/pushed), n=4 -> 11.5,
#   n=8 -> 21.5, n>=9 -> 24.0 (a broad slab is effectively unflippable under load).
const DYN_ANGULAR_DAMP := 4.0          # base: a single detached block (still tippable)
const DYN_ANGULAR_DAMP_PER_CELL := 2.5 # extra angular damp added per additional block
const DYN_ANGULAR_DAMP_MAX := 24.0     # clamp: an 8+ block slab stops flipping under load
const DYN_LINEAR_DAMP := 0.1      # gentle: settle without floating
const DYN_FRICTION := 0.5         # on-ground grip (rest, yet still pushable @1200N)
const DYN_BOUNCE := 0.0           # no bouncing on impact

# Collision layers: 1 = terrain ground, 2 = voxel bodies, 4 = player capsule.
const LAYER_BODY := 1 << 1        # this body lives on layer 2
const MASK_BODY := (1 << 0) | (1 << 1) | (1 << 2)   # collide w/ ground+bodies+player

var cells: Dictionary = {}        # Vector3i -> int PACKED cell value (body-local coords)
var world: WorldManager           # for the ground-contact (grounded) test
var activated: bool = false       # false = pristine frozen cluster; true = dynamic
var _is_wood := false             # cached _has_wood() — wood is sandbox-dynamic (Godot sleep/wake)

# Shared, no-bounce, medium-friction physics material for dynamic pieces. Built
# once and reused (RigidBody3D shares it freely — it is immutable here).
static var _dyn_phys_mat: PhysicsMaterial

# The 6 axis neighbours, reused by meshing and the connectivity flood-fill.
const _DIRS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

func _init() -> void:
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	freeze = true
	can_sleep = true
	collision_layer = LAYER_BODY
	collision_mask = MASK_BODY

## Spawn an already-dynamic loose body whose LOCAL cells are the given WORLD cells
## (identity transform, so the blocks render exactly where they sat in the world
## and then fall — used for terrain collapse and chopped canopies). Visual
## materials and mass are resolved internally from the per-cell ids. If
## `kick_from` is finite the new body gets a slight momentum away from it.
## Returns null for an empty dictionary.
static func spawn_loose(parent: Node, cell_ids: Dictionary,
		world_ref: WorldManager, kick_from: Vector3 = Vector3.INF) -> VoxelBody:
	if cell_ids.is_empty():
		return null
	var b := VoxelBody.new()
	b.world = world_ref
	b.cells = cell_ids.duplicate()    # take our own copy; caller keeps its dict
	b.activated = true                # born dynamic: _rebuild() unfreezes + applies props
	parent.add_child(b)
	b.global_transform = Transform3D.IDENTITY   # local cells == world cells
	b._rebuild()                      # sets freeze = false (activated) + dynamic props
	b.sleeping = false                # wake so it falls immediately
	_apply_kick(b, kick_from)         # slight away-from-breaker momentum (no-op if infinite)
	return b

## Break the voxel at body-local `cell`. Removes it, then splits the remaining
## cluster into connected components, spawning detached pieces as their own
## bodies. If `from_pos` is finite (a real breaker position), every piece that
## DETACHES because of this break — including this body itself if it unfreezes —
## gets a slight velocity kick directly away from `from_pos`.
func break_cell(cell: Vector3i, from_pos: Vector3 = Vector3.INF) -> void:
	if not cells.has(cell):
		return
	var was_frozen := freeze          # captured so a settled/pristine body kicks on unfreeze
	# Disturbance: wake dormant debris resting on/near this body's broken cell (dormant-by-default).
	if world != null:
		world.wake_bodies_near(global_transform * Vector3(cell.x + 0.5, cell.y + 0.5, cell.z + 0.5), 6.0)
	cells.erase(cell)
	if cells.is_empty():
		queue_free()
		return

	var comps := _components()
	if comps.size() == 1:
		cells = comps[0]
		if not activated and not _grounded(cells):
			_activate_self()          # lost its footing -> it must fall
		_rebuild()                    # activated bodies unfreeze here (freeze = not activated)
		_wake_if_dynamic()
		# It "unfroze" if it was frozen and can no longer find the ground -> kick it away.
		if was_frozen and not _grounded(cells):
			_apply_kick(self, from_pos)
		return

	# Multiple pieces. Decide which component this body keeps; the rest detach.
	var keep := _choose_keep(comps)
	var lin := linear_velocity
	var ang := angular_velocity
	for i in comps.size():
		if i == keep:
			continue
		_spawn_detached(comps[i], lin, ang, from_pos)   # each detached piece is kicked

	cells = comps[keep]
	if not activated and not _grounded(cells):
		_activate_self()
	_rebuild()
	_wake_if_dynamic()
	if was_frozen and not _grounded(cells):
		_apply_kick(self, from_pos)

## Material id at body-local `cell`; 0 (AIR) if the body has no such cell. Cells
## store packed values (a bare id is plain), so we project the material out.
func cell_block_id(cell: Vector3i) -> int:
	return CellCodec.mat(cells.get(cell, 0))

## Map a world-space ray hit (position + surface normal) to the body-local cell
## that was struck, so a click can break exactly the block the player pointed at.
func cell_at_hit(hit_pos: Vector3, hit_normal: Vector3) -> Vector3i:
	var inv := global_transform.affine_inverse()
	var p_local := inv * hit_pos
	var n_local := (global_transform.basis.inverse() * hit_normal).normalized()
	var probe := p_local - n_local * 0.5     # step just inside the struck face
	var c := Vector3i(floori(probe.x), floori(probe.y), floori(probe.z))
	if cells.has(c):
		return c
	# Fallback: nearest owned cell to the hit point (handles grazing hits).
	return _nearest_cell(p_local)

func block_count() -> int:
	return cells.size()

# --- settle / freeze / dormancy (§12; DORMANT-BY-DEFAULT PHYSICS) ----------------
# The world holds MANY persistent physical objects, so physics is dormant-by-default and active
# only on disturbance. A dropping GROUND body freezes to STATIC once it lands + stops (dormant,
# immovable furniture) and DISABLES its own _physics_process → ZERO per-frame script cost. A WOOD
# body is sandbox-dynamic (Godot can_sleep sleeps it at rest; contact/push auto-wakes it) and also
# runs no _physics_process. A dormant body reactivates via wake() — driven by WorldManager.
# wake_bodies_near() on any nearby terrain/body edit (break/collapse/place) and by break_cell —
# then re-simulates and re-settles. The collider gate counts only AWAKE bodies (is_awake), so a
# pile of settled debris near the player costs nothing.

## Ground bodies re-freeze once at rest so they can be jumped on / shoved without moving or
## tipping. Runs ONLY for a dynamic (dropping) ground body — _refresh_dormancy() keeps
## _physics_process OFF for wood, frozen and pristine bodies, so dormant debris is free.
func _physics_process(_delta: float) -> void:
	if not activated or _is_wood or freeze:
		return                                       # defensive; _physics_process is off in these states
	# Dynamic ground body: freeze once it has landed and stopped → dormant (zero per-frame cost).
	if _grounded(cells) \
			and linear_velocity.length() < SETTLE_LINEAR \
			and angular_velocity.length() < SETTLE_ANGULAR:
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		freeze = true
		set_physics_process(false)                   # DORMANT: no more per-frame script work

## Reactivate a dormant body on disturbance: unfreeze → dynamic → re-enable the settle loop, so it
## falls if it lost support or re-settles (+re-freezes) if still supported. Wood just clears the
## Godot sleep. Idempotent and cheap. Called by WorldManager.wake_bodies_near / break_cell.
func wake() -> void:
	if _is_wood:
		sleeping = false
		return
	activated = true
	freeze = false
	sleeping = false
	set_physics_process(true)

## AWAKE = simulating (dynamic and not asleep). The collider gate counts only awake bodies, so
## frozen ground debris and sleeping wood are dormant and keep the collider idle.
func is_awake() -> bool:
	return not freeze and not sleeping

## Enable per-frame settle logic ONLY for a dynamic (dropping) ground body; wood, a frozen
## (dormant) ground body, and a pristine cluster do ZERO per-frame script work.
func _refresh_dormancy() -> void:
	set_physics_process(activated and not _is_wood and not freeze)

## True iff this cluster contains at least one WOOD cell -> sandbox-dynamic (never auto-freezes).
## Everything else is a ground body. Cached into `_is_wood` at _rebuild (avoids a per-frame scan).
func _has_wood() -> bool:
	for c: Vector3i in cells.keys():
		if CellCodec.mat(cells[c]) == BlockCatalog.WOOD:
			return true
	return false

# --- internals -----------------------------------------------------------------

func _wake_if_dynamic() -> void:
	if activated:
		sleeping = false

## Transition THIS body from pristine-frozen to dynamic: it lost contact with the
## ground and must fall.
func _activate_self() -> void:
	activated = true

## Mean of the body-local cell centres (used to aim the detach kick away from the
## breaker). Body-local; transform with `global_transform` for a world point.
func _cells_center() -> Vector3:
	var sum := Vector3.ZERO
	for c: Vector3i in cells.keys():
		sum += Vector3(c.x + 0.5, c.y + 0.5, c.z + 0.5)
	return sum / float(maxi(1, cells.size()))

## Give `body` a slight velocity directly away from `from_pos` (a velocity ADD, so
## the push is uniform across masses). No-op when `from_pos` is not finite.
static func _apply_kick(body: VoxelBody, from_pos: Vector3) -> void:
	if not from_pos.is_finite():
		return
	if not body.is_inside_tree():     # transform not live yet; skip (kick needs it)
		return
	var center := body.global_transform * body._cells_center()
	var dir := center - from_pos
	if dir.length() < 0.001:
		dir = Vector3.UP
	body.linear_velocity += dir.normalized() * DETACH_KICK_SPEED

## Shared physics material for dynamic pieces: some friction so they come to rest
## (yet a 1200 N push still shifts small piles), and zero bounce.
static func _dyn_physics_material() -> PhysicsMaterial:
	if _dyn_phys_mat == null:
		var pm := PhysicsMaterial.new()
		pm.friction = DYN_FRICTION
		pm.bounce = DYN_BOUNCE
		_dyn_phys_mat = pm
	return _dyn_phys_mat

## Apply the falling/settling dynamics to a dynamic body: strong angular damping
## (drop straight, no chaotic toppling), light linear damping, no-bounce friction
## material, and continuous collision detection (no tunnelling/jitter through the
## trimesh ground at impact). Harmless to set on a frozen body (inert while
## frozen), so it is keyed on `activated`.
func _apply_dynamic_props() -> void:
	if not activated:
		return
	# Flip resistance scales with block count (see the DYN_ANGULAR_DAMP_* constants):
	# a lone block stays tippable/pushable, while a large slab barely rotates under the
	# player's downward lean, so it can be stood on without tipping or running away.
	var n := cells.size()
	angular_damp = minf(DYN_ANGULAR_DAMP + DYN_ANGULAR_DAMP_PER_CELL * float(n - 1),
			DYN_ANGULAR_DAMP_MAX)
	linear_damp = DYN_LINEAR_DAMP
	# AUTO center of mass: it settles low and broad for wide/flat clusters, which is
	# naturally stable and reinforces the angular-damp-based flip resistance.
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_AUTO
	physics_material_override = _dyn_physics_material()
	continuous_cd = true

## Which component this body retains. A pristine cluster keeps the piece still
## resting on the ground (it stays frozen); a body that is already dynamic keeps
## its largest piece (identity/least churn) and lets the rest fly off.
func _choose_keep(comps: Array) -> int:
	if not activated:
		for i in comps.size():
			if _grounded(comps[i]):
				return i
		return 0
	var best_i := 0
	var best_n := -1
	for i in comps.size():
		var n: int = (comps[i] as Dictionary).size()
		if n > best_n:
			best_n = n
			best_i = i
	return best_i

func _spawn_detached(comp: Dictionary, lin: Vector3, ang: Vector3, from_pos: Vector3) -> void:
	var nb := VoxelBody.new()
	nb.world = world
	nb.cells = comp                    # carries the detached cells' ids
	nb.activated = true                # detached pieces are always dynamic
	get_parent().add_child(nb)
	nb.global_transform = global_transform
	nb._rebuild()
	nb.freeze = false
	nb.linear_velocity = lin
	# Only inherit spin from a parent that was ALREADY moving. Detaching from a
	# frozen pristine cluster must NOT induce spin, else the piece topples in a
	# random direction instead of dropping onto its flat base.
	nb.angular_velocity = ang if activated else Vector3.ZERO
	nb.sleeping = false
	_apply_kick(nb, from_pos)          # slight away-from-breaker momentum

## Connected components of `cells` under 6-neighbour adjacency. Each returned
## Dictionary carries the same Vector3i -> int block_id entries as `cells`.
func _components() -> Array:
	var comps: Array = []
	var seen: Dictionary = {}
	for start: Vector3i in cells.keys():
		if seen.has(start):
			continue
		var comp: Dictionary = {}
		var stack: Array[Vector3i] = [start]
		seen[start] = true
		while not stack.is_empty():
			var c: Vector3i = stack.pop_back()
			comp[c] = cells[c]            # carry the id through the split
			for d in _DIRS:
				var nc: Vector3i = c + d
				if cells.has(nc) and not seen.has(nc):
					seen[nc] = true
					stack.append(nc)
		comps.append(comp)
	return comps

## True when any cell of `comp` is resting on (or below) the terrain surface, in
## the body's CURRENT world orientation. The one predicate that governs both
## re-freezing (settle) and un-freezing (support broken) for ground bodies.
func _grounded(comp: Dictionary) -> bool:
	if world == null:
		return true
	# Fast analytic check: any cell at/below the terrain heightmap surface.
	for c: Vector3i in comp.keys():
		var wp := global_transform * Vector3(c.x + 0.5, float(c.y), c.z + 0.5)
		if wp.y <= world.surface_y(wp.x, wp.z) + 0.2:
			return true
	# Otherwise: resting on a STABLE support — the static ground collider (which
	# also carries trees & placed blocks) or another already-frozen VoxelBody. This
	# lets soil-on-soil stacks and blocks resting on a placed tower settle too. A
	# support that is itself a still-moving (unfrozen) body does NOT count, so a
	# stack settles bottom-up instead of an upper block freezing mid-air.
	return _resting_on_support(comp)

## Downward physics probe under the body's exposed underside cells: true iff it
## rests on the static ground collider or a frozen body.
func _resting_on_support(comp: Dictionary) -> bool:
	if not is_inside_tree():
		return false
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	for c: Vector3i in comp.keys():
		# Only cells with no body cell directly beneath them have an exposed underside.
		if comp.has(Vector3i(c.x, c.y - 1, c.z)):
			continue
		var base := global_transform * Vector3(c.x + 0.5, float(c.y), c.z + 0.5)
		var q := PhysicsRayQueryParameters3D.create(
			base + Vector3(0.0, 0.05, 0.0),
			base - Vector3(0.0, SUPPORT_PROBE, 0.0),
			(1 << 0) | (1 << 1))          # ground layer + body layer (never the player)
		q.exclude = [get_rid()]
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var col: Object = hit.get("collider")
		if col is VoxelBody:
			if (col as VoxelBody).freeze:   # a settled block is a stable floor
				return true
		else:
			return true                     # static ground collider (terrain/trees/placed)
	return false

func _nearest_cell(p_local: Vector3) -> Vector3i:
	var best := Vector3i.ZERO
	var best_d := INF
	for c: Vector3i in cells.keys():
		var center := Vector3(c.x + 0.5, c.y + 0.5, c.z + 0.5)
		var d := center.distance_squared_to(p_local)
		if d < best_d:
			best_d = d
			best = c
	return best

## Rebuild mesh + colliders + mass from `cells`, and apply the freeze state.
func _rebuild() -> void:
	for child in get_children():
		if child is MeshInstance3D or child is CollisionShape3D:
			child.queue_free()

	# Exposed-face mesh, grouped by block id -> one surface (and one material) per
	# distinct id present. Different-id neighbours share no face (opaque blocks),
	# so the interior-face rule is unchanged.
	var mesh := ArrayMesh.new()
	var tools: Dictionary = {}          # int block_id -> SurfaceTool
	for c: Vector3i in cells.keys():
		var packed: int = cells[c]
		var id: int = CellCodec.mat(packed)   # surfaces group by MATERIAL
		var modifier: int = CellCodec.modifier(packed)
		if modifier != 0:
			# Shaped cell: emit its partial geometry from the shared ShapeMesh (SVS §4.3)
			# so a broken ramp keeps its ramp faces. No interior-face culling (cosmetic).
			_emit_shape(_tool_for_body(tools, id), c, modifier)
		else:
			for d in _DIRS:
				if not cells.has(c + d):
					_emit_face(_tool_for_body(tools, id), c, d)
	for id: int in tools.keys():
		var st: SurfaceTool = tools[id]
		var surf_index := mesh.get_surface_count()
		st.commit(mesh)
		if mesh.get_surface_count() > surf_index:
			mesh.surface_set_material(surf_index, BlockMaterials.get_for(id))
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)

	# One collider per cell: a box for a full cube; for a shaped cell, ≤ 2 convex prisms
	# (each top triangle extruded to the anchor face — always convex; SVS §4.3), so a
	# loose ramp collides on its true slope, not a phantom cube.
	for c: Vector3i in cells.keys():
		var modifier: int = CellCodec.modifier(cells[c])
		if modifier != 0:
			_add_prism_colliders(c, modifier)
		else:
			var shape := BoxShape3D.new()
			shape.size = Vector3(1, 1, 1)
			var cs := CollisionShape3D.new()
			cs.shape = shape
			cs.position = Vector3(c.x + 0.5, c.y + 0.5, c.z + 0.5)
			add_child(cs)

	# Mass = Σ density × fill-fraction (SVS §6): a detached half-ramp of stone weighs
	# 375 kg, not 1500. Full cubes reduce to the catalog mass exactly. Floor at 1 kg.
	var m := 0.0
	for c: Vector3i in cells.keys():
		m += BlockCatalog.mass_of_value(cells[c])
	mass = maxf(1.0, m)
	freeze = not activated
	_apply_dynamic_props()      # damping / friction / ccd for dynamic pieces
	_is_wood = _has_wood()      # cache once (avoids a per-frame cell scan in the settle loop)
	_refresh_dormancy()         # dormant bodies run NO _physics_process

## Lazily begin (once) and return the SurfaceTool for material `id`.
func _tool_for_body(tools: Dictionary, id: int) -> SurfaceTool:
	var st: SurfaceTool = tools.get(id, null)
	if st == null:
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		tools[id] = st
	return st

## Emit a shaped cell's full ShapeMesh geometry (body-local, translated to `c`) into
## the material SurfaceTool — the shared render seam (SVS §4), so a loose ramp shows
## the same faces as the world ramp did.
func _emit_shape(st: SurfaceTool, c: Vector3i, modifier: int) -> void:
	var geom := ShapeMesh.build(modifier)
	var verts: PackedVector3Array = geom["verts"]
	var normals: PackedVector3Array = geom["normals"]
	var uvs: PackedVector2Array = geom["uvs"]
	var indices: PackedInt32Array = geom["indices"]
	var base := Vector3(c)
	for i in indices:
		st.set_normal(normals[i])
		st.set_uv(uvs[i])
		st.add_vertex(base + verts[i])

## Add ≤ 2 convex prism colliders for a shaped cell (SVS §4.3): each surface triangle
## extruded down to the anchor face (BOTTOM: y=0; TOP: y=1) is a convex triangular
## prism. A degenerate triangle (all corners flush with the anchor plane — zero volume)
## is skipped. Points are body-local (cells are body-local), so the shape's transform
## is identity.
func _add_prism_colliders(c: Vector3i, modifier: int) -> void:
	var base_y := 0.0 if ShapeCodec.anchor(modifier) == ShapeCodec.ANCHOR_BOTTOM else 1.0
	var origin := Vector3(c)
	for tri: Dictionary in ShapeCodec.surface_tris(modifier):
		var pts := PackedVector3Array()
		var nondegen := false
		for key in ["v0", "v1", "v2"]:
			var sp: Vector3 = tri[key]
			if absf(sp.y - base_y) > 1e-4:
				nondegen = true
			pts.append(origin + sp)
			pts.append(origin + Vector3(sp.x, base_y, sp.z))
		if not nondegen:
			continue
		var shape := ConvexPolygonShape3D.new()
		shape.points = pts
		var cs := CollisionShape3D.new()
		cs.shape = shape
		add_child(cs)

## Emit the exposed face of cell `c` on side `d` (unit metre quad, one texture
## tile). Double-sided material makes winding irrelevant.
func _emit_face(st: SurfaceTool, c: Vector3i, d: Vector3i) -> void:
	var o := Vector3(c)
	var v: Array[Vector3]
	if d.x > 0:
		v = [o + Vector3(1, 0, 0), o + Vector3(1, 1, 0), o + Vector3(1, 1, 1), o + Vector3(1, 0, 1)]
	elif d.x < 0:
		v = [o + Vector3(0, 0, 1), o + Vector3(0, 1, 1), o + Vector3(0, 1, 0), o + Vector3(0, 0, 0)]
	elif d.y > 0:
		v = [o + Vector3(0, 1, 0), o + Vector3(0, 1, 1), o + Vector3(1, 1, 1), o + Vector3(1, 1, 0)]
	elif d.y < 0:
		v = [o + Vector3(0, 0, 1), o + Vector3(0, 0, 0), o + Vector3(1, 0, 0), o + Vector3(1, 0, 1)]
	elif d.z > 0:
		v = [o + Vector3(0, 0, 1), o + Vector3(1, 0, 1), o + Vector3(1, 1, 1), o + Vector3(0, 1, 1)]
	else:
		v = [o + Vector3(0, 0, 0), o + Vector3(0, 1, 0), o + Vector3(1, 1, 0), o + Vector3(1, 0, 0)]
	var n := Vector3(d)
	var uv := [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)]
	st.set_normal(n); st.set_uv(uv[0]); st.add_vertex(v[0])
	st.set_normal(n); st.set_uv(uv[1]); st.add_vertex(v[1])
	st.set_normal(n); st.set_uv(uv[2]); st.add_vertex(v[2])
	st.set_normal(n); st.set_uv(uv[0]); st.add_vertex(v[0])
	st.set_normal(n); st.set_uv(uv[2]); st.add_vertex(v[2])
	st.set_normal(n); st.set_uv(uv[3]); st.add_vertex(v[3])
