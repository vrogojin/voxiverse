extends SceneTree
## COSMOS-LOD-SKY M1 gate (docs/COSMOS-LOD-SKY-DESIGN.md §2/§5/§9/§10). Proves the parts a headless gate CAN
## prove of the multi-body distance-LOD SELECTION LAW (FP_BODY_LOD) + the D_SKY O3 revisit (FP_SKY_DSKY_R):
## the relief_px law + ±25% hysteresis, the sub-pixel no-pop discipline, the N_RING_MAX far-tier byte ceiling,
## and the derived sky radius. Every assert exercises the BodyLod pure-static kernel (DEAD with the flag off) or
## the CosmosSky.d_sky_derived static — so this gate is FLAG-INDEPENDENT: it passes identically with FP_BODY_LOD
## / FP_SKY_DSKY_R true or false. What M1 CANNOT prove headless: the LOOK of detail growing on approach — that
## needs M2's real per-body RING build (this law only SELECTS + ACCOUNTS).
##
## Asserts:
##   G-BODY-LOD     the tier table over synthetic (r, e_relief, d, K_px): POINT→IMPOSTOR→RING at the right
##                  distances; the Sun (e_relief=0) NEVER leaves IMPOSTOR at any distance/zoom; a telescope
##                  (higher K_px) promotes a distant IMPOSTOR body to RING; hysteresis does not thrash in the band.
##   G-LOD-CEILING  the worst legal far-tier state (Earth dominant w/ ring+dense+skin + Moon ring + Sun impostor)
##                  ≤ the 32 MB ceiling, with the breakdown; N_RING_MAX=2 binds under a zoom sweep that promotes
##                  three bodies (dominant kept, lowest-relief evicted to impostor).
##   G-LOD-NOPOP    on a fine synthetic approach AND recession, every latched tier transition's screen-space
##                  delta ≤ its threshold (impostor⇄ring sub-pixel by TAU_POP; point⇄impostor by P_POINT), and
##                  every transition produces a G-SSE-INV log line.
##   D_SKY (O3)     CosmosSky.d_sky_derived() sits OUTSIDE the planet (> R, with headroom) and INSIDE the camera
##                  far clip (star dome radius D·STAR_DOME_MULT < CAMERA_FAR), and pushes the impostor further
##                  out than the shipped literal 8000; the shipped literal is itself still inside the far clip.
##
## RUN (flag optional — the kernel is pure statics):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_body_lod.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const SKY := preload("res://src/cosmos/cosmos_sky.gd")

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

func _initialize() -> void:
	print("=== verify_body_lod (COSMOS-LOD-SKY M1: multi-body LOD selection law + D_SKY O3) ===")
	print("  CubeSphere.FP_BODY_LOD = %s ; FP_SKY_DSKY_R = %s (gate is flag-independent; kernels are pure statics)" % [
		str(CubeSphere.FP_BODY_LOD), str(CubeSphere.FP_SKY_DSKY_R)])
	print("  law: P_POINT=%.1f px, TAU_POP=%.1f px, HYST=%.2f ; e_relief earth=%.0f moon=%.0f sun=%.0f ; N_RING_MAX=%d" % [
		BodyLod.P_POINT, BodyLod.TAU_POP, BodyLod.HYST,
		BodyLod.e_relief_of("earth"), BodyLod.e_relief_of("moon"), BodyLod.e_relief_of("sun"), BodyLod.N_RING_MAX])
	_gate_body_lod()
	_gate_ceiling()
	_gate_nopop()
	_gate_dsky()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- G-BODY-LOD: the tier table + Sun-forever-impostor + telescope + hysteresis ----------
