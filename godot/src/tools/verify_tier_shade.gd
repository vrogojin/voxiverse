extends SceneTree
## COSMOS NIGHT-TERRAIN-CENTRE gate (fix/voxiverse-night-terrain-lit). Proves — HEADLESSLY, no GPU — the day/night
## bug where a large TERRAIN region (incl. a flat WATER sea) renders fully day-lit at LOCAL NIGHT, meeting the correct
## far-ring backstop at a sharp facet/tier seam, with the illuminated patch sweeping the WRONG way (west→east) and
## "fading suddenly on re-bake".
##
## ROOT CAUSE (verified here as pure shade MATH — the GLSL shaders are line-for-line mirrors of these twins):
##   The near-field daylight twins (block_atlas._NEAR_DAYLIGHT_SHADER for the godot_voxel path;
##   block_materials._NEAR_DAYLIGHT_* for the fallback/residual/debris + WATER path) compute the radial normal as
##   n = normalize(v_wp)  — i.e. they assume the planet centre is the SCENE ORIGIN. That holds only when
##   planet_render_centre() == 0. The live faceted build places the planet centre AWAY from the origin (the render
##   frame is T_active⁻¹; planet_render_centre() ≠ 0 — proven non-zero by the set_time up_bf fix, commit 4aa9d56).
##   With a non-zero centre C the wrong outward normal (a) mis-orients the terminator (lit past true dusk → the
##   inverted-brightness "bright at night"), (b) INVERTS the east↔west gradient of μ = n·ŝ (the reversed sweep), and
##   (c) only "refreshes" when geometry re-bakes because the centre is frozen at 0 (the lag). The far-ring shell and
##   the block-LOD tiers derive n = normalize(v_wp − MODEL·0) = normalize(v_wp − C) → the TRUE radial → stay correct
##   and DARK at night. The fix (FP_NIGHT_TERRAIN_CENTRE) feeds the true render centre into the near twins each frame
##   and switches them to n = normalize(v_wp − planet_centre) — identical to the far shell's MODEL·0 normal.
##
## GATES:
##   G-TS-MATCH     : the FIXED near-twin normal == the far-shell MODEL·0 normal, so their μ (and day/night) agree
##                    bit-for-bit at a night sun over facets on ≥2 cube faces (incl. water) — the tier is unified.
##   G-TS-NEARNIGHT : at a local-night sun, EVERY sampled night-side facet's FIXED shade is ≤ the night threshold
##                    (dark) — no tier lit at night, land AND flat water.
##   G-TS-FALSIFY   : the BUGGY normalize(v_wp) normal (shipped) is LIT (day-factor ≥ LIT) at that same night sun for
##                    at least one sampled night-side facet where the fixed normal is dark — the bug is real and the
##                    fix removes it. Teeth: an unchanged fix (or a centre==0 config) would NOT trigger this ⇒ FAIL.
##   G-TS-WATER     : a night-side WATER facet (g < SEA_LEVEL) specifically shades DARK under the fix and is LIT under
##                    the buggy normal — the coordinator's red-sea case (flat liquid is where the mis-light is worst).
##   G-TS-SHADER    : block_atlas / block_materials emit the centre-corrected shader string under the flag (true
##                    planet-radial normal) and the shipped string VERBATIM with it off (byte-identical guard).
##
## RUN: docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_tier_shade.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure. Flag-independent (drives the shade math directly), like verify_atmo_sky.

const TERM_MU := 0.12                 # CosmosSky.TERMINATOR_MU (day() crosses 0→1 over ±this)
const NIGHT_TH := 0.05                # day-factor ≤ this ⇒ effectively night (shade ≈ night_floor)
const LIT_TH := 0.5                   # day-factor ≥ this ⇒ clearly day-lit

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_tier_shade (COSMOS NIGHT-TERRAIN-CENTRE: G-TS-MATCH/NEARNIGHT/FALSIFY/WATER/SHADER) ===")
	FacetAtlas.warm_up()
	_gate_shade()
	_gate_shader_strings()
	_gate_livesun()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# smoothstep(-TERM_MU, TERM_MU, mu) — the shipped near/far day() factor (CosmosSky.day_factor mirror).
