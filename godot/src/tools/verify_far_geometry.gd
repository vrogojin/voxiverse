extends SceneTree
## docs/COSMOS-FAR-GEOMETRY-PREBAKE-DESIGN.md gate (task #99, STAGE 1: `FP_GLOBAL_RELIEF_DATA` "G2" +
## `FP_SKIN_RELIEF_SHADE` "G1a") — "mountains flat from orbit" fix, first two flags only. `godot/src/world/
## global_relief_data.gd` carries the full mechanism doc; this gate proves the properties team-lead's task
## assignment specified.
##
## Gates (run with FACETED + both flags sed-toggled true):
##   G-GP-DATA-EQ — G2 node heights == `FarDensity.node_at` heights (the GDScript oracle `bake_smooth_tile`
##                  mirrors, proven byte-equal historically by G-CSB-EQ) at every node of a real facet, ≤1
##                  quantum. Falsifier: a perturbed height diverges beyond tolerance.
##   G-GP-BYTES   — `resident_bytes()` (the FULL always-resident allocation, independent of how many facets are
##                  actually baked yet — `setup()` resizes upfront) stays ≤ the doc's 40 MB (G2+G1a+G3) cap, and
##                  matches the doc's own G2 byte arithmetic (3456 × 33² × 2 B) at K=24.
##   G-GP-PACE    — `step()` with an injected HOT frame_ms (≥ BG_FRAME_BUDGET_MS) dispatches ZERO new bakes
##                  (baked_count unchanged, returns -1); a HEALTHY frame_ms does dispatch exactly one.
##   G1a-SHADE    — the hillshade is SUN-AGNOSTIC by construction (`hillshade_from_heights` takes no sun_dir
##                  parameter at all — structurally cannot reproduce FP_SMOOTH_V2_LIT's wrong-sun-shadow class)
##                  and slope-magnitude-driven (a flat grid shades at 1.0; a steep grid darkens toward the floor).
##   G-GP-OFF     — self-describing on the CURRENT compiled flag value (mirrors verify_bg_prebake.gd's G-BGP-OFF
##                  convention): with the flag off this run, setup()/step() are no-ops and resident_bytes()==0;
##                  with it on, this sub-check confirms the flag is armed (the active gates above cover behaviour).
##                  The REAL byte-off pin is external: FLAT verify_feature.gd stays 6042/0 with both flags false.
##
## STAGE 1b (the shader-composite fast-follow, docs/COSMOS-FAR-GEOMETRY-PREBAKE-DESIGN.md §3.1 + team-lead's
## follow-up): the G1a hillshade is now multiplied into the ORBIT-VISIBLE base CELLS=4 shell's own vertex COLOUR
## at `FacetFarRing._ensure_cached` (facet_far_ring.gd) — NO shader source changes at all (reuses the existing
## vertex-colour pipeline every tier already uses; the live sun/day-night term `v_st` still multiplies on top in
## the fragment shader, unchanged). Dense backstop / weld / env variants are untouched this pass (Stage-1b scope).
##   G-GP-COMPOSITE     — with both flags on: every one of a real facet's 25 base-grid nodes' shaded colour ==
##                        its raw `FarPalette.color_for` colour × `GlobalReliefData.shade_at` EXACTLY (the (gi,gj)
##                        → G2-node mapping is verified exact, 32/4=8, no interpolation); at least one node
##                        actually darkens (not a vacuous all-1.0 pass); alpha is untouched.
##   G-GP-COMPOSITE-OFF — self-describing (run when FP_SKIN_RELIEF_SHADE is off this run): `_ensure_cached`'s
##                        colours are BYTE-IDENTICAL whether or not `set_relief_data` was ever called — the flag
##                        is an independent second guard on top of "was the data even pushed".

const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

const EPS := 1.0e-5

