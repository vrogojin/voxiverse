extends SceneTree
## COSMOS NO-PROTRUSION gate (docs/COSMOS-NO-PROTRUSION-FIDELITY-DESIGN.md §0.4) — G-NPT. Proves the user HARD
## invariant: the coarse/far tier NEVER protrudes UP through the fine near terrain, in EVERY regime (surface /
## orbit / descent), independent of roles / sticky / coverage. Extends verify_tier_depth.gd's SKEW-AWARE poke
## oracle: it reconstructs the AS-RENDERED far-ring triangle surface from the emitted caches (coarse horizon
## `_ensure_cached` + dense backstop `_ensure_backstop_cached`, the emit sink applied) and projects it onto the
## pitch-1 near truth (`profile_at_dir`, the one generator) ALONG THE FACET NORMAL (world_to_lattice64) — the
## projection a naive radial compare omits, and where R-A (un-sunk concave chord) and R-B (orbit) actually poke.
##
##   G-NPT-SURF   — M≥12 curvature-SELECTED facets (concave / mountain), each as a coarse HORIZON facet; N≥10k
##                  random dirs/facet vs true; assert rendered ≤ true with ZERO violations. Today FAILS (R-A).
##   G-NPT-ORBIT  — same, with the shell driven into `_shell_orbit` (shell_set_camera_abs floored=false) so every
##                  facet emits the un-sunk coarse cache. Today FAILS (R-B). FP_ENV_ALL turns it green.
##   G-NPT-DESCENT— floored=true with near meshes simulated present (pool/sticky harness); assert the invariant
##                  holds through the deferred-rebuild window (per-role reconstruct: backstop dense + coarse).
##   G-NPT-BOUND  — the measured between-fine-sample RAW residual (rendered WITHOUT sink − true) across the M
##                  facets; pins ε empirically (assert worst residual < ε so the retained sink covers it).
##   G-NPT-EDIT   — STUB (Phase N2 / FP_ENV_EDITS): a dug pit deeper than ε must not show the coarse tier through
##                  the excavation floor. Not implemented here — left as a clear marker.
##
## Each sub-gate is FALSIFIABLE: with FP_ENV_ALL off (the coarse cache is the shipped exact chord and no ε sink is
## applied to it) the violations REAPPEAR — that failing baseline IS the proof the gate catches the real bug. The
## in-run CONTRAST (an exact-chord reconstruction) is printed alongside so a single run shows env vs exact.
##
## RUN (green, FP_ENV_ALL on — with the full deploy set): sed FACETED + FP_FARRING_FULL_COVER + FP_SHELL_WELD +
##   FP_TIER_ENVELOPE + FP_TIER_STICKY_BACKSTOP + FP_TIER_WARM_CONVERGE + FP_FARRING_FULL_COVER + FP_ENV_ALL true:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_no_protrusion.gd
##   FALSIFY: same set with FP_ENV_ALL false → G-NPT-SURF / G-NPT-ORBIT go RED (R-A / R-B reappear).

const FA := preload("res://src/cosmos/facet_atlas.gd")
const FFR := preload("res://src/world/facet_far_ring.gd")
const CELLS := 4
const N_PROBE := 12000            # random directions per facet (≥ 10k, design §0.4)
const M_FACETS := 24              # curvature-selected facets (≥ 12; 24 to better bound the global-worst residual for ε)

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

var _rng := RandomNumberGenerator.new()