func _gate_body_lod() -> void:
	print("  --- G-BODY-LOD: relief_px law, Sun impostor-forever, telescope promote, hysteresis no-thrash ---")
	var kpx := BodyLod.k_px(1080.0, deg_to_rad(60.0))   # DPR1-1080p-ish reference; the law is K_px-relative

	# (1) The tier table at hand-picked distances for an Earth-class body (r=6371, e=112).
	var r := EPH_radius("earth")
	var e := BodyLod.e_relief_of("earth")
	# d where relief_px == TAU_POP: d_pop = e·kpx/TAU_POP. Below ⇒ RING, comfortably above ⇒ IMPOSTOR.
	var d_pop := e * kpx / BodyLod.TAU_POP
	_ok(BodyLod.tier_raw(r, e, d_pop * 0.5, kpx) == BodyLod.RING, "G-BODY-LOD: relief_px ≥ TAU_POP (d=0.5·d_pop) ⇒ RING")
	_ok(BodyLod.tier_raw(r, e, d_pop * 2.0, kpx) == BodyLod.IMPOSTOR, "G-BODY-LOD: relief_px < TAU_POP (d=2·d_pop) ⇒ IMPOSTOR")
	# d where ang_px == P_POINT: d_point = 2r·kpx/P_POINT. Far beyond it the disc is a POINT.
	var d_point := 2.0 * r * kpx / BodyLod.P_POINT
	_ok(BodyLod.tier_raw(r, e, d_point * 2.0, kpx) == BodyLod.POINT, "G-BODY-LOD: ang_px < P_POINT (d=2·d_point) ⇒ POINT")
	_ok(BodyLod.tier_raw(r, e, d_point * 0.5, kpx) != BodyLod.POINT, "G-BODY-LOD: ang_px ≥ P_POINT (d=0.5·d_point) ⇒ not POINT (disc)")
	# The RING boundary sits FAR nearer than the POINT boundary (2r/e_relief ≫ 1) ⇒ well-separated regimes.
	_ok(d_pop < d_point, "G-BODY-LOD: d_pop (%.0f) ≪ d_point (%.0f) — RING and POINT boundaries well-separated" % [d_pop, d_point])

	# (2) The Sun (e_relief=0) NEVER leaves IMPOSTOR (nor POINT) — impostor-forever BY THE LAW. Sweep distance
	#     AND zoom (telescope): relief_px is identically 0 ⇒ never RING; only POINT (very far/tiny) or IMPOSTOR.
	var rs := EPH_radius("sun")
	var es := BodyLod.e_relief_of("sun")
	var sun_ok := true
	for zi in range(1, 6):
		var kz := BodyLod.k_px(1080.0, deg_to_rad(60.0 / float(zi)))   # progressively narrower fov (zoom in)
		for di in range(1, 40):
			var d := 1.0e5 * float(di)          # 100k .. 3.9M blocks (well past & short of the real 1.496e8)
			if BodyLod.tier_raw(rs, es, d, kz) == BodyLod.RING:
				sun_ok = false
	_ok(sun_ok, "G-BODY-LOD: Sun (e_relief=0) is IMPOSTOR/POINT at every distance AND every zoom — never RING")

	# (3) Telescope: a body that is IMPOSTOR at a reference fov is promoted to RING purely by narrowing the fov
	#     (raising K_px). Pick d just ABOVE d_pop (impostor), then zoom until relief_px crosses TAU_POP.
	var d_far := d_pop * 1.5
	_ok(BodyLod.tier_raw(r, e, d_far, kpx) == BodyLod.IMPOSTOR, "G-BODY-LOD: body at d=1.5·d_pop is IMPOSTOR at the reference fov")
	var kpx_zoom := BodyLod.k_px(1080.0, deg_to_rad(60.0 / 2.0))       # 2× zoom ⇒ K_px doubles
	_ok(BodyLod.tier_raw(r, e, d_far, kpx_zoom) == BodyLod.RING, "G-BODY-LOD: the SAME body promotes to RING under 2× telescope zoom (K_px scales the law)")

	# (4) Hysteresis no-thrash: walk a scripted distance path across the IMPOSTOR⇄RING boundary and back inside
	#     the band; assert exactly one promote + one demote, the demote only PAST the ±HYST band, and no flip
	#     while oscillating inside the band.
	var path := [
		d_pop * 2.0,          # far: IMPOSTOR
		d_pop * 1.1,          # relief 0.91: still IMPOSTOR (promote only at ≥ TAU_POP)
		d_pop * 0.9,          # relief 1.11: PROMOTE to RING
		d_pop * 1.15,         # relief 0.87 (> 0.75): STAY RING (inside the band — no thrash)
		d_pop * 1.2,          # relief 0.83 (> 0.75): STAY RING
		d_pop * 1.1,          # relief 0.91: STAY RING
		d_pop * 1.5,          # relief 0.67 (< 0.75): DEMOTE to IMPOSTOR
	]
	var expect := [BodyLod.IMPOSTOR, BodyLod.IMPOSTOR, BodyLod.RING, BodyLod.RING, BodyLod.RING, BodyLod.RING, BodyLod.IMPOSTOR]
	var cur := BodyLod.IMPOSTOR
	var transitions := 0
	var band_flip := false
	for i in range(path.size()):
		var next := BodyLod.tier_hyst(cur, r, e, float(path[i]), kpx)
		if next != cur:
			transitions += 1
		if next != int(expect[i]):
			band_flip = true
		cur = next
	_ok(not band_flip, "G-BODY-LOD: hysteresis latches the expected tier at every step of the scripted path")
	_ok(transitions == 2, "G-BODY-LOD: exactly 2 transitions (1 promote + 1 demote) across the band round-trip — no thrash (got %d)" % transitions)

