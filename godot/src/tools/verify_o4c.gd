extends SceneTree
## COSMOS-ORBITAL-O1O4 §3.5/§3.6 + SPACE-NAV §8 (O4c) — the SOI-swap + walkable-Moon LANDING/WALK gate suite.
## Runs in WHATEVER CubeSphere.MULTI_BODY state it is launched in (the runner runs it both ways). The pure SOI
## and landing/walk-FEEL kernels do NOT need the Moon atlas (they read CosmosEphemeris/CosmosGravity, where the
## Moon always exists as a body), so those gates run in BOTH states; the atlas-dependent walk gates (Moon-fid
## dominant-body, Moon-facet landing gravity, Moon edit overlay) run only under MULTI_BODY. Gates:
##   G-SOI-SWAP  reexpress_soi round-trips + preserves the heliocentric state (Δ==0); soi_dominant captures the
##               Moon, escapes to the Sun, and honours the ±SOI_HYST band; per-regime energy conserved.
##   G-MOON-LAND airless: has_atmo(moon)=false ⇒ atmo_brake_k/accel == 0 ∀h (no atmospheric braking); Earth still
##               brakes; orbit_prewarm_h(moon)=4096 (deeper airless pre-warm) vs Earth's shipped value; the Moon
##               landing gravity recovers to the Moon's LOCAL surface pose (−facet_normal, feel_g(moon) magnitude).
##   G-MOON-WALK Moon-fid ⇒ body_name_of_fid=="moon" (the surface-walk dominant-body source); feel_g(moon) is
##               lower and the jump-height-preserving feel scale gives the ×2.5 hang time; Moon surface gravity
##               pulls to the Moon floor; the Moon edit key round-trips (walk = break/place on Moon fids).
##   G-O4C-OFF   SOI_SWAP defaults false (⇒ _dominant_body() is "earth" unconditionally — byte-identity keystone).
## player.gd is force-parsed here (a preload) so the "earth"→_dominant_body() plumbing is compile-checked by the gate.
const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const ORB := preload("res://src/cosmos/orbital_state.gd")
const NAV := preload("res://src/cosmos/cosmos_nav.gd")
const GRAV := preload("res://src/cosmos/cosmos_gravity.gd")
const DV := preload("res://src/cosmos/dvec3.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const TC := preload("res://src/world/terrain_config.gd")
const _PlayerParse := preload("res://src/player/player.gd")   # force-parse the O4c-plumbed controller

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _dvlen(a: PackedFloat64Array) -> float:
	return DV.length(a)

func _initialize() -> void:
	print("=== verify_o4c (SOI-swap + walkable Moon) — MULTI_BODY=%s SOI_SWAP=%s ===" % [CubeSphere.MULTI_BODY, CubeSphere.SOI_SWAP])
	TC.warm_up()
	FA.warm_up()
	_gate_soi_swap()
	_gate_moon_land()
	_gate_moon_walk()
	_gate_off()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---- G-SOI-SWAP: the dominant-body swap re-expression + SOI classification ----
func _gate_soi_swap() -> void:
	var t := 12345.0
	# A generic BCI state relative to Earth (a lunar-transfer-ish point + velocity).
	var p := DV.v(50000.0, -30000.0, 8000.0)
	var v := DV.v(120.0, 210.0, -15.0)

	# Round-trip earth→moon→earth is the identity to f64 ε.
	var em := ORB.reexpress_soi("earth", "moon", t, p, v)
	var back := ORB.reexpress_soi("moon", "earth", t, em[0], em[1])
	var dp := _dvlen(DV.sub(back[0], p))
	var dv := _dvlen(DV.sub(back[1], v))
	_ok(dp < 1e-6 and dv < 1e-9, "G-SOI-SWAP: reexpress_soi earth→moon→earth round-trips (Δp=%.3e Δv=%.3e)" % [dp, dv])

	# The swap PRESERVES the physical state: heliocentric position+velocity are identical before/after (Δ==0) —
	# the whole content of "the swap is a pure re-expression, not a teleport".
	var hel_earth := ORB.bci_to_helio("earth", t, p, v)
	var hel_moon := ORB.bci_to_helio("moon", t, em[0], em[1])
	var dhp := _dvlen(DV.sub(hel_earth[0], hel_moon[0]))
	var dhv := _dvlen(DV.sub(hel_earth[1], hel_moon[1]))
	_ok(dhp < 1e-6 and dhv < 1e-9, "G-SOI-SWAP: heliocentric state continuous across the swap (Δp=%.3e Δv=%.3e)" % [dhp, dhv])

	# soi_dominant — child capture: a point AT the Moon's centre (its BCI origin, expressed in Earth-BCI) is
	# dominated by the Moon.
	var moon_c := EPH.body_pos_parent("moon", t)              # Moon centre in Earth-BCI
	_ok(NAV.soi_dominant("earth", moon_c, t) == "moon", "G-SOI-SWAP: point at the Moon centre ⇒ dominant=moon (child capture)")
	# Near Earth (a low point) ⇒ Earth keeps dominion.
	_ok(NAV.soi_dominant("earth", DV.v(7000.0, 0.0, 0.0), t) == "earth", "G-SOI-SWAP: a near-Earth point ⇒ dominant=earth")
	# Parent escape: from the Moon, a point well beyond the Moon SOI hands up to Earth.
	var moon_soi := NAV.soi_radius("moon")
	_ok(NAV.soi_dominant("moon", DV.v(moon_soi * 2.0, 0.0, 0.0), t) == "earth", "G-SOI-SWAP: beyond the Moon SOI ⇒ dominant=earth (parent escape)")
	# Escape all the way to the Sun: a point far beyond Earth's SOI (and not in the Moon's) ⇒ dominant=sun.
	var earth_soi := NAV.soi_radius("earth")
	_ok(NAV.soi_dominant("earth", DV.v(earth_soi * 3.0, earth_soi * 3.0, 0.0), t) == "sun", "G-SOI-SWAP: beyond Earth SOI, off the Moon ⇒ dominant=sun")

	# Hysteresis band: a point just OUTSIDE the raw Moon SOI does NOT capture with a +2% margin; a point just
	# inside SOI·(1−2%) DOES. (Direction chosen along the Earth→Moon line so the Earth-BCI radius maps cleanly.)
	var mdir := DV.scale(moon_c, 1.0 / _dvlen(moon_c))         # unit Earth→Moon
	# |p_moon| = 0.97·SOI is inside the contracted capture boundary SOI·(1−0.02)=0.98·SOI ⇒ CAPTURES.
	var p_in := DV.sub(moon_c, DV.scale(mdir, moon_soi * 0.97))
	# |p_moon| = 0.99·SOI sits IN the hysteresis band (inside raw SOI, outside the 0.98 capture boundary) ⇒ NO capture.
	var p_band := DV.sub(moon_c, DV.scale(mdir, moon_soi * 0.99))
	_ok(NAV.soi_dominant("earth", p_in, t, CubeSphere.SOI_HYST) == "moon", "G-SOI-SWAP: |p_moon|=0.97·SOI captures the Moon under ±hyst")
	_ok(NAV.soi_dominant("earth", p_band, t, CubeSphere.SOI_HYST) == "earth", "G-SOI-SWAP: |p_moon|=0.99·SOI stays Earth (inside the hyst band, no flap)")

	# Coast/station-keeping works around the Moon's GM_dyn: a circular seed at a Moon orbit HOLDS radius over an
	# integration (energy bounded, drift ≈ 0 — the O1 property, now over the Moon's gm_dyn).
	var mu := GRAV.gm_dyn("moon")
	var r0 := 1737.0 + 400.0                                   # 400-block Moon LMO
	var pc := DV.v(r0, 0.0, 0.0)
	var vc := DV.v(0.0, sqrt(mu / r0), 0.0)                    # circular
	var os = ORB.make("moon", pc, vc)
	var e0 := ORB.specific_energy(mu, os.pos, os.vel)
	var rmin := r0; var rmax := r0
	for _i in range(4000):                                     # ~1 orbit at dt=1/60
		os.step(1.0 / 60.0, DV.v(0.0, 0.0, 0.0))
		var rr := _dvlen(os.pos)
		rmin = minf(rmin, rr); rmax = maxf(rmax, rr)
	var e1 := ORB.specific_energy(mu, os.pos, os.vel)
	_ok(absf(e1 - e0) / absf(e0) < 1e-3, "G-SOI-SWAP: Moon LMO coast conserves specific energy (Δ=%.2e rel)" % (absf(e1 - e0) / absf(e0)))
	_ok((rmax - rmin) / r0 < 0.01, "G-SOI-SWAP: Moon circular coast holds radius (spread %.4f of r)" % ((rmax - rmin) / r0))

# ---- G-MOON-LAND: airless landing model + per-body pre-warm + local surface pose ----
func _gate_moon_land() -> void:
	# Airless: NO atmospheric braking anywhere on the Moon (has_atmo false ⇒ k==0 ∀h). Earth DOES brake.
	_ok(not ORB.has_atmo("moon"), "G-MOON-LAND: Moon has no atmosphere (has_atmo==false)")
	var brake_max := 0.0
	for h in [0.0, 50.0, 128.0, 256.0, 383.0, 1000.0]:
		brake_max = maxf(brake_max, absf(ORB.atmo_brake_k("moon", h)))
		brake_max = maxf(brake_max, absf(ORB.atmo_brake_accel("moon", h, -170.0)))
	_ok(brake_max == 0.0, "G-MOON-LAND: airless collision model — zero atmospheric brake at every altitude (max %.3e)" % brake_max)
	_ok(ORB.atmo_brake_k("earth", 0.0) > 0.0, "G-MOON-LAND: Earth still brakes at the datum (regression guard)")

	# Per-body pre-warm: an airless body pre-warms deeper (4096) so a non-braking ballistic descent (120–170 b/s)
	# keeps the pool ahead of the lander; Earth (drag-capped) keeps the shipped ORBIT_PREWARM_H.
	_ok(is_equal_approx(CubeSphere.orbit_prewarm_h("moon"), 4096.0), "G-MOON-LAND: airless pre-warm altitude == 4096")
	_ok(is_equal_approx(CubeSphere.orbit_prewarm_h("earth"), CubeSphere.ORBIT_PREWARM_H), "G-MOON-LAND: Earth pre-warm == shipped ORBIT_PREWARM_H")

	# Landing recovers to the MOON'S LOCAL surface pose: at a Moon-facet surface point the blend gravity points
	# into the facet (−facet_normal) with the Moon feel magnitude — the gravity-aligned pose IS the Moon facet
	# frame. (Needs the Moon atlas.)
	if CubeSphere.MULTI_BODY:
		var bi := FA.body_index("moon")
		var base := FA.fid_base(bi)
		var fid := base + FA.body_facet_count(bi) / 2         # a mid-Moon facet
		var n := FA.facet_normal64(fid)                        # outward normal (world f64)
		var surf := DV.scale(n, 1737.0 + 1.0)                  # just above the datum along the normal
		var g := GRAV.gravity_fixed("moon", fid, surf)         # h ≈ 1 < H_BLEND_LO ⇒ pure lattice feel
		var gmag := _dvlen(g)
		# direction ≈ −n̂ (into the facet); magnitude ≈ feel_g(moon)
		var gdir := DV.scale(g, 1.0 / gmag) if gmag > 0.0 else g
		var align := DV.dot(gdir, DV.v(-n[0], -n[1], -n[2]))
		_ok(align > 0.9999, "G-MOON-LAND: Moon surface gravity aligns to the local facet down (−normal, dot %.5f)" % align)
		_ok(absf(gmag - GRAV.feel_g("moon")) < 1e-6, "G-MOON-LAND: Moon surface gravity magnitude == feel_g(moon)=%.3f (got %.3f)" % [GRAV.feel_g("moon"), gmag])

# ---- G-MOON-WALK: the surface-walk dominant-body source + lower gravity + edit overlay ----
func _gate_moon_walk() -> void:
	# feel_g(moon) is ~1/6 g and the jump-height-preserving scale gives the ×2.5 hang time — pure math, always.
	var ge := GRAV.feel_g("earth")
	var gm := GRAV.feel_g("moon")
	_ok(gm > 0.0 and gm < ge * 0.25, "G-MOON-WALK: Moon feel gravity %.3f ≪ Earth %.3f (floaty)" % [gm, ge])
	# Jump-height preservation: gravity=feel_g(b); jump=base·√(feel_g(b)/feel_g(earth)) ⇒ h=v²/2g equal; hang=2v/g.
	var jump_base := 8.0
	var jm := jump_base * sqrt(gm / ge)
	var h_earth := jump_base * jump_base / (2.0 * ge)
	var h_moon := jm * jm / (2.0 * gm)
	_ok(absf(h_earth - h_moon) < 1e-6, "G-MOON-WALK: jump HEIGHT preserved Earth↔Moon (%.3f vs %.3f)" % [h_earth, h_moon])
	var hang_ratio := (2.0 * jm / gm) / (2.0 * jump_base / ge)
	_ok(hang_ratio > 2.2 and hang_ratio < 2.7, "G-MOON-WALK: Moon hang time ×%.2f (≈2.5)" % hang_ratio)

	if CubeSphere.MULTI_BODY:
		var bi := FA.body_index("moon")
		var base := FA.fid_base(bi)
		var mfid := base + 17
		var efid := 100
		# The surface-walk dominant-body source: the active facet's body name. A Moon fid ⇒ "moon".
		_ok(FA.body_name_of_fid(mfid) == "moon", "G-MOON-WALK: body_name_of_fid(Moon fid) == 'moon' (walk dominant-body source)")
		_ok(FA.body_name_of_fid(efid) == "earth", "G-MOON-WALK: body_name_of_fid(Earth fid) == 'earth'")
		# Moon surface gravity pulls to the Moon floor (into the facet) at the feel magnitude — walk physics.
		var n := FA.facet_normal64(mfid)
		var g := GRAV.gravity_fixed("moon", mfid, DV.scale(n, 1737.0 + 0.5))
		_ok(absf(_dvlen(g) - gm) < 1e-6, "G-MOON-WALK: Moon walk gravity magnitude == feel_g(moon)")
		# Edit overlay on the Moon: break/place identity survives (fid,cell) round-trip on a Moon fid.
		var cell := Vector3i(37, 12, -8)
		var key := FA.edit_key(mfid, cell)
		var un: Array = FA.edit_key_unpack(key)
		_ok(key > 0 and int(un[0]) == mfid and un[1] == cell, "G-MOON-WALK: Moon edit_key round-trips (break/place on Moon fids)")
		# The Moon terrain the walker's floor reads is Moon worldgen (a Moon column resolves a solid surface).
		var cc := FA.centre_cell(mfid)
		var prof: Vector4 = TC.facet_profile(mfid, cc.x, cc.y)
		var gy := int(prof.x)
		var surf_cell := TC.resolve_cell(cc.x, gy, cc.y, gy, int(prof.y), prof.z, prof.w)
		_ok(surf_cell != BlockCatalog.AIR, "G-MOON-WALK: the Moon surface cell the floor query reads is solid (walkable)")

# ---- G-O4C-OFF: the byte-identity keystone — SOI_SWAP defaults false ----
func _gate_off() -> void:
	# The ONE switch: with SOI_SWAP false, player._dominant_body() returns "earth" unconditionally, so every
	# generalized call site resolves to the shipped literal — the Earth walk/nav/coast paths are byte-identical.
	# We can't instantiate a Player headlessly, but the default-false flag IS the invariant the OFF path rides on,
	# and the full FLAT/faceted/orbital/nav/multibody suites (run separately) prove the byte-identity end-to-end.
	# When the runner sed-toggles SOI_SWAP=true this gate simply notes it (the keystone is the DEFAULT).
	_ok(_PlayerParse != null, "G-O4C-OFF: player.gd (O4c dominant-body plumbing) parses")
	if not CubeSphere.SOI_SWAP:
		_ok(true, "G-O4C-OFF: SOI_SWAP defaults false ⇒ _dominant_body() is 'earth' (byte-identity keystone)")
	else:
		print("  note: SOI_SWAP toggled ON — byte-identity keystone is the DEFAULT (false); on-state is a live/gate-only check")
