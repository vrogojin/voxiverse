extends SceneTree
## docs/COSMOS-STREAM-PARALLEL-DESIGN.md Phase A gate (task #102) — FP_DEM_DEFER, the fresh-reload fix. Proves the
## deferral/demand-drive machinery in `GlobalReliefData` (godot/src/world/global_relief_data.gd) does exactly what
## the design's §4.2 / Phase A specifies, WITHOUT changing the DEM's shipped behaviour when the flag is off.
##
## Runs with FACETED + FP_GLOBAL_RELIEF_DATA sed-toggled true (needed to exercise the DEM at all — setup() no-ops
## otherwise), and self-describes on FP_DEM_DEFER's compiled value (mirrors verify_far_geometry.gd's convention):
##
##   G-SP-OFF        — FP_DEM_DEFER off ⇒ the DEM is byte-identical to today: the centre-dir table is NOT built (no
##                     new resident bytes), request() is a no-op (want-list stays empty), and step() bakes on a
##                     healthy frame with NO settle gate — including the shipped `frame_ms == 0` first-call loophole,
##                     UNCHANGED — while a hot frame still dispatches nothing. (The real byte-off pin is external:
##                     FLAT verify_feature.gd stays 6042/0 with the flag false.)
##   G-SP-DEM-DEFER  — FP_DEM_DEFER on: (a) the setup-time centre-dir table is built (the alloc-free scan basis — no
##                     per-call `_centre_dir` allocation); (b) the first call with `frame_ms == 0` bakes NOTHING
##                     (loophole closed); (c) before mark_settled() no bake is admitted even on a healthy frame with
##                     a demand queued (DEFERRED out of the reload window); (d) after settle, on-surface, ONLY the
##                     demanded fids bake, NEAREST-first, and once drained NO blind whole-planet sweep runs; (e)
##                     off-surface, the remaining planet fills via the alloc-free `_next_unbaked_fast` sweep.