# ---------- G-LOD-CEILING: the 32 MB far-tier ceiling + N_RING_MAX under zoom ----------
func _gate_ceiling() -> void:
	print("  --- G-LOD-CEILING: worst legal far-tier state ≤ 32 MB ; N_RING_MAX binds under zoom ---")

	# The worst LEGAL resident state (§5): Earth dominant at ground (its full shell stack — ring + dense + skin
	# all resident, the near voxel pool is the SEPARATE 128 MB), Moon's ring resident, Sun impostor.
	var states := [
		{"body": "earth", "tier": BodyLod.VOXEL, "dominant": true},
		{"body": "moon", "tier": BodyLod.RING, "dominant": false},
		{"body": "sun", "tier": BodyLod.IMPOSTOR, "dominant": false},
	]
	var total := BodyLod.far_tier_bytes(states)
	var mb := 1048576.0
	print("    ledger: earth(dom,voxel)=%.2f MB  moon(ring)=%.2f MB  sun(imp)=%.2f MB  atmo=%.2f MB  TOTAL=%.2f MB / ceiling %.0f MB" % [
		BodyLod.body_far_tier_bytes("earth", BodyLod.VOXEL, true) / mb,
		BodyLod.body_far_tier_bytes("moon", BodyLod.RING, false) / mb,
		BodyLod.body_far_tier_bytes("sun", BodyLod.IMPOSTOR, false) / mb,
		BodyLod.ATMO_SHELL_BYTES / mb, total / mb, BodyLod.FAR_TIER_CEILING_BYTES / mb])
	_ok(total <= BodyLod.FAR_TIER_CEILING_BYTES, "G-LOD-CEILING: worst legal far-tier total %.2f MB ≤ 32 MB ceiling" % (total / mb))
	# The ring is the only per-facet-scaling structure — confirm the per-body ledger reproduces the design (§3):
	_ok(_rel(BodyLod.ring_bytes("earth") / mb, 10.07) < 0.05, "G-LOD-CEILING: Earth ring resident %.2f MB ≈ 10.07 (7.3 GPU + 2.77 CPU, 3456 facets)" % (BodyLod.ring_bytes("earth") / mb))
	_ok(_rel(BodyLod.ring_bytes("moon") / mb, 3.43) < 0.05, "G-LOD-CEILING: Moon ring resident %.2f MB ≈ 3.43 (1176 facets)" % (BodyLod.ring_bytes("moon") / mb))
	_ok(BodyLod.ring_bytes("sun") == 0.0, "G-LOD-CEILING: Sun has no ring (0 bytes) — impostor-only body")

	# A future 8-body impostor table (§5: impostors ≤ 0.4 MB) plus Earth+Moon rings still clears the ceiling.
	var many := [{"body": "earth", "tier": BodyLod.VOXEL, "dominant": true}, {"body": "moon", "tier": BodyLod.RING, "dominant": false}]
	for i in range(6):
		many.append({"body": "b%d" % i, "tier": BodyLod.IMPOSTOR, "dominant": false})
	_ok(BodyLod.far_tier_bytes(many) <= BodyLod.FAR_TIER_CEILING_BYTES, "G-LOD-CEILING: Earth+Moon rings + 8-body impostor table still ≤ 32 MB (%.2f MB)" % (BodyLod.far_tier_bytes(many) / mb))

	# N_RING_MAX: three bodies all want a ring (a telescope zoom promotes them at once). Only N_RING_MAX may be
	# RESIDENT: the dominant always + the highest relief_px non-dominant; the lowest-relief is evicted to impostor.
	var wants := ["earth", "moon", "venus"]
	var relief := {"earth": 9.0, "venus": 5.0, "moon": 3.0}   # dominant (earth) + venus (higher relief) win the 2 slots
	var granted := BodyLod.select_ring_bodies(wants, relief, "earth")
	_ok(granted.size() == BodyLod.N_RING_MAX, "G-LOD-CEILING: 3 bodies want rings ⇒ exactly N_RING_MAX=%d resident (got %d)" % [BodyLod.N_RING_MAX, granted.size()])
	_ok("earth" in granted, "G-LOD-CEILING: the dominant body always keeps its ring")
	_ok("venus" in granted and not ("moon" in granted), "G-LOD-CEILING: the higher-relief non-dominant (venus) is kept; the lowest (moon) is evicted")
	_ok(BodyLod.present_tier("moon", BodyLod.RING, granted) == BodyLod.IMPOSTOR, "G-LOD-CEILING: the evicted body presents IMPOSTOR (the v1 third-body limit)")
	_ok(BodyLod.present_tier("venus", BodyLod.RING, granted) == BodyLod.RING, "G-LOD-CEILING: a granted body presents its law tier (RING)")

