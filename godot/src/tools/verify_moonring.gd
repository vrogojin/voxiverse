extends SceneTree
## COSMOS-LOD-SKY M2 gate (docs/COSMOS-LOD-SKY-DESIGN.md §3/§5/§9 stage M2) — the Moon far-ring (FP_MOON_RING).
## Proves the headless-provable parts of the Moon's body-parameterized coarse ring: it builds the RIGHT facet set
## (the Moon body's fid range, front-hemisphere culled), valid cratered terrain at the Moon datum, correct moon
## regolith/maria/highlands colours; the real bytes fit the §3 budget (≤ 2.5 MB GPU + 0.94 MB CPU) and free to
## ZERO on eviction; and the IMPOSTOR→RING handover is sub-pixel + G-SSE-INV logged (the BodyLod law for the Moon).
##
## The ring build (MoonFarRing) is exercised DIRECTLY — like BodyLod, its geometry is engine-static once the atlas
## is warmed, so this gate drives build/evict/budget without the live sky node. What M2 CANNOT prove headless: the
## LOOK of the Moon (oriented right, cratered, detail growing on approach) — that needs a real-GPU fly (LIVE-ONLY).
##
## Gates:
##   G-MOON-RING         builds only the Moon body's fids, front-hemisphere culled (the axis facet in, the antipode
##                       out); tri count == emitted·32; vertices at the Moon datum with real cratered relief; colours
##                       desaturated grey (regolith/maria/highlands), never an Earth green/blue.
##   G-MOON-RING-BUDGET  real GPU mesh bytes ≤ 2.5 MB, real CPU cache bytes ≤ 0.94 MB, both inside BodyLod's Moon
##                       ledger; evict() frees GPU + CPU to ZERO (the lifetime cap — nothing outlives the ring).
##   G-MOON-RING-NOPOP   the Moon is IMPOSTOR at its true orbit (relief_px < TAU_POP); a synthetic approach promotes
##                       it IMPOSTOR→RING sub-pixel (delta ≤ TAU_POP·1.02) with a G-SSE-INV "moon" log line.
##
## RUN (the runner sed-toggles MULTI_BODY := true + FP_MOON_RING := true; the build/budget gates REQUIRE the Moon
## facets to exist, so they need MULTI_BODY on — the no-pop law gate is flag-independent):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_moonring.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const _MB := 1048576.0
const GPU_BUDGET := 2.5 * _MB
const CPU_BUDGET := 0.94 * _MB

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_moonring (COSMOS-LOD-SKY M2: FP_MOON_RING) — MULTI_BODY=%s FP_MOON_RING=%s FP_BODY_LOD=%s ===" % [
		str(CubeSphere.MULTI_BODY), str(CubeSphere.FP_MOON_RING), str(CubeSphere.FP_BODY_LOD)])
	TerrainConfig.warm_up()
	FacetAtlas.warm_up()

	_gate_nopop()                                    # flag-independent (the BodyLod Moon law)
	if CubeSphere.MULTI_BODY:
		_gate_ring()
		_gate_budget()
		if CubeSphere.FP_MOON_RING:
			_gate_wiring()
	else:
		_ok(false, "verify_moonring: build/budget gates need MULTI_BODY=true (sed-toggle it, like verify_multibody)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# Build a ring aimed at moon facet `fid`'s own centre direction (so that facet is guaranteed emitted), returning
# [ring, axis, fid_base, fid_end]. Standalone (no SceneTree) — the geometry is engine-static once warmed.
func _make_ring() -> Array:
	var bi := FacetAtlas.body_index("moon")
	var ring := MoonFarRing.new()
	ring.setup(bi)
	var base := ring.fid_base()
	var end := ring.fid_end()
	# The axis = the centre direction of a facet near the middle of the Moon range (a well-interior front facet).
	var mid := base + (end - base) / 2
	var cd := _centre_dir(mid)
	ring.build(cd)
	return [ring, cd, base, end, mid]

func _centre_dir(fid: int) -> Array:
	var s := [0.0, 0.0, 0.0]
	for ci in range(4):
		var c := FacetAtlas.facet_planar_corner(fid, ci)
		s[0] += c[0]; s[1] += c[1]; s[2] += c[2]
	var ln: float = sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2])
	return [s[0] / ln, s[1] / ln, s[2] / ln]

