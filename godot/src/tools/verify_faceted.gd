extends SceneTree
## COSMOS FP1 gate (docs/COSMOS-FACETED-IMPL.md §4.7) — the playable-facet suite. Runs with FACETED = true
## (the gate runner sed-toggles it, like the FLAT_WORLD=false curved gates). Covers:
##   G-F1e  frame math      — every facet's frame is orthonormal, right-handed, outward, planar, round-trips
##   G-F1a  purity          — worker column == analytic column; generated_cell is deterministic across passes
##   G-F1d  spawn margin     — the spawn column sits ≥ 32 cells inside the facet polygon
##   G-F1f  seam continuity  — the two facets straddling a shared ridge agree in surface height (≤ 2 blocks)
## The off-toggle byte-identity (G-F1c) is a SEPARATE run: verify_feature + the curved suite with FACETED=false.

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_faceted (FP1 playable facet) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	if not CubeSphere.FLAT_WORLD:
		print("  FAIL: FACETED requires FLAT_WORLD = true (a facet is a flat world).")
		quit(1)
		return

	TC.warm_up()
	FA.warm_up()
	var nf := FA.facet_count()
	print("  atlas: %d facets (k=%d, R=%d), spawn facet=%d" % [nf, FA.K, int(FA.R_BLOCKS), FA.spawn_facet()])

	_gate_frame_math(nf)
	_gate_purity()
	_gate_spawn_margin()
	_gate_seam_continuity()
	_gate_seams(nf)
	_gate_crossing_math(nf)
	_gate_bevel_reuse(nf)
	_gate_junction_encode()
	_gate_junction_mesh()
	_gate_far_ring()
	_gate_live_loop()
	_gate_near_radius()              # FP-S1(a)
	_gate_block_early_out()          # FP-S1(b)
	_gate_crossing_containment()     # FP-S1(c)
	_gate_edit_key_global()          # FP-M1a G-M1-KEY

	# FP-M1c Planet Assembly gates (docs/COSMOS-FP-M1-DESIGN.md §11). Run ONLY when the pool flag is on AND the
	# module binary is present (they build a live VoxelTerrain pool). With just FACETED=true they are skipped, so
	# the standard faceted run stays at its baseline pass count; sed FP_M1_POOL=true to exercise them (payload gate).
	if CubeSphere.FP_M1_POOL and ClassDB.class_exists("VoxelTerrain"):
		await _gate_pool_assembly()      # G-M1-POOL + G-M1-MEM
		await _gate_redesignation()      # G-M1-XDES
		await _gate_pool_ramp()          # G-M1-RAMP (per-slot view ramp — the border-hitch fix)
		_gate_two_facet_seam()           # G-M1-SEAM-1 / SEAM-2
		await _gate_pool_walk_soak()     # end-to-end: WorldManager crossing is a POOL HIT (pool-miss 0)
	elif CubeSphere.FP_M1_POOL:
		print("  NOTE: FP_M1_POOL on but no VoxelTerrain (module absent) — FP-M1c live gates skipped (need the module binary).")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# G-F1b — the flat engine plays a facet. Build a bare WorldManager (FACETED=true → it installs the spawn facet
# and answers analytic cell/physics queries with the facet terrain), then run the break/place/collapse loop the
# flat game uses: solid ground with air above, break carves the overlay to air, floor_under drops into the hole,
# place writes to the overlay, and a break under an unsupported cluster detaches it as a loose VoxelBody.
func _gate_live_loop() -> void:
	TC.set_active_facet(FA.spawn_facet())          # deterministic: play the spawn facet
	var w := WorldManager.new()
	w.name = "FacetLive"
	get_root().add_child(w)
	var s: Vector2i = TC.find_spawn()
	var cx := s.x
	var cz := s.y
	var sy := int(round(w.surface_y(float(cx) + 0.5, float(cz) + 0.5)))
	# find the topmost solid cell near the reported surface (surface_y is the top FACE, so the top solid cell
	# is sy−1; scan to be robust to the exact convention and to snow/tree caps)
	var top := sy + 4
	while top > sy - 8 and w.block_id_at(Vector3i(cx, top, cz)) == 0:
		top -= 1
	_ok(BlockCatalog.solidity_of(w.block_id_at(Vector3i(cx, top, cz))) >= 0.5, "facet live: solid ground at top cell y=%d (surface_y≈%d)" % [top, sy])
	_ok(w.block_id_at(Vector3i(cx, top + 1, cz)) == 0, "facet live: air directly above the surface (y=%d)" % (top + 1))
	# break the top solid cell → overlay air; floor_under must drop after digging
	var feet := float(top) + 1.5
	var fu0 := w.floor_under(float(cx) + 0.5, float(cz) + 0.5, feet)
	var broke := w.break_terrain(Vector3i(cx, top, cz)) > 0
	_ok(broke and w.block_id_at(Vector3i(cx, top, cz)) == 0, "facet live: break_terrain carves the top cell to air (overlay)")
	var fu1 := w.floor_under(float(cx) + 0.5, float(cz) + 0.5, feet)
	_ok(fu1 < fu0 - 0.5, "facet live: floor_under drops after digging (%.2f → %.2f, no teleport)" % [fu0, fu1])
	# place STONE back into the just-dug cell (guaranteed air, adjacent to solid below) → overlay id
	var placed := w.place_block(Vector3i(cx, top, cz), BlockCatalog.STONE)
	_ok(placed and CellCodec.mat(w.block_id_at(Vector3i(cx, top, cz))) == BlockCatalog.STONE, "facet live: place_block writes STONE to the overlay")
	# collapse: place then break an isolated floating block — the structural pass must run without error
	var body_count_before := _loose_bodies(w)
	w.place_block(Vector3i(cx + 4, top + 6, cz + 4), BlockCatalog.STONE)   # isolated floater
	w.break_terrain(Vector3i(cx + 4, top + 6, cz + 4))                      # break it → structural pass runs
	_ok(_loose_bodies(w) >= body_count_before, "facet live: collapse pass runs without error on the facet")
	# FP2 B3a — junction physics through the WM: a cell wholly beyond a ridge MASKS to AIR, and a straddling
	# cell is a solid kind-2 junction (so _occ_span composes a partial interval, and the fallback mesher clips).
	var fidx := FA.spawn_facet()
	var lo2: Vector2i = FA.dom_min(fidx)
	var hi2: Vector2i = FA.dom_max(fidx)
	var masked_ok := false
	var junction_ok := false
	var zz := lo2.y
	while zz <= hi2.y and not (masked_ok and junction_ok):
		var xx := lo2.x
		while xx <= hi2.x:
			var gg := TC.height_at(xx, zz)
			var stj := FA.cell_seam_state(fidx, xx, gg - 1, zz)
			if stj["air"]:
				if w.block_id_at(Vector3i(xx, gg - 1, zz)) == 0:
					masked_ok = true
			elif not (stj["straddle"] as PackedInt32Array).is_empty():
				var vj := w.cell_value_at(Vector3i(xx, gg - 1, zz))
				if CellCodec.is_junction(CellCodec.modifier(vj)) and BlockCatalog.solidity_of(CellCodec.mat(vj)) >= 0.5:
					junction_ok = true
			xx += 1
		zz += 1
	_ok(masked_ok, "junction physics: a beyond-ridge cell masks to AIR (block_id_at == 0)")
	_ok(junction_ok, "junction physics: a straddling cell is a solid kind-2 junction via WM.cell_value_at")
	# FP2 Stage D — the ridge wall: blocked() lets the player stand in the interior but stops them at a ridge.
	# FP3: the FP2 ridge wall is gone — the crossing handoff replaces it. blocked() must let the player walk all
	# the way TO the ridge (and slightly past, where the crossing fires); only a DEEP backstop (>3 blocks past P,
	# a failed-crossing catch) still blocks. "Interior walkable": some interior, non-ridge column is not walled.
	var base_iz := cz + 5
	var wall_in := false
	var ridge_open := false          # the player is NOT walled right at / just past the ridge (crossing handles it)
	var backstop := false            # the deep backstop DOES block far past the ridge
	var scanned := false
	for dd in range(0, 60, 2):
		var jx := cx + dd
		var jfeet := w.surface_y(float(jx) + 0.5, float(base_iz) + 0.5)   # the standable height the player uses
		var odmin := 1.0e18
		for slot in range(4):
			odmin = minf(odmin, FA.own_dist(fidx, slot, float(jx) + 0.5, jfeet, float(base_iz) + 0.5))
		if odmin < 3.0:
			continue
		if not w.blocked(float(jx) + 0.5, float(base_iz) + 0.5, jfeet):
			wall_in = true
			for d in range(1, 400):
				var px := float(jx + d) + 0.5
				var od := 1.0e18
				for slot in range(4):
					od = minf(od, FA.own_dist(fidx, slot, px, jfeet, float(base_iz) + 0.5))
				if od < 0.1 and not scanned:
					ridge_open = not w.blocked(px, float(base_iz) + 0.5, jfeet)   # NOT walled at the ridge
					scanned = true
				if od < -3.5:
					backstop = w.blocked(px, float(base_iz) + 0.5, jfeet)         # deep backstop DOES block
					break
			break
	_ok(wall_in, "facet wall: an interior column is walkable (not blanket-walled)")
	_ok(scanned and ridge_open, "facet crossing: the player is NOT walled at the ridge (handoff replaces the wall)")
	_ok(backstop, "facet crossing: a deep backstop still blocks far past the ridge (failed-crossing catch)")
	# FP3 crossing smoke test: a synthetic position past a ridge fires maybe_cross_facet + switches the active facet.
	TC.set_active_facet(fidx)
	var cross_found := false
	var cross_res := {}
	for d in range(1, 400):
		var px := float(cx + d) + 0.5
		var pf := w.surface_y(px, float(cz) + 0.5)
		var mn := 1.0e18
		for slot in range(4):
			mn = minf(mn, FA.own_dist(fidx, slot, px, pf, float(cz) + 0.5))
		if mn < -1.0:
			cross_res = w.maybe_cross_facet(Vector3(px, pf, float(cz) + 0.5))
			cross_found = true
			break
	_ok(cross_found and cross_res.get("crossed", false), "crossing: maybe_cross_facet fires past a ridge")
	var to_fid := int(cross_res.get("to", -1))
	_ok(to_fid >= 0 and TC.active_facet() == to_fid, "crossing: active facet switched to the neighbour (%d→%d)" % [fidx, to_fid])
	TC.set_active_facet(fidx)                          # restore the spawn facet
	w.queue_free()

