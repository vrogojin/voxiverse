class_name StructuralSolver
extends RefCounted
## The bounded, event-driven structural-integrity solver (STRUCTURAL-INTEGRITY §5).
## Replaces WorldManager's pure-connectivity collapse with a real lower-bound limit
## analysis: it decides which solid cells of an arbitrary structure stay put and
## which detach as VoxelBody debris, by routing every cell's weight to the
## foundation through a network of load paths (compression down, tension up, shear
## sideways) that stay within per-material capacity.
##
## PATH-AGNOSTIC (SI §1): reads cells ONLY via `world.cell_solid`/`cell_value_at`
## (architectural rule 1) and temperatures ONLY via `world.environment` (rule 2), so
## it is identical for the godot_voxel and GDScript render paths. It never touches
## geometry. `solve()` returns the SET of cells to detach/crumble; WorldManager owns
## the carving, `_paint_cell`, ground-collider rebuild and VoxelBody.spawn_loose.
##
## FOUR PASSES (SI §5). Pass 0 is today's connectivity flood — bit-for-bit, so the
## tree-chop canopy detach cannot regress; if it reaches everything AND pass 1 finds
## no overload, the solve ends there (flat digging stays O(region), same as today).
## Only when pass 1 flags a non-column-supported or overloaded cell does the Dinic
## max-flow (pass 2) and moment audit (pass 3) run, over the affected structure only.

const RADIUS := 5                    # base collapse box half-extent (matches WorldManager)
const MAX_FLOW_CELLS := 4096         # hard cap: above this, degrade to connectivity only
const MAX_EDIT_FLOOD := 4096         # adaptive-region placed-component flood cap
const INF_CAP := StructuralModel.INF_CAP

const NB6: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
const LAT4: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

## THE entry point (SI §5). Returns Vector3i -> true, the set of solid cells that
## must detach or crumble (crushed cells are included: they "crumble" and join the
## falling cluster). WorldManager groups this set into 6-connected components and
## spawns each as one VoxelBody, exactly as the old collapse did.
static func solve(world: Object, center: Vector3i) -> Dictionary:
	var reg := _region(world, center)
	var x0: int = reg.x0
	var x1: int = reg.x1
	var z0: int = reg.z0
	var z1: int = reg.z1
	var y_lo: int = reg.y_lo
	var y_hi: int = reg.y_hi

	# 1) Solid cells + per-column vertical support.
	var solid := {}
	for xi in range(x0, x1 + 1):
		for zi in range(z0, z1 + 1):
			for y in range(y_lo, y_hi + 1):
				var c := Vector3i(xi, y, zi)
				if world.cell_solid(c):
					solid[c] = true

	# column_supported: an unbroken solid chain from the cell straight down to the
	# bottom row (the deep bulk). Feeds N_lat bracing and the pass-1 fast path.
	var col_sup := {}
	for xi in range(x0, x1 + 1):
		for zi in range(z0, z1 + 1):
			var below_sup := false
			for y in range(y_lo, y_hi + 1):
				var c := Vector3i(xi, y, zi)
				if not solid.has(c):
					below_sup = false
					continue
				var cs := (y == y_lo) or below_sup
				if cs:
					col_sup[c] = true
				below_sup = cs

	# 2) Foundation (sink) = region boundary shell + bottom row + confined bulk that
	# is column-supported. Confined pristine bulk (all 6 neighbours solid) has σ_c=∞
	# and routes to the true foundation, so treating it as a sink is exact AND keeps
	# the flow graph to the exposed surface + player builds (deep bulk never enters).
	# Adding confined-col-supported cells as seeds can only ADD reached cells that the
	# bottom-row flood already reached, so pass 0 is byte-identical to today.
	var foundation := {}
	for c in solid:
		var cc: Vector3i = c
		var on_bnd := cc.x == x0 or cc.x == x1 or cc.z == z0 or cc.z == z1
		if on_bnd or cc.y == y_lo:
			foundation[cc] = true
		elif col_sup.has(cc) and _confined(world, cc, solid):
			foundation[cc] = true

	# PASS 0 — connectivity flood (today's, unchanged). Solid cells never reached →
	# floating → detach immediately (this is what detaches a chopped tree's canopy).
	var reached := _flood(solid, foundation, {}, {})
	var falling := {}
	for c in solid:
		if not foundation.has(c) and not reached.has(c):
			falling[c] = true

	if reg.degrade:
		return falling                      # region cap exceeded → connectivity only

	# PASS 1 — column fast path (cheap screen). Flag any REACHED, non-foundation cell
	# that is not column-supported (overhang/hang/bridge) OR whose accumulated column
	# load exceeds its braced σ_c. No flag anywhere → done (the common flat-dig case).
	var scc_cache := {}
	var need_flow := false
	for xi in range(x0, x1 + 1):
		for zi in range(z0, z1 + 1):
			var run_load := 0
			for y in range(y_hi, y_lo - 1, -1):
				var c := Vector3i(xi, y, zi)
				if not solid.has(c):
					run_load = 0
					continue
				if foundation.has(c) or not reached.has(c):
					run_load = 0            # foundation absorbs; floaters are pass-0's job
					continue
				run_load += StructuralModel.weight_int(_mat(world, c))
				if col_sup.has(c):
					if run_load > _sigma_c_eff(world, c, solid, col_sup, scc_cache):
						need_flow = true
				else:
					need_flow = true
			if need_flow:
				break
		if need_flow:
			break

	if not need_flow:
		return falling

	# PASS 2 — flow feasibility (the real load router) + min-cut resolution.
	var add2 := _pass2(world, solid, foundation, col_sup, reached, scc_cache)
	for c in add2:
		falling[c] = true

	# PASS 3 — moment/bending audit of overhang lobes.
	var add3 := _pass3(world, solid, foundation, col_sup, reached, falling)
	for c in add3:
		falling[c] = true

	return falling

