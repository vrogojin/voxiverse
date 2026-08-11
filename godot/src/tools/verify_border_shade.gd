extends SceneTree
## COSMOS BORDER-SHADE WELD gate (docs/COSMOS-BORDER-SHADE-WELD-DESIGN.md §4 — FP_BORDER_SHADE_WELD). Certifies the fix
## for the bright interfacet border strip: the FP-CARVE seam-junction carve-sentinel cubes (drawn ONLY along the facet
## ridge) carried the PRE-UNIFICATION BlockMaterials daylight twin (night_floor 0.10, NO scatter tint) while every
## neighbour cube adopted the FP_SHADE_UNIFIED VoxiLight law ⇒ the strip glared at dawn/night. The fix welds the three
## BlockMaterials daylight twins onto VoxiLight.shade_glsl() via a pure string transform at the ONE choke point
## block_materials.gd::near_daylight_code(), and seeds their floor/term_mu/moonshine from the VoxiLight constants.
##
## Like verify_shade_unified, the transform is exercised via the PARAM-ized builder near_daylight_code(src, cf, weld)
## so BOTH weld on/off are tested WITHOUT toggling any const — the string gates (OFF/LAW/DISC) run green at ANY flag
## default. The material/seed/carve/stale gates read the LIVE config (border_shade_weld_on()) and assert the state that
## config implies, so the gate passes with FP_BORDER_SHADE_WELD both false AND true; run it additionally with
## FP_NEAR_DAYLIGHT + FP_SHADE_UNIFIED + FP_BORDER_SHADE_WELD all true to light up the live-twin proofs.
##
## Gates (all falsifiable):
##   G-BSW-OFF   — weld=false ⇒ near_daylight_code() of all 3 twin consts byte-equals the shipped (centre-fixed) string;
##                 a fresh twin's seeds equal the live-config expectation (CosmosSky when weld off).
##   G-BSW-LAW   — weld=true ⇒ generated code contains voxi_shade( and _scatter_tint(, drops the OLD fragment law
##                 (float mu = dot(nrm, normalize(sun_dir))), keeps EXACTLY ONE shader_type and ONE `uniform vec3
##                 sun_dir` (no include duplicate), for all 3 twins.
##   G-BSW-DISC  — GDScript numeric: dawn μ=0 new green < old/3 (the ≥3× dawn excess gone); noon μ=1 |old−new|<1e-6 per
##                 channel (blend preserved); night μ=−0.5 new floor 0.06 vs old 0.10 (floor unified).
##   G-BSW-CARVE — the ACTUAL ridge material: BlockMaterials.get_for(STONE) (the exact call in module_world.gd
##                 _build_carve_manifest) — under the live near-daylight twin config its shader.code contains
##                 _scatter_tint IFF border_shade_weld_on(); + the manifest source routes through get_for.
##   G-BSW-STALE — the _daylight_twins registry feeds LATE-built twins: a twin built after a sun feed still receives the
##                 next feed's value; + the build-time sun_dir seed comes from TierPlace's live cache (not (1,0,0)) under
##                 weld; + the WorldManager single-site pushes the feed.

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

const EPS := 1.0e-5
const TWINS := ["opaque", "translucent_ds", "translucent_back"]

func _twin_src(which: String) -> String:
	match which:
		"opaque": return BlockMaterials._NEAR_DAYLIGHT_OPAQUE_SHADER
		"translucent_ds": return BlockMaterials._NEAR_DAYLIGHT_TRANSLUCENT_DS_SHADER
		_: return BlockMaterials._NEAR_DAYLIGHT_TRANSLUCENT_BACK_SHADER

func _initialize() -> void:
	print("=== verify_border_shade (BORDER-SHADE WELD — FP_BORDER_SHADE_WELD: weld the near-daylight twins onto VoxiLight) ===")
	print("  live config: border_shade_weld_on=%s FP_BORDER_SHADE_WELD=%s FP_NEAR_DAYLIGHT=%s FP_SHADE_UNIFIED=%s FP_NIGHT_TERRAIN_CENTRE=%s" % [
		str(CubeSphere.border_shade_weld_on()), str(CubeSphere.FP_BORDER_SHADE_WELD), str(CubeSphere.FP_NEAR_DAYLIGHT),
		str(CubeSphere.FP_SHADE_UNIFIED), str(CubeSphere.FP_NIGHT_TERRAIN_CENTRE)])

	_gate_off()
	_gate_law()
	_gate_disc()
	_gate_carve()
	_gate_stale()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- G-BSW-OFF: weld=false ⇒ byte-identical to the shipped (centre-fixed) string; seeds match the live config --------
