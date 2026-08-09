extends SceneTree
## docs/COSMOS-FAR-TERMINATOR-DESIGN.md gate (FP_FAR_TERMINATOR_WELD) — the far-render "border day-lit at night"
## fix. Root cause (code-verified, not a guess): the day/night terminator LAW is CORRECT and unified everywhere
## (every far material multiplies albedo by voxi_shade(n, sun_dir), centre-relative normal) — it is NOT missing,
## NOT wrong-normal, NOT a shading-law bug. The live symptom is a RUNTIME sun_dir STALENESS gap: three far
## materials seed their `sun_dir` uniform to a hardcoded (1,0,0) fake-noon default at the moment they are (re)built,
## with no re-assert from the live Sun reaching that exact instance until the NEXT per-frame push cycle:
##   - `FacetSmoothV2._make_material()` (facet_smooth_v2.gd) — rebuilt on facet crossings.
##   - `TierPlace.make_biased_material()` (tier_place.gd) as consumed by `FacetSkinTier._make_material()`
##     (facet_skin_tier.gd) — built ONCE at skin-tier setup, had NO refresh path at all before this fix.
## Fix: each vulnerable class caches the last live `sun_dir` it was told (a static var, updated by its own
## `set_sun_dir`/`note_sun_dir`) and seeds NEW instances from that cache instead of the hardcoded default;
## `FacetSkinTier` gains a `set_sun_dir` wired into the SAME unconditional per-frame backstop fan-out the shipped
## block-LOD tiers already use (world_manager.gd `set_far_ring_shell_absolute`). Terminator axis ONLY — does not
## touch relief slope-shading (FP_SMOOTH_V2_LIT stays independent, never enabled here).
##
## Gates (all falsifiable — run with FP_FAR_TERMINATOR_WELD sed-toggled true; TierPlace assertions additionally
## need FP_SHADE_UNIFIED true, since that shader has no sun_dir uniform at all when unified is off):
##   G-FT-FRESH — build/rebuild a far material AFTER a live sun_dir push ⇒ its SEEDED sun_dir == the last-pushed
##                value, NOT the hardcoded (1,0,0) default. Covers FacetSmoothV2._make_material,
##                TierPlace.make_biased_material, and FacetSkinTier.set_sun_dir reaching its shared _mat.
##                Falsifier: FP_FAR_TERMINATOR_WELD OFF ⇒ every seed stays (1,0,0) regardless of any push.
##   G-FT-EQ    — this fix touches ONLY sun_dir freshness, never the shading law/geometry: the vulnerable far
##                materials' shader source still string-includes the ONE shared VoxiLight.shade_glsl() snippet
##                (unchanged), and VoxiLight.shade_tint stays a pure function of (n, sun_dir) with no hidden state.
##   G-FT-NIGHT — at a night sun, a REBUILT FacetSmoothV2 material's own seeded sun_dir shades a night-side point
##                at ≤ night_floor+ε (the border actually darkens). Falsifier: OFF ⇒ the rebuilt material still
##                reads that same point bright/day-lit through the stale (1,0,0) seed — the live bug, unfixed.
##   G-FT-OFF   — byte-off: FLAT verify_feature.gd stays 6042/0 (checked externally, not in this file).

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

const EPS := 1.0e-5

