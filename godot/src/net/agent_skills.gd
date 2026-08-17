class_name AgentSkills
extends RefCounted
## COSMOS-AGENT-AUTONOMY A4 (docs/COSMOS-AGENT-AUTONOMY-DESIGN.md §7) — the `chop_tree` server-side phase
## machine: FIND → GOTO → AIM → CHOP, the ONE call that turns "find a tree and chop it" into a single op
## (the Voyager-skill model — the loop lives next to the physics tick, the LLM only picks the goal).
## It DRIVES the shared A2/A3 primitives (RemoteControl's goto follower + aim easing + player.remote_break_cell)
## rather than duplicating actuation, and reports progress as namespaced step events. Instanced by the
## executor per chop_tree; freed on step end. Reachable only under CONTROL_ENABLED + FP_AGENT_SKILL.

var _exec = null                               # the RemoteControl executor (a Node — NOT RefCounted; untyped so a real Node exec isn't rejected)
var _player = null                              # a Player (Node3D) live; a lightweight stub under gate
var _world = null
var _phase := "done"                           # find | goto | aim | chop | done
var _tree_base := Vector3i.ZERO                # tree column surface cell (tree_info.base)
var _chop_start := Vector3i.ZERO               # lowest LOG cell of the trunk (break cursor start)
var _chop_cur := Vector3i.ZERO                 # current break cursor
var _chop_top := 0                             # cursor y ceiling
var _broken := 0
var _retries := 0
var _excluded: Dictionary = {}                 # grid cells (Vector2i) skipped on retry
var _max_range := 48
var _aim_retry := 0

func setup(exec, player, world) -> void:
	_exec = exec
	_player = player
	_world = world

## A log/trunk cell? WOOD + the named species logs (0-id lookups are harmless — never match a real cell).
func _is_log(id: int) -> bool:
	if id <= 0:
		return false
	return id == BlockCatalog.WOOD \
		or id == BlockCatalog.id_of(&"spruce_log") \
		or id == BlockCatalog.id_of(&"birch_log") \
		or id == BlockCatalog.id_of(&"jungle_log") \
		or id == BlockCatalog.id_of(&"acacia_log")

func phase() -> String:
	return _phase

## FIND (synchronous): spiral the 10-block tree grid out from the player's cell; a candidate is a placed tree
## (TreeGen.has_tree) whose trunk-base cell still reads a LOG (overlay-aware alive-check — a chopped tree reads
## air). Nearest ring wins. Returns the first directive (goto adjacent) or the no_tree terminal.
func begin(max_range: int) -> Dictionary:
	_max_range = max_range
	return _find_and_go()

func _find_and_go() -> Dictionary:
	if not is_instance_valid(_player) or not is_instance_valid(_world):
		return terminal("blocked", {"why": "no_world"})
	var fid := TerrainConfig.active_facet()
	if fid < 0:
		return terminal("blocked", {"why": "no_facet"})
	var ctx = TerrainConfig.GenCtx.new(0, fid)
	var g := TreeGen.G
	var pgx := floori(_player.position.x / float(g))
	var pgz := floori(_player.position.z / float(g))
	var rings := int(ceil(float(_max_range) / float(g))) + 1
	var found := false
	for r in range(0, rings + 1):
		for dgx in range(-r, r + 1):
			for dgz in range(-r, r + 1):
				if maxi(absi(dgx), absi(dgz)) != r:   # ring shell only (spiral outward = nearest first)
					continue
				var gx := pgx + dgx
				var gz := pgz + dgz
				if _excluded.has(Vector2i(gx, gz)):
					continue
				if not TreeGen.has_tree(gx, gz, ctx):
					continue
				var info := TreeGen.tree_info(gx, gz, ctx)
				if info.is_empty():
					continue
				var base: Vector3i = info["base"]
				# alive-check + find the lowest LOG cell of the trunk (grass/snow fill may sit at base).
				var start := Vector3i.ZERO
				var alive := false
				for k in range(0, 3):
					var c := base + Vector3i(0, k, 0)
					if _is_log(_world.block_id_at(c)):
						start = c
						alive = true
						break
				if not alive:
					continue                           # chopped / submerged / not really a trunk here
				if _cheb_to_player(base) > _max_range:
					continue
				_tree_base = base
				_chop_start = start
				_chop_top = base.y + int(info.get("trunk_h", 8)) + 1
				found = true
				break
			if found: break
		if found: break
	if not found:
		return terminal("blocked", {"why": "no_tree"})
	_phase = "goto"
	return {"act": "goto", "cell": _chop_start, "goal": "adjacent"}

