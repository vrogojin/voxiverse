extends SceneTree
## COSMOS M2 — headless property tests for full-face play: the floating-origin + global-edit-
## persistence layer (docs/COSMOS-PLANET-TOPOLOGY.md §9 M2, §1.3, §3.1, §3.2, §8.2). Run:
##   godot --headless --path godot --script res://src/tools/verify_cosmos_m2.gd
## Exits 0 all-pass, 1 on any failure. Asserts the CURVED-mode M2 invariants WITHOUT flipping
## CubeSphere.FLAT_WORLD (a const): a CosmosChart is injected into a WorldManager directly, so the
## global-key overlay + integer origin shift are exercised while the live FLAT_WORLD path stays
## byte-identical. The generator fallthrough is the flat gen while the const is on — which is
## exactly what proves the fold is window-INDEPENDENT (worldgen depends only on the global cell).
##
## Gates (§9 M2 + the task VERIFY list):
##   (a) an edit written at global cell (face,i,j,r) is retrieved by its global key AFTER an origin
##       re-anchor (the demo's "edits found again") — incl. block-entity metadata.
##   (b) the origin shift is an EXACT INTEGER translation preserving the continuous WORLD position
##       (no teleport: pre/post world point equal in f64) AND keeping local coords f32-safe at a
##       simulated 5–10 km face distance.
##   (c) worldgen is byte-identical regardless of chart anchor (§8.2 determinism).
##   (d) the global edit key round-trips through world_manager's store (curved keys, not window).
##   (e) latitude climate: face-4 centre (pole) is cold, the equatorial belt warmer, monotonic-ish.
##   (f) FLAT_WORLD-on ≡ pre-M2 edit behaviour at the data layer (Vector3i keying, byte-identical).
##   (g) per-(body,face) ZoneChunk region keys + a curved save_region/load_region round-trip (§1.1).

const CS := preload("res://src/cosmos/cube_sphere.gd")
const CHART := preload("res://src/cosmos/cosmos_chart.gd")
const TC := preload("res://src/world/terrain_config.gd")
const PVE := preload("res://src/sim/per_voxel_environment.gd")

var _fail := 0
var _pass := 0

func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		push_error("FAIL: " + msg)
		print("  FAIL: ", msg)

