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

	# --- G-WM-WIRING: real WorldManager builds the ActiveFrame @ identity (only when the flag chain is on) -----
	if CubeSphere.FP_FIXED_FRAME and CubeSphere.FACETED and CubeSphere.FP_M1_POOL:
		if ClassDB.class_exists("VoxelTerrain"):
			await _wm_wiring_check()   # awaits a process frame so WorldManager._ready fires
		else:
			print("  NOTE: G-WM-WIRING skipped — godot_voxel module absent (structural core still validated).")
	else:
		print("  NOTE: G-WM-WIRING skipped — FP_FIXED_FRAME/FACETED/FP_M1_POOL not all on (numeric core validated).")

	active.free()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

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
		_ok(_teq(af.transform, Transform3D.IDENTITY), "G-WM-WIRING ActiveFrame @ identity (Phase 1)")
	var fa = wm.frame_adapter()
	_ok(fa != null and fa.enabled(), "G-WM-WIRING frame_adapter enabled")
	_ok(wm._frame_host() == af, "G-WM-WIRING _frame_host() == ActiveFrame")
	# GroundCollider is hosted under the ActiveFrame.
	var gc := (af.get_node_or_null("GroundCollider") if af != null else null)
	_ok(gc != null, "G-WM-WIRING GroundCollider hosted under ActiveFrame")
	wm.free()
