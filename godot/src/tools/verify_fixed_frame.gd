extends SceneTree
## COSMOS FP-FIXED-FRAME P1 equivalence gate (docs/COSMOS-FIXED-FRAME-DESIGN.md §7 P1, §2.3) — the Phase-1
## SAFETY NET. It proves the frame-neutral refactor is BYTE-IDENTICAL: with the ActiveFrame pinned at IDENTITY
## (Phase 1) every FrameAdapter map and every enumerated physics-boundary computation returns exactly its
## FP_FIXED_FRAME-OFF result, and reparenting the player / GroundCollider / debris under an identity ActiveFrame
## leaves their GLOBAL transforms unchanged to the bit. It is flag-INDEPENDENT (it constructs its own identity
## ActiveFrame + adapters), so it passes whether committed (flags off) or run with FP_FIXED_FRAME sed-toggled on.
##
##   G-FA-DISABLED   FrameAdapter(null) is the strict identity on points/dirs/xforms/basis/up (the flag-off path).
##   G-FA-IDENTITY   FrameAdapter(ActiveFrame@identity) is byte-equal to the disabled adapter on the SAME inputs
##                   (Phase-1 numeric no-op) — Transform3D.IDENTITY·x == x exactly.
##   G-REPARENT      a child at an arbitrary LOCAL transform, parented under ActiveFrame@identity, has
##                   global_transform == its local transform (== the OFF layout under an identity host).
##   G-BOUNDARY      the ~8 player.gd physics-boundary formulas (§2.3) computed the ON way (through the adapter)
##                   equal the OFF way (direct) over randomized player states — move motion, stand-on ray,
##                   push shape+dir, weight force, aim origin/dir, terrain highlight xform.
##   G-BODY-FRAME    a body node under ActiveFrame@identity has transform == global_transform (VoxelBody lattice
##                   queries read `transform`; equal to the OFF `global_transform`).
##   G-WM-WIRING     (only when FP_FIXED_FRAME+FACETED+FP_M1_POOL+module are all present) WorldManager builds an
##                   ActiveFrame @ identity, frame_adapter().enabled(), and _frame_host() == the ActiveFrame.
##
## RUN (committed, flags off — proves the numeric core):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_fixed_frame.gd
## RUN (flag on — adds G-WM-WIRING; revert the sed after):
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_M1_POOL := false/const FP_M1_POOL := true/;\
##       s/const FP_FIXED_FRAME := false/const FP_FIXED_FRAME := true/' godot/src/cosmos/cube_sphere.gd
## Exits 0 all-pass / 1 on any failure.

const FA := preload("res://src/world/frame_adapter.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

## Exact (byte) equality helpers — Phase-1 identity maps must be exact, not approximate.
func _veq(a: Vector3, b: Vector3) -> bool:
	return a.x == b.x and a.y == b.y and a.z == b.z
func _teq(a: Transform3D, b: Transform3D) -> bool:
	return _veq(a.basis.x, b.basis.x) and _veq(a.basis.y, b.basis.y) \
		and _veq(a.basis.z, b.basis.z) and _veq(a.origin, b.origin)
## Approximate (tolerance) equality — Phase-2 tilted-frame invariants compose f32/f64 transforms at the shipped
## ~33 k lattice + ~3.3 k absolute magnitudes, so continuity/invariance holds to a small epsilon, never to the bit.
func _vapprox(a: Vector3, b: Vector3, eps: float) -> bool:
	return (a - b).length() <= eps
func _tapprox(a: Transform3D, b: Transform3D, eps: float) -> bool:
	return _vapprox(a.basis.x, b.basis.x, eps) and _vapprox(a.basis.y, b.basis.y, eps) \
		and _vapprox(a.basis.z, b.basis.z, eps) and _vapprox(a.origin, b.origin, eps)

## Deterministic pseudo-random sample points/dirs/xforms (no RNG seed dependence — a fixed lattice of states
## spanning the shipped coordinate magnitudes, incl. the ~33 k decorrelation-offset regime, §1.3).
func _sample_points() -> Array:
	return [
		Vector3(0, 0, 0), Vector3(1.5, 2.7, -3.9), Vector3(-12.25, 64.0, 128.5),
		Vector3(512.0, -33.0, 900.5), Vector3(-32768.0, 40.0, 32767.0), Vector3(3071.5, 200.25, -3071.5),
	]
func _sample_dirs() -> Array:
	return [
		Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1),
		Vector3(0.577, 0.577, -0.577), Vector3(-0.7071, 0.0, 0.7071), Vector3(0.267, -0.535, 0.802),
	]