# ---------- G-MOON-RING: right facet set + valid cratered terrain + moon colours ----------
func _gate_ring() -> void:
	print("  --- G-MOON-RING: Moon-body fid set, front-hemisphere cull, cratered terrain, grey palette ---")
	var r := _make_ring()
	var ring: MoonFarRing = r[0]
	var axis: Array = r[1]
	var base: int = r[2]
	var end: int = r[3]
	var mid: int = r[4]
	var total := end - base
	_ok(total == 6 * 14 * 14, "G-MOON-RING: Moon body has 6·14²=%d facets (got %d)" % [6 * 14 * 14, total])
	_ok(ring.is_built(), "G-MOON-RING: ring built")

	# Only the Moon body's fids are emitted, and the axis facet is in, the antipode out (front-hemisphere cull).
	var all_moon := true
	for fid in range(base, end):
		if ring.is_emitted(fid) and (fid < base or fid >= end):
			all_moon = false
	_ok(all_moon, "G-MOON-RING: every emitted facet lies in the Moon fid range [%d, %d)" % [base, end])
	_ok(ring.is_emitted(mid), "G-MOON-RING: the axis facet (fid %d) is emitted (front-facing)" % mid)
	var emit := ring.emitted_count()
	_ok(emit > 0 and emit < total, "G-MOON-RING: front-hemisphere cull keeps a strict subset (%d of %d facets)" % [emit, total])
	# The antipodal facet (centre dir ≈ −axis) must be culled.
	var anti := -1
	var worst := 2.0
	for fid in range(base, end):
		var cd := _centre_dir(fid)
		var dp: float = cd[0] * axis[0] + cd[1] * axis[1] + cd[2] * axis[2]
		if dp < worst:
			worst = dp; anti = fid
	_ok(anti >= 0 and not ring.is_emitted(anti), "G-MOON-RING: the antipodal facet (fid %d, dot %.3f) is culled" % [anti, worst])

	# Tri count == emitted · (CELLS²·2) = emitted · 32.
	var expect_tris := emit * MoonFarRing.CELLS * MoonFarRing.CELLS * 2
	_ok(ring.triangle_count() == expect_tris, "G-MOON-RING: tri count == emitted·32 (%d, got %d)" % [expect_tris, ring.triangle_count()])

	# Valid cratered terrain: vertices sit at the Moon datum + relief, and the relief SPREADS (not a flat sphere).
	var arrs := ring._mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
	var r_moon := CosmosEphemeris.radius_of("moon")
	var rmin := 1.0e18; var rmax := -1.0e18
	for v in verts:
		var d: float = v.length()
		rmin = minf(rmin, d); rmax = maxf(rmax, d)
	_ok(rmin > r_moon * 0.98 and rmax < r_moon + TerrainConfig.MOON_CEIL_Y + 6.0,
		"G-MOON-RING: vertices at Moon scale (|v| ∈ [%.0f, %.0f], datum %.0f)" % [rmin, rmax, r_moon])
	_ok(rmax - rmin > 10.0, "G-MOON-RING: real relief spread %.1f blocks (cratered terrain, not a flat sphere)" % (rmax - rmin))

	# Colours: desaturated grey (regolith/maria/highlands) — never an Earth green/blue. Sample across the mesh.
	var cols: PackedColorArray = arrs[Mesh.ARRAY_COLOR]
	var max_sat := 0.0
	var i := 0
	while i < cols.size():
		var c: Color = cols[i]
		var sat: float = maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b))
		max_sat = maxf(max_sat, sat)
		i += 337                                     # coprime stride — samples spread across facets
	_ok(max_sat < 0.12, "G-MOON-RING: all sampled colours desaturated (max channel spread %.3f < 0.12 — grey moon)" % max_sat)

	# Distinct maria vs highlands (the palette actually varies with biome, not one flat grey).
	var m_col := FarPalette.moon_color_for(TerrainConfig.B_MOON_MARIA)
	var h_col := FarPalette.moon_color_for(TerrainConfig.B_MOON_HIGHLANDS)
	_ok(h_col.r - m_col.r > 0.05, "G-MOON-RING: highlands (%.2f) brighter than maria (%.2f) — biome palette varies" % [h_col.r, m_col.r])

# ---------- G-MOON-RING-BUDGET: real bytes ≤ budget + freed to zero on evict ----------
func _gate_budget() -> void:
	print("  --- G-MOON-RING-BUDGET: real bytes ≤ 2.5 MB GPU + 0.94 MB CPU ; freed to zero on evict ---")
	var r := _make_ring()
	var ring: MoonFarRing = r[0]
	var gpu := ring.gpu_bytes()
	var real := ring.mesh_array_bytes()
	var cpu := ring.cpu_bytes()
	print("    emitted=%d facets  tris=%d  GPU(ledger)=%.3f MB  GPU(real arrays)=%.3f MB  CPU(caches)=%.3f MB" % [
		ring.emitted_count(), ring.triangle_count(), gpu / _MB, real / _MB, cpu / _MB])
	_ok(gpu <= GPU_BUDGET, "G-MOON-RING-BUDGET: GPU ledger %.3f MB ≤ 2.5 MB" % (gpu / _MB))
	_ok(real <= GPU_BUDGET, "G-MOON-RING-BUDGET: real mesh arrays %.3f MB ≤ 2.5 MB" % (real / _MB))
	_ok(cpu <= CPU_BUDGET, "G-MOON-RING-BUDGET: CPU caches %.3f MB ≤ 0.94 MB" % (cpu / _MB))
	_ok(float(gpu + cpu) <= BodyLod.ring_bytes("moon"), "G-MOON-RING-BUDGET: GPU+CPU %.3f MB ≤ BodyLod Moon ledger %.3f MB" % [
		float(gpu + cpu) / _MB, BodyLod.ring_bytes("moon") / _MB])

	# Free the WHOLE ring on eviction — nothing outlives it (the NEVER-OOM lifetime cap).
	ring.evict()
	_ok(not ring.is_built(), "G-MOON-RING-BUDGET: evict() clears the built flag")
	_ok(ring.gpu_bytes() == 0 and ring.mesh_array_bytes() == 0, "G-MOON-RING-BUDGET: GPU bytes freed to ZERO on evict")
	_ok(ring.cpu_bytes() == 0, "G-MOON-RING-BUDGET: CPU cache bytes freed to ZERO on evict")
	_ok(ring.triangle_count() == 0 and ring.emitted_count() == 0, "G-MOON-RING-BUDGET: mesh + emitted set empty after evict")

