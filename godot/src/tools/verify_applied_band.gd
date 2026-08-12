extends SceneTree
## COSMOS-FAR-NEAR-MESA-DESIGN.md §4 gate (FP_APPLIED_VIEW_BAND) — proves the applied-cover probe now tracks the
## ENGINE VIEWER ROW WINDOW (the conjunct #113's slab clamp left unsatisfiable), fixing the mesa/badlands c=0
## dead-latch WITHOUT touching the #89/#113-proven three-zone height law, and compensating the un-probed band with a
## height-banded zone C that NEVER draws less than today. Runs in BOTH compile states (flag OFF and ON) and passes
## in both:
##
##   G-VB-LAW   (both)     — the ENGINE-MODEL pin the #113 gate lacked. A synthetic coverage callable models the FULL
##                 loadable set: AABB ⊆ slab × domain±2 ∩ the viewer row window rows [c−e, c+e−1] (the
##                 from_center_extents one-short-upward asymmetry included). With NO band query wired (so the probe
##                 asks the FULL slab, exactly like #113), `_applied_box_meshed_slab` is FALSE at player ly=10 (c=0,
##                 row4 never loads), FALSE at ly=100 (c=3, row−2 never loads), TRUE at ly=40 (c=1, all rows) —
##                 reproducing the mesa root cause + the #113 blind spot with no engine.
##   G-VB-SAT   (flag ON)  — the ladder LIVES at the mesa. Band query wired: the band-clamped `_applied_box_meshed_slab`
##                 is TRUE at ly=10; driving `_applied_probe_step(on=true)` grows `_applied_r` 0→112 one step/tick;
##                 flipping the coverage callable false drops it to 0 in ONE call (shrink-instant intact); `_applied_band`
##                 is recorded (top=128 at view 128, top=96 at view 96 — the band self-adapts to the live view distance).
##   G-VB-ZONEC (both)     — protrusion + soundness (drives the real `_blend_uncovered`/`_applied_covered` with forced
##                 applied_on/applied_r/applied_top + a force-built height cache): (a) with band top 128 every real
##                 backstop node (g ≤ 116 < 127) that zone C would take under a vacuous top STILL takes zone C (grey
##                 oval gone — the fix does not wrongly exclude loaded terrain); (b) a synthetic h=130 vertex is
##                 EXCLUDED from zone C (stays zone B) at top 128 but included at top 1e9 (the height gate works); (c)
##                 with band top 96 a real ≥96 peak node is EXCLUDED (hole-proof over an unloaded wall); (d) the
##                 NEVER-DRAWS-LESS invariant: every node's band-96 height ≥ its band-1e9 (#113) height; (e) the
##                 degraded pin — a DEAD ladder (applied_r=0) raises zone-C nodes to zone B, worst ≥ +5 (a silent
##                 re-death fails loudly).
##   G-VB-OFF   (flag OFF) — byte-off parity: the flag is repo-default false; `_applied_band` stays (0,1e9); the stats
##                 dict carries NO sh_applied_band key; `_blend_uncovered` with the default applied_top equals passing
##                 1e9 explicitly; the band clamp is skipped with no band query wired. (FLAT verify_feature 6042/0
##                 byte-identity is checked separately.)

const FA := preload("res://src/cosmos/facet_atlas.gd")
const TC := preload("res://src/world/terrain_config.gd")
const FFR := preload("res://src/world/facet_far_ring.gd")

# --- LIVE flag fingerprint (baseline pins). Gate-LOCAL consts, NOT CubeSphere.FP_* (repo-default-false would void
# the pin): these encode the flags the SERVED pck bakes on (design §1 fact 1). FP_APPLIED_PROBE_SLAB is live-on too
# (this fix REFINES it). FP_APPLIED_VIEW_BAND is the ONE the run toggles — read live below, not pinned. ---
const LIVE_FACETED := true
const LIVE_FP_FARRING_FULL_COVER := true
const LIVE_FP_BLOCKY_FARRING := true
const LIVE_FP_FARRING_APPLIED_COVER := true
const LIVE_FP_FARRING_UNCOVERED_TRUE := true
const LIVE_FP_APPLIED_PROBE_SLAB := true

# The live degraded params the design pins: streamed_ellipsoid_params = (r=128, O=0, H=128) (§1 fact 1).
const PROBE_PARAMS := Vector3(128.0, 0.0, 128.0)
const BS := 32.0    # module_world mesh_block_size (module_world.gd:393) — the row-window quantum

