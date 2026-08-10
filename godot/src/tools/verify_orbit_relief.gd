extends SceneTree
## FP_ORBIT_RELIEF gate (docs/COSMOS-ORBIT-RELIEF-MESH-DESIGN.md, task #99 G3).
##
## Proves `FacetOrbitRelief` — the real relief-mesh tier that supersedes the rejected shading-only fix
## (FP_SKIN_RELIEF_SHADE/FP_RELIEF_REEMIT) — is byte-off by default, reads heights/positions that agree exactly
## with the already-baked `GlobalReliefData` DEM, welds bit-identically at shared facet edges, self-heals its
## no-protrusion seams at commit time (WS4), stays inside its NEVER-OOM byte cap, commits in O(≤batch) not
## O(resident-set) (WS1b), is fully suspended on-surface (WS1a), lights with the flat skin's terminator-ONLY
## law — no per-slope shading (WS3, user verdict "no slope shades, it just looks ugly") — and samples the SAME
## whole-planet fine-map texture the flat skin does, killing the coarse "large coloured squares" (WS2).
##
## Gates (mirrors `verify_far_geometry.gd`/`verify_relief_reemit.gd`'s self-describing convention — this run's
## compiled flags decide which assertions are meaningful):
##   G-OR-OFF          — FP_ORBIT_RELIEF off: `FacetFarRing.set_relief_data` never constructs a `FacetOrbitRelief`.
##   G-OR-LIGHT (WS3)   — the shader source calls `voxi_shade`, derives its normal IN-SHADER from VERTEX position
##                        (never reads a mesh NORMAL attribute — the mesh carries none), has no real-normal
##                        relief/lambert term, and `make_material` never touches `FacetSmoothV2` (G3's material is
##                        fully independent, so it can never inherit `FP_SMOOTH_V2_LIT`'s slope shading).
##   G-OR-TEXTURE (WS2) — `build_tile`'s per-node UV/UV2 decode (through the SAME quadrant/layer math the
##                        shader's fragment() runs) to the EXACT fine_map layer + texel region
##                        `FacetTexBaker._fine_commit` (the true bake-side oracle) placed that facet's tile at —
##                        for every node, not just a corner — and a DIFFERENT facet's UV provably does NOT land
##                        in the same region (falsifiable). Plus the id==0 → vertex-colour fallback (never black).
##   G-OR-DATA-EQ       — `build_tile`'s stored height at every one of a real facet's 1089 nodes equals
##                        `GlobalReliefData.height_at` EXACTLY. Falsifier: a hand-perturbed `heights` snapshot
##                        entry diverges from the oracle at that same node.
##   G-OR-BYTES         — `tile_bytes`/`arena_bytes` match the real per-component arithmetic; `want_set`
##                        truncates to `ORBIT_RELIEF_MAX_TILES` even when EVERY facet on the planet is a
##                        candidate; `arena_bytes()` stays under a 32 MB safety ceiling.
##   G-OR-WELD          — two real adjacent facets' shared-edge node positions coincide (≤1e-4·R_BLOCKS, f32
##                        rounding) — the One-Surface Law proof. `sunk_positions` (the WS4 commit-time sink,
##                        pure) sinks EXACTLY the flagged edge by `TierPlace.backstop_sink()` and leaves every
##                        other node untouched.
##   G-OR-SEAM (WS4)    — falsifier: commit facet A alone (its neighbour B not yet committed) — A's edge facing
##                        B is sunk. Then admit + commit B — BOTH now read the identical un-sunk (true DEM)
##                        height on the shared edge, self-healed with no rebuild of A's own data beyond a
##                        position rewrite. Never a one-sided cliff at any point in the sequence.
##   G-OR-COMMIT-COST (WS1b) — one `_commit()` call touches O(≤ORBIT_RELIEF_COMMIT_TILES) tiles' data, NEVER
##                        the whole resident set — falsifier: mark all `ORBIT_RELIEF_MAX_TILES` tiles dirty at
##                        once, confirm only the batch cap gets (re)written per call, and `_commit()`'s own
##                        source never calls `FacetSmoothV2.merge_tiles` (the O(resident) re-merge this removes).
##   G-OR-SUSPEND (WS1a) — on-surface (`shell_offsurface()` false): `step()` performs zero recompute/dispatch/
##                        commit past the initial reap — the resident/committed set is BYTE-IDENTICAL before and
##                        after. Off-surface: normal operation (dispatch + commit) resumes immediately.
##
## RUN (needs FACETED + FP_GLOBAL_RELIEF_DATA sed-toggled true for the ON-path gates, per the design's
## dependency on G2):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_orbit_relief.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const FOR_ := preload("res://src/world/facet_orbit_relief.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

const EPS := 1.0e-4

