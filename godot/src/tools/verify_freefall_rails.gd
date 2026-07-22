extends SceneTree
## COSMOS-PERF FALL-COLLAPSE FIX gate — G-FREEFALL-RAILS (fix/voxiverse-freefall-rails, flag FP_FREEFALL_RAILS).
## PROVEN root cause (live telemetry): DEV-FLY (thrust) is 60 fps at every altitude; the gravity FREE-FALL coast
## rendering the IDENTICAL scene is ~5 fps with `phys_ms` = 91.7 ms ⇒ the collapse is PHYSICS. The free-fall
## integrates gravity with velocity-Verlet substeps — an OUTER coast-substep loop (≤ 30, FP_COAST_FULL_DT) around
## OrbitalState.step's INNER Verlet loop (≤ 8) — a dt-scaled per-frame loop that spirals as the frame slows.
## The fix makes the free-fall use the SAME O(1) machinery the (smooth) ORBIT coast could: carry the BCI [p,v] and
## advance it each frame by ONE CLOSED-FORM universal-variable two-body step (CosmosNav.coast_kepler_bci →
## OrbitalState.propagate_uv). This gate proves:
##   (a) UV-CORRECT   — propagate_uv conserves specific energy + angular momentum along a coast (two-body
##                      invariants) and forward+back round-trips to f64 ε, for RADIAL (h≈0, the singular case a
##                      classical Kepler-element form cannot do) AND sub-orbital (tangential) seeds.
##   (b) TRAJ-EQUIV   — the closed-form free-fall (ONE propagate/frame of the full dt) matches the shipped Verlet
##                      coast (coast_batch_bci, N substeps/frame) within a tight tolerance over a LONG fall, for
##                      radial AND sub-orbital seeds, across VARIED frame dt (1/60 and big hitches). Closed form
##                      is exact ⇒ the residual is the Verlet truncation error (closed form is strictly better).
##   (c) O(1)/FRAME   — the perf invariant. The closed-form frame does ZERO dt-scaled substeps: exactly ONE
##                      propagate_uv (ZERO OrbitalState.make — no Verlet allocation) whose Newton solve is a
##                      FIXED, dt-INDEPENDENT iteration count (uv_iters ≤ UV_ITER_MAX, ~constant across dt), vs
##                      the Verlet coast whose substep count scales 1 → 30 with dt. Plus ONE lattice re-projection
##                      per frame (ZERO lattice_to_world64 in steady state — carries [p,v] — + ONE world_to_lattice64).
##   (d) LANDS        — a radial fall from orbit descends monotonically in radius, stays sane (no escape/NaN), and
##                      crosses below the atmosphere ceiling (reaches the surface-walk regime) in bounded frames.
## Flag-off byte-identity (FP_FREEFALL_RAILS off ⇒ the shipped Verlet coast) is the FLAT verify_feature (6042/0),
## run separately. The gate MIRRORS the exact structure of player.gd _coast_freefall_rails vs _coast_batch so the
## counts/trajectories it proves are the player's.
##
## RUN:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_freefall_rails.gd 2>/dev/null | grep VERIFY
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
var _t := 1234.5                              # a fixed nav clock (constant across a frame, as in the player)
var _fid := 0
var _soi := 0.0
var _mu := 0.0
var _R := 0.0

func _initialize() -> void:
	print("=== verify_freefall_rails (COSMOS-PERF: G-FREEFALL-RAILS — closed-form free-fall coast) ===")
	print("  CubeSphere.FP_FREEFALL_RAILS = %s (the closed-form math is flag-independent pure static)" % str(CubeSphere.FP_FREEFALL_RAILS))
	FacetAtlas.warm_up()
	_soi = NAV.soi_radius(_body)
	_mu = GRAV.gm_dyn(_body)
	_R = GRAV.r_vox(_body)
	_gate_uv_correct()
	_gate_traj_equiv()
	_gate_o1_perf()
	_gate_lands()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- (a) propagate_uv is a correct two-body propagation (conserves invariants, round-trips) ----------
