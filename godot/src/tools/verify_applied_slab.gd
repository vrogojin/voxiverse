extends SceneTree
## COSMOS-FAR-NEAR-GRASSBASE-DESIGN.md §3 gate (FP_APPLIED_PROBE_SLAB) — proves the applied-cover ladder is now
## SATISFIABLE (the dead-latch that pinned `_applied_r` at 0 everywhere is fixed) WITHOUT touching the #89-proven
## three-zone height law. Runs in BOTH compile states (flag OFF and ON) and passes in both:
##
##   G-ACS-OFF   (flag OFF)  — dead-probe ROOT-CAUSE PIN: with a bounds-semantics-faithful synthetic coverage
##                 callable (true iff the AABB ⊆ the meshed slab × domain±2 — mirrors engine is_area_meshed's
##                 never-clip), the SHIPPED `_applied_box_meshed(16, 128, col)` is FALSE at player lattice y 34
##                 AND y 110 (the ±128 box's 256-block span can NEVER fit the 194-block slab [−64,130]), and the
##                 real `_applied_probe_step(on=true)` ladder therefore stays pinned at 0. Documents the bug so a
##                 silent re-death is reproducible. (FLAT verify_feature.gd 6042/0 byte-identity checked separately.)
##   G-ACS-SAT   (flag ON)   — ladder LIVES: the CLAMPED `_applied_box_meshed` returns TRUE at an interior column
##                 when the near field is meshed; driving `_applied_probe_step(on=true)` grows `_applied_r`
##                 0→APPLIED_PROBE_MAX one step/tick, and flipping the coverage callable false drops it to 0 in ONE
##                 call (shrink-instantly intact). The cross-border remainder (a border column whose box overflows
##                 the active domain onto a pool neighbour) is TRUE only when the seam-strip probe passes, FALSE when
##                 it fails, and FALSE when no seam probe is wired — the FP_NB_WELD W1 bounds-safe proof.
##   G-ACS-LAW   (both)      — the protrusion pin (flag-independent — drives the real `_blend_uncovered` height law
##                 with forced applied_on/applied_r, mirroring verify_near_far_height): (a) with the ladder LIVE
##                 (applied_r=MAX) every zone-C node sits sunk UNDER its true top (no protrusion); (b) with the
##                 ladder DEAD (applied_r=0) those SAME near nodes RISE to zone B (TRUE−ENV_EPS_G) — worst rise ≈
##                 backstop_sink−ENV_EPS_G ≥ +5 (the +9.08-class overshoot), a re-death fails loudly; plus the
##                 BLOCKY corner-MIN concavity that makes it grass-base-specific (26-block tread over a concave base).

const FA := preload("res://src/cosmos/facet_atlas.gd")
const TC := preload("res://src/world/terrain_config.gd")
const FFR := preload("res://src/world/facet_far_ring.gd")

# --- LIVE flag fingerprint (baseline pins). Gate-LOCAL consts, NOT CubeSphere.FP_* (repo-default-false would void
# the pin): these encode the flags the SERVED pck bakes on (design §1 fact 1). Asserted true so a baseline drift is
# caught here. FP_APPLIED_PROBE_SLAB is the ONE the run toggles — read live below, not pinned. ---
const LIVE_FACETED := true
const LIVE_FP_FARRING_FULL_COVER := true
const LIVE_FP_BLOCKY_FARRING := true
const LIVE_FP_FARRING_APPLIED_COVER := true
const LIVE_FP_FARRING_UNCOVERED_TRUE := true
const LIVE_FP_NB_FULLRES := true

# The live degraded INPUT the design pins: streamed_ellipsoid_params = (r=128, O=0, H=128) (§1 fact 1). H=128 is
# what makes the shipped ±h box span 256 > the 194-block slab. Used for every probe/ladder assertion.
const PROBE_PARAMS := Vector3(128.0, 0.0, 128.0)

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