# ---------- G-LOD-NOPOP: every transition sub-pixel + logged, on approach and recession ----------
func _gate_nopop() -> void:
	print("  --- G-LOD-NOPOP: every tier transition ≤ its px threshold (sub-pixel) + G-SSE-INV logged ---")
	var kpx := BodyLod.k_px(1080.0, deg_to_rad(60.0))
	var r := EPH_radius("earth")
	var e := BodyLod.e_relief_of("earth")

	# Approach: d from far (POINT) down to near (RING) in fine multiplicative steps (0.1%/step) so a transition
	# overshoots its threshold by ≤ 0.1%. Every latched change: assert its screen-space delta ≤ threshold·1.02.
	var worst_ratio := 0.0
	var seen := {}
	var cur := BodyLod.POINT
	var d := 2.0 * r * kpx / BodyLod.P_POINT * 4.0    # start well beyond the POINT boundary
	var d_stop := e * kpx / BodyLod.TAU_POP * 0.4     # end well inside the RING regime
	while d > d_stop:
		var next := BodyLod.tier_hyst(cur, r, e, d, kpx)
		if next != cur:
			var delta := BodyLod.swap_delta_px(cur, next, r, e, d, kpx)
			var thr := BodyLod.swap_threshold(cur, next)
			worst_ratio = maxf(worst_ratio, delta / thr)
			var line := BodyLod.transition_log("earth", cur, next, d, BodyLod.relief_px(e, d, kpx))
			seen[str(cur) + "->" + str(next)] = line
			cur = next
		d *= 0.999
	_ok(worst_ratio <= 1.02, "G-LOD-NOPOP: approach — every transition delta ≤ 1.02·threshold (worst %.4f·thr, sub-pixel by the law)" % worst_ratio)
	_ok(cur == BodyLod.RING, "G-LOD-NOPOP: approach ended in RING (full POINT→IMPOSTOR→RING ladder traversed)")
	_ok(seen.has(str(BodyLod.POINT) + "->" + str(BodyLod.IMPOSTOR)), "G-LOD-NOPOP: POINT→IMPOSTOR transition observed + logged")
	_ok(seen.has(str(BodyLod.IMPOSTOR) + "->" + str(BodyLod.RING)), "G-LOD-NOPOP: IMPOSTOR→RING transition observed + logged")
	# The log line is a real G-SSE-INV record (body + tier names + relief_px).
	var sample := String(seen[str(BodyLod.IMPOSTOR) + "->" + str(BodyLod.RING)])
	_ok(sample.contains("G-SSE-INV") and sample.contains("IMPOSTOR->RING") and sample.contains("earth"), "G-LOD-NOPOP: the transition log is a G-SSE-INV line: '%s'" % sample)

	# Recession: d increasing — demotes fire BELOW threshold (past the hysteresis band) ⇒ delta strictly ≤ thr.
	var worst_rec := 0.0
	cur = BodyLod.RING
	d = e * kpx / BodyLod.TAU_POP * 0.4
	var d_top := 2.0 * r * kpx / BodyLod.P_POINT * 4.0
	while d < d_top:
		var next := BodyLod.tier_hyst(cur, r, e, d, kpx)
		if next != cur:
			var delta := BodyLod.swap_delta_px(cur, next, r, e, d, kpx)
			var thr := BodyLod.swap_threshold(cur, next)
			worst_rec = maxf(worst_rec, delta / thr)
			cur = next
		d *= 1.001
	_ok(worst_rec <= 1.0 + 1.0e-6, "G-LOD-NOPOP: recession — every demote delta ≤ threshold (worst %.4f·thr; demotes fire below the band)" % worst_rec)
	_ok(cur == BodyLod.POINT, "G-LOD-NOPOP: recession ended in POINT (full ladder traversed down)")

