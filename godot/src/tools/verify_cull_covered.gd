extends SceneTree
## G-CV — FP_FARRING_CULL_COVERED (COSMOS TEXTURED-LOD U2, §2U.3): the far ring STOPS emitting a backstop cell once the
## near voxel field fully covers it (occlusion cull), so near and far never coexist there — no z-fight, no poke-through,
## no see-under. The CORRECTNESS-CRITICAL property is the SEAM-SAFETY of the asymmetric hysteresis, proved headlessly by
## driving the pure state machine `cull_feed` with a mocked coverage signal (no godot_voxel needed):
##
##   G-CV-SAFE     — for EVERY step of scripted dig/ascend/sprint drives (near un-meshes ⇒ coverage flips false), the
##                   culled set is a subset of the currently-covered set: culled ⇒ covered, ALWAYS. Equivalently
##                   (near covers cell) OR (far cell emitted) every frame → NEVER a hole. This is the no-hole proof.
##   G-CV-REAPPEAR — a culled cell un-culls INSTANTLY (same step) on the first uncovered read → prompt re-emit; and the
##                   probe AABB is dilated by +CULL_DILATE so the cell re-emits while the tight cell is still covered.
##   G-CV-CHURN    — culling needs CULL_CONFIRM consecutive covered reads: a jittering signal never culls; a settled
##                   standing-still signal (stable covered OR stable uncovered) produces ZERO mask changes / rebuilds.
##
## Plus byte-identity (is_cell_culled == false with the flag off, even with a populated mask) and the module-fallback
## (invalid coverage callable ⇒ cull inert). Exits 0 all-pass, 1 on any failure. Flag-independent (drives the state
## machine directly); byte-off is additionally covered by verify_feature (FLAT 6042/0).

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	print(("  PASS " if c else "  FAIL ") + m)
	if c: _pass += 1
	else: _fail += 1

# --- mock coverage callables (stand in for module_world.skin_near_meshed) ---
func _cover_true(_fid: int, _aabb: AABB) -> bool: return true
func _cover_false(_fid: int, _aabb: AABB) -> bool: return false