# --- region (SI §5.1) -----------------------------------------------------------

static func _region(world: Object, center: Vector3i) -> Dictionary:
	var x0 := center.x - RADIUS
	var x1 := center.x + RADIUS
	var z0 := center.z - RADIUS
	var z1 := center.z + RADIUS
	var max_h := -0x3FFFFFFF
	var y_lo_top := 0x3FFFFFFF
	var placed_hi := -0x40000000
	for xi in range(x0, x1 + 1):
		for zi in range(z0, z1 + 1):
			var h: int = TerrainConfig.height_at(xi, zi)
			max_h = maxi(max_h, h)
			y_lo_top = mini(y_lo_top, h)
			placed_hi = maxi(placed_hi, world.placed_top(xi, zi))
	var y_hi := maxi(max_h + TreeGen.MAX_ABOVE_SURFACE, placed_hi)
	var y_lo := y_lo_top - 2

	# Adaptive expansion: pull in the connected component of PLACED (edited, value>0)
	# cells touching the base box, so player builds larger than the box are seen
	# whole and their own cells never sit on the falsely-supported boundary shell.
	var edits: Dictionary = world.placed_cells()
	var comp := {}
	var stack: Array[Vector3i] = []
	for c in edits:
		var cc: Vector3i = c
		if int(edits[cc]) > 0 and cc.x >= x0 and cc.x <= x1 and cc.z >= z0 and cc.z <= z1 \
				and cc.y >= y_lo and cc.y <= y_hi:
			if not comp.has(cc):
				comp[cc] = true
				stack.append(cc)
	var degrade := false
	while not stack.is_empty():
		if comp.size() > MAX_EDIT_FLOOD:
			degrade = true
			break
		var c: Vector3i = stack.pop_back()
		for d in NB6:
			var nc: Vector3i = c + d
			if int(edits.get(nc, -1)) > 0 and not comp.has(nc):
				comp[nc] = true
				stack.append(nc)
	if not degrade:
		for c in comp:
			var cc: Vector3i = c
			x0 = mini(x0, cc.x - 1)
			x1 = maxi(x1, cc.x + 1)
			z0 = mini(z0, cc.z - 1)
			z1 = maxi(z1, cc.z + 1)
			y_lo = mini(y_lo, cc.y - 1)
			y_hi = maxi(y_hi, cc.y + 1)
	return {"x0": x0, "x1": x1, "z0": z0, "z1": z1, "y_lo": y_lo, "y_hi": y_hi, "degrade": degrade}