func _cheb_to_player(c: Vector3i) -> int:
	# c is CELL space (block_id_at); the pose is PLAY space (play y = cell y + datum lift). Remap the player's Y
	# so the Chebyshev range compares like-for-like — else a ~6-block datum lift inflates every tree's distance.
	var py: float = _player.position.y
	if is_instance_valid(_world) and _world.has_method("play_y_to_cell_y"):
		py = _world.play_y_to_cell_y(_player.position.x, _player.position.z, _player.position.y)
	var p := Vector3i(floori(_player.position.x), floori(py), floori(_player.position.z))
	return maxi(maxi(absi(c.x - p.x), absi(c.y - p.y)), absi(c.z - p.z))

## GOTO done → AIM (or retry a fresh tree on unreachable).
func on_goto_done(status: String) -> Dictionary:
	if status != "ok":
		if _retries < CubeSphere.SKILL_RETRY_MAX:
			_retries += 1
			_excluded[Vector2i(floori(float(_tree_base.x) / float(TreeGen.G)), floori(float(_tree_base.z) / float(TreeGen.G)))] = true
			return _find_and_go()                      # re-pick the next nearest tree
		return terminal("blocked", {"why": "unreachable", "tree": [_tree_base.x, _tree_base.y, _tree_base.z]})
	_phase = "aim"
	_aim_retry = 0
	return {"act": "aim", "cell": _chop_start}

## AIM done → CHOP (or re-aim one cell higher if occluded).
func on_aim_done(status: String, _hit: Array, _in_range: bool) -> Dictionary:
	if status != "ok":
		if _aim_retry < 1:
			_aim_retry += 1
			return {"act": "aim", "cell": _chop_start + Vector3i(0, 1, 0)}   # base can be shadowed; try higher
		return terminal("blocked", {"why": "occluded", "tree": [_tree_base.x, _tree_base.y, _tree_base.z]})
	_phase = "chop"
	_chop_cur = _chop_start
	return {"act": "continue"}

## CHOP poll: break ONE trunk cell per call, bottom-up, until air (collapse detached the canopy) or the cap.
func on_chop_poll() -> Dictionary:
	if _chop_cur.y > _chop_top or _broken >= CubeSphere.CHOP_MAX:
		return _chop_terminal()
	if not (is_instance_valid(_player) and _player.has_method("remote_break_cell")):
		return terminal("blocked", {"why": "no_player"})
	var res: Dictionary = _player.call("remote_break_cell", _chop_cur)
	match str(res.get("why", "")):
		"ok":
			_broken += 1
			_chop_cur += Vector3i(0, 1, 0)
			return {"act": "continue"}
		"air":
			# collapse (or a prior break) reached this cell — the tree is felled iff we already took the base.
			if _broken >= 1:
				return _chop_terminal()
			_chop_cur += Vector3i(0, 1, 0)              # nothing broken yet: skip a grass/snow-fill cap and keep going
			return {"act": "continue"}
		"out_of_reach":
			return _chop_terminal()                    # trunk climbed out of reach — partial fell, canopy usually detached
		_:
			return _chop_terminal()                    # protected / other — stop with what we have

func _chop_terminal() -> Dictionary:
	var why := "ok" if _broken >= 1 else "blocked"
	return terminal(why, {"why": why, "tree": [_tree_base.x, _tree_base.y, _tree_base.z], "broken": _broken})

## Force the terminal directive (also the watchdog path). The executor emits the chop_tree step_done from this.
func terminal(status: String, extra: Dictionary) -> Dictionary:
	_phase = "done"
	return {"act": "done", "status": ("ok" if status == "ok" else "blocked"), "extra": extra}