# ---------- G-MOON-RING-WIRE: CosmosSky builds + drives the ring without crashing (live-path smoke) ----------
func _gate_wiring() -> void:
	print("  --- G-MOON-RING-WIRE: CosmosSky creates + drives the Moon ring node (live wiring smoke) ---")
	var sky := CosmosSky.new()
	get_root().add_child(sky)
	sky.setup(null, null, null)                      # null clock ⇒ t=0; _build_nodes + one _update_sky run inside
	var mr: MoonFarRing = sky.moon_ring()
	_ok(mr != null, "G-MOON-RING-WIRE: CosmosSky built the MoonFarRing node under FP_MOON_RING + MULTI_BODY")
	# At the true orbit the law says IMPOSTOR ⇒ the ring stays unbuilt and the impostor visible — and driving
	# _update_sky several times must not crash (the tier<RING branch: evict-if-built + impostor visible).
	for _i in range(3):
		sky._update_sky(0.0)
	if mr != null:
		_ok(not mr.is_built(), "G-MOON-RING-WIRE: Moon stays IMPOSTOR at true orbit (ring not built) — no crash driving _update_sky")
	sky.free()

# ---------- G-MOON-RING-NOPOP: the Moon impostor→ring handover is sub-pixel + logged ----------
func _gate_nopop() -> void:
	print("  --- G-MOON-RING-NOPOP: Moon IMPOSTOR at true orbit; approach promotes sub-pixel + G-SSE-INV logged ---")
	var kpx := BodyLod.k_px(1080.0, deg_to_rad(70.0))
	var r := CosmosEphemeris.radius_of("moon")
	var e := BodyLod.e_relief_of("moon")

	# At the true ~384.4 k orbit the Moon is IMPOSTOR (relief_px ≪ 1) — the shipped disc, no ring (M1 fact).
	var d_orbit := 384400.0
	var rp_orbit := BodyLod.relief_px(e, d_orbit, kpx)
	_ok(BodyLod.tier_raw(r, e, d_orbit, kpx) == BodyLod.IMPOSTOR, "G-MOON-RING-NOPOP: Moon at 384.4k orbit is IMPOSTOR (relief_px %.3f < TAU_POP)" % rp_orbit)

	# The distance where relief_px == TAU_POP — the ring-BUILD threshold. e·kpx/TAU_POP.
	var d_pop := e * kpx / BodyLod.TAU_POP
	print("    d_pop(relief_px==1) ≈ %.0f blocks (ring builds inside this on approach)" % d_pop)
	_ok(d_pop < d_orbit, "G-MOON-RING-NOPOP: the ring-build distance (%.0f) is well inside the orbit (%.0f)" % [d_pop, d_orbit])

	# Fine synthetic approach: every latched transition sub-pixel; capture the IMPOSTOR→RING G-SSE-INV line.
	var worst := 0.0
	var cur := BodyLod.POINT
	var d := 2.0 * r * kpx / BodyLod.P_POINT * 4.0
	var d_stop := d_pop * 0.4
	var imp_ring_line := ""
	while d > d_stop:
		var next := BodyLod.tier_hyst(cur, r, e, d, kpx)
		if next != cur:
			var delta := BodyLod.swap_delta_px(cur, next, r, e, d, kpx)
			var thr := BodyLod.swap_threshold(cur, next)
			worst = maxf(worst, delta / thr)
			if cur == BodyLod.IMPOSTOR and next == BodyLod.RING:
				imp_ring_line = BodyLod.transition_log("moon", cur, next, d, BodyLod.relief_px(e, d, kpx))
			cur = next
		d *= 0.999
	_ok(worst <= 1.02, "G-MOON-RING-NOPOP: every approach transition ≤ 1.02·threshold (worst %.4f — sub-pixel by the law)" % worst)
	_ok(cur == BodyLod.RING, "G-MOON-RING-NOPOP: approach ends in RING (the ring is presented at close range)")
	_ok(imp_ring_line.contains("G-SSE-INV") and imp_ring_line.contains("IMPOSTOR->RING") and imp_ring_line.contains("moon"),
		"G-MOON-RING-NOPOP: the handover logs a G-SSE-INV line: '%s'" % imp_ring_line)