func _initialize() -> void:
	print("=== verify_far_terminator (FP_FAR_TERMINATOR_WELD — far-material sun_dir freshness) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	_gate_fresh_smoothv2()
	_gate_fresh_tierplace()
	_gate_fresh_skintier()
	_gate_eq()
	_gate_night()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- G-FT-FRESH: FacetSmoothV2 ------------------------------------------------------------------------------------
func _gate_fresh_smoothv2() -> void:
	var pushed := Vector3(0.3, 0.85, -0.2).normalized()
	var inst := FacetSmoothV2.new()
	inst.set_sun_dir(pushed)                              # live push BEFORE the rebuild (mirrors main.gd's per-frame push)
	var mat: ShaderMaterial = FacetSmoothV2._make_material()   # simulate a REBUILD (facet crossing → new instance)
	var seeded: Vector3 = mat.get_shader_parameter("sun_dir")
	# UNCONDITIONAL — this is THE falsifiable assertion (per task spec): with the flag ON it must hold; a run with
	# FP_FAR_TERMINATOR_WELD forced OFF (other prereqs on) must FAIL here (seeded stays the hardcoded (1,0,0)).
	_ok(seeded.distance_to(pushed) <= EPS,
		"G-FT-FRESH: FacetSmoothV2._make_material seeds sun_dir from the last live push (got %s, want %s)" % [str(seeded), str(pushed)])

# --- G-FT-FRESH: TierPlace (the shell's + FacetSkinTier's shared biased-material factory) --------------------------
func _gate_fresh_tierplace() -> void:
	if not CubeSphere.FP_SHADE_UNIFIED:
		print("  SKIP: G-FT-FRESH (TierPlace) needs FP_SHADE_UNIFIED on (the tier shader has no sun_dir uniform otherwise).")
		return
	var pushed := Vector3(-0.4, 0.6, 0.3).normalized()
	TierPlace.note_sun_dir(pushed)
	var mat := TierPlace.make_biased_material(0.0)
	var seeded: Vector3 = mat.get_shader_parameter("sun_dir")
	_ok(seeded.distance_to(pushed) <= EPS,
		"G-FT-FRESH: TierPlace.make_biased_material seeds sun_dir from the last live push (got %s, want %s)" % [str(seeded), str(pushed)])

# --- G-FT-FRESH: FacetSkinTier.set_sun_dir reaches its shared _mat (the gap with NO refresh path before this fix) --
func _gate_fresh_skintier() -> void:
	if not CubeSphere.FP_SHADE_UNIFIED:
		print("  SKIP: G-FT-FRESH (FacetSkinTier) needs FP_SHADE_UNIFIED on (same reason as TierPlace above).")
		return
	var skin := FacetSkinTier.new()
	skin._mat = TierPlace.make_biased_material(0.0)   # simulate the ONE build-time material (built once in setup())
	var pushed := Vector3(0.1, 0.2, -0.9).normalized()
	skin.set_sun_dir(pushed)
	var got: Vector3 = skin.sun_dir_telemetry()
	_ok(got.distance_to(pushed) <= EPS,
		"G-FT-FRESH: FacetSkinTier.set_sun_dir reaches its shared _mat (got %s, want %s)" % [str(got), str(pushed)])
	skin.free()

# --- G-FT-EQ: this fix touches sun_dir freshness ONLY — the shading law/geometry is untouched -----------------------
func _gate_eq() -> void:
	var snip := VoxiLight.shade_glsl()
	_ok(FacetSmoothV2.shader_code().contains(snip),
		"G-FT-EQ: FacetSmoothV2 shader still string-includes the shared VoxiLight law verbatim (unchanged by this fix)")
	if CubeSphere.FP_SHADE_UNIFIED:
		_ok(TierPlace.tier_shader_code(true).contains(snip),
			"G-FT-EQ: TierPlace unified tier shader still string-includes the shared VoxiLight law verbatim (unchanged)")
	# VoxiLight.shade_tint is a PURE function of (n, sun_dir) — the fix only changes WHICH sun_dir value reaches the
	# uniform, never the function computing shade from it. Falsifiable: a perturbed sun_dir must diverge the result.
	var n := Vector3(0.4, 0.6, -0.2).normalized()
	var sun_a := Vector3(0.5, 0.3, 0.1).normalized()
	var sun_b := Vector3(0.5, 0.3, 0.1).normalized()
	_ok((VoxiLight.shade_tint(n, sun_a) - VoxiLight.shade_tint(n, sun_b)).length() <= EPS,
		"G-FT-EQ: shade_tint(n, sun_dir) is deterministic/pure — identical inputs give identical shade")
	var sun_c := Vector3(-0.5, -0.3, -0.1).normalized()
	_ok((VoxiLight.shade_tint(n, sun_a) - VoxiLight.shade_tint(n, sun_c)).length() > EPS,
		"G-FT-EQ: shade_tint(n, sun_dir) DOES depend on sun_dir (a flipped sun diverges) — the gate is falsifiable")

# --- G-FT-NIGHT: the actual code path shades a night-side point at the night floor once the fix lands ---------------
func _gate_night() -> void:
	var n := Vector3(1.0, 0.02, 0.0).normalized()             # a far-tile point ALIGNED with the stale default sun
	var live_sun := Vector3(-1.0, 0.05, 0.0).normalized()     # the TRUE current sun — nearly OPPOSITE n ⇒ night here

	# Demonstrate the stakes: the shipped hardcoded default (fake noon, +X) reads this SAME point as bright day —
	# exactly the live "far border day-lit at night" symptom, reproduced numerically.
	var shade_default := VoxiLight.shade_tint(n, Vector3(1.0, 0.0, 0.0))
	_ok(shade_default.x > VoxiLight.NIGHT_FLOOR + 0.3,
		"G-FT-NIGHT: the hardcoded (1,0,0) default renders a night-side point bright/day-lit (got %.4f) — the live symptom" % shade_default.x)

	# FacetSmoothV2: push the live sun, force a REBUILD (facet crossing), read the rebuilt material's OWN seeded
	# sun_dir back, and shade this same point through it — the real fix path, not a synthetic VoxiLight call.
	var inst := FacetSmoothV2.new()
	inst.set_sun_dir(live_sun)
	var mat: ShaderMaterial = FacetSmoothV2._make_material()
	var seeded: Vector3 = mat.get_shader_parameter("sun_dir")
	var shade_v2 := VoxiLight.shade_tint(n, seeded)
	_ok(shade_v2.x <= VoxiLight.NIGHT_FLOOR + EPS,
		"G-FT-NIGHT: FacetSmoothV2's REBUILT material shades this night-side point at the night floor (got %.4f, floor %.4f)" % [shade_v2.x, VoxiLight.NIGHT_FLOOR])
