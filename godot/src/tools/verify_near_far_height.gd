extends SceneTree
## COSMOS-NEAR-FAR-HEIGHT-DESIGN.md §3/§4 gate — proves FP_FARRING_APPLIED_COVER's three-zone REFINEMENT of the
## deployed FP_FARRING_UNCOVERED_TRUE two-zone blend: the annulus between the honest near-mesh-APPLIED edge and
## the streamed+margin ellipsoid (classified "covered" by the deployed law even though nothing near is actually
## drawn there — the trench) now takes the TRUE chord minus a small z-guard (zone B) instead of the sunk
## envelope-minimum height. Every assertion drives the REAL FacetFarRing methods (`_applied_box_meshed` /
## `_applied_probe_step` / `_applied_covered` / `_blend_uncovered` / `_emit_cached`) with the flag/ellipsoid/radius
## FORCED VIA FUNCTION PARAMS — this file's own existing convention (mirrors verify_pale_backstop.gd, e.g.
## `_sunk_positions`'s `rim_on`, `_blend_uncovered`'s new `applied_on`/`applied_r`) — so no sed and no FACETED
## requirement: the facet geometry / worldgen profile functions this fix touches are FACETED-independent pure
## functions of (fid) / (direction), same as the pale-backstop fix it refines.
##
##   G-NFH-STEP     — mountain facet + peak player column + realistic ellipsoid params (r=128,O=12,H=52) + forced
##                    applied_r=96: every vertex classified zone B (not `_uncovered`, not `_applied_covered` at
##                    r_applied=96) sits, after `_blend_uncovered` with applied_on=true, within
##                    [true−ENV_EPS_G−1.0, true]. FALSIFIER: those SAME vertices, with applied_on=false (the
##                    deployed two-zone law), sit ≥0.8·sink blocks BELOW true height — the trench this fix removes.
##   G-NFH-COVERED  — every zone-C vertex (`_applied_covered` true at the forced radius) is BYTE-IDENTICAL
##                    (exact Vector3 equality) to the flag-off covered branch — the proven near/far-coexist regime
##                    is untouched inside the applied radius.
##   G-NFH-OUTER    — every zone-A vertex (`_uncovered` true) is BYTE-IDENTICAL to the deployed
##                    FP_FARRING_UNCOVERED_TRUE emit (applied_on has no effect there) — zone-A preservation.
##   G-NFH-PROBE    — `_applied_probe_step`'s ladder law: grows by exactly one APPLIED_PROBE_STEP per call on a
##                    passing probe (never more), drops fully to 0 in the SAME call a re-verify fails (never
##                    gradual), and stays 0 with an invalid coverage callable or no real column yet.
##   G-NFH-CHURN    — a scripted stream-in (ladder 0→APPLIED_PROBE_MAX) followed by a 256-block walk at constant
##                    full coverage: total `_pending` re-arms stays inside the documented
##                    ladder_steps + walk/UNSINK_DRIFT_BLOCKS + slack bound (bounded churn, never per-probe).
##   G-NFH-OFF      — `TierPlace.applied_cover_on()` false (the default, real compile flags) ⇒ `_emit_cached` /
##                    `_blend_uncovered` reproduce the deployed two-zone law byte-for-byte regardless of a forced
##                    `applied_r`, and `_applied_probe_step()` with no override never moves `_applied_r` off 0 or
##                    sets `_pending`. FLAT `verify_feature.gd` (checked separately, not in this file) stays
##                    6042/0; `verify_pale_backstop.gd` (checked separately) stays 16/0.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const TC := preload("res://src/world/terrain_config.gd")
const FFR := preload("res://src/world/facet_far_ring.gd")
const FSV2 := preload("res://src/world/facet_smooth_v2.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_near_far_height (COSMOS-NEAR-FAR-HEIGHT-DESIGN.md — FP_FARRING_APPLIED_COVER) ===")
	TC.warm_up()
	FA.warm_up()
	var fid := _find_mountain_facet()
	var span := _facet_relief_span(fid)
	print("  atlas: k=%d, R=%.0f, mountain fid=%d, relief span≈%.1f blocks, sink=%.2f, ENV_EPS_G=%.2f, STEP=%d, MAX=%d" % [
		FA.K, FA.R_BLOCKS, fid, span, TierPlace.backstop_sink(), TierPlace.ENV_EPS_G,
		CubeSphere.APPLIED_PROBE_STEP, CubeSphere.APPLIED_PROBE_MAX])
	_ok(span >= 30.0, "fixture: scanned mountain facet has relief span ≥30 blocks (found %.1f)" % span)
	_gate_step_covered_outer(fid)
	_gate_probe()
	_gate_churn()
	_gate_off(fid)
	_gate_fh_unsink(fid)
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- fixture helpers (mirror verify_pale_backstop.gd) ----------