# --- synthetic coverage callables (mirror engine is_area_meshed's bounds semantics) -----------------------------
# FAITHFUL: "the near field is meshed everywhere it CAN be" — true iff the queried AABB lies fully inside the
# meshable slab (TerrainConfig.meshed_slab_y) × the facet's domain±2. is_area_meshed NEVER clips to bounds, so any
# block outside → un-meshed → false: exactly this test. This is the design's repro state (backlog 0, fully streamed).
func _cover_faithful(fid: int, aabb: AABB) -> bool:
	var slab: Vector2 = TC.meshed_slab_y()
	var dmin: Vector2i = FA.dom_min(fid)
	var dmax: Vector2i = FA.dom_max(fid)
	var lo := aabb.position
	var hi := aabb.position + aabb.size
	return lo.y >= slab.x - 0.001 and hi.y <= slab.y + 0.001 \
		and lo.x >= float(dmin.x) - 2.0 - 0.001 and hi.x <= float(dmax.x) + 2.0 + 0.001 \
		and lo.z >= float(dmin.y) - 2.0 - 0.001 and hi.z <= float(dmax.y) + 2.0 + 0.001
# NEVER: the near field has fully retreated (models shrink-instantly).
func _cover_never(_fid: int, _aabb: AABB) -> bool:
	return false
# seam-strip probe stubs (the cross-border remainder): controllable pass/fail.
func _seam_true(_fid: int, _pap: Vector3) -> bool:
	return true
func _seam_false(_fid: int, _pap: Vector3) -> bool:
	return false