func _gate_uv_correct() -> void:
	print("  --- (a) UV-CORRECT: propagate_uv conserves energy+h, round-trips, incl. the RADIAL h≈0 case ---")
	var v_circ := sqrt(_mu / (_R + 8000.0))
	var cases := [
		{"name": "radial fall (h=0, singular for coe)", "p": DV.v(_R + 8000.0, 0.0, 0.0), "v": DV.v(-20.0, 0.0, 0.0)},
		{"name": "near-radial fall", "p": DV.v(_R + 8000.0, 0.0, 0.0), "v": DV.v(-40.0, 3.0, 0.0)},
		{"name": "sub-orbital ellipse", "p": DV.v(_R + 8000.0, 0.0, 0.0), "v": DV.v(-10.0, 0.7 * v_circ, 0.0)},
		{"name": "circular orbit", "p": DV.v(_R + 8000.0, 0.0, 0.0), "v": DV.v(0.0, v_circ, 0.0)},
	]
	for c in cases:
		var p0: PackedFloat64Array = c["p"]
		var v0: PackedFloat64Array = c["v"]
		var e0 := ORB.specific_energy(_mu, p0, v0)
		var h0 := DV.length(ORB.ang_momentum(p0, v0))
		# Propagate a chain of steps; energy + |h| must be conserved (two-body invariants) to f64 ε.
		var p := PackedFloat64Array([p0[0], p0[1], p0[2]])
		var v := PackedFloat64Array([v0[0], v0[1], v0[2]])
		var max_de := 0.0
		var max_dh := 0.0
		for _i in 40:
			var rv := ORB.propagate_uv(_mu, p, v, 0.25)
			p = rv[0]; v = rv[1]
			max_de = maxf(max_de, _rel(ORB.specific_energy(_mu, p, v), e0))
			max_dh = maxf(max_dh, absf(DV.length(ORB.ang_momentum(p, v)) - h0))
		_ok(max_de < 1.0e-9, "(a) %s: specific energy conserved (max rel Δ=%s)" % [c["name"], max_de])
		_ok(max_dh < 1.0e-4, "(a) %s: |angular momentum| conserved (max Δ=%s blocks²/s)" % [c["name"], max_dh])
		# Forward dt then back −dt returns to the seed (the propagation is a bijection in time).
		var fwd := ORB.propagate_uv(_mu, p0, v0, 3.0)
		var back := ORB.propagate_uv(_mu, fwd[0], fwd[1], -3.0)
		var dp := DV.length(DV.sub(back[0], p0))
		var dvv := DV.length(DV.sub(back[1], v0))
		_ok(dp < 1.0e-4 and dvv < 1.0e-6, "(a) %s: forward+back round-trip returns to seed (Δp=%s, Δv=%s)" % [c["name"], dp, dvv])
	# The radial fall stays EXACTLY radial (p ∥ v, h stays 0) — the universal form does not spuriously inject
	# tangential motion the classical element form would need a defined perifocal frame to avoid.
	var pr := DV.v(_R + 8000.0, 0.0, 0.0)
	var vr := DV.v(-20.0, 0.0, 0.0)
	for _i in 20:
		var rv := ORB.propagate_uv(_mu, pr, vr, 0.5)
		pr = rv[0]; vr = rv[1]
	_ok(DV.length(ORB.ang_momentum(pr, vr)) < 1.0e-6 and absf(pr[1]) < 1.0e-6 and absf(pr[2]) < 1.0e-6,
		"(a) radial fall stays rectilinear (h=%s, off-axis pos=%s)" % [DV.length(ORB.ang_momentum(pr, vr)), maxf(absf(pr[1]), absf(pr[2]))])

# ---------- player-frame mirrors: closed-form (rails) vs shipped Verlet (batch) ----------
## ONE rails free-fall frame (mirrors player _coast_freefall_rails, steady state): carries [p,v], ONE closed-form
## propagate over the full delta, ONE world_to_lattice64 (display). ZERO lattice_to_world64 (p carried). Returns
## [p_bci', v_bci', display_position].
func _rails_frame(p_bci: PackedFloat64Array, v_bci: PackedFloat64Array, delta: float) -> Array:
	var out := NAV.coast_kepler_bci(_body, p_bci, v_bci, delta, _soi)
	var pf_new: PackedFloat64Array = ORB.bci_to_fixed(_body, _t, out[0], out[1])[0]
	var lat := _world_to_lattice(_fid, pf_new[0], pf_new[1], pf_new[2])
	return [out[0], out[1], Vector3(lat[0], lat[1], lat[2])]

## ONE shipped Verlet free-fall frame (mirrors player _coast_batch: FP_COAST_FULL_DT substeps via coast_batch_bci,
## carried [p,v]). N = coast_substep_count(delta) Verlet substeps of coast_substep_dt(delta). Returns [p',v',pos].
func _verlet_frame(p_bci: PackedFloat64Array, v_bci: PackedFloat64Array, delta: float) -> Array:
	var n := NAV.coast_substep_count(delta)
	var h := NAV.coast_substep_dt(delta)
	var out := NAV.coast_batch_bci(_body, p_bci, v_bci, h, n, _soi)
	var pf_new: PackedFloat64Array = ORB.bci_to_fixed(_body, _t, out[0], out[1])[0]
	var lat := _world_to_lattice(_fid, pf_new[0], pf_new[1], pf_new[2])
	return [out[0], out[1], Vector3(lat[0], lat[1], lat[2])]

