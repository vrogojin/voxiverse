extends SceneTree
## COSMOS FALL-THROUGH FIX gate (FP_DESCENT_FACET_RESYNC) — a genuine (non-flying) descent whose ACTIVE facet has
## desynced from the true sub-camera facet (a fast/high FAR flight drifts many facets in the active facet's OWN frame
## while adjacent crossings are cooldown/containment-deferred and the high-flyer pool freeze suppresses resync) must
## RESYNC onto the true facet_of_dir owner so the floor is the owner's REAL surface — never the stale facet's piecewise-
## FLAT datum plane, which (extended far past its ridge domain) DIVES below the sphere even though the player is
## physically at radius ≈ R on the surface. Measured live: surface_y ≈ −28 at a far spot that really has trees; this
## gate's probe reproduces the same lie (surface_y −39 @ ~800 blocks off-centre, −108 @ ~1200, world radius ≈ R
## throughout), and asserts the resync restores the true positive surface, position-continuously.
##
## RUN (flags ON):
##   sed -i 's/const FACETED := false/const FACETED := true/; \
##           s/const FP_DESCENT_FACET_RESYNC := false/const FP_DESCENT_FACET_RESYNC := true/; \
##           s/const FP_DATUM_BAKE := false/const FP_DATUM_BAKE := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --import   # (twice on a fresh worktree)
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_descent_facet_resync.gd
##   then REVERT. Exits 0 all-pass / 1 on any failure.
const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

const R_BLOCKS := 6371.0

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

# Is `b` an EDGE-neighbour of `a` (or a itself)? Non-adjacent ⇒ unreachable by the adjacent-only seam march.
func _adjacent(a: int, b: int) -> bool:
	if a == b:
		return true
	for slot in 4:
		if FA.seam_neighbour(a, slot) == b:
			return true
	return false

# The true facet_of_dir owner of an A-frame lattice column (invariant: lattice→world is frame-consistent).
func _owner_of(A: int, x: float, z: float, y: float) -> int:
	var w := FA.lattice_to_world64(A, x, y, z)
	return FA.facet_of_dir(CubeSphere.DVec3.new(w[0], w[1], w[2]))

func _world_radius(A: int, x: float, z: float, y: float) -> float:
	var w := FA.lattice_to_world64(A, x, y, z)
	return sqrt(w[0]*w[0] + w[1]*w[1] + w[2]*w[2])

var _A := -1
var _cc := Vector2i.ZERO
# The chosen DEEP desync column: a large diagonal offset from A's centre whose owner is NON-ADJACENT and whose
# stale surface_y is deep (a genuine fall-through). Populated in _pick_desync.
var _dx := 0
var _dz := 0
var _owner := -1

func _initialize() -> void:
	print("=== verify_descent_facet_resync (FP_DESCENT_FACET_RESYNC: a desynced far descent resyncs onto the true owner surface) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED = true (+ FP_DESCENT_FACET_RESYNC) to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	if not CubeSphere.FLAT_WORLD:
		print("  FAIL: FACETED requires FLAT_WORLD = true."); quit(1); return
	TC.warm_up(); FA.warm_up()
	_A = FA.spawn_facet()
	_cc = FA.centre_cell(_A)
	TC.set_active_facet(_A)
	var w: WorldManager = WorldManager.new(); w.name = "DFRWM"; get_root().add_child(w)
	print("  FP_DESCENT_FACET_RESYNC=%s FP_DATUM_BAKE=%s A=%d centre=(%d,%d)" % [
		str(CubeSphere.FP_DESCENT_FACET_RESYNC), str(CubeSphere.FP_DATUM_BAKE), _A, _cc.x, _cc.y])

	_pick_desync(w)
	if _owner < 0:
		_ok(false, "could not find a non-adjacent deep-desync column off facet A — atlas/probe changed")
		print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail]); quit(1); return

	_gate_deep_lie(w)
	_gate_resync(w)
	_gate_adjacent_defer(w)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Scan a diagonal ray out from A's centre (the flight track in A's OWN frame) for the first offset whose TRUE owner is
## NON-ADJACENT to A (drifted ≥ 2 facets) AND whose stale surface_y is deep enough to bury the player (< −25, the live
## −28). This is the exact desync a far flight leaves behind.
func _pick_desync(w: WorldManager) -> void:
	TC.set_active_facet(_A)
	for d in range(200, 6000, 50):
		var x := float(_cc.x + d) + 0.5
		var z := float(_cc.y + d) + 0.5
		var owner := _owner_of(_A, x, z, 8.0)
		if owner < 0 or _adjacent(_A, owner):
			continue
		# Require BOTH a non-adjacent owner (drifted ≥ 2 facets — the real flight desync) AND a deep stale surface_y
		# (< the live −28 fall-through), so the falsifier exercises a genuine bury, not a boundary graze.
		if w.surface_y(x, z) >= -28.0:
			continue
		_dx = d; _dz = d; _owner = owner
		return