# FP-S1(a) — a facet must stream the CHEAP curved near radius (128), NOT the flat 256. FACETED requires FLAT_WORLD=true,
# so the old `FLAT_WORLD ? 256 : 128` branch wrongly gave a facet the full 256 (≈4× the box, ~8× the per-column cost
# per crossing restream). The fix routes FACETED to CURVED_RENDER_RADIUS_BLOCKS. (FLAT non-faceted byte-identity — the
# 256 branch — is covered by the separate verify_feature.gd run with FACETED=false.)
func _gate_near_radius() -> void:
	var r := TC.near_render_radius()
	_ok(r == TC.CURVED_RENDER_RADIUS_BLOCKS, "FP-S1(a): near_render_radius()=%d == CURVED_RENDER_RADIUS_BLOCKS(%d) under FACETED" % [r, TC.CURVED_RENDER_RADIUS_BLOCKS])
	_ok(r == 128, "FP-S1(a): the faceted near radius is 128 blocks")
	_ok(r != TC.RENDER_RADIUS_BLOCKS, "FP-S1(a): FACETED does NOT take the flat %d branch" % TC.RENDER_RADIUS_BLOCKS)

# FP-S1(b) — the BLOCK-level facet-domain early-out (FacetAtlas.block_all_air) must be CONSERVATIVE: whenever it
# returns true for a block, EVERY cell in that block masks to AIR under junction_modify (the per-cell mask the module
# generator applies at its buffer-write exit). So skipping such a block emits byte-identical voxels (all air), just
# faster. This gate sweeps block origins from deep interior out into foreign territory and asserts: (i) SOUNDNESS —
# no block_all_air block contains any cell junction_modify would KEEP (deep-scanned, capped); (ii) the optimisation
# actually FIRES (some wholly-foreign block is caught) and does NOT over-fire (an interior surface block is kept).
func _gate_block_early_out() -> void:
	var fid := FA.spawn_facet()
	var lo: Vector2i = FA.dom_min(fid)
	var hi: Vector2i = FA.dom_max(fid)
	var full := CellCodec.pack(BlockCatalog.STONE, 0)      # a solid probe: junction_modify returns 0 ONLY via ridge masking
	var BS := 8
	var span_x := hi.x - lo.x
	var span_z := hi.y - lo.y
	var unsound := 0
	var caught := 0
	var deep := 0                                          # deep soundness scans done (capped for runtime)
	var interior_kept := false
	var ox := lo.x - span_x
	while ox <= hi.x + span_x:
		var oz := lo.y - span_z
		while oz <= hi.y + span_z:
			var cix := clampi(ox + BS / 2, lo.x, hi.x)
			var ciz := clampi(oz + BS / 2, lo.y, hi.y)
			var oy := int(TC.height_at(cix, ciz)) - BS / 2   # straddle the surface where content lives
			if FA.block_all_air(fid, ox, oy, oz, BS, BS, BS, 1):
				caught += 1
				if deep < 40:                                # SOUNDNESS: no cell in a "wholly air" block may survive the mask
					deep += 1
					for x in range(BS):
						for z in range(BS):
							for y in range(BS):
								if FA.junction_modify(fid, Vector3i(ox + x, oy + y, oz + z), full) != 0:
									unsound += 1
			elif ox >= lo.x and ox <= hi.x and oz >= lo.y and oz <= hi.y:
				interior_kept = true                          # a domain-interior surface block is NOT skipped
			oz += BS
		ox += BS
	_ok(unsound == 0, "FP-S1(b): block_all_air is SOUND — every skipped block's cells all mask to AIR (%d deep-scanned, 0 survivors)" % deep)
	_ok(caught > 0, "FP-S1(b): the block-level early-out FIRES on foreign territory (%d blocks skipped)" % caught)
	_ok(interior_kept, "FP-S1(b): an interior surface block is NOT wrongly skipped (early-out is conservative)")

# FP-S1(c) — the crossing containment check + cooldown kill the near-corner ping-pong storm (§4-R3) WITHOUT trapping
# the player. Three properties:
#   (1) INVARIANT: any COMMITTED crossing lands CONTAINED — the reframed position is interior (own_dist >= −HYST) to
#       ALL FOUR of the destination's ridges, so it can never itself immediately re-fire.
#   (2) NO STORM: a STATIONARY player parked in a corner region (past ≥2 of the active facet's ridges) — the exact
#       ping-pong trigger — crosses ≤1 time over many ticks (the fix defers the corner rather than B→C→B storming).
#   (3) NO TRAP: a normal mid-edge crossing (a straight march past ONE ridge near an edge midpoint) still succeeds.
func _gate_crossing_containment() -> void:
	var fid := FA.spawn_facet()
	var HYST := WorldManager.FACET_CROSS_HYST
	var cc := FA.centre_cell(fid)
	var w := WorldManager.new(); w.name = "FCrossContain"; get_root().add_child(w)
	TC.set_active_facet(fid)
	var y0 := w.surface_y(float(cc.x) + 0.5, float(cc.y) + 0.5)   # a representative feet height for the ridge planes
	# (2) build a corner-region position: push a domain corner OUTWARD past the ridges until it is beyond ≥2 of them.
	var lo: Vector2i = FA.dom_min(fid)
	var hi: Vector2i = FA.dom_max(fid)
	var corners := [Vector2(hi.x, hi.y), Vector2(hi.x, lo.y), Vector2(lo.x, hi.y), Vector2(lo.x, lo.y)]
	var cpx := 0.0; var cpz := 0.0; var found := false
	for corner in corners:
		var dirx := signf(corner.x - float(cc.x))
		var dirz := signf(corner.y - float(cc.y))
		for push in [1.0, 3.0, 5.0, 8.0, 12.0]:
			var qx: float = corner.x + dirx * push + 0.5
			var qz: float = corner.y + dirz * push + 0.5
			var past := 0
			for slot in range(4):
				if FA.own_dist(fid, slot, qx, y0, qz) < -HYST:
					past += 1
			if past >= 2:
				cpx = qx; cpz = qz; found = true
				break
		if found:
			break
	_ok(found, "FP-S1(c): constructed a corner-region position (past ≥2 of the active facet's ridges)")
	# stationary storm test: reframe after each cross (as the player does) but never MOVE. Count crossings + check
	# every landing is contained.
	var crossings := 0
	var contain_violations := 0
	var apx := cpx; var apz := cpz
	for _call in range(40):
		var apy := w.surface_y(apx, apz)
		var res := w.maybe_cross_facet(Vector3(apx, apy, apz))
		if res.get("crossed", false):
			crossings += 1
			var to := int(res["to"])
			var np: Vector3 = res["new_pos"]
			for bslot in range(4):
				if FA.own_dist(to, bslot, np.x, np.y, np.z) < -HYST - 1e-4:
					contain_violations += 1
			apx = np.x; apz = np.z              # reframe into the new facet, but stay put (stationary)
	_ok(crossings <= 1, "FP-S1(c): a STATIONARY corner player does not cross-storm (%d crossings over 40 ticks ≤ 1)" % crossings)
	_ok(contain_violations == 0, "FP-S1(c): every committed crossing lands interior to ALL of B's ridges (no immediate re-fire)")
	w.queue_free()
	# (3) NO-TRAP: a normal mid-edge crossing still fires (straight +X march from centre → crosses the +X ridge once).
	var w2 := WorldManager.new(); w2.name = "FCrossMid"; get_root().add_child(w2)
	TC.set_active_facet(fid)
	var mx := float(cc.x) + 0.5; var mz := float(cc.y) + 0.5
	var midcross := 0
	for _step in range(600):
		mx += 1.0
		var my := w2.surface_y(mx, mz)
		var r := w2.maybe_cross_facet(Vector3(mx, my, mz))
		if r.get("crossed", false):
			midcross += 1
			break
	_ok(midcross == 1, "FP-S1(c): a normal mid-edge crossing still succeeds (containment does not trap the player)")
	w2.queue_free()
	TC.set_active_facet(fid)

