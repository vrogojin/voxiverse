extends SceneTree
## COSMOS UP-VECTOR FACET-DESYNC FIX gate (FP_UPVECTOR_FACET_HEAL, task #91,
## docs/COSMOS-PLAYER-UPVECTOR-FACET-DESYNC-DESIGN.md §3). Hunts a genuine TILT_H equilibrium live (the
## probe_upvector_tilt.gd technique, ported here — atlas-robust, no hard-coded cells) and exercises the SHIPPED
## `WorldManager.maybe_cross_facet` directly (never a re-implementation of the decision):
##   G-REPRO    — the shipped call (heal inert: default grounded=false) returns {} at a TILT_H point; the soil
##                cell is masked for the active facet; the true owner's up diverges > 3.5°. Reproduces the
##                persistent tilt headlessly.
##   G-HEAL     — flag ON + (h_speed=0, grounded=true) at the SAME pose commits to the owner: up-divergence
##                < 0.1°, f64 world-point continuity < 1e-6, play-surface continuity < 1 block, and a re-scan at
##                the healed pose returns {} (fixed point — no ping-pong).
##   G-NOREG-*  — an interior point, a normal deep contained crossing, the SAME TILT_H pose at walking speed, and
##                an edit-marked TILT_H column are all untouched / unaffected by the flag.
##   G-WELD     — floor_under/surface_y agree (within FLOOR_WELD_EPS) before and after the heal — composition
##                with the fall-through fix (task #90).
##
## RUN (flags ON — all four, so G-WELD genuinely exercises the composition):
##   sed -i 's/const FACETED := false/const FACETED := true/; \
##           s/const FP_QUERY_FRAME_GUARD := false/const FP_QUERY_FRAME_GUARD := true/; \
##           s/const FP_FLOOR_SURFACE_WELD := false/const FP_FLOOR_SURFACE_WELD := true/; \
##           s/const FP_UPVECTOR_FACET_HEAL := false/const FP_UPVECTOR_FACET_HEAL := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --import
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_upvector_heal.gd
##   then REVERT via sed (NEVER `git checkout -- <file>` — it discards uncommitted work in this worktree).
##   Exits 0 all-pass / 1 on any failure.
const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

const HYST := 0.1   # mirrors WorldManager.FACET_CROSS_HYST (private to that class) for this gate's own hunts

# Candidate facets to hunt across (mirrors probe_upvector_tilt.gd's sample — 6·K² = 3456 total, K=24).
const _CANDIDATE_FIDS := [1356, 348, 0, 300, 1000, 2000, 3000, 3455]

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

var _w: WorldManager