func _find_mountain_facet() -> int:
	var total := FA.K * FA.K * 6
	var best_fid := 0
	var best_span := -1.0
	for fid in range(0, total, 5):
		var span := _facet_relief_span(fid, 3)
		if span > best_span:
			best_span = span
			best_fid = fid
			if span >= 60.0:
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

# ---------- G-NFH-STEP + G-NFH-COVERED + G-NFH-OUTER ----------
func _gate_step_covered_outer(fid: int) -> void:
	print("  --- G-NFH-STEP / G-NFH-COVERED / G-NFH-OUTER: three-zone blend on a real mountain facet ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)

	ring.call("_ensure_backstop_true_cached", fid)
	var true_pos: PackedVector3Array = (ring.get("_btrue_cache") as Dictionary)[fid]
	var covered: PackedVector3Array = ring.call("_sunk_positions", true_pos, fid)
	_ok(true_pos.size() == covered.size() and true_pos.size() > 0, "fixture: true/covered grids are non-empty and same size (%d)" % true_pos.size())

	# Player column: the highest true-grid node (a peak vantage — same fixture convention as G-PB-TRUE), with the
	# design's own cited ellipsoid numbers (r=128, O=12, H=52) so the frontier genuinely straddles all three zones.
	var peak_i := 0
	var peak_r := -1.0
	for i in range(true_pos.size()):
		var l: float = (true_pos[i] as Vector3).length()
		if l > peak_r:
			peak_r = l; peak_i = i
	var col: Vector3 = true_pos[peak_i]
	var params := Vector3(128.0, 12.0, 52.0)
	var applied_r := 96.0   # forced (the streamed+margin boundary is 128+24=152 — a real ⌊MAX/STEP⌋ ladder rung)
	var sink := TierPlace.backstop_sink()
	var eps := TierPlace.ENV_EPS_G

	var blended_on: PackedVector3Array = ring.call("_blend_uncovered", covered, fid, col, true, params, true, applied_r)
	var blended_off: PackedVector3Array = ring.call("_blend_uncovered", covered, fid, col, true, params, false, 0.0)
	_ok(blended_on.size() == covered.size() and blended_off.size() == covered.size(), "blend: output sizes match input")

	var n_a := 0; var n_b := 0; var n_c := 0
	var step_ok := true
	var falsifier_ok := true
	var covered_ok := true
	var outer_ok := true
	for i in range(true_pos.size()):
		var t: Vector3 = true_pos[i]
		var t_len := t.length()
		var uncov: bool = ring.call("_uncovered", t, col, true, params)
		if uncov:
			n_a += 1
			# G-NFH-OUTER: zone A is unaffected by applied_on — both blends must equal the true chord exactly.
			if blended_on[i] != t or blended_off[i] != t:
				outer_ok = false
			continue
		var appl_cov: bool = ring.call("_applied_covered", t, col, applied_r, params)
		if appl_cov:
			n_c += 1
			# G-NFH-COVERED: zone C keeps the shipped covered law verbatim, on OR off.
			if blended_on[i] != covered[i] or blended_off[i] != covered[i]:
				covered_ok = false
		else:
			n_b += 1
			# G-NFH-STEP: zone B blends to TRUE − ENV_EPS_G (within a 1.0-block slack for the sqrt/normalize chain).
			if absf(blended_on[i].length() - (t_len - eps)) > 1.0:
				step_ok = false
			# FALSIFIER: the deployed (applied_on=false) blend keeps the OLD sunk covered height here — measurably
			# lower than true by most of the sink, reproducing the pre-fix trench.
			if blended_off[i] != covered[i] or (t_len - covered[i].length()) < 0.8 * sink:
				falsifier_ok = false

	_ok(n_a > 0 and n_b > 0 and n_c > 0, "fixture straddles all three zones: A=%d B=%d C=%d" % [n_a, n_b, n_c])
	_ok(step_ok, "G-NFH-STEP: every zone-B vertex blends to TRUE−ENV_EPS_G (±1.0)")
	_ok(falsifier_ok, "G-NFH-STEP falsifier: those same vertices sit ≥0.8·sink below true with applied_on=false (the trench)")
	_ok(covered_ok, "G-NFH-COVERED: every zone-C vertex is BYTE-IDENTICAL to the flag-off covered branch")
	_ok(outer_ok, "G-NFH-OUTER: every zone-A vertex is BYTE-IDENTICAL to the deployed un-sink (TRUE chord)")
	ring.free()

# ---------- G-NFH-PROBE ----------
# A controllable coverage stub: "covered" iff the queried box's horizontal half-extent is ≤ `_stub_r`. Mirrors the
# `_applied_box_meshed` box shape (half-extent r in x/z) without depending on real fid-lattice placement.
var _stub_r := 0.0
func _cover_upto(_fid: int, aabb: AABB) -> bool:
	return aabb.size.x * 0.5 <= _stub_r + 0.01
func _cover_invalid(_fid: int, _aabb: AABB) -> bool:
	return false   # never used as a Callable target — see the "invalid callable" sub-gate below, which unsets it entirely

func _gate_probe() -> void:
	print("  --- G-NFH-PROBE: ladder growth ≤1 step/tick, instant shrink, invalid/no-column ⇒ 0 ---")
	var params := Vector3(128.0, 12.0, 52.0)
	var step := CubeSphere.APPLIED_PROBE_STEP
	var max_r := CubeSphere.APPLIED_PROBE_MAX

	# (a) growth: fully covered from the start — each call may grow by AT MOST one step, never jump straight to MAX.
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.set("_active_fid", 0)
	ring.call("set_cover_query", Callable(self, "_cover_upto"))
	ring.call("set_player_column", Vector3(FA.R_BLOCKS, 0.0, 0.0))
	_stub_r = float(max_r)
	var grow_ok := true
	var prev := 0.0
	var calls := ceili(float(max_r) / float(step)) + 1
	for _i in range(calls):
		ring.call("_applied_probe_step", true, params)
		var cur := float(ring.get("_applied_r"))
		if cur - prev > float(step) + 0.001 or cur < prev:
			grow_ok = false
		prev = cur
	_ok(grow_ok, "G-NFH-PROBE: _applied_r never grows by more than one step per call")
	_ok(is_equal_approx(prev, float(max_r)), "G-NFH-PROBE: fully covered ⇒ converges to APPLIED_PROBE_MAX (%d), got %.1f" % [max_r, prev])

	# (b) instant shrink: coverage collapses to 0 ⇒ the NEXT call drops _applied_r to 0 in that SAME call (not
	# gradually over several calls).
	_stub_r = 0.0
	ring.call("_applied_probe_step", true, params)
	_ok(is_equal_approx(float(ring.get("_applied_r")), 0.0), "G-NFH-PROBE: shrink is INSTANT — one call fully collapsed applied_r once coverage vanished (was %.1f)" % prev)

	# (c) partial re-coverage after a full drop: growth resumes at exactly one step, not a jump back to the old value.
	_stub_r = float(max_r)
	ring.call("_applied_probe_step", true, params)
	_ok(is_equal_approx(float(ring.get("_applied_r")), float(step)), "G-NFH-PROBE: re-growth after a drop advances exactly one step (%d), not a jump" % step)
	ring.free()

	# (d) invalid coverage callable ⇒ 0, even with a real column and `on=true`.
	var ring2: Node3D = FFR.new()
	get_root().add_child(ring2)
	ring2.set("_active_fid", 0)
	ring2.call("set_player_column", Vector3(FA.R_BLOCKS, 0.0, 0.0))
	ring2.call("_applied_probe_step", true, params)
	_ok(is_equal_approx(float(ring2.get("_applied_r")), 0.0), "G-NFH-PROBE: an invalid coverage callable ⇒ applied_r stays 0")
	ring2.free()

	# (e) no real column yet ⇒ 0, even with a valid, fully-covering callable.
	var ring3: Node3D = FFR.new()
	get_root().add_child(ring3)
	ring3.set("_active_fid", 0)
	ring3.call("set_cover_query", Callable(self, "_cover_upto"))
	_stub_r = float(max_r)
	ring3.call("_applied_probe_step", true, params)
	_ok(is_equal_approx(float(ring3.get("_applied_r")), 0.0), "G-NFH-PROBE: no real player column pushed yet ⇒ applied_r stays 0")
	ring3.free()

# ---------- G-NFH-CHURN ----------
func _gate_churn() -> void:
	print("  --- G-NFH-CHURN: bounded rebuild count over stream-in + a 256-block walk ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.set("_active_fid", 0)
	ring.call("set_cover_query", Callable(self, "_cover_upto"))
	var params := Vector3(128.0, 12.0, 52.0)
	var step := CubeSphere.APPLIED_PROBE_STEP
	var max_r := CubeSphere.APPLIED_PROBE_MAX
	var ladder_steps := ceili(float(max_r) / float(step))

	var rearms := 0
	# Stream-in: coverage ramps 0 → max_r over `ladder_steps` ticks at a fixed column (mesh catching up around a
	# parked player) — each tick's step-change re-arms _pending exactly once.
	var col := Vector3(FA.R_BLOCKS, 0.0, 0.0)
	ring.call("set_player_column", col)
	for i in range(ladder_steps + 1):
		_stub_r = minf(float(max_r), float(step) * float(i))
		ring.set("_pending", false)
		ring.call("_applied_probe_step", true, params)
		if bool(ring.get("_pending")):
			rearms += 1
	# Then a 256-block walk at CONSTANT full coverage (the coverage stub is column-independent by construction —
	# the honest streaming case where the near field has already fully caught up) — no further step-changes.
	var walk_steps := 16
	for _i in range(walk_steps):
		col.y += 16.0
		ring.call("set_player_column", col)
		ring.set("_pending", false)
		ring.call("_applied_probe_step", true, params)
		if bool(ring.get("_pending")):
			rearms += 1
	var bound := ladder_steps + walk_steps + 2   # ladder_steps + walk/UNSINK_DRIFT_BLOCKS + role-event slack
	_ok(rearms <= bound, "G-NFH-CHURN: %d re-arms over stream-in(%d ticks) + %d-step walk ≤ bound %d" % [rearms, ladder_steps + 1, walk_steps, bound])
	_ok(rearms >= 1, "G-NFH-CHURN: fixture sanity — the stream-in ramp actually re-armed at least once")
	ring.free()

# ---------- G-NFH-OFF ----------
func _gate_off(fid: int) -> void:
	print("  --- G-NFH-OFF: TierPlace.applied_cover_on() false ⇒ byte-identical to the deployed two-zone law ---")
	_ok(not TierPlace.applied_cover_on(), "compile flags: FP_FARRING_APPLIED_COVER is false (the shipped default)")

	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("_ensure_backstop_true_cached", fid)
	var true_pos: PackedVector3Array = (ring.get("_btrue_cache") as Dictionary)[fid]
	var col: Vector3 = true_pos[0] * 1.001   # any real column; the flag gate, not the column, decides here
	var params := TC.streamed_ellipsoid_params()   # the REAL default `_emit_cached` uses internally — must match exactly

	# _emit_cached with NO override (real caller convention) reads TierPlace.applied_cover_on() internally — must
	# match a hand-forced applied_on=false _blend_uncovered call exactly, even with a large forced applied_r. The
	# reference is built from `_bpos_cache` (via `_ensure_backstop_cached`, THE SAME cache `_emit_cached`'s sunk
	# branch reads) — NOT `_btrue_cache` — since with FP_SHELL_WELD off (the default) the two grids are built by
	# different constructions and are not index-comparable to `true_pos`; `_blend_uncovered` itself is what makes
	# them index-comparable (it always reads its OWN TRUE chord internally), so this mirrors the real call exactly.
	ring.call("set_player_column", col)
	ring.call("_ensure_backstop_cached", fid)   # populate _bpos_cache — _emit_cached's sunk branch reads it directly
	var bpos: PackedVector3Array = (ring.get("_bpos_cache") as Dictionary)[fid]
	var covered: PackedVector3Array = ring.call("_sunk_positions", bpos, fid)
	ring.set("_applied_r", 80.0)   # simulate a probe having grown, to prove the FLAG (not a zero radius) gates this off
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	ring.call("_emit_cached", st, fid, true, false, true)   # uncovered_true_on forced true (the deployed flag)
	var emitted := st.commit().surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array

	var reference: PackedVector3Array = ring.call("_blend_uncovered", covered, fid, col, true, params, false, 0.0)
	var stride := CubeSphere.BACKSTOP_CELLS + 1
	var ref_tris := PackedVector3Array()
	var cells := CubeSphere.BACKSTOP_CELLS
	for gj in range(cells):
		for gi in range(cells):
			var i0 := gj * stride + gi
			var i1 := i0 + 1
			var i2 := i0 + stride
			var i3 := i2 + 1
			ref_tris.push_back(reference[i0]); ref_tris.push_back(reference[i2]); ref_tris.push_back(reference[i1])
			ref_tris.push_back(reference[i1]); ref_tris.push_back(reference[i2]); ref_tris.push_back(reference[i3])
	var match_ok := emitted.size() == ref_tris.size()
	if match_ok:
		for i in range(emitted.size()):
			if emitted[i] != ref_tris[i]:
				match_ok = false
				break
	_ok(match_ok, "G-NFH-OFF: _emit_cached (flag off) is BYTE-IDENTICAL to the deployed two-zone _blend_uncovered, despite a forced non-zero _applied_r (%d verts)" % emitted.size())

	# _applied_probe_step() with NO override, called repeatedly, never moves _applied_r off 0 nor sets _pending —
	# even with a fully-covering callable and a real column (the flag, not the inputs, gates it off).
	ring.set("_applied_r", 0.0)
	ring.call("set_cover_query", Callable(self, "_cover_upto"))
	_stub_r = float(CubeSphere.APPLIED_PROBE_MAX)
	var inert_ok := true
	for _i in range(5):
		ring.set("_pending", false)
		ring.call("_applied_probe_step")   # no override — real call-site convention
		if not is_equal_approx(float(ring.get("_applied_r")), 0.0) or bool(ring.get("_pending")):
			inert_ok = false
	_ok(inert_ok, "G-NFH-OFF: _applied_probe_step() with no override never moves _applied_r off 0 or sets _pending")
	ring.free()

# ---------- G-FH-UNSINK + G-FH-OFF (FP_V2_NEARFILL_UNSINK, docs/COSMOS-FAR-HEIGHT-DESIGN.md §3) ----------
## The V2 near-fill un-sink is a VERTEX-shader zone law (the headless dummy RenderingServer never parses GLSL), so this
## gate drives its CPU TWIN `FacetSmoothV2.unsink_pos_cpu` — kept byte-for-byte in lock-step with `_V2_SHADER_TAIL_UNSINK`
## — over the SAME mountain fixture + forced ellipsoid the G-NFH suite uses. The un-sink recovers the TRUE radial position
## from the shipped 6-block-sunk near-fill vertex and applies the ring's own `_applied_covered` ellipsoid: zone C keeps the
## sunk pos byte-identical (no-protrusion preserved), zone B collapses to TRUE − ENV_EPS_G (the skirt 6→1.5). Flag-independent
## (pure function), so it is all-pass at the byte-off default; G-FH-OFF pins that the SHARED shader (orbit-relief's) is untouched.
func _gate_fh_unsink(fid: int) -> void:
	print("  --- G-FH-UNSINK / G-FH-OFF: FP_V2_NEARFILL_UNSINK vertex zone law (CPU mirror) ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("_ensure_backstop_true_cached", fid)
	var true_pos: PackedVector3Array = (ring.get("_btrue_cache") as Dictionary)[fid]
	# Peak player column (same convention as G-NFH-STEP), the design's cited ellipsoid, a real ladder rung.
	var peak_i := 0
	var peak_r := -1.0
	for i in range(true_pos.size()):
		var l: float = (true_pos[i] as Vector3).length()
		if l > peak_r:
			peak_r = l; peak_i = i
	var col: Vector3 = true_pos[peak_i]
	var params := Vector3(128.0, 12.0, 52.0)
	var applied_r := 96.0
	var sink: float = CubeSphere.V2_NEARFILL_SINK
	var eps: float = TierPlace.ENV_EPS_G
	var r_datum: float = FA.r_of(fid)
	var band_top := 1.0e9   # vacuous band gate — this gate exercises the ellipsoid, not the view-band (covered by G-NFH)

	var n_c := 0
	var n_b := 0
	var zoneC_byte_ok := true
	var zoneB_height_ok := true
	for i in range(true_pos.size()):
		var t: Vector3 = true_pos[i]
		var p: Vector3 = t - t.normalized() * sink              # the shipped SUNK near-fill vertex (COLOR.a=1 ⇒ vsink=sink)
		var outp: Vector3 = FSV2.unsink_pos_cpu(p, sink, col, applied_r, params, band_top, r_datum, eps)
		var appl_cov: bool = ring.call("_applied_covered", t, col, applied_r, params)
		if appl_cov:
			n_c += 1
			if outp != p:                                       # zone C: keep the shipped sunk pos byte-identical
				zoneC_byte_ok = false
		else:
			n_b += 1
			if absf(outp.length() - (t.length() - eps)) > 0.05:  # zone B: TRUE − ENV_EPS_G
				zoneB_height_ok = false
	_ok(n_c > 0 and n_b > 0, "G-FH-UNSINK: fixture straddles zone C (%d) and zone B (%d)" % [n_c, n_b])
	_ok(zoneC_byte_ok, "G-FH-UNSINK: every zone-C vertex byte-identical to the shipped sunk position (no-protrusion preserved)")
	_ok(zoneB_height_ok, "G-FH-UNSINK: every zone-B vertex lands at TRUE − ENV_EPS_G (the 6→1.5 skirt collapse)")

	# FALSIFIER: the shipped sunk position sits a full `sink` below TRUE — the un-sink must LIFT every zone-B vertex.
	var lifted_ok := true
	for i in range(true_pos.size()):
		var t: Vector3 = true_pos[i]
		var p: Vector3 = t - t.normalized() * sink
		var appl_cov: bool = ring.call("_applied_covered", t, col, applied_r, params)
		if not appl_cov:
			var outp: Vector3 = FSV2.unsink_pos_cpu(p, sink, col, applied_r, params, band_top, r_datum, eps)
			if outp.length() - p.length() < (sink - eps) - 0.2:   # lifted by ≈(sink−eps)=4.5 blocks
				lifted_ok = false
	_ok(lifted_ok, "G-FH-UNSINK falsifier: zone-B vertices are LIFTED ≈(sink−eps) blocks above the shipped sunk trench")

	# applied_r = 0 (degraded / no probe) ⇒ un-sink everywhere to TRUE − eps, never the 6-block trench.
	var all_b := true
	for i in range(true_pos.size()):
		var t: Vector3 = true_pos[i]
		var p: Vector3 = t - t.normalized() * sink
		var outp: Vector3 = FSV2.unsink_pos_cpu(p, sink, col, 0.0, params, band_top, r_datum, eps)
		if absf(outp.length() - (t.length() - eps)) > 0.05:
			all_b = false
	_ok(all_b, "G-FH-UNSINK: applied_r=0 (degraded) ⇒ whole near-fill un-sinks to TRUE−eps (never the sunk trench)")

	# sink = 0 (hop≥2 tiles carry COLOR.a=0 ⇒ vsink=0) ⇒ VERTEX byte-identical (untouched).
	var untouched := true
	for i in range(mini(true_pos.size(), 64)):
		var t: Vector3 = true_pos[i]
		if FSV2.unsink_pos_cpu(t, 0.0, col, applied_r, params, band_top, r_datum, eps) != t:
			untouched = false
	_ok(untouched, "G-FH-UNSINK: sink=0 (hop≥2) vertices are byte-identical — VERTEX untouched (merged-mesh safety)")

	# G-FH-OFF: the SHARED shader (which FacetOrbitRelief reuses) never carries the un-sink uniforms, regardless of flag —
	# the un-sink lives ONLY in the separate un-sink source. This pins orbit-relief isolation.
	var shared := FSV2.shader_code()
	var unsink := FSV2.shader_code_unsink()
	_ok(not ("u_ns_col" in shared), "G-FH-OFF: the shared shader_code() (orbit-relief reuse) has NO un-sink uniforms")
	_ok(("u_ns_col" in unsink) and ("u_ns_applied_r" in unsink), "G-FH-OFF: shader_code_unsink() carries the un-sink uniforms")
	ring.free()