func _initialize() -> void:
	print("=== verify_no_protrusion (G-NPT: far tier never pokes UP through the near terrain) ===")
	if not CubeSphere.FACETED or not CubeSphere.FP_FARRING_FULL_COVER:
		print("  FAIL: needs FACETED + FP_FARRING_FULL_COVER sed-toggled true.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	TerrainConfig.warm_up()
	FA.warm_up()
	_rng.seed = 0x0C0FFEE                 # deterministic probe set (repeatable worst deltas)
	var active := FA.spawn_facet()
	TerrainConfig.set_active_facet(active)
	print("  flags: FP_ENV_ALL=%s env_all_on=%s FP_TIER_ENVELOPE=%s FP_SHELL_WELD=%s | eps(sink)=%.2f CELLS=%d BACKSTOP_CELLS=%d" % [
		str(CubeSphere.FP_ENV_ALL), str(TierPlace.env_all_on()), str(CubeSphere.FP_TIER_ENVELOPE),
		str(CubeSphere.FP_SHELL_WELD), TierPlace.backstop_sink(), CELLS, CubeSphere.BACKSTOP_CELLS])
	# SELECT the M worst facets by profile CURVATURE (concave/relief), not hand-picked — this is where the chord
	# over-estimate lives. Keep them AWAY from the active facet so they reconstruct as coarse HORIZON facets (R-A).
	var sel := _select_curved_facets(M_FACETS, active)
	print("  selected %d curvature facets: %s" % [sel.size(), str(sel)])

	_gate_surf(active, sel)
	_gate_orbit(active, sel)
	_gate_descent(active, sel)
	_gate_bound(active, sel)
	_gate_weld(active, sel)
	_gate_mid_dense_ledger(active)
	_gate_edit_stub()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# =====================================================================================================
# G-NPT-SURF — the far surface never rises above the near tops on the worst (concave / mountain) facets.
# =====================================================================================================
func _gate_surf(active: int, sel: Array) -> void:
	print("  --- G-NPT-SURF: coarse HORIZON far surface ≤ near truth over %d curvature facets (%d random dirs each) ---" % [sel.size(), N_PROBE])
	var ring: Node3D = _mk_ring(active)
	var worst := -1.0e30
	var worst_fid := -1
	var contrast := -1.0e30            # the un-enveloped EXACT chord over the SAME facets (what env replaces)
	var contrast_fid := -1
	for fid in sel:
		# As RENDERED coarse horizon (env lower bound + ε sink when FP_ENV_ALL; the shipped exact chord otherwise).
		var gp: PackedVector3Array = ring.call("horizon_rendered_positions", fid)
		var m := _probe_random(fid, gp, CELLS, N_PROBE)
		if m > worst:
			worst = m; worst_fid = fid
		# CONTRAST: the plain exact-height CELLS=4 chord (no envelope, no sink) — reconstructed in-gate.
		var ex := _exact_positions(fid, CELLS, 0.0)
		var cm := _probe_random(fid, ex, CELLS, N_PROBE)
		if cm > contrast:
			contrast = cm; contrast_fid = fid
	# §1 F2 (FP_MID_DENSE): fold the AS-RENDERED DENSE reconstruction of each facet — promoted into the ring-2 disc
	# around its own centre — into the SAME `worst` accumulator + assertion. So with the flag on, the mid-distance
	# dense tier the player looks at is covered by G-NPT-SURF's zero-protrusion contract too (no new assertion → the
	# 32/0 count is unmoved). Each facet is probed at BACKSTOP_CELLS as the live emit draws it (backstop_rendered_positions
	# = the ε-sunk dense envelope cache). Off ⇒ this block is skipped (byte-identical to the coarse-only reconstruction).
	var dense_worst := -1.0e30
	var dense_fid := -1
	var dense_cnt := 0
	if CubeSphere.FP_MID_DENSE:
		for fid in sel:
			var c := _centre_dir(fid)
			ring.call("_recompute_mid_dense", [[c.x, c.y, c.z], 0.0])
			if not bool(ring.call("is_mid_dense_promoted", fid)):
				continue
			dense_cnt += 1
			var dp: PackedVector3Array = ring.call("backstop_rendered_positions", fid)
			var dm := _probe_random(fid, dp, CubeSphere.BACKSTOP_CELLS, N_PROBE)
			if dm > dense_worst:
				dense_worst = dm; dense_fid = fid
			if dm > worst:
				worst = dm; worst_fid = fid
		print("    F2 mid-dense: %d/%d selected facets promoted+reconstructed DENSE; dense worst protrusion = %+.2f blocks (facet %d)" % [dense_cnt, sel.size(), dense_worst, dense_fid])
	_ok(worst <= 0.0,
		"G-NPT-SURF: rendered far surface ≤ near truth (worst protrusion %+.2f blocks, facet %d, need ≤ 0)" % [worst, worst_fid])
	print("    rendered worst protrusion = %+.2f blocks (facet %d); exact-chord CONTRAST = %+.2f blocks (facet %d)" % [worst, worst_fid, contrast, contrast_fid])
	# The contrast MUST poke (the un-enveloped chord over concave terrain rises above near) — proves the facet
	# selection actually exercises R-A and the gate is not vacuously green.
	_ok(contrast > 0.0,
		"G-NPT-SURF-CONTRAST: the un-enveloped exact chord DOES poke (%+.2f > 0) — the selected facets exercise R-A" % contrast)
	ring.free()

# =====================================================================================================
# G-NPT-ORBIT — the un-sunk orbit emission path (`_shell_orbit`): every facet a coarse cache, no backstop role.
# =====================================================================================================
func _gate_orbit(active: int, sel: Array) -> void:
	print("  --- G-NPT-ORBIT: shell driven off-surface (_shell_orbit) — every facet emits the coarse cache ---")
	var ring: Node3D = _mk_ring(active)
	# Engage the camera-set law OFF-SURFACE so _shell_orbit() is true ⇒ _is_backstop == false for all facets.
	var c := _centre_dir(active)
	ring.call("shell_set_camera_abs", [c.x, c.y, c.z], FA.R_BLOCKS + 1323.0, false)
	_ok(bool(ring.call("_shell_orbit")), "G-NPT-ORBIT: shell engaged into the off-surface orbit regime")
	var worst := -1.0e30
	var worst_fid := -1
	for fid in sel:
		# In orbit _is_backstop(fid) is false ⇒ the facet renders the coarse cache; reconstruct exactly that.
		_ok(not bool(ring.call("is_backstop", fid)), "G-NPT-ORBIT: facet %d is a coarse (non-backstop) emit in orbit" % fid)
		var gp: PackedVector3Array = ring.call("horizon_rendered_positions", fid)
		var m := _probe_random(fid, gp, CELLS, N_PROBE)
		if m > worst:
			worst = m; worst_fid = fid
	_ok(worst <= 0.0,
		"G-NPT-ORBIT: orbit far surface ≤ near truth (worst protrusion %+.2f blocks, facet %d, need ≤ 0)" % [worst, worst_fid])
	print("    orbit rendered worst protrusion = %+.2f blocks (facet %d)" % [worst, worst_fid])
	ring.free()

# =====================================================================================================
# G-NPT-DESCENT — floored (surface) with near meshes simulated present: per-role reconstruct (dense backstop +
# coarse horizon) and assert the invariant holds through the deferred-rebuild window (the G-TIER-STICKY harness).
# =====================================================================================================
func _gate_descent(active: int, sel: Array) -> void:
	print("  --- G-NPT-DESCENT: floored + near meshes present — backstop AND coarse facets stay ≤ near truth ---")
	var ring: Node3D = _mk_ring(active)                       # surface (floored); sticky seeds ring-1 as sunk backstops
	# Simulate near meshes arriving: push some front facets into the pool so they become backstop (RC-B window).
	var pool := PackedInt32Array()
	for slot in range(4):
		var nb := FA.seam_neighbour(active, slot)
		if nb >= 0:
			pool.append(nb)
	ring.call("set_pool_excluded", pool)
	# Probe BOTH the pooled/sticky backstop facets AND the curvature horizon facets — every emitted role.
	var probe := []
	probe.append(active)
	for f in pool:
		probe.append(int(f))
	for f in sel:
		if not probe.has(int(f)):
			probe.append(int(f))
	var worst := -1.0e30
	var worst_fid := -1
	var worst_role := ""
	for fid in probe:
		var is_bs := bool(ring.call("is_backstop", fid))
		var gp: PackedVector3Array
		var cells := CELLS
		if is_bs:
			gp = ring.call("backstop_rendered_positions", fid)
			cells = CubeSphere.BACKSTOP_CELLS
		else:
			gp = ring.call("horizon_rendered_positions", fid)
		var m := _probe_random(fid, gp, cells, N_PROBE)
		if m > worst:
			worst = m; worst_fid = fid; worst_role = ("backstop" if is_bs else "horizon")
	_ok(worst <= 0.0,
		"G-NPT-DESCENT: every emitted role ≤ near truth through the window (worst %+.2f blocks, facet %d [%s], need ≤ 0)" % [worst, worst_fid, worst_role])
	print("    descent worst protrusion = %+.2f blocks (facet %d, role %s)" % [worst, worst_fid, worst_role])
	ring.free()

# =====================================================================================================
# G-NPT-BOUND — measure the RAW between-fine-sample residual (rendered WITHOUT the ε sink − true) and assert it is
# below ε, so the retained emit-time sink provably covers it. Pins ε empirically (design §0.4).
# =====================================================================================================
func _gate_bound(active: int, sel: Array) -> void:
	var eps := TierPlace.backstop_sink()
	print("  --- G-NPT-BOUND: raw (un-sunk) residual across %d facets must be < ε=%.2f (pins the sink) ---" % [sel.size(), eps])
	var ring: Node3D = _mk_ring(active)
	var worst := -1.0e30
	var worst_fid := -1
	for fid in sel:
		# RAW coarse cache (no sink) — the height the envelope stores; residual over true is what ε must cover.
		var raw: PackedVector3Array = ring.call("horizon_positions", fid)
		var m := _probe_random(fid, raw, CELLS, N_PROBE)
		if m > worst:
			worst = m; worst_fid = fid
	_ok(worst < eps,
		"G-NPT-BOUND: worst raw residual %+.2f < ε=%.2f (the retained ε sink covers it; facet %d)" % [worst, eps, worst_fid])
	print("    raw residual worst = %+.2f blocks (facet %d); ε = %.2f" % [worst, worst_fid, eps])
	ring.free()

# =====================================================================================================
# G-NPT-EDIT — STUB (Phase N2 / FP_ENV_EDITS). A dug pit deeper than ε must not reveal the coarse tier through the
# excavation floor: fold the fid-keyed edit overlay into the min (env(v)=min(env_gen, exposed_top(edit_column)))
# and assert rendered ≤ pit floor − ε, then revert to a bit-exact baseline. NOT implemented in N1 — placeholder.
# =====================================================================================================
func _gate_edit_stub() -> void:
	print("  --- G-NPT-EDIT: SKIPPED (Phase N2 / FP_ENV_EDITS — not part of N0/N1) ---")

# =====================================================================================================
# G-NPT-MIDDENSE-LEDGER (§1 F2 / FP_MID_DENSE) — the mid-ring dense promotion is NEVER-OOM bounded. A ring-2 disc is
# a FIXED angular set (~ring-2 count) and promoted caches are reaped as the sub-point moves, so the extra dense-cache
# memory is bounded to a small ceiling (design: ~+16 facets ≈ +130 KB). Promote a disc, count the promoted facets and
# their dense-cache bytes, and assert both stay under a hard ceiling. SKIPPED (no assertion) with the flag off, so the
# MID-off run is exactly the shipped 32/0.
# =====================================================================================================
const MID_DENSE_FACET_CEIL := 40            # NEVER-OOM ceiling on concurrently-promoted facets (ring-2 disc ≈ 13-20)
const DENSE_BYTES_PER_FACET := 8092         # (BACKSTOP_CELLS+1)² × (Vector3 12 B + Color 16 B) = 289 × 28
func _gate_mid_dense_ledger(active: int) -> void:
	if not CubeSphere.FP_MID_DENSE:
		print("  --- G-NPT-MIDDENSE-LEDGER: SKIPPED (FP_MID_DENSE off) ---")
		return
	print("  --- G-NPT-MIDDENSE-LEDGER: the ring-2 dense promotion is NEVER-OOM bounded ---")
	var ring: Node3D = _mk_ring(active)
	# Promote the disc around a spread of sub-points; take the WORST (largest) promoted count as the ceiling witness.
	var worst_cnt := 0
	var probe := [active]
	for f in _select_curved_facets(6, active):
		probe.append(int(f))
	for center in probe:
		var c := _centre_dir(center)
		ring.call("_recompute_mid_dense", [[c.x, c.y, c.z], 0.0])
		worst_cnt = maxi(worst_cnt, int(ring.call("mid_dense_count")))
	var kb := float(worst_cnt * DENSE_BYTES_PER_FACET) / 1024.0
	_ok(worst_cnt <= MID_DENSE_FACET_CEIL,
		"G-NPT-MIDDENSE-LEDGER: promoted facets %d ≤ %d ceiling (≈ %.0f KB extra dense cache ≤ %.0f KB); NEVER-OOM bounded" % [
			worst_cnt, MID_DENSE_FACET_CEIL, kb, float(MID_DENSE_FACET_CEIL * DENSE_BYTES_PER_FACET) / 1024.0])
	print("    worst promoted disc = %d facets ≈ %.0f KB extra dense cache (ceiling %d facets / %.0f KB)" % [
		worst_cnt, kb, MID_DENSE_FACET_CEIL, float(MID_DENSE_FACET_CEIL * DENSE_BYTES_PER_FACET) / 1024.0])
	ring.free()

# =====================================================================================================
# G-NPT-WELD — the EDGE-CANON envelope still WELDS (a fast, self-contained subset of verify_shell_weld @ env_all):
# a coarse env facet's shared-edge vertices coincide with its neighbour's (coarse↔coarse), and a dense backstop's
# coarse-index edge vertices land on the coarse horizon boundary (coarse↔dense T-junction). Both build on the
# SHARED corner-dir EDGE-CANON rule (disc corners + line/band coarse-index edges) ⇒ identical values ⇒ no slit.
# Under FP_ENV_ALL this exercises the new builders; with it off it degrades to the shipped exact-chord weld.
# =====================================================================================================
func _gate_weld(active: int, sel: Array) -> void:
	print("  --- G-NPT-WELD: EDGE-CANON coarse↔coarse + coarse↔dense shared edges weld (≤ 1e-3 blocks) ---")
	var ring: Node3D = _mk_ring(active)
	# Sample facets: the curvature set + the active + its ring — a representative seam spread (not all 13824, which
	# under env_all would rebuild every facet's heavy cache; this proves the weld property on the worst terrain).
	var probe := [active]
	for slot in range(4):
		var nb := FA.seam_neighbour(active, slot)
		if nb >= 0 and not probe.has(nb):
			probe.append(nb)
	for f in sel:
		if not probe.has(int(f)):
			probe.append(int(f))
	var worst_cc := 0.0            # coarse↔coarse shared-edge gap
	var worst_t := 0.0             # coarse↔dense coarse-node gap (T-junction)
	for fidA in probe:
		var pa: PackedVector3Array = ring.call("horizon_positions", fidA)          # coarse env cache (raw, un-sunk)
		var da: PackedVector3Array = ring.call("backstop_raw_positions", fidA)      # dense env cache (raw, un-sunk)
		for slot in range(4):
			var fidB := FA.seam_neighbour(fidA, slot)
			if fidB < 0:
				continue
			var pb: PackedVector3Array = ring.call("horizon_positions", fidB)
			var bnd := _boundary_verts(pb, CELLS)
			# coarse↔coarse: every A-edge vert coincides with some B-boundary vert.
			worst_cc = maxf(worst_cc, _max_min_dist(_edge_verts(pa, CELLS, slot), bnd))
			# coarse↔dense T-junction: A's dense coarse-INDEX edge verts land on B's coarse boundary.
			var cstride := CubeSphere.BACKSTOP_CELLS / CELLS
			var ea := _edge_verts(da, CubeSphere.BACKSTOP_CELLS, slot)
			for i in range(ea.size()):
				if i % cstride != 0:
					continue
				var best := 1.0e18
				for vb in bnd:
					best = minf(best, ea[i].distance_to(vb))
				worst_t = maxf(worst_t, best)
	_ok(worst_cc <= 1.0e-3, "G-NPT-WELD: coarse↔coarse env edges weld (worst gap %.5f ≤ 1e-3)" % worst_cc)
	_ok(worst_t <= 1.0e-3, "G-NPT-WELD-T: dense coarse-node env verts land on the coarse horizon (worst gap %.5f ≤ 1e-3)" % worst_t)
	print("    coarse↔coarse worst gap = %.5f ; coarse↔dense coarse-node worst gap = %.5f blocks" % [worst_cc, worst_t])
	ring.free()

## Edge / boundary vertex extraction from a (cells+1)² grid (index gj*stride+gi) — mirrors verify_shell_weld.
func _edge_verts(pos: PackedVector3Array, cells: int, slot: int) -> PackedVector3Array:
	var stride := cells + 1
	var out := PackedVector3Array()
	for i in range(cells + 1):
		match slot:
			0: out.append(pos[i * stride + cells])   # East
			1: out.append(pos[i * stride + 0])        # West
			2: out.append(pos[cells * stride + i])    # North
			_: out.append(pos[0 * stride + i])        # South
	return out

func _boundary_verts(pos: PackedVector3Array, cells: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for slot in range(4):
		out.append_array(_edge_verts(pos, cells, slot))
	return out

func _max_min_dist(a: PackedVector3Array, b: PackedVector3Array) -> float:
	var worst := 0.0
	for va in a:
		var best := 1.0e18
		for vb in b:
			best = minf(best, va.distance_to(vb))
		worst = maxf(worst, best)
	return worst

## Light ring init for the gate: the lazy cache accessors (horizon_rendered_positions / backstop_rendered_positions)
## build ONLY the facets we probe, so we deliberately AVOID setup()'s full front-hemisphere _rebuild_full (which, under
## FP_ENV_ALL, would build ~1700 heavy EDGE-CANON caches). We seed exactly the role state _is_backstop reads: the
## active fid + the sticky ring-1 set (_recompute_sticky). set_pool_excluded / shell_set_camera_abs add the rest.
func _mk_ring(active: int) -> Node3D:
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.set("_active_fid", active)
	ring.call("_recompute_sticky")
	return ring

# --------------------------------- reconstruction / probe helpers ---------------------------------

## Worst positive margin (rendered − true) over N random directions inside facet `fid`. Mirrors verify_tier_depth's
## SKEW-AWARE poke oracle: bilerp the rendered grid at a random coarse-cell coord, project that world point onto the
## near height field ALONG THE FACET NORMAL (world_to_lattice64 splits n̂-height from in-plane position), and compare
## the far n̂-height to the near block TOP (g+1) at the in-plane column it overlays. margin > 0 ⇔ the far tier pokes.
func _probe_random(fid: int, gp: PackedVector3Array, cells: int, n: int) -> float:
	var worst := -1.0e30
	for i in range(n):
		var s := _rng.randf() * float(cells)
		var t := _rng.randf() * float(cells)
		var P := _bilerp_vec3(gp, cells, s, t)
		var lat := FA.world_to_lattice64(fid, P.x, P.y, P.z)
		var h_far: float = lat[1]
		var plane := FA.lattice_to_world64(fid, lat[0], 0.0, lat[2])
		var dir := Vector3(plane[0], plane[1], plane[2]).normalized()
		var g_near := int(TerrainConfig.profile_at_dir(dir.x, dir.y, dir.z, FA.R_BLOCKS).x)
		var margin := h_far - float(g_near + 1)   # near top face is at g+1 along n̂
		if margin > worst:
			worst = margin
	return worst

## The plain EXACT-height CELLS chord for facet `fid` (profile_at_dir per coarse vertex, radial relief, pushed in by
## `sink`) — the shipped un-enveloped placement, reconstructed in-gate for the R-A contrast (independent of any flag).
func _exact_positions(fid: int, cells: int, sink: float) -> PackedVector3Array:
	var c0 := FA.facet_planar_corner(fid, 0)
	var c1 := FA.facet_planar_corner(fid, 1)
	var c2 := FA.facet_planar_corner(fid, 2)
	var c3 := FA.facet_planar_corner(fid, 3)
	var stride := cells + 1
	var out := PackedVector3Array()
	out.resize(stride * stride)
	for gj in range(stride):
		for gi in range(stride):
			var s := float(gi) / float(cells)
			var t := float(gj) / float(cells)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var dx := bx / ln; var dy := by / ln; var dz := bz / ln
			var g := int(TerrainConfig.profile_at_dir(dx, dy, dz, FA.R_BLOCKS).x)
			var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL))
			var vx := bx + dx * relief; var vy := by + dy * relief; var vz := bz + dz * relief
			var vln := sqrt(vx * vx + vy * vy + vz * vz)
			out[gj * stride + gi] = Vector3(vx - vx / vln * sink, vy - vy / vln * sink, vz - vz / vln * sink)
	return out