# ---------- (b) closed-form free-fall matches the shipped Verlet coast over a long, varied-dt fall ----------
func _gate_traj_equiv() -> void:
	print("  --- (b) TRAJ-EQUIV: closed-form fall == shipped Verlet coast over a long varied-dt fall (tight tol) ---")
	var v_circ := sqrt(_mu / (_R + 8000.0))
	# A realistic hitchy fall: normal 60-fps frames interleaved with 5-fps / 10-fps hitches (the spiral regime).
	var frame_dts := [1.0 / 60.0, 1.0 / 60.0, 0.2, 0.166, 0.1, 1.0 / 60.0, 0.05, 0.2, 1.0 / 30.0, 0.14, 1.0 / 60.0, 0.2]
	var seeds := [
		{"name": "radial fall (h=0)", "p": DV.v(_R + 8000.0, 0.0, 0.0), "v": DV.v(-25.0, 0.0, 0.0)},
		{"name": "sub-orbital ellipse", "p": DV.v(_R + 8000.0, 0.0, 0.0), "v": DV.v(-10.0, 0.6 * v_circ, 0.0)},
	]
	for sd in seeds:
		var p0: PackedFloat64Array = sd["p"]
		var v0: PackedFloat64Array = sd["v"]
		var r_p := PackedFloat64Array([p0[0], p0[1], p0[2]]); var r_v := PackedFloat64Array([v0[0], v0[1], v0[2]])
		var b_p := PackedFloat64Array([p0[0], p0[1], p0[2]]); var b_v := PackedFloat64Array([v0[0], v0[1], v0[2]])
		var max_dp := 0.0
		# 30 cycles of the 12-frame hitch pattern ≈ a long multi-hundred-second fall.
		for _cyc in 30:
			for fdt in frame_dts:
				var rr := _rails_frame(r_p, r_v, fdt)
				r_p = rr[0]; r_v = rr[1]
				var vv := _verlet_frame(b_p, b_v, fdt)
				b_p = vv[0]; b_v = vv[1]
				max_dp = maxf(max_dp, DV.length(DV.sub(r_p, b_p)))
		var dp := DV.length(DV.sub(r_p, b_p))
		var dvv := DV.length(DV.sub(r_v, b_v))
		var travelled := DV.length(DV.sub(r_p, p0))
		var rel := dp / maxf(travelled, 1.0)
		print("    %s: travelled=%.1f blocks, end Δpos=%.4f blocks (rel %.8f), end Δvel=%.5f b/s, max Δpos=%.4f" % [sd["name"], travelled, dp, rel, dvv, max_dp])
		# Tight: closed form is exact, so the residual is only the Verlet truncation over the whole fall. Well under
		# a block over a fall of many hundreds of blocks (rel < 1e-3). Both agree the fall happened (moved a lot).
		_ok(rel < 1.0e-3, "(b) %s: closed-form matches Verlet within rel 1e-3 (rel=%.8f)" % [sd["name"], rel])
		_ok(travelled > 100.0, "(b) %s: a real long fall was integrated (%.0f blocks)" % [sd["name"], travelled])