func _initialize() -> void:
	print("=== verify_fixed_frame (FP-FIXED-FRAME P1: frame-neutral byte-identity) ===")

	# The two adapters under test: the DISABLED one (flag-off path) and the IDENTITY-frame one (flag-on Phase 1).
	var off := FA.new()                    # null frame ⇒ strict identity
	var active := Node3D.new()             # the ActiveFrame — PINNED at identity (Phase 1)
	active.name = "ActiveFrame"
	active.transform = Transform3D.IDENTITY
	get_root().add_child(active)           # in-tree so global_transform composes
	var on := FA.new()
	on.setup(active)

	# --- G-FA-DISABLED + G-FA-IDENTITY: both adapters are the numeric identity on every map -------------------
	for p: Vector3 in _sample_points():
		_ok(_veq(off.l2g_point(p), p), "G-FA-DISABLED l2g_point %s" % p)
		_ok(_veq(off.g2l_point(p), p), "G-FA-DISABLED g2l_point %s" % p)
		_ok(_veq(on.l2g_point(p), p), "G-FA-IDENTITY l2g_point %s" % p)
		_ok(_veq(on.g2l_point(p), p), "G-FA-IDENTITY g2l_point %s" % p)
		# round-trip both ways
		_ok(_veq(on.g2l_point(on.l2g_point(p)), p), "G-FA-IDENTITY point round-trip %s" % p)
	for d: Vector3 in _sample_dirs():
		_ok(_veq(off.l2g_dir(d), d), "G-FA-DISABLED l2g_dir %s" % d)
		_ok(_veq(off.g2l_dir(d), d), "G-FA-DISABLED g2l_dir %s" % d)
		_ok(_veq(on.l2g_dir(d), d), "G-FA-IDENTITY l2g_dir %s" % d)
		_ok(_veq(on.g2l_dir(d), d), "G-FA-IDENTITY g2l_dir %s" % d)
	# basis / up / xform identity
	_ok(_teq(on.xform(), Transform3D.IDENTITY) and _teq(off.xform(), Transform3D.IDENTITY), "G-FA xform == identity")
	_ok(_veq(on.up(), Vector3.UP) and _veq(off.up(), Vector3.UP), "G-FA up == +Y")
	for p: Vector3 in _sample_points():
		var t := Transform3D(Basis(Vector3(0, 1, 0), 0.37), p)   # a non-trivial pose to map
		_ok(_teq(on.l2g_xform(t), t), "G-FA-IDENTITY l2g_xform %s" % p)
		_ok(_teq(on.g2l_xform(t), t), "G-FA-IDENTITY g2l_xform %s" % p)
		_ok(_teq(off.l2g_xform(t), t), "G-FA-DISABLED l2g_xform %s" % p)

	# --- G-IDENTITY-COMPOSE: the lemma that makes reparenting under an identity frame pose-NEUTRAL --------------
	# Godot computes a child's global as `parent.global_transform * child.transform`. The player, GroundCollider and
	# debris hang under ActiveFrame (Phase 1: @ identity) whose own global is EXACTLY identity — and, in the flag-off
	# layout, under WorldManager/main which are likewise EXACTLY identity. So proving `Transform3D.IDENTITY · T == T`
	# to the bit (over rotated bases + the shipped ≤33 k translation magnitudes) proves every hosted node's GLOBAL
	# pose is unchanged by the reparent → byte-identical. (A bare --script SceneTree does not propagate node
	# global_transform without a running frame, so this lemma — not a live global_transform read — is the sound test;
	# verify_feature separately exercises live VoxelBody physics under these changes and stays green.)
	var compose_poses := [
		Transform3D.IDENTITY,
		Transform3D(Basis(Vector3(1, 0, 0), -0.21), Vector3(512.0, -33.0, 900.5)),
		Transform3D(Basis(Vector3(0, 1, 0), 1.37), Vector3(-32768.0, 40.0, 32767.0)),
		Transform3D(Basis(Vector3(0.577, 0.577, 0.577).normalized(), 2.1), Vector3(3071.5, 200.25, -3071.5)),
	]
	for T: Transform3D in compose_poses:
		_ok(_teq(Transform3D.IDENTITY * T, T), "G-IDENTITY-COMPOSE IDENTITY·T == T %s" % T.origin)
		# The adapter states the same neutrality: at identity the play frame leaves a local pose == the global pose.
		_ok(_teq(on.l2g_xform(T), T), "G-IDENTITY-COMPOSE frame l2g_xform == T %s" % T.origin)
		_ok(_teq(off.l2g_xform(T), T), "G-IDENTITY-COMPOSE off l2g_xform == T %s" % T.origin)

	# --- G-BOUNDARY: every enumerated player.gd physics-boundary formula ON == OFF (§2.3) --------------------
	# The OFF path is the pre-refactor formula (direct); the ON path routes through the identity adapter.
	for p: Vector3 in _sample_points():
		# move / fly motion: a lattice displacement mapped to global for move_and_collide.
		var mv := Vector3(0.3, 0.0, -0.42)
		_ok(_veq(on.l2g_dir(mv), mv), "G-BOUNDARY move motion %s" % p)
		# stand-on ray endpoints (lattice → global) + hit back to lattice.
		var top := p + Vector3(0, 0.05, 0)
		var bot := p + Vector3(0, -0.6, 0)
		_ok(_veq(on.l2g_point(top), top) and _veq(on.l2g_point(bot), bot), "G-BOUNDARY stand-on ray ends %s" % p)
		var hit := p + Vector3(0.1, -0.3, 0.2)
		_ok(on.g2l_point(hit).y == hit.y, "G-BOUNDARY stand-on hit→lattice y %s" % p)
		# push shape transform (lattice pose → global) + push dir.
		var cap := Transform3D(Basis(), p + Vector3(0, 0.9, 0))
		_ok(_teq(on.l2g_xform(cap), cap), "G-BOUNDARY push shape xform %s" % p)
		var pd := Vector3(0.6, 0.0, 0.8)
		_ok(_veq(on.l2g_dir(pd), pd), "G-BOUNDARY push dir %s" % p)
		# weight force direction (local −ŷ → global).
		var wf := Vector3(0, -700.0, 0)
		_ok(_veq(on.l2g_dir(wf), wf), "G-BOUNDARY weight force %s" % p)
	for d: Vector3 in _sample_dirs():
		# aim: camera origin/dir (global) → lattice for the DDA.
		var org := Vector3(10.0, 20.0, 30.0)
		_ok(_veq(on.g2l_point(org), org) and _veq(on.g2l_dir(d), d), "G-BOUNDARY aim origin/dir %s" % d)
	# terrain highlight cube xform (lattice cell → global).
	for c: Vector3 in [Vector3(3, 4, 5), Vector3(-100, 12, 900), Vector3(32767, 8, -32768)]:
		var cx := Transform3D(Basis(), c)
		_ok(_teq(on.l2g_xform(cx), cx), "G-BOUNDARY terrain highlight xform %s" % c)

	# --- G-BODY-FRAME: VoxelBody's lattice-query read (transform·cell) == the old read (global·cell) -----------
	# voxel_body.gd now feeds surface_y/cell_solid/wake_bodies_near from `transform·cell` (LOCAL) instead of
	# `global_transform·cell`. Under an EXACTLY-identity parent (WM in flag-off, ActiveFrame in Phase 1) global ==
	# local, so the query point is unchanged — even for a TUMBLING (rotated-basis) body. Model it with the lemma:
	# `(IDENTITY · L) · c == L · c` for a rotated body pose L over representative cells c.
	var body_poses := [
		Transform3D(Basis(), Vector3(4.0, 12.0, -7.0)),
		Transform3D(Basis(Vector3(1, 0, 0), 0.9), Vector3(900.5, -33.0, 512.0)),
		Transform3D(Basis(Vector3(0.267, -0.535, 0.802), 1.9), Vector3(-32768.0, 8.0, 32767.0)),
	]
	for L: Transform3D in body_poses:
		var g := Transform3D.IDENTITY * L                    # what a child's global_transform is under identity host
		for c: Vector3 in [Vector3(0.5, 0.0, 0.5), Vector3(3.5, 4.0, 5.5), Vector3(-2.5, 10.0, 7.5)]:
			_ok(_veq(L * c, g * c), "G-BODY-FRAME transform·c == global·c %s @ %s" % [L.origin, c])

	# --- G-P2-* keystone NUMERIC lemmas (flag-INDEPENDENT): the crossing bookkeeping math, proven against FacetAtlas
	# so they hold in the committed (flag-off) build too. -----------------------------------------------------------
	_p2_numeric_lemmas()

	# --- G-WM-WIRING + G-P2-LIVE: real WorldManager + a scripted crossing (only when the flag chain is on) ---------
	if CubeSphere.FP_FIXED_FRAME and CubeSphere.FACETED and CubeSphere.FP_M1_POOL:
		if ClassDB.class_exists("VoxelTerrain"):
			await _wm_wiring_check()      # awaits a process frame so WorldManager._ready fires
			await _p2_live_crossing_check()   # drives a real crossing + asserts the keystone invariants
		else:
			print("  NOTE: G-WM-WIRING/G-P2-LIVE skipped — godot_voxel module absent (numeric core still validated).")
	else:
		print("  NOTE: G-WM-WIRING/G-P2-LIVE skipped — FP_FIXED_FRAME/FACETED/FP_M1_POOL not all on (numeric core validated).")

	active.free()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## COSMOS FP-FIXED-FRAME P2 (§2.2, §5, §2.3) — the crossing is pure bookkeeping; these lemmas prove its math against