# ---------- D_SKY (O3): the derived sky radius sits outside the planet and inside the far clip ----------
func _gate_dsky() -> void:
	print("  --- D_SKY (O3): derived radius outside the planet AND inside the camera far clip ---")
	var R := FacetAtlas.R_BLOCKS
	var far := FacetFarRing.CAMERA_FAR
	var derived := SKY.d_sky_derived()
	var dome := derived * SKY.STAR_DOME_MULT
	print("    R=%.0f  CAMERA_FAR=%.0f  D_SKY(shipped)=%.0f  d_sky_derived=%.1f  star_dome_edge=%.1f  (derived/R=%.3f, shipped/R=%.3f)" % [
		R, far, SKY.D_SKY, derived, dome, derived / R, SKY.D_SKY / R])
	# Outside the planet, with headroom (> 1.2·R). Inside the far clip, with the dome fully inside by margin.
	_ok(derived > R, "D_SKY: derived %.1f > R %.0f (impostor sits OUTSIDE the planet)" % [derived, R])
	_ok(derived > R * 1.2, "D_SKY: derived > 1.2·R (headroom outside the planet)")
	_ok(dome < far, "D_SKY: star dome edge %.1f < CAMERA_FAR %.0f (inside the far clip — no clipping)" % [dome, far])
	_ok(dome <= far * SKY.SKY_FAR_MARGIN + 1.0, "D_SKY: star dome edge ≤ %.0f%% of the far clip (stated margin)" % (SKY.SKY_FAR_MARGIN * 100.0))
	# The O3 fix pushes the impostor FURTHER out than the stale literal 8000 (raising the R-multiple).
	_ok(derived > SKY.D_SKY, "D_SKY: derived %.1f > shipped literal %.0f (improves the R-multiple post-rescale)" % [derived, SKY.D_SKY])
	# Flag-off safety: the shipped literal's own star dome is also inside the far clip (byte-identical path safe).
	_ok(SKY.D_SKY * SKY.STAR_DOME_MULT < far, "D_SKY: shipped literal 8000's star dome (%.0f) also < CAMERA_FAR (flag-off path safe)" % (SKY.D_SKY * SKY.STAR_DOME_MULT))
	# Derivation is exactly CAMERA_FAR·margin/mult (tracks the far plane; can never clip).
	_ok(_rel(derived, far * SKY.SKY_FAR_MARGIN / SKY.STAR_DOME_MULT) < 1.0e-9, "D_SKY: derived == CAMERA_FAR·SKY_FAR_MARGIN/STAR_DOME_MULT (tracks the far plane)")

# CosmosEphemeris body radius (blocks) — small helper so the gate reads the same table the law consumes.
func EPH_radius(body: String) -> float:
	return CosmosEphemeris.radius_of(body)
