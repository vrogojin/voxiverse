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
	print("=== verify_stream_parallel (task #102 Phase A — FP_DEM_DEFER) ===")
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

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

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