const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_stream_parallel (task #102 Phase A — FP_DEM_DEFER + Phase C — FP_NB_FULLRES) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	FA.warm_up()

	if not CubeSphere.FP_GLOBAL_RELIEF_DATA:
		# Can't exercise the DEM without its data. Assert the no-op contract and instruct the harness.
		var rd := GlobalReliefData.new()
		rd.setup()
		_ok(not rd.is_ready(), "G-SP-REQUIRES-FLAG: setup() no-ops with FP_GLOBAL_RELIEF_DATA off — run this gate with it (and FP_DEM_DEFER) sed-toggled true")
	elif CubeSphere.FP_DEM_DEFER:
		_gate_dem_defer()
	else:
		_gate_off()

	# Phase C — FP_NB_FULLRES. These run ALWAYS (independent of the DEM flags): the selector gates drive the STATIC
	# z1_live_targets directly (both fullres modes, so they hold regardless of the compiled FP_NB_FULLRES value), and the
	# policy gates drive the REAL WorldManager ledger/retire/exclusion helpers against a lightweight module stub.
	print("--- Phase C: FP_NB_FULLRES (compiled FP_NB_FULLRES=%s) ---" % str(CubeSphere.FP_NB_FULLRES))
	_gate_nb_off()
	_gate_nb_cover()
	_gate_nb_prio()
	_gate_nb_rebalance()
	_gate_nb_cap()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ============================ Phase C — FP_NB_FULLRES gates =====================================================
# A lightweight stand-in for module_world: only the few methods the WorldManager NB helpers call, all test-controllable.
# WorldManager._module_world is typed Node3D, so the stub extends Node3D and is assigned directly (no scene / no setup()).
class _NBModStub extends Node3D:
	var count := 3
	var voxel_bytes := 0
	var ages := {}       # fid → live seconds (default 999 ⇒ past MIN_LIVE_S)
	var meshed := {}     # fid → bool (pool_seam_meshed)
	func pool_neighbour_count() -> int: return count
	func nb_voxel_used_bytes() -> int: return voxel_bytes
	func pool_age_s(fid: int) -> float: return float(ages.get(int(fid), 999.0))
	func pool_seam_meshed(fid, _pos) -> bool: return bool(meshed.get(int(fid), false))

func _new_wm(stub) -> WorldManager:
	var wm := WorldManager.new()
	wm._module_world = stub
	return wm

# --- G-SP-NB-OFF: fullres=false ⇒ the selector is byte-identical to the shipped FP-M2d output ------------------------
func _gate_nb_off() -> void:
	# Matrix of want/live/off-surface inputs; every fullres=false output must equal the DEFAULT-param output (proving the
	# added `fullres` tail is inert by default) AND obey the shipped residency law (≤ FP2_LIVE_CAP; imminent + corner-second).
	var cases := [
		{"want": {10: 20.0, 11: 40.0, 12: 60.0, 13: 80.0}, "live": [], "off": false},
		{"want": {10: 20.0, 11: 44.0}, "live": [11], "off": false},          # incumbent hysteresis
		{"want": {10: 20.0, 11: 90.0}, "live": [], "off": false},            # corner-second beyond D_WARM2 ⇒ dropped
		{"want": {10: 20.0, 11: 40.0}, "live": [], "off": true},             # off-surface freeze ⇒ []
	]
	for c in cases:
		var d := WorldManager.z1_live_targets(c["want"], c["off"], c["live"], 0.0, false)
		var dflt := WorldManager.z1_live_targets(c["want"], c["off"], c["live"], 0.0)
		_ok(d == dflt, "G-SP-NB-OFF: fullres=false == default-param output (added tail inert) — %s" % str(d))
		_ok(d.size() <= CubeSphere.FP2_LIVE_CAP, "G-SP-NB-OFF: output within FP2_LIVE_CAP(%d) — %s" % [CubeSphere.FP2_LIVE_CAP, str(d)])
	# The off-surface case is empty (freeze) both modes.
	_ok(WorldManager.z1_live_targets({10: 20.0}, true, [], 0.0, true).is_empty(), "G-SP-NB-OFF: off-surface freezes even under fullres (=[])")

# --- G-SP-NB-COVER: fullres=true ⇒ imminent-first + ALL remaining edges nearest-first; band-conditional exclusion -----
func _gate_nb_cover() -> void:
	# Four edges all inside D_WARM ⇒ the fullres tail returns all 4, imminent-first then ascending ridge distance.
	var want := {10: 60.0, 11: 20.0, 12: 40.0, 13: 80.0}
	var t := WorldManager.z1_live_targets(want, false, [], 0.0, true)
	_ok(t.size() == 4, "G-SP-NB-COVER: all 4 edge neighbours become targets under fullres — %s" % str(t))
	_ok(int(t[0]) == 11, "G-SP-NB-COVER: index-0 is the imminent (nearest ridge, fid 11)")
	_ok(t == [11, 12, 10, 13], "G-SP-NB-COVER: tail is nearest-first after the imminent (%s)" % str(t))
	_ok(t.size() <= CubeSphere.POOL_MAX_NEIGHBOURS, "G-SP-NB-COVER: capped at POOL_MAX_NEIGHBOURS(%d)" % CubeSphere.POOL_MAX_NEIGHBOURS)

	# Band-conditional far-ring exclusion (§2.4 CORRECTION 2) via the REAL WorldManager helpers + a module stub.
	var stub := _NBModStub.new()
	var wm := _new_wm(stub)
	wm._nb_imminent_fid = 11
	wm._nb_excl_latch = {}
	stub.meshed = {12: true, 13: false}          # 12's band is up; 13's is not
	var live := [11, 12, 13]
	_ok(wm._nb_excluded_neighbour(11), "G-SP-NB-COVER: the imminent is always far-ring-excluded (cover-until-meshed)")
	_ok(not wm._nb_excluded_neighbour(12), "G-SP-NB-COVER: a live-but-unlatched neighbour is NOT excluded (keeps its far tile — no see-through hole)")
	wm._nb_update_excl_latch(live, {11: 20.0, 12: 40.0, 13: 60.0}, Vector3.ZERO)   # probes nearest non-imminent = 12 (meshed)
	_ok(wm._nb_excl_latch.has(12), "G-SP-NB-COVER: band-meshed neighbour latches (<=1 probe/tick, nearest non-imminent first)")
	_ok(wm._nb_excluded_neighbour(12), "G-SP-NB-COVER: a latched (band-up) neighbour IS excluded (far tile drops, band covers)")
	_ok(not wm._nb_excl_latch.has(13), "G-SP-NB-COVER: the farther un-probed neighbour is not yet latched (paced probe)")
	wm._nb_update_excl_latch(live, {11: 20.0, 12: 40.0, 13: 60.0}, Vector3.ZERO)   # next tick probes 13 (not meshed)
	_ok(not wm._nb_excl_latch.has(13), "G-SP-NB-COVER: an un-meshed band does not latch (stays far-ring-covered)")
	# Geometric release: 12 walks past NB_EXCL_RELEASE ⇒ its band unloads ⇒ latch clears ⇒ the far tile returns.
	wm._nb_update_excl_latch(live, {11: 20.0, 12: CubeSphere.NB_EXCL_RELEASE + 10.0, 13: 60.0}, Vector3.ZERO)
	_ok(not wm._nb_excl_latch.has(12), "G-SP-NB-COVER: latch clears geometrically past NB_EXCL_RELEASE (band gone → far tile back)")
	wm.free()

# --- G-SP-NB-PRIO: imminent never starved; farthest eviction; imminent never evicted; one viewer (construction) -------
func _gate_nb_prio() -> void:
	# The selector always yields the imminent at index 0 — in BOTH modes, and regardless of live incumbency.
	var want := {10: 30.0, 11: 15.0, 12: 55.0, 13: 70.0}
	_ok(int(WorldManager.z1_live_targets(want, false, [], 0.0, false)[0]) == 11, "G-SP-NB-PRIO: index-0 = nearest imminent (shipped)")
	_ok(int(WorldManager.z1_live_targets(want, false, [], 0.0, true)[0]) == 11, "G-SP-NB-PRIO: index-0 = nearest imminent (fullres)")

	var stub := _NBModStub.new()
	var wm := _new_wm(stub)
	wm._nb_imminent_fid = 11
	stub.ages = {10: 999.0, 11: 999.0, 12: 999.0, 13: 5.0}   # 13 younger than MIN_LIVE_S
	var live := [10, 11, 12, 13]
	# Same-tick imminent-priority eviction picks the FARTHEST NON-target, never the imminent, honoring MIN_LIVE_S.
	# targets = {11}; non-targets 10(30),12(55),13(70) but 13 is too young ⇒ farthest eligible = 12.
	var ev := wm._nb_farthest_retirable(live, [11], want, true, -1.0)
	_ok(ev == 12, "G-SP-NB-PRIO: same-tick eviction sheds the farthest eligible non-target (fid 12) — got %d" % ev)
	_ok(ev != 11, "G-SP-NB-PRIO: the index-0 imminent is NEVER evicted (never starved)")
	_ok(ev != 13, "G-SP-NB-PRIO: a < MIN_LIVE_S neighbour is spared by the eviction (anti-thrash)")
	# Construction fact: the NB widening adds NO viewer — pool_spawn never attaches one (§1.3). Asserted live-side by
	# verify_faceted G-M1-POOL (exactly 1 VoxelViewer); nothing in the WorldManager NB policy creates a viewer either.
	_ok(true, "G-SP-NB-PRIO: one-viewer construction — the NB policy adds no viewer (live authority: verify_faceted G-M1-POOL)")
	wm.free()

# --- G-SP-NB-REBALANCE: crossing flips the want-set to the new active's 4 edges; paced farthest retire of the far side -
func _gate_nb_rebalance() -> void:
	# After a crossing the selector recomputes from the NEW active's want — the old far-side fids simply aren't in it.
	var new_want := {20: 25.0, 21: 45.0, 22: 65.0, 23: 85.0}
	var t := WorldManager.z1_live_targets(new_want, false, [10, 11, 12, 13], 0.0, true)   # live = OLD neighbours
	_ok(t == [20, 21, 22, 23], "G-SP-NB-REBALANCE: targets become the NEW active's 4 edges, nearest-first — %s" % str(t))
	for old in [10, 11, 12, 13]:
		_ok(not t.has(old), "G-SP-NB-REBALANCE: old far-side fid %d left the target set" % old)

	# Farthest-first retire order + MIN_LIVE_S anti-thrash on the REAL helper: old neighbours are non-targets (want=1e30
	# for them), farthest retires first; a just-crossed-back young one is spared.
	var stub := _NBModStub.new()
	var wm := _new_wm(stub)
	wm._nb_imminent_fid = 20
	stub.ages = {10: 999.0, 11: 999.0, 12: 3.0, 13: 999.0}   # 12 just re-spawned (young) → spared
	var live := [10, 11, 12, 13, 20]
	# want has no entry for the old fids ⇒ 1e30 each; the imminent 20 has want 25. farthest-first over the retirable
	# (non-target, non-imminent, aged) → any of {10,11,13} (all 1e30, tie → last max wins deterministically = 13).
	var r := wm._nb_farthest_retirable(live, [20, 21, 22, 23], new_want, true, CubeSphere.POOL_D_RETIRE)
	_ok(r == 10 or r == 11 or r == 13, "G-SP-NB-REBALANCE: a far-side old neighbour is retired first (fid %d, past D_RETIRE)" % r)
	_ok(r != 12, "G-SP-NB-REBALANCE: the young (< MIN_LIVE_S) neighbour is spared (anti-thrash)")
	_ok(r != 20, "G-SP-NB-REBALANCE: the imminent is never retired")
	wm.free()

# --- G-SP-NB-CAP: measured-byte ledger falsifier — breach ⇒ refuse, hysteresis re-admit, never OOM --------------------
func _gate_nb_cap() -> void:
	var stub := _NBModStub.new()
	var wm := _new_wm(stub)
	stub.count = 3
	stub.voxel_bytes = 0
	wm._nb_b0_bytes = wm._nb_measured_bytes()     # snapshot B0 with zero NB voxel bytes (static-heap term ~cancels in growth)
	wm._nb_breached = false
	print("  [G-SP-NB-CAP] measured B0 = %.2f MB (voxel_used + static heap); cap = %d MB, rehyst = %d MB" % [
		wm._nb_b0_bytes / 1048576.0, CubeSphere.NB_POOL_BYTES_CAP / 1048576, CubeSphere.NB_BYTES_REHYST / 1048576])
	_ok(wm._nb_ledger_admit(), "G-SP-NB-CAP: admits a widened spawn under budget (growth ~0)")
	_ok(not wm._nb_breached, "G-SP-NB-CAP: not breached under budget")
	# Push simulated NB voxel growth over the cap ⇒ refuse + breach latched.
	stub.voxel_bytes = CubeSphere.NB_POOL_BYTES_CAP + CubeSphere.NB_SPAWN_EST + 2 * 1048576
	_ok(not wm._nb_ledger_admit(), "G-SP-NB-CAP: over-cap growth ⇒ widened spawn REFUSED (breach ladder step 1)")
	_ok(wm._nb_breached, "G-SP-NB-CAP: breach latched")
	# In the hysteresis band (below cap but above cap − REHYST) it stays breached (no thrash).
	stub.voxel_bytes = CubeSphere.NB_POOL_BYTES_CAP - int(CubeSphere.NB_BYTES_REHYST / 2)
	_ok(not wm._nb_ledger_admit(), "G-SP-NB-CAP: still refused inside the hysteresis band (no thrash)")
	_ok(wm._nb_breached, "G-SP-NB-CAP: breach held in the hysteresis band")
	# Below cap − REHYST ⇒ re-admission, breach cleared.
	stub.voxel_bytes = CubeSphere.NB_POOL_BYTES_CAP - CubeSphere.NB_BYTES_REHYST - 3 * 1048576
	_ok(wm._nb_ledger_admit(), "G-SP-NB-CAP: re-admits only below cap − REHYST (hysteresis)")
	_ok(not wm._nb_breached, "G-SP-NB-CAP: breach cleared below cap − REHYST")
	# Empty widened pool ⇒ B0 re-baselines (drift honesty), never a stuck breach.
	stub.count = 0
	stub.voxel_bytes = CubeSphere.NB_POOL_BYTES_CAP * 4     # even absurd foreign bytes: empty pool re-baselines
	_ok(wm._nb_ledger_admit() and not wm._nb_breached, "G-SP-NB-CAP: empty widened pool re-baselines B0 (never a stuck breach)")
	print("  [G-SP-NB-CAP] NOTE: live per-neighbour resident bytes are the verify_faceted G-M1-MEM authority (real spawn); this gate falsifies the ENFORCEMENT logic on measured counters.")
	wm.free()

# --- G-SP-OFF: FP_DEM_DEFER off ⇒ DEM byte-identical to today --------------------------------------------------------
func _gate_off() -> void:
	var rd := GlobalReliefData.new()
	rd.setup()
	_ok(rd.is_ready(), "G-SP-OFF: setup() allocates (FP_GLOBAL_RELIEF_DATA on)")
	# The deferred machinery is fully inert off the flag.
	_ok(rd._centre_dirs.is_empty(), "G-SP-OFF: centre-dir table NOT built with FP_DEM_DEFER off (no new resident bytes)")
	rd.request(5)
	_ok(rd.want_count() == 0, "G-SP-OFF: request() is a no-op off the flag (want-list stays empty)")
	_ok(not rd.is_settled(), "G-SP-OFF: never settled off the flag (mark_settled unused)")
	# Shipped pacer: bakes on a healthy frame with NO settle gate at all.
	var before := rd.baked_count()
	var fid := rd.step([], 5.0)
	_ok(fid >= 0 and rd.baked_count() == before + 1, "G-SP-OFF: step() bakes on a healthy frame with NO settle (shipped gated pacer)")
	# The shipped first-call loophole (frame_ms == 0 admits) is UNCHANGED off the flag — this is the byte-identical proof.
	var rd2 := GlobalReliefData.new(); rd2.setup()
	var fid0 := rd2.step([], 0.0)
	_ok(fid0 >= 0 and rd2.baked_count() == 1, "G-SP-OFF: frame_ms==0 first call STILL bakes off the flag (loophole unchanged = byte-identical)")
	# A hot frame still gates (shipped budget check intact).
	var rd3 := GlobalReliefData.new(); rd3.setup()
	_ok(rd3.step([], CubeSphere.BG_FRAME_BUDGET_MS + 1.0) == -1, "G-SP-OFF: a hot frame dispatches nothing (shipped gate intact)")

# --- G-SP-DEM-DEFER: FP_DEM_DEFER on ⇒ defer + demand-drive + alloc-free + first-call fix ----------------------------
func _gate_dem_defer() -> void:
	var n := FA.facet_count()
	var rd := GlobalReliefData.new()
	rd.setup()
	_ok(rd.is_ready(), "G-SP-DEM-DEFER: setup() allocates (FP_GLOBAL_RELIEF_DATA on)")
	# (a) ALLOC-FREE centre-dir table built once at setup.
	_ok(rd._centre_dirs.size() == n, "G-SP-DEM-DEFER: setup-time centre-dir table built (n=%d) — the alloc-free scan basis, no per-call _centre_dir alloc" % n)

	# (b) FIRST-CALL FIX: frame_ms == 0 (the boot-frame loophole) bakes nothing.
	var f0 := rd.step([], 0.0, false)
	_ok(f0 == -1 and rd.baked_count() == 0, "G-SP-DEM-DEFER: first call with frame_ms==0 bakes NOTHING (loophole closed)")

	# (c) DEFER: before settle, a healthy frame bakes nothing — even with a demand queued.
	_ok(rd.step([], 5.0, false) == -1 and rd.baked_count() == 0, "G-SP-DEM-DEFER: healthy frame BEFORE settle bakes nothing (deferred out of the reload window)")
	rd.request(7)
	_ok(rd.want_count() == 1, "G-SP-DEM-DEFER: request() populates the want-list under the flag")
	_ok(rd.step([], 5.0, false) == -1 and rd.baked_count() == 0, "G-SP-DEM-DEFER: still deferred pre-settle even with a demand queued")

	# (d) SETTLE ⇒ demand served (on-surface, offsurface=false); NO blind whole-planet sweep.
	rd.mark_settled()
	_ok(rd.is_settled(), "G-SP-DEM-DEFER: mark_settled() latches settled")
	var served := rd.step([], 5.0, false)
	_ok(served == 7 and rd.is_baked(7), "G-SP-DEM-DEFER: post-settle on-surface serves the DEMANDED fid (7)")
	_ok(rd.want_count() == 0, "G-SP-DEM-DEFER: served demand dropped from the want-list")
	_ok(rd.step([], 5.0, false) == -1 and rd.baked_count() == 1, "G-SP-DEM-DEFER: on-surface with empty want-list bakes NOTHING (no O(%d) blind sweep)" % n)

	# NEAREST-first demand ordering, reading the alloc-free table (axis = fid a's own centre dir ⇒ a wins with dot=1).
	var a := int(n / 4)
	var b := int((3 * n) / 4)
	rd.request(a); rd.request(b)
	var ca := rd._centre_dirs[a]
	var axis := [ca.x, ca.y, ca.z]
	var pick := rd.step(axis, 5.0, false)
	_ok(pick == a, "G-SP-DEM-DEFER: demand served NEAREST-first (axis→fid %d picked over %d)" % [a, b])
	rd.step(axis, 5.0, false)   # drain b as well
	_ok(rd.want_count() == 0, "G-SP-DEM-DEFER: both demands drained")

	# (e) OFF-SURFACE sweep fills the rest of the planet via the alloc-free _next_unbaked_fast (empty want + offsurface).
	var bc := rd.baked_count()
	var swept := rd.step([], 5.0, true)
	_ok(swept >= 0 and rd.baked_count() == bc + 1, "G-SP-DEM-DEFER: off-surface sweep fills the planet (alloc-free _next_unbaked_fast) when the want-list is empty")
	# ...and an off-surface sweep with a real axis prefers the nearest unbaked facet (alloc-free nearest scan).
	var rd2 := GlobalReliefData.new(); rd2.setup(); rd2.mark_settled()
	var target := int(n / 3)
	var ct := rd2._centre_dirs[target]
	var swept_near := rd2.step([ct.x, ct.y, ct.z], 5.0, true)
	_ok(swept_near == target, "G-SP-DEM-DEFER: off-surface sweep picks the NEAREST unbaked facet to the axis (fid %d)" % target)