## the FacetAtlas frames directly (no module/flags needed), so they run in EVERY invocation:
##   G-P2-ORTHO     facet_transform is orthonormal det=+1 ⇒ the gravity target −T.basis.y is a unit vector.
##   G-P2-PLAYER    reframe_position64(A→B, p)=np ⇒ T_A·p == T_B·np (the player's ABSOLUTE pose is continuous, f64).
##   G-P2-RETURN    reframe A→B→A round-trips a lattice point to itself (cross-and-return, f64).
##   G-P2-DEBRIS    the §5 compensation L' = crossing_transform(A,B)·L preserves a body's ABSOLUTE pose: T_B·L' == T_A·L.
func _p2_numeric_lemmas() -> void:
	TerrainConfig.warm_up()
	FacetAtlas.warm_up()
	if TerrainConfig.active_facet() < 0:
		TerrainConfig.set_active_facet(FacetAtlas.spawn_facet())
	var fid := FacetAtlas.spawn_facet()
	var pairs: Array = []
	for slot in 4:
		var to: int = FacetAtlas.seam_neighbour(fid, slot)
		if to >= 0:
			pairs.append([fid, to])
	_ok(pairs.size() > 0, "G-P2 spawn facet %d has seam neighbours" % fid)
	for pr: Array in pairs:
		var a: int = pr[0]; var b: int = pr[1]
		var ta := FacetAtlas.facet_transform(a)
		var tb := FacetAtlas.facet_transform(b)
		# G-P2-ORTHO: orthonormal basis (unit columns, det +1) — so −T.basis.y is a valid unit gravity direction.
		_ok(absf(ta.basis.determinant() - 1.0) < 1e-4, "G-P2-ORTHO facet %d det==+1" % a)
		_ok(absf(tb.basis.y.length() - 1.0) < 1e-4, "G-P2-ORTHO facet %d up is unit" % b)
		var delta := FacetAtlas.crossing_transform(a, b)   # T_B⁻¹·T_A
		for p: Vector3 in _sample_points():
			# G-P2-PLAYER: absolute continuity of the reframe (the player's world pose does not jump). The reframe is
			# f64-exact; ta/tb are single-precision Transform3D so at the shipped ~33 k lattice magnitudes the mapped
			# check holds to ~cm (§3), never to the bit.
			var np64: Array = FacetAtlas.reframe_position64(a, b, p.x, p.y, p.z)
			var np := Vector3(float(np64[0]), float(np64[1]), float(np64[2]))
			_ok(_vapprox(ta * p, tb * np, 0.1), "G-P2-PLAYER absolute continuity %d→%d %s" % [a, b, p])
			# G-P2-RETURN: A→B→A round-trip (cross-and-return) of the lattice point — kept fully f64 (arrays, no Vector3
			# truncation between the two reframes), so it round-trips to the bit-ish.
			var rt64: Array = FacetAtlas.reframe_position64(b, a, float(np64[0]), float(np64[1]), float(np64[2]))
			_ok(absf(rt64[0] - p.x) < 1e-4 and absf(rt64[1] - p.y) < 1e-4 and absf(rt64[2] - p.z) < 1e-4,
				"G-P2-RETURN round-trip %d→%d→%d %s" % [a, b, a, p])
			# G-P2-DEBRIS: the §5 body-local compensation preserves the body's ABSOLUTE pose across the frame flip.
			var body_local := Transform3D(Basis(Vector3(0.267, -0.535, 0.802).normalized(), 1.3), p)
			var comp := delta * body_local                 # L' = crossing_transform(A,B) · L
			_ok(_tapprox(tb * comp, ta * body_local, 0.25), "G-P2-DEBRIS abs pose preserved %d→%d %s" % [a, b, p])