## SELECT the M facets with the worst profile CURVATURE (concave sag) blended with relief span — the terrain where a
## linear chord most over-estimates. Sampled on a 5×5 g grid per facet (max |second difference| + hi-lo relief).
## Excludes the active facet and its 4 seam neighbours (they are sticky backstops; we want coarse HORIZON facets).
func _select_curved_facets(m: int, active: int) -> Array:
	var avoid := {active: true}
	for slot in range(4):
		var nb := FA.seam_neighbour(active, slot)
		if nb >= 0:
			avoid[nb] = true
	var k := FA.K
	var ng := 5
	var ranked := []
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if avoid.has(fid):
					continue
				var grid := []
				grid.resize(ng * ng)
				var lo := 1 << 30
				var hi := -(1 << 30)
				for gj in range(ng):
					for gi in range(ng):
						var g := _g_at(_col_dir(fid, float(gi) / float(ng - 1), float(gj) / float(ng - 1)))
						grid[gj * ng + gi] = g
						lo = mini(lo, g); hi = maxi(hi, g)
				# curvature proxy = worst |g(i-1) − 2g(i) + g(i+1)| over rows and columns (concave sag ⇒ chord pokes).
				var curv := 0
				for gj in range(ng):
					for gi in range(1, ng - 1):
						curv = maxi(curv, abs(grid[gj * ng + gi - 1] - 2 * grid[gj * ng + gi] + grid[gj * ng + gi + 1]))
				for gi in range(ng):
					for gj in range(1, ng - 1):
						curv = maxi(curv, abs(grid[(gj - 1) * ng + gi] - 2 * grid[gj * ng + gi] + grid[(gj + 1) * ng + gi]))
				ranked.append([curv * 8 + (hi - lo), fid])   # curvature dominates, relief breaks ties
	ranked.sort_custom(func(x, y): return x[0] > y[0])
	var out := []
	for i in range(mini(m, ranked.size())):
		out.append(int(ranked[i][1]))
	return out

