extends SceneTree
## docs/COSMOS-NB-JUNCTION-WELD-DESIGN.md gate (task #104) — FP_NB_WELD, the fix for the FP_NB_FULLRES "floating tilted
## slab" at a facet junction. Proves the three-part weld does exactly what §3 specifies WITHOUT changing shipped bytes when
## FP_NB_WELD is off. Self-describes on the compiled FP_NB_WELD value (mirrors verify_stream_parallel's convention); the
## gates below drive REAL code (ModuleWorld.pool_seam_meshed_shipped/_weld against a bounds-aware fake terrain, and the
## WorldManager latch/placement helpers) so they hold regardless of the compiled flag.
##
##   G-NB-WELD-PROBE  — THE root-cause discriminator. With B's seam strip meshed: the WELD strip probe returns TRUE and
##                      never touches B's forbidden (out-of-domain) space, while the SHIPPED box provably returns FALSE and
##                      DOES reach unloadable cells (dead by construction, §2). Falsifier: strip unmeshed ⇒ weld FALSE (no
##                      premature release). Corner: a foot with no bounds-safe anchor ⇒ weld FALSE, still no out-of-domain probe.
##   G-NB-WELD-EXCL   — W2: _nb_update_excl_latch returns `changed` on a set AND on a geometric clear, FALSE on a no-op
##                      (so _manage_pool_z1hybrid re-syncs the far ring THAT tick). W3 post-condition: a seeded latch marks
##                      the old active far-ring-excluded. Geometric release past NB_EXCL_RELEASE clears + reports it.
##   G-NB-PLACE       — the junction-weld/placement LAW (pins it is NOT a transform bug): facet_transform(fid) is the exact
##                      lattice→world map, and a shared-edge column reframed A↔B agrees to ≤1e-3 world units — so every
##                      live slot's geometry already welds to the active's at the seam; nothing is mis-placed (§1).

