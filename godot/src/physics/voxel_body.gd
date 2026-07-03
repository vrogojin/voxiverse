class_name VoxelBody
extends RigidBody3D
## A physical, breakable cluster of voxel blocks (the physics sandbox's building
## block — the wooden pillars are made of these).
##
## A VoxelBody owns a set of local voxel cells (`cells`: Vector3i -> true) where
## cell `c` occupies the unit cube [c, c+1] in body-LOCAL space. From that set it
## builds, in `_rebuild()`:
##   * a MeshInstance3D of only the EXPOSED faces (a face is drawn when the
##     neighbouring cell is empty), textured with the wood material, and
##   * one BoxShape3D collider per cell, so the cluster collides blockily with the
##     ground and with other bodies, and
##   * a mass proportional to the block count.
##
## Breaking (`break_cell`) removes one cell, then recomputes the CONNECTED
## COMPONENTS of what remains: if the cluster fell into several disconnected
## pieces, each piece becomes its own independent VoxelBody. This is the
## "detach / split one mesh into several separate meshes" behaviour — the piece
## that is no longer resting on the ground drops and tumbles under gravity and can
## be pushed around; a piece still sitting on the ground stays put.
##
## FREEZE model: a pristine, untouched pillar spawns FROZEN (freeze_mode = STATIC)
## so thin stacks stand perfectly still instead of toppling on spawn. The first
## break "activates" the affected pieces: any component that has lost contact with
## the ground unfreezes and becomes fully dynamic. Once a body is dynamic it stays
## dynamic (so it remains pushable) — only never-disturbed pillars are frozen.

const BLOCK_MASS := 12.0          # kg per voxel block (shared contract w/ player push_force)

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
const DYN_FRICTION := 0.5         # wood-on-ground grip (rest, yet still pushable @1200N)
const DYN_BOUNCE := 0.0           # no bouncing on impact

# Collision layers: 1 = terrain ground, 2 = voxel bodies, 4 = player capsule.
const LAYER_BODY := 1 << 1        # this body lives on layer 2
const MASK_BODY := (1 << 0) | (1 << 1) | (1 << 2)   # collide w/ ground+bodies+player

var cells: Dictionary = {}        # Vector3i -> true (body-local voxel coords)
var material: StandardMaterial3D
var world: WorldManager           # for the ground-contact (grounded) test
var activated: bool = false       # false = pristine frozen pillar; true = dynamic
# True only for wood pillars (and the pieces they break into). Gates the wood-tint
# variant swap: a spawn_loose body carries an explicit material (e.g. grass ground)
# and must KEEP it — it is never re-tinted. Only wood_pillar bodies claim variants.
var wood_pillar: bool = false

# Distinct wood tint per dynamic body so adjacent loose pieces (and loose vs.
# untouched pillars) read as separate objects. Deterministic: each dynamic body
# claims the next index. Frozen pristine pillars never touch this.
static var _variant_counter: int = 0

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

## Spawn a vertical pillar of `height` wooden blocks at world column (wx, wz) with
## its base block resting on top of the ground at `base_y`. Returns the body.
static func spawn_pillar(parent: Node, wx: int, wz: int, base_y: float,
		height: int, world_ref: WorldManager) -> VoxelBody:
	var b := VoxelBody.new()
	b.material = WoodMaterial.build()
	b.wood_pillar = true              # eligible for the per-piece wood-tint variants
	b.world = world_ref
	for k in height:
		b.cells[Vector3i(0, k, 0)] = true
	parent.add_child(b)
	b.global_position = Vector3(float(wx), base_y, float(wz))
	b._rebuild()
	return b

## Spawn an already-dynamic loose body whose LOCAL cells are the given world cells,
## at identity transform — so the blocks render exactly where they sat in the world
## and then fall (used for terrain collapse). The passed `material` is used AS-IS:
## these are typically grass ground blocks and must NOT be re-tinted to wood, so the
## body is left non-wood (wood_pillar = false) and never claims a tint variant.
## Returns null for an empty cell list.
static func spawn_loose(parent: Node, world_cells: Array,
		material: StandardMaterial3D, world_ref: WorldManager) -> VoxelBody:
	if world_cells.is_empty():
		return null
	var b := VoxelBody.new()
	b.material = material              # keep the caller's material verbatim (no wood tint)
	b.wood_pillar = false             # ineligible for wood-tint variants
	b.world = world_ref
	for c: Vector3i in world_cells:
		b.cells[c] = true
	b.activated = true                # born dynamic: _rebuild() unfreezes + applies props
	parent.add_child(b)
	b.global_transform = Transform3D.IDENTITY   # local cells == world cells
	b._rebuild()                      # sets freeze = false (activated) + dynamic props
	b.sleeping = false                # wake so it falls immediately
	return b

