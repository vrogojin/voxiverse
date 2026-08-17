class_name AgentNav
extends RefCounted
## COSMOS-AGENT-AUTONOMY A3 (docs/COSMOS-AGENT-AUTONOMY-DESIGN.md §6) — a bounded, time-sliced A* over the
## ONE authoritative cell query (WorldManager.cell_solid / block_id_at), the mineflayer-pathfinder/Baritone
## model sized to VOXIVERSE's analytic movement contract + the never-OOM law. Planner ONLY — no node, no
## world writes; every read is the overlay-else-generated truth physics uses, so the plan can never disagree
## with blocked() about what is solid (CLAUDE.md rule 1). Instanced by RemoteControl per `goto`; freed on
## step end. Reachable only under the CONTROL_ENABLED + FP_AGENT_NAV-gated executor ⇒ dead in normal play.
##
## Frame: all cells are ABSOLUTE LATTICE (§3). Only meaningful on one facet interior; the caller caps range
## (NAV_RANGE_MAX) well inside a facet span and bails `reframed` on a crossing.

const UP := Vector3i(0, 1, 0)
const DOWN := Vector3i(0, -1, 0)
const _NEI := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]  # 4-connected (§6.2)

## A cell is passable-clear (2-cell body) and NOT liquid. Liquid = non-air non-solid (water/lava/powder):
## solidity_of<0.5 makes them "clear", so we exclude them explicitly (mineflayer's blocksToAvoid).
static func _is_liquid(world, c: Vector3i) -> bool:
	return world.block_id_at(c) != 0 and not world.cell_solid(c)

## Stand cell: floor under the feet + 2-cell clearance + neither body cell a liquid.
static func _stand(world, c: Vector3i) -> bool:
	if not world.cell_solid(c + DOWN):
		return false
	if world.cell_solid(c) or world.cell_solid(c + UP):
		return false
	if _is_liquid(world, c) or _is_liquid(world, c + UP):
		return false
	return true

## Admissible heuristic: Manhattan XZ + |Δy| (never over-estimates against the move-cost table §6.2).
static func _h(a: Vector3i, b: Vector3i) -> float:
	return float(absi(a.x - b.x) + absi(a.z - b.z) + absi(a.y - b.y))

static func _reached(c: Vector3i, goal: Vector3i, mode: String) -> bool:
	if mode == "adjacent":
		# GoalGetToBlock: stand horizontally adjacent to the target column, roughly level (the skill's
		# aim_cell + break_cell then enforce the real reach). Includes the same column (stand next to a stump).
		return maxi(absi(c.x - goal.x), absi(c.z - goal.z)) <= 1 and absi(c.y - goal.y) <= 2
	return c == goal                                  # "stand": GoalBlock

## One planning slice: expand ≤ budget nodes. `state` carries open/g/parent/closed/result/path between slices
## (the block_box_slice pattern). Returns true when planning is COMPLETE (state.result ∈ ok|no_path), false
## while still working. Never-OOM: expansions capped at NAV_NODE_CAP, range at NAV_RANGE_MAX, path at NAV_PATH_MAX.
func plan_slice(world, from: Vector3i, goal: Vector3i, mode: String, state: Dictionary, budget: int) -> bool:
	if not state.get("started", false):
		state["started"] = true
		state["g"] = {from: 0.0}
		state["parent"] = {}
		state["open"] = {from: _h(from, goal)}        # cell -> f
		state["closed"] = {}
		state["exp"] = 0
		state["result"] = ""
		state["path"] = []
		if _reached(from, goal, mode):
			state["result"] = "ok"
			return true
	var g: Dictionary = state["g"]
	var parent: Dictionary = state["parent"]
	var open: Dictionary = state["open"]
	var closed: Dictionary = state["closed"]
	var did := 0
	while did < budget:
		if open.is_empty():
			state["result"] = "no_path"
			return true
		# Pop the min-f node (deterministic tie-break: lower f, then lower g, then packed-cell order).
		var best: Vector3i = _pop_min(open, g)
		var bf: float = open[best]
		open.erase(best)
		if _reached(best, goal, mode):
			state["path"] = _reconstruct(parent, from, best)
			state["result"] = ("ok" if (state["path"] as Array).size() <= CubeSphere.NAV_PATH_MAX else "no_path")
			return true
		closed[best] = true
		state["exp"] = int(state["exp"]) + 1
		did += 1
		if int(state["exp"]) > CubeSphere.NAV_NODE_CAP:
			state["result"] = "no_path"               # bounded — refuse rather than grow unbounded
			return true
		var bg: float = g[best]
		for n in _NEI:
			for mv in _moves(world, best, n):
				var nc: Vector3i = mv[0]
				var nco: float = bg + mv[1]
				if closed.has(nc):
					continue
				if maxi(maxi(absi(nc.x - from.x), absi(nc.y - from.y)), absi(nc.z - from.z)) > CubeSphere.NAV_RANGE_MAX:
					continue                           # never expand beyond the range cap
				if not g.has(nc) or nco < float(g[nc]):
					g[nc] = nco
					parent[nc] = best
					open[nc] = nco + _h(nc, goal)
	return false                                       # more slices needed

## The executable moves from stand cell `best` toward horizontal neighbour `n` (§6.2 table). Returns
## Array of [dest_cell, cost].
func _moves(world, best: Vector3i, n: Vector3i) -> Array:
	var out: Array = []
	var flat := best + n
	if _stand(world, flat):
		out.append([flat, 1.0])                        # flat step
	var up := best + n + UP
	if _stand(world, up) and not world.cell_solid(best + UP + UP):   # jump headroom over the source
		out.append([up, 2.0])                          # step-UP = a planned jump (the ledge-stall fix)
	for k in range(1, CubeSphere.NAV_DROP_MAX + 1):    # step-DOWN 1..3, swept column clear
		var down := best + n - UP * k
		var swept := true
		for j in range(0, k):
			var cc := best + n - UP * j
			if world.cell_solid(cc) or _is_liquid(world, cc):
				swept = false
				break
		if swept and _stand(world, down):
			out.append([down, 1.0 + 0.4 * float(k)])
			break                                      # nearest landing only
	return out

## Deterministic min-f pop: lowest f, ties by lowest g, then packed-cell order (no dict-iteration nondeterminism).
static func _pop_min(open: Dictionary, g: Dictionary) -> Vector3i:
	var best: Vector3i = Vector3i.ZERO
	var bf := INF
	var bg := INF
	var bkey := INF
	var seen := false
	for c in open:
		var f: float = open[c]
		var gg: float = g.get(c, INF)
		var ck := float((int(c.x) & 0xFFFFF) | ((int(c.y) & 0xFFFFF) << 20) | ((int(c.z) & 0xFFFFF) << 40))
		if not seen or f < bf or (f == bf and (gg < bg or (gg == bg and ck < bkey))):
			best = c; bf = f; bg = gg; bkey = ck; seen = true
	return best

static func _reconstruct(parent: Dictionary, from: Vector3i, goal: Vector3i) -> Array:
	var path: Array = [goal]
	var cur := goal
	var guard := 0
	while cur != from and parent.has(cur) and guard < CubeSphere.NAV_PATH_MAX + 2:
		cur = parent[cur]
		path.append(cur)
		guard += 1
	path.reverse()
	if not path.is_empty() and path[0] == from:
		path.remove_at(0)                              # drop the start cell — waypoints are targets to move TO
	return path