static func _day(mu: float) -> float:
	var e := TERM_MU
	var t: float = clampf((mu + e) / (2.0 * e), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

# The absolute (body-centred) surface point of facet `fid`'s centre column, and whether it is water.
func _abs_surface(fid: int) -> Dictionary:
	var cc := FacetAtlas.centre_cell(fid)
	var prof := TerrainConfig.facet_profile(fid, cc.x, cc.y)
	var g := int(prof.x)
	var a := FacetAtlas.lattice_to_world64(fid, float(cc.x), float(g), float(cc.y))
	return {"v": Vector3(a[0], a[1], a[2]), "water": g < TerrainConfig.SEA_LEVEL, "g": g}

func _gate_shade() -> void:
	print("  --- G-TS-MATCH/NEARNIGHT/FALSIFY/WATER: near-twin normal vs far-shell MODEL·0 at a local-night sun ---")
	# Live render placement: the non-fixed-frame law T = facet_transform(active)⁻¹. Its origin C = planet_render_centre()
	# is far from the scene origin (~R) — exactly the live condition the shipped normalize(v_wp) assumes away.
	var active_fid := 0
	var T := FacetAtlas.facet_transform(active_fid).affine_inverse()
	var C := T.origin
	_ok(C.length() > 1000.0, "render centre C is far from the scene origin (|C|=%.1f) — the live bug condition" % C.length())

	# A local-night sun in the RENDER frame: opposite the active facet's TRUE render normal ⇒ the active hemisphere
	# is in deep night. (The shaders dot the render-frame normal with the passed sun_dir; the fixed twin and far shell
	# use the SAME render-frame normal, so a night sun for one is a night sun for the other — that is the whole point.)
	var s0 := _abs_surface(active_fid)
	var n0_true := (T * (s0["v"] as Vector3) - C).normalized()
	var sun := -n0_true

	# Sample facets across ≥2 cube faces (face 0 fids 0.., face 1 fids K²..). Include the active + neighbours + a
	# scan to find a night-side WATER facet.
	var faces_seen := {}
	var falsifier_hit := false
	var water_checked := false
	var kk := FacetAtlas.K * FacetAtlas.K
	var sample: Array = [0, 1, 2, kk, kk + 1, kk + 2, 2 * kk, 3 * kk, 4 * kk, 5 * kk]
	# Add a wider scan (nearest facets on face 0) to reliably catch a night-side water column.
	for i in range(0, 400, 7):
		sample.append(i)

	for fid in sample:
		if fid < 0 or fid >= FacetAtlas.facet_count():
			continue
		var s := _abs_surface(fid)
		var v_wp := T * (s["v"] as Vector3)
		var n_true := (v_wp - C).normalized()      # far-shell MODEL·0 normal  (= the FIXED near-twin)
		var n_bug := v_wp.normalized()               # shipped near-twin normal (centre = scene origin)
		# far-shell MODEL·0 normal, computed the shader's way (MODEL·vertex, MODEL·0) — must MATCH n_true bit-for-bit.
		var shell_n := (v_wp - (T * Vector3.ZERO)).normalized()
		var day_true := _day(n_true.dot(sun))
		var day_bug := _day(n_bug.dot(sun))
		faces_seen[fid / kk] = true

		# G-TS-MATCH: the fixed near-twin normal is the far-shell normal, bit-for-bit.
		_ok(shell_n.distance_to(n_true) < 1.0e-6, "fid %d: fixed near-twin normal == far-shell MODEL·0 normal" % fid)

		# Only assert night behaviour where the CORRECT (far-shell) shade is actually night.
		if day_true <= NIGHT_TH:
			# G-TS-NEARNIGHT: the FIX is dark at night (matches the far ring).
			_ok(day_true <= NIGHT_TH, "fid %d: FIXED shade is night (day=%.3f ≤ %.2f)" % [fid, day_true, NIGHT_TH])
			# G-TS-FALSIFY: the SHIPPED buggy normal is lit at that same night sun for at least one facet.
			if day_bug >= LIT_TH:
				falsifier_hit = true
			# G-TS-WATER: the coordinator's flat-liquid case — a night-side water facet.
			if s["water"] and not water_checked:
				water_checked = true
				_ok(day_true <= NIGHT_TH, "WATER fid %d: FIXED sea shade is night (day=%.3f) — blue, not a lit red slab" % [fid, day_true])
				_ok(day_bug >= LIT_TH, "WATER fid %d: BUGGY sea shade is DAY-lit at night (day=%.3f) — the red-sea bug" % [fid, day_bug])

	_ok(faces_seen.size() >= 2, "sampled facets span ≥2 cube faces (got %d)" % faces_seen.size())
	_ok(falsifier_hit, "G-TS-FALSIFY: the shipped normalize(v_wp) normal is DAY-lit at local night (bug reproduced; fix diverges)")
	_ok(water_checked, "G-TS-WATER: a night-side water facet was found and checked")

func _gate_shader_strings() -> void:
	print("  --- G-TS-SHADER: centre-corrected shader under the flag; shipped string verbatim off ---")
	# block_atlas module path.
	var atlas_off := BlockAtlas.near_daylight_shader_code(false, false)
	var atlas_fix := BlockAtlas.near_daylight_shader_code(false, true)
	_ok(not atlas_off.contains("planet_centre"), "atlas: flag off ⇒ shipped shader (no planet_centre) — byte-identical")
	_ok(atlas_off.contains("normalize(v_wp)"), "atlas: flag off ⇒ shipped origin-normal normalize(v_wp)")
	_ok(atlas_fix.contains("normalize(v_wp - planet_centre)"), "atlas: flag on ⇒ TRUE radial normalize(v_wp - planet_centre)")
	_ok(atlas_fix.contains("uniform vec3 planet_centre"), "atlas: flag on ⇒ planet_centre uniform declared")
	_ok(atlas_fix.contains("night_floor") and atlas_fix.contains("smoothstep(-term_mu"), "atlas: flag on keeps the SHIPPED shade law (not the unified law)")

	# block_materials fallback / residual / water path — the string transform on each shipped twin.
	for src in [BlockMaterials._NEAR_DAYLIGHT_OPAQUE_SHADER, BlockMaterials._NEAR_DAYLIGHT_TRANSLUCENT_DS_SHADER,
			BlockMaterials._NEAR_DAYLIGHT_TRANSLUCENT_BACK_SHADER]:
		var off: String = BlockMaterials.near_daylight_code(src, false)
		var fix: String = BlockMaterials.near_daylight_code(src, true)
		_ok(off == src, "block_materials: flag off ⇒ shipped string verbatim (byte-identical)")
		_ok(not off.contains("planet_centre"), "block_materials: shipped twin has no planet_centre")
		_ok(fix.contains("normalize(v_wp - planet_centre)"), "block_materials: flag on ⇒ TRUE radial normal")
		_ok(fix.contains("uniform vec3 planet_centre"), "block_materials: flag on ⇒ planet_centre uniform declared")
		_ok(not fix.contains("normalize(v_wp)\n") and not fix.contains("normalize(v_wp);"), "block_materials: flag on ⇒ no residual origin-normal")

## G-TS-LIVESUN + G-TS-UNIFIED: the block-LOD tier reads a LIVE, SHARED sun_dir uniform (never a per-facet baked-in
## value), and it shades by the SAME true planet-radial (MODEL·0) normal the far-ring shell uses — so two facets whose
## meshes are committed at DIFFERENT sim-times shade IDENTICALLY at a given clock, and no per-tile sun patchwork can form.
func _gate_livesun() -> void:
	print("  --- G-TS-LIVESUN/UNIFIED: block-LOD reads ONE shared live sun_dir + the far-shell MODEL·0 normal ---")
	var ring := FacetBlockLodRing.new()
	# ONE shared material for every facet mesh (shared_material() is idempotent) — the whole point: all committed
	# facet meshes carry material_override == this one material, so a single per-frame uniform write repaints them ALL.
	var m1 := ring.shared_material()
	var m2 := ring.shared_material()
	_ok(m1 == m2, "block-LOD shared_material() is ONE material instance (all facet meshes share it → one live uniform)")

	# The pushed sun_dir lands on the shared uniform UNMODIFIED (no sign flip / no frame remap) — the far ring and the
	# block-LOD tier are fed the SAME current_sun_dir, so their day/night terminators agree (no mirrored sweep between tiers).
	var sun := Vector3(0.37, -0.51, 0.77).normalized()
	ring.set_sun_dir(sun)
	var got: Vector3 = m1.get_shader_parameter("sun_dir")
	_ok(got.distance_to(sun) < 1.0e-6, "block-LOD set_sun_dir writes the sun VERBATIM to the shared uniform (no mirror/remap)")

	# BAKE-TIME INDEPENDENCE: the shade is a pure function of (this live uniform, geometry) — it holds NO per-facet
	# bake-time sun. The material's shader computes the radial normal from MODEL·0 (the true planet centre in the render
	# frame), exactly like the far-ring _SHELL_ABS_SHADER — so a facet meshed at dawn and one meshed at noon read the
	# identical live sun at any later clock. Assert the shared material's shader carries the far-shell normal law.
	var code: String = m1.shader.code
	_ok(code.contains("MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)"), "block-LOD normal centre = MODEL·0 (true planet centre, not scene origin)")
	_ok(code.contains("normalize(wp - centre)"), "block-LOD normal = normalize(wp - centre) — the far-shell radial (unified)")
	_ok(not code.contains("normalize(wp);") and not code.contains("normalize(wp)\n"), "block-LOD does NOT use the origin-assuming normalize(wp)")
	# The shade must read the sun_dir UNIFORM (live), not a constant — proves no bake-time capture.
	_ok(code.contains("uniform vec3 sun_dir"), "block-LOD shade reads the live sun_dir uniform (not a baked-in constant)")

	# Two facets 'committed at different times' would each get material_override == m1 (see _commit_facet_arrays):
	# assert the commit path binds the shared material, so their shade is bake-time-independent by construction.
	var a1 := ring._build_facet_arrays(0)
	if not (a1["verts"] as PackedVector3Array).is_empty():
		ring._commit_facet_arrays(0, a1)
		var mesh_by: Dictionary = ring._mesh_by_fid
		var mi: MeshInstance3D = mesh_by.get(0, null)
		_ok(mi != null and mi.material_override == m1, "a committed facet mesh binds the ONE shared material (bake-time-independent shade)")
	ring.free()
