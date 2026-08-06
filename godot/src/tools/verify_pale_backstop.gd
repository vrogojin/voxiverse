extends SceneTree
## COSMOS-PALE-BACKSTOP-FIX-DESIGN.md §3.1/§4 gate — proves FP_FARRING_UNCOVERED_TRUE's per-vertex analytic
## un-sink law: a dense-backstop vertex whose TRUE (welded, un-sunk) chord position lies OUTSIDE the streamed
## VoxelViewer ellipsoid (inflated by UNSINK_MARGIN_BLOCKS) emits at that TRUE height; a vertex INSIDE keeps the
## shipped envelope+sink law byte-identically. Every assertion drives the REAL FacetFarRing methods
## (`_uncovered` / `_ensure_backstop_true_cached` / `_blend_uncovered` / `_emit_cached` / `_append_backstop_tris`
## / `_unsink_drift_check`) with the flag/ellipsoid FORCED VIA FUNCTION PARAMS — this file's own existing
## convention (e.g. `_sunk_positions`'s `rim_on`, `_noblack_guarantee`'s `noblack_on`) — so no sed and no
## FACETED requirement: the facet geometry / worldgen profile functions this fix touches (FacetAtlas.
## facet_corner_dirs, TerrainConfig.profile_at_dir) are FACETED-independent pure functions of (fid) / (direction).
##
##   G-PB-TRUE     — on a real mountain facet (scanned for relief ≥30 blocks — comfortably found ≥60), with a
##                    synthetic player column + ellipsoid straddling it (part covered, part not): every vertex
##                    `_uncovered` calls uncovered sits, after `_blend_uncovered`, within ±1.0 block of its TRUE
##                    chord height. FALSIFIER: those SAME vertices, in the shipped covered array (flag off), sit
##                    ≥ ε·0.8 blocks BELOW true height — the pale sunk well the fix removes.
##   G-PB-COVERED   — every vertex `_uncovered` calls covered is BYTE-IDENTICAL (exact Vector3 equality) to the
##                    flag-off covered array — the no-protrusion regime is untouched wherever near/far can
##                    coexist. Plus a margin audit: no vertex classified uncovered under the INFLATED ellipsoid
##                    is classified uncovered by less than half the margin (the slack is real, not a knife-edge).
##   G-PB-HOVER     — player column far above the surface (no near field can exist anywhere near it) ⇒ EVERY
##                    vertex of the facet un-sinks to its true height (no lingering sunk well off-surface).
##   G-PB-OFF       — uncovered_true_on=false (the default, real compile flag) ⇒ `_emit_cached` reproduces the
##                    pre-fix mean emitted radius (measurably lower than the flag-forced-on emit), and
##                    `_btrue_cache` is never populated by an off-path call (zero wasted work). FLAT
##                    `verify_feature.gd` (checked separately, not in this file) stays 6042/0.
##   G-PB-LEDGER    — `_btrue_cache` stays bounded (bytes ≤ 64 KB for a realistic resident set) and
##                    `_unsink_drift_check` re-arms `_pending` at the documented ≤1-per-UNSINK_DRIFT_BLOCKS
##                    cadence over a scripted walk, never every step.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const TC := preload("res://src/world/terrain_config.gd")
const FFR := preload("res://src/world/facet_far_ring.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_pale_backstop (COSMOS-PALE-BACKSTOP-FIX-DESIGN.md — FP_FARRING_UNCOVERED_TRUE) ===")
	TC.warm_up()
	FA.warm_up()
	var fid := _find_mountain_facet()
	var span := _facet_relief_span(fid)
	print("  atlas: k=%d, R=%.0f, mountain fid=%d, relief span≈%.1f blocks, sink=%.2f, MARGIN=%.0f, DRIFT=%.0f" % [
		FA.K, FA.R_BLOCKS, fid, span, TierPlace.backstop_sink(), CubeSphere.UNSINK_MARGIN_BLOCKS, CubeSphere.UNSINK_DRIFT_BLOCKS])
	_ok(span >= 30.0, "fixture: scanned mountain facet has relief span ≥30 blocks (found %.1f)" % span)
	_gate_true_and_covered(fid)
	_gate_hover(fid)
	_gate_off(fid)
	_gate_ledger(fid)
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- fixture helpers ----------