func _gate_off() -> void:
	for which in TWINS:
		var src := _twin_src(which)
		# weld=false, centre_fix both ways ⇒ exactly the pre-weld behaviour (identity when centre_fix off; the
		# centre-fixed string when on) — the transform NEVER runs.
		_ok(BlockMaterials.near_daylight_code(src, false, false) == src,
			"G-BSW-OFF: %s weld=false, centre_fix=false ⇒ shipped string verbatim (byte-id)" % which)
		_ok(BlockMaterials.near_daylight_code(src, true, false) == BlockMaterials._centre_fix_code(src),
			"G-BSW-OFF: %s weld=false, centre_fix=true ⇒ the shipped centre-fixed string (byte-id)" % which)
		# The generated OFF string must NOT carry the unified markers.
		_ok(not BlockMaterials.near_daylight_code(src, true, false).contains("voxi_shade("),
			"G-BSW-OFF: %s weld=false has NO voxi_shade (the transform is gated)" % which)

	# A fresh twin's seeds reflect the LIVE config: weld off ⇒ the shipped CosmosSky values + (1,0,0) sun.
	BlockMaterials.reset_cache()
	var m := BlockMaterials._daylight_opaque(null, Color(1, 1, 1), true)
	if CubeSphere.border_shade_weld_on():
		_ok(is_equal_approx(float(m.get_shader_parameter("night_floor")), VoxiLight.NIGHT_FLOOR),
			"G-BSW-OFF/seed: weld ON ⇒ night_floor seeded to VoxiLight.NIGHT_FLOOR (%.3f)" % VoxiLight.NIGHT_FLOOR)
		_ok(is_equal_approx(float(m.get_shader_parameter("term_mu")), VoxiLight.TERM_MU),
			"G-BSW-OFF/seed: weld ON ⇒ term_mu seeded to VoxiLight.TERM_MU")
	else:
		_ok(is_equal_approx(float(m.get_shader_parameter("night_floor")), CosmosSky.NEAR_NIGHT_FLOOR),
			"G-BSW-OFF/seed: weld OFF ⇒ night_floor seeded to CosmosSky.NEAR_NIGHT_FLOOR (0.10, shipped)")
		_ok(is_equal_approx(float(m.get_shader_parameter("term_mu")), CosmosSky.TERMINATOR_MU),
			"G-BSW-OFF/seed: weld OFF ⇒ term_mu seeded to CosmosSky.TERMINATOR_MU (shipped)")
		_ok((m.get_shader_parameter("sun_dir") as Vector3) == Vector3(1.0, 0.0, 0.0),
			"G-BSW-OFF/seed: weld OFF ⇒ sun_dir seeded to the shipped (1,0,0) literal")
	BlockMaterials.reset_cache()

# --- G-BSW-LAW: weld=true ⇒ the unified law, one shader_type, one sun_dir, no old fragment law --------------------
func _gate_law() -> void:
	for which in TWINS:
		var src := _twin_src(which)
		var on := BlockMaterials.near_daylight_code(src, true, true)
		_ok(on.contains("voxi_shade("), "G-BSW-LAW: %s weld=true includes voxi_shade(" % which)
		_ok(on.contains("_scatter_tint("), "G-BSW-LAW: %s weld=true includes the scatter tint (_scatter_tint()" % which)
		_ok(on.contains("ALBEDO = base.rgb * voxi_shade(nrm, sun_dir);"),
			"G-BSW-LAW: %s routes the diffuse sink through voxi_shade(nrm, sun_dir)" % which)
		# The OLD fragment day/night law is gone (this is the distinctive per-fragment marker; shade_glsl re-uses the
		# `float shade = max(night_floor…` text INSIDE voxi_shade, so we key on the fragment's dot(nrm, …) instead).
		_ok(not on.contains("float mu = dot(nrm, normalize(sun_dir))"),
			"G-BSW-LAW: %s drops the OLD inline fragment law (float mu = dot(nrm, normalize(sun_dir)))" % which)
		# No duplicate declarations from the include.
		_ok(on.count("shader_type") == 1, "G-BSW-LAW: %s has EXACTLY ONE shader_type (zero new compiled programs)" % which)
		_ok(on.count("uniform vec3 sun_dir") == 1, "G-BSW-LAW: %s declares EXACTLY ONE `uniform vec3 sun_dir` (no include dup)" % which)
		_ok(on.count("float _day(float mu)") == 1, "G-BSW-LAW: %s has EXACTLY ONE _day helper (twin copy stripped)" % which)
		_ok(on.count("uniform float night_floor") == 1, "G-BSW-LAW: %s has EXACTLY ONE night_floor uniform (unified 0.06)" % which)
		# The unified snippet is string-INCLUDED verbatim.
		_ok(on.contains(VoxiLight.shade_glsl()), "G-BSW-LAW: %s string-includes VoxiLight.shade_glsl() verbatim" % which)
		# vs off it is genuinely different.
		_ok(on != BlockMaterials.near_daylight_code(src, true, false), "G-BSW-LAW: %s weld ON differs from weld OFF (the fix is real)" % which)
	# planet_centre (centre-fix normal) is PRESERVED through the weld.
	var op := BlockMaterials.near_daylight_code(BlockMaterials._NEAR_DAYLIGHT_OPAQUE_SHADER, true, true)
	_ok(op.contains("uniform vec3 planet_centre") and op.contains("normalize(v_wp - planet_centre)"),
		"G-BSW-LAW: the centre-fixed radial normal (planet_centre) survives the weld")

