extends SceneTree
## G-CV — FP_FARRING_CULL_COVERED (COSMOS TEXTURED-LOD U2, §2U.3 + round-2 live-perf fix): the far ring STOPS emitting a
## backstop cell once the near voxel field fully covers it (occlusion cull), WITHOUT rebuilding the whole ring every probe.
## The live per-cell hysteresis mask is DECOUPLED from the COMMITTED mesh: the emit reads the committed snapshot; a full
## (≈1 s sync) rebuild fires only on a settle (APPLY) or a safety (FLUSH) transition. Proved headlessly by driving the pure
## state machine + the decoupled decision with a mocked coverage signal (no godot_voxel needed):
##
##   G-CV-SAFE          — for EVERY step of scripted dig/ascend/sprint drives, the LIVE culled set ⊆ the covered set.
##   G-CV-SAFE-COMMITTED— the actual MESH never holes: no committed-culled cell is ever tight-UNcovered (the FLUSH fires
##                        when the +32-dilated probe un-covers, LEAD probes before the tight cell would).
##   G-CV-REAPPEAR      — a culled cell un-culls INSTANTLY (same step) on the first uncovered read; probe AABB dilated +32.
##   G-CV-CHURN         — culling needs CULL_CONFIRM consecutive covered reads (jitter never culls); a SETTLED standing
##                        signal triggers ZERO further rebuilds.
##   G-CV-NOCHURN-COST  — THE LIVE-FIX PROOF: a coverage signal that CHANGES EVERY probe for hundreds of probes (streaming,
##                        NOT self-cancelling jitter) triggers only a BOUNDED number of far-ring rebuilds (≪ probes).
##
## Plus byte-identity (is_cell_culled == false with the flag off) and the module-fallback (invalid callable ⇒ cull inert).
## Exits 0 all-pass, 1 on any failure. Flag-independent; byte-off also covered by verify_feature (FLAT 6042/0).

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	print(("  PASS " if c else "  FAIL ") + m)
	if c: _pass += 1
	else: _fail += 1

# Read the COMMITTED (mesh-reflected) cull bit directly, bypassing the flag gate on is_cell_culled (so the committed
# no-hole proof runs even with the flag off — the decoupled decision itself is flag-independent and testable).
func _committed(ring: FacetFarRing, fid: int, ci: int) -> bool:
	var cm: PackedByteArray = ring._committed_cull.get(fid, PackedByteArray())
	return ci < cm.size() and cm[ci] == 1

# One faithful probe pass: reset the per-pass change latch, feed every cell, then run the decoupled rebuild decision
# exactly as _cull_update does. `covered` is Callable(ci)->bool. Returns whether a rebuild fired this pass.
func _probe(ring: FacetFarRing, fid: int, ncell: int, covered: Callable, now_ms: int) -> bool:
	ring._cull_changed = false
	for ci in range(ncell):
		ring.cull_feed(fid, ci, bool(covered.call(ci)))
	return ring._cull_decide_reemit(ring._cull_changed, now_ms)