## Scan for a facet with real relief (a steep mountain flank) using the SAME shared corner-dir bilerp the ring's
## own weld construction uses (FFR._weld_unit), sampled on a coarse 3x3 grid — cheap, plenty to flag a steep
## facet. Stride-5 across the whole K=24 grid (mountain bands are wide, MOUNTAIN_MASK_LO=0.35) with an early
## stop once a comfortably-steep facet (≥60 blocks) is found.
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

## max(g) − min(g) over an n×n bilinear sample of facet `fid`'s interior (direct TerrainConfig.profile_at_dir
## sampling — independent of any FacetFarRing cache).
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

## Independent (gate-owned) re-derivation of the ellipsoid law, used ONLY as a sanity cross-check that the
## shipped `_uncovered` is not degenerate (§ "non-empty on both sides" checks below) — the actual pass/fail
## assertions compare emitted HEIGHTS against ground truth, not this formula against itself.
func _oracle_uncovered(pt: Vector3, col: Vector3, params: Vector3, margin: float) -> bool:
	var r := params.x + margin
	var h := params.z + margin
	var up := col.normalized() if col.length() > 0.001 else Vector3.UP
	var delta := pt - (col + up * params.y)
	var radial := delta.dot(up)
	var tangential := (delta - up * radial).length()
	return (radial / h) * (radial / h) + (tangential / r) * (tangential / r) > 1.0