## Break the voxel at body-local `cell`. Removes it, then splits the remaining
## cluster into connected components, spawning detached pieces as their own bodies.
func break_cell(cell: Vector3i) -> void:
	if not cells.has(cell):
		return
	cells.erase(cell)
	if cells.is_empty():
		queue_free()
		return

	var comps := _components()
	if comps.size() == 1:
		cells = comps[0]
		if not activated and not _grounded(cells):
			_activate_self()          # lost its footing -> it must fall
		_rebuild()
		_wake_if_dynamic()
		return

	# Multiple pieces. Decide which component this body keeps; the rest detach.
	var keep := _choose_keep(comps)
	var lin := linear_velocity
	var ang := angular_velocity
	for i in comps.size():
		if i == keep:
			continue
		_spawn_detached(comps[i], lin, ang)

	cells = comps[keep]
	if not activated and not _grounded(cells):
		_activate_self()
	_rebuild()
	_wake_if_dynamic()

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

# --- internals -----------------------------------------------------------------

func _wake_if_dynamic() -> void:
	if activated:
		sleeping = false

## Transition THIS body from pristine-frozen to dynamic: it lost contact with the
## ground and must fall. A wood pillar gets a distinct tint (so it reads as a loose
## piece, not a standing pillar) before the caller's _rebuild() applies the material;
## a non-wood body (e.g. a spawn_loose ground block) keeps its given material.
func _activate_self() -> void:
	activated = true
	if wood_pillar:                   # only wood pillars re-tint; loose bodies keep theirs
		material = _next_variant_material()

## Claim the next deterministic wood tint. Cheap, no randomness — each dynamic
## body gets its own index so adjacent loose pieces differ visibly.
func _next_variant_material() -> StandardMaterial3D:
	var idx := _variant_counter
	_variant_counter += 1
	return WoodMaterial.build_variant(idx)

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
## trimesh ground at impact). Harmless to set on a frozen pillar (inert while
## frozen), so it is keyed on `activated` and left off untouched pillars.
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

## Which component this body retains. A pristine pillar keeps the piece still
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

func _spawn_detached(comp: Dictionary, lin: Vector3, ang: Vector3) -> void:
	var nb := VoxelBody.new()
	nb.world = world
	nb.cells = comp
	nb.activated = true                # detached pieces are always dynamic
	nb.wood_pillar = wood_pillar       # inherit tint-eligibility from the parent cluster
	# A wood piece gets a distinct tint so it reads as separate from its neighbours and
	# the untouched pillars; a non-wood (loose) piece keeps the parent's exact material.
	# Assigned BEFORE _rebuild() so the mesh shows it (dynamic damping/material/ccd are
	# likewise applied inside _rebuild).
	nb.material = _next_variant_material() if wood_pillar else material
	get_parent().add_child(nb)
	nb.global_transform = global_transform
	nb._rebuild()
	nb.freeze = false
	nb.linear_velocity = lin
	# Only inherit spin from a parent that was ALREADY moving. Detaching from a
	# frozen pristine pillar must NOT induce spin, else the piece topples in a
	# random direction instead of dropping onto its flat base.
	nb.angular_velocity = ang if activated else Vector3.ZERO
	nb.sleeping = false

## Connected components of `cells` under 6-neighbour adjacency.
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
			comp[c] = true
			for d in _DIRS:
				var nc: Vector3i = c + d
				if cells.has(nc) and not seen.has(nc):
					seen[nc] = true
					stack.append(nc)
		comps.append(comp)
	return comps

## True when any cell of `comp` is resting on (or below) the terrain surface, in
## the body's CURRENT world orientation. Used only while the body is still a
## pristine frozen pillar, so the orientation is upright and the test is exact.
func _grounded(comp: Dictionary) -> bool:
	if world == null:
		return true
	for c: Vector3i in comp.keys():
		var wp := global_transform * Vector3(c.x + 0.5, float(c.y), c.z + 0.5)
		if wp.y <= world.surface_y(wp.x, wp.z) + 0.2:
			return true
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

	# Exposed-face mesh.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for c: Vector3i in cells.keys():
		for d in _DIRS:
			if not cells.has(c + d):
				_emit_face(st, c, d)
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	if mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, material)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)

	# One box collider per cell.
	for c: Vector3i in cells.keys():
		var shape := BoxShape3D.new()
		shape.size = Vector3(1, 1, 1)
		var cs := CollisionShape3D.new()
		cs.shape = shape
		cs.position = Vector3(c.x + 0.5, c.y + 0.5, c.z + 0.5)
		add_child(cs)

	mass = maxf(1.0, float(cells.size()) * BLOCK_MASS)
	freeze = not activated
	_apply_dynamic_props()      # damping / friction / ccd for dynamic pieces

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