func _initialize() -> void:
	print("=== verify_cull_covered (G-CV: FP_FARRING_CULL_COVERED) ===")
	FacetAtlas.warm_up()
	var CONFIRM: int = CubeSphere.CULL_CONFIRM
	var CELLS: int = CubeSphere.BACKSTOP_CELLS
	var NCELL := CELLS * CELLS

	# ---------------------------------------------------------------------------------------------------------------
	# G-CV-CHURN part 1 — a cell must read covered CULL_CONFIRM times CONSECUTIVELY before it culls (2-to-cull).
	# ---------------------------------------------------------------------------------------------------------------
	var ring := FacetFarRing.new()
	var fid := 300
	# One covered read is NOT enough (CONFIRM >= 2): still emitted after 1.
	var culled_after_1 := ring.cull_feed(fid, 0, true)
	_ok(not culled_after_1, "CHURN: 1 covered read does NOT cull (needs %d)" % CONFIRM)
	# CONFIRM consecutive covered reads DO cull.
	var culled := false
	for i in range(CONFIRM - 1):
		culled = ring.cull_feed(fid, 0, true)
	_ok(culled, "CHURN: %d consecutive covered reads CULL" % CONFIRM)
	# Jitter: covered,uncovered,covered,uncovered,... on a FRESH cell never reaches culled (streak resets each uncover).
	var jitter_culled := false
	for i in range(40):
		jitter_culled = jitter_culled or ring.cull_feed(fid, 5, (i % 2) == 0)
	_ok(not jitter_culled, "CHURN: a jittering signal (cover/uncover) NEVER culls — no flip-flop")
	ring.free()

	# ---------------------------------------------------------------------------------------------------------------
	# G-CV-REAPPEAR — a culled cell un-culls INSTANTLY on the first uncovered read (holes worse than overdraw).
	# ---------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	for i in range(CONFIRM):
		ring.cull_feed(fid, 7, true)
	_ok(ring.cull_feed(fid, 7, true), "REAPPEAR: cell is culled after settling covered")   # still covered → stays culled
	var reappeared := not ring.cull_feed(fid, 7, false)                                     # first uncovered read
	_ok(reappeared, "REAPPEAR: first UNcovered read un-culls INSTANTLY (same step) → re-emits")
	# And re-culling again needs the FULL CONFIRM streak from scratch (streak was reset), not 1.
	_ok(not ring.cull_feed(fid, 7, true), "REAPPEAR: streak reset — a single covered read after un-cull does NOT re-cull")
	ring.free()

	# ---------------------------------------------------------------------------------------------------------------
	# G-CV-SAFE — THE INVARIANT. Drive scripted dig/ascend/sprint timelines over a 16×16 cell grid and assert, after
	# EVERY feed of EVERY step, culled ⇒ covered (the culled set ⊆ the currently-covered set) → no cell is ever
	# absent while its area is uncovered (no hole). `covered[ci]` is the mocked near-coverage truth for this step.
	# ---------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xC0FFEE
	var safe_ok := true
	var worst_step := -1
	# Model a moving "near disk" boundary that expands (walk in), retreats (dig/ascend un-meshes near), and sprints
	# (fast boundary sweep) — the exact transitions §2U.5 E1 warns about. coverage of cell ci = (ci in the disk).
	var STEPS := 600
	for step in range(STEPS):
		# Boundary radius oscillates + a sprint phase (fast jumps) + a dig phase (sudden collapse to a small disk).
		var t := float(step)
		var base_r := 8.0 + 6.0 * sin(t * 0.05)                       # slow breathing near disk (walk in/out)
		if (step / 40) % 5 == 4:
			base_r = 2.0                                             # DIG/ASCEND: near collapses → most cells uncover
		var sprint := 4.0 * sin(t * 0.9) if (step / 40) % 5 == 2 else 0.0   # SPRINT: fast boundary sweep
		var disk_r := maxf(0.0, base_r + sprint)
		var cx := 8.0 + 4.0 * sin(t * 0.03)                          # the disk also drifts (crossing facets)
		var cz := 8.0 + 4.0 * cos(t * 0.031)
		for cj in range(CELLS):
			for ci in range(CELLS):
				var d := Vector2(float(ci) - cx, float(cj) - cz).length()
				# a little probe noise near the boundary (is_area_meshed is not perfectly monotone) to stress hysteresis
				var covered := d <= disk_r
				if absf(d - disk_r) < 0.7:
					covered = rng.randf() < 0.5
				var idx := cj * CELLS + ci
				var bit := ring.cull_feed(fid, idx, covered)
				# THE ASSERT: a culled cell must be covered THIS step (else it would be a hole).
				if bit and not covered:
					safe_ok = false
					if worst_step < 0: worst_step = step
	_ok(safe_ok, "SAFE: over %d steps × %d cells of dig/ascend/sprint, culled ⇒ covered EVERY step (no hole)%s"
		% [STEPS, NCELL, ("" if safe_ok else "  VIOLATED first at step %d" % worst_step)])
	ring.free()

	# ---------------------------------------------------------------------------------------------------------------
	# G-CV-CHURN part 2 — standing still (a settled, unchanging coverage signal) produces ZERO mask changes → no
	# re-emit churn. Both a stable-covered (culled) cell and a stable-uncovered (annulus) cell must be quiescent.
	# ---------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	for i in range(CONFIRM):
		ring.cull_feed(fid, 3, true)      # settle to culled
	ring.cull_feed(fid, 9, false)         # settle to emitted (uncovered)
	ring._cull_changed = false            # clear the settle transients — now "stand still"
	for i in range(50):
		ring.cull_feed(fid, 3, true)      # stable covered
		ring.cull_feed(fid, 9, false)     # stable uncovered
	_ok(not ring._cull_changed, "CHURN: standing still (settled signal) ⇒ zero mask changes → no rebuild churn")
	ring.free()

	# ---------------------------------------------------------------------------------------------------------------
	# Byte-identity guard — with the flag OFF (default), is_cell_culled is ALWAYS false, even after a populated mask,
	# so no cell is ever suppressed → the emit is byte-identical to today. (cull_feed populates state unconditionally
	# so the state machine is testable; the EMIT read is what the flag gates.)
	# ---------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	ring.set_cover_query(Callable(self, "_cover_true"))   # a VALID query, but the const flag is still off
	for i in range(CONFIRM + 1):
		ring.cull_feed(fid, 11, true)                     # mask bit 11 is now 1 in the state
	if CubeSphere.FP_FARRING_CULL_COVERED:
		_ok(ring.is_cell_culled(fid, 11), "FLAG-ON: a confirmed-covered cell reads culled")
	else:
		_ok(not ring.is_cell_culled(fid, 11),
			"OFF: flag off ⇒ is_cell_culled == false despite a populated mask → emit byte-identical")
	ring.free()

	# ---------------------------------------------------------------------------------------------------------------
	# Module fallback — an INVALID coverage callable (no module / GDScript path) ⇒ cull inert: _cull_on() false,
	# _cull_probe_cell false, _cull_update() a no-op (never over-culls, never allocates).
	# ---------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	# no set_cover_query → _cull_cover_query is an invalid Callable
	_ok(not ring._cull_on(), "FALLBACK: invalid coverage callable ⇒ _cull_on() false (cull inert)")
	_ok(not ring._cull_probe_cell(fid, 0, 0), "FALLBACK: _cull_probe_cell false on an invalid callable (never over-cull)")
	ring._cull_update()   # must not crash / allocate with no query
	_ok(ring._cull_mask.is_empty(), "FALLBACK: _cull_update() allocates no state with no query")
	ring.free()

	# ---------------------------------------------------------------------------------------------------------------
	# +32 DILATION — the probe AABB is a SUPERSET of the tight cell footprint by ±CULL_DILATE (x/z) and ±CULL_Y_MARGIN
	# (radial). A dilated box is HARDER to be fully meshed ⇒ cull is stricter/safer, and it uncovers at its boundary
	# while the tight cell is still covered. Needs a real dense facet cache (FACETED); skipped otherwise.
	# ---------------------------------------------------------------------------------------------------------------
	if CubeSphere.FACETED:
		ring = FacetFarRing.new()
		var dfid := 300
		ring._ensure_backstop_cached(dfid)
		if ring._bpos_cache.has(dfid):
			var gi := 5; var gj := 6
			var stride := CELLS + 1
			# the tight lattice span of this cell's 4 corners (no dilation)
			var i0 := gj * stride + gi
			var idxs := [i0, i0 + 1, i0 + stride, i0 + stride + 1]
			var lo := Vector3(INF, INF, INF); var hi := Vector3(-INF, -INF, -INF)
			for k in idxs:
				var p: Vector3 = ring._bpos_cache[dfid][k]
				var l: Array = FacetAtlas.world_to_lattice64(dfid, p.x, p.y, p.z)
				var lv := Vector3(float(l[0]), float(l[1]), float(l[2]))
				lo = Vector3(minf(lo.x, lv.x), minf(lo.y, lv.y), minf(lo.z, lv.z))
				hi = Vector3(maxf(hi.x, lv.x), maxf(hi.y, lv.y), maxf(hi.z, lv.z))
			var box: AABB = ring._cull_cell_aabb(dfid, gi, gj)
			var d: float = CubeSphere.CULL_DILATE
			var ym: float = CubeSphere.CULL_Y_MARGIN
			var got_x := box.size.x
			var want_x := (hi.x - lo.x) + 2.0 * d
			var got_z := box.size.z
			var want_z := (hi.z - lo.z) + 2.0 * d
			var got_y := box.size.y
			var want_y := (hi.y - lo.y) + 2.0 * ym
			_ok(absf(got_x - want_x) < 0.01 and absf(got_z - want_z) < 0.01,
				"DILATE: probe AABB dilated +%.0f blk x/z (x %.1f≈%.1f, z %.1f≈%.1f)" % [d, got_x, want_x, got_z, want_z])
			_ok(absf(got_y - want_y) < 0.01, "DILATE: probe AABB banded ±%.0f blk radially (y %.1f≈%.1f)" % [ym, got_y, want_y])
			# the dilated box strictly CONTAINS the tight cell footprint (superset ⇒ stricter cull ⇒ safer)
			_ok(box.position.x < lo.x and box.position.z < lo.z
				and box.position.x + box.size.x > hi.x and box.position.z + box.size.z > hi.z,
				"DILATE: dilated AABB strictly CONTAINS the tight cell footprint (cull stricter/safer)")
		else:
			_ok(true, "DILATE: SKIP (no dense cache for fid %d)" % dfid)
		ring.free()
	else:
		print("  SKIP DILATE: not FACETED")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