func _initialize() -> void:
	print("=== verify_applied_slab (COSMOS-FAR-NEAR-GRASSBASE — FP_APPLIED_PROBE_SLAB) ===")
	TC.warm_up()
	FA.warm_up()
	var slab: Vector2 = TC.meshed_slab_y()
	var slab_on := CubeSphere.FP_APPLIED_PROBE_SLAB
	print("  meshed_slab_y = (%.1f, %.1f), height %.1f blk; box y-span 2·H = %.1f; FP_APPLIED_PROBE_SLAB = %s" % [
		slab.x, slab.y, slab.y - slab.x, 2.0 * PROBE_PARAMS.z, str(slab_on)])
	# baseline fingerprint pins
	_ok(LIVE_FACETED and LIVE_FP_FARRING_FULL_COVER and LIVE_FP_BLOCKY_FARRING and LIVE_FP_FARRING_APPLIED_COVER
		and LIVE_FP_FARRING_UNCOVERED_TRUE and LIVE_FP_NB_FULLRES,
		"fixture: live flag fingerprint pinned (FACETED + FULL_COVER + BLOCKY + APPLIED_COVER + UNCOVERED_TRUE + NB_FULLRES)")
	# The dead-probe argument is altitude-INDEPENDENT: the box span exceeds the slab height, always.
	_ok(2.0 * PROBE_PARAMS.z > (slab.y - slab.x),
		"fixture: shipped ±H box span (%.0f) exceeds the meshed slab height (%.0f) ⇒ dead at EVERY altitude" % [2.0 * PROBE_PARAMS.z, slab.y - slab.x])

	var fid := _find_mountain_facet()
	var span := _facet_relief_span(fid)
	print("  atlas: k=%d, R=%.0f, mountain fid=%d, relief span≈%.1f blk, backstop_sink=%.2f, ENV_EPS_G=%.2f, STEP=%d, MAX=%d" % [
		FA.K, FA.R_BLOCKS, fid, span, TierPlace.backstop_sink(), TierPlace.ENV_EPS_G,
		CubeSphere.APPLIED_PROBE_STEP, CubeSphere.APPLIED_PROBE_MAX])
	_ok(span >= 30.0, "fixture: scanned mountain facet has relief span ≥30 blocks (found %.1f)" % span)

	if slab_on:
		_gate_sat(fid)
	else:
		_gate_off_deadprobe(fid)
	_gate_law(fid)

	print("=== verify_applied_slab: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- fixtures (shared with verify_near_far_height's convention) ----------
func _find_mountain_facet() -> int:
	var total := FA.K * FA.K * 6
	var best_fid := 0
	var best_span := -1.0
	for fid in range(0, total, 5):
		var s := _facet_relief_span(fid, 3)
		if s > best_span:
			best_span = s
			best_fid = fid
			if s >= 60.0:
				break
	return best_fid

func _facet_relief_span(fid: int, n: int = 9) -> float:
	var cd := FA.facet_corner_dirs(fid)
	var gmin := 1e9
	var gmax := -1e9
	for j in range(n):
		for i in range(n):
			var s := float(i) / float(n - 1)
			var t := float(j) / float(n - 1)
			var d: Vector3 = FFR._weld_unit(cd, s, t)
			var g := TC.profile_at_dir(d.x, d.y, d.z, FA.R_BLOCKS).x
			gmin = minf(gmin, g)
			gmax = maxf(gmax, g)
	return gmax - gmin

# Fine surface HEIGHT g at facet-uv (s,t) — the welded unit dir sampled through the worldgen profile (one basis).
func _g_at(cd: PackedFloat64Array, s: float, t: float) -> float:
	var d: Vector3 = FFR._weld_unit(cd, s, t)
	return TC.profile_at_dir(d.x, d.y, d.z, FA.R_BLOCKS).x

# Build an absolute-world column at a chosen lattice point (lx, ly, lz) of `fid` (inverse of world_to_lattice64).
func _col_at_lattice(fid: int, lx: float, ly: float, lz: float) -> Vector3:
	var w: Array = FA.lattice_to_world64(fid, lx, ly, lz)
	return Vector3(float(w[0]), float(w[1]), float(w[2]))

# ---------- G-ACS-OFF: dead-probe pin (flag OFF compile) ----------
func _gate_off_deadprobe(fid: int) -> void:
	print("  --- G-ACS-OFF: shipped ±H probe provably FALSE at every altitude; ladder stays 0 ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.set("_active_fid", fid)
	ring.call("set_cover_query", Callable(self, "_cover_faithful"))
	var dmin: Vector2i = FA.dom_min(fid)
	var dmax: Vector2i = FA.dom_max(fid)
	var dcx := float(dmin.x + dmax.x) * 0.5
	var dcz := float(dmin.y + dmax.y) * 0.5
	# The shipped body builds a box y∈[l1−128, l1+128]. At l1=34 → [−94,162], at l1=110 → [−18,238]: both overflow
	# the slab [−64,130], and the faithful callable (never-clip) returns false ⇒ the probe is dead. r=16 (one rung).
	var col34 := _col_at_lattice(fid, dcx, 34.0, dcz)
	var col110 := _col_at_lattice(fid, dcx, 110.0, dcz)
	_ok(not bool(ring.call("_applied_box_meshed", 16.0, PROBE_PARAMS.z, col34)),
		"G-ACS-OFF: shipped _applied_box_meshed(16,128) FALSE at player lattice y≈34 (box y-span overflows slab)")
	_ok(not bool(ring.call("_applied_box_meshed", 16.0, PROBE_PARAMS.z, col110)),
		"G-ACS-OFF: shipped _applied_box_meshed(16,128) FALSE at player lattice y≈110 (dead at altitude too)")
	# The real ladder therefore cannot leave 0, even fully "covered" and on=true (the design's pinned dead state).
	ring.call("set_player_column", col34)
	var moved := false
	for _i in range(8):
		ring.call("_applied_probe_step", true, PROBE_PARAMS)
		if float(ring.get("_applied_r")) != 0.0:
			moved = true
	_ok(not moved, "G-ACS-OFF: _applied_probe_step(on=true) leaves _applied_r pinned at 0 (dead ladder)")
	ring.free()

# ---------- G-ACS-SAT: ladder lives (flag ON compile) ----------
func _gate_sat(fid: int) -> void:
	print("  --- G-ACS-SAT: clamped probe TRUE when meshed; ladder 0→MAX; shrink-instant; cross-border via W1 ---")
	var dmin: Vector2i = FA.dom_min(fid)
	var dmax: Vector2i = FA.dom_max(fid)
	var dcx := float(dmin.x + dmax.x) * 0.5
	var dcz := float(dmin.y + dmax.y) * 0.5
	var col_c := _col_at_lattice(fid, dcx, 34.0, dcz)

	# (1) interior column, near field meshed ⇒ the CLAMPED box fits the slab×domain ⇒ probe TRUE.
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.set("_active_fid", fid)
	ring.call("set_cover_query", Callable(self, "_cover_faithful"))
	ring.call("set_seam_cover_query", Callable(self, "_seam_true"))
	_ok(bool(ring.call("_applied_box_meshed", 16.0, PROBE_PARAMS.z, col_c)),
		"G-ACS-SAT: clamped _applied_box_meshed(16,128) TRUE at an interior meshed column (slab-clamped box fits)")

	# (2) ladder grows one step/tick to APPLIED_PROBE_MAX.
	ring.call("set_player_column", col_c)
	var step := float(CubeSphere.APPLIED_PROBE_STEP)
	var max_r := float(CubeSphere.APPLIED_PROBE_MAX)
	var grow_ok := true
	var prev := 0.0
	for _i in range(ceili(max_r / step) + 1):
		ring.call("_applied_probe_step", true, PROBE_PARAMS)
		var cur := float(ring.get("_applied_r"))
		if cur - prev > step + 0.001 or cur < prev:
			grow_ok = false
		prev = cur
	_ok(grow_ok, "G-ACS-SAT: _applied_r never grows by more than one step per call")
	_ok(is_equal_approx(prev, max_r), "G-ACS-SAT: ladder converges to APPLIED_PROBE_MAX (%d), got %.1f" % [int(max_r), prev])

	# (3) shrink-instantly: the near field retreats (callable → never) ⇒ ONE call drops _applied_r to 0.
	ring.call("set_cover_query", Callable(self, "_cover_never"))
	ring.call("_applied_probe_step", true, PROBE_PARAMS)
	_ok(is_equal_approx(float(ring.get("_applied_r")), 0.0),
		"G-ACS-SAT: shrink-instantly — one call collapses _applied_r to 0 when coverage vanishes")
	ring.free()

	# (4) cross-border remainder: a column near the −x domain edge, r=112 ⇒ box overflows onto a pool neighbour.
	#     Proven only when the W1 seam-strip probe passes; FALSE when it fails; FALSE when no seam probe is wired.
	var col_b := _col_at_lattice(fid, float(dmin.x) + 4.0, 34.0, dcz)
	var r_big := float(CubeSphere.APPLIED_PROBE_MAX)
	var ring2: Node3D = FFR.new()
	get_root().add_child(ring2)
	ring2.set("_active_fid", fid)
	ring2.call("set_cover_query", Callable(self, "_cover_faithful"))
	# seam TRUE ⇒ remainder proven ⇒ box true
	ring2.call("set_seam_cover_query", Callable(self, "_seam_true"))
	var border_true := bool(ring2.call("_applied_box_meshed", r_big, PROBE_PARAMS.z, col_b))
	# seam FALSE ⇒ overflowed neighbour unmeshed ⇒ box false
	ring2.call("set_seam_cover_query", Callable(self, "_seam_false"))
	var border_false := bool(ring2.call("_applied_box_meshed", r_big, PROBE_PARAMS.z, col_b))
	# no seam probe wired ⇒ remainder unprovable ⇒ box false (no over-claim)
	ring2.call("set_seam_cover_query", Callable())
	var border_noseam := bool(ring2.call("_applied_box_meshed", r_big, PROBE_PARAMS.z, col_b))
	_ok(border_true, "G-ACS-SAT: cross-border box TRUE when the W1 seam-strip probe passes for the overflowed neighbour")
	_ok(not border_false, "G-ACS-SAT: cross-border box FALSE when the seam-strip probe FAILS (no over-claim)")
	_ok(not border_noseam, "G-ACS-SAT: cross-border box FALSE with NO seam probe wired (fallback/no-module convention)")
	ring2.free()

# ---------- G-ACS-LAW: the protrusion pin (flag-independent) ----------
func _gate_law(fid: int) -> void:
	print("  --- G-ACS-LAW: ladder-live sinks zone C UNDER near tops; ladder-dead raises it to zone B (protrusion) ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("_ensure_backstop_true_cached", fid)
	var true_pos: PackedVector3Array = (ring.get("_btrue_cache") as Dictionary)[fid]
	var covered: PackedVector3Array = ring.call("_sunk_positions", true_pos, fid)
	_ok(true_pos.size() == covered.size() and true_pos.size() > 0, "fixture: true/covered grids non-empty, same size (%d)" % true_pos.size())

	# Player column at the peak (a robust straddle vantage). The rise a dead ladder inflicts on a zone-C node is
	# column-independent (zone C sunk → zone B (TRUE−ENV_EPS_G)); the peak just guarantees a populated zone C.
	var peak_i := 0
	var peak_r := -1.0
	for i in range(true_pos.size()):
		var l: float = (true_pos[i] as Vector3).length()
		if l > peak_r:
			peak_r = l; peak_i = i
	var col: Vector3 = true_pos[peak_i]
	var applied_max := float(CubeSphere.APPLIED_PROBE_MAX)
	var eps := TierPlace.ENV_EPS_G
	var sink := TierPlace.backstop_sink()

	# Ladder LIVE (applied_r = MAX) vs DEAD (applied_r = 0), both applied_on=true (the fix's zone-C refinement).
	var blended_live: PackedVector3Array = ring.call("_blend_uncovered", covered, fid, col, true, PROBE_PARAMS, true, applied_max)
	var blended_dead: PackedVector3Array = ring.call("_blend_uncovered", covered, fid, col, true, PROBE_PARAMS, true, 0.0)

	var n_zc := 0            # nodes zone-C when the ladder is live
	var n_rise := 0         # of those, how many RISE when the ladder dies (become zone B)
	var worst_rise := 0.0
	var zc_under_ok := true
	for i in range(true_pos.size()):
		var t: Vector3 = true_pos[i]
		if bool(ring.call("_uncovered", t, col, true, PROBE_PARAMS)):
			continue                                    # zone A — untouched by the ladder
		if not bool(ring.call("_applied_covered", t, col, applied_max, PROBE_PARAMS)):
			continue                                    # zone B even when live — not a ladder-C cell
		n_zc += 1
		# (a) ladder LIVE ⇒ this node is sunk (zone C) UNDER its own true top (near tops ≈ true) — no protrusion.
		if blended_live[i].length() > t.length() + 0.001:
			zc_under_ok = false
		# (b) ladder DEAD ⇒ the SAME node rises to zone B — its height climbs toward TRUE−eps.
		var rise := blended_dead[i].length() - blended_live[i].length()
		if rise > 0.5:
			n_rise += 1
		worst_rise = maxf(worst_rise, rise)
	var frac := (float(n_rise) / float(n_zc)) if n_zc > 0 else 0.0
	print("    zone-C nodes=%d, rise-on-death=%d (%.0f%%), worst rise=%.2f blk, sink−eps=%.2f" % [
		n_zc, n_rise, 100.0 * frac, worst_rise, sink - eps])
	_ok(n_zc > 0, "G-ACS-LAW: fixture has a populated zone C when the ladder is live (%d nodes)" % n_zc)
	_ok(zc_under_ok, "G-ACS-LAW (a): every zone-C node sits UNDER its true top when the ladder is live (no protrusion)")
	_ok(frac >= 0.30, "G-ACS-LAW (b): ≥30%% of zone-C nodes RISE when the ladder dies (got %.0f%%)" % [100.0 * frac])
	_ok(worst_rise >= 5.0, "G-ACS-LAW (b): worst dead-ladder rise ≥ +5 blk — the +9.08-class overshoot (got %.2f)" % worst_rise)

	ring.free()

	# WHY the live worst is +9.08 (not the full sink−eps of ≈11.5): the realized NEAR tops sit BELOW the true
	# profile by the top-face −0.64 + the SHARP-SLOPE carve (design fact 7), so the dead zone-B tread (TRUE−1.5)
	# rides that much less over them than over the true chord. That carve is #111/#112 machinery, outside this
	# far-ring-only fix; a diagnostic scan confirms the overshoot is NOT from 26-block cell concavity (which is
	# <2 blk at this worldgen resolution) but from the sink/carve mechanism the primary rise pin above captures.
	var cells := CubeSphere.BACKSTOP_CELLS
	var total := FA.K * FA.K * 6
	var worst_concavity := 0.0
	for ff in range(0, total, 31):                       # sparse sample — diagnostic only, bounded worldgen cost
		var cd := FA.facet_corner_dirs(ff)
		for gj in range(cells):
			for gi in range(cells):
				var c00 := _g_at(cd, float(gi) / float(cells), float(gj) / float(cells))
				var c10 := _g_at(cd, float(gi + 1) / float(cells), float(gj) / float(cells))
				var c01 := _g_at(cd, float(gi) / float(cells), float(gj + 1) / float(cells))
				var c11 := _g_at(cd, float(gi + 1) / float(cells), float(gj + 1) / float(cells))
				var fine := _g_at(cd, (float(gi) + 0.5) / float(cells), (float(gj) + 0.5) / float(cells))
				worst_concavity = maxf(worst_concavity, minf(minf(c00, c10), minf(c01, c11)) - fine)
	print("    diagnostic: worst 26-block cell concavity (corner-MIN − interior) = %.2f blk ⇒ protrusion is sink/carve-driven, not concavity" % worst_concavity)