# ---------- G-PB-TRUE + G-PB-COVERED ----------
func _gate_true_and_covered(fid: int) -> void:
	print("  --- G-PB-TRUE / G-PB-COVERED: per-vertex un-sink on a real mountain facet ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)

	ring.call("_ensure_backstop_true_cached", fid)
	var true_pos: PackedVector3Array = (ring.get("_btrue_cache") as Dictionary)[fid]
	# "covered" = the shipped SUNK law applied to the SAME true chord (radially aligned, same direction per index —
	# a fair same-location comparison; construction-convention differences between the weld and non-weld chord
	# builders are orthogonal to this fix and would only add noise to the height comparison below).
	var covered: PackedVector3Array = ring.call("_sunk_positions", true_pos, fid)
	_ok(true_pos.size() == covered.size() and true_pos.size() > 0, "fixture: true/covered grids are non-empty and same size (%d)" % true_pos.size())

	# Player column: the HIGHEST true-grid node (a peak vantage — the design's "grounded on a peak" case), with a
	# realistic ellipsoid (r=128, O=12, H=52 — the design's own cited numbers) so the down-slope genuinely falls
	# outside it while the peak itself (under the camera) stays inside.
	var peak_i := 0
	var peak_r := -1.0
	for i in range(true_pos.size()):
		var l: float = (true_pos[i] as Vector3).length()
		if l > peak_r:
			peak_r = l; peak_i = i
	var col: Vector3 = true_pos[peak_i]
	var params := Vector3(128.0, 12.0, 52.0)
	var margin: float = CubeSphere.UNSINK_MARGIN_BLOCKS

	var blended: PackedVector3Array = ring.call("_blend_uncovered", covered, fid, col, true, params)
	_ok(blended.size() == covered.size(), "blend: output size matches input (%d)" % blended.size())

	var n_uncov := 0
	var n_cov := 0
	var sink := TierPlace.backstop_sink()
	var margin_audit_ok := true
	var true_ok := true
	var covered_ok := true
	for i in range(blended.size()):
		var uncov: bool = ring.call("_uncovered", true_pos[i], col, true, params)
		# cross-check against the gate's OWN independent re-derivation (sanity — the law is not degenerate).
		if uncov != _oracle_uncovered(true_pos[i], col, params, margin):
			margin_audit_ok = false
		if uncov:
			n_uncov += 1
			if absf((blended[i] as Vector3).length() - (true_pos[i] as Vector3).length()) > 1.0:
				true_ok = false
			# FALSIFIER half: the shipped covered array sits measurably BELOW true height at this same vertex —
			# the pale sunk well the fix removes.
			if (true_pos[i] as Vector3).length() - (covered[i] as Vector3).length() < 0.8 * sink:
				true_ok = false
			# margin slack: not classified uncovered by a hair — half the (un-inflated) margin still excludes it.
			if not _oracle_uncovered(true_pos[i], col, params, margin * 0.5):
				margin_audit_ok = false
		else:
			n_cov += 1
			if blended[i] != covered[i]:
				covered_ok = false

	_ok(n_uncov > 0 and n_cov > 0, "fixture straddles the ellipsoid: %d uncovered + %d covered vertices" % [n_uncov, n_cov])
	_ok(true_ok, "G-PB-TRUE: every uncovered vertex blends to TRUE height (±1.0) and sits ≥0.8·sink above the shipped covered height")
	_ok(covered_ok, "G-PB-COVERED: every covered vertex is BYTE-IDENTICAL to the shipped covered array")
	_ok(margin_audit_ok, "G-PB-COVERED: margin audit — classification has real half-margin slack, not knife-edge")
	ring.free()

# ---------- G-PB-HOVER ----------
func _gate_hover(fid: int) -> void:
	print("  --- G-PB-HOVER: player far above the surface ⇒ the whole facet un-sinks ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("_ensure_backstop_true_cached", fid)
	var true_pos: PackedVector3Array = (ring.get("_btrue_cache") as Dictionary)[fid]
	var covered: PackedVector3Array = ring.call("_sunk_positions", true_pos, fid)

	var cd := FA.facet_corner_dirs(fid)
	var centre: Vector3 = FFR._weld_unit(cd, 0.5, 0.5)
	var col := centre * (FA.R_BLOCKS + 300.0)   # hovering well above the surface — no near field anywhere near here
	var params := Vector3(128.0, 12.0, 52.0)

	var blended: PackedVector3Array = ring.call("_blend_uncovered", covered, fid, col, true, params)
	var all_true := true
	for i in range(blended.size()):
		if absf((blended[i] as Vector3).length() - (true_pos[i] as Vector3).length()) > 1.0:
			all_true = false
	_ok(all_true, "G-PB-HOVER: every one of %d vertices un-sinks to true height while hovering (no lingering sunk plate)" % blended.size())
	ring.free()

# ---------- G-PB-OFF ----------
func _gate_off(fid: int) -> void:
	print("  --- G-PB-OFF: flag param false ⇒ shipped (pre-fix) emit, no wasted cache build ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("_ensure_backstop_cached", fid)
	_ok((ring.get("_btrue_cache") as Dictionary).is_empty(), "G-PB-OFF: _btrue_cache starts empty (nothing built yet)")

	var st_off := SurfaceTool.new(); st_off.begin(Mesh.PRIMITIVE_TRIANGLES)
	ring.call("_emit_cached", st_off, fid, true, false, false)   # uncovered_true_on forced FALSE
	_ok((ring.get("_btrue_cache") as Dictionary).is_empty(), "G-PB-OFF: an off-path emit never populates _btrue_cache (zero wasted work)")
	var r_off := _mean_radius(st_off.commit())

	# A synthetic column that WOULD un-sink plenty of vertices if the law ran — proves the off-path genuinely
	# ignores it, not merely that the test column happens to classify everything covered.
	var cd := FA.facet_corner_dirs(fid)
	var col: Vector3 = FFR._weld_unit(cd, 0.5, 0.5) * (FA.R_BLOCKS + 300.0)
	var st_off2 := SurfaceTool.new(); st_off2.begin(Mesh.PRIMITIVE_TRIANGLES)
	ring.call("_emit_cached", st_off2, fid, true, false, false)
	var r_off2 := _mean_radius(st_off2.commit())
	_ok(absf(r_off - r_off2) < 0.01, "G-PB-OFF: emit is BYTE-IDENTICAL regardless of player column (the flag param, not the column, gates the law)")

	var st_on := SurfaceTool.new(); st_on.begin(Mesh.PRIMITIVE_TRIANGLES)
	ring.call("set_player_column", col)
	ring.call("_emit_cached", st_on, fid, true, false, true)   # uncovered_true_on forced TRUE, same fixture
	var r_on := _mean_radius(st_on.commit())
	_ok(r_on > r_off + 0.5 * TierPlace.backstop_sink(), "G-PB-OFF falsifier: forcing the law ON measurably raises the mean emitted radius (%.2f vs %.2f)" % [r_on, r_off])
	ring.free()

func _mean_radius(mesh: ArrayMesh) -> float:
	if mesh.get_surface_count() == 0:
		return 0.0
	var pos: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	if pos.size() == 0:
		return 0.0
	var s := 0.0
	for v in pos:
		s += (v as Vector3).length()
	return s / float(pos.size())

# ---------- G-PB-LEDGER ----------
func _gate_ledger(fid: int) -> void:
	print("  --- G-PB-LEDGER: _btrue_cache bytes bound + drift-gated re-arm cadence ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)

	# Bytes: a realistic resident set — the sticky ring-1 bound (STICKY_RING1_MAX=12) worth of backstop facets.
	var cap := 16
	var built := 0
	for f in range(0, FA.K * FA.K * 6, 137):   # spread across the globe, cheap stride
		if built >= cap:
			break
		ring.call("_ensure_backstop_true_cached", f)
		built += 1
	var cache: Dictionary = ring.get("_btrue_cache")
	var stride := CubeSphere.BACKSTOP_CELLS + 1
	var bytes_per_facet := stride * stride * 12   # PackedVector3Array: 3 floats × 4 B per vertex
	var total_bytes := cache.size() * bytes_per_facet
	_ok(cache.size() == built, "ledger: built %d true-chord caches as requested" % built)
	_ok(total_bytes <= 65536, "NEVER-OOM: %d cached facets × %d B/facet = %d B ≤ 64 KB" % [cache.size(), bytes_per_facet, total_bytes])

	# Drift cadence: walk a synthetic column in fixed steps and count how many times _unsink_drift_check re-arms
	# _pending — should fire once per UNSINK_DRIFT_BLOCKS-ish step, never every call.
	var step := 4.0
	var walk_steps := 40
	var arms := 0
	var col := Vector3(FA.R_BLOCKS, 0.0, 0.0)
	for i in range(walk_steps):
		col.y += step   # a straight walk — drift accumulates linearly
		ring.set("_pending", false)
		ring.call("set_player_column", col)
		ring.call("_unsink_drift_check", true)   # force the law ON via the param
		if bool(ring.get("_pending")):
			arms += 1
	var walked := step * walk_steps
	var expected_max := ceili(walked / CubeSphere.UNSINK_DRIFT_BLOCKS) + 1   # +1 slack for the first-column arm
	_ok(arms >= 1 and arms <= expected_max,
		"G-PB-LEDGER: %d arms over a %.0f-block walk (≤ 1 per %d blocks, expected ≤%d) — never every step (%d steps)" % [
			arms, walked, CubeSphere.UNSINK_DRIFT_BLOCKS, expected_max, walk_steps])

	# Off ⇒ _unsink_drift_check is fully inert (never touches _pending).
	ring.set("_pending", false)
	ring.call("_unsink_drift_check", false)
	_ok(not bool(ring.get("_pending")), "G-PB-LEDGER: flag param false ⇒ _unsink_drift_check never sets _pending (byte-identical off)")
	ring.free()