func _initialize() -> void:
	print("=== verify_orbit_relief (task #99 G3 — FP_ORBIT_RELIEF) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	FA.warm_up()

	_gate_off()
	_gate_light()
	_gate_texture()
	if CubeSphere.FP_ORBIT_RELIEF and CubeSphere.FP_GLOBAL_RELIEF_DATA:
		_gate_data_eq()
		_gate_bytes()
		_gate_weld()
		_gate_seam()
		_gate_commit_cost()
		_gate_suspend()
	else:
		_ok(true, "G-OR-DATA-EQ/BYTES/WELD/SEAM/COMMIT-COST/SUSPEND: skipped this run (needs FP_ORBIT_RELIEF + FP_GLOBAL_RELIEF_DATA both sed-toggled true)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Real off-surface fixture: a bare `FacetFarRing.new()` defaults ON-surface (`_cam_set=false` ⇒
## `shell_offsurface()==false`), which would make `step()` early-return in every dispatch-exercising gate below.
## Poke the two private fields `shell_offsurface()` reads (mirrors the established "gates poke private fields
## directly" precedent, e.g. `verify_far_geometry.gd`'s `ring._active_fid = fid`) so these gates actually drive
## the off-surface path — the SAME path a real orbit session runs.
## WS2 test convenience: `FOR_.build_tile` now needs `fid`'s [face,a,b,k] tex-decode too — every OTHER gate here
## is testing something unrelated to that decode (heights/bytes/welding/commit), so this wrapper auto-fills it
## from the real `FOR_._tex_decode(fid)` (the exact call `step()` itself makes, main-thread) rather than making
## every call site repeat the same four extra args. G-OR-TEXTURE tests `_tex_decode`/the UV formula directly.
func _bt(fid: int, heights: PackedInt32Array, coarse_col: PackedColorArray, vert_base: int) -> Dictionary:
	var tx := FOR_._tex_decode(fid)
	return FOR_.build_tile(fid, heights, coarse_col, vert_base, int(tx[0]), int(tx[1]), int(tx[2]), int(tx[3]))

func _force_offsurface(ring: FacetFarRing) -> void:
	ring._cam_set = true
	ring._emit_floored_last = false

# --- G-OR-OFF: self-describing, run only when FP_ORBIT_RELIEF is off this run ----------------------------------------
func _gate_off() -> void:
	if CubeSphere.FP_ORBIT_RELIEF:
		_ok(true, "G-OR-OFF: skipped this run (flag currently ON — the ON-path gates below cover behaviour)")
		return
	var rd := GlobalReliefData.new()
	rd.setup()
	var ring := FacetFarRing.new()
	ring._active_fid = 12
	ring.set_relief_data(rd)
	_ok(ring._orbit_relief == null, "G-OR-OFF: set_relief_data never constructs FacetOrbitRelief with the flag off")
	ring.free()

# --- G-OR-LIGHT (WS3, user verdict "no slope shades"): terminator-only, radial in-shader normal, no ARRAY_NORMAL ------
func _gate_light() -> void:
	var code := FOR_.shader_code()
	_ok(code.find("voxi_shade(") != -1, "G-OR-LIGHT: the shader calls voxi_shade — the flat skin's SAME day/night/terminator law")
	_ok(code.find("wp - centre") != -1, "G-OR-LIGHT: the shading normal is derived IN-SHADER from VERTEX position (wp - centre), not from a mesh attribute")
	_ok(code.find("NORMAL") == -1, "G-OR-LIGHT: the shader never reads the mesh NORMAL attribute at all")
	# "lam" alone would false-positive on "clamp" — check for the actual banned patterns instead (a real
	# per-slope lambert/relief term reads as "lam =", "lam)", or a "relief" identifier — none of which are
	# substrings of any word this shader source legitimately uses).
	_ok(code.find("lam ") == -1 and code.find("lam)") == -1 and code.find("relief") == -1,
		"G-OR-LIGHT: no real-normal relief/lambert term anywhere (no lam=dot(nm,..), no relief term — user verdict: no slope shades)")
	_ok(code.find("ALBEDO = fine_albedo * v_st") != -1,
		"G-OR-LIGHT: ALBEDO is exactly fine_albedo * v_st — nothing else composited in")

	# G3's material is its OWN — never shares/derives from FacetSmoothV2's, so its lighting can never accidentally
	# couple to FP_SMOOTH_V2_LIT (V2's own, unrelated, slope-shaded variant). Extract make_material()'s body by
	# INDENTATION (every real body line starts with a tab), not by "next func" text search — the instance section
	# right after it is mostly comments/var declarations at column 0, not another `func`, so a naive "\nfunc "
	# search over-captures hundreds of unrelated lines (including a doc comment that legitimately says
	# "Mirrors FacetSmoothV2's worker-slot-pool...").
	var f := FileAccess.open("res://src/world/facet_orbit_relief.gd", FileAccess.READ)
	_ok(f != null, "G-OR-LIGHT: opened facet_orbit_relief.gd for the static source check")
	if f != null:
		var lines := f.get_as_text().split("\n")
		var in_body := false
		var body_lines: Array = []
		var found := false
		for line in lines:
			if not in_body:
				if line.begins_with("static func make_material()"):
					in_body = true
					found = true
				continue
			if line.begins_with("\t") or line.strip_edges() == "":
				body_lines.append(line)
			else:
				break   # dedented to column 0 ⇒ left the function body
		_ok(found, "G-OR-LIGHT: found make_material()'s definition")
		var body := "\n".join(body_lines)
		_ok(body.find("FacetSmoothV2") == -1, "G-OR-LIGHT: make_material() never calls into FacetSmoothV2 — G3's material is fully independent")

	var mat := FOR_.make_material()
	_ok(mat is ShaderMaterial, "G-OR-LIGHT: make_material() returns a ShaderMaterial")
	_ok(mat.get_shader_parameter("sun_dir") != null, "G-OR-LIGHT: the material carries a sun_dir shader parameter")

	# set_sun_dir on a live instance updates the material's uniform (mirrors FacetSmoothV2.set_sun_dir's contract).
	var fid := 12
	var rd := GlobalReliefData.new()
	rd.setup()
	var ring2 := FacetFarRing.new()
	ring2._active_fid = fid
	_force_offsurface(ring2)
	var relief := FacetOrbitRelief.new()
	relief.setup_instance(ring2, fid, rd)
	var new_sun := Vector3(0.3, 0.6, 0.74).normalized()
	relief.set_sun_dir(new_sun)
	var got_sun: Vector3 = relief._material.get_shader_parameter("sun_dir")
	_ok(got_sun.distance_to(new_sun) < 1.0e-6, "G-OR-LIGHT: set_sun_dir updates THIS instance's own material uniform exactly")
	ring2.free()

# --- G-OR-TEXTURE (WS2): G3's UV lands on the flat skin's EXACT fine-map (fid,layer,texel) parametrisation ------------
# The true oracle is `FacetTexBaker._fine_commit` (facet_tex_baker.gd:1734-1743) — where a baked facet's tile
# ACTUALLY lands in the whole-planet fine_map: `layer = face·4 + (b/quad)·2 + (a/quad)`, tile placed at pixel
# offset `((a%quad)·texels, (b%quad)·texels)`. This gate decodes G3's OWN emitted UV/UV2 through the IDENTICAL
# quadrant/layer math the shader's fragment() runs (a small pure GDScript mirror, `_decode_uv` below) and proves
# it reproduces that SAME layer + falls INSIDE that SAME facet's placed texel region — i.e. G3 samples exactly
# the texels the bake pipeline wrote for that facet, nothing else. Depends on the structural precondition
# `k_of(fid) == 2·PLANET_MAP_QUAD` (24 == 2·12, LOCKED per facet_atlas.gd) that makes the two quadrant systems
# agree in the first place — asserted explicitly so a future K/QUAD change fails loudly here, not silently on
# screen.
func _decode_uv(uv: Vector2, uv2: Vector2, quad: int, texels: int) -> Array:
	var q := Vector2(clampf(floor(uv.x * 2.0), 0.0, 1.0), clampf(floor(uv.y * 2.0), 0.0, 1.0))
	var layer := int(uv2.x + 0.5) * 4 + int(q.y) * 2 + int(q.x)
	# GLSL fract(x) == x - floor(x); no fract() builtin in GDScript.
	var ux2 := uv.x * 2.0
	var fux: float = ux2 - floor(ux2)
	var uy2 := uv.y * 2.0
	var fuy: float = uy2 - floor(uy2)
	var fx := clampi(int(fux * float(quad * texels)), 0, quad * texels - 1)
	var fy := clampi(int(fuy * float(quad * texels)), 0, quad * texels - 1)
	return [layer, fx, fy]

func _gate_texture() -> void:
	var quad := CubeSphere.PLANET_MAP_QUAD
	var texels := CubeSphere.PLANET_MAP_TEXELS
	var fid := 12
	var tx := FOR_._tex_decode(fid)
	var face: int = tx[0]; var a: int = tx[1]; var b: int = tx[2]; var k: int = tx[3]
	_ok(k == 2 * quad, "G-OR-TEXTURE: fixture precondition — k_of(fid)==2·PLANET_MAP_QUAD (%d == 2·%d), the invariant the quadrant math below depends on" % [k, quad])

	# Independent oracle: FacetTexBaker._fine_commit's OWN formula for where fid's baked tile lands.
	var oracle_layer := face * 4 + (b / quad) * 2 + (a / quad)
	var oracle_x0 := (a % quad) * texels
	var oracle_y0 := (b % quad) * texels

	var rd := GlobalReliefData.new()
	rd.setup()
	rd.bake_facet(fid)
	var tile := _bt(fid, rd.height_grid(fid), PackedColorArray(), 0)
	_ok(tile.has("uv") and tile.has("uv2"), "G-OR-TEXTURE: build_tile's returned dict carries 'uv' and 'uv2'")
	var uv: PackedVector2Array = tile["uv"]
	var uv2: PackedVector2Array = tile["uv2"]
	var cells := FOR_.ORBIT_RELIEF_CELLS
	var stride := cells + 1

	# UV2 (face) is constant across the WHOLE tile.
	var uv2_ok := true
	for idx in range(uv2.size()):
		if absf(uv2[idx].x - float(face)) > 1.0e-6 or absf(uv2[idx].y) > 1.0e-6:
			uv2_ok = false
			break
	_ok(uv2_ok, "G-OR-TEXTURE: UV2 == (face, 0.0) constant across every node of the tile")

	# The exact closed-form UV: corner (i=0,j=0) == (a/k, b/k); corner (i=cells,j=cells) == ((a+1)/k, (b+1)/k).
	var kf := float(k)
	var uv00 := uv[0]
	var uv11 := uv[stride * stride - 1]
	_ok(uv00.distance_to(Vector2(float(a) / kf, float(b) / kf)) < 1.0e-6,
		"G-OR-TEXTURE: node (0,0)'s UV == (a/k, b/k) exactly (Δ=%.8f)" % uv00.distance_to(Vector2(float(a) / kf, float(b) / kf)))
	_ok(uv11.distance_to(Vector2(float(a + 1) / kf, float(b + 1) / kf)) < 1.0e-6,
		"G-OR-TEXTURE: node (cells,cells)'s UV == ((a+1)/k, (b+1)/k) exactly (Δ=%.8f)" % uv11.distance_to(Vector2(float(a + 1) / kf, float(b + 1) / kf)))

	# The falsifiable core: decode G3's own UV/UV2 through the SAME quadrant/layer math the shader runs, and
	# confirm it lands on the oracle's layer + inside the oracle's placed texel region, for EVERY node — not just
	# a corner (a node near the facet's own boundary is the case most likely to leak into a neighbour's texels).
	# The trailing-edge node (i or j == cells, UV == the EXACT facet boundary) decodes to the ONE-PAST-the-end
	# texel index (the shared seam pixel two adjacent facets' regions both touch) — inherent to sampling exactly
	# AT a shared edge, not a leak into the interior of the next facet, so that single boundary pixel is allowed;
	# anything landing 2+ texels past the region (a REAL leak) still fails.
	var all_layer_ok := true
	var all_region_ok := true
	var interior_ok := true
	var mid := int(cells / 2)
	for idx in range(uv.size()):
		var dec := _decode_uv(uv[idx], uv2[idx], quad, texels)
		if int(dec[0]) != oracle_layer:
			all_layer_ok = false
		var fx: int = dec[1]; var fy: int = dec[2]
		if fx < oracle_x0 - 0 or fx > oracle_x0 + texels or fy < oracle_y0 or fy > oracle_y0 + texels:
			all_region_ok = false
	var dec_mid := _decode_uv(uv[mid * stride + mid], uv2[mid * stride + mid], quad, texels)
	if int(dec_mid[1]) < oracle_x0 or int(dec_mid[1]) >= oracle_x0 + texels or int(dec_mid[2]) < oracle_y0 or int(dec_mid[2]) >= oracle_y0 + texels:
		interior_ok = false
	_ok(all_layer_ok, "G-OR-TEXTURE: every node's UV/UV2 decodes to the SAME fine_map layer FacetTexBaker._fine_commit assigns this facet (%d)" % oracle_layer)
	_ok(all_region_ok, "G-OR-TEXTURE: every node's decoded texel falls within ONE texel of this facet's own placed tile region [%d,%d]×[%d,%d] (the trailing edge legitimately lands on the shared seam pixel) — never a real leak" % [oracle_x0, oracle_x0 + texels, oracle_y0, oracle_y0 + texels])
	_ok(interior_ok, "G-OR-TEXTURE: an INTERIOR node (mid-tile, not on any shared edge) falls STRICTLY inside the region — the boundary allowance above isn't hiding a real bug")

	# Falsifier: a DIFFERENT facet's UV must NOT decode into this facet's region (proves the check above isn't
	# vacuously true for every input).
	var fid_b := FacetAtlas.seam_neighbour(fid, FacetAtlas.S_EAST)
	if fid_b >= 0:
		var txb := FOR_._tex_decode(fid_b)
		var tile_b := _bt(fid_b, rd.height_grid(fid_b) if rd.bake_facet(fid_b) else PackedInt32Array(), PackedColorArray(), 0)
		if tile_b.has("uv"):
			var uv_b: PackedVector2Array = tile_b["uv"]
			var dec_b := _decode_uv(uv_b[0], tile_b["uv2"][0], quad, texels)
			var b_matches_a_region := int(dec_b[0]) == oracle_layer and int(dec_b[1]) >= oracle_x0 and int(dec_b[1]) < oracle_x0 + texels and int(dec_b[2]) >= oracle_y0 and int(dec_b[2]) < oracle_y0 + texels
			_ok(not b_matches_a_region, "G-OR-TEXTURE: a DIFFERENT facet's (fid_b's) UV does NOT decode into fid's texel region — the region check is falsifiable, not vacuous")

	# Fallback contract (source text, complements G-OR-LIGHT): id==0 falls back to the vertex colour, never black.
	var code := FOR_.shader_code()
	_ok(code.find("(_f8 > 0) ? far_lut[_f8 - 1] : v_col_raw") != -1,
		"G-OR-TEXTURE: an un-baked texel (id 0) falls back to v_col_raw (the vertex coarse_color) — never black")

	# far_lut is seeded ONCE at material creation from the SAME 14-entry palette the flat skin's fine decode uses.
	var mat := FOR_.make_material()
	var lut = mat.get_shader_parameter("far_lut")
	_ok(lut != null and lut.size() == FarPalette.frozen_colors().size(),
		"G-OR-TEXTURE: make_material() seeds far_lut with FarPalette.frozen_colors()'s exact %d entries" % FarPalette.frozen_colors().size())

	# The binding chain: FacetOrbitRelief.set_fine_map updates THIS instance's own material uniform directly
	# (flag-independent — the FP_PLANET_MAP guard lives one level up, in FacetFarRing.set_fine_map, which this
	# gate's sed-toggle scheme doesn't flip, so it's checked via a static source read below instead).
	var rd3 := GlobalReliefData.new()
	rd3.setup()
	var ring3 := FacetFarRing.new()
	ring3._active_fid = fid
	_force_offsurface(ring3)
	var relief3 := FacetOrbitRelief.new()
	relief3.setup_instance(ring3, fid, rd3)
	var dummy_tex := Texture2DArray.new()
	relief3.set_fine_map(dummy_tex)
	_ok(relief3._material.get_shader_parameter("fine_map") == dummy_tex,
		"G-OR-TEXTURE: FacetOrbitRelief.set_fine_map updates THIS instance's own material's fine_map uniform")
	relief3.set_fine_map(null)
	_ok(relief3._material.get_shader_parameter("fine_map") == dummy_tex,
		"G-OR-TEXTURE: set_fine_map(null) is a no-op — never clears an already-bound texture")
	ring3.free()

	# FacetFarRing.set_fine_map forwards to _orbit_relief.set_fine_map (the actual per-frame WorldManager push
	# site, world_manager.gd, is unchanged — it already calls ring.set_fine_map every frame under FP_PLANET_MAP).
	var f2 := FileAccess.open("res://src/world/facet_far_ring.gd", FileAccess.READ)
	_ok(f2 != null, "G-OR-TEXTURE: opened facet_far_ring.gd for the static source check")
	if f2 != null:
		var text2 := f2.get_as_text()
		var start2 := text2.find("func set_fine_map(")
		_ok(start2 >= 0, "G-OR-TEXTURE: found FacetFarRing.set_fine_map's definition")
		if start2 >= 0:
			var lines2 := text2.substr(start2).split("\n")
			var body2 := []
			for i in range(1, lines2.size()):
				var line: String = lines2[i]
				if line.begins_with("\t") or line.strip_edges() == "":
					body2.append(line)
				else:
					break
			_ok("\n".join(body2).find("_orbit_relief.set_fine_map(tex)") != -1,
				"G-OR-TEXTURE: FacetFarRing.set_fine_map forwards the SAME tex to _orbit_relief.set_fine_map")

# --- G-OR-DATA-EQ: build_tile's stored heights == the GlobalReliefData oracle, falsifiable ----------------------------
func _gate_data_eq() -> void:
	var fid := 12   # real terrain, the same facet the STAGE-1/FIRES gates already use
	var rd := GlobalReliefData.new()
	rd.setup()
	_ok(rd.is_ready(), "G-OR-DATA-EQ: GlobalReliefData.setup() allocates (FP_GLOBAL_RELIEF_DATA on)")
	_ok(rd.bake_facet(fid), "G-OR-DATA-EQ: bake_facet(fid) succeeds")

	var heights := rd.height_grid(fid)
	_ok(heights.size() == GlobalReliefData.NODES_PER_FACET, "G-OR-DATA-EQ: height_grid returns the full %d-node snapshot" % GlobalReliefData.NODES_PER_FACET)

	var tile := _bt(fid, heights, PackedColorArray(), 0)
	_ok(not tile.is_empty(), "G-OR-DATA-EQ: build_tile succeeds on a baked facet")
	var g: PackedInt32Array = tile["g"]
	var stride := FOR_.ORBIT_RELIEF_CELLS + 1
	var worst := 0
	for j in range(stride):
		for i in range(stride):
			var want := rd.height_at(fid, i, j)
			var got := g[j * stride + i]
			worst = maxi(worst, absi(got - want))
	_ok(worst == 0, "G-OR-DATA-EQ: every one of %d nodes' stored height == GlobalReliefData.height_at exactly (worst Δ=%d)" % [heights.size(), worst])

	# WS1b: vert_base is baked into idx at build time — index k should equal (local index + vert_base).
	var idx: PackedInt32Array = tile["idx"]
	var base := 7000
	var tile_b := _bt(fid, heights, PackedColorArray(), base)
	var idx_b: PackedInt32Array = tile_b["idx"]
	var offsets_ok := true
	for k in range(idx.size()):
		if idx_b[k] != idx[k] + base:
			offsets_ok = false
			break
	_ok(offsets_ok, "G-OR-DATA-EQ: build_tile bakes vert_base into every idx entry exactly (worker-side, WS1b)")

	# Falsification: perturb ONE entry of a COPY before building, and confirm THAT node's stored height now
	# diverges from the (unperturbed) oracle — proving this gate actually reads through build_tile, not just
	# echoing back whatever it was fed.
	var bad := heights.duplicate()
	bad[100] += 77
	var bad_tile := _bt(fid, bad, PackedColorArray(), 0)
	var bad_g: PackedInt32Array = bad_tile["g"]
	_ok(bad_g[100] != rd.height_at(fid, 100 % stride, int(100 / stride)),
		"G-OR-DATA-EQ: a perturbed heights[100] DIVERGES from the true oracle at that node (gate is falsifiable)")

	# A refusal contract: wrong-size / empty heights never returns a non-empty tile.
	_ok(_bt(fid, PackedInt32Array(), PackedColorArray(), 0).is_empty(),
		"G-OR-DATA-EQ: build_tile refuses (returns {}) on an empty/malformed heights snapshot")

# --- G-OR-BYTES: real tile_bytes/arena_bytes arithmetic + the hard want_set cap, even under an all-planet burst ------
func _gate_bytes() -> void:
	var fid := 12
	var rd := GlobalReliefData.new()
	rd.setup()
	rd.bake_facet(fid)
	var heights := rd.height_grid(fid)
	var tile := _bt(fid, heights, PackedColorArray(), 0)
	var tb := FOR_.tile_bytes(tile)
	var stride := FOR_.ORBIT_RELIEF_CELLS + 1
	var nv: int = (tile["pos"] as PackedVector3Array).size()
	var ni: int = (tile["idx"] as PackedInt32Array).size()
	# WS3: pos 12B + col 16B (NO nrm — the mesh carries no normal attribute at all, see facet_orbit_relief.gd's doc).
	# WS2: + uv 8B + uv2 8B (the fine-map sample).
	var want_bytes := nv * (12 + 16 + 8 + 8) + ni * 4
	_ok(tb == want_bytes, "G-OR-BYTES: tile_bytes matches the real per-component arithmetic, WS3 no-normal + WS2 uv/uv2 (%d verts, %d indices) exactly" % [nv, ni])
	_ok(not tile.has("nrm"), "G-OR-BYTES: WS3 — build_tile's returned dict carries NO 'nrm' key at all")
	_ok(nv == FOR_.VERTS_PER_TILE and ni == FOR_.IDX_PER_TILE, "G-OR-BYTES: a tile's vert/idx count == VERTS_PER_TILE/IDX_PER_TILE exactly (fixed-slot arena precondition, WS1b)")

	var arena_want := CubeSphere.ORBIT_RELIEF_MAX_TILES * (FOR_.VERTS_PER_TILE * (12 + 16 + 8 + 8) + FOR_.IDX_PER_TILE * 4)
	_ok(FOR_.arena_bytes() == arena_want, "G-OR-BYTES: arena_bytes() matches the fixed-capacity arithmetic exactly")
	var cap_mb := float(FOR_.arena_bytes()) / (1024.0 * 1024.0)
	_ok(cap_mb <= 32.0, "G-OR-BYTES: the arena's fixed allocation stays under the 32 MB safety ceiling (got %.2f MB)" % cap_mb)

	# The pathological burst: EVERY facet on the planet is a candidate (a huge reach, huge theta_h) — want_set
	# must still truncate to the hard cap.
	var n := FA.facet_count()
	var all_fids := PackedInt32Array(); all_fids.resize(n)
	for i in range(n):
		all_fids[i] = i
	var order := FOR_.want_set(fid, Vector3(0, 0, 1), PI, 0, CubeSphere.ORBIT_RELIEF_MAX_TILES, all_fids, PI)
	_ok(order.size() <= CubeSphere.ORBIT_RELIEF_MAX_TILES, "G-OR-BYTES: want_set NEVER exceeds ORBIT_RELIEF_MAX_TILES(%d) even when all %d facets are candidates (got %d)" % [CubeSphere.ORBIT_RELIEF_MAX_TILES, n, order.size()])
	_ok(order.size() == CubeSphere.ORBIT_RELIEF_MAX_TILES, "G-OR-BYTES: the all-planet burst actually SATURATES the cap (proves this isn't a vacuous pass)")

# --- G-OR-WELD: shared-edge positions coincide + sunk_positions sinks EXACTLY the flagged edge -------------------------
func _gate_weld() -> void:
	var fid_a := 12
	var fid_b := FA.seam_neighbour(fid_a, FA.S_EAST)
	_ok(fid_b >= 0, "G-OR-WELD: facet %d has a real EAST neighbour" % fid_a)
	if fid_b < 0:
		return
	var rd := GlobalReliefData.new()
	rd.setup()
	rd.bake_facet(fid_a)
	rd.bake_facet(fid_b)
	var tile_a := _bt(fid_a, rd.height_grid(fid_a), PackedColorArray(), 0)
	var tile_b := _bt(fid_b, rd.height_grid(fid_b), PackedColorArray(), 0)
	var pos_a: PackedVector3Array = tile_a["pos"]
	var pos_b: PackedVector3Array = tile_b["pos"]
	var cells := FOR_.ORBIT_RELIEF_CELLS
	var stride := cells + 1
	var edge_a: Array = []
	for j in range(stride):
		edge_a.append(pos_a[j * stride + cells])
	var edge_b: Array = []
	for j in range(stride):
		edge_b.append(pos_b[j * stride + 0])
	var scale := float(FacetAtlas.R_BLOCKS)
	var matched := 0
	for pa in edge_a:
		var best := INF
		for pb in edge_b:
			best = minf(best, (pa as Vector3).distance_to(pb as Vector3))
		if best <= EPS * scale:
			matched += 1
	_ok(matched == edge_a.size(), "G-OR-WELD: every one of fid %d's EAST-edge nodes has a coincident node on fid %d's WEST edge (%d/%d matched, ≤%.4f blocks)" % [fid_a, fid_b, matched, edge_a.size(), EPS * scale])

	# sunk_positions (WS4, pure): sinking WEST only moves i=0 nodes by exactly backstop_sink(); everything else untouched.
	var mask := 1 << FacetSmoothV2.EDGE_WEST
	var sunk := FOR_.sunk_positions(pos_a, cells, stride, mask)
	var sink := TierPlace.backstop_sink()
	var boundary_ok := true
	var interior_ok := true
	for j in range(stride):
		for i in range(stride):
			var k := j * stride + i
			var d_raw := (pos_a[k] as Vector3).length()
			var d_sunk := (sunk[k] as Vector3).length()
			if i == 0:
				if absf((d_raw - d_sunk) - sink) > EPS * scale:
					boundary_ok = false
			else:
				if pos_a[k].distance_to(sunk[k]) > EPS * scale:
					interior_ok = false
	_ok(boundary_ok, "G-OR-WELD: sunk_positions sinks the flagged WEST-edge (i=0) nodes by EXACTLY backstop_sink() (%.2f blocks)" % sink)
	_ok(interior_ok, "G-OR-WELD: sunk_positions leaves every non-flagged node (i>0) untouched — scoped, not tier-wide")
	_ok(pos_a[0].distance_to((FOR_.sunk_positions(pos_a, cells, stride, 0) as PackedVector3Array)[0]) <= EPS * scale,
		"G-OR-WELD: sunk_positions is a no-op (byte-identical copy) with sink_edges==0")

# --- G-OR-SEAM (WS4): a build-up sequence never shows a one-sided cliff, and heals to the true height -----------------
# NOTE (root-cause correction, live A/B follow-up): node (i=cells, j=0) — the j=0 END of A's EAST edge — is a
# CORNER shared with A's SOUTH edge too (`_edge_indices` for SOUTH includes gi=cells). A node on TWO cardinal
# edges legitimately stays sunk as long as EITHER bordering neighbour is uncommitted — it must still guard against
# protrusion from whichever side is still open — so it only fully heals to the TRUE height once EVERY neighbour it
# borders has committed, not just one. Testing that exact corner for "heals as soon as ONLY the EAST neighbour
# commits" was the earlier gate's bug (not a `_commit()` bug: direct instrumentation confirmed `_commit()` already
# rewrites A's mask correctly and A/B never disagree at any point — Δ=0.000000 measured — the corner just wasn't
# expected to reach `a_raw` yet). This version tests THREE properties instead: (1) a pure EAST-only INTERIOR node
# (j=cells/2, on no other cardinal edge) heals to the true height the instant ONLY B commits — the direct proof of
# this WS4 fix; (2) the shared CORNER never shows a crack between A's and B's copies at any point (the actual
# no-one-sided-cliff safety property) even while it is still correctly sunk; (3) once ALL of A's neighbours have
# committed, the corner ALSO fully heals — the complete self-heal closure. Also exercises the `sunk_positions`
# double-sink fix: a node on 2 flagged edges must sink by exactly ONE `backstop_sink()`, not two — falsified below
# by checking the alone-facet corner sinks by the SAME amount as the interior edge nodes, not double.
func _gate_seam() -> void:
	var fid_a := 12
	var fid_b := FA.seam_neighbour(fid_a, FA.S_EAST)
	var fid_s := FA.seam_neighbour(fid_a, FA.S_SOUTH)
	var fid_w := FA.seam_neighbour(fid_a, FA.S_WEST)
	var fid_n := FA.seam_neighbour(fid_a, FA.S_NORTH)
	_ok(fid_b >= 0 and fid_s >= 0 and fid_w >= 0 and fid_n >= 0, "G-OR-SEAM: facet %d has all 4 real cardinal neighbours" % fid_a)
	if fid_b < 0 or fid_s < 0 or fid_w < 0 or fid_n < 0:
		return
	var rd := GlobalReliefData.new()
	rd.setup()
	for f in [fid_a, fid_b, fid_s, fid_w, fid_n]:
		rd.bake_facet(f)
	var ring := FacetFarRing.new()
	ring._active_fid = fid_a
	_force_offsurface(ring)
	var relief := FacetOrbitRelief.new()
	relief.setup_instance(ring, fid_a, rd)

	var stride := FOR_.ORBIT_RELIEF_CELLS + 1
	var cells := FOR_.ORBIT_RELIEF_CELLS
	var mid := int(cells / 2)
	var raw_pos: PackedVector3Array = (_bt(fid_a, rd.height_grid(fid_a), PackedColorArray(), 0)["pos"] as PackedVector3Array)
	var a_edge_mid_raw := raw_pos[mid * stride + cells]     # (i=cells, j=mid) — pure EAST-edge INTERIOR node
	var a_corner_raw := raw_pos[0 * stride + cells]          # (i=cells, j=0) — the EAST/SOUTH shared CORNER
	var scale := float(FacetAtlas.R_BLOCKS)

	# Step 1: A alone is dirty/ready; every neighbour is NOT in the committed set yet — every touched node sunk.
	relief._want = {fid_a: true}
	relief._tiles[fid_a] = _bt(fid_a, rd.height_grid(fid_a), PackedColorArray(), relief._alloc_arena_slot(fid_a) * FOR_.VERTS_PER_TILE)
	relief._commit_dirty = true
	relief._commit()
	_ok(relief._committed_tiles.has(fid_a), "G-OR-SEAM: facet A is committed alone")
	var slot_a: int = relief._fid_slot[fid_a]
	var vbase_a := slot_a * FOR_.VERTS_PER_TILE
	var a_edge_mid_before := relief._arena_pos[vbase_a + mid * stride + cells]
	var a_corner_before := relief._arena_pos[vbase_a + 0 * stride + cells]
	var d_edge_before := absf(a_edge_mid_before.length() - a_edge_mid_raw.length())
	var d_corner_before := absf(a_corner_before.length() - a_corner_raw.length())
	_ok(d_edge_before > 1.0, "G-OR-SEAM: A's EAST-edge interior node is SUNK while B is uncommitted — Δ=%.2f" % d_edge_before)
	_ok(d_corner_before > 1.0, "G-OR-SEAM: A's shared corner is also SUNK while every neighbour is uncommitted — Δ=%.2f" % d_corner_before)
	_ok(absf(d_corner_before - d_edge_before) <= EPS * scale,
		"G-OR-SEAM: the corner (on 2 flagged edges) sinks by the SAME single amount as an interior node (on 1) — no double-sink (edge Δ=%.4f corner Δ=%.4f)" % [d_edge_before, d_corner_before])

	# Step 2: admit + commit ONLY B (the EAST neighbour). The pure EAST-edge interior node must now read the TRUE
	# height; the CORNER (still bordering the uncommitted SOUTH neighbour) legitimately stays sunk — but IDENTICALLY
	# on both A's and B's copy, so there is still no crack (the real no-one-sided-cliff invariant).
	relief._want[fid_b] = true
	relief._tiles[fid_b] = _bt(fid_b, rd.height_grid(fid_b), PackedColorArray(), relief._alloc_arena_slot(fid_b) * FOR_.VERTS_PER_TILE)
	relief._commit_dirty = true
	relief._commit()
	_ok(relief._committed_tiles.has(fid_b), "G-OR-SEAM: facet B is now committed")
	var slot_b: int = relief._fid_slot[fid_b]
	var vbase_b := slot_b * FOR_.VERTS_PER_TILE
	var a_edge_mid_after := relief._arena_pos[vbase_a + mid * stride + cells]
	var a_corner_after := relief._arena_pos[vbase_a + 0 * stride + cells]
	var b_corner_after := relief._arena_pos[vbase_b + 0 * stride + 0]     # B's (i=0,j=0) — its WEST edge, same seam node as A's corner
	_ok(a_edge_mid_after.distance_to(a_edge_mid_raw) <= EPS * scale,
		"G-OR-SEAM: once B commits, A's EAST-edge INTERIOR node self-heals to the true un-sunk height (Δ=%.4f)" % a_edge_mid_after.distance_to(a_edge_mid_raw))
	_ok(absf(a_corner_after.length() - a_corner_raw.length()) > 1.0,
		"G-OR-SEAM: the shared corner correctly STAYS sunk (its SOUTH neighbour is still uncommitted) — Δ=%.2f" % absf(a_corner_after.length() - a_corner_raw.length()))
	_ok(a_corner_after.distance_to(b_corner_after) <= EPS * scale,
		"G-OR-SEAM: A and B agree EXACTLY at the shared corner even while both still sink it — no one-sided cliff (Δ=%.6f)" % a_corner_after.distance_to(b_corner_after))

	# Step 3: commit A's remaining neighbours (S/W/N) too — every one of A's edges is now resolved, so even the
	# corner must fully self-heal — the complete closure of the self-heal property.
	for f in [fid_s, fid_w, fid_n]:
		relief._want[f] = true
		relief._tiles[f] = _bt(f, rd.height_grid(f), PackedColorArray(), relief._alloc_arena_slot(f) * FOR_.VERTS_PER_TILE)
	relief._commit_dirty = true
	var iterations := 0
	while relief._commit_dirty and iterations < 10:
		relief._commit()
		iterations += 1
	var a_corner_final := relief._arena_pos[vbase_a + 0 * stride + cells]
	_ok(a_corner_final.distance_to(a_corner_raw) <= EPS * scale,
		"G-OR-SEAM: once ALL of A's neighbours are committed, even the shared corner fully self-heals to the true height (Δ=%.4f)" % a_corner_final.distance_to(a_corner_raw))

	ring.free()

# --- G-OR-COMMIT-COST (WS1b): O(≤batch), never O(resident-set); no merge_tiles re-scan in _commit() -------------------
func _gate_commit_cost() -> void:
	# Static source check: _commit()'s body never calls FacetSmoothV2.merge_tiles (the O(resident-set) re-merge
	# the arena replaces) and never touches SurfaceTool/generate_normals (the earlier perf fix, still true).
	var f := FileAccess.open("res://src/world/facet_orbit_relief.gd", FileAccess.READ)
	_ok(f != null, "G-OR-COMMIT-COST: opened facet_orbit_relief.gd for the static source check")
	if f != null:
		var text := f.get_as_text()
		var start := text.find("func _commit()")
		_ok(start >= 0, "G-OR-COMMIT-COST: found _commit()'s definition")
		if start >= 0:
			var next_func := text.find("\nfunc ", start + 1)
			var body := text.substr(start, (next_func - start) if next_func >= 0 else -1)
			_ok(body.find("merge_tiles") == -1, "G-OR-COMMIT-COST: _commit()'s body never calls FacetSmoothV2.merge_tiles (WS1b — no whole-set re-merge)")
			_ok(body.find("SurfaceTool") == -1, "G-OR-COMMIT-COST: _commit()'s body never references SurfaceTool")
			_ok(body.find("generate_normals") == -1, "G-OR-COMMIT-COST: _commit()'s body never calls generate_normals")
			_ok(body.find("add_surface_from_arrays") != -1, "G-OR-COMMIT-COST: _commit() still commits via the SAFE high-level add_surface_from_arrays API")

	# The batch cap: mark the WHOLE 384-tile want-set as already BUILT (bypassing real dispatch — this gate only
	# needs to prove the COMMIT-time batching, not re-prove dispatch pacing, already covered by the dispatch test
	# below) and confirm ONE _commit() call folds at most ORBIT_RELIEF_COMMIT_TILES of them into the arena.
	var fid := 12
	var rd := GlobalReliefData.new()
	rd.setup()
	rd.bake_facet(fid)
	var ring := FacetFarRing.new()
	ring._active_fid = fid
	_force_offsurface(ring)
	var relief := FacetOrbitRelief.new()
	relief.setup_instance(ring, fid, rd)
	var n := CubeSphere.ORBIT_RELIEF_MAX_TILES
	var heights := rd.height_grid(fid)
	for i in range(n):
		var slot := relief._alloc_arena_slot(i)
		relief._tiles[i] = _bt(fid, heights, PackedColorArray(), slot * FOR_.VERTS_PER_TILE)
	relief._commit_dirty = true
	relief._commit()
	_ok(relief._committed_tiles.size() <= CubeSphere.ORBIT_RELIEF_COMMIT_TILES,
		"G-OR-COMMIT-COST: ONE _commit() call admits at most ORBIT_RELIEF_COMMIT_TILES(%d) of the %d-tile burst (got %d)" % [CubeSphere.ORBIT_RELIEF_COMMIT_TILES, n, relief._committed_tiles.size()])
	_ok(relief._committed_tiles.size() == CubeSphere.ORBIT_RELIEF_COMMIT_TILES,
		"G-OR-COMMIT-COST: the burst actually SATURATES the batch cap (proves this isn't a vacuous pass)")
	_ok(relief._commit_dirty, "G-OR-COMMIT-COST: still dirty after one capped commit — the rest of the burst is NOT silently dropped")
	var iterations := 0
	while relief._commit_dirty and iterations < n:
		relief._commit()
		iterations += 1
	_ok(not relief._commit_dirty and relief._committed_tiles.size() == n,
		"G-OR-COMMIT-COST: repeated capped commits eventually converge to the full %d-tile resident set (took %d more commits)" % [n, iterations])
	ring.free()

# --- G-OR-SUSPEND (WS1a): on-surface freezes everything past the initial reap --------------------------------------
func _gate_suspend() -> void:
	var fid := 12
	var rd := GlobalReliefData.new()
	rd.setup()
	rd.bake_facet(fid)
	var ring := FacetFarRing.new()
	ring._active_fid = fid
	# Deliberately do NOT call _force_offsurface — a bare ring's shell_offsurface() is false (on-surface),
	# matching the fixture this gate needs.
	_ok(not ring.shell_offsurface(), "G-OR-SUSPEND: fixture sanity — a bare ring is ON-surface by default")
	var relief := FacetOrbitRelief.new()
	relief.setup_instance(ring, fid, rd)

	# Seed some pending work as if a prior off-surface session left it queued.
	relief._want = {fid: true}
	relief._want_order = [fid]
	var before_committed := relief._committed_tiles.size()
	var before_tiles := relief._tiles.size()
	var before_want := relief._want.duplicate()

	relief.step()   # ON-surface: must be a complete no-op past the (empty) reap.

	_ok(relief._committed_tiles.size() == before_committed, "G-OR-SUSPEND: on-surface step() dispatches/commits NOTHING (committed count unchanged)")
	_ok(relief._tiles.size() == before_tiles, "G-OR-SUSPEND: on-surface step() builds NOTHING (no worker dispatch)")
	_ok(relief._want == before_want, "G-OR-SUSPEND: on-surface step() never recomputes the want-set")

	# set_active while on-surface: records the new fid, does NOT force a recompute.
	relief.set_active(fid + 1)
	_ok(relief._active_fid == fid + 1, "G-OR-SUSPEND: set_active still records the new active fid on-surface")
	_ok(relief._want == before_want, "G-OR-SUSPEND: set_active on-surface does NOT force a want-set recompute (mesh stays frozen)")

	# Now go off-surface: normal operation must resume immediately.
	_force_offsurface(ring)
	relief.step()
	_ok(not relief._want.is_empty(), "G-OR-SUSPEND: the FIRST off-surface step() recomputes a real want-set (resumes normal operation)")

	ring.free()