func _initialize() -> void:
	print("COSMOS M2 — full-face play verification (FLAT_WORLD=%s)" % str(CS.FLAT_WORLD))
	BlockCatalog.ensure_ready()
	TC.warm_up()
	_test_key_roundtrip()          # (d)
	_test_edit_survives_reanchor() # (a)
	_test_reanchor_teleport_free() # (b)
	_test_worldgen_anchor_indep()  # (c)
	_test_latitude_climate()       # (e)
	_test_flat_byte_identity()     # (f)
	_test_region_keys()            # (g)
	print("\n==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## A WorldManager NOT added to the tree (so _ready never runs): the render/collider plumbing stays
## null and _write_cell/cell_value_at exercise the overlay + key logic in isolation. The overlay
## dicts are field-initialised, so they work without _ready.
func _bare_world() -> WorldManager:
	return WorldManager.new()

# ---------------------------------------------------------------------------------------
# (d) The global edit key round-trips through the store.
# ---------------------------------------------------------------------------------------
func _test_key_roundtrip() -> void:
	print("[d] global edit key round-trips through WorldManager's store (curved keys, not window)")
	var w := _bare_world()
	var chart := CHART.new(CS.HOME_BODY, CS.HOME_FACE, 0, 0)
	w.install_chart(chart)
	var wc := Vector3i(137, 5, 4242)
	var packed := CellCodec.pack(BlockCatalog.STONE)
	w._write_cell(wc, packed)
	var key := chart.to_global_key(wc)
	_ok(key == CS.edit_key(CS.HOME_FACE, 137, 4242, 5), "to_global_key(cell) == edit_key(face, i, j, r)")
	_ok(w._edits.has(key), "the overlay stores the edit under the 43-bit GLOBAL key")
	_ok(not w._edits.has(wc), "the overlay does NOT key by the Vector3i window cell (curved mode)")
	_ok(w._edits.size() == 1, "exactly one overlay entry after one write")
	_ok(CellCodec.mat(w.cell_value_at(wc)) == BlockCatalog.STONE, "cell_value_at reads the edit back via the global key")
	# The same global cell reached from a DIFFERENT window cell (via a re-origined chart) hits the
	# SAME key — the store is keyed by global identity, not by where the window happens to sit.
	var chart2 := CHART.new(CS.HOME_BODY, CS.HOME_FACE, 100, 4000)
	var wc2 := Vector3i(37, 5, 242)   # 100+37=137, 4000+242=4242 → same global cell
	_ok(chart2.to_global_key(wc2) == key, "a different anchor's window cell folds to the SAME global key")
	w.free()

# ---------------------------------------------------------------------------------------
# (a) An edit is found again by its global key after an origin re-anchor.
# ---------------------------------------------------------------------------------------
func _test_edit_survives_reanchor() -> void:
	print("[a] an edit written at a global cell is retrieved after an origin re-anchor (found again)")
	var w := _bare_world()
	var chart := CHART.new(CS.HOME_BODY, CS.HOME_FACE, 0, 0)
	w.install_chart(chart)
	var wc := Vector3i(100, 5, 200)
	var packed := CellCodec.pack(BlockCatalog.STONE, 0, 7)   # material + a state to prove the full value survives
	w._write_cell(wc, packed)
	var key := chart.to_global_key(wc)

	# Re-anchor by walking the player far past the trigger (Δ = floor(local)). The origin shifts an
	# exact integer; the edit's GLOBAL key does not move.
	var shift := w.maybe_reanchor(Vector3(300.0, 5.0, 0.0))
	_ok(shift == Vector3(300.0, 0.0, 0.0), "re-anchor returned the exact integer shift Δ=(300,0,0) (got %s)" % str(shift))
	_ok(chart.i_org == 300 and chart.j_org == 0, "chart origin advanced to (300, 0)")

	# The SAME physical cell is now at window (100−300, 5, 200) = (−200, 5, 200).
	var wc_after := Vector3i(100 - 300, 5, 200)
	_ok(chart.to_global_key(wc_after) == key, "the physical cell's global key is unchanged across the shift")
	_ok(w._edits.has(key) and w._edits.size() == 1, "the overlay entry is untouched by the shift (still one, same key)")
	_ok(w.cell_value_at(wc_after) == packed, "the edit is FOUND AGAIN at its new window cell, full value intact")
	_ok(CellCodec.state(w.cell_value_at(wc_after)) == 7, "the state axis survived the re-anchor")

	# Block-entity metadata survives the same way (global-keyed).
	var be := BlockCatalog.STONE
	var be_state: VoxelState = BlockCatalog.state_of(be)
	var prev := be_state.has_block_entity
	be_state.has_block_entity = true
	var wc_be := Vector3i(120, 6, 200)
	w._write_cell(wc_be, CellCodec.pack(be))
	var doc := {"label": "chest", "count": 3}
	_ok(w.set_metadata(wc_be, doc), "attach metadata to a block-entity cell (curved store)")
	var d2 := w.maybe_reanchor(Vector3(500.0, 5.0, 300.0))   # another shift Δ=(500,300)
	var wc_be_after := Vector3i(wc_be.x - int(d2.x), 6, wc_be.z - int(d2.z))
	_ok(w.has_metadata(wc_be_after) and w.get_metadata(wc_be_after) == doc,
		"block-entity metadata is found again at the re-anchored cell")
	be_state.has_block_entity = prev
	w.free()

# ---------------------------------------------------------------------------------------
# (b) The origin shift is an exact integer translation: teleport-free + f32-safe at 5–10 km.
# ---------------------------------------------------------------------------------------
func _test_reanchor_teleport_free() -> void:
	print("[b] origin shift is an exact integer translation (no teleport) + f32-safe at 5–10 km")
	var chart := CHART.new(CS.HOME_BODY, CS.HOME_FACE, 0, 0)
	var step := 137
	var local_x := 0.0
	var global_i := 0
	var max_abs_local := 0.0
	var teleport_ok := true
	var continuous := true
	var worst_wp_err := 0.0
	while global_i <= 10016 - step:
		local_x += float(step)
		global_i += step
		# Global identity invariant: i_org + local_x == global_i (continuous world position).
		if absf(float(chart.i_org) + local_x - float(global_i)) > 1e-9:
			continuous = false
		max_abs_local = maxf(max_abs_local, absf(local_x))
		var lp := Vector3(local_x, 5.0, 0.0)
		if chart.needs_reanchor(lp):
			# World point of the player's cell BEFORE the shift...
			var wc_before := Vector3i(int(floor(local_x)), 5, 0)
			var wp_before := chart.world_point_of(wc_before)
			var d := chart.reanchor(lp)
			local_x -= float(d.x)
			# ...and of the SAME physical cell AFTER (its window cell moved by −Δ, origin by +Δ).
			var wc_after := Vector3i(wc_before.x - d.x, 5, -d.y)
			var wp_after := chart.world_point_of(wc_after)
			var e := maxf(absf(wp_before.x - wp_after.x),
				maxf(absf(wp_before.y - wp_after.y), absf(wp_before.z - wp_after.z)))
			worst_wp_err = maxf(worst_wp_err, e)
			if e > 0.0:
				teleport_ok = false   # must be BIT-EXACT: same global cell → same world point
	_ok(continuous, "the world position stays continuous across a 10 km walk (i_org + local == global i)")
	_ok(teleport_ok, "each re-anchor is teleport-free: pre/post world point BIT-IDENTICAL (worst err %f m)" % worst_wp_err)
	_ok(global_i > 5000, "the simulated walk actually crossed 5+ km of face (global i = %d)" % global_i)
	# f32 safety: after the walk the band is tiny; contrast against an un-anchored 7000-block window.
	var band := float(CHART.SHIFT_TRIGGER + step)
	_ok(max_abs_local <= band + 1e-6, "local coords stayed within [−%.1f, %.1f] over the whole walk (max %.1f)" % [band, band, max_abs_local])
	var ulp_anchored := max_abs_local * pow(2.0, -23.0)
	var ulp_unanchored := 7000.0 * pow(2.0, -23.0)
	print("    f32 ULP: reanchored band %.6f m vs un-anchored 7 km %.6f m" % [ulp_anchored, ulp_unanchored])
	_ok(ulp_anchored < 1.0e-4, "the reanchored scene ULP is sub-0.1 mm (%.6f m)" % ulp_anchored)

	# Explicit 5–10 km cross-anchor identity: the same global cell (7000, 3000, 12) from two anchors.
	var cA := CHART.new(CS.HOME_BODY, CS.HOME_FACE, 6800, 2800)   # window (200, 12, 200)
	var cB := CHART.new(CS.HOME_BODY, CS.HOME_FACE, 7000, 3000)   # window (0, 12, 0)
	var pA := cA.world_point_of(Vector3i(200, 12, 200))
	var pB := cB.world_point_of(Vector3i(0, 12, 0))
	var pRef := CS.world_point(CS.HOME_FACE, 7000.0, 3000.0, 12.0, float(cA.radius), cA.n)
	var same := absf(pA.x - pB.x) == 0.0 and absf(pA.y - pB.y) == 0.0 and absf(pA.z - pB.z) == 0.0
	var ref_ok := absf(pA.x - pRef.x) == 0.0 and absf(pA.y - pRef.y) == 0.0 and absf(pA.z - pRef.z) == 0.0
	_ok(same and ref_ok, "the same 7 km global cell maps to one world point from either anchor (bit-identical)")
	_ok(cA.to_global_key(Vector3i(200, 12, 200)) == cB.to_global_key(Vector3i(0, 12, 0)),
		"...and to one global edit key from either anchor")

# ---------------------------------------------------------------------------------------
# (c) Worldgen is byte-identical regardless of chart anchor (§8.2 determinism).
# ---------------------------------------------------------------------------------------
func _test_worldgen_anchor_indep() -> void:
	print("[c] worldgen is byte-identical regardless of chart anchor (window-independent, §8.2)")
	# Two worlds with two DIFFERENT anchors, whose window cells fold to the SAME global cells.
	var wA := _bare_world(); wA.install_chart(CHART.new(CS.HOME_BODY, CS.HOME_FACE, 0, 0))
	var wB := _bare_world(); wB.install_chart(CHART.new(CS.HOME_BODY, CS.HOME_FACE, 300, 400))
	var indep := true
	for gi in [50, 500, 3003, 9000]:
		for gj in [70, 700, 5005]:
			for r in [-30, 0, 12, 60]:
				var wcA := Vector3i(gi - 0,   r, gj - 0)     # anchor A: window = global
				var wcB := Vector3i(gi - 300, r, gj - 400)   # anchor B: window = global − origin
				if wA.cell_value_at(wcA) != wB.cell_value_at(wcB):
					indep = false
	_ok(indep, "the same global cell generates an IDENTICAL packed value from either chart anchor")

	# The curved generator itself is a pure, order-independent function of (face, i, j) (§8.2).
	var pure := true
	for c in [[100, 200], [4096, 4096], [9000, 1000], [0, 0]]:
		var a := TC._curved_profile(CS.HOME_FACE, c[0], c[1])
		var b := TC._curved_profile(CS.HOME_FACE, c[0], c[1])
		if a != b:
			pure = false
	_ok(pure, "_curved_profile is bit-for-bit deterministic on re-call")

	# generated_cell_global for a fixed GLOBAL cell is identical however it is reached.
	var gc_ok := true
	for _t in range(3):
		if TC.generated_cell_global(CS.HOME_FACE, 512, 777, 4) != TC.generated_cell_global(CS.HOME_FACE, 512, 777, 4):
			gc_ok = false
	_ok(gc_ok, "generated_cell_global is deterministic for a fixed global cell")
	wA.free(); wB.free()

# ---------------------------------------------------------------------------------------
# (e) Latitude climate — pole cold, equator warm, monotonic-ish.
# ---------------------------------------------------------------------------------------
func _test_latitude_climate() -> void:
	print("[e] latitude climate: face-4 centre (pole) cold, equatorial belt warmer, monotonic-ish")
	var n := CS.n_for(CS.HOME_BODY)
	var half := n / 2

	# The pure latitude term is strictly monotonic in |latitude|: +0.8 at the equator, −0.8 at a pole.
	var eq := TC._latitude_temperature(0.0, 0.0)
	var pole := TC._latitude_temperature(1.0, 0.0)
	var mono := true
	var last := INF
	for k in range(0, 101):
		var dz := float(k) / 100.0
		var v := TC._latitude_temperature(dz, 0.0)
		if v > last + 1e-12:
			mono = false
		last = v
	_ok(eq > 0.5 and pole < -0.5, "pure latitude term: equator warm (%.3f), pole cold (%.3f)" % [eq, pole])
	_ok(mono, "pure latitude term is monotonic non-increasing from equator to pole")

	# face-4 CENTRE is the north pole (§5.2) → cold; an equatorial face centre (face 0) → warm.
	var t_pole := TC._curved_profile(4, half, half).w
	var t_eq := TC._curved_profile(0, half, half).w
	_ok(t_pole < -0.3, "face-4 centre (pole) climate is cold (t=%.3f < −0.3)" % t_pole)
	_ok(t_eq > 0.3, "an equatorial face centre climate is warm (t=%.3f > 0.3)" % t_eq)
	_ok(t_eq - t_pole > 0.9, "equator is clearly warmer than the pole (Δt=%.3f)" % (t_eq - t_pole))

	# Along a radial from the face-4 centre toward an edge, |d.z| falls, so climate warms. The pure
	# latitude term is flat near the pole (quadratic in u), so the ±0.30 noise dominates locally there
	# — "monotonic-ish" is a TREND claim, not per-step. Bin the radial into thirds and assert the band
	# means rise pole→middle→edge, and the edge is clearly warmer than the centre.
	var samples: Array = []
	var steps := 30
	for s in range(steps + 1):
		var i := half + int(round(float(s) / float(steps) * float(half - 1)))   # centre → i-edge
		samples.append(TC._curved_profile(4, i, half).w)
	var third := (samples.size()) / 3
	var m_pole := _mean(samples, 0, third)
	var m_mid := _mean(samples, third, 2 * third)
	var m_edge := _mean(samples, 2 * third, samples.size())
	_ok(m_pole < m_mid and m_mid < m_edge,
		"climate band means rise pole→middle→edge (%.3f < %.3f < %.3f)" % [m_pole, m_mid, m_edge])
	_ok(samples[samples.size() - 1] > samples[0] + 0.3, "the face-4 edge is clearly warmer than its centre (%.3f > %.3f)" % [samples[samples.size() - 1], samples[0]])

func _mean(a: Array, lo: int, hi: int) -> float:
	var s := 0.0
	for k in range(lo, hi):
		s += float(a[k])
	return s / float(hi - lo)

# ---------------------------------------------------------------------------------------
# (f) FLAT_WORLD-on ≡ pre-M2 edit behaviour at the data layer.
# ---------------------------------------------------------------------------------------
func _test_flat_byte_identity() -> void:
	print("[f] FLAT_WORLD / no chart ≡ pre-M2 edit behaviour (Vector3i keying, byte-identical)")
	var w := _bare_world()     # NO chart installed — exactly the FLAT_WORLD live configuration
	_ok(w.chart() == null, "a fresh world has no chart (FLAT_WORLD configuration)")
	var wc := Vector3i(12, 7, -34)
	var packed := CellCodec.pack(BlockCatalog.STONE, 0, 3)
	w._write_cell(wc, packed)
	_ok(w._edits.has(wc), "the overlay keys by the Vector3i WINDOW cell (pre-M2)")
	_ok(typeof(w._edits.keys()[0]) == TYPE_VECTOR3I, "the overlay key is a Vector3i, not a packed int")
	_ok(w.cell_value_at(wc) == packed, "cell_value_at reads the Vector3i-keyed edit back (state intact)")
	_ok(w.is_removed(Vector3i(0, 200, 0)) == false, "is_removed on an unedited cell is false")
	w._write_cell(Vector3i(0, 200, 0), 0)   # dig to air
	_ok(w.is_removed(Vector3i(0, 200, 0)), "is_removed on a dug cell is true (Vector3i key)")
	# maybe_reanchor is a byte-identical no-op with no chart.
	_ok(w.maybe_reanchor(Vector3(9999.0, 0.0, 9999.0)) == Vector3.ZERO, "maybe_reanchor is a no-op without a chart")
	_ok(WorldManager.region_origin_of(Vector3i(70, 5, -3)) == Vector3i(64, 0, -32),
		"region_origin_of stays the Vector3i 32-aligned grid (byte-identical)")
	w.free()

# ---------------------------------------------------------------------------------------
# (g) Per-(body,face) ZoneChunk region keys + a curved save_region/load_region round-trip.
# ---------------------------------------------------------------------------------------
func _test_region_keys() -> void:
	print("[g] per-(body,face) ZoneChunk region keys + curved save_region/load_region round-trip")
	var w := _bare_world()
	var chart := CHART.new(CS.HOME_BODY, CS.HOME_FACE, 0, 0)
	w.install_chart(chart)

	# The region key is the §1.3 per-(face, region_i, region_j, region_r) prefix, and it is per-FACE:
	# the same (i,j,r) on a different face is a different region (N is 32-aligned so none straddle).
	var cell := Vector3i(320, -32, 480)
	var rk := w.region_key_of(cell)
	_ok(rk == CS.region_key(CS.HOME_FACE, 320, 480, -32), "region_key_of == CubeSphere.region_key(face, i, j, r)")
	var other_face := CHART.new(CS.HOME_BODY, 0, 0, 0)
	_ok(other_face.to_region_key(cell) != rk, "the same (i,j,r) on another face is a DIFFERENT region (per-face)")
	# Every cell in one 32³ region shares the key; a neighbouring region differs.
	var same := w.region_key_of(Vector3i(320 + 31, -32 + 31, 480 + 31)) == rk
	var diff := w.region_key_of(Vector3i(320 + 32, -32, 480)) != rk
	_ok(same and diff, "the region key is constant across a 32³ region and differs for the neighbour")

	# Write a few edits, save the region they live in, load into a FRESH world, assert restored by
	# the SAME global cells — persistence twin of edit-survival (§1.3). Load under a re-origined
	# chart to prove the chunk re-materialises at the global cells, not the window positions.
	var cells := [Vector3i(325, -20, 485), Vector3i(330, -18, 490), Vector3i(322, -30, 500)]
	var vals := [CellCodec.pack(BlockCatalog.STONE), CellCodec.pack(BlockCatalog.GRASS), CellCodec.pack(BlockCatalog.DIRT)]
	for k in range(cells.size()):
		w._write_cell(cells[k], vals[k])
	var region_key := w.region_key_of(cells[0])
	# all three cells share the region (325..330 in [320,352), r −30..−20 in [−32,0), 485..500 in [480,512))
	var all_in := w.region_key_of(cells[1]) == region_key and w.region_key_of(cells[2]) == region_key
	_ok(all_in, "the three edits share one 32³ region")
	var bytes := w.save_region(region_key).to_bytes()

	var w2 := _bare_world()
	# Fresh world, chart re-origined by an arbitrary integer — global cells must still restore.
	w2.install_chart(CHART.new(CS.HOME_BODY, CS.HOME_FACE, 256, 128))
	w2.load_region(region_key, ZoneChunk.from_bytes(bytes))
	var restored := true
	for k in range(cells.size()):
		# global cell of cells[k] under the ORIGINAL (0,0) chart:
		var g := chart.to_global(cells[k])
		# its window cell under w2's re-origined chart:
		var wc2 := Vector3i(int(g["i"]) - 256, int(g["r"]), int(g["j"]) - 128)
		if w2.cell_value_at(wc2) != vals[k]:
			restored = false
	_ok(restored, "save_region/load_region restores every edit at its GLOBAL cell under a re-origined chart")
	_ok(w2._edits.size() == 3, "exactly the three saved edits were loaded")
	w.free(); w2.free()