## G-DFR-DEEP (teeth / falsifier) — the bug MUST be real: at the chosen far offset in A's OWN frame the player is
## physically ON the surface (world radius ≈ R), yet with the STALE facet A active surface_y resolves A's piecewise-FLAT
## datum plane — which has DIVED far below the sphere — so the descending player would land tens of blocks underground.
func _gate_deep_lie(w: WorldManager) -> void:
	TC.set_active_facet(_A)
	var x := float(_cc.x + _dx) + 0.5
	var z := float(_cc.y + _dz) + 0.5
	var stale_sy := w.surface_y(x, z)
	var radius := _world_radius(_A, x, z, 8.0)
	print("  G-DFR-DEEP: offset d=%d owner=%d (non-adj) stale surface_y=%.1f world_radius=%.1f (R=%.0f)" % [
		_dx, _owner, stale_sy, radius, R_BLOCKS])
	_ok(not _adjacent(_A, _owner), "chosen owner %d is adjacent to A — not a genuine multi-facet desync" % _owner)
	_ok(absf(radius - R_BLOCKS) < 60.0, "the desync column is not physically on the surface (radius %.1f vs R %.0f)" % [radius, R_BLOCKS])
	_ok(stale_sy < -25.0, "the stale-facet surface is NOT deep (%.1f ≥ −25) — no fall-through, the desync would be moot" % stale_sy)

## G-DFR-RESYNC — the fix: resync_subcamera_facet on the desynced far position redesignates the active facet onto the true
## owner; from the owner the reframed position resolves the REAL positive surface (never the deep lie), and the reframe is
## WORLD-position-continuous (a rigid facet-frame change — no teleport).
func _gate_resync(w: WorldManager) -> void:
	TC.set_active_facet(_A)
	var pa := Vector3(float(_cc.x + _dx) + 0.5, 8.0, float(_cc.y + _dz) + 0.5)
	var world_before := FA.lattice_to_world64(_A, pa.x, pa.y, pa.z)
	var res: Dictionary = w.resync_subcamera_facet(pa)
	_ok(not res.is_empty(), "resync_subcamera_facet returned {} on a non-adjacent far desync (no resync fired)")
	if res.is_empty():
		return
	var now := TC.active_facet()
	_ok(now == _owner, "active facet after resync=%d != true owner=%d" % [now, _owner])
	var np: Vector3 = res["new_pos"]
	var world_after := FA.lattice_to_world64(now, np.x, np.y, np.z)
	var dpos := Vector3(float(world_after[0] - world_before[0]), float(world_after[1] - world_before[1]), float(world_after[2] - world_before[2])).length()
	_ok(dpos < 1.0, "resync moved the WORLD position by %.3f blocks (not position-continuous — a teleport)" % dpos)
	var healed_sy := w.surface_y(np.x, np.z)
	print("  G-DFR-RESYNC: resync %d -> %d, reframed surface_y=%.2f, world Δ=%.4f" % [_A, now, healed_sy, dpos])
	_ok(healed_sy > 0.0, "post-resync surface_y=%.2f is not a positive above-ground top (still buried)" % healed_sy)

## G-DFR-ADJACENT-DEFER (walk-safety) — an owner that IS an edge-neighbour of the active facet must NOT resync here (the
## −HYST/cooldown/containment hysteresis of maybe_cross_facet owns adjacent seam crossings). Guarantees normal walking is
## untouched: a walk step only ever drifts to an adjacent facet, so this guard never fires during a walk. Find a small
## offset whose owner is an ADJACENT neighbour and assert resync defers.
func _gate_adjacent_defer(w: WorldManager) -> void:
	TC.set_active_facet(_A)
	var chosen := -1
	var cx := 0
	var cz := 0
	for d in range(50, _dx, 25):
		var owner := _owner_of(_A, float(_cc.x + d) + 0.5, float(_cc.y) + 0.5, 8.0)
		if owner != _A and _adjacent(_A, owner):
			chosen = owner; cx = _cc.x + d; cz = _cc.y
			break
	_ok(chosen >= 0, "found no adjacent-owner offset to test the walk-safety defer")
	if chosen < 0:
		return
	TC.set_active_facet(_A)
	var res: Dictionary = w.resync_subcamera_facet(Vector3(float(cx) + 0.5, 8.0, float(cz) + 0.5))
	print("  G-DFR-DEFER: owner is adjacent neighbour %d ⇒ resync returned %s (must be {})" % [chosen, "{}" if res.is_empty() else str(res.get("to", "?"))])
	_ok(res.is_empty(), "resync FIRED for an adjacent owner (fid %d) — it would fight maybe_cross_facet's hysteresis and could disturb walking" % chosen)