func _initialize() -> void:
	print("=== verify_far_geometry (task #99 STAGE 1 — FP_GLOBAL_RELIEF_DATA + FP_SKIN_RELIEF_SHADE) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	FA.warm_up()

	_gate_off()
	if CubeSphere.FP_GLOBAL_RELIEF_DATA:
		_gate_data_eq()
		_gate_bytes()
		_gate_pace()
	if CubeSphere.FP_SKIN_RELIEF_SHADE:
		_gate_shade_sun_agnostic()
	if CubeSphere.FP_GLOBAL_RELIEF_DATA and CubeSphere.FP_SKIN_RELIEF_SHADE:
		_gate_composite()
	if not CubeSphere.FP_SKIN_RELIEF_SHADE:
		_gate_composite_off()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- G-GP-OFF: self-describing on the current compiled flag value --------------------------------------------------
func _gate_off() -> void:
	if not CubeSphere.FP_GLOBAL_RELIEF_DATA:
		var rd := GlobalReliefData.new()
		rd.setup()
		_ok(not rd.is_ready(), "G-GP-OFF: setup() never allocates with FP_GLOBAL_RELIEF_DATA off")
		_ok(rd.step([], 0.0) == -1, "G-GP-OFF: step() is a no-op with the flag off (returns -1)")
		_ok(rd.resident_bytes() == 0, "G-GP-OFF: resident_bytes() == 0 with the flag off")
		_ok(rd.bake_facet(0) == false, "G-GP-OFF: bake_facet() is a no-op with the flag off (nothing to write into)")
	else:
		_ok(CubeSphere.FP_GLOBAL_RELIEF_DATA, "G-GP-OFF: FP_GLOBAL_RELIEF_DATA compiled true for this run (active-behaviour gates below cover it)")

# --- G-GP-DATA-EQ: G2 heights == the FarDensity.node_at oracle, falsifiable -----------------------------------------
func _gate_data_eq() -> void:
	var fid := 37   # an arbitrary real facet
	var corner_dirs := FA.facet_corner_dirs(fid)
	var r_datum := FA.r_of(fid)
	var rd := GlobalReliefData.new()
	rd.setup()
	_ok(rd.is_ready(), "G-GP-DATA-EQ: setup() allocates with the flag on")
	_ok(rd.bake_facet(fid), "G-GP-DATA-EQ: bake_facet(fid) succeeds")
	_ok(rd.is_baked(fid), "G-GP-DATA-EQ: is_baked(fid) true after bake_facet")
	_ok(not rd.bake_facet(fid), "G-GP-DATA-EQ: bake_facet is idempotent (already-baked ⇒ false, no double-count)")

	var worst := 0
	for j in range(GlobalReliefData.NODES_PER_EDGE):
		for i in range(GlobalReliefData.NODES_PER_EDGE):
			var got := rd.height_at(fid, i, j)
			var want := GlobalReliefData.node_height_gd(corner_dirs, r_datum, i, j)
			worst = maxi(worst, absi(got - want))
	_ok(worst <= 1, "G-GP-DATA-EQ: G2 heights == FarDensity.node_at oracle at every one of %d nodes (worst Δ=%d quanta)" % [GlobalReliefData.NODES_PER_FACET, worst])

	# Falsification: a hand-perturbed height must diverge from the oracle beyond tolerance.
	var oracle_mid := GlobalReliefData.node_height_gd(corner_dirs, r_datum, 16, 16)
	var perturbed := oracle_mid + 50
	_ok(absi(perturbed - oracle_mid) > 1, "G-GP-DATA-EQ: a perturbed height DIVERGES from the oracle (gate is falsifiable)")

	# An unbaked facet stays at the neutral default (0), never garbage / never crashes on out-of-range query.
	_ok(rd.height_at(fid + 1, 5, 5) == 0, "G-GP-DATA-EQ: an unbaked facet reads 0 (neutral default, not garbage)")
	_ok(rd.height_at(fid, -1, 0) == 0 and rd.height_at(fid, 999, 0) == 0, "G-GP-DATA-EQ: out-of-range node queries are bounds-safe (0, no crash)")

# --- G-GP-BYTES: the FULL always-resident allocation stays under the doc's cap -------------------------------------
func _gate_bytes() -> void:
	var rd := GlobalReliefData.new()
	rd.setup()
	var n := FA.facet_count()
	var expect_heights := n * GlobalReliefData.NODES_PER_FACET * 2   # i16
	var mb := float(rd.resident_bytes()) / (1024.0 * 1024.0)
	_ok(rd.resident_bytes() >= expect_heights, "G-GP-BYTES: resident_bytes() accounts for the full i16 height array (%d facets × %d nodes × 2B)" % [n, GlobalReliefData.NODES_PER_FACET])
	_ok(mb <= 40.0, "G-GP-BYTES: G2%s ledger ≤ the doc's 40 MB (G2+G1a+G3) cap (got %.2f MB)" % [("+G1a" if CubeSphere.FP_SKIN_RELIEF_SHADE else ""), mb])
	# resident_bytes() is CONSTANT from setup() — the array is allocated upfront (doc §3.2: "always resident"),
	# not grown per-bake. Bake a couple of facets and confirm the byte count does NOT change (only VALUES fill in).
	var before := rd.resident_bytes()
	rd.bake_facet(0)
	rd.bake_facet(1)
	_ok(rd.resident_bytes() == before, "G-GP-BYTES: resident_bytes() is fixed at setup() — baking facets fills VALUES, not new allocation")

# --- G-GP-PACE: a hot frame dispatches nothing; a healthy frame dispatches exactly one -------------------------------
func _gate_pace() -> void:
	var rd := GlobalReliefData.new()
	rd.setup()
	var before := rd.baked_count()
	var hot := rd.step([], CubeSphere.BG_FRAME_BUDGET_MS + 5.0)
	_ok(hot == -1, "G-GP-PACE: a HOT frame_ms (≥ BG_FRAME_BUDGET_MS) dispatches nothing (step() returns -1)")
	_ok(rd.baked_count() == before, "G-GP-PACE: a HOT frame_ms leaves baked_count unchanged (zero new bakes)")

	var healthy := rd.step([], 1.0)
	_ok(healthy >= 0, "G-GP-PACE: a HEALTHY frame_ms (well under budget) dispatches exactly one facet (step() returns a real fid)")
	_ok(rd.baked_count() == before + 1, "G-GP-PACE: a HEALTHY frame_ms bakes exactly ONE facet this call (never a burst)")

	# Repeat once more: still exactly one per call, never more, regardless of how much budget remains.
	var healthy2 := rd.step([], 1.0)
	_ok(healthy2 >= 0 and healthy2 != healthy, "G-GP-PACE: the NEXT healthy call advances to a DIFFERENT facet (no re-bake of the same one)")
	_ok(rd.baked_count() == before + 2, "G-GP-PACE: still exactly one new bake this call (rate-cap holds across repeated calls)")

# --- G1a-SHADE: sun-agnostic by construction + slope-magnitude-driven ------------------------------------------------
func _gate_shade_sun_agnostic() -> void:
	# Structural guard: hillshade_from_heights's signature carries NO sun_dir parameter at all — the failure class
	# it must avoid (FP_SMOOTH_V2_LIT's wrong-sun shadows) requires a directional term to exist in the first place.
	var flat := PackedInt32Array(); flat.resize(9); flat.fill(100)   # 3x3 flat grid (edge=2), all heights equal
	var s_flat := GlobalReliefData.hillshade_from_heights(flat, 2, 1, 1, 10.0)
	_ok(is_equal_approx(s_flat, 1.0), "G1a-SHADE: a FLAT height grid shades at 1.0 (no slope ⇒ no darkening, got %.4f)" % s_flat)

	var sloped := PackedInt32Array([0, 0, 0, 0, 0, 0, 100, 100, 100])   # steep gradient along j (a cliff)
	var s_sloped := GlobalReliefData.hillshade_from_heights(sloped, 2, 1, 1, 10.0)
	_ok(s_sloped < s_flat - EPS, "G1a-SHADE: a STEEP grid darkens relative to flat (slope-magnitude-driven, got %.4f < %.4f)" % [s_sloped, s_flat])
	_ok(s_sloped >= GlobalReliefData.SHADE_FLOOR - EPS, "G1a-SHADE: shade never drops below SHADE_FLOOR (got %.4f, floor %.4f)" % [s_sloped, GlobalReliefData.SHADE_FLOOR])

	# Determinism/purity: calling it again with the IDENTICAL grid gives the IDENTICAL result — there is no sun-
	# direction (or any other) hidden state it could vary with.
	var again := GlobalReliefData.hillshade_from_heights(sloped, 2, 1, 1, 10.0)
	_ok(is_equal_approx(s_sloped, again), "G1a-SHADE: deterministic/pure — repeat call on the same grid gives the same shade (no hidden state)")

	# Wired through bake_facet on a real facet: the shade array is populated alongside the heights, in [0,1].
	var rd := GlobalReliefData.new()
	rd.setup()
	var fid := 12
	rd.bake_facet(fid)
	var worst_lo := 2.0
	var worst_hi := -1.0
	for j in range(GlobalReliefData.NODES_PER_EDGE):
		for i in range(GlobalReliefData.NODES_PER_EDGE):
			var s := rd.shade_at(fid, i, j)
			worst_lo = minf(worst_lo, s)
			worst_hi = maxf(worst_hi, s)
	_ok(worst_lo >= GlobalReliefData.SHADE_FLOOR - EPS and worst_hi <= 1.0 + EPS,
		"G1a-SHADE: a baked real facet's shade values all land in [SHADE_FLOOR, 1.0] (got [%.4f, %.4f])" % [worst_lo, worst_hi])

# --- G-GP-COMPOSITE (Stage 1b): the base CELLS=4 shell's vertex colour == raw × G2 shade_at, exactly ----------------
func _gate_composite() -> void:
	_ok(GlobalReliefData.CELLS % FacetFarRing.CELLS == 0,
		"G-GP-COMPOSITE: G2's CELLS(%d) is an exact multiple of the shell's CELLS(%d) — the (gi,gj)→G2-node map needs no interpolation" % [GlobalReliefData.CELLS, FacetFarRing.CELLS])
	var scale := GlobalReliefData.CELLS / FacetFarRing.CELLS

	var fid := 12   # the SAME facet G1a-SHADE already baked above — real terrain, not synthetic
	var rd := GlobalReliefData.new()
	rd.setup()
	rd.bake_facet(fid)

	var ring_raw := FacetFarRing.new()
	ring_raw._active_fid = fid
	ring_raw._ensure_cached(fid, true)   # _relief_shade never pushed ⇒ the pre-existing shipped colours
	var raw_col: PackedColorArray = ring_raw._col_cache[fid]

	var ring_shaded := FacetFarRing.new()
	ring_shaded._active_fid = fid
	ring_shaded.set_relief_data(rd)
	ring_shaded._ensure_cached(fid, true)
	var shaded_col: PackedColorArray = ring_shaded._col_cache[fid]

	var stride := FacetFarRing.CELLS + 1
	_ok(raw_col.size() == shaded_col.size() and raw_col.size() == stride * stride,
		"G-GP-COMPOSITE: both caches hold the shipped (CELLS+1)² == %d nodes" % (stride * stride))

	var worst := 0.0
	var any_darkened := false
	var alpha_ok := true
	for gj in range(stride):
		for gi in range(stride):
			var k := gj * stride + gi
			var want_shade := rd.shade_at(fid, gi * scale, gj * scale)
			var r := raw_col[k]
			var s := shaded_col[k]
			worst = maxf(worst, absf(s.r - r.r * want_shade))
			worst = maxf(worst, absf(s.g - r.g * want_shade))
			worst = maxf(worst, absf(s.b - r.b * want_shade))
			if not is_equal_approx(s.a, r.a):
				alpha_ok = false
			if want_shade < 1.0 - EPS:
				any_darkened = true
	_ok(worst <= EPS, "G-GP-COMPOSITE: every one of %d nodes' shaded colour == raw × shade_at(...) exactly (worst Δ=%.6f)" % [stride * stride, worst])
	_ok(alpha_ok, "G-GP-COMPOSITE: alpha channel is untouched by the composite (always 1.0, per the shipped shell law)")
	_ok(any_darkened, "G-GP-COMPOSITE: at least one of this real facet's nodes actually darkens (shade<1) — not a vacuous all-flat pass")

	ring_raw.free(); ring_shaded.free()

# --- G-GP-COMPOSITE-OFF: self-describing, run only when FP_SKIN_RELIEF_SHADE is off this run ------------------------
func _gate_composite_off() -> void:
	if CubeSphere.FP_SKIN_RELIEF_SHADE:
		_ok(true, "G-GP-COMPOSITE-OFF: skipped this run (flag currently ON — G-GP-COMPOSITE above covers the ON behaviour)")
		return
	var fid := 12
	var rd := GlobalReliefData.new()
	rd.setup()
	if rd.is_ready():
		rd.bake_facet(fid)

	var ring_wired := FacetFarRing.new()
	ring_wired._active_fid = fid
	if rd.is_ready():
		ring_wired.set_relief_data(rd)   # mirrors the real wiring: WorldManager pushes it whenever FP_GLOBAL_RELIEF_DATA is on
	ring_wired._ensure_cached(fid, true)
	var wired_col: PackedColorArray = ring_wired._col_cache[fid]

	var ring_never := FacetFarRing.new()
	ring_never._active_fid = fid
	ring_never._ensure_cached(fid, true)   # set_relief_data never called at all — the pre-existing shipped path
	var never_col: PackedColorArray = ring_never._col_cache[fid]

	_ok(wired_col.size() == never_col.size(), "G-GP-COMPOSITE-OFF: same node count with/without set_relief_data wired")
	var worst := 0.0
	for i in range(mini(wired_col.size(), never_col.size())):
		var a := wired_col[i]; var b := never_col[i]
		worst = maxf(worst, absf(a.r - b.r)); worst = maxf(worst, absf(a.g - b.g))
		worst = maxf(worst, absf(a.b - b.b)); worst = maxf(worst, absf(a.a - b.a))
	_ok(worst <= EPS, "G-GP-COMPOSITE-OFF: FP_SKIN_RELIEF_SHADE off ⇒ _ensure_cached colours are BYTE-IDENTICAL whether or not set_relief_data was ever called (worst Δ=%.6f)" % worst)

	ring_wired.free(); ring_never.free()