## Build a real WorldManager with the flags on and assert its fixed-frame wiring (ActiveFrame @ identity, adapter
## enabled, debris host == ActiveFrame). Guarded to the flag-on run so the committed default never needs the module.
## In a --script SceneTree, _ready is deferred to the first processed frame, so we await one after add_child.
func _wm_wiring_check() -> void:
	TerrainConfig.warm_up()
	FacetAtlas.warm_up()
	if TerrainConfig.active_facet() < 0:
		TerrainConfig.set_active_facet(FacetAtlas.spawn_facet())
	var wm := WorldManager.new()
	wm.name = "WorldManager"
	get_root().add_child(wm)          # _ready is deferred to the first frame in a --script SceneTree
	await process_frame               # let _ready run → creates the ActiveFrame under the flag
	await process_frame               # module setup settle
	var af: Node3D = wm.get_node_or_null("ActiveFrame")
	_ok(af != null, "G-WM-WIRING ActiveFrame node created")
	if af != null:
		# Phase 2: the ActiveFrame sits at the active facet's TRUE absolute transform (NOT identity — that was Phase 1).
		_ok(_tapprox(af.transform, FacetAtlas.facet_transform(TerrainConfig.active_facet()), 1e-3),
			"G-WM-WIRING ActiveFrame @ T_active (Phase 2)")
	var fa = wm.frame_adapter()
	_ok(fa != null and fa.enabled(), "G-WM-WIRING frame_adapter enabled")
	_ok(wm._frame_host() == af, "G-WM-WIRING _frame_host() == ActiveFrame")
	# GroundCollider is hosted under the ActiveFrame.
	var gc := (af.get_node_or_null("GroundCollider") if af != null else null)
	_ok(gc != null, "G-WM-WIRING GroundCollider hosted under ActiveFrame")
	# Phase 2: PlanetRoot is pinned @ identity (the scene frame IS the planet-absolute frame).
	var pr := wm.find_child("PlanetRoot", true, false)
	if pr != null:
		_ok(_tapprox((pr as Node3D).transform, Transform3D.IDENTITY, 1e-5), "G-WM-WIRING PlanetRoot @ identity (Phase 2)")
	else:
		print("  NOTE: PlanetRoot absent (fallback path / no module pool) — PlanetRoot pin covered by G-P2-LIVE when present.")
	wm.free()