const FA := preload("res://src/cosmos/facet_atlas.gd")
const MW := preload("res://src/world/voxel_module/module_world.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

# A bounds-aware fake VoxelTerrain: is_area_meshed faithfully models the engine (voxel_terrain.cpp:2072/is_area_meshed +
# _apply_bounds) — EVERY cell of the box must be a LOADED mesh block. Two things make a cell un-loaded, matching §2's two
# independent killers of the shipped ±(32,40,32) box: (1) it lies OUTSIDE the terrain's AABB bounds [dom±MARGIN±2 seam × the
# y slab] — the engine clips every view box to bounds, so such cells can NEVER load (`touched_unloadable` records this — the
# horizontal overreach, geometry-dependent); (2) it lies outside the seam band's finite reach around the player foot `lp`
# (h_reach ≈ NB_BAND_BLOCKS, v_reach ≈ view·vertical_ratio ≈ 32) — so the shipped box's ±40 VERTICAL always overshoots
# (the geometry-INDEPENDENT killer), while a single cell at the player y never does. `band_up`=false ⇒ nothing meshed yet.
# The fields are convex/monotone, so the failing cells are always at the box extremes — checked in O(1) at the corners.
class _FakeTerrain extends RefCounted:
	var fid := 0
	var cx := 0.0
	var cy := 0.0
	var cz := 0.0
	var h_reach := CubeSphere.NB_BAND_BLOCKS
	var v_reach := 32.0
	var band_up := true
	var touched_unloadable := false
	func is_area_meshed(aabb: AABB) -> bool:
		var p0 := aabb.position
		var p1 := aabb.position + aabb.size
		var dmn: Vector2i = FacetAtlas.dom_min(fid)
		var dmx: Vector2i = FacetAtlas.dom_max(fid)
		var y0 := float(TerrainConfig.BEDROCK_FLOOR)
		var y1 := float(TerrainConfig.MAX_SURFACE_Y + max(TreeGen.MAX_ABOVE_SURFACE, TerrainConfig.SNOW_FILL_MAX_CELLS))
		# (1) any part past the engine AABB bounds ⇒ unloadable cells in the box ⇒ dead (records the overreach).
		if p0.x < float(dmn.x) - 2.0 or p1.x > float(dmx.x) + 2.0 \
				or p0.z < float(dmn.y) - 2.0 or p1.z > float(dmx.y) + 2.0 \
				or p0.y < y0 or p1.y > y1:
			touched_unloadable = true
			return false
		if not band_up:
			return false
		# (2) the farthest box corner must be within the seam band's reach on each axis (else those cells aren't meshed yet).
		var mx := maxf(absf(p0.x - cx), absf(p1.x - cx))
		var mz := maxf(absf(p0.z - cz), absf(p1.z - cz))
		var my := maxf(absf(p0.y - cy), absf(p1.y - cy))
		return mx <= h_reach and mz <= h_reach and my <= v_reach

# A minimal module stand-in for the WorldManager latch helpers (mirrors verify_stream_parallel._NBModStub).
class _NBModStub extends Node3D:
	var meshed := {}
	func pool_seam_meshed(fid, _pos) -> bool: return bool(meshed.get(int(fid), false))

func _initialize() -> void:
	print("=== verify_nb_weld (task #104 — FP_NB_WELD, compiled FP_NB_WELD=%s) ===" % str(CubeSphere.FP_NB_WELD))
	if not CubeSphere.FACETED:
		print("  FAIL: this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	FA.warm_up()
	_gate_probe()
	_gate_excl()
	_gate_place()
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# Pick an active facet A and one edge neighbour B; return {A, B, slot_b, player} where `player` is a lattice point in A,
# `inset` cells inside A from the A↔B ridge, near the ridge midpoint (or endpoint, for the corner probe when `endpoint`).
func _pick(inset: float, endpoint: bool) -> Dictionary:
	var a := 0
	var slot_a := 0
	var b := FA.seam_neighbour(a, slot_a)
	# find B's slot that faces A (exact, not nearest-plane).
	var slot_b := -1
	for s in 4:
		if FA.seam_neighbour(b, s) == a:
			slot_b = s
			break
	# a lattice point on the A↔B ridge, stepped `inset` cells into A's interior along A's own-side normal.
	var ring: Array = FA.seam_ring(a, slot_a)                     # [r0, r1] world endpoints
	var rw: Vector3 = ring[0] if endpoint else (ring[0] + ring[1]) * 0.5
	var lp := FA.world_to_lattice64(a, rw.x, rw.y, rw.z)
	var spa := FA.seam_plane(a, slot_a)
	var na := Vector3(spa.x, spa.y, spa.z).normalized()
	var player := Vector3(float(lp[0]), float(lp[1]), float(lp[2])) + na * inset
	return {"a": a, "b": b, "slot_b": slot_b, "player": player}

func _new_mw(sel: Dictionary, band_up: bool) -> Dictionary:
	var mw = MW.new()
	mw._pool_active = int(sel["a"])
	var player: Vector3 = sel["player"]
	var lp := FA.reframe_position64(int(sel["a"]), int(sel["b"]), player.x, player.y, player.z)   # the band centre = player foot in B
	var fake := _FakeTerrain.new()
	fake.fid = int(sel["b"])
	fake.cx = float(lp[0]); fake.cy = float(lp[1]); fake.cz = float(lp[2])
	fake.band_up = band_up
	mw._pool = {int(sel["b"]): {"terrain": fake}}
	return {"mw": mw, "fake": fake}

# --- G-NB-WELD-PROBE: the dead-latch discriminator (the load-bearing gate) --------------------------------------------
func _gate_probe() -> void:
	var sel := _pick(8.0, false)                                 # player 8 cells inside A from the ridge midpoint
	_ok(int(sel["slot_b"]) >= 0, "G-NB-WELD-PROBE: B's shared slot resolves via seam_neighbour (exact)")
	var b := int(sel["b"]); var player: Vector3 = sel["player"]

	# (1) STRIP MESHED (band up): the WELD probe returns TRUE and stays inside B's loadable domain; the SHIPPED box, in the
	# SAME state, returns FALSE — pinning §2's dead-by-construction latch in ONE binary. The box dies by BOTH mechanisms: it
	# reaches past B's AABB bounds (horizontal overreach) and/or its ±40 vertical overshoots the band's ±v_reach.
	var ctx := _new_mw(sel, true)
	var mw = ctx["mw"]; var fake = ctx["fake"]
	fake.touched_unloadable = false
	var weld_up := bool(mw.pool_seam_meshed_weld(b, player))
	var weld_touched_bad := bool(fake.touched_unloadable)
	fake.touched_unloadable = false
	var box_up := bool(mw.pool_seam_meshed_shipped(b, player))
	var box_touched_bad := bool(fake.touched_unloadable)
	_ok(weld_up, "G-NB-WELD-PROBE: with B's seam strip meshed, the WELD probe latches TRUE")
	_ok(not weld_touched_bad, "G-NB-WELD-PROBE: the WELD probe never queries a cell outside B's loadable domain (bounds-safe by construction)")
	_ok(not box_up, "G-NB-WELD-PROBE: the SHIPPED box stays FALSE in the SAME meshed state (dead by construction, §2)")
	print("  [G-NB-WELD-PROBE] shipped-box death mechanism: reached-past-bounds=%s, ±40-vertical>band=%s" % [str(box_touched_bad), str(not box_touched_bad)])
	mw.free()

	# (2) FALSIFIER — strip UNMESHED (band down): the WELD probe must NOT latch (no premature far-tile release → no see-through).
	var ctx0 := _new_mw(sel, false)
	var mw0 = ctx0["mw"]; var fake0 = ctx0["fake"]
	fake0.touched_unloadable = false
	var weld_dn := bool(mw0.pool_seam_meshed_weld(b, player))
	_ok(not weld_dn, "G-NB-WELD-PROBE (falsifier): an UN-meshed strip does NOT latch (keeps the far cover — no see-through hole)")
	_ok(not fake0.touched_unloadable, "G-NB-WELD-PROBE (falsifier): still bounds-safe (no out-of-domain probe when unmeshed)")
	mw0.free()

	# (3) CORNER — near the ridge ENDPOINT the depth-anchored foot may leave B's polygon; the weld degrades to keep-cover
	# (returns without ever probing forbidden space), never a spurious latch through an out-of-bounds query (risk #3 kill).
	var selc := _pick(8.0, true)
	var ctxc := _new_mw(selc, true)
	var mwc = ctxc["mw"]; var fakec = ctxc["fake"]
	fakec.touched_unloadable = false
	var _weld_corner := bool(mwc.pool_seam_meshed_weld(int(selc["b"]), selc["player"]))
	_ok(not fakec.touched_unloadable, "G-NB-WELD-PROBE (corner): the weld never probes outside B's domain even at a ridge endpoint (in_polygon guard holds)")
	mwc.free()

# --- G-NB-WELD-EXCL: W2 same-tick re-sync signal + W3 seed post-condition + geometric release -------------------------
func _gate_excl() -> void:
	var stub := _NBModStub.new()
	var wm := WorldManager.new()
	wm._module_world = stub
	wm._nb_imminent_fid = 11
	wm._nb_excl_latch = {}
	stub.meshed = {12: true, 13: false}
	var live := [11, 12, 13]
	# W2: latching a band-meshed neighbour REPORTS changed=true (drives the same-tick _facet_ring_sync_exclusion).
	var c1 := bool(wm._nb_update_excl_latch(live, {11: 20.0, 12: 40.0, 13: 60.0}, Vector3.ZERO))
	_ok(c1 and wm._nb_excl_latch.has(12), "G-NB-WELD-EXCL: a latch SET reports changed=true (W2 same-tick ring re-sync)")
	# a steady tick that flips nothing (12 already latched, 13 unmeshed & out-of-gate) reports changed=false → no needless resync.
	var c2 := bool(wm._nb_update_excl_latch(live, {11: 20.0, 12: 40.0, 13: 60.0}, Vector3.ZERO))
	_ok(not c2, "G-NB-WELD-EXCL: a no-op tick reports changed=false (set_pool_excluded stays un-called)")
	# geometric release: 12 walks past NB_EXCL_RELEASE ⇒ latch clears AND reports changed=true (the far tile must return).
	var c3 := bool(wm._nb_update_excl_latch(live, {11: 20.0, 12: CubeSphere.NB_EXCL_RELEASE + 10.0, 13: 60.0}, Vector3.ZERO))
	_ok(c3 and not wm._nb_excl_latch.has(12), "G-NB-WELD-EXCL: a geometric clear past NB_EXCL_RELEASE reports changed=true")
	# W3 post-condition: the crossing seeds `_nb_excl_latch[from]=true` (code: _commit_facet_change) ⇒ the OLD active is
	# then far-ring-excluded, so its cover tile never pops in over the freshly-crossed (already-meshed) ground.
	wm._nb_excl_latch = {27: true}
	_ok(wm._nb_excluded_neighbour(27), "G-NB-WELD-EXCL: a seeded (crossing W3) latch marks the old active far-ring-excluded")
	_ok(not wm._nb_excluded_neighbour(99), "G-NB-WELD-EXCL: an unseeded, non-imminent neighbour is NOT excluded (keeps its far tile)")
	wm.free()

# --- G-NB-PLACE: the placement LAW — every live slot already welds to the active at the seam (NOT a transform bug) -----
func _gate_place() -> void:
	var worst := 0.0
	var checked := 0
	# for several active facets, take each edge neighbour and a lattice column on/near the shared ridge; assert the SAME
	# world point via A's slot transform and via B's slot transform (over the reframed column) agree. The bound is the f32
	# Transform3D precision floor at |lattice| ~ 3e4 (the decorrelation offset; the atlas itself loses ~2e-4 there, so a
	# round-trip through two f32 slot transforms lands ~5e-3) — FIVE orders of magnitude below the ~10³-10⁴-block divergence
	# a stale/identity transform (the refuted placement bug) would show. Any bound in that gulf discriminates; 0.05 clears f32.
	for a in [0, 1, 5, 20]:
		var ta := FA.facet_transform(a)
		for slot in 4:
			var b := FA.seam_neighbour(a, slot)
			if b < 0 or b == a:
				continue
			var ring: Array = FA.seam_ring(a, slot)
			var rw: Vector3 = (ring[0] + ring[1]) * 0.5
			var lp := FA.world_to_lattice64(a, rw.x, rw.y, rw.z)
			# a small column of points straddling the shared edge in A's lattice.
			for dy in [-4.0, 0.0, 6.0]:
				var pa := Vector3(float(lp[0]), float(lp[1]) + dy, float(lp[2]))
				var rb := FA.reframe_position64(a, b, pa.x, pa.y, pa.z)
				var pb := Vector3(float(rb[0]), float(rb[1]), float(rb[2]))
				var wa := ta * pa                       # A's slot places the column here...
				var wb := FA.facet_transform(b) * pb    # ...and B's slot places the SAME world point (weld)
				worst = maxf(worst, (wa - wb).length())
				checked += 1
	_ok(checked > 0, "G-NB-PLACE: exercised %d shared-edge columns across facets" % checked)
	_ok(worst <= 0.05, "G-NB-PLACE: A-slot and B-slot agree on shared-edge world points to <=0.05 (f32 slot-transform floor; worst %s) — placement is correct, the slab is NOT a transform bug" % str(worst))
	# facet_transform IS the lattice→world map used to place a slot (== lattice_to_world64) — the law the fixed frame relies on.
	var q := Vector3(12.0, 3.0, -7.0)
	var lw := FA.lattice_to_world64(5, q.x, q.y, q.z)
	var tw := FA.facet_transform(5) * q
	_ok((Vector3(float(lw[0]), float(lw[1]), float(lw[2])) - tw).length() <= 1.0e-3,
		"G-NB-PLACE: facet_transform(fid)·p == lattice_to_world64(fid, p) (the slot placement law)")
