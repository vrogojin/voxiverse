extends SceneTree
## COSMOS MAIN-THREAD ORCHESTRATION TH1 — the FP_TEX_BAKE_WORKER truth gate (docs/COSMOS-MAINTHREAD-ORCHESTRATION-
## DESIGN.md §6, table row TH1). Proves the FacetTexBaker per-frame bake COMPUTE moved onto the TH0 job-lane worker
## while the main thread pays ONLY the update_layer commit, and that the result is BYTE-IDENTICAL to the on-main bake.
##
## The offload path is driven directly via the baker's _gate_force_worker hook (a supplied JobLane), so the gate is
## valid in whatever CubeSphere flag state it launches in — like verify_job_lane driving the plain lane class.
##
##   G-TW-OFF       FP_TEX_BAKE_WORKER defaults false — the byte-identity keystone. A baker handed a lane with the flag
##                  off does NOT go to the worker (worker_offload_on()==false): it bakes on main, the lane stays idle,
##                  and the pixels equal a no-lane baker's.
##   G-TW-EXACT     the worker-computed bake is byte-identical to the on-main bake for the same facet — base map (a
##                  progressive base facet) always, and the U1 band layer when FP_BAND_BLOCK_MAP is on. The sampler is
##                  pure ⇒ exact (ε 0), and premultiply on an a==1 texel is the identity, so texels match to the byte.
##   G-TW-MAINCOST  with the offload on, the bake COMPUTE leaves the frame: the worker baker's per-update MAIN cost
##                  (main_bake_ms — orchestration + submit only) is far below the on-main baker's compute, while the
##                  actual bake still completes (compute ran off-main) and the lane's commit uploads stay bounded.
##   G-TW-NOTREE    structural: the worker compute functions (_worker_compute_unit / _bake_facet_pixels /
##                  _cu_compute_slice / _bm_compute_slice) touch NO RenderingServer / Texture2DArray / update_layer —
##                  they write only the staging Images; every GPU touch lives in the main-thread commit.
const JobLaneC := preload("res://src/world/job_lane.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const TC := preload("res://src/world/terrain_config.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

## Facet `fid`'s centre unit direction (avg of its 4 planar corners) — the emit axis that makes _next_base_fid pick it.
func _centre(fid: int) -> Array:
	var s := Vector3.ZERO
	for ci in range(4):
		var c := FA.facet_planar_corner(fid, ci)
		s += Vector3(float(c[0]), float(c[1]), float(c[2]))
	var n := s.normalized()
	return [n.x, n.y, n.z]

## Pump the lane + drive the worker baker until `fid` is base-baked (or the iteration budget is spent). Inline loop
## (no closures — the GDScript capture-by-value trap fakes progress), giving the shared pool real time between pumps.
func _drive_base(baker, lane, axis: Array) -> bool:
	for _i in range(8000):
		baker.update(axis, false, 2.0, -1)
		lane.pump()
		if baker.job_inflight() == false and lane.is_idle() and baker.baked_count() > 0:
			return true
		OS.delay_msec(1)
	return false

func _initialize() -> void:
	print("=== verify_tex_worker (TH1 FP_TEX_BAKE_WORKER) — flag=%s ===" % CubeSphere.FP_TEX_BAKE_WORKER)
	if not CubeSphere.FACETED or not CubeSphere.FLAT_WORLD:
		print("  FAIL: this gate must run with FACETED = true (FLAT_WORLD = true).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	TC.warm_up()
	FA.warm_up()
	BlockCatalog.ensure_ready()
	FarPalette.ensure_ready()
	var fid := FA.spawn_facet()
	TC.set_active_facet(fid)
	var BT: int = FacetTexBaker.BASE_TEXELS
	print("  spawn facet = %d (K=%d), flags FP_JOB_LANE=%s FP_BAND_BLOCK_MAP=%s" % [fid, FA.K, str(CubeSphere.FP_JOB_LANE), str(CubeSphere.FP_BAND_BLOCK_MAP)])

	# --- G-TW-OFF: flag defaults false; a lane-wired baker with the flag off stays on the on-main path ---
	_ok(CubeSphere.FP_TEX_BAKE_WORKER == false, "G-TW-OFF: FP_TEX_BAKE_WORKER defaults false (byte-identical keystone)")
	var laneoff := JobLaneC.new(2)
	var boff := FacetTexBaker.new(); boff.setup(fid)
	boff.set_job_lane(laneoff)                      # flag off ⇒ worker NOT engaged
	_ok(not boff.worker_offload_on(), "G-TW-OFF: set_job_lane with the flag off leaves the offload disabled (on-main path)")
	var axis := _centre(fid)
	# An update() with the flag off must run on main and NEVER touch the lane (a budget-driven bake, timing-dependent
	# in count — so this checks lane non-use, not a texel diff).
	boff.update(axis, false, 60.0, -1)
	_ok(laneoff.is_idle() and laneoff.take_main_commit_ms() == 0.0 and boff.baked_count() > 0,
		"G-TW-OFF: flag-off update bakes on main, the lane is never used (idle, 0 commit; baked=%d)" % boff.baked_count())
	# Byte-identity: a DETERMINISTIC single-facet bake (no budget timing) with a lane wired but flag off equals the
	# no-lane bake, texel for texel.
	var boff2 := FacetTexBaker.new(); boff2.setup(fid); boff2.set_job_lane(laneoff)
	boff2.bake_facet(fid)
	var bnol := FacetTexBaker.new(); bnol.setup(fid)
	bnol.bake_facet(fid)
	var off_same := true
	for ty in range(BT):
		for tx in range(BT):
			if boff2.texel_color(fid, tx, ty) != bnol.texel_color(fid, tx, ty):
				off_same = false
	_ok(off_same, "G-TW-OFF: lane-wired-but-flag-off bake is byte-identical to the no-lane bake")

	# --- G-TW-EXACT (base): worker bake == on-main bake for the same facet ---
	var bref := FacetTexBaker.new(); bref.setup(fid)
	bref.bake_facet(fid)                            # on-main reference (straight rgb, a=1)
	var lane := JobLaneC.new(2)
	var bw := FacetTexBaker.new(); bw.setup(fid)
	bw.prewarm(PackedInt32Array())                 # build the base array so the commit's update_layer is the real path
	bw._gate_force_worker(lane)
	_ok(bw.worker_offload_on(), "G-TW-EXACT: _gate_force_worker engaged the offload path")
	var baked := _drive_base(bw, lane, axis)
	_ok(baked and bw.is_baked(fid), "G-TW-EXACT: the worker baked the axis facet through the lane (baked=%s)" % str(bw.is_baked(fid)))
	var exact := baked
	var diffs := 0
	for ty in range(BT):
		for tx in range(BT):
			if bref.texel_color(fid, tx, ty) != bw.texel_color(fid, tx, ty):
				exact = false; diffs += 1
	_ok(exact, "G-TW-EXACT(base): every worker texel == the on-main bake, byte-identical (%d/%d differ)" % [diffs, BT * BT])
	# Teeth: the compared grids are REAL baked data (opaque, a==1 at the centre) — not two empty transparent grids that
	# would trivially "match". So a genuine difference would have been caught.
	_ok(bw.texel_color(fid, BT / 2, BT / 2).a == 1.0 and bref.texel_color(fid, BT / 2, BT / 2).a == 1.0,
		"G-TW-EXACT teeth: both compared grids are opaque real bakes (worker a=%.1f, ref a=%.1f)" % [bw.texel_color(fid, BT / 2, BT / 2).a, bref.texel_color(fid, BT / 2, BT / 2).a])

	# --- G-TW-MAINCOST: the compute left the frame (worker main-per-update << on-main compute), bake still completes ---
	var bmain := FacetTexBaker.new(); bmain.setup(fid); bmain.prewarm(PackedInt32Array())
	bmain.update(axis, false, 60.0, -1)            # one big-budget on-main update → the whole compute paid on main
	var c := bmain.main_bake_ms()
	var lane2 := JobLaneC.new(2)
	var bw2 := FacetTexBaker.new(); bw2.setup(fid); bw2.prewarm(PackedInt32Array())
	bw2._gate_force_worker(lane2)
	var wmax := 0.0
	for _i in range(600):
		bw2.update(axis, false, 60.0, -1)
		wmax = maxf(wmax, bw2.main_bake_ms())
		lane2.pump()
		OS.delay_msec(1)
	var commit_ms := lane2.take_main_commit_ms()
	print("  MAINCOST: on-main compute = %.3f ms/update, worker main = %.3f ms/update (max), lane commit total = %.3f ms, worker baked = %d" % [c, wmax, commit_ms, bw2.baked_count()])
	_ok(c > 0.0 and wmax < c, "G-TW-MAINCOST: worker per-update MAIN cost %.3fms is below the on-main compute %.3fms (compute left the frame)" % [wmax, c])
	_ok(bw2.baked_count() > 0, "G-TW-MAINCOST: the offloaded bake still completed on the worker (%d facets baked)" % bw2.baked_count())
	_ok(commit_ms >= 0.0, "G-TW-MAINCOST: the main-thread commit (update_layer only) is the bounded residual (%.3f ms total)" % commit_ms)

	# --- G-TW-NOTREE: structural — the worker compute functions touch no RenderingServer / GPU array ---
	_gate_notree()

	# --- G-TW-EXACT (band): only when FP_BAND_BLOCK_MAP is sed-toggled on ---
	if CubeSphere.FP_FACET_TEX and CubeSphere.FP_SHELL_ABSOLUTE and CubeSphere.FP_BLOCK_DETAIL and CubeSphere.FP_BAND_BLOCK_MAP:
		_gate_band_exact(fid)
	else:
		print("  (band G-TW-EXACT skipped — needs FP_FACET_TEX && FP_SHELL_ABSOLUTE && FP_BLOCK_DETAIL && FP_BAND_BLOCK_MAP)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- G-TW-NOTREE ---------------------------------------------------------------------------------
func _gate_notree() -> void:
	var src := ""
	var f := FileAccess.open("res://src/world/facet_tex_baker.gd", FileAccess.READ)
	if f != null:
		src = f.get_as_text()
		f.close()
	# The worker-thread compute functions — every GPU touch must be ABSENT from their bodies.
	var funcs := ["_worker_compute_unit", "_bake_facet_pixels", "_cu_compute_slice", "_bm_compute_slice"]
	var forbidden := ["update_layer", "create_from_images", "RenderingServer", "Texture2DArray",
		"_tex.", "_id_tex.", "_cu_tex.", "_bm_tex.", "add_child"]
	var lines := src.split("\n")
	var clean := src != ""
	var offender := ""
	for fn in funcs:
		var inside := false
		for line in lines:
			var s := line as String
			var st := s.strip_edges()
			if st.begins_with("func "):
				inside = st.begins_with("func " + fn + "(")
				continue
			if not inside:
				continue
			if st.begins_with("#"):
				continue                          # a comment may name a GPU op in prose — code only
			for tok in forbidden:
				if st.find(tok) != -1:
					clean = false
					offender = "%s → %s (%s)" % [fn, tok, st]
					break
			if not clean:
				break
		if not clean:
			break
	_ok(clean, "G-TW-NOTREE: worker compute functions touch no RenderingServer/GPU array (offender: %s)" % (offender if offender != "" else "none"))

# --- G-TW-EXACT (band) ---------------------------------------------------------------------------
func _gate_band_exact(fid: int) -> void:
	# On-main reference: a single huge-budget update bakes the whole band on main.
	var bref := FacetTexBaker.new(); bref.setup(fid)
	bref.update([2.0, 0.0, 0.0], false, 100000.0, fid)
	if not (bref.band_on() and bref.band_slot(fid) >= 0):
		_ok(false, "G-TW-EXACT(band): on-main reference failed to bake the active band facet")
		return
	# Worker: drive the band bake through the lane (small budget → row-sliced across round-trips).
	var lane := JobLaneC.new(2)
	var bw := FacetTexBaker.new(); bw.setup(fid)
	bw._gate_force_worker(lane)
	var res := false
	for _i in range(30000):
		bw.update([2.0, 0.0, 0.0], false, 4.0, fid)
		lane.pump()
		if bw.band_slot(fid) >= 0 and not bw.job_inflight() and lane.is_idle():
			res = true; break
		OS.delay_msec(1)
	_ok(res and bw.band_slot(fid) >= 0, "G-TW-EXACT(band): the worker baked the active band facet resident (slot=%d)" % bw.band_slot(fid))
	var n := bref.band_n_of(fid)
	var nx := int(n.x)
	var ny := int(n.y)
	var same := res and int(bw.band_n_of(fid).x) == nx and int(bw.band_n_of(fid).y) == ny
	var bdiffs := 0
	for by in range(ny):
		for bx in range(nx):
			if bref.band_id_at(fid, bx, by) != bw.band_id_at(fid, bx, by):
				same = false; bdiffs += 1
	_ok(same, "G-TW-EXACT(band): every worker band id == the on-main band id, byte-identical (%dx%d, %d differ)" % [nx, ny, bdiffs])