# gate-controllable engine-model state read by the synthetic callables (the callable signature is (fid, aabb) /
# (ly), so the player row + live view reach are stashed here — the SAME "member-var fixture" convention).
var _gate_player_ly := 0.0
var _gate_view_reach := 128.0

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

# --- synthetic coverage callables (mirror engine is_area_meshed's FULL loadable set: bounds slab × domain±2 AND the
# viewer row window rows [c−e, c+e−1]). The row window is the constraint #113's verify_applied_slab.gd model lacked. -
func _loadable_band() -> Vector2:
	var slab: Vector2 = TC.meshed_slab_y()
	var c := floorf(_gate_player_ly / BS)
	var e := ceilf(_gate_view_reach / BS)
	return Vector2(maxf((c - e) * BS, slab.x), minf((c + e) * BS, slab.y))   # rows [c−e, c+e−1] ⇒ [(c−e)·32,(c+e)·32)
func _cover_rowwindow(fid: int, aabb: AABB) -> bool:
	var slab: Vector2 = TC.meshed_slab_y()
	var dmin: Vector2i = FA.dom_min(fid)
	var dmax: Vector2i = FA.dom_max(fid)
	var lo := aabb.position
	var hi := aabb.position + aabb.size
	# slab × domain±2 (is_area_meshed never clips to bounds — the #113/FP_NB_WELD fact)
	if not (lo.y >= slab.x - 0.001 and hi.y <= slab.y + 0.001
			and lo.x >= float(dmin.x) - 2.001 and hi.x <= float(dmax.x) + 2.001
			and lo.z >= float(dmin.y) - 2.001 and hi.z <= float(dmax.y) + 2.001):
		return false
	# AND inside the viewer row window (the engine only meshes rows [c−e, c+e−1] around the player row)
	var band := _loadable_band()
	return lo.y >= band.x - 0.001 and hi.y <= band.y + 0.001
func _cover_never(_fid: int, _aabb: AABB) -> bool:
	return false
func _seam_true(_fid: int, _pap: Vector3) -> bool:
	return true
# the loadable-row-band query the fix wires (mirrors module_world.meshed_band_y with the gate's live view reach).
func _gate_band(ly: float) -> Vector2:
	var slab: Vector2 = TC.meshed_slab_y()
	var c := floorf(ly / BS)
	var e := ceilf(_gate_view_reach / BS)
	return Vector2(maxf((c - e) * BS, slab.x), minf((c + e) * BS, slab.y))