# --- G-BSW-DISC: the numeric shading divergence that IS the bug (dawn glare / night floor / noon blend) -------------
func _old_shade(mu: float) -> float:
	# The PRE-UNIFICATION near law (CosmosSky.near_shade), NO scatter tint ⇒ green channel == shade.
	return CosmosSky.near_shade(mu, 0.0)

func _new_green(mu: float) -> float:
	var n := Vector3(mu, sqrt(maxf(0.0, 1.0 - mu * mu)), 0.0)
	var sun := Vector3(1.0, 0.0, 0.0)
	return VoxiLight.shade_tint(n, sun, VoxiLight.NIGHT_FLOOR, VoxiLight.TERM_MU, VoxiLight.MOONSHINE).y

func _gate_disc() -> void:
	# Dawn μ=0: the untinted old green is the smoothstep midpoint (~0.55); the unified green collapses under the
	# scatter tint (air mass ~38, green ≈ exp(-3.7)) ⇒ the glaring ≥3× excess vanishes.
	var old0 := _old_shade(0.0)
	var new0 := _new_green(0.0)
	_ok(new0 < old0 / 3.0, "G-BSW-DISC: dawn μ=0 unified green %.4f < old/3 (%.4f) — the dawn glare is gone" % [new0, old0 / 3.0])
	# Noon μ=1: both saturate ⇒ the day look is byte-preserved (per channel).
	var old1 := _old_shade(1.0)
	var n1 := Vector3(1.0, 0.0, 0.0)
	var new1 := VoxiLight.shade_tint(n1, Vector3(1.0, 0.0, 0.0), VoxiLight.NIGHT_FLOOR, VoxiLight.TERM_MU, VoxiLight.MOONSHINE)
	_ok(absf(old1 - new1.x) < 1.0e-6 and absf(old1 - new1.y) < 1.0e-6 and absf(old1 - new1.z) < 1.0e-6,
		"G-BSW-DISC: noon μ=1 |old−new| < 1e-6 per channel (blend preserved: %.7f)" % maxf(absf(old1 - new1.x), maxf(absf(old1 - new1.y), absf(old1 - new1.z))))
	# Night μ=−0.5: the floor is unified 0.10 → 0.06.
	var oldn := _old_shade(-0.5)
	var newn := _new_green(-0.5)
	_ok(absf(oldn - 0.10) < 1.0e-4, "G-BSW-DISC: night μ=−0.5 old floor == 0.10 (%.4f)" % oldn)
	_ok(absf(newn - 0.06) < 1.0e-4, "G-BSW-DISC: night μ=−0.5 unified floor == 0.06 (%.4f)" % newn)
	_ok(newn < oldn, "G-BSW-DISC: night unified floor < old floor (the ~1.7× residue removed)")

