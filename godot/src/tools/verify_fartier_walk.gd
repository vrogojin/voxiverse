extends SceneTree
## COSMOS FAR-TIER WALK gate (docs/COSMOS-FARTIER-WALK-DESIGN.md §5) — the move-churn diet + Schmitt dead-band levers.
## Real-path drivers (the runtime-dead lesson): every assertion exercises the ACTUAL far-tree / far-structure decision
## code (_rebuild_inputs_changed / _probe_pass / _inputs_changed / _band_code), never a synthetic shadow.
##
## Flag-aware (the verify_far_trees / verify_structures convention): the FP_* consts are compile-time, so each gate
## SELF-DESCRIBES its off (byte-identical) vs on (sed-toggled A/B build) behaviour. With every walk-fix flag at its
## repo default (false) this asserts the byte-off path; sed-toggling FP_FT_WALK_CALM / FP_STRUCT_WALK_CALM /
## FP_STRUCT_HANDOFF_HYST true asserts the levered path.
##
## SCOPE NOTE: Lever 2a/2b (FP_FT_NEARCULL_XFADE / FP_STRUCT_XFADE — the cross-fade animators) are DECLARED but their
## bodies are deferred (shader-migration subset — see the design-vs-reality note in the branch report), so the
## G-LODX-GAP/SETTLE cross-fade gates are not yet present. Lever 1 (walk-churn diet) + Lever 2c (Schmitt) are proven here.
##
## RUN:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_fartier_walk.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const FT := preload("res://src/world/facet_far_trees.gd")
const FS := preload("res://src/world/facet_far_structures.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0

func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_fartier_walk (COSMOS-FARTIER-WALK — Lever 1 walk-churn diet + Lever 2c Schmitt) ===")
	FA.warm_up()
	TerrainConfig.warm_up()
	_gate_off_pins()
	_gate_tree_threshold()
	_gate_struct_fingerprint()
	_gate_struct_fresh()
	_gate_schmitt()
	_gate_walk_budget()
	print("=== VERIFY fartier_walk: ", _pass, " passed, ", _fail, " failed ===")
	quit(1 if _fail > 0 else 0)

# =====================================================================================================================
# G-WC-OFF — flag existence pins + byte-off identity of the decision path.
# =====================================================================================================================
func _gate_off_pins() -> void:
	# Existence pins (a repo-default flip would otherwise silently void the byte-off promise).
	_ok(CubeSphere.FP_FT_WALK_CALM == false or CubeSphere.FP_FT_WALK_CALM == true, "G-WC-OFF: FP_FT_WALK_CALM declared")
	_ok(CubeSphere.FP_STRUCT_WALK_CALM == false or CubeSphere.FP_STRUCT_WALK_CALM == true, "G-WC-OFF: FP_STRUCT_WALK_CALM declared")
	_ok(CubeSphere.FP_STRUCT_HANDOFF_HYST == false or CubeSphere.FP_STRUCT_HANDOFF_HYST == true, "G-WC-OFF: FP_STRUCT_HANDOFF_HYST declared")
	_ok(CubeSphere.FP_FT_NEARCULL_XFADE == false or CubeSphere.FP_FT_NEARCULL_XFADE == true, "G-WC-OFF: FP_FT_NEARCULL_XFADE declared")
	_ok(CubeSphere.FP_STRUCT_XFADE == false or CubeSphere.FP_STRUCT_XFADE == true, "G-WC-OFF: FP_STRUCT_XFADE declared")
	_ok(CubeSphere.FT_CALM_MARGIN == 32.0, "G-WC-OFF: FT_CALM_MARGIN == 32")
	# Structures byte-off: a fresh tier's fingerprint members are inert (0) until a probe pass under the flag.
	var t = FS.new()
	_ok(t._band_fp == 0 and t._last_band_fp == 0, "G-WC-OFF: structure band-fp members inert on construction")

# =====================================================================================================================
# G-WC-TREE — the far-tree camera re-arm threshold. OFF ⇒ the shipped FT_DELTA_MIN_MOVE (2) / MOVE_HYST (12); ON
# (FP_FT_WALK_CALM) ⇒ raised to FT_CALM_MARGIN·0.5 (16). Drives the REAL _rebuild_inputs_changed (no ring/worker).
# =====================================================================================================================
func _gate_tree_threshold() -> void:
	var on := CubeSphere.FP_FT_WALK_CALM
	var t = FT.new()
	var cam0 := Vector3(1000.0, 0.0, 0.0)
	_ok(t._rebuild_inputs_changed(cam0), "G-WC-TREE: first check always rebuilds (latches reference)")
	_ok(not t._rebuild_inputs_changed(cam0), "G-WC-TREE: static camera ⇒ NO rebuild")
	# A 15-block move from the latched reference.
	var cam15 := cam0 + Vector3(15.0, 0.0, 0.0)
	var did15 := t._rebuild_inputs_changed(cam15)
	if on:
		_ok(not did15, "G-WC-TREE(on): 15-blk move < FT_CALM_MARGIN·0.5 (16) ⇒ NO rebuild (calmed)")
		# 17-block move from the same reference (cam0 still latched — did15 returned false, no re-latch).
		var cam17 := cam0 + Vector3(17.0, 0.0, 0.0)
		_ok(t._rebuild_inputs_changed(cam17), "G-WC-TREE(on): 17-blk move ≥ 16 ⇒ exactly one rebuild")
		_ok(not t._rebuild_inputs_changed(cam17), "G-WC-TREE(on): static after the re-arm ⇒ NO rebuild")
	else:
		_ok(did15, "G-WC-TREE(off): 15-blk move ≥ shipped threshold (≤12) ⇒ rebuild (byte-identical)")
	# Membership delta (a facet's records changed) always re-commits, in BOTH flag states.
	var t2 = FT.new()
	_ok(t2._rebuild_inputs_changed(cam0), "G-WC-TREE: fresh tier first rebuild")
	_ok(not t2._rebuild_inputs_changed(cam0), "G-WC-TREE: then static ⇒ skip")
	t2.debug_set_cache(0, PackedFloat32Array())          # bumps _cache_epoch (a facet landed)
	_ok(t2._rebuild_inputs_changed(cam0), "G-WC-TREE: record-cache epoch bump at a still camera ⇒ exactly one rebuild (both states)")

# =====================================================================================================================
# G-WC-STRUCT — the far-structure band FINGERPRINT. OFF ⇒ the shipped 2-blk camera re-arm; ON (FP_STRUCT_WALK_CALM) ⇒
# a pure translation crossing NO band edge does NOT re-commit, a translation crossing one edge does (exactly once), a
# rev bump always does. Drives the REAL _probe_pass (populates _band_fp) → _inputs_changed chain.
# =====================================================================================================================
func _gate_struct_fingerprint() -> void:
	var on := CubeSphere.FP_STRUCT_WALK_CALM
	var t = FS.new()
	# near_query wired exactly as WorldManager does (UNKNOWABLE ⇒ no cull churn, cover_fp stable) so _probe_pass runs
	# the full band loop (its early-out is only for an UNWIRED query).
	t.set_near_query(func(_fid: int, _box: AABB) -> int: return NearPresence.UNKNOWABLE)
	# 3 houses, all initially in the BAND zone (code 2). house0 near the OUT edge so a radial move crosses it.
	var reg: Array = [
		{"root": 11, "fid": 0, "bmin": Vector3i(60, 40, 0), "bmax": Vector3i(66, 46, 6), "rev": 1},
		{"root": 12, "fid": 0, "bmin": Vector3i(0, 40, 60), "bmax": Vector3i(6, 46, 66), "rev": 1},
		{"root": 13, "fid": 0, "bmin": Vector3i(0, 40, 0), "bmax": Vector3i(6, 46, 6), "rev": 1},
	]
	var c0 := t._structure_centre(reg[0])
	var rdir := c0.normalized()
	var cam_band := c0 - rdir * (CubeSphere.STRUCT_FAR_MAX - 50.0)   # house0 in BAND (dist ≈ FAR_MAX-50)
	var rev_sum := 3
	_ok(t._structure_dist(reg[0], cam_band) < CubeSphere.STRUCT_FAR_MAX
		and t._structure_dist(reg[0], cam_band) > float(TerrainConfig.near_render_radius()) + FS.CULL_ANNULUS,
		"G-WC-STRUCT: house0 starts in the BAND zone")

	t._probe_pass(reg, cam_band)
	_ok(t._inputs_changed(cam_band, 3, rev_sum, 0), "G-WC-STRUCT: first check always rebuilds")
	# Pure translation crossing NO band edge: tangential 3-block move (radial distance essentially unchanged).
	var tangent := rdir.cross(Vector3(0, 1, 0)).normalized()
	if tangent.length() < 0.5:
		tangent = rdir.cross(Vector3(1, 0, 0)).normalized()
	var cam_walk := cam_band + tangent * 3.0
	t._probe_pass(reg, cam_walk)
	var did_walk := t._inputs_changed(cam_walk, 3, rev_sum, 0)
	if on:
		_ok(not did_walk, "G-WC-STRUCT(on): pure translation (no band-edge crossing) ⇒ ZERO re-commit")
	else:
		_ok(did_walk, "G-WC-STRUCT(off): 3-blk camera move ≥ STRUCT_DELTA_MOVE ⇒ re-commit (byte-identical)")

	# Membership delta: pull the camera radially out so house0 crosses BAND→OUT (fingerprint flips).
	var cam_cross := c0 - rdir * (CubeSphere.STRUCT_FAR_MAX + 60.0)
	_ok(t._structure_dist(reg[0], cam_cross) > CubeSphere.STRUCT_FAR_MAX, "G-WC-STRUCT: house0 crossed to OUT (> STRUCT_FAR_MAX)")
	t._probe_pass(reg, cam_cross)
	_ok(t._inputs_changed(cam_cross, 3, rev_sum, 0), "G-WC-STRUCT: a band-edge crossing ⇒ re-commit (both states)")
	t._probe_pass(reg, cam_cross)
	var did_still := t._inputs_changed(cam_cross, 3, rev_sum, 0)
	if on:
		_ok(not did_still, "G-WC-STRUCT(on): still camera after the crossing ⇒ ZERO further re-commit (exactly one per crossing)")
	else:
		_ok(not did_still, "G-WC-STRUCT(off): still camera ⇒ no re-commit (shipped: no move)")
	# A rev bump (a structure changed) always re-commits within one step, in BOTH flag states.
	t._probe_pass(reg, cam_cross)
	_ok(t._inputs_changed(cam_cross, 3, rev_sum + 1, 0), "G-WC-STRUCT: rev-sum bump ⇒ re-commit within one step (both states)")

# =====================================================================================================================
# G-WC-FRESH — no-stale / no-drop. (1) WALK_CALM changes ONLY the DELTA gate, never _rebuild's OUTPUT: a real _rebuild
# yields the identical merged mesh regardless of the flag. (2) The fingerprint is a PURE function of membership: a
# fresh tier fed the same (reg, camera) computes the SAME _band_fp — so a skip can never diverge the committed state.
# =====================================================================================================================
func _gate_struct_fresh() -> void:
	var g := BlockCatalog.id_of(&"grass")
	if g <= 0:
		_ok(false, "G-WC-FRESH: grass id unavailable")
		return
	var r0 := float(TerrainConfig.near_render_radius())
	var reg: Array = []
	for k in range(6):
		var bmin := Vector3i(200 + k * 6, 40, 0)
		reg.append({"root": 1000 + k, "fid": 0, "bmin": bmin, "bmax": bmin + Vector3i(3, 3, 3), "rev": 1})
	var probe := FS.new()
	var c0 := probe._structure_centre(reg[0])
	var cam := c0 - c0.normalized() * (r0 + 400.0)     # unconditional-emit band (dist > r0+annulus)
	var samp := func(_fid: int, _cell: Vector3i) -> int: return g
	# (1) real _rebuild output — flag-independent merged tris.
	var t = FS.new()
	t.setup_instance(Node3D.new(), 0)
	t.set_sampler(samp)
	t.set_near_query(func(_fid: int, _box: AABB) -> int: return NearPresence.UNKNOWABLE)
	t._rebuild(reg, cam)
	var tris_first := t.live_tris()
	_ok(tris_first > 0 and t.live_structures() == 6, "G-WC-FRESH: real _rebuild emits every in-band house (output unaffected by WALK_CALM)")
	# A second _rebuild with the SAME inputs is bit-identical (no drift in the committed set).
	t._rebuild(reg, cam)
	_ok(t.live_tris() == tris_first and t.live_structures() == 6, "G-WC-FRESH: a repeat _rebuild yields the identical merged mesh (no stale, no drop)")
	# (2) fingerprint purity: two fresh tiers, same (reg, cam) ⇒ same _band_fp (only meaningful under the flag).
	var a = FS.new(); a.set_near_query(func(_f: int, _b: AABB) -> int: return NearPresence.UNKNOWABLE)
	var b = FS.new(); b.set_near_query(func(_f: int, _b: AABB) -> int: return NearPresence.UNKNOWABLE)
	a._probe_pass(reg, cam)
	b._probe_pass(reg, cam)
	_ok(a._band_fp == b._band_fp, "G-WC-FRESH: band-fingerprint is a pure function of (membership, camera) — fresh tiers agree")

# =====================================================================================================================
# G-WC-SCHMITT — the FP_STRUCT_HANDOFF_HYST dead-band on _band_code. OFF ⇒ raw edge compares flip at the edge; ON ⇒
# a state-keyed code sticks across a ±STRUCT_HYST_W wobble (no per-pass flap for a player oscillating on the boundary).
# =====================================================================================================================
func _gate_schmitt() -> void:
	var on := CubeSphere.FP_STRUCT_HANDOFF_HYST
	var t = FS.new()
	var r0 := float(TerrainConfig.near_render_radius())
	var edge := CubeSphere.STRUCT_FAR_MAX            # the BAND|OUT edge (codes 2↔3)
	var w := CubeSphere.STRUCT_HYST_W
	# Enter from below the edge (code 2 = BAND). prev latched by the previous call.
	var prev := t._band_code(edge - 2.0 * w, r0, -1)
	_ok(prev == 2, "G-WC-SCHMITT: just inside the edge classifies BAND (code 2)")
	# A single-block back-and-forth straddling the edge, feeding prev each time.
	var flips := 0
	var offs := [1.0, -1.0, 1.0, -1.0, 1.0, -1.0]    # ±1 blk around the edge (inside the dead-band)
	for off in offs:
		var code := t._band_code(edge + off, r0, prev)
		if code != prev:
			flips += 1
		prev = code
	if on:
		_ok(flips == 0, "G-WC-SCHMITT(on): ±1-blk wobble inside the dead-band ⇒ ZERO code flaps")
	else:
		_ok(flips >= 2, "G-WC-SCHMITT(off): raw edge ⇒ the wobble flaps the code every crossing (byte-identical)")
	# A decisive move past edge + w (ON) / past the edge (OFF) DOES advance the code (the dead-band never sticks forever).
	var prev2 := t._band_code(edge - 2.0 * w, r0, -1)
	var far_code := t._band_code(edge + 2.0 * w, r0, prev2)
	_ok(far_code == 3, "G-WC-SCHMITT: a decisive move past edge+HYST_W advances the code to OUT (dead-band is bounded)")

# =====================================================================================================================
# G-WC-PERF — a scripted ~200-block straight walk past a village. ON (FP_STRUCT_WALK_CALM) ⇒ structure re-commits are
# bounded by band-edge crossings (few); OFF ⇒ ~one per STRUCT_DELTA_MOVE blocks (the shipped control). Drives the real
# _probe_pass → _inputs_changed decision each step (the same chain step() runs post-rate-cap).
# =====================================================================================================================
func _gate_walk_budget() -> void:
	var on := CubeSphere.FP_STRUCT_WALK_CALM
	var t = FS.new()
	t.set_near_query(func(_fid: int, _box: AABB) -> int: return NearPresence.UNKNOWABLE)
	# A small village in the BAND zone.
	var reg: Array = []
	for k in range(5):
		var bmin := Vector3i(20 + k * 8, 40, 0)
		reg.append({"root": 2000 + k, "fid": 0, "bmin": bmin, "bmax": bmin + Vector3i(5, 5, 5), "rev": 1})
	var c0 := t._structure_centre(reg[0])
	var rdir := c0.normalized()
	var tangent := rdir.cross(Vector3(0, 1, 0)).normalized()
	if tangent.length() < 0.5:
		tangent = rdir.cross(Vector3(1, 0, 0)).normalized()
	# Start deep in the BAND, walk tangentially 200 blocks (a straight walk that never crosses a band edge — the
	# village stays in-band throughout, so ON should see ~zero re-commits, OFF ~200/STRUCT_DELTA_MOVE).
	var cam := c0 - rdir * (float(TerrainConfig.near_render_radius()) + 600.0)
	var rev_sum := reg.size()
	var recommits := 0
	# Prime.
	t._probe_pass(reg, cam)
	if t._inputs_changed(cam, reg.size(), rev_sum, 0):
		pass   # the mandatory first rebuild — not counted in the walk budget
	for step in range(200):
		cam += tangent * 1.0
		t._probe_pass(reg, cam)
		if t._inputs_changed(cam, reg.size(), rev_sum, 0):
			recommits += 1
	if on:
		_ok(recommits <= 4, "G-WC-PERF(on): a 200-blk no-crossing walk ⇒ ≤4 structure re-commits (calmed; was ~100)")
	else:
		var expect := int(200.0 / FS.STRUCT_DELTA_MOVE)
		_ok(recommits >= expect - 5, "G-WC-PERF(off): a 200-blk walk ⇒ ~200/STRUCT_DELTA_MOVE re-commits (=%d, shipped churn control)" % expect)
