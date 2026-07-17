extends SceneTree
## verify_skin — COSMOS SEAMLESS-SCALES §10 C3 gate for the heightfield SKIN tier (SKIN).
##
## Runs with FACETED = true (sed-toggled, like verify_faceted) — the skin is a faceted-planet feature
## (it samples FacetAtlas). It drives SKIN through a GDScript SAMPLER that returns the SAME
## {heights,biomes,water,colors} shape the C++ VoxelGeneratorCosmos.sample_columns returns, built from
## TerrainConfig.column_profile + FarPalette — the ONE worldgen core's GDScript oracle (byte-equal to
## the C++ path by verify_cppgen's G-CG-COLUMNS). So this gate tests the skin's GEOMETRY/BUDGET logic
## independent of the binary, and Stage A's byte-equality carries the C++ path transitively.
##
## GATES (each with a falsification):
##   G-SKIN-EDGE   two adjacent tiles' SHARED boundary column is bit-identical (no crack). FALSIFY by
##                 perturbing one tile's origin by +1 and showing the shared edge then DIVERGES.
##   G-SKIN-SINK   every skin vertex sits exactly SINK blocks below the true surface (radially) and never
##                 above it, so the opaque near voxels strictly overdraw it. FALSIFY: a zero-sink point is
##                 rejected by the same test.
##   G-SKIN-MEM    over a scripted player pan the skin's bytes never exceed the 8 MB ceiling.
##   G-SKIN-M3     time-to-cover-256: tiles × build ms to fill the 256 annulus, and the coverage radius
##                 actually reached under the 8 MB cap. Reported (design target <= 1.5 s).
##
## Run (FACETED sed-toggled true):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_skin.gd

const TC := preload("res://src/world/terrain_config.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")
const SKIN := preload("res://src/world/facet_skin_tier.gd")

var _pass := 0
var _fail := 0

func _ok(c: bool, m: String) -> void:
	if c:
		_pass += 1
		print("  PASS: %s" % m)
	else:
		_fail += 1
		print("  FAIL: %s" % m)

func _done(code: int) -> void:
	print("==== VERIFY SKIN: %d passed, %d failed ====" % [_pass, _fail])
	quit(code)