# --- pass 2: max-flow feasibility + min-cut (SI §5.4) ---------------------------

static func _pass2(world: Object, solid: Dictionary, foundation: Dictionary,
		col_sup: Dictionary, reached: Dictionary, scc_cache: Dictionary) -> Dictionary:
	var nodes: Array[Vector3i] = []
	var idx := {}
	for c in reached:
		if foundation.has(c):
			continue
		idx[c] = nodes.size()
		nodes.append(c)
	var n := nodes.size()
	if n == 0:
		return {}
	if n > MAX_FLOW_CELLS:
		return {}                           # degrade → connectivity only (never worse)

	var d := Dinic.new(2 * n + 2)
	var src := 2 * n
	var snk := 2 * n + 1
	var total := 0
	for i in n:
		var u: Vector3i = nodes[i]
		var uid := _mat(world, u)
		var w := StructuralModel.weight_int(uid)
		total += w
		d.add_edge(src, 2 * i, w)                                   # source injects own weight
		d.add_edge(2 * i, 2 * i + 1, _sigma_c_eff(world, u, solid, col_sup, scc_cache))  # crush cap
		var umod := CellCodec.modifier(world.cell_value_at(u))
		for dir in NB6:
			var v: Vector3i = u + dir
			var target: int
			if foundation.has(v):
				target = snk
			elif idx.has(v):
				target = 2 * int(idx[v])
			else:
				continue                    # air or a pass-0 floater: no support
			var cap: int
			if dir.y < 0:
				cap = INF_CAP               # compression down (bounded by the bearing node)
			else:
				var vid := _mat(world, v)
				var t := _joint_temp(world, u, v)
				var reinf: int = world.joint_mod(u, v)
				var area := ShapeCodec.contact_area(umod, CellCodec.modifier(world.cell_value_at(v)), _axis(dir))
				if dir.y > 0:
					cap = StructuralModel.joint_ft(uid, vid, t, reinf, area)   # tension up
				else:
					cap = StructuralModel.joint_fs(uid, vid, t, reinf, area)   # shear lateral
			d.add_edge(2 * i + 1, target, cap)

	var flow := d.max_flow(src, snk)
	if flow >= total:
		return {}                           # statically admissible → stable

	# Infeasible: the min-cut is the physically weakest break surface.
	var reach := d.residual_reachable(src)
	var crushed := {}
	var snapped := {}
	for i in n:
		var u: Vector3i = nodes[i]
		if reach[2 * i] == 1 and reach[2 * i + 1] == 0:
			crushed[u] = true               # in→out cut: the cell crushes
		if reach[2 * i + 1] == 1:
			for dir in NB6:
				if dir.y < 0:
					continue                # compression edges are ∞, never in the cut
				var v: Vector3i = u + dir
				var target: int
				if foundation.has(v):
					target = snk
				elif idx.has(v):
					target = 2 * int(idx[v])
				else:
					continue
				if reach[target] == 0:
					snapped[_jkey(u, v)] = true

	# Resolution: re-flood connectivity with the crushed cells + snapped joints
	# removed; every node no longer reaching foundation detaches (SI §5.6).
	var reflood := _flood(solid, foundation, crushed, snapped)
	var result := {}
	for c in crushed:
		result[c] = true
	for c in nodes:
		if not reflood.has(c):
			result[c] = true
	return result

# --- pass 3: moment / bending audit of overhang lobes (SI §5.5) -----------------

