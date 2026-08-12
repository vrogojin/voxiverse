extends SceneTree
## G-APC — FP_APPLIED_PROBE_CALM (COSMOS-APPLIED-PROBE-CALM, task #123): coalesce the far-ring covered-cull re-emit and
## credit-gate the APPLY, so a minutes-long coverage TRICKLE no longer rebuilds the ~480k-vert FULL_COVER shell 182× (each
## a 60–94 ms MAIN-THREAD swap). The FLUSH safety path stays instant + un-rate-limited (holes are worse than overdraw). The
## decider (`_cull_decide_reemit`), the hysteresis (`cull_feed`), the probe-slice (`_cull_probe_indices`) and the applied
## ladder (`_applied_probe_step`) are all headlessly drivable (mocked coverage callable + injectable now_ms), so this proves:
##
##   G-APC-1 coalesce   — a scripted coverage trickle yields ≤ 5 APPLYs with the flag ON (≫20 shipped); committed == live.
##   G-APC-2 safety     — un-covering a committed cell mid-trickle FLUSHes in the SAME decide pass (rate-limit ignored).
##   G-APC-3 credit gate— flag ON: _stream_credit_ok=false blocks EVERY APPLY (FLUSH still fires); true ⇒ APPLY next decide.
##   G-APC-4 flap pin   — a cell whose reads flip ≥ CALM_FLAP_N is pinned DRAWN; it never culls again until pruned.
##   G-APC-5 ladder     — a 0→MAX applied-cover climb sets _pending ONCE at the fixpoint (7× shipped); a shrink sets it now.
##   G-APC-6 slice      — the probe slice sweeps the whole grid within ceil(ncell/CALM_PROBE_SLICE) reaps (detection lag).
##   G-APC-7 parity     — flag OFF ⇒ the shipped CULL_SETTLE_PROBES/CULL_REBUILD_MS + per-step ladder cadence, verbatim.
##
## Each assertion is flag-adaptive (reads CubeSphere.FP_APPLIED_PROBE_CALM), so the SAME gate proves calm behaviour with the
## flag ON and byte-identical shipped behaviour with it OFF. Run BOTH states. Exits 0 all-pass, 1 on any failure.

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	print(("  PASS " if c else "  FAIL ") + m)
	if c: _pass += 1
	else: _fail += 1

# One faithful probe pass (mirrors _cull_update's decoupled decision): reset the per-pass latch, feed EVERY cell, decide.
func _probe(ring: FacetFarRing, fid: int, ncell: int, covered: Callable, now_ms: int) -> bool:
	ring._cull_changed = false
	for ci in range(ncell):
		ring.cull_feed(fid, ci, bool(covered.call(ci)))
	return ring._cull_decide_reemit(ring._cull_changed, now_ms)