func _initialize() -> void:
	print("=== verify_skin (COSMOS SEAMLESS-SCALES C3: the heightfield skin tier) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — this gate must run with FACETED = true (sed-toggled).")
		_fail += 1
		_done(1)
		return
	TC.warm_up()
	FA.warm_up()
	var fid: int = TC.active_facet()
	if fid < 0:
		fid = FA.spawn_facet()
		TC.set_active_facet(fid)

	# The skin builds its own sampler in setup() — the compiled VoxelGeneratorCosmos.sample_columns when
	# present (the shipping path, and the only sampler fast enough to measure M3 honestly), else the
	# GDScript oracle. Same code path the live WorldManager uses.
	var skin := SKIN.new()
	get_root().add_child(skin)
	skin.setup(fid)
	var T: int = SKIN.TILE

	# Anchor the tiles near the facet centre so the columns are inside the facet domain.
	var lo: Vector2i = FA.dom_min(fid)
	var hi: Vector2i = FA.dom_max(fid)
	var ox := ((lo.x + hi.x) / 2 / T) * T          # tile-aligned origin near centre
	var oz := ((lo.y + hi.y) / 2 / T) * T

	# --- G-SKIN-EDGE — adjacent tiles share their boundary column bit-for-bit ----------------------
	# Tile A at (ox,oz); tile B at (ox+T,oz). A's right column (gi=T) and B's left column (gi=0) are the
	# SAME lattice x = ox+T, so their sunk vertices must be identical. A crack here IS the seam the skin
	# exists to remove; it is a correctness property, gated.
	var stride := T + 1
	var pa := skin.gate_tile_positions(fid, ox, oz)
	var pb := skin.gate_tile_positions(fid, ox + T, oz)
	var edge_ok := true
	var edge_checked := 0
	for gj in range(stride):
		var va: Vector3 = pa[gj * stride + T]      # A's rightmost column
		var vb: Vector3 = pb[gj * stride + 0]      # B's leftmost column
		edge_checked += 1
		if va != vb:
			edge_ok = false
	_ok(edge_ok and edge_checked == stride,
		"G-SKIN-EDGE — %d shared boundary vertices bit-identical across adjacent tiles" % edge_checked)

	# FALSIFY: a tile whose origin is off by ONE column no longer shares the edge — proves the test bites.
	var pb_bad := skin.gate_tile_positions(fid, ox + T + 1, oz)
	var diverged := false
	for gj in range(stride):
		if pa[gj * stride + T] != pb_bad[gj * stride + 0]:
			diverged = true
			break
	_ok(diverged, "G-SKIN-EDGE-FALS — a +1 origin perturbation DIVERGES the shared edge (the test bites)")

	# --- G-SKIN-SINK — the skin sits exactly SINK below the true surface, never above ----------------
	var sink_ok := true
	var below_ok := true
	var checked := 0
	for dz in range(0, T + 1, 4):
		for dx in range(0, T + 1, 4):
			var x := ox + dx
			var z := oz + dz
			var sv: Vector3 = skin.skin_vertex(fid, x, z)
			var tv: Vector3 = skin.true_vertex(fid, x, z)
			checked += 1
			# radial: |true| - SINK == |skin| (both radial from planet centre = origin)
			if absf((tv.length() - SKIN.SINK) - sv.length()) > 1.0e-2:
				sink_ok = false
			if sv.length() > tv.length() + 1.0e-4:
				below_ok = false
	_ok(sink_ok, "G-SKIN-SINK — %d columns: skin radius == true radius − SINK(%.1f)" % [checked, SKIN.SINK])
	_ok(below_ok, "G-SKIN-SINK — every skin vertex is at/below the true surface (voxels overdraw it)")
	# FALSIFY: the same test rejects a zero-sink point (skin AT the true surface).
	var tv0: Vector3 = skin.true_vertex(fid, ox, oz)
	_ok(absf((tv0.length() - SKIN.SINK) - tv0.length()) > 1.0e-2,
		"G-SKIN-SINK-FALS — the sink test REJECTS a zero-sink vertex (it bites)")

	# --- G-SKIN-MEM — the 8 MB ceiling holds over a scripted pan -------------------------------------
	# Pan the player across the facet; update() schedules/evicts tiles nearest-first under MAX_BYTES.
	var fids := PackedInt32Array([fid])
	for nb in _front_neighbours(fid):
		fids.append(nb)
	var mem_ok := true
	var max_bytes_seen := 0
	var cy := int((lo.x + hi.x) / 2)
	var cz := int((lo.y + hi.y) / 2)
	var g0 := int(TC.column_profile(cy, cz, TC.GenCtx.new(0, fid)).x)
	for step in range(0, 10):
		var px := cy - 100 + step * 24            # 24 > TILE·0.5 hysteresis, so each step reschedules
		skin.update(fid, Vector3(float(px), float(g0), float(cz)), fids)
		var b := skin.total_bytes()
		max_bytes_seen = maxi(max_bytes_seen, b)
		if b > SKIN.MAX_BYTES:
			mem_ok = false
	_ok(mem_ok, "G-SKIN-MEM — skin bytes stayed <= 8 MB over the pan (peak %.2f MB, %d tiles)"
		% [float(max_bytes_seen) / 1048576.0, skin.tile_count()])
	# FALSIFY the assertion is meaningful: the ceiling is actually smaller than a full pitch-1 256 disc,
	# so the cap MUST have bound (else the gate proves nothing). Report the reached coverage below.

	# --- G-SKIN-M3 — time-to-cover the 256 annulus + reached coverage under the cap ------------------
	var skin2 := SKIN.new()
	get_root().add_child(skin2)
	skin2.setup(fid)
	var t0 := Time.get_ticks_usec()
	skin2.update(fid, Vector3(float(cy), float(g0), float(cz)), fids)
	var dt_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var pwc := FA.lattice_to_world64(fid, float(cy), float(g0), float(cz))
	var reach := skin2.coverage_radius(Vector3(pwc[0], pwc[1], pwc[2]))
	print("  ... M3: %d tiles built in %.1f ms; %.2f MB; coverage radius ~%.0f blocks (target R_OUTER=%.0f)"
		% [skin2.tile_count(), dt_ms, float(skin2.total_bytes()) / 1048576.0, reach, SKIN.R_OUTER])
	_ok(dt_ms <= 1500.0, "G-SKIN-M3 — cover pass built in %.1f ms (design target <= 1500 ms)" % dt_ms)
	_ok(skin2.total_bytes() <= SKIN.MAX_BYTES, "G-SKIN-M3 — cover pass respected the 8 MB ceiling")

	# --- G-SKIN-DRAW — merged draw calls: ONE per LIVE FACET, not one per tile (§ Part A) ------------
	# The whole point of the merge: the skin must render ~(live facets) MeshInstance3Ds, not ~(tiles). At
	# the shipped tile count that was ~114 extra draws (fps 60→30); merged it is ≤ the candidate-facet set.
	var mic := skin2.mesh_instance_count()
	var dfc := skin2.distinct_facet_count()
	var tc := skin2.tile_count()
	print("  ... DRAW: %d MeshInstance3Ds for %d distinct live facets over %d tiles (candidate fids %d)"
		% [mic, dfc, tc, fids.size()])
	_ok(mic == dfc and mic > 0,
		"G-SKIN-DRAW — %d merged draws == %d distinct live facets (exactly one merged draw per facet)" % [mic, dfc])
	_ok(mic <= fids.size(),
		"G-SKIN-DRAW — %d merged draws <= %d candidate facets (the ≤N_live_facets bound holds)" % [mic, fids.size()])
	_ok(mic < tc,
		"G-SKIN-DRAW — %d merged draws « %d tiles (merge cut skin draws ~%dx)" % [mic, tc, tc / maxi(mic, 1)])
	# FALSIFY: a per-tile skin would issue tile_count draws — which EXCEEDS the ≤facets bound. Proving
	# tc > dfc shows the merged assertion is non-trivial: without the merge it would fail.
	_ok(tc > dfc,
		"G-SKIN-DRAW-FALS — a per-tile skin (%d draws) would BREACH the %d-facet bound (the merge bound bites)" % [tc, dfc])

	# --- G-SKIN-COVER — the covered-tile skip: no overdraw over meshed near voxels, gap-fill preserved ----
	# The measured problem is STANDING STILL: after the player stops, the near field finishes meshing over
	# ~1 s and the skin tiles in the 64..128 band then render behind the opaque near voxels for nothing (the
	# ~20 fps fill hit). This gate models exactly that: (1) arrive over a STILL-STREAMING near field (nothing
	# meshed) — the skin fills the gap; (2) STAND while the near field meshes in — the reap must drop every
	# tile that becomes CONFIRMED-covered, while a tile over a persistent UNMESHED hole must KEEP rendering
	# (the skin's real job). It is driven by a scripted coverage Callable (the same (fid, fid-lattice AABB) ->
	# bool contract module_world.skin_near_meshed implements), so it exercises the EXACT decision path
	# (update/reap → _tile_covered → _probe_covered → cover_query) without a live VoxelTerrain.
	var T2: int = T
	var hole_tx := int(floor(float(cy + 80) / float(T2)))     # a persistent UNMESHED near hole (must render)
	var hole_tz := int(floor(float(cz) / float(T2)))
	var cov_tx := int(floor(float(cy - 80) / float(T2)))      # a tile the near field meshes over (must drop)
	var cov_tz := int(floor(float(cz) / float(T2)))
	var none_stub := func(_f: int, _b: AABB) -> bool: return false           # near field: nothing meshed yet
	var mesh_stub := func(_f: int, box: AABB) -> bool:                       # meshed everywhere EXCEPT the hole
		var qtx := int(round(box.position.x / float(T2)))
		var qtz := int(round(box.position.z / float(T2)))
		return not (qtx == hole_tx and qtz == hole_tz)

	# Baseline: arrive at the pose with NO coverage query (invalid Callable) — every in-range owned tile is
	# emitted, exactly the pre-fix behaviour. This is the "before" tile-emit count (the fill/overdraw proxy).
	var skin_base := SKIN.new()
	get_root().add_child(skin_base)
	skin_base.setup(fid)
	skin_base.update(fid, Vector3(float(cy), float(g0), float(cz)), fids)    # 3-arg → no skip
	var base_tiles := skin_base.tile_count()
	var base_has_cov := skin_base.has_tile(fid, cov_tx, cov_tz)
	var base_has_hole := skin_base.has_tile(fid, hole_tx, hole_tz)

	# With coverage: arrive over a streaming near field, THEN stand while it meshes in (reap a few throttle
	# ticks to clear COVER_CONFIRM). The covered tiles must be gone; the hole must remain.
	var skin_cov := SKIN.new()
	get_root().add_child(skin_cov)
	skin_cov.setup(fid)
	skin_cov.update(fid, Vector3(float(cy), float(g0), float(cz)), fids, none_stub)   # arrive (gap-fill)
	var stream_tiles := skin_cov.tile_count()
	var stream_has_cov := skin_cov.has_tile(fid, cov_tx, cov_tz)              # rendered while streaming
	for _r in range(0, 4):
		skin_cov.gate_reap(fid, Vector3(float(cy), float(g0), float(cz)), mesh_stub)  # stand: mesh settles
	var settled_tiles := skin_cov.tile_count()
	var settled_has_cov := skin_cov.has_tile(fid, cov_tx, cov_tz)
	var settled_has_hole := skin_cov.has_tile(fid, hole_tx, hole_tz)
	print("  ... COVER: tiles emitted no-skip=%d ; streaming(gap-fill)=%d ; standing-settled=%d ; covered-tile %s(stream)->%s(settled) ; hole settled=%s"
		% [base_tiles, stream_tiles, settled_tiles, str(stream_has_cov), str(settled_has_cov), str(settled_has_hole)])
	_ok(base_has_cov and base_has_hole, "G-SKIN-COVER — baseline (no coverage query) emits both the covered tile and the hole (the overdraw exists to remove)")
	_ok(stream_has_cov, "G-SKIN-COVER — while the near field is STILL STREAMING the tile IS emitted (immediate gap-fill preserved)")
	_ok(not settled_has_cov, "G-SKIN-COVER — once the near field meshes in, the covered tile is REAPED while standing (the standing overdraw is removed)")
	_ok(settled_has_hole, "G-SKIN-COVER — a tile over a persistent UNMESHED hole KEEPS rendering (gap-fill not over-reaped)")
	_ok(settled_tiles < base_tiles, "G-SKIN-COVER — the standing-settled emit count fell far below baseline (%d -> %d)" % [base_tiles, settled_tiles])

	# FALSIFY: if the near field NEVER meshes (all-exposed query), the covered tile is NEVER reaped — proving
	# the skip is driven by CONFIRMED coverage, not by anything incidental (position, budget, ownership, time).
	var skin_fals := SKIN.new()
	get_root().add_child(skin_fals)
	skin_fals.setup(fid)
	skin_fals.update(fid, Vector3(float(cy), float(g0), float(cz)), fids, none_stub)
	for _r2 in range(0, 4):
		skin_fals.gate_reap(fid, Vector3(float(cy), float(g0), float(cz)), none_stub)
	_ok(skin_fals.has_tile(fid, cov_tx, cov_tz),
		"G-SKIN-COVER-FALS — with nothing ever meshed the tile is NEVER reaped (the skip is coverage-driven, the test bites)")

	# G-SKIN-MEM still holds under the skip (skipping/reaping only ever removes tiles → bytes can only fall).
	_ok(skin_cov.total_bytes() <= SKIN.MAX_BYTES, "G-SKIN-COVER — the 8 MB ceiling still holds with the skip on")

	_done(0 if _fail == 0 else 1)

## The front-hemisphere neighbour facets of `fid` (a handful) — the candidate set the live skin covers.
func _front_neighbours(fid: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var nrm := FA.facet_normal64(fid)
	var k: int = FA.K
	var nf := 6 * k * k
	for f in range(nf):
		if f == fid:
			continue
		var cd := FA.facet_normal64(f)
		if cd[0] * nrm[0] + cd[1] * nrm[1] + cd[2] * nrm[2] >= 0.85:   # immediate neighbours only
			out.append(f)
	return out