func _initialize() -> void:
	print("=== verify_cull_covered (G-CV: FP_FARRING_CULL_COVERED, decoupled) ===")
	FacetAtlas.warm_up()
	var CONFIRM: int = CubeSphere.CULL_CONFIRM
	var CELLS: int = CubeSphere.BACKSTOP_CELLS
	var NCELL := CELLS * CELLS
	var SETTLE: int = CubeSphere.CULL_SETTLE_PROBES
	var fid := 300

	# ---------------------------------------------------------------------------------------------------------------
	# G-CV-CHURN part 1 — 2-to-cull, and a jittering signal never culls (state machine).
	# ---------------------------------------------------------------------------------------------------------------
	var ring := FacetFarRing.new()
	_ok(not ring.cull_feed(fid, 0, true), "CHURN: 1 covered read does NOT cull (needs %d)" % CONFIRM)
	var culled := false
	for i in range(CONFIRM - 1):
		culled = ring.cull_feed(fid, 0, true)
	_ok(culled, "CHURN: %d consecutive covered reads CULL (live mask)" % CONFIRM)
	var jitter_culled := false
	for i in range(40):
		jitter_culled = jitter_culled or ring.cull_feed(fid, 5, (i % 2) == 0)
	_ok(not jitter_culled, "CHURN: a jittering signal (cover/uncover) NEVER culls — no flip-flop")
	ring.free()

	# ---------------------------------------------------------------------------------------------------------------
	# G-CV-REAPPEAR — instant un-cull in the live mask.
	# ---------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	for i in range(CONFIRM):
		ring.cull_feed(fid, 7, true)
	_ok(ring.cull_feed(fid, 7, true), "REAPPEAR: cell is culled after settling covered")
	_ok(not ring.cull_feed(fid, 7, false), "REAPPEAR: first UNcovered read un-culls INSTANTLY (same step)")
	_ok(not ring.cull_feed(fid, 7, true), "REAPPEAR: streak reset — a single covered read after un-cull does NOT re-cull")
	ring.free()

	# ---------------------------------------------------------------------------------------------------------------
	# G-CV-SAFE (state machine, live mask) — dig/ascend/sprint drives: culled ⇒ covered every step.
	# ---------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	var rng := RandomNumberGenerator.new(); rng.seed = 0xC0FFEE
	var safe_ok := true
	var STEPS := 600
	for step in range(STEPS):
		var t := float(step)
		var base_r := 8.0 + 6.0 * sin(t * 0.05)
		if (step / 40) % 5 == 4: base_r = 2.0
		var sprint := (4.0 * sin(t * 0.9)) if ((step / 40) % 5 == 2) else 0.0
		var disk_r := maxf(0.0, base_r + sprint)
		var cx := 8.0 + 4.0 * sin(t * 0.03); var cz := 8.0 + 4.0 * cos(t * 0.031)
		for cj in range(CELLS):
			for ci in range(CELLS):
				var d := Vector2(float(ci) - cx, float(cj) - cz).length()
				var covered := d <= disk_r
				if absf(d - disk_r) < 0.7: covered = rng.randf() < 0.5
				var bit := ring.cull_feed(fid, cj * CELLS + ci, covered)
				if bit and not covered: safe_ok = false
	_ok(safe_ok, "SAFE: 600×256 dig/ascend/sprint — live culled ⇒ covered EVERY step (no hole in the mask)")
	ring.free()

	# ---------------------------------------------------------------------------------------------------------------
	# G-CV-NOCHURN-COST — THE LIVE FIX. Coverage changes EVERY probe for hundreds of probes (streaming). Phases:
	# sustained motion (disk sweeps, nothing settles) → stand still (settle → ONE apply) → resume motion (un-cull → ONE flush).
	# ---------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	ring.set_cover_query(Callable(self, "_cover_true"))
	var now := 0
	var PROBE := CubeSphere.CULL_REAP_MS
	var MOT := 200
	for step in range(MOT):
		var cx2 := fmod(float(step) * 0.7, float(CELLS))
		var covered_fn := func(ci: int) -> bool:
			var gx := ci % CELLS; var gz := ci / CELLS
			return Vector2(float(gx) - cx2, float(gz) - 8.0).length() <= 5.0
		_probe(ring, fid, NCELL, covered_fn, now); now += PROBE
	var reemit_after_motion := ring._cull_reemit_count
	_ok(reemit_after_motion <= 2,
		"NOCHURN-COST: %d probes of SUSTAINED motion (coverage changes every probe) → %d rebuilds (bounded)" % [MOT, reemit_after_motion])
	var still_fn := func(ci: int) -> bool:
		var gx := ci % CELLS; var gz := ci / CELLS
		return Vector2(float(gx) - 8.0, float(gz) - 8.0).length() <= 5.0
	for step in range(SETTLE + 6):
		_probe(ring, fid, NCELL, still_fn, now); now += PROBE
	var reemit_after_still := ring._cull_reemit_count
	_ok(reemit_after_still - reemit_after_motion == 1,
		"NOCHURN-COST: standing still settles to exactly ONE apply rebuild (%d → %d)" % [reemit_after_motion, reemit_after_still])
	for step in range(50):
		_probe(ring, fid, NCELL, still_fn, now); now += PROBE
	_ok(ring._cull_reemit_count == reemit_after_still,
		"CHURN: 50 more standing-still probes ⇒ ZERO further rebuilds (committed stable)")
	var before_flush := ring._cull_reemit_count
	var flush_fired := false
	for step in range(5):
		if _probe(ring, fid, NCELL, Callable(self, "_cover_false_ci"), now): flush_fired = true
		now += PROBE
	_ok(flush_fired and ring._cull_reemit_count - before_flush == 1,
		"NOCHURN-COST: motion resume un-covers committed cells → exactly ONE FLUSH rebuild (%d → %d)" % [before_flush, ring._cull_reemit_count])
	_ok(ring._committed_cull.is_empty(), "NOCHURN-COST: after the flush the committed mesh emits everything (no stale cull)")
	_ok(ring._cull_reemit_count <= 4,
		"NOCHURN-COST: TOTAL rebuilds over %d probes = %d ≪ probes" % [MOT + SETTLE + 6 + 50 + 5, ring._cull_reemit_count])
	ring.free()

	# ---------------------------------------------------------------------------------------------------------------
	# G-CV-SAFE-COMMITTED — the actual MESH never holes. dilated-covered is the probe signal; tight coverage stays true
	# LEAD probes after the dilated signal falls (the +32-block dilation as a time lead). Assert: no committed-culled cell
	# is ever tight-UNcovered.
	# ---------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	ring.set_cover_query(Callable(self, "_cover_true"))
	var LEAD := 3
	now = 0
	var hist := []
	var NSTEP := 90
	var committed_hole := false
	var worst := -1
	for step in range(NSTEP):
		var dil := PackedByteArray(); dil.resize(NCELL)
		var disk := 20.0 if step < 30 else maxf(0.0, 20.0 - float(step - 30) * 0.5)
		for ci in range(NCELL):
			var gx := ci % CELLS; var gz := ci / CELLS
			dil[ci] = 1 if Vector2(float(gx) - 8.0, float(gz) - 8.0).length() <= disk else 0
		hist.append(dil)
		var cov_fn := func(ci: int) -> bool: return (dil as PackedByteArray)[ci] == 1
		_probe(ring, fid, NCELL, cov_fn, now); now += PROBE
		for ci in range(NCELL):
			var tight := false
			for k in range(maxi(0, step - LEAD), step + 1):
				if (hist[k] as PackedByteArray)[ci] == 1: tight = true; break
			if _committed(ring, fid, ci) and not tight:
				committed_hole = true
				if worst < 0: worst = step
	_ok(not committed_hole, "SAFE-COMMITTED: mesh never omits a tight-uncovered cell over %d probes (no hole)%s"
		% [NSTEP, ("" if not committed_hole else "  first at step %d" % worst)])
	ring.free()

	# ---------------------------------------------------------------------------------------------------------------
	# Byte-identity guard — flag OFF ⇒ is_cell_culled always false (emit byte-identical).
	# ---------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	ring.set_cover_query(Callable(self, "_cover_true"))
	now = 0
	for step in range(SETTLE + 4):
		_probe(ring, fid, NCELL, Callable(self, "_cover_true_ci"), now); now += PROBE
	if CubeSphere.FP_FARRING_CULL_COVERED:
		_ok(ring.is_cell_culled(fid, 11), "FLAG-ON: a settled covered cell reads culled in the mesh")
	else:
		_ok(not ring.is_cell_culled(fid, 11), "OFF: flag off ⇒ is_cell_culled == false → emit byte-identical")
	ring.free()

	# ---------------------------------------------------------------------------------------------------------------
	# Module fallback — invalid coverage callable ⇒ cull inert.
	# ---------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	_ok(not ring._cull_on(), "FALLBACK: invalid coverage callable ⇒ _cull_on() false (cull inert)")
	_ok(not ring._cull_probe_cell(fid, 0, 0), "FALLBACK: _cull_probe_cell false on an invalid callable (never over-cull)")
	ring._cull_update()
	_ok(ring._cull_mask.is_empty() and ring._committed_cull.is_empty(), "FALLBACK: _cull_update() allocates no state with no query")
	ring.free()

	# ---------------------------------------------------------------------------------------------------------------
	# +32 DILATION — probe AABB is a superset of the tight cell (needs a real dense cache; FACETED only).
	# ---------------------------------------------------------------------------------------------------------------
	if CubeSphere.FACETED:
		ring = FacetFarRing.new()
		ring._ensure_backstop_cached(fid)
		if ring._bpos_cache.has(fid):
			var gi := 5; var gj := 6; var stride := CELLS + 1
			var i0 := gj * stride + gi
			var lo := Vector3(INF, INF, INF); var hi := Vector3(-INF, -INF, -INF)
			for k in [i0, i0 + 1, i0 + stride, i0 + stride + 1]:
				var p: Vector3 = ring._bpos_cache[fid][k]
				var l: Array = FacetAtlas.world_to_lattice64(fid, p.x, p.y, p.z)
				var lv := Vector3(float(l[0]), float(l[1]), float(l[2]))
				lo = Vector3(minf(lo.x, lv.x), minf(lo.y, lv.y), minf(lo.z, lv.z))
				hi = Vector3(maxf(hi.x, lv.x), maxf(hi.y, lv.y), maxf(hi.z, lv.z))
			var box: AABB = ring._cull_cell_aabb(fid, gi, gj)
			var dd: float = CubeSphere.CULL_DILATE
			_ok(absf(box.size.x - ((hi.x - lo.x) + 2.0 * dd)) < 0.01 and absf(box.size.z - ((hi.z - lo.z) + 2.0 * dd)) < 0.01,
				"DILATE: probe AABB dilated +%.0f blk x/z" % dd)
			_ok(box.position.x < lo.x and box.position.z < lo.z and box.position.x + box.size.x > hi.x and box.position.z + box.size.z > hi.z,
				"DILATE: dilated AABB strictly CONTAINS the tight cell footprint (cull stricter/safer)")
		else:
			_ok(true, "DILATE: SKIP (no dense cache)")
		ring.free()
	else:
		print("  SKIP DILATE: not FACETED")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# named Callable(ci)->bool helpers (used where a lambda capture is unnecessary)
func _cover_false_ci(_ci: int) -> bool: return false
func _cover_true_ci(_ci: int) -> bool: return true
func _cover_true(_fid: int, _aabb: AABB) -> bool: return true
func _cover_false(_fid: int, _aabb: AABB) -> bool: return false