# --- shared helpers (mirroring verify_tier_depth.gd so the two gates read the same surface the same way) ---
func _centre_dir(fid: int) -> Vector3:
	var s := Vector3.ZERO
	for ci in range(4):
		var c := FA.facet_planar_corner(fid, ci)
		s += Vector3(c[0], c[1], c[2])
	return s.normalized()

static func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

func _bilerp_vec3(gp: PackedVector3Array, cells: int, s: float, t: float) -> Vector3:
	var stride := cells + 1
	var fs := clampf(s, 0.0, float(cells))
	var ft := clampf(t, 0.0, float(cells))
	var ci := mini(int(fs), cells - 1)
	var cj := mini(int(ft), cells - 1)
	var ls := fs - float(ci)
	var lt := ft - float(cj)
	var v00 := gp[cj * stride + ci]
	var v10 := gp[cj * stride + ci + 1]
	var v11 := gp[(cj + 1) * stride + ci + 1]
	var v01 := gp[(cj + 1) * stride + ci]
	return v00 * (1.0 - ls) * (1.0 - lt) + v10 * ls * (1.0 - lt) + v11 * ls * lt + v01 * (1.0 - ls) * lt

func _g_at(d: Vector3) -> int:
	return int(TerrainConfig.profile_at_dir(d.x, d.y, d.z, FA.R_BLOCKS).x)

func _col_dir(fid: int, s: float, t: float) -> Vector3:
	var c0 := FA.facet_planar_corner(fid, 0)
	var c1 := FA.facet_planar_corner(fid, 1)
	var c2 := FA.facet_planar_corner(fid, 2)
	var c3 := FA.facet_planar_corner(fid, 3)
	var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
	var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
	var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
	return Vector3(bx, by, bz).normalized()