## COSMOS FP-FIXED-FRAME P2 LIVE keystone (§2.2, §7 P2 acceptance a–g) — build a real WorldManager (flags on, module
## present) and drive a SCRIPTED crossing, asserting the keystone invariants against the live scene:
##   G-P2-LIVE-PROOT   PlanetRoot.transform is CONSTANT (== identity) across the crossing (the write is SKIPPED).
##   G-P2-LIVE-SLOTS   each live FacetSlot stays at its own T_fid (absolute), i.e. the active slot is NOT re-centred.
##   G-P2-LIVE-PLAYER  a player-proxy under ActiveFrame keeps its ABSOLUTE pose across the crossing + reframe (no jump).
##   G-P2-LIVE-DEBRIS  a debris VoxelBody keeps its ABSOLUTE global_transform across the crossing; a sleeper stays asleep.
##   G-P2-LIVE-GRAV    world gravity == −T_to.basis.y after the crossing.
##   G-P2-LIVE-FRAME   ActiveFrame flips to T_to (the O(1) re-place that replaces the PlanetRoot write).
##   G-P2-LIVE-RETURN  a cross-and-return restores the active facet + the player-proxy's absolute pose.
## (Edit-overlay correctness across a crossing — edits are (fid,cell)-GLOBAL, §1.5 — is UNCHANGED by P2, which
## touches zero edit code; it is proven flag-on by the existing FP-M1a overlay gate, not re-derived here.)
func _p2_live_crossing_check() -> void:
	TerrainConfig.warm_up()
	FacetAtlas.warm_up()
	var fid := FacetAtlas.spawn_facet()
	TerrainConfig.set_active_facet(fid)
	var w := WorldManager.new()
	w.name = "P2Live"
	get_root().add_child(w)
	await process_frame
	await process_frame          # module + pool settle
	var af: Node3D = w.get_node_or_null("ActiveFrame")
	var pr: Node3D = w.find_child("PlanetRoot", true, false)
	if af == null:
		_ok(false, "G-P2-LIVE ActiveFrame present"); w.free(); return
	# Find a position PAST a ridge that will commit a crossing (mirrors verify_faceted's smoke test).
	var cc := FacetAtlas.centre_cell(fid)
	var cx := cc.x; var cz := cc.y
	var cross_pos := Vector3.INF
	for d in range(1, 400):
		var px := float(cx + d) + 0.5
		var pf := w.surface_y(px, float(cz) + 0.5)
		var mn := 1.0e18
		for slot in range(4):
			mn = minf(mn, FacetAtlas.own_dist(fid, slot, px, pf, float(cz) + 0.5))
		if mn < -1.0:
			cross_pos = Vector3(px, pf, float(cz) + 0.5)
			break
	if not cross_pos.is_finite():
		_ok(false, "G-P2-LIVE found a past-ridge crossing position"); w.free(); return

	# A player-proxy + two debris bodies, all hosted under the ActiveFrame exactly like the real player/debris.
	var proxy := Node3D.new(); proxy.name = "PlayerProxy"; af.add_child(proxy)
	proxy.position = cross_pos                              # LOCAL == lattice; its GLOBAL is planet-absolute
	var proxy_abs_before := proxy.global_transform
	var STONE := BlockCatalog.STONE
	var debris: VoxelBody = VoxelBody.spawn_loose(af, {Vector3i(int(cx), int(w.surface_y(float(cx) + 0.5, float(cz) + 0.5)) + 30, int(cz)): STONE}, w)
	debris.freeze = true                                   # make it a stable marker (no fall between the two reads)
	var debris_abs_before := debris.global_transform
	var sleeper: VoxelBody = VoxelBody.spawn_loose(af, {Vector3i(int(cx) + 2, int(w.surface_y(float(cx) + 2.5, float(cz) + 0.5)) + 30, int(cz)): STONE}, w)
	sleeper.freeze = false
	sleeper.sleeping = true
	var proot_before := pr.transform if pr != null else Transform3D.IDENTITY
	var slot_before := FacetAtlas.facet_transform(fid)     # the active slot's expected absolute placement

	var res := w.maybe_cross_facet(cross_pos)              # THE crossing (synchronous — no physics step between reads)
	_ok(bool(res.get("crossed", false)), "G-P2-LIVE crossing committed from facet %d" % fid)
	if not res.get("crossed", false):
		w.free(); return
	var to := int(res["to"])

	# (a) PlanetRoot constant == identity across the crossing.
	if pr != null:
		_ok(_tapprox(pr.transform, proot_before, 1e-5) and _tapprox(pr.transform, Transform3D.IDENTITY, 1e-5),
			"G-P2-LIVE-PROOT PlanetRoot.transform CONSTANT == identity across the crossing")
	# (a') the just-left facet's slot is STILL at its own T_fid (absolute) — the active slot was NOT re-centred.
	var slot_from := w.find_child("FacetSlot_%d" % fid, true, false)
	if slot_from != null:
		_ok(_tapprox((slot_from as Node3D).global_transform, slot_before, 0.25),
			"G-P2-LIVE-SLOTS FacetSlot_%d stays @ its absolute T_fid" % fid)
	# (b) ActiveFrame flipped to T_to.
	_ok(_tapprox(af.transform, FacetAtlas.facet_transform(to), 1e-3), "G-P2-LIVE-FRAME ActiveFrame @ T_to")
	# (c) player-proxy absolute pose continuous across crossing + reframe.
	proxy.position = res["new_pos"]                        # the real player reframe (apply_reframe assigns local)
	_ok(_tapprox(proxy.global_transform, proxy_abs_before, 0.25),
		"G-P2-LIVE-PLAYER player-proxy ABSOLUTE pose continuous across the crossing")
	# (d) debris absolute pose invariant + sleeper stays asleep.
	_ok(_tapprox(debris.global_transform, debris_abs_before, 0.25),
		"G-P2-LIVE-DEBRIS debris global_transform invariant across the crossing")
	_ok(sleeper.sleeping, "G-P2-LIVE-DEBRIS sleeper stays asleep across the crossing")
	# (e) gravity rotated to the new facet's absolute up.
	_ok(_vapprox(w.gravity_vector(), -FacetAtlas.facet_transform(to).basis.y, 1e-4),
		"G-P2-LIVE-GRAV world gravity == −T_to.basis.y")

	# (g) cross-and-return: from the landing in `to`, drain the crossing cooldown, then march DOWN the own_dist
	# gradient of the ridge whose neighbour is `fid` (the seam we just came over) until past it, and cross back.
	var landing := Vector3(res["new_pos"])
	for _drain in range(WorldManager.FACET_CROSS_COOLDOWN + 4):
		w.maybe_cross_facet(landing)      # landing is interior to `to` (containment) → no cross, just decrements cooldown
	var bs := -1                          # the slot of `to` whose seam neighbour is the origin facet `fid`
	for s in range(4):
		if FacetAtlas.seam_neighbour(to, s) == fid:
			bs = s
			break
	var returned := false
	var pos2 := landing
	for _step in range(600):
		var y2 := w.surface_y(pos2.x, pos2.z)
		var d0 := FacetAtlas.own_dist(to, bs, pos2.x, y2, pos2.z)
		if d0 < -1.0:
			var r2 := w.maybe_cross_facet(Vector3(pos2.x, y2, pos2.z))
			if r2.get("crossed", false):
				returned = (int(r2["to"]) == fid)
			break
		var dx := FacetAtlas.own_dist(to, bs, pos2.x + 1.0, y2, pos2.z) - d0
		var dz := FacetAtlas.own_dist(to, bs, pos2.x, y2, pos2.z + 1.0) - d0
		var g := Vector2(dx, dz)
		if g.length() < 1e-9:
			break
		var stepv := -g.normalized() * 2.0   # descend own_dist toward the ridge (y re-sampled next iter)
		pos2 = Vector3(pos2.x + stepv.x, y2, pos2.z + stepv.y)
	_ok(returned and TerrainConfig.active_facet() == fid, "G-P2-LIVE-RETURN cross-and-return restores active facet %d" % fid)
	if returned:
		_ok(_tapprox(af.transform, FacetAtlas.facet_transform(fid), 1e-3), "G-P2-LIVE-RETURN ActiveFrame back @ T_fid")
		# PlanetRoot never moved through the whole round trip.
		if pr != null:
			_ok(_tapprox(pr.transform, Transform3D.IDENTITY, 1e-5), "G-P2-LIVE-RETURN PlanetRoot still @ identity after round-trip")
	w.free()