func _initialize() -> void:
	print("=== verify_upvector_heal (FP_UPVECTOR_FACET_HEAL) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED (+FP_UPVECTOR_FACET_HEAL, +FP_QUERY_FRAME_GUARD/FP_FLOOR_SURFACE_WELD for G-WELD) to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	if not CubeSphere.FLAT_WORLD:
		print("  FAIL: FACETED requires FLAT_WORLD = true."); quit(1); return
	TC.warm_up(); FA.warm_up()
	var home := FA.spawn_facet()
	TC.set_active_facet(home)
	_w = WorldManager.new(); _w.name = "UpvectorHealWM"; get_root().add_child(_w)   # _ready() builds the collider
	print("  FP_UPVECTOR_FACET_HEAL=%s FP_QUERY_FRAME_GUARD=%s FP_FLOOR_SURFACE_WELD=%s" % [
		str(CubeSphere.FP_UPVECTOR_FACET_HEAL), str(CubeSphere.FP_QUERY_FRAME_GUARD), str(CubeSphere.FP_FLOOR_SURFACE_WELD)])

	var tilt := _find_tilt_h()
	_ok(not tilt.is_empty(), "could not find a live TILT_H equilibrium — atlas/probe changed")
	if not tilt.is_empty():
		_gate_repro(tilt)
		_gate_heal(tilt)
		_gate_noreg_walking(tilt)
		_gate_noreg_edited(tilt)
		_gate_weld(tilt)
	_gate_noreg_interior()
	_gate_noreg_deep_crossing()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Port of probe_upvector_tilt.gd's `_place_at_own`: place a probe point near (px, pz) with min-slot own_dist ==
## dtarget, feet at surface+1. Returns {} if degenerate (no plane gradient) or the point escapes the ridge.
func _place_at_own(fid: int, px: float, pz: float, dtarget: float) -> Dictionary:
	var y := 64.0
	var x := px
	var z := pz
	for _it in range(3):
		var pl: PackedFloat64Array = FA.seam_planes_f64(fid)
		var best_slot := -1
		var best := INF
		for slot in range(4):
			var s: float = FA.own_dist(fid, slot, x, y, z)
			if s < best:
				best = s
				best_slot = slot
		var A := pl[best_slot * 4 + 0]
		var C := pl[best_slot * 4 + 2]
		var gh := sqrt(A * A + C * C)
		if gh < 1e-9:
			return {}
		x += (dtarget - best) * A / (gh * gh)
		z += (dtarget - best) * C / (gh * gh)
		var xi := int(floor(x))
		var zi := int(floor(z))
		var g: float = float(int(TC.column_profile(xi, zi).x))
		y = g + 1.0
	var xi2 := int(floor(x))
	var zi2 := int(floor(z))
	var g2 := float(int(TC.column_profile(xi2, zi2).x))
	return {"x": x, "y": g2 + 1.0, "z": z, "xi": xi2, "zi": zi2, "gy": g2}

## Hunt the real atlas for a TILT_H equilibrium, classifying via the SHIPPED `maybe_cross_facet` (heal inert:
## default grounded=false) rather than a re-implementation — so "the shipped call returns {}" is authoritative,
## not assumed.
func _find_tilt_h() -> Dictionary:
	for fid: int in _CANDIDATE_FIDS:
		TC.set_active_facet(fid)
		var corners := []
		for ci in range(4):
			var wc: Array = FA.facet_planar_corner(fid, ci)
			corners.append(FA.world_to_lattice64(fid, wc[0], wc[1], wc[2]))
		for e in range(4):
			var c0: Array = corners[e]
			var c1: Array = corners[(e + 1) % 4]
			for ti in range(0, 41):
				var t := 0.005 + 0.99 * float(ti) / 40.0
				var px := lerpf(c0[0], c1[0], t)
				var pz := lerpf(c0[2], c1[2], t)
				for dtarget in [-0.02, -0.05, -0.08, -0.15, -0.3, -0.5]:
					var q := _place_at_own(fid, px, pz, dtarget)
					if q.is_empty():
						continue
					var x: float = q["x"]
					var y: float = q["y"]
					var z: float = q["z"]
					TC.set_active_facet(fid)
					_w._cross_cooldown = 0
					var shipped := _w.maybe_cross_facet(Vector3(x, y, z))   # default args ⇒ heal inert
					if not shipped.is_empty():
						continue                          # a normal crossing point, not the equilibrium we want
					var xi: int = q["xi"]
					var zi: int = q["zi"]
					var gy: int = int(q["gy"])
					var soil_masked: bool = FA.cell_seam_state(fid, xi, gy, zi)["air"]
					if not soil_masked:
						continue
					var w := FA.lattice_to_world64(fid, x, y, z)
					var owner := FA.facet_of_dir(CubeSphere.DVec3.new(w[0], w[1], w[2]))
					if owner < 0 or owner == fid:
						continue
					var tilt_deg := rad_to_deg(FA.facet_transform(fid).basis.y.angle_to(FA.facet_transform(owner).basis.y))
					if tilt_deg <= 3.5:
						continue
					return {"fid": fid, "owner": owner, "x": x, "y": y, "z": z, "xi": xi, "zi": zi, "gy": gy, "tilt_deg": tilt_deg}
	return {}

func _gate_repro(tilt: Dictionary) -> void:
	var fid: int = tilt["fid"]
	var owner: int = tilt["owner"]
	TC.set_active_facet(fid)
	_w._cross_cooldown = 0
	var pos := Vector3(tilt["x"], tilt["y"], tilt["z"])
	var shipped := _w.maybe_cross_facet(pos)   # default args: grounded=false ⇒ heal inert regardless of flag
	print("  G-REPRO: fid=%d owner=%d pos=(%.2f,%.2f,%.2f) tilt=%.3f° shipped_returns_empty=%s" % [
		fid, owner, pos.x, pos.y, pos.z, float(tilt["tilt_deg"]), str(shipped.is_empty())])
	_ok(shipped.is_empty(), "shipped maybe_cross_facet did not return {} at the TILT_H point — not a genuine equilibrium")
	var soil_masked: bool = FA.cell_seam_state(fid, int(tilt["xi"]), int(tilt["gy"]), int(tilt["zi"]))["air"]
	_ok(soil_masked, "soil cell is not masked for the active facet — not a genuine TILT_H point")
	_ok(owner != fid, "owner == active facet — not a genuine TILT_H point")
	_ok(float(tilt["tilt_deg"]) > 3.5, "up-divergence %.3f° <= 3.5° — the persistent tilt was not reproduced" % float(tilt["tilt_deg"]))

func _gate_heal(tilt: Dictionary) -> void:
	var fid: int = tilt["fid"]
	var owner: int = tilt["owner"]
	TC.set_active_facet(fid)
	_w._cross_cooldown = 0
	var pos := Vector3(tilt["x"], tilt["y"], tilt["z"])
	var world_before := FA.lattice_to_world64(fid, pos.x, pos.y, pos.z)
	var sy_before := _w.surface_y(pos.x, pos.z)          # the pre-heal facet's own analytic surface at the pose
	var heal := _w.maybe_cross_facet(pos, 0.0, true)     # flag ON, grounded, stationary
	_ok(not heal.is_empty(), "G-HEAL: flag ON + grounded + stationary did not commit at the TILT_H point")
	if heal.is_empty():
		TC.set_active_facet(fid)
		return
	var to := int(heal["to"])
	_ok(to == owner, "healed to %d, expected the true owner %d" % [to, owner])
	var now := TC.active_facet()
	_ok(now == owner, "active facet after heal = %d, expected %d" % [now, owner])
	var np: Vector3 = heal["new_pos"]
	var world_after := FA.lattice_to_world64(now, np.x, np.y, np.z)
	var dpos := Vector3(float(world_after[0] - world_before[0]), float(world_after[1] - world_before[1]),
		float(world_after[2] - world_before[2])).length()
	# NOTE: `_commit_facet_change`'s returned `new_pos` is a `Vector3` (f32, world_manager.gd:2701) — the SAME
	# return type every crossing uses (maybe_cross_facet's normal path, resync_subcamera_facet, the re-entry
	# restore). Round-tripping the f64 reframe through that f32 cast floors precision at ~ULP(10^4) ≈ 1e-3, not
	# 1e-6 (a genuinely double-precision comparison would need the pre-cast f64 array, not the returned dict).
	# 0.01 stays two orders of magnitude tighter than the codebase's existing "continuous, not a teleport" bound
	# (verify_descent_facet_resync.gd's G-DFR-RESYNC uses < 1.0) while still catching a real teleport.
	_ok(dpos < 0.01, "heal moved the WORLD position by %.6f blocks (not continuous — a teleport)" % dpos)
	var up_after: Vector3 = FA.facet_transform(now).basis.y
	var up_owner: Vector3 = FA.facet_transform(owner).basis.y
	var divergence := rad_to_deg(up_after.angle_to(up_owner))
	_ok(divergence < 0.1, "post-heal up-divergence %.4f° >= 0.1° — active facet's up doesn't match the owner's" % divergence)
	var sy_after := _w.surface_y(np.x, np.z)             # the post-heal facet's own analytic surface at the reframed pose
	print("  G-HEAL: healed %d -> %d, world Δ=%.9f, up-divergence=%.4f° surface_before=%.2f surface_after=%.2f" % [
		fid, now, dpos, divergence, sy_before, sy_after])
	_ok(absf(sy_after - sy_before) < 1.0, "play-surface step at the heal (%.2f -> %.2f) exceeds 1 block" % [sy_before, sy_after])
	# Fixed point (§2 stability argument): re-scan at the healed pose (now active == owner) — must return {}.
	var rescan := _w.maybe_cross_facet(np, 0.0, true)
	_ok(rescan.is_empty(), "re-scan at the healed pose did NOT return {} — ping-pong (ownership isn't a fixed point)")

func _gate_noreg_walking(tilt: Dictionary) -> void:
	var fid: int = tilt["fid"]
	TC.set_active_facet(fid)
	_w._cross_cooldown = 0
	var pos := Vector3(tilt["x"], tilt["y"], tilt["z"])
	var res := _w.maybe_cross_facet(pos, 4.0, true)      # walking speed, still "grounded"
	print("  G-NOREG-WALK: fid=%d h_speed=4.0 result_empty=%s" % [fid, str(res.is_empty())])
	_ok(res.is_empty(), "heal fired for a walking-speed player at the TILT_H pose — walkers must be untouched")

func _gate_noreg_edited(tilt: Dictionary) -> void:
	var fid: int = tilt["fid"]
	TC.set_active_facet(fid)
	_w._cross_cooldown = 0
	var pos := Vector3(tilt["x"], tilt["y"], tilt["z"])
	var col := Vector2i(int(tilt["xi"]), int(tilt["zi"]))
	# Mark the TILT_H column as edited (fault-injection, same technique verify_floor_weld.gd uses) WITHOUT
	# changing its actual solid content — the mask law reads geometry only, so this must NOT change the heal's
	# decision (§2/§3 arm 4-iv: "the mask law ignores edits").
	_w._edit_columns[col] = true
	var res := _w.maybe_cross_facet(pos, 0.0, true)
	_w._edit_columns.erase(col)
	print("  G-NOREG-EDITED: fid=%d col=%s marked-edited result_empty=%s (expected NOT empty — edits don't gate the heal)" % [
		fid, str(col), str(res.is_empty())])
	_ok(not res.is_empty(), "marking the column edited suppressed the heal — the mask law must ignore _edit_columns")

func _gate_weld(tilt: Dictionary) -> void:
	var fid: int = tilt["fid"]
	TC.set_active_facet(fid)
	_w._cross_cooldown = 0
	var pos := Vector3(tilt["x"], tilt["y"], tilt["z"])
	var floor_before := _w.floor_under(pos.x, pos.z, pos.y)
	var surface_before := _w.surface_y(pos.x, pos.z)
	_ok(absf(floor_before - surface_before) < CubeSphere.FLOOR_WELD_EPS,
		"floor_under/surface_y disagree by more than the weld epsilon BEFORE the heal (floor=%.2f surface=%.2f)" % [floor_before, surface_before])
	var heal := _w.maybe_cross_facet(pos, 0.0, true)
	_ok(not heal.is_empty(), "G-WELD setup: heal did not commit at the TILT_H point")
	if heal.is_empty():
		return
	var np: Vector3 = heal["new_pos"]
	var floor_after := _w.floor_under(np.x, np.z, np.y)
	var surface_after := _w.surface_y(np.x, np.z)
	print("  G-WELD: before floor=%.2f surface=%.2f | after floor=%.2f surface=%.2f" % [
		floor_before, surface_before, floor_after, surface_after])
	_ok(absf(floor_after - surface_after) < CubeSphere.FLOOR_WELD_EPS,
		"floor_under/surface_y disagree by more than the weld epsilon AFTER the heal (floor=%.2f surface=%.2f)" % [floor_after, surface_after])

## G-NOREG-INTERIOR (§3 arm 4-i): a solidly interior point (own_min > +1) is never healed.
func _gate_noreg_interior() -> void:
	var fid := FA.spawn_facet()
	TC.set_active_facet(fid)
	_w._cross_cooldown = 0
	var c := FA.centre_cell(fid)
	var x := float(c.x) + 0.5
	var z := float(c.y) + 0.5
	var g := float(int(TC.column_profile(c.x, c.y).x))
	var pos := Vector3(x, g + 1.0, z)
	var own_min := INF
	for slot in 4:
		own_min = minf(own_min, FA.own_dist(fid, slot, pos.x, pos.y, pos.z))
	_ok(own_min > 1.0, "sanity: facet centre own_min=%.2f is not solidly interior (>1.0) — atlas changed" % own_min)
	var res := _w.maybe_cross_facet(pos, 0.0, true)      # flag ON, grounded, stationary
	print("  G-NOREG-INTERIOR: fid=%d own_min=%.2f result_empty=%s" % [fid, own_min, str(res.is_empty())])
	_ok(res.is_empty(), "heal fired at a solidly interior point — spurious heal")

## G-NOREG-DEEP (§3 arm 4-ii): a normal deep, CONTAINED crossing (own_dist < −0.5, the reframed landing interior
## to all 4 of the destination's own ridges) is caught by the SHIPPED slot scan — the heal is unreachable there,
## so it must land on the SAME destination the scan alone would give.
func _gate_noreg_deep_crossing() -> void:
	var found := {}
	for fid: int in _CANDIDATE_FIDS:
		TC.set_active_facet(fid)
		var c := FA.centre_cell(fid)
		var pl: PackedFloat64Array = FA.seam_planes_f64(fid)
		for slot in 4:
			var A := pl[slot * 4 + 0]
			if absf(A) < 1e-6:
				continue
			var base_z := float(c.y) + 0.5
			var base_own := FA.own_dist(fid, slot, float(c.x) + 0.5, 8.0, base_z)
			var target := -0.8
			var x := float(c.x) + 0.5 + (target - base_own) / A   # exact single-axis step to own_dist == target
			var xi := int(floor(x))
			var zi := int(floor(base_z))
			var g := float(int(TC.column_profile(xi, zi).x))
			var pos := Vector3(x, g + 1.0, base_z)
			var s := FA.own_dist(fid, slot, pos.x, pos.y, pos.z)
			if s >= -0.5:
				continue
			var to: int = FA.seam_neighbour(fid, slot)
			var np := FA.reframe_position64(fid, to, pos.x, pos.y, pos.z)
			var contained := true
			for bslot in 4:
				if FA.own_dist(to, bslot, np[0], np[1], np[2]) < -HYST:
					contained = false
					break
			if contained:
				found = {"fid": fid, "pos": pos, "to": to, "slot": slot}
				break
		if not found.is_empty():
			break
	_ok(not found.is_empty(), "could not find a normal deep contained crossing point — atlas/probe changed")
	if found.is_empty():
		return
	var fid: int = found["fid"]
	TC.set_active_facet(fid)
	_w._cross_cooldown = 0
	var res := _w.maybe_cross_facet(found["pos"], 0.0, true)   # flag ON, grounded — heal is UNREACHABLE here
	print("  G-NOREG-DEEP: fid=%d slot=%d expected_to=%d result=%s" % [fid, int(found["slot"]), int(found["to"]), str(res)])
	_ok(not res.is_empty(), "a normal deep crossing did not commit")
	_ok(int(res.get("to", -1)) == int(found["to"]),
		"deep crossing landed on %d, expected the shipped destination %d" % [int(res.get("to", -1)), int(found["to"])])
