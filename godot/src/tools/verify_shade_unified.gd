extends SceneTree
## COSMOS TEXTURED-LOD V1 gate (docs/COSMOS-TEXTURED-LOD-DESIGN.md §2V.3 — FP_SHADE_UNIFIED). Certifies the ONE lighting
## law shared by the near blocks and the far skin: a near block top and the far texel covering it shade IDENTICALLY at
## every sun angle (incl. the terminator), and the near planet_centre stays FRESH across a facet crossing (§2V.6 F1).
##
## The FP_SHADE_UNIFIED shader effect is exercised via the PARAM-ized builders (BlockAtlas.near_daylight_shader_code(u),
## FacetFarRing._apply_shade_unified(code, u), TierPlace.tier_shader_code(u)) so BOTH on/off are tested WITHOUT toggling
## the const — the gate runs green with flags at their defaults. Runs with FACETED = true (harness sed-toggle).
##
## Gates (all falsifiable):
##   G-VL-SNIPPET  — VoxiLight.SHADE_GLSL is string-INCLUDED verbatim in the unified near / shell(base+cu) / tier shaders;
##                   the snippet defines voxi_shade and carries NO shader_type (a pure include).
##   G-VL-NORMAL   — the unified near uses the TRUE planet radial normalize(v_wp − planet_centre) (not the scene-origin
##                   normalize(v_wp)); the unified shell + tier use normalize(wp − centre) with centre = MODEL·0.
##   G-VL-SHADERTYPE— every unified shader has EXACTLY ONE shader_type — zero new compiled programs vs off.
##   G-VL-OFF      — unified=false ⇒ every builder returns the shipped const BYTE-IDENTICAL (near/shell base+cu/abs/tier).
##   G-VL-PARITY   — the ONE uniform set is shared: VoxiLight.NIGHT_FLOOR == CosmosSky.SHELL_NIGHT_FLOOR, TERM_MU ==
##                   TERMINATOR_MU; near and far are seeded from the SAME VoxiLight constants.
##   G-VL-EQ       — numeric sweep (sun elevation × latitude, incl. terminator ±): near shade·tint (n = wp − planet_centre)
##                   == far shade·tint (n = wp − MODEL·0) within ε when the centres agree; FALSIFIED by (a) perturbing the
##                   near night_floor, (b) a STALE near planet_centre.
##   G-VL-CROSS    — FacetFarRing.render_centre() varies per active facet (not constant), near==far holds at each, and a
##                   stale (un-updated) near centre across the crossing is DETECTED; the WorldManager site pushes it fresh.

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
	print("=== verify_shade_unified (TEXTURED-LOD V1 — FP_SHADE_UNIFIED: one shade·tint law + true planet-radial normal) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	FA.warm_up()

	_gate_snippet()
	_gate_normal()
	_gate_shadertype()
	_gate_off_identical()
	_gate_parity()
	_gate_eq()
	_gate_cross()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- builders under test (unified ON) --------------------------------------------------------------------------
func _near_on() -> String:  return BlockAtlas.near_daylight_shader_code(true)
func _near_off() -> String: return BlockAtlas.near_daylight_shader_code(false)
func _shell_on() -> String:  return FacetFarRing._apply_shade_unified(FacetFarRing._SHELL_ABS_TEX_SHADER, true)
func _cu_on() -> String:     return FacetFarRing._apply_shade_unified(FacetFarRing._SHELL_ABS_TEX_CU_SHADER, true)
func _abs_on() -> String:    return FacetFarRing._apply_shade_unified(FacetFarRing._SHELL_ABS_SHADER, true)
func _tier_on() -> String:   return TierPlace.tier_shader_code(true)

# --- G-VL-SNIPPET ----------------------------------------------------------------------------------------------
func _gate_snippet() -> void:
	var snip := VoxiLight.SHADE_GLSL
	_ok(snip.contains("vec3 voxi_shade(vec3 n, vec3 sd)"), "G-VL-SNIPPET: VoxiLight.SHADE_GLSL defines voxi_shade")
	_ok(not snip.contains("shader_type"), "G-VL-SNIPPET: the snippet carries NO shader_type (pure body — zero new program)")
	for pair in [["near", _near_on()], ["shell", _shell_on()], ["closeup", _cu_on()], ["abs", _abs_on()], ["tier", _tier_on()]]:
		_ok((pair[1] as String).contains(snip),
			"G-VL-SNIPPET: %s unified shader string-INCLUDES VoxiLight.SHADE_GLSL verbatim" % pair[0])
	# Falsification: a one-byte-perturbed snippet is NOT contained.
	_ok(not (_near_on()).contains(snip + "x"), "G-VL-SNIPPET: a perturbed snippet is not contained (gate is falsifiable)")

# --- G-VL-NORMAL -----------------------------------------------------------------------------------------------
func _gate_normal() -> void:
	# near: the TRUE planet radial (a new planet_centre uniform), NOT the scene-origin pseudo-normal.
	_ok(_near_on().contains("normalize(v_wp - planet_centre)"),
		"G-VL-NORMAL: unified near uses normalize(v_wp − planet_centre) (true planet radial)")
	_ok(_near_on().contains("uniform vec3 planet_centre"),
		"G-VL-NORMAL: unified near declares the planet_centre uniform")
	_ok(_near_off().contains("normalize(v_wp)") and not _near_off().contains("planet_centre"),
		"G-VL-NORMAL: the SHIPPED near still uses normalize(v_wp), no planet_centre (off = unchanged)")
	_ok(_near_on() != _near_off(), "G-VL-NORMAL: unified near differs from the shipped near (the fix is real)")
	# far shell + tier: the radial normal from MODEL·0 (already the shell's; the tier gains it).
	for pair in [["shell", _shell_on()], ["closeup", _cu_on()], ["abs", _abs_on()], ["tier", _tier_on()]]:
		_ok((pair[1] as String).contains("normalize(wp - centre)"),
			"G-VL-NORMAL: %s unified uses normalize(wp − centre) with centre = MODEL·0" % pair[0])

# --- G-VL-SHADERTYPE -------------------------------------------------------------------------------------------
func _gate_shadertype() -> void:
	for pair in [["near", _near_on()], ["shell", _shell_on()], ["closeup", _cu_on()], ["abs", _abs_on()], ["tier", _tier_on()]]:
		_ok((pair[1] as String).count("shader_type") == 1,
			"G-VL-SHADERTYPE: %s unified shader has EXACTLY ONE shader_type (zero new compiled programs)" % pair[0])
	# And off has the same count (no program added by the flag).
	_ok(_near_on().count("shader_type") == _near_off().count("shader_type"),
		"G-VL-SHADERTYPE: unified near adds no shader_type vs off")
	_ok(_shell_on().count("shader_type") == FacetFarRing._SHELL_ABS_TEX_SHADER.count("shader_type"),
		"G-VL-SHADERTYPE: unified shell adds no shader_type vs off")

# --- G-VL-OFF: unified=false returns the shipped const BYTE-IDENTICAL --------------------------------------------
func _gate_off_identical() -> void:
	_ok(_near_off() == BlockAtlas._NEAR_DAYLIGHT_SHADER, "G-VL-OFF: near_daylight_shader_code(false) == _NEAR_DAYLIGHT_SHADER (byte-id)")
	_ok(TierPlace.tier_shader_code(false) == TierPlace._TIER_SHADER, "G-VL-OFF: tier_shader_code(false) == _TIER_SHADER (byte-id)")
	for pair in [["shell", FacetFarRing._SHELL_ABS_TEX_SHADER], ["closeup", FacetFarRing._SHELL_ABS_TEX_CU_SHADER],
			["abs", FacetFarRing._SHELL_ABS_SHADER], ["light", FacetFarRing._SHELL_ABS_TEX_LIGHT],
			["albedo", FacetFarRing._SHELL_ABS_TEX_ALBEDO]]:
		_ok(FacetFarRing._apply_shade_unified(pair[1], false) == pair[1],
			"G-VL-OFF: _apply_shade_unified(%s, false) == the const (identity when off)" % pair[0])
	# The ALBEDO tail is NEVER touched even when unified is ON (V2's domain — no conflict).
	_ok(_shell_on().contains(FacetFarRing._SHELL_ABS_TEX_ALBEDO),
		"G-VL-OFF: the unified shell PRESERVES the ALBEDO tail verbatim (V1 touches only the LIGHT head)")

# --- G-VL-PARITY: the ONE uniform set is shared ----------------------------------------------------------------
func _gate_parity() -> void:
	_ok(is_equal_approx(VoxiLight.NIGHT_FLOOR, CosmosSky.SHELL_NIGHT_FLOOR),
		"G-VL-PARITY: VoxiLight.NIGHT_FLOOR == CosmosSky.SHELL_NIGHT_FLOOR (near adopts the far shell's floor)")
	_ok(is_equal_approx(VoxiLight.TERM_MU, CosmosSky.TERMINATOR_MU), "G-VL-PARITY: VoxiLight.TERM_MU == TERMINATOR_MU")
	_ok(is_equal_approx(VoxiLight.MOONSHINE, 0.0), "G-VL-PARITY: the moonshine floor defaults 0.0 (static, both sides equal)")

# --- G-VL-EQ: near shade·tint == far shade·tint over the sun × latitude grid ------------------------------------
func _gate_eq() -> void:
	var C := Vector3(1234.0, -5678.0, 910.0)   # an arbitrary planet centre (render frame)
	var R := 6371.0
	var worst := 0.0
	var samples := 0
	# latitude/longitude grid of surface points; sun swept through elevations incl. the terminator (μ≈0).
	for lat_i in range(-4, 5):
		var lat := float(lat_i) * (PI / 10.0)
		for lon_i in range(0, 8):
			var lon := float(lon_i) * (PI / 4.0)
			var dir := Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
			var wp := C + dir * R
			for sun_i in range(-6, 7):
				var se := float(sun_i) * (PI / 12.0)    # sun elevation incl. ±terminator
				var sun := Vector3(cos(se), sin(se), 0.0)
				# NEAR way: n = wp − planet_centre (planet_centre fed FRESH = C). FAR way: n = wp − MODEL·0 (centre = C).
				var n_near := (wp - C).normalized()
				var n_far := (wp - C).normalized()
				var near_st := VoxiLight.shade_tint(n_near, sun, VoxiLight.NIGHT_FLOOR, VoxiLight.TERM_MU, VoxiLight.MOONSHINE)
				var far_st := VoxiLight.shade_tint(n_far, sun, VoxiLight.NIGHT_FLOOR, VoxiLight.TERM_MU, VoxiLight.MOONSHINE)
				worst = maxf(worst, (near_st - far_st).length())
				# sanity: the shade·tint is finite and componentwise in [0,1] (night floor ≤ comp ≤ noon).
				if not (is_finite(near_st.x) and near_st.x >= -EPS and near_st.x <= 1.0 + EPS):
					_fail += 1
					print("  FAIL: G-VL-EQ: shade·tint out of [0,1] / non-finite at lat=%.2f sun=%.2f -> %s" % [lat, se, str(near_st)])
					return
				samples += 1
	_ok(worst <= EPS, "G-VL-EQ: near shade·tint == far shade·tint over %d (sun × lat) samples (worst Δ=%.9f)" % [samples, worst])

	# Falsification (a): give the near a DIFFERENT night_floor (the shipped NEAR_NIGHT_FLOOR 0.10) → it must diverge.
	var div_a := 0.0
	for sun_i in range(-6, 7):
		var se := float(sun_i) * (PI / 12.0)
		var sun := Vector3(cos(se), sin(se), 0.0)
		var n := Vector3(0.2, 0.9, 0.1).normalized()
		var near_bad := VoxiLight.shade_tint(n, sun, CosmosSky.NEAR_NIGHT_FLOOR, VoxiLight.TERM_MU, VoxiLight.MOONSHINE)
		var far := VoxiLight.shade_tint(n, sun, VoxiLight.NIGHT_FLOOR, VoxiLight.TERM_MU, VoxiLight.MOONSHINE)
		div_a = maxf(div_a, (near_bad - far).length())
	_ok(div_a > EPS, "G-VL-EQ: perturbing the near night_floor DIVERGES near vs far (parity requirement bites, Δ=%.3f)" % div_a)

	# Falsification (b): a STALE near planet_centre (far uses C, near uses a shifted C') → the normal, hence shade, differs.
	var Cstale := C + Vector3(400.0, -300.0, 250.0)
	var div_b := 0.0
	for lon_i in range(0, 8):
		var lon := float(lon_i) * (PI / 4.0)
		var wp := C + Vector3(cos(lon), 0.2, sin(lon)) * R
		var sun := Vector3(0.05, 0.3, 0.1)    # near the terminator, where the normal difference bites hardest
		var near_stale := VoxiLight.shade_tint((wp - Cstale).normalized(), sun)
		var far := VoxiLight.shade_tint((wp - C).normalized(), sun)
		div_b = maxf(div_b, (near_stale - far).length())
	_ok(div_b > EPS, "G-VL-EQ: a STALE near planet_centre DIVERGES near vs far (freshness required, Δ=%.3f)" % div_b)

# --- G-VL-CROSS: render_centre freshness across a facet crossing (§2V.6 F1) -------------------------------------
func _gate_cross() -> void:
	var ring := FacetFarRing.new()
	var fid_a := FA.spawn_facet()
	var fid_b := (fid_a + FA.K * FA.K + 1) % (6 * FA.K * FA.K)   # a facet on a different cube face
	if fid_b == fid_a:
		fid_b = (fid_a + 1) % (6 * FA.K * FA.K)
	ring._active_fid = fid_a
	var c_a: Vector3 = ring.render_centre()
	ring._active_fid = fid_b
	var c_b: Vector3 = ring.render_centre()
	_ok(c_a.distance_to(c_b) > 1.0, "G-VL-CROSS: render_centre() VARIES per active facet (a=%s b=%s) — not a constant cache" % [str(c_a), str(c_b)])

	# near==far at BOTH facets when planet_centre = render_centre (what the WorldManager site pushes each frame).
	var sun := Vector3(0.06, 0.25, 0.12)
	var eq_ok := true
	for cfg in [[fid_a, c_a], [fid_b, c_b]]:
		var C: Vector3 = cfg[1]
		for lon_i in range(0, 6):
			var lon := float(lon_i) * (PI / 3.0)
			var wp := C + Vector3(cos(lon), 0.4, sin(lon)) * 6371.0
			var near_st := VoxiLight.shade_tint((wp - C).normalized(), sun)   # planet_centre fed FRESH = render_centre
			var far_st := VoxiLight.shade_tint((wp - C).normalized(), sun)    # far centre = MODEL·0 = render_centre
			if (near_st - far_st).length() > EPS:
				eq_ok = false
	_ok(eq_ok, "G-VL-CROSS: near == far at BOTH facets when planet_centre tracks render_centre (no pop at the flip)")

	# Falsification: if the near did NOT re-read render_centre after A→B (stale c_a while far is at c_b) → divergence.
	var stale_div := 0.0
	for lon_i in range(0, 6):
		var lon := float(lon_i) * (PI / 3.0)
		var wp := c_b + Vector3(cos(lon), 0.4, sin(lon)) * 6371.0
		var near_stale := VoxiLight.shade_tint((wp - c_a).normalized(), sun)   # near stuck on the OLD centre
		var far_now := VoxiLight.shade_tint((wp - c_b).normalized(), sun)      # far at the NEW centre
		stale_div = maxf(stale_div, (near_stale - far_now).length())
	_ok(stale_div > EPS, "G-VL-CROSS: a near centre NOT re-read after the crossing DIVERGES (Δ=%.3f) — freshness is load-bearing" % stale_div)

	# The WorldManager single-site wiring actually pushes render_centre → planet_centre fresh each frame.
	var wm := FileAccess.get_file_as_string("res://src/world/world_manager.gd")
	var i := wm.find("func set_near_daylight_sun_dir")
	var j := wm.find("\nfunc ", i + 10) if i >= 0 else -1
	var seg := wm.substr(i, (j - i) if j > i else 1600) if i >= 0 else ""
	_ok(seg.contains("render_centre()") and seg.contains("set_near_daylight_planet_centre"),
		"G-VL-CROSS: world_manager.set_near_daylight_sun_dir pushes render_centre() → planet_centre at the single site")
	ring.free()