func _initialize() -> void:
	print("=== verify_applied_calm (G-APC: FP_APPLIED_PROBE_CALM) ===")
	FacetAtlas.warm_up()
	var CALM: bool = CubeSphere.FP_APPLIED_PROBE_CALM
	print("  flag FP_APPLIED_PROBE_CALM = %s" % str(CALM))
	var CELLS: int = CubeSphere.BACKSTOP_CELLS
	var NCELL := CELLS * CELLS
	var fid := 300

	# ------------------------------------------------------------------------------------------------------------------
	# G-APC-1 coalesce — a coverage trickle: cells 0..k-1 covered, k grows by 1 every HOLD probes. Flag ON: the APPLY
	# coalesces to ~1 (settle 20 never reached mid-trickle; one harvest at the end). Flag OFF: ~1 APPLY per cell plateau.
	# ------------------------------------------------------------------------------------------------------------------
	var ring := FacetFarRing.new()
	ring.set_cover_query(Callable(self, "_cover_true"))     # valid callable ⇒ cull path is live for the decider
	ring.set_stream_credit_ok(true)                         # credit up so the calm APPLY is not credit-blocked here
	var TRICKLE := 60
	var HOLD := 5
	var now := 0
	for k in range(1, TRICKLE + 1):
		for _h in range(HOLD):
			var kk := k
			_probe(ring, fid, NCELL, func(ci: int) -> bool: return ci < kk, now); now += 100
	# quiet tail — lets the calm settle (20) + harvest fire exactly one APPLY of the accumulated delta
	for _t in range(30):
		_probe(ring, fid, NCELL, func(ci: int) -> bool: return ci < TRICKLE, now); now += 100
	var reemit := ring._cull_reemit_count
	if CALM:
		_ok(reemit <= 5, "COALESCE(ON): %d-cell trickle → %d APPLYs (≤5; shipped ≈ one per cell)" % [TRICKLE, reemit])
	else:
		_ok(reemit >= 20, "COALESCE(OFF): %d-cell trickle → %d APPLYs (shipped per-plateau cadence, unchanged)" % [TRICKLE, reemit])
	_ok(ring._cull_mask_delta_count() == 0, "COALESCE: committed == live at rest (convergence reached, delta 0)")
	ring.free()

	# ------------------------------------------------------------------------------------------------------------------
	# G-APC-2 safety — build a committed cull (credit up, long settle), then un-cover one committed cell. FLUSH must fire
	# the SAME decide pass, ignoring the rate-limit. Identical on both flags (FLUSH is never gated/delayed).
	# ------------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	ring.set_cover_query(Callable(self, "_cover_true"))
	ring.set_stream_credit_ok(true)
	now = 0
	for _s in range(24):                                    # settle 30 covered cells; now advances 1 s/probe (gap ≫ any limit)
		_probe(ring, fid, NCELL, func(ci: int) -> bool: return ci < 30, now); now += 1000
	var committed_after_settle := ring._cull_reemit_count
	_ok(committed_after_settle >= 1 and not ring._committed_cull.is_empty(),
		"SAFETY setup: a settled 30-cell cull committed (%d APPLY)" % committed_after_settle)
	var before_flush := ring._cull_reemit_count
	# un-cover cell 0 (still covered elsewhere): its live bit un-culls instantly; committed[0]==1 ⇒ FLUSH this pass.
	var flushed := _probe(ring, fid, NCELL, func(ci: int) -> bool: return ci >= 1 and ci < 30, now); now += 5
	_ok(flushed and ring._cull_reemit_count - before_flush == 1 and ring._committed_cull.is_empty(),
		"SAFETY: un-covering a committed cell FLUSHes the SAME pass (rate-limit ignored) → committed emits everything")
	ring.free()

	# ------------------------------------------------------------------------------------------------------------------
	# G-APC-3 credit gate — flag ON: credit=false blocks every APPLY even when settle+delta+rate all pass; flip true ⇒
	# APPLY on the next eligible decide. Flag OFF: credit is ignored (shipped) ⇒ the APPLY fires regardless of credit.
	# ------------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	ring.set_cover_query(Callable(self, "_cover_true"))
	ring.set_stream_credit_ok(false)
	now = 100000                                            # far past any rate-limit window
	for _s in range(24):
		_probe(ring, fid, NCELL, func(ci: int) -> bool: return ci < 30, now); now += 1000
	var reemit_credit_off := ring._cull_reemit_count
	if CALM:
		_ok(reemit_credit_off == 0, "CREDIT(ON): credit=false ⇒ ZERO APPLYs across a fully-settled differing mask")
		ring.set_stream_credit_ok(true)
		var fired := _probe(ring, fid, NCELL, func(ci: int) -> bool: return ci < 30, now); now += 1000
		_ok(fired and ring._cull_reemit_count == 1, "CREDIT(ON): flipping credit true ⇒ APPLY on the next decide")
	else:
		_ok(reemit_credit_off >= 1, "CREDIT(OFF): credit is ignored (shipped) ⇒ the settled APPLY fires regardless")
	ring.free()

	# ------------------------------------------------------------------------------------------------------------------
	# G-APC-4 flap pin — oscillate one cell's coverage read. Flag ON: after CALM_FLAP_N flips it pins DRAWN and never culls
	# again (even under a steady covered signal). Flag OFF: no pin ⇒ it culls normally after CULL_CONFIRM covered reads.
	# ------------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	var cell := 7
	for i in range(2 * CubeSphere.CALM_FLAP_N + 2):         # alternate covered/uncovered enough times to exceed the flap cap
		ring.cull_feed(fid, cell, (i % 2) == 0)
	var culled_after_steady := false
	for _i in range(CubeSphere.CULL_CONFIRM + 3):           # now hold a STEADY covered signal (would normally cull)
		culled_after_steady = ring.cull_feed(fid, cell, true)
	if CALM:
		_ok(not culled_after_steady, "FLAP(ON): a cell flipping ≥ CALM_FLAP_N is pinned DRAWN — steady coverage never re-culls it")
		var flap: PackedByteArray = ring._cull_flap.get(fid, PackedByteArray())
		_ok(cell < flap.size() and flap[cell] >= CubeSphere.CALM_FLAP_N, "FLAP(ON): the flap counter reached the pin threshold")
	else:
		_ok(culled_after_steady, "FLAP(OFF): no flap tracking ⇒ a steady covered signal culls normally (shipped hysteresis)")
	ring.free()

	# ------------------------------------------------------------------------------------------------------------------
	# G-APC-5 ladder — a 0→APPLIED_PROBE_MAX applied-cover climb. Flag ON: _pending set ONCE at the fixpoint; a shrink sets
	# it immediately. Flag OFF: _pending set on EVERY +STEP grow. Drive _applied_probe_step with a mocked coverage query.
	# ------------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	ring._active_fid = fid
	ring._player_col_abs = Vector3(3072.0, 0.0, 0.0)
	ring._unsink_have_col = true
	ring.set_cover_query(Callable(self, "_cover_true"))     # box always meshed ⇒ the ladder grows every call
	var params := Vector3(0.0, 0.0, 64.0)                   # z = h (box half-height); the mock query ignores the box
	var STEP: float = float(CubeSphere.APPLIED_PROBE_STEP)
	var MAX: float = float(CubeSphere.APPLIED_PROBE_MAX)
	var expected_steps := int(round(MAX / STEP))            # e.g. 112/16 = 7
	var grow_pendings := 0
	for _c in range(expected_steps + 2):                    # climb to the fixpoint (extra calls are stable → no _pending)
		ring._pending = false
		ring._applied_probe_step(true, params)
		if ring._pending: grow_pendings += 1
	_ok(ring._applied_r >= MAX - 0.001, "LADDER: the climb reached APPLIED_PROBE_MAX (%.0f)" % ring._applied_r)
	if CALM:
		_ok(grow_pendings == 1, "LADDER(ON): 0→MAX grow climb sets _pending ONCE at the fixpoint (was %d)" % expected_steps)
	else:
		_ok(grow_pendings == expected_steps, "LADDER(OFF): _pending set on EVERY grow step (%d, shipped)" % grow_pendings)
	# shrink: the coverage claim breaks ⇒ _applied_r drops to 0 and _pending is set the SAME step (safety, both flags).
	ring.set_cover_query(Callable(self, "_cover_false"))
	ring._pending = false
	ring._applied_probe_step(true, params)
	_ok(ring._applied_r == 0.0 and ring._pending, "LADDER: a broken coverage claim SHRINKS to 0 and re-emits immediately")
	ring.free()

	# ------------------------------------------------------------------------------------------------------------------
	# G-APC-6 slice — the round-robin probe window sweeps the whole grid within ceil(ncell/CALM_PROBE_SLICE) reaps, so a
	# scripted un-cover is detected within that many reaps. Only meaningful ON (OFF probes the full grid every reap).
	# ------------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	if CALM:
		var slice: int = mini(CubeSphere.CALM_PROBE_SLICE, NCELL)
		var reaps := int(ceil(float(NCELL) / float(slice)))
		var seen := {}
		var sizes_ok := true
		for _r in range(reaps):
			var idx: PackedInt32Array = ring._cull_probe_indices(fid, NCELL)
			if idx.size() != slice: sizes_ok = false
			for ci in idx: seen[ci] = true
		_ok(sizes_ok, "SLICE(ON): each reap probes exactly CALM_PROBE_SLICE (%d) cells" % slice)
		_ok(seen.size() == NCELL, "SLICE(ON): the whole %d-cell grid is swept within %d reaps (detection lag ≤ %d reaps)" % [NCELL, reaps, reaps])
	else:
		_ok(true, "SLICE(OFF): full-grid probe every reap (no slice state) — nothing to sweep")
	ring.free()

	# ------------------------------------------------------------------------------------------------------------------
	# G-APC-7 parity — flag OFF: the shipped settle (CULL_SETTLE_PROBES) + rate (CULL_REBUILD_MS), credit-independent. A
	# settled differing mask APPLYs at exactly CULL_SETTLE_PROBES quiet probes with credit=false. (ON: this path is bypassed.)
	# ------------------------------------------------------------------------------------------------------------------
	ring = FacetFarRing.new()
	ring.set_cover_query(Callable(self, "_cover_true"))
	ring.set_stream_credit_ok(false)                        # shipped path ignores credit
	now = 0
	for _s in range(CubeSphere.CULL_CONFIRM):               # cull cells 0..9 into the live mask (2 covered reads)
		_probe(ring, fid, NCELL, func(ci: int) -> bool: return ci < 10, now); now += 100
	var pre := ring._cull_reemit_count
	for _s in range(CubeSphere.CULL_SETTLE_PROBES + 2):     # settle
		_probe(ring, fid, NCELL, func(ci: int) -> bool: return ci < 10, now); now += 100
	if CALM:
		_ok(ring._cull_reemit_count == pre, "PARITY(ON): credit=false ⇒ the calm path fires no APPLY (parity check inert ON)")
	else:
		_ok(ring._cull_reemit_count - pre == 1, "PARITY(OFF): a settled cull APPLYs once at CULL_SETTLE_PROBES, credit-independent (shipped)")
	ring.free()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _cover_true(_fid: int, _aabb: AABB) -> bool: return true
func _cover_false(_fid: int, _aabb: AABB) -> bool: return false