# ---------- (c) O(1) per frame: one propagate, bounded dt-independent iters, zero dt-scaled substeps ----------
func _gate_o1_perf() -> void:
	print("  --- (c) O(1)/FRAME: closed-form = 1 propagate (0 Verlet make), dt-INDEPENDENT iters, 1 re-projection ---")
	var v_circ := sqrt(_mu / (_R + 8000.0))
	var p0 := DV.v(_R + 8000.0, 0.0, 0.0)
	var v0 := DV.v(-25.0, 0.4 * v_circ, 0.0)
	# The perf invariant across a normal frame AND catastrophic hitches: the closed-form work does NOT scale with dt.
	var dts := [1.0 / 60.0, 0.2, 1.0, 4.0]
	var rails_iters: Array[int] = []
	for fdt in dts:
		# rails frame: ZERO OrbitalState.make (no Verlet), bounded uv_iters, ONE propagate, 0 l2w + 1 w2l.
		_l2w = 0; _w2l = 0; ORB.make_calls = 0; ORB.uv_iters = 0
		var _r := _rails_frame(p0, PackedFloat64Array([v0[0], v0[1], v0[2]]), fdt)
		var r_iters := ORB.uv_iters; var r_mk := ORB.make_calls; var r_l2w := _l2w; var r_w2l := _w2l
		rails_iters.append(r_iters)
		# the shipped Verlet coast substep count for the SAME dt (the dt-scaled loop the closed form replaces).
		var verlet_n := NAV.coast_substep_count(fdt)
		print("    dt=%.4f: rails(make=%d uv_iters=%d l2w=%d w2l=%d)  vs  Verlet substeps N=%d" % [fdt, r_mk, r_iters, r_l2w, r_w2l, verlet_n])
		_ok(r_mk == 0, "(c) dt=%.4f: closed-form frame does ZERO OrbitalState.make (no Verlet substeps/allocation)" % fdt)
		_ok(r_iters <= ORB.UV_ITER_MAX, "(c) dt=%.4f: Newton iters %d ≤ UV_ITER_MAX=%d (bounded)" % [fdt, r_iters, ORB.UV_ITER_MAX])
		_ok(r_l2w == 0 and r_w2l == 1, "(c) dt=%.4f: 0 lattice_to_world64 (carries [p,v]) + 1 world_to_lattice64 (display)" % fdt)
	# THE O(1) claim: the Newton iteration count is dt-INDEPENDENT (a small fixed band), NOT proportional to dt like
	# the Verlet substep count (which runs 1 → 30 → 30 as dt grows to the COAST_CATCHUP_MAX cap). Spread ≤ a few iters.
	var lo: int = rails_iters[0]; var hi: int = rails_iters[0]
	for it in rails_iters:
		lo = mini(lo, it); hi = maxi(hi, it)
	_ok(hi - lo <= 6 and hi <= 12, "(c) Newton iters dt-INDEPENDENT across dt∈[1/60..4s]: band [%d..%d] (≤6 spread, ≤12 total)" % [lo, hi])
	# Contrast the growth explicitly: the closed form is CONSTANT 1 propagate while the Verlet substep count scales.
	_ok(NAV.coast_substep_count(1.0 / 60.0) == 1 and NAV.coast_substep_count(1.0) == 30,
		"(c) the replaced Verlet loop IS dt-scaled (substeps 1 at 1/60 → 30 at 1s) — closed form is constant 1")

# ---------- (d) a radial fall from orbit descends monotonically, stays sane, and lands ----------
func _gate_lands() -> void:
	print("  --- (d) LANDS: radial fall from orbit descends monotone, stays sane, crosses below the atmo ceiling ---")
	# A high radial fall (the "worse the higher you fall from" live case). Start well above the atmosphere.
	var p := DV.v(_R + 40000.0, 0.0, 0.0)
	var v := DV.v(-5.0, 0.0, 0.0)                            # a gentle radial drop; gravity does the rest
	var r_prev := DV.length(p)
	var monotone := true
	var sane := true
	var landed := false
	var frames := 0
	var atmo_top := CubeSphere.ATMO_TOP
	# realistic hitchy dt so this exercises the same varied-dt path; bounded frame budget (anti-infinite-loop).
	var dts := [1.0 / 60.0, 0.2, 0.1, 1.0 / 30.0]
	for i in 20000:
		var fdt: float = dts[i % dts.size()]
		var out := NAV.coast_kepler_bci(_body, p, v, fdt, _soi)
		p = out[0]; v = out[1]
		frames += 1
		var r := DV.length(p)
		if r > r_prev + 1.0e-6:                              # allow f64 noise; a real climb breaks monotonicity
			monotone = false
		if not NAV.v_is_sane(v) or is_nan(r) or is_inf(r):
			sane = false
			break
		if r - _R <= atmo_top:
			landed = true
			break
		r_prev = r
	print("    frames=%d, final altitude=%.1f blocks (atmo ceiling %.0f), landed=%s, monotone=%s, sane=%s, final speed=%.2f b/s" % [frames, DV.length(p) - _R, atmo_top, str(landed), str(monotone), str(sane), DV.length(v)])
	_ok(sane, "(d) the fall stayed sane (finite, ≤ FD_SPEED_MAX) the whole descent")
	_ok(monotone, "(d) the radial fall descended monotonically (no spurious climb/escape)")
	_ok(landed, "(d) the fall reached the atmosphere ceiling (hands off to the surface-walk regime) in %d frames" % frames)
	_ok(DV.length(v) > 5.0, "(d) it arrived with a real downward speed (%.1f b/s) — gravity accelerated the fall" % DV.length(v))