# ---------------------------------------------------------------------------------------
# G-M1-KEY (COSMOS-FP-M1-DESIGN §11 FP-M1a / §6.2) — the (fid, cell) GLOBAL edit key. Under FACETED the
# edit overlay MUST key by (facet, lattice cell), never the active-lattice Vector3i: a Vector3i key
# silently re-interprets after a crossing, so a block placed on facet A corrupts once B is active. This
# gate places edits on BOTH sides of a seam, drives a REAL cross-and-return (A→B→A) through the existing
# maybe_cross_facet path, and proves: (a) edits are stored under (fid,cell) int keys — NO Vector3i key
# ever enters the overlay; (b) A-edits survive the round-trip byte-identical (same block id / packed
# value); (c) A and B edits coexist without collision; (d) the window-keyed PERF indices re-derive ==
# the incrementally-maintained ones; (e) the fidcell-v1 save fence tags faceted saves and refuses a
# cross-mode (legacy) chunk.
func _gate_edit_key_global() -> void:
	var A := FA.spawn_facet()
	var B: int = FA.seam_neighbour(A, 0)            # an edge neighbour — a mid-edge crossing lands contained
	TC.set_active_facet(A)
	var w := WorldManager.new(); w.name = "FEditKey"; get_root().add_child(w)

	# --- A-side edits (active = A): dig the top cell, place STONE just above it ---
	var s: Vector2i = TC.find_spawn()
	var cxA := s.x; var czA := s.y
	var topA := _top_solid(w, cxA, czA)
	var dig_A := Vector3i(cxA, topA, czA)
	var place_A := Vector3i(cxA + 2, topA + 1, czA)
	var broke_A := w.break_terrain(dig_A) > 0
	var placed_A := w.place_block(place_A, BlockCatalog.STONE)
	var exp_dig_A := w.block_id_at(dig_A)           # 0 (air)
	var exp_place_A := w.block_id_at(place_A)        # STONE material id
	var pak_place_A: int = w._edits.get(FA.edit_key(A, place_A), -999)
	var key_dig_A := FA.edit_key(A, dig_A)
	var key_place_A := FA.edit_key(A, place_A)
	_ok(broke_A and placed_A, "G-M1-KEY: A-side break+place succeed (active facet A=%d)" % A)
	_ok(w._edits.has(key_dig_A) and w._edits.has(key_place_A),
		"G-M1-KEY: A edits stored under (fid,cell) global keys")

	# --- index parity on A: the incremental _edit_columns/_placed_top == a full re-derive ---
	var inc_cols: Dictionary = w._edit_columns.duplicate()
	var inc_top: Dictionary = w._placed_top.duplicate()
	w._rebuild_window_indices()
	_ok(_dict_eq(inc_cols, w._edit_columns) and _dict_eq(inc_top, w._placed_top),
		"G-M1-KEY: incremental _edit_columns/_placed_top == full _rebuild_window_indices (A)")

	# --- REAL crossing A→B through maybe_cross_facet ---
	var rAB := _drive_cross_to(w, B)
	_ok(bool(rAB.get("crossed", false)) and TC.active_facet() == B,
		"G-M1-KEY: real crossing A→B via maybe_cross_facet (active=%d, want %d)" % [TC.active_facet(), B])
	# A edits are UNTOUCHED and NOT re-interpreted in B's lattice: the (A,cell) key + value survive.
	_ok(w._edits.has(key_place_A) and int(w._edits[key_place_A]) == pak_place_A,
		"G-M1-KEY: the A edit's (A,cell) key + packed value are unchanged after the crossing")

	# --- B-side edits (active = B): a placement in B's own lattice, on the OTHER side of the seam ---
	var ccB := FA.centre_cell(B)
	var cxB := ccB.x; var czB := ccB.y
	var topB := _top_solid(w, cxB, czB)
	var place_B := Vector3i(cxB, topB + 1, czB)
	var placed_B := w.place_block(place_B, BlockCatalog.STONE)
	var exp_place_B := w.block_id_at(place_B)
	var key_place_B := FA.edit_key(B, place_B)
	_ok(placed_B and w._edits.has(key_place_B), "G-M1-KEY: B-side edit stored under (B,cell) key")

	# both A and B keys coexist; assert NO Vector3i key and every key decodes to A or B.
	var all_int := true
	var all_decode := true
	var saw_a := false
	var saw_b := false
	for k in w._edits.keys():
		if typeof(k) != TYPE_INT:
			all_int = false
			continue
		var fid: int = FA.edit_key_fid(k)
		if fid == A: saw_a = true
		elif fid == B: saw_b = true
		else: all_decode = false
	_ok(all_int, "G-M1-KEY: NO Vector3i-keyed edit under FACETED (every overlay key is a packed int)")
	_ok(all_decode and saw_a and saw_b,
		"G-M1-KEY: A and B edits coexist under distinct (fid,cell) keys (no collision)")

	# --- REAL return crossing B→A ---
	var rBA := _drive_cross_to(w, A)
	_ok(bool(rBA.get("crossed", false)) and TC.active_facet() == A,
		"G-M1-KEY: real return crossing B→A via maybe_cross_facet (active=%d)" % TC.active_facet())
	# THE round-trip assertion: every A edit resolves to the SAME block/value after A→B→A (byte-identical).
	_ok(w.block_id_at(dig_A) == exp_dig_A and w.block_id_at(place_A) == exp_place_A
			and int(w._edits.get(key_place_A, -999)) == pak_place_A,
		"G-M1-KEY: A edits byte-identical after A→B→A round-trip (block ids + packed value unchanged)")

	# --- cross A→B once more: the B edit survives the round-trip too ---
	var rAB2 := _drive_cross_to(w, B)
	_ok(bool(rAB2.get("crossed", false)) and w.block_id_at(place_B) == exp_place_B,
		"G-M1-KEY: B edit byte-identical after the round-trip (seen again when B is active)")
	TC.set_active_facet(A)
	w.queue_free()

	# --- §6.3 save fence: a faceted save tags fidcell-v1 (survives serialization); a legacy chunk is refused ---
	var w2 := WorldManager.new(); w2.name = "FEditKeyFence"; get_root().add_child(w2)
	var ro := WorldManager.region_origin_of(place_A)
	w2.place_block(place_A, BlockCatalog.STONE)
	var zc := w2.save_edits(ro)
	_ok(zc.key_format() == ZoneChunk.FIDCELL_V1, "G-M1-KEY: faceted save_edits tags key_format = fidcell-v1")
	var zc2 := ZoneChunk.from_bytes(zc.to_bytes())
	_ok(zc2.key_format() == ZoneChunk.FIDCELL_V1, "G-M1-KEY: the fidcell-v1 fence survives to_bytes/from_bytes")
	var w3 := WorldManager.new(); w3.name = "FEditKeyLoad"; get_root().add_child(w3)
	w3.load_edits(ro, zc2)
	_ok(w3.block_id_at(place_A) == exp_place_A, "G-M1-KEY: a fidcell-v1 chunk loads into a faceted session (cell restored)")
	# a legacy (untagged) chunk is REFUSED by the faceted loader — the cell stays at its generated value.
	var lp := place_A - ro
	var legacy := ZoneChunk.new()
	legacy.set_cell(ZoneChunk.local_index(lp.x, lp.y, lp.z), CellCodec.pack(BlockCatalog.STONE), null)
	var w4 := WorldManager.new(); w4.name = "FEditKeyLegacy"; get_root().add_child(w4)
	var before := w4.block_id_at(place_A)
	w4.load_edits(ro, legacy)
	_ok(w4.block_id_at(place_A) == before, "G-M1-KEY: the faceted loader REFUSES a legacy (unfenced) chunk (fence holds)")
	w2.queue_free(); w3.queue_free(); w4.queue_free()
	TC.set_active_facet(A)

## G-M1-KEY helper: the topmost solid cell of column (cx, cz) in the ACTIVE facet (surface_y is the top
## FACE, so scan down from a little above to the first solid cell — robust to snow/tree caps).
func _top_solid(w: WorldManager, cx: int, cz: int) -> int:
	var sy := int(round(w.surface_y(float(cx) + 0.5, float(cz) + 0.5)))
	var top := sy + 4
	while top > sy - 8 and w.block_id_at(Vector3i(cx, top, cz)) == 0:
		top -= 1
	return top

## G-M1-KEY helper: drive maybe_cross_facet to cross from the CURRENT active facet onto `target`. Marches
## straight down the gradient of `target`'s ridge own_dist from the facet centre (the plane is affine, so
## the xz-gradient is a constant heading toward the ridge midpoint → a contained mid-edge crossing). Burns
## the post-crossing cooldown naturally (each call decrements it while still interior). {} if no crossing.
func _drive_cross_to(w: WorldManager, target: int) -> Dictionary:
	var from_fid := TC.active_facet()
	var slot := -1
	for sl in range(4):
		if FA.seam_neighbour(from_fid, sl) == target:
			slot = sl
			break
	if slot < 0:
		return {}
	var cc := FA.centre_cell(from_fid)
	var px := float(cc.x) + 0.5
	var pz := float(cc.y) + 0.5
	var py := w.surface_y(px, pz)
	var d0 := FA.own_dist(from_fid, slot, px, py, pz)
	var g := Vector2(FA.own_dist(from_fid, slot, px + 1.0, py, pz) - d0,
		FA.own_dist(from_fid, slot, px, py, pz + 1.0) - d0)
	g = g.normalized() if g.length() > 1e-9 else Vector2(1, 0)
	for _step in range(4000):
		px -= g.x * 0.5                            # −gradient: march toward (then past) the ridge
		pz -= g.y * 0.5
		py = w.surface_y(px, pz)
		var r := w.maybe_cross_facet(Vector3(px, py, pz))
		if bool(r.get("crossed", false)):
			return r
	return {}