static func _pass3(world: Object, solid: Dictionary, foundation: Dictionary,
		col_sup: Dictionary, reached: Dictionary, falling: Dictionary) -> Dictionary:
	var result := {}
	var cand := {}                          # non-column-supported, still-standing cells
	for c in reached:
		if foundation.has(c) or col_sup.has(c) or falling.has(c):
			continue
		cand[c] = true
	var seen := {}
	for start in cand:
		if seen.has(start):
			continue
		var lobe: Array[Vector3i] = []
		var st: Array[Vector3i] = [start]
		seen[start] = true
		while not st.is_empty():
			var c: Vector3i = st.pop_back()
			lobe.append(c)
			for d in NB6:
				var nc: Vector3i = c + d
				if cand.has(nc) and not seen.has(nc):
					seen[nc] = true
					st.append(nc)
		# Interface joints J: lobe cell ↔ a supported neighbour (foundation or a
		# standing column-supported cell) — where the lobe hands its load off.
		var jm: Array = []
		for u in lobe:
			for d in NB6:
				var v: Vector3i = u + d
				if not solid.has(v):
					continue
				if foundation.has(v) or (col_sup.has(v) and not falling.has(v)):
					jm.append([u, v])
		if jm.is_empty():
			continue                        # (a reached lobe always has an interface)
		# Interface centroid (horizontal), lobe centre of mass, worst overturning axis.
		var centroid := Vector2.ZERO
		for j in jm:
			centroid += (_hpos(j[0]) + _hpos(j[1])) * 0.5
		centroid /= float(jm.size())
		var com := Vector2.ZERO
		var wsum := 0.0
		for c in lobe:
			var w := float(StructuralModel.weight_int(_mat(world, c)))
			com += _hpos(c) * w
			wsum += w
		com /= maxf(1.0, wsum)
		var offset := com - centroid
		if offset.length() < 1e-6:
			continue                        # symmetric: no overturning direction
		var axis_dir := offset.normalized()
		var m_g := 0.0
		for c in lobe:
			var w := float(StructuralModel.weight_int(_mat(world, c)))
			m_g += w * (_hpos(c) - centroid).dot(axis_dir)
		m_g = absf(m_g)
		var m_r := 0.0
		for j in jm:
			var u: Vector3i = j[0]
			var v: Vector3i = j[1]
			var jmid := (_hpos(u) + _hpos(v)) * 0.5
			var arm := absf((jmid - centroid).dot(axis_dir))
			var t := _joint_temp(world, u, v)
			var reinf: int = world.joint_mod(u, v)
			m_r += float(StructuralModel.joint_ft(_mat(world, u), _mat(world, v), t, reinf, 1.0)) * arm
			m_r += float(StructuralModel.joint_m0(_mat(world, u), _mat(world, v), t, reinf, 1.0))
		# Slack absorbs float error so the calibrated cantilever (M_g == M_r exactly)
		# survives; a genuine overturning lobe (M_g ≫ M_r) still detaches whole.
		if m_g > m_r * (1.0 + 1e-6) + 1e-6:
			for c in lobe:
				result[c] = true
	return result

# --- shared helpers -------------------------------------------------------------

## Connectivity flood from `seeds` through solid 6-neighbours, skipping excluded
## cells and joints. Used by pass 0 (empty exclusions) and pass 2 resolution.
static func _flood(solid: Dictionary, seeds: Dictionary,
		excl_cells: Dictionary, excl_joints: Dictionary) -> Dictionary:
	var reached := {}
	var stack: Array[Vector3i] = []
	for s in seeds:
		if not excl_cells.has(s):
			reached[s] = true
			stack.append(s)
	while not stack.is_empty():
		var c: Vector3i = stack.pop_back()
		for d in NB6:
			var nc: Vector3i = c + d
			if not solid.has(nc) or reached.has(nc) or excl_cells.has(nc):
				continue
			if excl_joints.has(_jkey(c, nc)):
				continue
			reached[nc] = true
			stack.append(nc)
	return reached

## Effective braced compressive capacity of a node (SI §3), memoised. Confined
## pristine bulk (all 6 neighbours solid) → ∞ (defensive: those are foundation).
static func _sigma_c_eff(world: Object, c: Vector3i, solid: Dictionary,
		col_sup: Dictionary, cache: Dictionary) -> int:
	if cache.has(c):
		return int(cache[c])
	var v: int
	if _confined(world, c, solid):
		v = INF_CAP
	else:
		var n_lat := 0
		for d in LAT4:
			var nc: Vector3i = c + d
			if solid.has(nc) and col_sup.has(nc):
				n_lat += 1
		v = StructuralModel.braced_sigma_c(_mat(world, c), n_lat)
	cache[c] = v
	return v

## True for a pristine (unedited) cell with all 6 neighbours solid — confined bulk.
static func _confined(world: Object, c: Vector3i, _solid: Dictionary) -> bool:
	if world.placed_cells().has(c):
		return false                        # edited (placed) cells are never confined
	for d in NB6:
		if not world.cell_solid(c + d):
			return false
	return true

