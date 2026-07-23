extends SceneTree
## COSMOS-PERF FALL-COLLAPSE FIX gate — G-COAST-BATCH (fix/voxiverse-coast-batch, flag CubeSphere.FP_COAST_BATCH).
## The live fall-from-orbit collapsed to ~6 fps (hovering at the SAME altitude ran 49 fps): the free-fall / orbit
## coast movers cover the full frame delta with N ≤ 30 substeps, but each substep RE-PROJECTED the whole state
## lattice↔BCI and ALLOCATED a fresh OrbitalState (lattice_to_world64 → fixed_to_bci → OrbitalState.make → step →
## clamp → bci_to_fixed → world_to_lattice64) — N re-projections + N allocations per frame (~150 ms). The fix BATCHES
## the substeps: convert lattice→BCI ONCE, run the N cheap symplectic steps entirely in the BCI frame (reusing ONE
## OrbitalState — CosmosNav.coast_batch_bci), re-project BCI→lattice ONCE. This gate proves the batch is:
##   (a) BCI-EXACT     — coast_batch_bci(n) is BIT-identical to n sequential make()+single-step()+clamp() (the
##                       physics core is a faithful batch — so the orbit coast, which carries [p,v] and never reads
##                       `position` back, is numerically exact batched).
##   (b) ONE ALLOC     — coast_batch_bci does EXACTLY ONE OrbitalState.make for the whole N-substep batch (vs N for
##                       the per-substep chain) — measured on the REAL constructor counter OrbitalState.make_calls.
##   (c) FALL-EQUIV    — the full free-fall per-frame chain (with the lattice↔BCI round-trip + the per-substep f32
##                       `position` truncation) matches the batched chain within a tight tolerance over many frames
##                       of VARIED dt (the batch is strictly MORE accurate — it removes the per-substep f32 round-trip).
##   (d) ONE REPROJ    — the batched free-fall frame does EXACTLY ONE lattice_to_world64 + ONE world_to_lattice64 +
##                       ONE make regardless of N (the per-substep reference does N of each) — the perf invariant,
##                       counted on the REAL FacetAtlas maps. The batched ORBIT frame does ZERO lattice_to_world64
##                       (it carries [p,v], never reconstructs) + ONE world_to_lattice64.
##   (e) ORBIT-EXACT   — the batched orbit coast over many frames is BIT-identical to the per-substep _coast_step_kepler
##                       chain (neither reads `position` back ⇒ no divergence at all).
## Flag-off byte-identity (FP_COAST_BATCH off ⇒ the shipped per-substep chain) is the FLAT verify_feature (6042/0),
## run separately. The gate MIRRORS the exact structure of player.gd _coast_step / _coast_batch / _coast_step_kepler /
## _coast_batch_kepler (they are the same lattice_to_world64/fixed_to_bci/coast_batch_bci/bci_to_fixed/world_to_lattice64
## sequence) so the counts/trajectories it proves are the player's.
##
## RUN:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_coast_batch.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const DV := preload("res://src/cosmos/dvec3.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")
const ORB := preload("res://src/cosmos/orbital_state.gd")
const NAV := preload("res://src/cosmos/cosmos_nav.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _rel(a: float, b: float) -> float:
	var d := absf(b)
	if d < 1.0e-300:
		return absf(a - b)
	return absf(a - b) / d

# --- FacetAtlas conversion counters (prove the one-reprojection perf invariant on the REAL maps) ---
var _l2w := 0
var _w2l := 0
func _lattice_to_world(fid: int, x: float, y: float, z: float) -> Array:
	_l2w += 1
	return FacetAtlas.lattice_to_world64(fid, x, y, z)
func _world_to_lattice(fid: int, wx: float, wy: float, wz: float) -> Array:
	_w2l += 1
	return FacetAtlas.world_to_lattice64(fid, wx, wy, wz)

var _body := "earth"
var _t := 1234.5                              # a fixed nav clock (constant across a frame's substeps, as in the player)
var _fid := 0
var _soi := 0.0

func _initialize() -> void:
	print("=== verify_coast_batch (COSMOS-PERF: G-COAST-BATCH — batched free-fall / orbit coast) ===")
	print("  CubeSphere.FP_COAST_BATCH = %s (the batch math is flag-independent pure static)" % str(CubeSphere.FP_COAST_BATCH))
	FacetAtlas.warm_up()
	_soi = NAV.soi_radius(_body)
	_gate_bci_exact()
	_gate_one_alloc()
	_gate_fall_equiv()
	_gate_one_reproj()
	_gate_orbit_exact()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- (a) coast_batch_bci is BIT-identical to n sequential make+step+clamp ----------
func _gate_bci_exact() -> void:
	print("  --- (a) BCI-EXACT: coast_batch_bci(n) == n sequential make+step+clamp (bit-identical physics core) ---")
	var R := GRAV.r_vox(_body)
	# Two seeds: a near-radial fall and a tangential orbit — both must batch exactly.
	var cases := [
		{"name": "radial fall", "p": DV.v(R + 701.0, 0.0, 0.0), "v": DV.v(-60.0, 5.0, 0.0)},
		{"name": "tangential orbit", "p": DV.v(5.0 * R, 0.0, 0.0), "v": DV.v(0.0, sqrt(GRAV.gm_dyn(_body) / (5.0 * R)), 0.0)},
	]
	for c in cases:
		var p0: PackedFloat64Array = c["p"]
		var v0: PackedFloat64Array = c["v"]
		for n in [1, 5, 30]:
			var h := NAV.MAX_NAV_DT
			# reference: n fresh make()+single-step()+clamp(), carrying [p,v] (the per-substep BCI physics)
			var rp := PackedFloat64Array([p0[0], p0[1], p0[2]])
			var rv := PackedFloat64Array([v0[0], v0[1], v0[2]])
			for _i in n:
				var os = ORB.make(_body, rp, rv)
				os.step(h, DV.v(0.0, 0.0, 0.0))
				var safe := NAV.clamp_bci_state(os.pos, os.vel, rp, rv, _soi)
				rp = safe[0]; rv = safe[1]
			var out := NAV.coast_batch_bci(_body, p0, v0, h, n, _soi)
			var dp := DV.length(DV.sub(out[0], rp))
			var dvv := DV.length(DV.sub(out[1], rv))
			_ok(dp < 1.0e-9 and dvv < 1.0e-9,
				"(a) %s n=%d: batch == per-substep (Δp=%s, Δv=%s blocks)" % [c["name"], n, dp, dvv])

# ---------- (b) coast_batch_bci allocates ONE OrbitalState for the whole batch (vs N) ----------
func _gate_one_alloc() -> void:
	print("  --- (b) ONE ALLOC: coast_batch_bci does 1 OrbitalState.make for N substeps (per-substep does N) ---")
	var R := GRAV.r_vox(_body)
	var p0 := DV.v(R + 701.0, 0.0, 0.0)
	var v0 := DV.v(-60.0, 0.0, 0.0)
	var n := 30
	var h := NAV.MAX_NAV_DT
	ORB.make_calls = 0
	var _out := NAV.coast_batch_bci(_body, p0, v0, h, n, _soi)
	var batch_makes := ORB.make_calls
	_ok(batch_makes == 1, "(b) batched N=%d ⇒ ONE OrbitalState.make (got %d — no per-substep allocation)" % [n, batch_makes])
	# The per-substep reference: N makes for the SAME batch.
	ORB.make_calls = 0
	var rp := PackedFloat64Array([p0[0], p0[1], p0[2]])
	var rv := PackedFloat64Array([v0[0], v0[1], v0[2]])
	for _i in n:
		var os = ORB.make(_body, rp, rv)
		os.step(h, DV.v(0.0, 0.0, 0.0))
		var safe := NAV.clamp_bci_state(os.pos, os.vel, rp, rv, _soi)
		rp = safe[0]; rv = safe[1]
	var ref_makes := ORB.make_calls
	_ok(ref_makes == n, "(b) per-substep N=%d ⇒ %d makes (the allocation convoy the batch removes)" % [n, ref_makes])
	_ok(batch_makes * n == ref_makes, "(b) batch does N× FEWER allocations (1 vs %d)" % ref_makes)

# ---------- helpers: ONE free-fall substep (mirrors player _coast_step) + a whole batched frame ----------
## ONE per-substep free-fall tick: reconstruct p_bci from the f32 lattice `position`, step, re-project. Returns
## [new_position (Vector3, f32-truncated), new_v_bci]. Byte-for-byte the structure of player.gd _coast_step.
func _ref_fall_substep(pos: Vector3, v_bci: PackedFloat64Array, h: float) -> Array:
	var w := _lattice_to_world(_fid, pos.x, pos.y, pos.z)
	var p_bci: PackedFloat64Array = ORB.fixed_to_bci(_body, _t, DV.v(w[0], w[1], w[2]), DV.v(0.0, 0.0, 0.0))[0]
	var os = ORB.make(_body, p_bci, v_bci)
	os.step(h, DV.v(0.0, 0.0, 0.0))
	var safe := NAV.clamp_bci_state(os.pos, os.vel, p_bci, v_bci, _soi)
	var pf_new: PackedFloat64Array = ORB.bci_to_fixed(_body, _t, safe[0], safe[1])[0]
	var lat := _world_to_lattice(_fid, pf_new[0], pf_new[1], pf_new[2])
	return [Vector3(lat[0], lat[1], lat[2]), safe[1]]

## The batched free-fall frame (mirrors player _coast_batch): ONE lattice→BCI, N BCI steps, ONE BCI→lattice.
func _batched_fall_frame(pos: Vector3, v_bci: PackedFloat64Array, h: float, n: int) -> Array:
	var w := _lattice_to_world(_fid, pos.x, pos.y, pos.z)
	var p_bci: PackedFloat64Array = ORB.fixed_to_bci(_body, _t, DV.v(w[0], w[1], w[2]), DV.v(0.0, 0.0, 0.0))[0]
	var out := NAV.coast_batch_bci(_body, p_bci, v_bci, h, n, _soi)
	var pf_new: PackedFloat64Array = ORB.bci_to_fixed(_body, _t, out[0], out[1])[0]
	var lat := _world_to_lattice(_fid, pf_new[0], pf_new[1], pf_new[2])
	return [Vector3(lat[0], lat[1], lat[2]), out[1]]

## A consistent starting lattice `position` for a chosen BCI point (inverse of the coast round-trip).
func _lattice_pos_for_bci(p_bci: PackedFloat64Array) -> Vector3:
	var p_fix: PackedFloat64Array = ORB.bci_to_fixed(_body, _t, p_bci, DV.v(0.0, 0.0, 0.0))[0]
	var lat := FacetAtlas.world_to_lattice64(_fid, p_fix[0], p_fix[1], p_fix[2])
	return Vector3(lat[0], lat[1], lat[2])

# ---------- (c) the full free-fall chain: batched matches per-substep over many VARIED-dt frames ----------
func _gate_fall_equiv() -> void:
	print("  --- (c) FALL-EQUIV: batched free-fall == per-substep over many varied-dt frames (within f32 tol) ---")
	var R := GRAV.r_vox(_body)
	var p_bci0 := DV.v(R + 701.0, 0.0, 0.0)
	var pos0 := _lattice_pos_for_bci(p_bci0)
	var v_seed := DV.v(-40.0, 8.0, 0.0)                      # a downward-ish fall with a little tangential drift
	# Frame dts: a realistic hitchy fall — normal 60-fps frames mixed with 5-fps / 10-fps hitches (varied N).
	var frame_dts := [1.0 / 60.0, 1.0 / 60.0, 0.2, 0.166, 0.1, 1.0 / 60.0, 0.05, 0.2, 1.0 / 30.0, 0.14, 1.0 / 60.0, 0.2]
	# reference: per-substep chain (N _coast_step calls per frame, f32 position each substep)
	var r_pos := pos0
	var r_v := PackedFloat64Array([v_seed[0], v_seed[1], v_seed[2]])
	# batched: ONE re-projection per frame
	var b_pos := pos0
	var b_v := PackedFloat64Array([v_seed[0], v_seed[1], v_seed[2]])
	var max_frame_dp := 0.0
	for fdt in frame_dts:
		var n := NAV.coast_substep_count(fdt)
		var h := NAV.coast_substep_dt(fdt)
		for _i in n:
			var rs := _ref_fall_substep(r_pos, r_v, h)
			r_pos = rs[0]; r_v = rs[1]
		var bs := _batched_fall_frame(b_pos, b_v, h, n)
		b_pos = bs[0]; b_v = bs[1]
		max_frame_dp = maxf(max_frame_dp, (b_pos - r_pos).length())
	var dp := (b_pos - r_pos).length()
	var dvv := DV.length(DV.sub(b_v, r_v))
	print("    measured: end Δposition=%s blocks, end Δvelocity=%s b/s, max per-frame Δpos=%s" % [dp, dvv, max_frame_dp])
	# Tight tolerance: the ONLY divergence is the per-substep f32 `position` truncation the batch removes (the batch is
	# strictly more accurate). Over this whole varied-dt fall it stays far below a block / a b/s.
	_ok(dp < 1.0e-1, "(c) end position matches within 0.1 block (Δ=%s) over %d varied-dt frames" % [dp, frame_dts.size()])
	_ok(dvv < 1.0e-1, "(c) end velocity matches within 0.1 b/s (Δ=%s)" % dvv)
	# Sanity: the fall actually MOVED (this is a live trajectory, not a no-op comparison).
	var travelled := (b_pos - pos0).length()
	_ok(travelled > 10.0, "(c) the fall actually integrated a real trajectory (moved %.1f blocks)" % travelled)

# ---------- (d) ONE lattice re-projection per frame regardless of N (the perf invariant) ----------
func _gate_one_reproj() -> void:
	print("  --- (d) ONE REPROJ: batched frame does 1 lattice_to_world64 + 1 world_to_lattice64 regardless of N ---")
	var R := GRAV.r_vox(_body)
	var pos0 := _lattice_pos_for_bci(DV.v(R + 701.0, 0.0, 0.0))
	var v0 := DV.v(-40.0, 0.0, 0.0)
	for fdt in [1.0 / 60.0, 0.2, 0.5]:
		var n := NAV.coast_substep_count(fdt)
		var h := NAV.coast_substep_dt(fdt)
		# batched free-fall frame: exactly ONE of each conversion + ONE make.
		_l2w = 0; _w2l = 0; ORB.make_calls = 0
		var _b := _batched_fall_frame(pos0, PackedFloat64Array([v0[0], v0[1], v0[2]]), h, n)
		var b_l2w := _l2w; var b_w2l := _w2l; var b_mk := ORB.make_calls
		# per-substep reference frame: N of each conversion + N makes.
		_l2w = 0; _w2l = 0; ORB.make_calls = 0
		var rp := pos0; var rv := PackedFloat64Array([v0[0], v0[1], v0[2]])
		for _i in n:
			var rs := _ref_fall_substep(rp, rv, h)
			rp = rs[0]; rv = rs[1]
		var r_l2w := _l2w; var r_w2l := _w2l; var r_mk := ORB.make_calls
		print("    dt=%.4f N=%d: batched(l2w=%d w2l=%d make=%d) vs per-substep(l2w=%d w2l=%d make=%d)" % [fdt, n, b_l2w, b_w2l, b_mk, r_l2w, r_w2l, r_mk])
		_ok(b_l2w == 1 and b_w2l == 1, "(d) N=%d: batched free-fall frame = 1 l2w + 1 w2l (O(1) re-projection)" % n)
		_ok(b_mk == 1, "(d) N=%d: batched free-fall frame = 1 OrbitalState.make (O(1) allocation)" % n)
		_ok(r_l2w == n and r_w2l == n, "(d) N=%d: per-substep frame = %d l2w + %d w2l (the O(N) cost removed)" % [n, n, n])
		_ok(r_mk == n, "(d) N=%d: per-substep frame = %d makes (the O(N) allocation removed)" % [n, n])
	# The batched ORBIT frame (carries [p,v]) reconstructs nothing ⇒ ZERO lattice_to_world64, ONE world_to_lattice64.
	var p_bci := DV.v(5.0 * R, 0.0, 0.0)
	var v_bci := DV.v(0.0, sqrt(GRAV.gm_dyn(_body) / (5.0 * R)), 0.0)
	var n2 := NAV.coast_substep_count(0.2)
	var h2 := NAV.coast_substep_dt(0.2)
	_l2w = 0; _w2l = 0; ORB.make_calls = 0
	var _o := _batched_orbit_frame(p_bci, v_bci, h2, n2)
	print("    orbit N=%d: batched(l2w=%d w2l=%d make=%d)" % [n2, _l2w, _w2l, ORB.make_calls])
	_ok(_l2w == 0 and _w2l == 1, "(d) batched orbit frame = 0 l2w (carries [p,v]) + 1 w2l (display only)")
	_ok(ORB.make_calls == 1, "(d) batched orbit frame = 1 OrbitalState.make regardless of N=%d" % n2)

# ---------- (e) the batched orbit coast is BIT-identical to the per-substep kepler chain over many frames ----------
## ONE per-substep kepler tick (mirrors player _coast_step_kepler): carries [p,v], projects display `position` (thrown
## away). Returns [p_bci', v_bci'] — the carried state, the ONLY per-tick output read back.
func _ref_kepler_substep(p_bci: PackedFloat64Array, v_bci: PackedFloat64Array, h: float) -> Array:
	var os = ORB.make(_body, p_bci, v_bci)
	os.step(h, DV.v(0.0, 0.0, 0.0))
	var safe := NAV.clamp_bci_state(os.pos, os.vel, p_bci, v_bci, _soi)
	var pf_new: PackedFloat64Array = ORB.bci_to_fixed(_body, _t, safe[0], safe[1])[0]
	var _lat := _world_to_lattice(_fid, pf_new[0], pf_new[1], pf_new[2])   # display only, discarded
	return [safe[0], safe[1]]

## The batched orbit frame (mirrors player _coast_batch_kepler): N BCI steps, ONE display projection.
func _batched_orbit_frame(p_bci: PackedFloat64Array, v_bci: PackedFloat64Array, h: float, n: int) -> Array:
	var out := NAV.coast_batch_bci(_body, p_bci, v_bci, h, n, _soi)
	var pf_new: PackedFloat64Array = ORB.bci_to_fixed(_body, _t, out[0], out[1])[0]
	var _lat := _world_to_lattice(_fid, pf_new[0], pf_new[1], pf_new[2])   # display only, discarded
	return out

func _gate_orbit_exact() -> void:
	print("  --- (e) ORBIT-EXACT: batched orbit coast == per-substep kepler chain, bit-identical over frames ---")
	var R := GRAV.r_vox(_body)
	var p0 := DV.v(5.0 * R, 0.0, 0.0)
	var v0 := DV.v(0.0, 0.9 * sqrt(GRAV.gm_dyn(_body) / (5.0 * R)), 0.0)   # a mild ellipse
	var frame_dts := [1.0 / 60.0, 0.2, 0.1, 1.0 / 30.0, 0.2, 0.05, 0.14]
	var r_p := PackedFloat64Array([p0[0], p0[1], p0[2]]); var r_v := PackedFloat64Array([v0[0], v0[1], v0[2]])
	var b_p := PackedFloat64Array([p0[0], p0[1], p0[2]]); var b_v := PackedFloat64Array([v0[0], v0[1], v0[2]])
	for fdt in frame_dts:
		var n := NAV.coast_substep_count(fdt)
		var h := NAV.coast_substep_dt(fdt)
		for _i in n:
			var rs := _ref_kepler_substep(r_p, r_v, h)
			r_p = rs[0]; r_v = rs[1]
		var bs := _batched_orbit_frame(b_p, b_v, h, n)
		b_p = bs[0]; b_v = bs[1]
	var dp := DV.length(DV.sub(b_p, r_p))
	var dvv := DV.length(DV.sub(b_v, r_v))
	print("    measured: end Δp=%s blocks, end Δv=%s b/s" % [dp, dvv])
	_ok(dp < 1.0e-9 and dvv < 1.0e-9, "(e) batched orbit == per-substep kepler, bit-identical (Δp=%s, Δv=%s)" % [dp, dvv])
	var travelled := DV.length(DV.sub(b_p, p0))
	_ok(travelled > 50.0, "(e) the orbit actually integrated (moved %.0f blocks)" % travelled)
