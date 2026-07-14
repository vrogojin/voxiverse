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