static func _mat(world: Object, c: Vector3i) -> int:
	return CellCodec.mat(world.cell_value_at(c))

static func _joint_temp(world: Object, u: Vector3i, v: Vector3i) -> float:
	var env: Object = world.environment
	if env == null:
		return PerVoxelEnvironment.T_AIR
	var tu: float = env.temperature(Vector3(u.x + 0.5, u.y + 0.5, u.z + 0.5))
	var tv: float = env.temperature(Vector3(v.x + 0.5, v.y + 0.5, v.z + 0.5))
	return (tu + tv) * 0.5

static func _hpos(c: Vector3i) -> Vector2:
	return Vector2(float(c.x) + 0.5, float(c.z) + 0.5)

static func _axis(dir: Vector3i) -> int:
	if dir.x != 0:
		return 0
	if dir.y != 0:
		return 1
	return 2

## Canonical unordered joint key: the lexicographically-smaller cell + the axis
## (0=x,1=y,2=z). Matches WorldManager's reinforcement key form.
static func _jkey(a: Vector3i, b: Vector3i) -> Vector4i:
	var axis := 0 if a.x != b.x else (1 if a.y != b.y else 2)
	return Vector4i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z), axis)

# --- Dinic max-flow (integer capacities, deterministic) -------------------------

class Dinic:
	extends RefCounted
	var _head: PackedInt32Array
	var _to: PackedInt32Array
	var _next: PackedInt32Array
	var _cap: PackedInt64Array
	var _level: PackedInt32Array
	var _it: PackedInt32Array

	func _init(num_nodes: int) -> void:
		_head = PackedInt32Array()
		_head.resize(num_nodes)
		_head.fill(-1)
		_to = PackedInt32Array()
		_next = PackedInt32Array()
		_cap = PackedInt64Array()
		_level = PackedInt32Array()
		_level.resize(num_nodes)
		_it = PackedInt32Array()
		_it.resize(num_nodes)

	## Directed edge u→v (cap) with a paired 0-capacity reverse edge (v→u). Edges are
	## added in pairs from index 0, so the reverse of edge e is `e ^ 1`.
	func add_edge(u: int, v: int, cap: int) -> void:
		_to.append(v); _cap.append(cap); _next.append(_head[u]); _head[u] = _to.size() - 1
		_to.append(u); _cap.append(0); _next.append(_head[v]); _head[v] = _to.size() - 1

	func _bfs(s: int, t: int) -> bool:
		_level.fill(-1)
		_level[s] = 0
		var q: Array[int] = [s]
		var qi := 0
		while qi < q.size():
			var u: int = q[qi]
			qi += 1
			var e := _head[u]
			while e != -1:
				if _cap[e] > 0 and _level[_to[e]] < 0:
					_level[_to[e]] = _level[u] + 1
					q.append(_to[e])
				e = _next[e]
		return _level[t] >= 0

	func _dfs(u: int, t: int, f: int) -> int:
		if u == t:
			return f
		while _it[u] != -1:
			var e := _it[u]
			var v := _to[e]
			if _cap[e] > 0 and _level[v] == _level[u] + 1:
				var pushed := _dfs(v, t, mini(f, _cap[e]))
				if pushed > 0:
					_cap[e] -= pushed
					_cap[e ^ 1] += pushed
					return pushed
			_it[u] = _next[e]
		return 0

	func max_flow(s: int, t: int) -> int:
		var flow := 0
		while _bfs(s, t):
			_it = _head.duplicate()
			var f := _dfs(s, t, INF_CAP)
			while f > 0:
				flow += f
				f = _dfs(s, t, INF_CAP)
		return flow

	## Nodes reachable from `s` in the residual graph — the source side of the min cut.
	func residual_reachable(s: int) -> PackedInt32Array:
		var reach := PackedInt32Array()
		reach.resize(_head.size())
		reach.fill(0)
		reach[s] = 1
		var q: Array[int] = [s]
		var qi := 0
		while qi < q.size():
			var u: int = q[qi]
			qi += 1
			var e := _head[u]
			while e != -1:
				if _cap[e] > 0 and reach[_to[e]] == 0:
					reach[_to[e]] = 1
					q.append(_to[e])
				e = _next[e]
		return reach