# --- G-BSW-CARVE: the ACTUAL ridge material (module_world _build_carve_manifest → get_for) -------------------------
func _gate_carve() -> void:
	# The manifest source routes the ridge carve cube's material through BlockMaterials.get_for(mat).
	var mw := FileAccess.get_file_as_string("res://src/world/voxel_module/module_world.gd")
	_ok(mw.contains("_add_cube(library, BlockMaterials.get_for(mat)"),
		"G-BSW-CARVE: _build_carve_manifest routes the ridge cube through BlockMaterials.get_for(mat)")
	# Build the EXACT material the manifest assigns for a representative ridge material (STONE — always in the set).
	BlockMaterials.reset_cache()
	var mat := BlockMaterials.get_for(BlockCatalog.STONE)
	if CubeSphere.FP_NEAR_DAYLIGHT:
		# Live near-daylight config: the ridge material is the ShaderMaterial twin; its code carries the unified law
		# IFF the weld is on (this is the actual strip fix reaching the actual geometry).
		var is_shader := mat is ShaderMaterial
		_ok(is_shader, "G-BSW-CARVE: near-daylight ⇒ the ridge material is a ShaderMaterial twin")
		if is_shader:
			var code: String = (mat as ShaderMaterial).shader.code
			_ok(code.contains("_scatter_tint(") == CubeSphere.border_shade_weld_on(),
				"G-BSW-CARVE: the ridge material's shader.code contains _scatter_tint IFF border_shade_weld_on() (=%s)" % str(CubeSphere.border_shade_weld_on()))
	else:
		# Shipped non-daylight config (gate defaults): the ridge material is the plain StandardMaterial3D (no twin) —
		# there is no law split to weld, so the strip cannot arise. Structural confirmation only.
		_ok(mat is StandardMaterial3D and not (mat is ShaderMaterial),
			"G-BSW-CARVE: FP_NEAR_DAYLIGHT off ⇒ the ridge material is the shipped StandardMaterial3D (no twin, no split)")
	BlockMaterials.reset_cache()

# --- G-BSW-STALE: late-built twins are fed; the build-time seed is the live Sun, not (1,0,0) ------------------------
func _gate_stale() -> void:
	# The WorldManager single-site pushes the per-frame sun feed (unchanged by this fix — same uniform names).
	var wm := FileAccess.get_file_as_string("res://src/world/world_manager.gd")
	_ok(wm.contains("set_near_daylight_sun_dir"),
		"G-BSW-STALE: world_manager pushes set_near_daylight_sun_dir (the per-frame feed hub is intact)")

	# The registry feeds LATE-built twins: build one, feed, build ANOTHER, feed again ⇒ both carry the last value.
	# set_near_daylight_sun_dir is FP_NEAR_DAYLIGHT-gated; exercise the live feed only when that config is active.
	BlockMaterials.reset_cache()
	if CubeSphere.FP_NEAR_DAYLIGHT:
		var v1 := Vector3(0.3, 0.6, 0.2).normalized()
		var _m1 := BlockMaterials._daylight_opaque(null, Color(1, 1, 1), true)
		BlockMaterials.set_near_daylight_sun_dir(v1)
		var v2 := Vector3(-0.5, 0.4, 0.7).normalized()
		var m2 := BlockMaterials._daylight_opaque(null, Color(0.5, 0.5, 0.5), true)   # built AFTER the first feed
		BlockMaterials.set_near_daylight_sun_dir(v2)
		_ok((m2.get_shader_parameter("sun_dir") as Vector3).distance_to(v2) < EPS,
			"G-BSW-STALE: a twin built between feeds still receives the next feed (registry covers late twins)")
	else:
		# Registry mechanism proof without the live feed: the builder appends to _daylight_twins regardless of flags.
		var before := BlockMaterials._daylight_twins.size()
		var _mx := BlockMaterials._daylight_opaque(null, Color(1, 1, 1), true)
		_ok(BlockMaterials._daylight_twins.size() == before + 1,
			"G-BSW-STALE: a fresh twin registers in _daylight_twins (the per-frame feed target)")

	# Build-time sun_dir hardening: under the weld the seed comes from TierPlace's live cache, not (1,0,0).
	BlockMaterials.reset_cache()
	var probe := Vector3(0.1, -0.2, 0.97).normalized()
	var saved: Vector3 = TierPlace._last_sun_dir
	TierPlace._last_sun_dir = probe
	var m := BlockMaterials._daylight_opaque(null, Color(1, 1, 1), true)
	if CubeSphere.border_shade_weld_on():
		_ok((m.get_shader_parameter("sun_dir") as Vector3).distance_to(probe) < EPS,
			"G-BSW-STALE: weld ⇒ build-time sun_dir seeded from TierPlace._last_sun_dir (not the (1,0,0) fake-noon)")
	else:
		_ok((m.get_shader_parameter("sun_dir") as Vector3) == Vector3(1.0, 0.0, 0.0),
			"G-BSW-STALE: weld off ⇒ build-time sun_dir is the shipped (1,0,0) literal (byte-id seeding)")
	TierPlace._last_sun_dir = saved
	BlockMaterials.reset_cache()