func _dict_eq(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a.keys():
		if not b.has(k) or b[k] != a[k]:
			return false
	return true

# FP3 — the junction bevel geometry is GENUINELY PER-FACET: seam orientations vary widely across facets (the
# cube-sphere warp shears facets differently), so a single-manifest reuse across a crossing would crack/mis-tilt
# most seams. This gate PINS that finding — it is why set_facet clears the manifest (safe lip) on a crossing
# rather than reuse it, and why correct bevels-on-crossing need a per-facet re-bake (infeasible: godot_voxel's
# library bake is all-or-nothing, ~13s web stall). Do NOT reintroduce a reference-facet reuse without solving
# the mesher-carve problem first.
func _slot_normal(fid: int, slot: int) -> Vector3:
	var p := FA.seam_plane(fid, slot)
	return Vector3(p.x, p.y, p.z).normalized()

func _ang(a: Vector3, b: Vector3) -> float:
	return acos(clampf(a.dot(b), -1.0, 1.0))

func _gate_bevel_reuse(nf: int) -> void:
	var ref := FA.spawn_facet()
	var all_worst := 0.0
	var step := maxi(1, nf / 400)
	for slot in range(4):
		var rn := _slot_normal(ref, slot)
		for fid in range(0, nf, step):
			all_worst = maxf(all_worst, _ang(rn, _slot_normal(fid, slot)))
	_ok(all_worst > deg_to_rad(20.0), "bevel geometry is genuinely per-facet: seam orientations span %.1f° across facets (a single-manifest reuse WOULD crack → clear-on-cross is required)" % rad_to_deg(all_worst))

# FP3 — the crossing reframe math (§6.1). The f64 A→B→A position reframe round-trips exactly (Δ_AB·Δ_BA = I),
# and crossing_basis is a true inverse pair — so a cross-and-return is byte-identical and the player can never
# drift across repeated seam crossings.
func _gate_crossing_math(nf: int) -> void:
	var worst_rt := 0.0
	var basis_worst := 0.0
	var step := maxi(1, nf / 150)
	for a in range(0, nf, step):
		for slot in range(4):
			var b: int = FA.seam_neighbour(a, slot)
			var cc := FA.centre_cell(a)
			var p := Vector3(float(cc.x) + 0.5, 12.0, float(cc.y) + 0.5)
			var pb := FA.reframe_position64(a, b, p.x, p.y, p.z)
			var pa := FA.reframe_position64(b, a, pb[0], pb[1], pb[2])
			worst_rt = maxf(worst_rt, Vector3(float(pa[0]) - p.x, float(pa[1]) - p.y, float(pa[2]) - p.z).length())
			var m := FA.crossing_basis(b, a) * FA.crossing_basis(a, b)
			basis_worst = maxf(basis_worst, (m.x - Vector3(1, 0, 0)).length() + (m.y - Vector3(0, 1, 0)).length() + (m.z - Vector3(0, 0, 1)).length())
	_ok(worst_rt < 1e-3, "crossing: A→B→A position round-trips exactly (worst %s < 1e-3, f64)" % worst_rt)
	_ok(basis_worst < 1e-5, "crossing: crossing_basis(B,A)·crossing_basis(A,B) = identity (worst %s)" % basis_worst)

# FP2 Stage A — seam table + junction clip (§2.5, §3.5.1-3). Weld closure (reciprocity + matching ring +
# opposite m̂ = watertight by construction), G-J1 exact complementarity (own_A(p) = −own_B(p) on the shared
# plane ⇒ every wedge point claimed by exactly one side, no gap/overlap), and clip sanity (junction cells
# produce a partial convex prism inside all straddling half-spaces).
func _gate_seams(nf: int) -> void:
	# weld closure: every slot's neighbour reciprocates, with a matching welded ring and an opposite m̂
	var recip_ok := true
	var ring_worst := 0.0
	var mhat_worst := -1.0                    # want dot ≈ −1 (opposite); track the LEAST-opposite (largest dot)
	for fid in range(nf):
		for slot in range(4):
			var fidB: int = FA.seam_neighbour(fid, slot)
			# find B's reciprocal slot pointing back to fid
			var rs := -1
			for s2 in range(4):
				if FA.seam_neighbour(fidB, s2) == fid:
					rs = s2
					break
			if rs < 0:
				recip_ok = false
				continue
			var ra: Array = FA.seam_ring(fid, slot)
			var rb: Array = FA.seam_ring(fidB, rs)
			# ring endpoints match up to order (the average is symmetric); take the best pairing
			var d_same: float = (ra[0] as Vector3).distance_to(rb[0]) + (ra[1] as Vector3).distance_to(rb[1])
			var d_swap: float = (ra[0] as Vector3).distance_to(rb[1]) + (ra[1] as Vector3).distance_to(rb[0])
			ring_worst = maxf(ring_worst, minf(d_same, d_swap))
			var md: float = FA.seam_mhat(fid, slot).dot(FA.seam_mhat(fidB, rs))
			mhat_worst = maxf(mhat_worst, md)   # track the LEAST-opposite (largest dot)
	_ok(recip_ok, "seams: every slot's neighbour reciprocates (watertight adjacency)")
	_ok(ring_worst < 1e-3, "seams: welded ring matches from both sides (worst Δ = %s blocks)" % ring_worst)
	_ok(mhat_worst < -0.999, "seams: shared ridge normal is exactly opposite from both sides (worst dot = %s)" % mhat_worst)

	# G-J1 exact complementarity: for f64 world points near each sampled ridge, own_A(p) = −own_B(p) — so the
	# same world plane splits the wedge, and every point is claimed by exactly one facet (no gap, no overlap).
	var comp_worst := 0.0
	var exclusive := true
	var step := maxi(1, nf / 200)
	for fid in range(0, nf, step):
		for slot in range(4):
			var fidB: int = FA.seam_neighbour(fid, slot)
			var rs := -1
			for s2 in range(4):
				if FA.seam_neighbour(fidB, s2) == fid:
					rs = s2; break
			if rs < 0:
				continue
			var ring: Array = FA.seam_ring(fid, slot)
			var r0: Vector3 = ring[0]; var r1: Vector3 = ring[1]
			var mh: Vector3 = FA.seam_mhat(fid, slot)
			for tstep in range(1, 5):
				var tt := float(tstep) / 5.0
				var mid := r0.lerp(r1, tt)
				for off in [-3.0, -0.5, 0.5, 3.0]:
					var p := mid + mh * float(off)        # world point off the ridge, on A's side if off>0
					var la := FA.world_to_lattice64(fid, p.x, p.y, p.z)
					var lb := FA.world_to_lattice64(fidB, p.x, p.y, p.z)
					var oa := FA.own_dist(fid, slot, la[0], la[1], la[2])
					var ob := FA.own_dist(fidB, rs, lb[0], lb[1], lb[2])
					comp_worst = maxf(comp_worst, absf(oa + ob))      # complementary ⇒ oa ≈ −ob
					if (oa > 1e-4) == (ob > 1e-4):                     # both own or neither → gap/overlap
						exclusive = false
	_ok(comp_worst < 1e-3, "G-J1: own_A(p) = −own_B(p) on the shared plane (worst |sum| = %s)" % comp_worst)
	_ok(exclusive, "G-J1: every wedge point claimed by exactly one facet (no gap, no double-coverage)")

	# clip sanity: find a straddling junction cell on the spawn facet and check its prism is a proper partial
	var fid0 := FA.spawn_facet()
	TC.set_active_facet(fid0)
	var lo: Vector2i = FA.dom_min(fid0)
	var hi: Vector2i = FA.dom_max(fid0)
	var found := false
	var verts_inside := true
	var partial := false
	var masked_seen := false
	var interior_seen := false
	var z := lo.y
	while z <= hi.y and not (found and masked_seen and interior_seen):
		var x := lo.x
		while x <= hi.x:
			var g := TC.height_at(x, z)
			var st := FA.cell_seam_state(fid0, x, g, z)
			if st["air"]:
				masked_seen = true
			elif (st["straddle"] as PackedInt32Array).is_empty():
				interior_seen = true
			elif not found:
				var vp := FA.junction_prism_verts(fid0, x, g, z)
				found = vp.size() >= 4
				partial = vp.size() < 8 or _prism_volume(vp) < 0.999
				for u in vp:
					for slot in (st["straddle"] as PackedInt32Array):
						# check the plane in f64 (own_dist) — seam_plane() is a Vector4 (f32) and loses ~2e-4
						# at |lattice|~3e4, which would falsely flag exact edge∩plane vertices as outside.
						if FA.own_dist(fid0, slot, float(x) + u.x, float(g) + u.y, float(z) + u.z) < -1e-4:
							verts_inside = false
			x += 1
		z += 1
	_ok(found, "clip: a straddling junction cell yields a non-empty prism")
	_ok(verts_inside, "clip: every prism vertex is inside all straddling half-spaces (own ≥ 0)")
	_ok(partial, "clip: the junction prism is a proper PARTIAL fill (< full cube)")
	_ok(masked_seen and interior_seen, "mask: the facet has both masked (air, beyond ridge) and interior cells")

# FP2 Stage B1 — the junction encoding authority (§3.5.4). junction_modify is deterministic (G-J4), maps the
# three cell classes correctly (air→AIR mask, interior→unchanged, straddle→kind-2 modifier), and the cut offset
# q ALWAYS rounds OUTWARD (the model plane sits ≥ the exact plane, overlap ≤ 1/16 block — never an inward crack).
func _gate_junction_encode() -> void:
	var fid := FA.spawn_facet()
	TC.set_active_facet(fid)
	var lo: Vector2i = FA.dom_min(fid)
	var hi: Vector2i = FA.dom_max(fid)
	var FULL := CellCodec.pack(BlockCatalog.STONE, 0)
	var det_ok := true; var class_ok := true; var outward_ok := true
	var overlap_worst := 0.0
	var jcount := 0; var air_count := 0; var interior_count := 0
	var z := lo.y
	while z <= hi.y:
		var x := lo.x
		while x <= hi.x:
			var g := TC.height_at(x, z)
			for y in [g - 2, g, g + 1]:
				var cell := Vector3i(x, y, z)
				var st := FA.cell_seam_state(fid, x, y, z)
				var m0 := FA.junction_modify(fid, cell, FULL)
				if FA.junction_modify(fid, cell, FULL) != m0:
					det_ok = false
				if st["air"]:
					air_count += 1
					if m0 != 0:
						class_ok = false
				elif (st["straddle"] as PackedInt32Array).is_empty():
					interior_count += 1
					if m0 != FULL:
						class_ok = false
				else:
					jcount += 1
					var mod := CellCodec.modifier(m0)
					if not CellCodec.is_junction(mod):
						class_ok = false
					else:
						var slot := CellCodec.junction_slot(mod)
						var q := CellCodec.junction_q(mod)
						var dc := FA.own_dist(fid, slot, float(x) + 0.5, float(y) + 0.5, float(z) + 0.5) / FA.seam_grad_len(fid, slot)
						var dq := float(q) / 16.0 - 1.0
						if dq < dc - 1e-6:
							outward_ok = false
						overlap_worst = maxf(overlap_worst, dq - dc)
			x += 1
		z += 1
	_ok(det_ok, "junction: junction_modify is deterministic (G-J4)")
	_ok(class_ok, "junction: air→AIR mask, interior→unchanged, straddle→kind-2 modifier")
	_ok(jcount > 0 and air_count > 0 and interior_count > 0, "junction: all three classes present (air=%d interior=%d junction=%d)" % [air_count, interior_count, jcount])
	_ok(outward_ok, "junction: cut offset q rounds OUTWARD (model plane ≥ exact, no inward crack)")
	_ok(overlap_worst <= 1.0 / 16.0 + 1e-6, "junction: outward overlap ≤ 1/16 block (worst %s)" % overlap_worst)

# FP2 Stage C — the far ring (§5.2). Builds the planet mesh around the active facet headlessly and checks it
# produced a substantial-but-bounded triangle count (the active facet is excluded; back-hemisphere facets culled).
func _gate_far_ring() -> void:
	var fid := FA.spawn_facet()
	TC.set_active_facet(fid)
	var ring := FacetFarRing.new()
	get_root().add_child(ring)
	ring.setup(fid)
	var tris := ring.triangle_count()
	var k := FA.K
	var maxtris := 6 * k * k * FacetFarRing.CELLS * FacetFarRing.CELLS * 2
	_ok(tris > 0, "far ring: built %d triangles around the active facet" % tris)
	_ok(tris < maxtris, "far ring: triangle count bounded by the all-facet cap (%d < %d, back-hemisphere culled)" % [tris, maxtris])
	# FP3/FP-S1(d): set_active (crossing) rigidly re-places the planet (transform only) and DEFERS the re-emit off
	# the crossing frame. It must NOT synchronously re-emit — the old mesh stays valid/placed until the deferred
	# rebuild lands. force_rebuild() stands in for _process (headless frames aren't stepped).
	var nb: int = FA.seam_neighbour(fid, 0)
	var re0 := ring.reemit_count()
	ring.set_active(nb)
	_ok(ring.triangle_count() > 0, "far ring: set_active(neighbour %d) keeps a valid mesh (rigid re-place)" % nb)
	_ok(ring.is_rebuild_pending(), "FP-S1(d): set_active marks a deferred rebuild (no synchronous full re-emit)")
	_ok(ring.reemit_count() == re0, "FP-S1(d): set_active did NOT re-emit synchronously (reemit_count still %d)" % re0)
	ring.force_rebuild()
	_ok(ring.reemit_count() == re0 + 1 and not ring.is_rebuild_pending(), "FP-S1(d): the deferred rebuild completes exactly once")
	_ok(not ring.is_emitted(nb), "FP-S1(d): the active facet %d is EXCLUDED from the re-emitted visible set" % nb)
	_ok(ring.emitted_count() > 0 and ring.emitted_count() < 6 * k * k, "FP-S1(d): visible set non-empty and back-hemisphere culled (%d < %d)" % [ring.emitted_count(), 6 * k * k])
	ring.set_active(fid)
	ring.force_rebuild()
	ring.queue_free()

# FP2 Stage B2 — the junction mesh builder (§3.5.4). G-J2: ShapeMesh._build_junction's clipped vertices match
# the shared clip enumerator (junction_model_verts) to ≤1e-4 — render geometry == the atlas clip by shared
# construction — and every junction mesh is a proper partial (has an interior cut vertex, not a full cube).
func _gate_junction_mesh() -> void:
	var fid := FA.spawn_facet()
	TC.set_active_facet(fid)
	var full := CellCodec.pack(BlockCatalog.STONE, 0)
	var seen := {}
	var lo: Vector2i = FA.dom_min(fid)
	var hi: Vector2i = FA.dom_max(fid)
	var z := lo.y
	while z <= hi.y and seen.size() < 24:
		var x := lo.x
		while x <= hi.x and seen.size() < 24:
			var g := TC.height_at(x, z)
			for y in [g - 1, g, g - 3]:
				var st := FA.cell_seam_state(fid, x, y, z)
				if st["air"] or (st["straddle"] as PackedInt32Array).is_empty():
					continue
				var mod := CellCodec.modifier(FA.junction_modify(fid, Vector3i(x, y, z), full))
				if CellCodec.is_junction(mod):
					seen[mod] = true
			x += 1
		z += 1
	var match_ok := true; var complete_ok := true; var bounds_ok := true
	var worst := 0.0; var n := 0; var n_partial := 0
	for mod in seen.keys():
		var slot := CellCodec.junction_slot(mod); var q := CellCodec.junction_q(mod)
		var mesh := ShapeMesh.build(mod)
		var mv: PackedVector3Array = mesh["verts"]
		var model := FA.junction_model_verts(fid, slot, q)
		if mv.is_empty() or model.is_empty():
			continue
		n += 1
		for v in mv:
			var best := 1e9
			for u in model:
				best = minf(best, v.distance_to(u))
			worst = maxf(worst, best)
			if best > 1e-4:
				match_ok = false
			if v.x < -1e-4 or v.x > 1.0 + 1e-4 or v.y < -1e-4 or v.y > 1.0 + 1e-4 or v.z < -1e-4 or v.z > 1.0 + 1e-4:
				bounds_ok = false
		for u in model:
			var best2 := 1e9
			for v in mv:
				best2 = minf(best2, u.distance_to(v))
			if best2 > 1e-4:
				complete_ok = false
		for v in mv:
			if (v.x > 1e-4 and v.x < 1.0 - 1e-4) or (v.y > 1e-4 and v.y < 1.0 - 1e-4) or (v.z > 1e-4 and v.z < 1.0 - 1e-4):
				n_partial += 1
				break
	_ok(n > 0, "junction mesh: built %d distinct junction models" % n)
	_ok(match_ok, "G-J2: every mesh vertex matches the shared clip enumerator (worst %s ≤ 1e-4)" % worst)
	_ok(complete_ok, "G-J2: the mesh covers every clip vertex (no missing geometry)")
	_ok(bounds_ok, "G-J2: no mesh vertex escapes the unit cube")
	_ok(n_partial > 0, "G-J2: some junction meshes are proper partials (%d/%d; full-cube models are legit outward rounding)" % [n_partial, n])

# rough hull volume via the AABB of the point cloud (a cheap "is it smaller than the unit cube" proxy)
func _prism_volume(pts: PackedVector3Array) -> float:
	var lo := Vector3(1e9, 1e9, 1e9); var hi := Vector3(-1e9, -1e9, -1e9)
	for p in pts:
		lo = lo.min(p); hi = hi.max(p)
	var d := hi - lo
	return d.x * d.y * d.z

func _loose_bodies(w: WorldManager) -> int:
	var n := 0
	for c in w.get_children():
		if c is VoxelBody:
			n += 1
	return n

# G-F1e — for every facet: orthonormal basis, det=+1, outward n̂, near-planar corners, exact W_fid round-trip.
func _gate_frame_math(nf: int) -> void:
	var worst_ortho := 0.0
	var worst_rt := 0.0
	var worst_dev_ratio := 0.0
	var min_ndc := 1.0
	var bad_det := 0
	var cos1 := cos(deg_to_rad(1.0))
	for fid in range(nf):
		var m: Dictionary = FA.verify_frame(fid)
		worst_ortho = maxf(worst_ortho, m["ortho"])
		worst_rt = maxf(worst_rt, m["roundtrip"])
		min_ndc = minf(min_ndc, m["n_dot_centre"])
		if absf(float(m["det"]) - 1.0) > 1e-6:
			bad_det += 1
		var edge: float = m["edge"]
		if edge > 0.0:
			worst_dev_ratio = maxf(worst_dev_ratio, float(m["plane_dev"]) / edge)
	_ok(worst_ortho < 1e-9, "frame orthonormal (worst Gram residual %s < 1e-9)" % worst_ortho)
	_ok(bad_det == 0, "every basis right-handed det=+1 (%d facets off)" % bad_det)
	_ok(min_ndc >= cos1, "n̂ points outward within 1° (min n̂·centre = %.6f ≥ cos1°=%.6f)" % [min_ndc, cos1])
	_ok(worst_dev_ratio < 0.02, "facet near-planar (worst corner plane-dev / edge = %.4f < 0.02)" % worst_dev_ratio)
	_ok(worst_rt < 1e-3, "W_fid round-trips (worst |T⁻¹∘W − id| = %s < 1e-3, f64 kernel)" % worst_rt)

# G-F1a — purity/determinism on 3 facets (spawn + a face-4 corner-quadrant facet + a face-0 facet). The worker
# column path (a frozen GenCtx(0,fid)) must equal the analytic column (which reads _active_facet), and
# generated_cell must be byte-stable across a re-run and across a memo clear. Catches f32 leakage in the d̂ path.
func _gate_purity() -> void:
	var k := FA.K
	var sample := [FA.spawn_facet(), (4 * k + 0) * k + 0, (0 * k + k / 2) * k + (k / 2)]
	for fid in sample:
		TC.set_active_facet(fid)
		var cc: Vector2i = FA.centre_cell(fid)
		# column equality: worker (frozen ctx) == analytic (null ctx → _active_facet)
		var col_eq := true
		for dz in range(-12, 12):
			for dx in range(-12, 12):
				var x := cc.x + dx
				var z := cc.y + dz
				var wctx := TC.GenCtx.new(0, fid)
				var pw: Vector4 = TC.column_profile(x, z, wctx)
				var pa: Vector4 = TC.column_profile(x, z)     # analytic, reads _active_facet == fid
				if pw != pa:
					col_eq = false
		_ok(col_eq, "facet %d: worker column == analytic column (24×24, no f32 divergence)" % fid)
		# cell determinism: generated_cell box stable across a 2nd pass AND after a memo clear
		var g0 := TC.height_at(cc.x, cc.y)
		var h1 := _cell_box_hash(cc, g0)
		var h2 := _cell_box_hash(cc, g0)
		TC.set_active_facet(-1)              # clear active + memos, then re-home to force a cold recompute
		TC.set_active_facet(fid)
		var h3 := _cell_box_hash(cc, g0)
		_ok(h1 == h2 and h1 == h3, "facet %d: generated_cell deterministic (2nd pass + post-clear byte-equal)" % fid)

func _cell_box_hash(cc: Vector2i, g0: int) -> int:
	var vals := PackedInt32Array()
	for dz in range(-8, 8):
		for dx in range(-8, 8):
			for y in range(g0 - 8, g0 + 9):
				vals.append(TC.generated_cell(cc.x + dx, y, cc.y + dz))
	return hash(vals)

# G-F1d — the spawn column sits ≥ 32 cells inside every facet-polygon edge (covers _find_flat's ±16 wander).
func _gate_spawn_margin() -> void:
	var fid := FA.spawn_facet()
	var sc: Vector2i = FA.spawn_column()
	TC.set_active_facet(fid)
	var spawn: Vector2i = TC.find_spawn()
	_ok(FA.in_polygon(fid, sc.x, sc.y, -32.0), "spawn window centre ≥ 32 cells inside the facet polygon")
	_ok(FA.in_polygon(fid, spawn.x, spawn.y, -16.0), "resolved spawn column ≥ 16 cells inside the polygon")
	var p: Vector4 = TC.column_profile(spawn.x, spawn.y)
	_ok(int(p.x) > TC.SEA_LEVEL + 1, "spawn column is land (g=%d > sea)" % int(p.x))

# G-F1f — two facets sharing a ridge agree in surface height at the cells straddling it (the datum step across
# a dihedral is GEOMETRIC, not a terrain discontinuity). For 19 points along the shared ridge arc we find each
# facet's OWN lattice cell whose cell_dir is nearest that ridge direction, then compare the two facets' surface
# heights (facet_profile.g). They must agree to ≤ 2 blocks — this pins the d̂ adapter (sampling map correct on
# both sides), independent of the geometric datum offset. Also pins the one-map rule: facet_profile == profile
# at cell_dir.
func _gate_seam_continuity() -> void:
	var k := FA.K
	var fid := FA.spawn_facet()
	var face := int(fid / (k * k))
	var rem := fid - face * k * k
	var a := int(rem / k)
	var b := rem - a * k
	# one-map rule: facet_profile(fid,x,z) must equal profile_at_dir(cell_dir(fid,x,z))
	var cc: Vector2i = FA.centre_cell(fid)
	var d: CubeSphere.DVec3 = FA.cell_dir(fid, cc.x, cc.y)
	var one_map := TC.facet_profile(fid, cc.x, cc.y) == TC.profile_at_dir(d.x, d.y, d.z, FA.R_BLOCKS)
	_ok(one_map, "one-map rule: facet_profile == profile_at_dir(cell_dir) (sampling map is placement map)")
	if a + 1 >= k:
		_ok(true, "seam continuity: spawn facet on a cube-face edge — cross-face neighbour deferred to FP2")
		return
	var nfid := (face * k + (a + 1)) * k + b   # the +a neighbour facet, sharing the a→a+1 ridge
	var worst := 0
	for s in range(1, 20):
		var tt := float(s) / 20.0
		var e0 := CosmosFacet.vertex_dir(face, a + 1, b, k)
		var e1 := CosmosFacet.vertex_dir(face, a + 1, b + 1, k)
		var rd := CubeSphere.DVec3.new(e0.x + (e1.x - e0.x) * tt, e0.y + (e1.y - e0.y) * tt, e0.z + (e1.z - e0.z) * tt).normalized()
		var ca := _nearest_cell(fid, rd)
		var cb := _nearest_cell(nfid, rd)
		var ga := int(TC.facet_profile(fid, ca.x, ca.y).x)
		var gb := int(TC.facet_profile(nfid, cb.x, cb.y).x)
		worst = maxi(worst, absi(ga - gb))
	_ok(worst <= 2, "seam facets %d↔%d agree in surface height (worst Δg = %d ≤ 2 blocks)" % [fid, nfid, worst])

## The facet lattice cell whose cell_dir is nearest unit direction `rd` — scan the facet's polygon-clipped
## lattice domain (a few hundred cells per side). Used only by the seam gate.
func _nearest_cell(fid: int, rd: CubeSphere.DVec3) -> Vector2i:
	var lo: Vector2i = FA.dom_min(fid)
	var hi: Vector2i = FA.dom_max(fid)
	var best := Vector2i(lo.x, lo.y)
	var best_dot := -2.0
	var z := lo.y
	while z <= hi.y:
		var x := lo.x
		while x <= hi.x:
			if FA.in_polygon(fid, x, z, 0.0):
				var cd: CubeSphere.DVec3 = FA.cell_dir(fid, x, z)
				var dp := cd.x * rd.x + cd.y * rd.y + cd.z * rd.z
				if dp > best_dot:
					best_dot = dp
					best = Vector2i(x, z)
			x += 1
		z += 1
	return best

# ============================ FP-M1c Planet Assembly gates (docs/COSMOS-FP-M1-DESIGN.md §11) ============================
# All three build a module_world directly (the verify_fp_r0 pattern) so the pool is isolated from the WorldManagers
# the earlier gates spawn. They run ONLY under FP_M1_POOL + the module binary (see _initialize). Each asserts a §11
# invariant with a REAL live VoxelTerrain pool — the anti-spike gates the payload stage must pass before deploy.

## Build the active-facet module, add to the tree, run setup(). Returns the module Node3D or null.
func _build_pool_module(active: int) -> Node3D:
	TC.set_active_facet(active)
	var mod: Node3D = (load("res://src/world/voxel_module/module_world.gd").new()) as Node3D
	get_root().add_child(mod)
	if not bool(mod.call("setup")):
		return null
	return mod

## Count LIVE VoxelTerrain nodes anywhere under `root` (recursive) — the anti-leak instrument (§10/§12.1a).
func _count_voxel_terrains(root: Node) -> int:
	var n := 0
	if root.get_class() == "VoxelTerrain":
		n += 1
	for c in root.get_children():
		n += _count_voxel_terrains(c)
	return n

## Count VoxelViewer nodes anywhere in the scene tree (G-M1-POOL: must be exactly 1).
func _count_voxel_viewers() -> int:
	return _count_by_class(get_root(), "VoxelViewer")
func _count_by_class(root: Node, cls: String) -> int:
	var n := (1 if root.get_class() == cls else 0)
	for c in root.get_children():
		n += _count_by_class(c, cls)
	return n

## Two distinct edge-neighbours of `active` (for spawning ≥2 live facets). [] if fewer exist.
func _edge_neighbours(active: int) -> Array:
	var out: Array = []
	for slot in range(4):
		var nb: int = FA.seam_neighbour(active, slot)
		if nb >= 0 and nb != active and not out.has(nb):
			out.append(nb)
	return out

# ---- G-M1-POOL + G-M1-MEM ----
func _gate_pool_assembly() -> void:
	var active := FA.spawn_facet()
	var mem_base := OS.get_static_memory_usage()
	var mod := await _pool_ready_module(active)
	if mod == null:
		_ok(false, "G-M1-POOL: module_world.setup() built the active-facet pool")
		return
	_ok(true, "G-M1-POOL: module_world.setup() built the active-facet pool (PlanetRoot + active slot)")
	# The active terrain sits at composite IDENTITY (PlanetRoot T_active⁻¹ · slot T_active), so world == active
	# lattice — physics/DDA/collider unchanged. Assert it to 1e-9 (the reparent must not perturb the frame).
	var at: Node3D = mod.call("pool_terrain", active)
	_ok(at != null, "G-M1-POOL: the active facet is pooled")
	if at != null:
		var comp := at.global_transform
		var id_err := _xform_identity_err(comp)
		_ok(id_err < 1e-6, "G-M1-POOL: active terrain composite == identity (frame err %.2e < 1e-6 — physics frame unchanged)" % id_err)

	# Attach the ONE global player viewer (a holder Node3D stands in for the player). No other viewer ever exists.
	var holder := Node3D.new()
	get_root().add_child(holder)
	mod.call("attach_viewer", holder)
	print("  [G-M1-POOL] VoxelViewer count in tree = %d (must be 1)" % _count_voxel_viewers())
	_ok(_count_voxel_viewers() == 1, "G-M1-POOL: exactly ONE VoxelViewer in the tree (spike's per-neighbour viewers BANNED) — count=%d" % _count_voxel_viewers())

	var base_terrains := _count_voxel_terrains(mod)
	_ok(base_terrains == 1, "G-M1-POOL: baseline live VoxelTerrain count under the module == 1 (active only)")

	# Spawn ≥2 edge neighbours → ≥2 facets rendering real voxels at once (the first user complaint).
	var nbs := _edge_neighbours(active)
	_ok(nbs.size() >= 2, "G-M1-POOL: the active facet has >=2 edge neighbours to pool (found %d)" % nbs.size())
	var spawn_deltas: Array = []
	var spawned: Array = []
	for i in range(min(2, nbs.size())):
		var m0 := OS.get_static_memory_usage()
		var ok_sp: bool = bool(mod.call("pool_spawn", nbs[i]))
		var m1 := OS.get_static_memory_usage()
		spawn_deltas.append(m1 - m0)
		if ok_sp:
			spawned.append(nbs[i])
		_ok(ok_sp and bool(mod.call("pool_has", nbs[i])), "G-M1-POOL: pool_spawn(facet %d) built a live neighbour terrain" % nbs[i])
	_ok(int(mod.call("pool_neighbour_count")) == spawned.size(), "G-M1-POOL: neighbour count == %d after spawns" % spawned.size())
	_ok(_count_voxel_terrains(mod) == 1 + spawned.size(), "G-M1-POOL: live VoxelTerrain count == 1 active + %d neighbours" % spawned.size())
	_ok(int(mod.call("pool_neighbour_count")) <= CubeSphere.POOL_MAX_NEIGHBOURS, "G-M1-POOL: neighbour count <= POOL_MAX_NEIGHBOURS(%d)" % CubeSphere.POOL_MAX_NEIGHBOURS)

	# bounds ⊆ facet slab (§3.2): every pool terrain's bounds matches its own facet's domain-slab AABB.
	var bounds_ok := true
	for fid in (mod.call("pool_fids") as Array):
		if not _bounds_is_slab(mod.call("pool_bounds", fid), int(fid)):
			bounds_ok = false
	_ok(bounds_ok, "G-M1-POOL: every pool terrain's bounds is clamped to its own facet domain slab (no foreign block)")

	# MIN_LIVE anti-thrash: a just-spawned neighbour is younger than MIN_LIVE_S, so the policy would NOT retire it.
	if spawned.size() > 0:
		_ok(float(mod.call("pool_age_s", spawned[0])) < CubeSphere.POOL_MIN_LIVE_S,
			"G-M1-POOL: a just-spawned neighbour age < MIN_LIVE_S(%.0fs) — retire is suppressed (anti-thrash)" % CubeSphere.POOL_MIN_LIVE_S)

	# G-M1-MEM: per-spawn heap delta <= the §10 neighbour budget (ceiling — headless streams little without the
	# viewer near the neighbour, so this is a CEILING assertion; the live A/B is the authority on GPU memory).
	var neigh_budget: int = int(mod.get("POOL_NEIGHBOUR_MEM_BUDGET_MB")) * 1048576
	var mem_ok := true
	for d in spawn_deltas:
		if int(d) > neigh_budget:
			mem_ok = false
	var deltas_mb: Array = []
	for d in spawn_deltas:
		deltas_mb.append("%.2f" % (int(d) / 1048576.0))
	print("  [G-M1-MEM] per-spawn static-heap deltas = %s MB (budget %d MB/neighbour; headless CPU-only, GPU is the live A/B)" % [str(deltas_mb), mod.get("POOL_NEIGHBOUR_MEM_BUDGET_MB")])
	_ok(mem_ok, "G-M1-MEM: per-spawn heap delta <= %d MB budget (deltas=%s bytes)" % [mod.get("POOL_NEIGHBOUR_MEM_BUDGET_MB"), str(spawn_deltas)])
	var pool_total := OS.get_static_memory_usage() - mem_base
	print("  [G-M1-MEM] pool total static-heap delta = %.2f MB (ceiling POOL_MEM_BUDGET_MB = %d MB)" % [pool_total / 1048576.0, CubeSphere.POOL_MEM_BUDGET_MB])
	_ok(pool_total <= CubeSphere.POOL_MEM_BUDGET_MB * 1048576,
		"G-M1-MEM: pool total heap delta %.1f MB <= POOL_MEM_BUDGET_MB(%d)" % [pool_total / 1048576.0, CubeSphere.POOL_MEM_BUDGET_MB])

	# THE anti-leak assertion (the spike would FAIL here): retire every neighbour, pump frames, assert the live
	# VoxelTerrain count returns to baseline (freed — no stray GDScript ref pins the maps, §12.1a).
	for fid in spawned:
		_ok(bool(mod.call("pool_retire", fid)), "G-M1-POOL: pool_retire(facet %d) succeeded" % fid)
	for _i in range(6):
		await process_frame
	_ok(_count_voxel_terrains(mod) == base_terrains,
		"G-M1-POOL: retired terrains FREED — live VoxelTerrain count back to baseline %d (anti-leak; the spike would leak here)" % base_terrains)
	_ok(int(mod.call("pool_neighbour_count")) == 0, "G-M1-POOL: neighbour count == 0 after retiring all")
	mod.queue_free()
	holder.queue_free()
	await process_frame

# ---- G-M1-XDES (re-designation: no teardown) ----
func _gate_redesignation() -> void:
	var active := FA.spawn_facet()
	var mod := await _pool_ready_module(active)
	if mod == null:
		_ok(false, "G-M1-XDES: module built for the re-designation gate")
		return
	var holder := Node3D.new()
	get_root().add_child(holder)
	mod.call("attach_viewer", holder)
	var nbs := _edge_neighbours(active)
	if nbs.is_empty():
		_ok(false, "G-M1-XDES: found an edge neighbour to designate")
		return
	var B: int = nbs[0]
	_ok(bool(mod.call("pool_spawn", B)), "G-M1-XDES: spawned neighbour facet %d for the re-designation" % B)
	# Capture identities BEFORE the crossing: the active terrain (must survive), B's generator (must NOT be rebuilt).
	var a_terrain: Node3D = mod.call("pool_terrain", active)
	var a_terrain_id := a_terrain.get_instance_id() if a_terrain != null else 0
	var b_gen: Object = null
	# read B's generator object via a designate + read-back trick: redesignate then compare module _generator to a fresh
	var terrains_before := _count_voxel_terrains(mod)
	var ok_rd: bool = bool(mod.call("redesignate", B))
	_ok(ok_rd, "G-M1-XDES: redesignate(%d) returned true (POOL HIT — no teardown fallback)" % B)
	_ok(int(mod.call("pool_active")) == B, "G-M1-XDES: active facet switched to B(%d) by re-designation" % B)
	# No teardown: the old active terrain is STILL LIVE (rotated neighbour now), and NO terrain was created/freed.
	_ok(a_terrain != null and is_instance_valid(a_terrain), "G-M1-XDES: old active terrain NOT freed (persists as the rotated neighbour — no removed frame)")
	_ok(a_terrain != null and a_terrain.get_instance_id() == a_terrain_id, "G-M1-XDES: old active terrain is the SAME node object (no rebuild)")
	_ok(_count_voxel_terrains(mod) == terrains_before, "G-M1-XDES: live terrain count unchanged across the crossing (no new generator/terrain, none freed)")
	# The newly-active B terrain now sits at composite IDENTITY (editable, axis-aligned).
	var bt: Node3D = mod.call("pool_terrain", B)
	if bt != null:
		var id_err := _xform_identity_err(bt.global_transform)
		_ok(id_err < 1e-6, "G-M1-XDES: post-crossing active(B) composite == identity (err %.2e < 1e-6 — physics frame re-based cleanly)" % id_err)
	# Cross-and-return: designate back to A; A must again be identity, B persists as neighbour.
	_ok(bool(mod.call("redesignate", active)), "G-M1-XDES: re-designate back to A (A->B->A) succeeds")
	_ok(int(mod.call("pool_active")) == active, "G-M1-XDES: active facet back to A after the round trip")
	if a_terrain != null:
		var id_err2 := _xform_identity_err(a_terrain.global_transform)
		_ok(id_err2 < 1e-6, "G-M1-XDES: A back at composite identity after A->B->A (err %.2e < 1e-6)" % id_err2)
	_ok(_count_voxel_terrains(mod) == terrains_before, "G-M1-XDES: A->B->A froze/freed NO terrain (count stable at %d)" % terrains_before)
	mod.queue_free()
	holder.queue_free()
	await process_frame

# ---- G-M1-RAMP (per-slot view-distance ramp — the facet-border hitch fix) ----
# Asserts the anti-burst load-shaping the live soak proves: a freshly spawned neighbour STARTS below its view target
# and RAMPS (never steps) to it over ~RAMP_SECONDS; a re-designation sets `to`'s target to the near radius (128) and
# ramps up rather than jamming it in one write; the old active SNAPS its shrink to the neighbour radius immediately.
func _gate_pool_ramp() -> void:
	var active := FA.spawn_facet()
	var mod := await _pool_ready_module(active)
	if mod == null:
		_ok(false, "G-M1-RAMP: module built for the view-ramp gate")
		return
	var holder := Node3D.new()
	get_root().add_child(holder)
	mod.call("attach_viewer", holder)
	var nbs := _edge_neighbours(active)
	if nbs.is_empty():
		_ok(false, "G-M1-RAMP: found an edge neighbour to ramp")
		mod.queue_free(); holder.queue_free(); return
	var B: int = nbs[0]
	_ok(bool(mod.call("pool_spawn", B)), "G-M1-RAMP: spawned neighbour facet %d" % B)

	# 1) A fresh neighbour STARTS below its target (built at RAMP_START, not jammed to the full 96).
	var v0 := int(mod.call("pool_view", B))
	var tgt := int(mod.call("pool_view_target", B))
	print("  [G-M1-RAMP] neighbour spawn view=%d target=%d (start must be < target)" % [v0, tgt])
	_ok(tgt == 96, "G-M1-RAMP: neighbour view target == 96 (the neighbour render radius)")
	_ok(v0 < tgt, "G-M1-RAMP: freshly spawned neighbour view (%d) STARTS below its target (%d) — no one-pass full request" % [v0, tgt])

	# 2) ONE small tick does NOT reach the target (it RAMPS, it does not STEP).
	mod.call("pool_ramp_tick", 0.05)
	var v1 := int(mod.call("pool_view", B))
	_ok(v1 >= v0 and v1 < tgt, "G-M1-RAMP: after one 50ms tick view grew (%d->%d) but is still below target — ramp, not step" % [v0, v1])

	# 3) After ~RAMP_SECONDS of ticks the ramp REACHES the target and settles (tick reports no more growing).
	var settled := false
	for _i in range(240):                       # up to 12s sim @ 50ms — RAMP_SECONDS is 1.5s
		if not bool(mod.call("pool_ramp_tick", 0.05)):
			settled = true
			break
	var v2 := int(mod.call("pool_view", B))
	print("  [G-M1-RAMP] after ramp: view=%d target=%d settled=%s" % [v2, tgt, settled])
	_ok(settled and v2 == tgt, "G-M1-RAMP: neighbour ramp REACHED its target (%d) and settled after ~RAMP_SECONDS of ticks" % tgt)

	# 4) Re-designation: `to`(B) target becomes the near radius (128) and RAMPS up (not stepped); old active A SNAPS
	#    its shrink to 96 immediately (a shrink only unloads) — OR, under COSMOS-PERF R4 (FP_SHRINK_PACED), PACES that
	#    shrink through the ramp (view held above 96 the same frame, stepping ≤SHRINK_STEP_BLOCKS/frame to 96).
	var near := TC.near_render_radius()
	_ok(bool(mod.call("redesignate", B)), "G-M1-RAMP: redesignate(%d) POOL HIT" % B)
	var b_tgt := int(mod.call("pool_view_target", B))
	var b_view_now := int(mod.call("pool_view", B))
	_ok(b_tgt == near, "G-M1-RAMP: redesignate set `to` view target to the near radius (%d)" % near)
	_ok(b_view_now < near, "G-M1-RAMP: right after redesignate `to` view (%d) is STILL below the near radius (%d) — it ramps, not steps" % [b_view_now, near])
	var a_view := int(mod.call("pool_view", active))
	if CubeSphere.FP_SHRINK_PACED:
		# R4: the old active is NOT snapped — the same frame it is still above 96, with its target set to 96 so the
		# ramp paces the unload down over ≥2 frames (no one-frame 128→96 dlmalloc convoy). Same END STATE (96) below.
		_ok(a_view > 96, "G-M1-RAMP(paced): old active NOT snapped — view (%d) still above 96 the same frame (shrink paced)" % a_view)
		_ok(int(mod.call("pool_view_target", active)) == 96, "G-M1-RAMP(paced): old active view target set to 96 (the paced goal)")
	else:
		_ok(a_view == 96, "G-M1-RAMP: the old active facet SNAPPED its shrink to the neighbour radius (96) immediately (view=%d)" % a_view)
	# Drive the `to` ramp home (and, under FP_SHRINK_PACED, the old active's paced shrink).
	for _j in range(240):
		if not bool(mod.call("pool_ramp_tick", 0.05)):
			break
	var b_final := int(mod.call("pool_view", B))
	print("  [G-M1-RAMP] post-crossing `to` ramp: view=%d target=%d" % [b_final, near])
	_ok(b_final == near, "G-M1-RAMP: post-crossing `to` ramp REACHED the near radius (%d)" % near)
	if CubeSphere.FP_SHRINK_PACED:
		# R4: the paced shrink reaches the SAME end state the snap would (96) — only the per-frame work was bounded.
		_ok(int(mod.call("pool_view", active)) == 96, "G-M1-RAMP(paced): old active paced shrink REACHED 96 (same end state as the snap)")

	mod.queue_free()
	holder.queue_free()
	await process_frame

# ---- G-M1-SEAM-1 / SEAM-2 (two live voxel facets at a shared ridge) ----
func _gate_two_facet_seam() -> void:
	var active := FA.spawn_facet()
	TC.set_active_facet(active)
	var mod: Node3D = (load("res://src/world/voxel_module/module_world.gd").new()) as Node3D
	get_root().add_child(mod)
	if not bool(mod.call("setup")):
		_ok(false, "G-M1-SEAM: module built for the two-facet seam gate")
		mod.queue_free(); return
	# Pick a shared ridge (slot) between the active facet A and a neighbour B (mid-edge, away from corners).
	var slotAB := -1
	var B := -1
	for slot in range(4):
		var nb: int = FA.seam_neighbour(active, slot)
		if nb >= 0 and nb != active:
			slotAB = slot; B = nb; break
	if B < 0:
		_ok(false, "G-M1-SEAM: found a shared ridge A|B")
		mod.queue_free(); return
	var slotBA := -1
	for slot in range(4):
		if FA.seam_neighbour(B, slot) == active:
			slotBA = slot; break
	_ok(slotBA >= 0, "G-M1-SEAM: located the reciprocal ridge B|A (slot %d)" % slotBA)

	var lib: Object = mod.call("pool_library")
	var gen_a: Object = mod.call("pool_generator", active)
	var gen_b: Object = mod.call("pool_generator", B)
	var mesh_a: Object = mod.call("pool_carve_mesher", active)
	var mesh_b: Object = mod.call("pool_carve_mesher", B)
	var carve_rng: Vector2i = mod.call("pool_carve_range")
	_ok(lib != null and gen_a != null and gen_b != null and mesh_a != null and mesh_b != null, "G-M1-SEAM: built shared library + per-facet generators + carve meshers")
	if gen_a == null or mesh_a == null:
		mod.queue_free(); return

	# Sample a straddling region centred on the ridge midpoint (in each facet's OWN lattice), build both meshes.
	# The ridge welds two cells; own_dist(fid, slot, .) == 0 on the plane, > 0 interior. We centre a 32³ mesh block
	# on a mid-ridge cell of A and the reciprocal cell of B, generate + build_mesh, and inspect the seam faces.
	var ccA: Vector2i = FA.centre_cell(active)
	var gA := int(TC.facet_profile(active, ccA.x, ccA.y).x)
	# Walk from the centre toward ridge `slotAB` until own_dist ~ small positive (near the seam), staying mid-edge.
	var seam_cell := _seam_probe_cell(active, slotAB, ccA, gA)
	var res_a := _gen_and_mesh(gen_a, mesh_a, Vector3i(seam_cell.x - 16, gA - 16, seam_cell.y - 16), 32)
	_ok(int(res_a["verts"]) > 0, "G-M1-SEAM-1: A-side straddling region meshes non-empty (%d verts) at the ridge" % int(res_a["verts"]))
	_ok(not bool(gen_a.get("oob_seen")), "G-M1-SEAM-2: A generator OOB fence never fired (oob_seen == false)")
	# B-side: reframe the SAME world ridge point into B's lattice.
	var wsA: Array = FA.lattice_to_world64(active, float(seam_cell.x), float(gA), float(seam_cell.y))
	var lbB: Array = FA.world_to_lattice64(B, wsA[0], wsA[1], wsA[2])
	var bcell := Vector2i(int(round(lbB[0])), int(round(lbB[2])))
	var gB := int(round(lbB[1]))
	var res_b := _gen_and_mesh(gen_b, mesh_b, Vector3i(bcell.x - 16, gB - 16, bcell.y - 16), 32)
	_ok(int(res_b["verts"]) > 0, "G-M1-SEAM-1: B-side straddling region meshes non-empty (%d verts) at the same ridge" % int(res_b["verts"]))
	_ok(not bool(gen_b.get("oob_seen")), "G-M1-SEAM-2: B generator OOB fence never fired (oob_seen == false)")

	# No RUNAWAY double-geometry: no mesh vertex escapes past its OWN ridge plane by more than the geometric
	# supremum. junction_modify keeps a cell solid iff own_dist(origin) + Σmax(0,coef) > EPS, so a solid cell's
	# origin sits at own_dist > -Σmax(0,coef) and its cube vertices reach down to own_dist(origin) + Σmin(0,coef),
	# i.e. penetration < Σ|coef| — the exact per-plane bound (the same coefficients junction_modify uses). +1 cell
	# absorbs the build_mesh vertex/buffer-origin offset. A vertex beyond THIS is real double-solid (a seam bug);
	# within it, the two coplanar cut faces cull back-to-back (the §7 anti-z-fight property, straddle band carved).
	var bnd_a := _seam_penetration_bound(active, slotAB)
	var bnd_b := _seam_penetration_bound(B, slotBA)
	var pen_a := _max_penetration(res_a["verts_arr"], Vector3i(seam_cell.x - 16, gA - 16, seam_cell.y - 16), active, slotAB)
	var pen_b := _max_penetration(res_b["verts_arr"], Vector3i(bcell.x - 16, gB - 16, bcell.y - 16), B, slotBA)
	_ok(pen_a <= bnd_a, "G-M1-SEAM-1: A-side geometry stays within its own ridge (pen %.3f <= supremum %.3f — no runaway double-solid)" % [pen_a, bnd_a])
	_ok(pen_b <= bnd_b, "G-M1-SEAM-1: B-side geometry stays within its own ridge (pen %.3f <= supremum %.3f)" % [pen_b, bnd_b])
	# SEAM-2: carve blob enabled (patch 0004 present) — else SKIP with the cube-lip note rather than fail.
	if carve_rng.y > 0:
		_ok(true, "G-M1-SEAM-2: per-mesher carve blob enabled on both facets (ARID range count=%d, planes pushed)" % carve_rng.y)
	else:
		print("  SKIP G-M1-SEAM-2: carve range empty (unpatched binary) — sentinels cube-fall-back (full-cube lip, never a hole)")
	mod.queue_free()
	await process_frame

# ---- FP-M1c gate helpers ----

## setup the module and pump a few frames so any deferred init settles. Returns the module or null.
func _pool_ready_module(active: int) -> Node3D:
	var mod := _build_pool_module(active)
	if mod == null:
		return null
	await process_frame
	return mod

## Frobenius-style deviation of a Transform3D from the identity (basis off-identity + origin length).
func _xform_identity_err(t: Transform3D) -> float:
	var b := t.basis
	var e := 0.0
	var cols := [b.x - Vector3(1,0,0), b.y - Vector3(0,1,0), b.z - Vector3(0,0,1)]
	for c in cols:
		e += (c as Vector3).length()
	e += t.origin.length()
	return e

## True iff `bounds` is facet `fid`'s domain slab (dom_min-2 .. dom_max+2 in x/z, worldgen y band) block-quantized:
## the engine snaps a VoxelTerrain.bounds OUTWARD to 16-voxel data-block boundaries (pos floored, far edge ceiled),
## so the check is exact against that quantization. Also asserts the slab is far below the default (clamped) and the
## y-band <= 256 (§3.2). Block-quantized outward containment guarantees the slab still covers the whole facet domain.
func _bounds_is_slab(bounds: AABB, fid: int) -> bool:
	var dmin: Vector2i = FA.dom_min(fid)
	var dmax: Vector2i = FA.dom_max(fid)
	var y_min := float(TC.BEDROCK_FLOOR)
	var y_max := float(TC.MAX_SURFACE_Y + max(TreeGen.MAX_ABOVE_SURFACE, TC.SNOW_FILL_MAX_CELLS))
	if (y_max - y_min) > 256.0:
		return false
	var blk := 16.0
	var qp := Vector3(floor((float(dmin.x) - 2.0) / blk) * blk, floor(y_min / blk) * blk, floor((float(dmin.y) - 2.0) / blk) * blk)
	var qe := Vector3(ceil((float(dmax.x) + 2.0) / blk) * blk, ceil(y_max / blk) * blk, ceil((float(dmax.y) + 2.0) / blk) * blk)
	# Far below the huge default box (clamped at all), and equal to the block-quantized slab (covers the domain).
	if bounds.size.x > 1.0e6 or bounds.size.z > 1.0e6:
		return false
	return bounds.position.is_equal_approx(qp) and (bounds.position + bounds.size).is_equal_approx(qe) \
		and bounds.position.x <= float(dmin.x) and (bounds.position.x + bounds.size.x) >= float(dmax.x) \
		and bounds.position.z <= float(dmin.y) and (bounds.position.z + bounds.size.z) >= float(dmax.y)

## generate_block(lod0) + build_mesh; returns {verts, tris, verts_arr(PackedVector3Array)}.
func _gen_and_mesh(gen: Object, mesher: Object, corner: Vector3i, n: int) -> Dictionary:
	var buf: Object = ClassDB.instantiate("VoxelBuffer")
	buf.call("create", n + 2, n + 2, n + 2)
	buf.call("set_channel_depth", 0, 1)
	gen.call("generate_block", buf, Vector3(corner.x - 1, corner.y - 1, corner.z - 1), 0)
	var mesh: Mesh = mesher.call("build_mesh", buf, [], {}) as Mesh
	var verts := 0
	var tris := 0
	var vout := PackedVector3Array()
	if mesh != null:
		for si in range(mesh.get_surface_count()):
			var arr: Array = mesh.surface_get_arrays(si)
			var pv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			verts += pv.size()
			for v in pv:
				vout.append(v)
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			tris += idx.size() / 3
	return {"verts": verts, "tris": tris, "verts_arr": vout}

## The geometric supremum (in cells) of how far a solid cell's cube vertex can sit past facet `fid`'s ridge `slot`
## plane: Σ|coef| of the (unit-ish) plane normal — the same coefficients junction_modify masks with — plus 1 cell
## to absorb the standalone build_mesh vertex/buffer-origin offset. A penetration beyond this is real double-solid.
func _seam_penetration_bound(fid: int, slot: int) -> float:
	var p: Vector4 = FA.seam_plane(fid, slot)
	return absf(p.x) + absf(p.y) + absf(p.z) + 1.0

## Max penetration (in cells) of any mesh vertex BEYOND facet `fid`'s ridge `slot` plane (own_dist < 0 = past it).
## Mesh vertices are in the padded-buffer frame; the buffer origin is (corner - 1), so world lattice = corner-1+vert.
func _max_penetration(verts: PackedVector3Array, corner: Vector3i, fid: int, slot: int) -> float:
	var worst := 0.0
	var base := Vector3(corner.x - 1, corner.y - 1, corner.z - 1)
	for v in verts:
		var lx := base.x + v.x
		var ly := base.y + v.y
		var lz := base.z + v.z
		var d := FA.own_dist(fid, slot, lx, ly, lz)   # >=0 interior; < 0 means past the own ridge (penetration)
		if -d > worst:
			worst = -d
	return worst

## Walk from the facet centre toward ridge `slot` until near the seam (own_dist small positive), returning a
## mid-edge lattice cell straddling the ridge (away from the polygon corners so it is not a singular junction).
func _seam_probe_cell(fid: int, slot: int, centre: Vector2i, g: int) -> Vector2i:
	var cur := Vector2i(centre)
	# March the cell outward along the gradient of the own-side ridge distance until own_dist ~ 1.
	for _i in range(512):
		var d := FA.own_dist(fid, slot, float(cur.x), float(g), float(cur.y))
		if d <= 1.5:
			break
		# step 1 cell in the direction that decreases own_dist (the ridge normal in lattice x/z).
		var dx := FA.own_dist(fid, slot, float(cur.x + 1), float(g), float(cur.y)) - d
		var dz := FA.own_dist(fid, slot, float(cur.x), float(g), float(cur.y + 1)) - d
		cur += Vector2i(-1 if dx > 0.0 else 1, 0) if absf(dx) >= absf(dz) else Vector2i(0, -1 if dz > 0.0 else 1)
	return cur

# ---- End-to-end pool walk-soak: a WorldManager crossing is a POOL HIT (re-designation), pool-miss 0 ----
# Drives WorldManager.update_streaming (which runs the pool manager) as the player approaches a ridge inside D_WARM
# — pre-warming the neighbour — then fires maybe_cross_facet just past the ridge and asserts the crossing was a
# RE-DESIGNATION (POOL HIT), not a teardown fallback. This is the headless proxy for the live "pool-miss count 0".
func _gate_pool_walk_soak() -> void:
	var active := FA.spawn_facet()
	TC.set_active_facet(active)
	var w := WorldManager.new()
	w.name = "PoolWalkSoak"
	get_root().add_child(w)
	# Attach the ONE viewer via a stand-in player so the module streams (on_player_ready wires it).
	var player := Node3D.new()
	get_root().add_child(player)
	if w.has_method("on_player_ready"):
		w.on_player_ready(player)
	# Pick a mid-edge ridge + its neighbour, and build interior/past positions along the ridge normal.
	var slot := -1
	var B := -1
	for s in range(4):
		var nb: int = FA.seam_neighbour(active, s)
		if nb >= 0 and nb != active:
			slot = s; B = nb; break
	if B < 0:
		_ok(false, "G-M1-POOL walk: found a ridge to cross")
		return
	var cc: Vector2i = FA.centre_cell(active)
	var gA := int(TC.facet_profile(active, cc.x, cc.y).x)
	var seam_cell := _seam_probe_cell(active, slot, cc, gA)
	var pl: Vector4 = FA.seam_plane(active, slot)
	var n := Vector3(pl.x, pl.y, pl.z)
	var nlen := maxf(n.length(), 1e-9)
	var nhat := n / nlen
	var seam_pt := Vector3(float(seam_cell.x), float(gA), float(seam_cell.y))
	var d_s := FA.own_dist(active, slot, seam_pt.x, seam_pt.y, seam_pt.z)
	var approach := seam_pt + nhat * ((40.0 - d_s) / nlen)     # own_dist ~ +40 (inside D_WARM=96)
	var past := seam_pt + nhat * ((-0.5 - d_s) / nlen)         # own_dist ~ -0.5 (just past the ridge)
	# Warm the pool: update_streaming runs _manage_facet_pool (first call spawns B — the throttle starts ready).
	var warmed := false
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3000:
		w.update_streaming(approach)
		await process_frame
		if w.facet_pool_has(B):
			warmed = true
			break
	print("  [G-M1-POOL walk] approaching ridge (own_dist~40): B pooled = %s, neighbour count = %d" % [warmed, w.facet_pool_neighbour_count()])
	_ok(warmed, "G-M1-POOL walk: neighbour B(%d) spawned while approaching the ridge (own_dist < D_WARM)" % B)
	var miss_before := w.pool_miss_count()
	# Cross just past the ridge — with B pooled this must be a RE-DESIGNATION (pool hit), no teardown fallback.
	var res := w.maybe_cross_facet(past)
	_ok(bool(res.get("crossed", false)), "G-M1-POOL walk: maybe_cross_facet fires past the ridge")
	_ok(TC.active_facet() == B, "G-M1-POOL walk: active facet re-designated to B(%d)" % B)
	print("  [G-M1-POOL walk] pool-miss count: before=%d after=%d (0 delta == the crossing was a POOL HIT)" % [miss_before, w.pool_miss_count()])
	_ok(w.pool_miss_count() == miss_before, "G-M1-POOL walk: the crossing was a POOL HIT — pool-miss count unchanged (re-designation, no teardown)")
	w.queue_free()
	player.queue_free()
	await process_frame