func _initialize() -> void:
	print("=== verify_applied_band (COSMOS-FAR-NEAR-MESA — FP_APPLIED_VIEW_BAND) ===")
	TC.warm_up()
	FA.warm_up()
	var slab: Vector2 = TC.meshed_slab_y()
	var band_on := CubeSphere.FP_APPLIED_VIEW_BAND
	print("  meshed_slab_y = (%.1f, %.1f); mesh_block_size = %d; FP_APPLIED_VIEW_BAND = %s" % [
		slab.x, slab.y, int(BS), str(band_on)])
	_ok(LIVE_FACETED and LIVE_FP_FARRING_FULL_COVER and LIVE_FP_BLOCKY_FARRING and LIVE_FP_FARRING_APPLIED_COVER
		and LIVE_FP_FARRING_UNCOVERED_TRUE and LIVE_FP_APPLIED_PROBE_SLAB,
		"fixture: live flag fingerprint pinned (FACETED + FULL_COVER + BLOCKY + APPLIED_COVER + UNCOVERED_TRUE + APPLIED_PROBE_SLAB)")
	# The row window at c=0 tops out at row 3 (y128 excluded) ⇒ the FULL slab (top 130) is unloadable there.
	var view128_e := int(ceil(128.0 / BS))
	_ok(float((0 + view128_e) * int(BS)) < slab.y,
		"fixture: at c=0 the viewer row window top ((0+%d)·32=%d) is below the slab top (%.0f) ⇒ full-slab probe dead" % [
			view128_e, (0 + view128_e) * int(BS), slab.y])

	var fid := _find_mountain_facet()
	var span := _facet_relief_span(fid)
	print("  atlas: k=%d, R=%.0f, mountain fid=%d, relief span≈%.1f blk, backstop_sink=%.2f, ENV_EPS_G=%.2f, STEP=%d, MAX=%d" % [
		FA.K, FA.R_BLOCKS, fid, span, TierPlace.backstop_sink(), TierPlace.ENV_EPS_G,
		CubeSphere.APPLIED_PROBE_STEP, CubeSphere.APPLIED_PROBE_MAX])
	_ok(span >= 30.0, "fixture: scanned mountain facet has relief span ≥30 blocks (found %.1f)" % span)

	_gate_law(fid)                 # G-VB-LAW — engine-model pin (both compiles)
	if band_on:
		_gate_sat(fid)             # G-VB-SAT — ladder lives (flag ON)
	else:
		_gate_off(fid)             # G-VB-OFF — byte-off parity (flag OFF)
	_gate_zonec(fid)               # G-VB-ZONEC — protrusion + soundness (both compiles)

	print("=== verify_applied_band: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- fixtures ----------
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
			var d: Vector3 = FFR._weld_unit(cd, float(i) / float(n - 1), float(j) / float(n - 1))
			var g := TC.profile_at_dir(d.x, d.y, d.z, FA.R_BLOCKS).x
			gmin = minf(gmin, g)
			gmax = maxf(gmax, g)
	return gmax - gmin

func _col_at_lattice(fid: int, lx: float, ly: float, lz: float) -> Vector3:
	var w: Array = FA.lattice_to_world64(fid, lx, ly, lz)
	return Vector3(float(w[0]), float(w[1]), float(w[2]))

# ---------- G-VB-LAW: the engine-model pin (both compiles; NO band query wired ⇒ the #113 full-slab probe) ----------
func _gate_law(fid: int) -> void:
	print("  --- G-VB-LAW: full-slab probe DEAD at c=0/c=3, ALIVE at c=1 under the viewer-row-window model ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.set("_active_fid", fid)
	ring.call("set_cover_query", Callable(self, "_cover_rowwindow"))
	ring.call("set_seam_cover_query", Callable(self, "_seam_true"))
	# NO band query wired ⇒ `_applied_box_meshed_slab` asks the FULL slab (exactly #113) even under FP_APPLIED_VIEW_BAND.
	var dmin: Vector2i = FA.dom_min(fid)
	var dmax: Vector2i = FA.dom_max(fid)
	var dcx := float(dmin.x + dmax.x) * 0.5
	var dcz := float(dmin.y + dmax.y) * 0.5
	# ly = 10 (c=0, mesa valley floor), view 128: the full-slab box top (ly+h=138 → slab 130) needs row 4 (y128..),
	# but the c=0 window tops out at row 3 (band top 128) ⇒ FALSE. THE mesa dead-latch.
	_gate_view_reach = 128.0
	_gate_player_ly = 10.0
	var f10 := bool(ring.call("_applied_box_meshed_slab", 16.0, PROBE_PARAMS.z, dcx, 10.0, dcz))
	# ly = 40 (c=1, the #113 grass base), view 128: band top (1+4)·32=160 clips to slab 130 = the box top ⇒ TRUE.
	_gate_player_ly = 40.0
	var t40 := bool(ring.call("_applied_box_meshed_slab", 16.0, PROBE_PARAMS.z, dcx, 40.0, dcz))
	# ly = 40 (c=1) but a FORCED view 64 (e=2): band top (1+2)·32=96 < slab 130, so the full-slab box top (130)
	# overflows the window ⇒ FALSE. Proves the band MUST fold in the live view distance (a forced-96/64 view), not
	# just the static slab — the #113 clamp is dead even at c=1 once the view shrinks.
	_gate_view_reach = 64.0
	_gate_player_ly = 40.0
	var f40v64 := bool(ring.call("_applied_box_meshed_slab", 16.0, PROBE_PARAMS.z, dcx, 40.0, dcz))
	_ok(not f10, "G-VB-LAW: full-slab probe FALSE at ly=10 (c=0 — row 4 never loads, THE mesa dead-latch)")
	_ok(t40, "G-VB-LAW: full-slab probe TRUE at ly=40 view128 (c=1 — band top clips to slab, why #113 shipped 'healed')")
	_ok(not f40v64, "G-VB-LAW: full-slab probe FALSE at ly=40 view64 (band top 96 < slab ⇒ dead at c=1 too — view distance matters)")
	ring.free()

# ---------- G-VB-SAT: ladder lives (flag ON) ----------
func _gate_sat(fid: int) -> void:
	print("  --- G-VB-SAT: band-clamped probe TRUE at the mesa (c=0); ladder 0→MAX; shrink-instant; band self-adapts ---")
	# The ladder path (`_applied_probe_step`→`_applied_box_meshed`) only reaches the slab body (and thus the band
	# clamp) when FP_APPLIED_PROBE_SLAB is also on — this fix REFINES it. The live pck bakes BOTH on; run the SAT
	# config with both (`sed` FP_APPLIED_PROBE_SLAB=true too). The DIRECT `_applied_box_meshed_slab` asserts below
	# don't need it, but the ladder-convergence sub-test does.
	_ok(CubeSphere.FP_APPLIED_PROBE_SLAB, "G-VB-SAT config: FP_APPLIED_PROBE_SLAB is also on (this fix refines it)")
	var dmin: Vector2i = FA.dom_min(fid)
	var dmax: Vector2i = FA.dom_max(fid)
	var dcx := float(dmin.x + dmax.x) * 0.5
	var dcz := float(dmin.y + dmax.y) * 0.5

	# (1) band query wired ⇒ the box is clamped to the loadable window ⇒ probe TRUE at c=0.
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.set("_active_fid", fid)
	ring.call("set_cover_query", Callable(self, "_cover_rowwindow"))
	ring.call("set_seam_cover_query", Callable(self, "_seam_true"))
	ring.call("set_band_query", Callable(self, "_gate_band"))
	_gate_view_reach = 128.0
	_gate_player_ly = 10.0
	_ok(bool(ring.call("_applied_box_meshed_slab", 16.0, PROBE_PARAMS.z, dcx, 10.0, dcz)),
		"G-VB-SAT: band-clamped _applied_box_meshed_slab TRUE at ly=10 (c=0 mesa — the dead-latch is fixed)")

	# (2) the real ladder grows one step/tick to APPLIED_PROBE_MAX at the mesa column.
	var col_c := _col_at_lattice(fid, dcx, 10.0, dcz)
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
	_ok(grow_ok, "G-VB-SAT: _applied_r never grows by more than one step per call")
	_ok(is_equal_approx(prev, max_r), "G-VB-SAT: ladder converges to APPLIED_PROBE_MAX (%d), got %.1f" % [int(max_r), prev])
	# (2b) the band that let it live is recorded — top 128 at view 128.
	var band128: Vector2 = ring.get("_applied_band")
	_ok(is_equal_approx(band128.y, 128.0), "G-VB-SAT: _applied_band top = 128 at view 128 (got %.1f)" % band128.y)

	# (3) shrink-instantly: coverage vanishes ⇒ ONE call drops _applied_r to 0.
	ring.call("set_cover_query", Callable(self, "_cover_never"))
	ring.call("_applied_probe_step", true, PROBE_PARAMS)
	_ok(is_equal_approx(float(ring.get("_applied_r")), 0.0),
		"G-VB-SAT: shrink-instantly — one call collapses _applied_r to 0 when coverage vanishes")
	ring.free()

	# (4) the band SELF-ADAPTS to a forced-96 view: top drops to 96, and the ladder still lives (band narrows in step).
	var ring2: Node3D = FFR.new()
	get_root().add_child(ring2)
	ring2.set("_active_fid", fid)
	ring2.call("set_cover_query", Callable(self, "_cover_rowwindow"))
	ring2.call("set_seam_cover_query", Callable(self, "_seam_true"))
	ring2.call("set_band_query", Callable(self, "_gate_band"))
	_gate_view_reach = 96.0
	_gate_player_ly = 10.0
	ring2.call("set_player_column", col_c)
	ring2.call("_applied_probe_step", true, PROBE_PARAMS)
	var band96: Vector2 = ring2.get("_applied_band")
	_ok(float(ring2.get("_applied_r")) > 0.0, "G-VB-SAT: ladder still alive at forced view 96 (band self-adapts)")
	_ok(is_equal_approx(band96.y, 96.0), "G-VB-SAT: _applied_band top = 96 at view 96 (got %.1f) — self-adapting" % band96.y)
	ring2.free()

# ---------- G-VB-ZONEC: protrusion + soundness (both compiles) ----------
func _gate_zonec(fid: int) -> void:
	print("  --- G-VB-ZONEC: band top 128 keeps loaded terrain in zone C; above-band vertices stay zone B (hole-proof) ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("_ensure_backstop_true_cached", fid)
	ring.call("_ensure_btrue_h_cached", fid)   # force-build the height cache so the gate runs in BOTH compiles
	var true_pos: PackedVector3Array = (ring.get("_btrue_cache") as Dictionary)[fid]
	var true_h: PackedFloat32Array = (ring.get("_btrue_h_cache") as Dictionary)[fid]
	_ok(true_pos.size() == true_h.size() and true_pos.size() > 0,
		"fixture: true position/height caches non-empty, same size (%d)" % true_pos.size())

	# player column at the peak (a robust straddle vantage that populates zone C).
	var peak_i := 0
	var peak_r := -1.0
	for i in range(true_pos.size()):
		var l: float = (true_pos[i] as Vector3).length()
		if l > peak_r:
			peak_r = l; peak_i = i
	var col: Vector3 = true_pos[peak_i]
	var g_peak := true_h[peak_i]
	var applied_max := float(CubeSphere.APPLIED_PROBE_MAX)

	# (a) band top 128: every real node (g ≤ 116 < 127) that zone C takes under a vacuous top STILL takes zone C —
	#     the fix does not wrongly demote loaded terrain (⇒ the grey oval's zone-C cover is still there).
	var demoted := 0
	var zc_vac := 0
	for i in range(true_pos.size()):
		var t: Vector3 = true_pos[i]
		var zc_v := bool(ring.call("_applied_covered", t, col, applied_max, PROBE_PARAMS, true_h[i], 1.0e9))
		var zc_b := bool(ring.call("_applied_covered", t, col, applied_max, PROBE_PARAMS, true_h[i], 128.0))
		if zc_v:
			zc_vac += 1
			if not zc_b:
				demoted += 1
	_ok(zc_vac > 0, "G-VB-ZONEC (a): fixture has a populated zone C (%d nodes)" % zc_vac)
	_ok(demoted == 0, "G-VB-ZONEC (a): band top 128 demotes NO real (g≤116) zone-C node (grey oval cover intact; %d demoted)" % demoted)

	# (b) synthetic h=130 vertex: EXCLUDED from zone C at top 128, INCLUDED at top 1e9 — the height gate itself.
	var s130_128 := bool(ring.call("_applied_covered", col, col, applied_max, PROBE_PARAMS, 130.0, 128.0))
	var s130_vac := bool(ring.call("_applied_covered", col, col, applied_max, PROBE_PARAMS, 130.0, 1.0e9))
	_ok(not s130_128, "G-VB-ZONEC (b): a synthetic h=130 vertex is EXCLUDED from zone C at band top 128 (stays zone B)")
	_ok(s130_vac, "G-VB-ZONEC (b): the SAME h=130 vertex IS zone-C-eligible at top 1e9 (only the height gate excludes it)")

	# (c) hole-proof: at a band top BELOW the real peak (a reduced view / low ground can't load the wall top) the
	#     peak node is EXCLUDED from zone C — it stays zone B over an unloaded wall (no sink-into-a-hole).
	var hole_top := floorf(g_peak) - 4.0
	var peak_vac := bool(ring.call("_applied_covered", col, col, applied_max, PROBE_PARAMS, g_peak, 1.0e9))
	var peak_hole := bool(ring.call("_applied_covered", col, col, applied_max, PROBE_PARAMS, g_peak, hole_top))
	_ok(peak_vac and not peak_hole,
		"G-VB-ZONEC (c): the peak node (g=%.0f) is zone C at top 1e9 but EXCLUDED at top %.0f (stays zone B over an unloaded wall)" % [g_peak, hole_top])

	# (d) NEVER-DRAWS-LESS invariant: band-clamped zone C is a SUBSET of band-1e9 zone C ⇒ every node's band-clamped
	#     height ≥ its band-1e9 (#113) height (a demoted node rises from sunk zone C to at-height zone B — draws MORE,
	#     never a hole).
	var covered: PackedVector3Array = ring.call("_sunk_positions", true_pos, fid)
	var blend_1e9: PackedVector3Array = ring.call("_blend_uncovered", covered, fid, col, true, PROBE_PARAMS, true, applied_max, 1.0e9)
	var blend_band: PackedVector3Array = ring.call("_blend_uncovered", covered, fid, col, true, PROBE_PARAMS, true, applied_max, hole_top)
	var draws_less := 0
	for i in range(true_pos.size()):
		if blend_band[i].length() < blend_1e9[i].length() - 0.001:
			draws_less += 1
	_ok(draws_less == 0, "G-VB-ZONEC (d): NEVER draws less than today — band-clamped height ≥ band-1e9 for every node (%d violations)" % draws_less)

	# (e) degraded pin: a DEAD ladder (applied_r=0) raises zone-C nodes to zone B — worst ≥ +5 (a silent re-death fails loudly).
	var blend_live: PackedVector3Array = ring.call("_blend_uncovered", covered, fid, col, true, PROBE_PARAMS, true, applied_max, 1.0e9)
	var blend_dead: PackedVector3Array = ring.call("_blend_uncovered", covered, fid, col, true, PROBE_PARAMS, true, 0.0, 1.0e9)
	var n_zc := 0
	var n_rise := 0
	var worst_rise := 0.0
	for i in range(true_pos.size()):
		var t: Vector3 = true_pos[i]
		if bool(ring.call("_uncovered", t, col, true, PROBE_PARAMS)):
			continue
		if not bool(ring.call("_applied_covered", t, col, applied_max, PROBE_PARAMS)):
			continue
		n_zc += 1
		var rise := blend_dead[i].length() - blend_live[i].length()
		if rise > 0.5:
			n_rise += 1
		worst_rise = maxf(worst_rise, rise)
	var frac := (float(n_rise) / float(n_zc)) if n_zc > 0 else 0.0
	print("    zone-C nodes=%d, rise-on-death=%d (%.0f%%), worst rise=%.2f blk" % [n_zc, n_rise, 100.0 * frac, worst_rise])
	_ok(frac >= 0.30, "G-VB-ZONEC (e): ≥30%% of zone-C nodes RISE when the ladder dies (got %.0f%%)" % [100.0 * frac])
	_ok(worst_rise >= 5.0, "G-VB-ZONEC (e): worst dead-ladder rise ≥ +5 blk (the +9.08-class overshoot; got %.2f)" % worst_rise)
	ring.free()

# ---------- G-VB-OFF: byte-off parity (flag OFF) ----------
func _gate_off(fid: int) -> void:
	print("  --- G-VB-OFF: flag off ⇒ default band, no telemetry key, band clamp skipped ---")
	_ok(not CubeSphere.FP_APPLIED_VIEW_BAND, "G-VB-OFF: FP_APPLIED_VIEW_BAND is repo-default false")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.set("_active_fid", fid)
	# _applied_band starts at the vacuous default (0, 1e9) ⇒ applied_top 1e9 ⇒ height gate vacuous.
	var band0: Vector2 = ring.get("_applied_band")
	_ok(is_equal_approx(band0.y, 1.0e9), "G-VB-OFF: _applied_band top is the vacuous 1e9 default (no band recorded)")
	# The stats dict must NOT carry the sh_applied_band key with the flag off (shell_telemetry needs _cam_set to build).
	ring.set("_cam_set", true)
	var st: Dictionary = ring.call("shell_telemetry")
	_ok(not st.has("sh_applied_band"), "G-VB-OFF: stats dict has NO sh_applied_band key with the flag off")
	_ok(st.has("sh_applied_r"), "G-VB-OFF: stats dict still carries sh_applied_r (shipped #113 telemetry intact)")
	# The band clamp is skipped with no band query wired ⇒ the probe body is the shipped #113 slab clamp verbatim.
	ring.call("set_cover_query", Callable(self, "_cover_rowwindow"))
	ring.call("set_seam_cover_query", Callable(self, "_seam_true"))
	var dmin: Vector2i = FA.dom_min(fid)
	var dmax: Vector2i = FA.dom_max(fid)
	var dcx := float(dmin.x + dmax.x) * 0.5
	var dcz := float(dmin.y + dmax.y) * 0.5
	_gate_view_reach = 128.0
	_gate_player_ly = 10.0
	# With no band query, even were the flag on the clamp is skipped ⇒ full-slab probe ⇒ dead at c=0 (the #113 state).
	_ok(not bool(ring.call("_applied_box_meshed_slab", 16.0, PROBE_PARAMS.z, dcx, 10.0, dcz)),
		"G-VB-OFF: no band query wired ⇒ full-slab probe ⇒ dead at c=0 (shipped #113 behaviour preserved)")
	ring.free()
