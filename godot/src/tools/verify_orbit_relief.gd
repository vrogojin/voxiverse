extends SceneTree
## FP_ORBIT_RELIEF gate (docs/COSMOS-ORBIT-RELIEF-MESH-DESIGN.md, task #99 G3).
##
## Proves `FacetOrbitRelief` — the real relief-mesh tier that supersedes the rejected shading-only fix
## (FP_SKIN_RELIEF_SHADE/FP_RELIEF_REEMIT) — is byte-off by default, reads heights/positions that agree exactly
## with the already-baked `GlobalReliefData` DEM, welds bit-identically at shared facet edges, self-heals its
## no-protrusion seams at commit time (WS4), stays inside its NEVER-OOM byte cap, commits in O(≤batch) not
## O(resident-set) (WS1b), is fully suspended on-surface (WS1a), and lights with the flat skin's terminator-ONLY
## law — no per-slope shading (WS3, user verdict "no slope shades, it just looks ugly").
##
## Gates (mirrors `verify_far_geometry.gd`/`verify_relief_reemit.gd`'s self-describing convention — this run's
## compiled flags decide which assertions are meaningful):
##   G-OR-OFF          — FP_ORBIT_RELIEF off: `FacetFarRing.set_relief_data` never constructs a `FacetOrbitRelief`.
##   G-OR-LIGHT (WS3)   — the shader source calls `voxi_shade`, derives its normal IN-SHADER from VERTEX position
##                        (never reads a mesh NORMAL attribute — the mesh carries none), has no real-normal
##                        relief/lambert term, and `make_material` never touches `FacetSmoothV2` (G3's material is
##                        fully independent, so it can never inherit `FP_SMOOTH_V2_LIT`'s slope shading).
##   G-OR-DATA-EQ       — `build_tile`'s stored height at every one of a real facet's 1089 nodes equals
##                        `GlobalReliefData.height_at` EXACTLY. Falsifier: a hand-perturbed `heights` snapshot
##                        entry diverges from the oracle at that same node.
##   G-OR-BYTES         — `tile_bytes`/`arena_bytes` match the real per-component arithmetic; `want_set`
##                        truncates to `ORBIT_RELIEF_MAX_TILES` even when EVERY facet on the planet is a
##                        candidate; `arena_bytes()` stays under a 32 MB safety ceiling.
##   G-OR-WELD          — two real adjacent facets' shared-edge node positions coincide (≤1e-4·R_BLOCKS, f32
##                        rounding) — the One-Surface Law proof. `sunk_positions` (the WS4 commit-time sink,
##                        pure) sinks EXACTLY the flagged edge by `TierPlace.backstop_sink()` and leaves every
##                        other node untouched.
##   G-OR-SEAM (WS4)    — falsifier: commit facet A alone (its neighbour B not yet committed) — A's edge facing
##                        B is sunk. Then admit + commit B — BOTH now read the identical un-sunk (true DEM)
##                        height on the shared edge, self-healed with no rebuild of A's own data beyond a
##                        position rewrite. Never a one-sided cliff at any point in the sequence.
##   G-OR-COMMIT-COST (WS1b) — one `_commit()` call touches O(≤ORBIT_RELIEF_COMMIT_TILES) tiles' data, NEVER
##                        the whole resident set — falsifier: mark all `ORBIT_RELIEF_MAX_TILES` tiles dirty at
##                        once, confirm only the batch cap gets (re)written per call, and `_commit()`'s own
##                        source never calls `FacetSmoothV2.merge_tiles` (the O(resident) re-merge this removes).
##   G-OR-SUSPEND (WS1a) — on-surface (`shell_offsurface()` false): `step()` performs zero recompute/dispatch/
##                        commit past the initial reap — the resident/committed set is BYTE-IDENTICAL before and
##                        after. Off-surface: normal operation (dispatch + commit) resumes immediately.
##
## RUN (needs FACETED + FP_GLOBAL_RELIEF_DATA sed-toggled true for the ON-path gates, per the design's
## dependency on G2):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_orbit_relief.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const FOR_ := preload("res://src/world/facet_orbit_relief.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

const EPS := 1.0e-4

func _initialize() -> void:
	print("=== verify_orbit_relief (task #99 G3 — FP_ORBIT_RELIEF) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	FA.warm_up()

	_gate_off()
	_gate_light()
	if CubeSphere.FP_ORBIT_RELIEF and CubeSphere.FP_GLOBAL_RELIEF_DATA:
		_gate_data_eq()
		_gate_bytes()
		_gate_weld()
		_gate_seam()
		_gate_commit_cost()
		_gate_suspend()
	else:
		_ok(true, "G-OR-DATA-EQ/BYTES/WELD/SEAM/COMMIT-COST/SUSPEND: skipped this run (needs FP_ORBIT_RELIEF + FP_GLOBAL_RELIEF_DATA both sed-toggled true)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Real off-surface fixture: a bare `FacetFarRing.new()` defaults ON-surface (`_cam_set=false` ⇒
## `shell_offsurface()==false`), which would make `step()` early-return in every dispatch-exercising gate below.
## Poke the two private fields `shell_offsurface()` reads (mirrors the established "gates poke private fields
## directly" precedent, e.g. `verify_far_geometry.gd`'s `ring._active_fid = fid`) so these gates actually drive
## the off-surface path — the SAME path a real orbit session runs.
func _force_offsurface(ring: FacetFarRing) -> void:
	ring._cam_set = true
	ring._emit_floored_last = false

# --- G-OR-OFF: self-describing, run only when FP_ORBIT_RELIEF is off this run ----------------------------------------
func _gate_off() -> void:
	if CubeSphere.FP_ORBIT_RELIEF:
		_ok(true, "G-OR-OFF: skipped this run (flag currently ON — the ON-path gates below cover behaviour)")
		return
	var rd := GlobalReliefData.new()
	rd.setup()
	var ring := FacetFarRing.new()
	ring._active_fid = 12
	ring.set_relief_data(rd)
	_ok(ring._orbit_relief == null, "G-OR-OFF: set_relief_data never constructs FacetOrbitRelief with the flag off")
	ring.free()

# --- G-OR-LIGHT (WS3, user verdict "no slope shades"): terminator-only, radial in-shader normal, no ARRAY_NORMAL ------
func _gate_light() -> void:
	var code := FOR_.shader_code()
	_ok(code.find("voxi_shade(") != -1, "G-OR-LIGHT: the shader calls voxi_shade — the flat skin's SAME day/night/terminator law")
	_ok(code.find("wp - centre") != -1, "G-OR-LIGHT: the shading normal is derived IN-SHADER from VERTEX position (wp - centre), not from a mesh attribute")
	_ok(code.find("NORMAL") == -1, "G-OR-LIGHT: the shader never reads the mesh NORMAL attribute at all")
	# "lam" alone would false-positive on "clamp" — check for the actual banned patterns instead (a real
	# per-slope lambert/relief term reads as "lam =", "lam)", or a "relief" identifier — none of which are
	# substrings of any word this shader source legitimately uses).
	_ok(code.find("lam ") == -1 and code.find("lam)") == -1 and code.find("relief") == -1,
		"G-OR-LIGHT: no real-normal relief/lambert term anywhere (no lam=dot(nm,..), no relief term — user verdict: no slope shades)")
	_ok(code.find("ALBEDO = v_col.rgb") != -1 or code.find("ALBEDO=v_col.rgb") != -1,
		"G-OR-LIGHT: ALBEDO is exactly fine_albedo(COLOR) * v_st — nothing else composited in")

	# G3's material is its OWN — never shares/derives from FacetSmoothV2's, so its lighting can never accidentally
	# couple to FP_SMOOTH_V2_LIT (V2's own, unrelated, slope-shaded variant). Extract make_material()'s body by
	# INDENTATION (every real body line starts with a tab), not by "next func" text search — the instance section
	# right after it is mostly comments/var declarations at column 0, not another `func`, so a naive "\nfunc "
	# search over-captures hundreds of unrelated lines (including a doc comment that legitimately says
	# "Mirrors FacetSmoothV2's worker-slot-pool...").
	var f := FileAccess.open("res://src/world/facet_orbit_relief.gd", FileAccess.READ)
	_ok(f != null, "G-OR-LIGHT: opened facet_orbit_relief.gd for the static source check")
	if f != null:
		var lines := f.get_as_text().split("\n")
		var in_body := false
		var body_lines: Array = []
		var found := false
		for line in lines:
			if not in_body:
				if line.begins_with("static func make_material()"):
					in_body = true
					found = true
				continue
			if line.begins_with("\t") or line.strip_edges() == "":
				body_lines.append(line)
			else:
				break   # dedented to column 0 ⇒ left the function body
		_ok(found, "G-OR-LIGHT: found make_material()'s definition")
		var body := "\n".join(body_lines)
		_ok(body.find("FacetSmoothV2") == -1, "G-OR-LIGHT: make_material() never calls into FacetSmoothV2 — G3's material is fully independent")

	var mat := FOR_.make_material()
	_ok(mat is ShaderMaterial, "G-OR-LIGHT: make_material() returns a ShaderMaterial")
	_ok(mat.get_shader_parameter("sun_dir") != null, "G-OR-LIGHT: the material carries a sun_dir shader parameter")

	# set_sun_dir on a live instance updates the material's uniform (mirrors FacetSmoothV2.set_sun_dir's contract).
	var fid := 12
	var rd := GlobalReliefData.new()
	rd.setup()
	var ring2 := FacetFarRing.new()
	ring2._active_fid = fid
	_force_offsurface(ring2)
	var relief := FacetOrbitRelief.new()
	relief.setup_instance(ring2, fid, rd)
	var new_sun := Vector3(0.3, 0.6, 0.74).normalized()
	relief.set_sun_dir(new_sun)
	var got_sun: Vector3 = relief._material.get_shader_parameter("sun_dir")
	_ok(got_sun.distance_to(new_sun) < 1.0e-6, "G-OR-LIGHT: set_sun_dir updates THIS instance's own material uniform exactly")
	ring2.free()

# --- G-OR-DATA-EQ: build_tile's stored heights == the GlobalReliefData oracle, falsifiable ----------------------------
func _gate_data_eq() -> void:
	var fid := 12   # real terrain, the same facet the STAGE-1/FIRES gates already use
	var rd := GlobalReliefData.new()
	rd.setup()
	_ok(rd.is_ready(), "G-OR-DATA-EQ: GlobalReliefData.setup() allocates (FP_GLOBAL_RELIEF_DATA on)")
	_ok(rd.bake_facet(fid), "G-OR-DATA-EQ: bake_facet(fid) succeeds")

	var heights := rd.height_grid(fid)
	_ok(heights.size() == GlobalReliefData.NODES_PER_FACET, "G-OR-DATA-EQ: height_grid returns the full %d-node snapshot" % GlobalReliefData.NODES_PER_FACET)

	var tile := FOR_.build_tile(fid, heights, PackedColorArray(), 0)
	_ok(not tile.is_empty(), "G-OR-DATA-EQ: build_tile succeeds on a baked facet")
	var g: PackedInt32Array = tile["g"]
	var stride := FOR_.ORBIT_RELIEF_CELLS + 1
	var worst := 0
	for j in range(stride):
		for i in range(stride):
			var want := rd.height_at(fid, i, j)
			var got := g[j * stride + i]
			worst = maxi(worst, absi(got - want))
	_ok(worst == 0, "G-OR-DATA-EQ: every one of %d nodes' stored height == GlobalReliefData.height_at exactly (worst Δ=%d)" % [heights.size(), worst])

	# WS1b: vert_base is baked into idx at build time — index k should equal (local index + vert_base).
	var idx: PackedInt32Array = tile["idx"]
	var base := 7000
	var tile_b := FOR_.build_tile(fid, heights, PackedColorArray(), base)
	var idx_b: PackedInt32Array = tile_b["idx"]
	var offsets_ok := true
	for k in range(idx.size()):
		if idx_b[k] != idx[k] + base:
			offsets_ok = false
			break
	_ok(offsets_ok, "G-OR-DATA-EQ: build_tile bakes vert_base into every idx entry exactly (worker-side, WS1b)")

	# Falsification: perturb ONE entry of a COPY before building, and confirm THAT node's stored height now
	# diverges from the (unperturbed) oracle — proving this gate actually reads through build_tile, not just
	# echoing back whatever it was fed.
	var bad := heights.duplicate()
	bad[100] += 77
	var bad_tile := FOR_.build_tile(fid, bad, PackedColorArray(), 0)
	var bad_g: PackedInt32Array = bad_tile["g"]
	_ok(bad_g[100] != rd.height_at(fid, 100 % stride, int(100 / stride)),
		"G-OR-DATA-EQ: a perturbed heights[100] DIVERGES from the true oracle at that node (gate is falsifiable)")

	# A refusal contract: wrong-size / empty heights never returns a non-empty tile.
	_ok(FOR_.build_tile(fid, PackedInt32Array(), PackedColorArray(), 0).is_empty(),
		"G-OR-DATA-EQ: build_tile refuses (returns {}) on an empty/malformed heights snapshot")

# --- G-OR-BYTES: real tile_bytes/arena_bytes arithmetic + the hard want_set cap, even under an all-planet burst ------
func _gate_bytes() -> void:
	var fid := 12
	var rd := GlobalReliefData.new()
	rd.setup()
	rd.bake_facet(fid)
	var heights := rd.height_grid(fid)
	var tile := FOR_.build_tile(fid, heights, PackedColorArray(), 0)
	var tb := FOR_.tile_bytes(tile)
	var stride := FOR_.ORBIT_RELIEF_CELLS + 1
	var nv: int = (tile["pos"] as PackedVector3Array).size()
	var ni: int = (tile["idx"] as PackedInt32Array).size()
	# WS3: pos 12B + col 16B (NO nrm — the mesh carries no normal attribute at all, see facet_orbit_relief.gd's doc).
	var want_bytes := nv * (12 + 16) + ni * 4
	_ok(tb == want_bytes, "G-OR-BYTES: tile_bytes matches the real per-component arithmetic, WS3 no-normal (%d verts, %d indices) exactly" % [nv, ni])
	_ok(not tile.has("nrm"), "G-OR-BYTES: WS3 — build_tile's returned dict carries NO 'nrm' key at all")
	_ok(nv == FOR_.VERTS_PER_TILE and ni == FOR_.IDX_PER_TILE, "G-OR-BYTES: a tile's vert/idx count == VERTS_PER_TILE/IDX_PER_TILE exactly (fixed-slot arena precondition, WS1b)")

	var arena_want := CubeSphere.ORBIT_RELIEF_MAX_TILES * (FOR_.VERTS_PER_TILE * (12 + 16) + FOR_.IDX_PER_TILE * 4)
	_ok(FOR_.arena_bytes() == arena_want, "G-OR-BYTES: arena_bytes() matches the fixed-capacity arithmetic exactly")
	var cap_mb := float(FOR_.arena_bytes()) / (1024.0 * 1024.0)
	_ok(cap_mb <= 32.0, "G-OR-BYTES: the arena's fixed allocation stays under the 32 MB safety ceiling (got %.2f MB)" % cap_mb)

	# The pathological burst: EVERY facet on the planet is a candidate (a huge reach, huge theta_h) — want_set
	# must still truncate to the hard cap.
	var n := FA.facet_count()
	var all_fids := PackedInt32Array(); all_fids.resize(n)
	for i in range(n):
		all_fids[i] = i
	var order := FOR_.want_set(fid, Vector3(0, 0, 1), PI, 0, CubeSphere.ORBIT_RELIEF_MAX_TILES, all_fids, PI)
	_ok(order.size() <= CubeSphere.ORBIT_RELIEF_MAX_TILES, "G-OR-BYTES: want_set NEVER exceeds ORBIT_RELIEF_MAX_TILES(%d) even when all %d facets are candidates (got %d)" % [CubeSphere.ORBIT_RELIEF_MAX_TILES, n, order.size()])
	_ok(order.size() == CubeSphere.ORBIT_RELIEF_MAX_TILES, "G-OR-BYTES: the all-planet burst actually SATURATES the cap (proves this isn't a vacuous pass)")

# --- G-OR-WELD: shared-edge positions coincide + sunk_positions sinks EXACTLY the flagged edge -------------------------
func _gate_weld() -> void:
	var fid_a := 12
	var fid_b := FA.seam_neighbour(fid_a, FA.S_EAST)
	_ok(fid_b >= 0, "G-OR-WELD: facet %d has a real EAST neighbour" % fid_a)
	if fid_b < 0:
		return
	var rd := GlobalReliefData.new()
	rd.setup()
	rd.bake_facet(fid_a)
	rd.bake_facet(fid_b)
	var tile_a := FOR_.build_tile(fid_a, rd.height_grid(fid_a), PackedColorArray(), 0)
	var tile_b := FOR_.build_tile(fid_b, rd.height_grid(fid_b), PackedColorArray(), 0)
	var pos_a: PackedVector3Array = tile_a["pos"]
	var pos_b: PackedVector3Array = tile_b["pos"]
	var cells := FOR_.ORBIT_RELIEF_CELLS
	var stride := cells + 1
	var edge_a: Array = []
	for j in range(stride):
		edge_a.append(pos_a[j * stride + cells])
	var edge_b: Array = []
	for j in range(stride):
		edge_b.append(pos_b[j * stride + 0])
	var scale := float(FacetAtlas.R_BLOCKS)
	var matched := 0
	for pa in edge_a:
		var best := INF
		for pb in edge_b:
			best = minf(best, (pa as Vector3).distance_to(pb as Vector3))
		if best <= EPS * scale:
			matched += 1
	_ok(matched == edge_a.size(), "G-OR-WELD: every one of fid %d's EAST-edge nodes has a coincident node on fid %d's WEST edge (%d/%d matched, ≤%.4f blocks)" % [fid_a, fid_b, matched, edge_a.size(), EPS * scale])

	# sunk_positions (WS4, pure): sinking WEST only moves i=0 nodes by exactly backstop_sink(); everything else untouched.
	var mask := 1 << FacetSmoothV2.EDGE_WEST
	var sunk := FOR_.sunk_positions(pos_a, cells, stride, mask)
	var sink := TierPlace.backstop_sink()
	var boundary_ok := true
	var interior_ok := true
	for j in range(stride):
		for i in range(stride):
			var k := j * stride + i
			var d_raw := (pos_a[k] as Vector3).length()
			var d_sunk := (sunk[k] as Vector3).length()
			if i == 0:
				if absf((d_raw - d_sunk) - sink) > EPS * scale:
					boundary_ok = false
			else:
				if pos_a[k].distance_to(sunk[k]) > EPS * scale:
					interior_ok = false
	_ok(boundary_ok, "G-OR-WELD: sunk_positions sinks the flagged WEST-edge (i=0) nodes by EXACTLY backstop_sink() (%.2f blocks)" % sink)
	_ok(interior_ok, "G-OR-WELD: sunk_positions leaves every non-flagged node (i>0) untouched — scoped, not tier-wide")
	_ok(pos_a[0].distance_to((FOR_.sunk_positions(pos_a, cells, stride, 0) as PackedVector3Array)[0]) <= EPS * scale,
		"G-OR-WELD: sunk_positions is a no-op (byte-identical copy) with sink_edges==0")

# --- G-OR-SEAM (WS4): a build-up sequence never shows a one-sided cliff, and heals to the true height -----------------
# NOTE (root-cause correction, live A/B follow-up): node (i=cells, j=0) — the j=0 END of A's EAST edge — is a
# CORNER shared with A's SOUTH edge too (`_edge_indices` for SOUTH includes gi=cells). A node on TWO cardinal
# edges legitimately stays sunk as long as EITHER bordering neighbour is uncommitted — it must still guard against
# protrusion from whichever side is still open — so it only fully heals to the TRUE height once EVERY neighbour it
# borders has committed, not just one. Testing that exact corner for "heals as soon as ONLY the EAST neighbour
# commits" was the earlier gate's bug (not a `_commit()` bug: direct instrumentation confirmed `_commit()` already
# rewrites A's mask correctly and A/B never disagree at any point — Δ=0.000000 measured — the corner just wasn't
# expected to reach `a_raw` yet). This version tests THREE properties instead: (1) a pure EAST-only INTERIOR node
# (j=cells/2, on no other cardinal edge) heals to the true height the instant ONLY B commits — the direct proof of
# this WS4 fix; (2) the shared CORNER never shows a crack between A's and B's copies at any point (the actual
# no-one-sided-cliff safety property) even while it is still correctly sunk; (3) once ALL of A's neighbours have
# committed, the corner ALSO fully heals — the complete self-heal closure. Also exercises the `sunk_positions`
# double-sink fix: a node on 2 flagged edges must sink by exactly ONE `backstop_sink()`, not two — falsified below
# by checking the alone-facet corner sinks by the SAME amount as the interior edge nodes, not double.
func _gate_seam() -> void:
	var fid_a := 12
	var fid_b := FA.seam_neighbour(fid_a, FA.S_EAST)
	var fid_s := FA.seam_neighbour(fid_a, FA.S_SOUTH)
	var fid_w := FA.seam_neighbour(fid_a, FA.S_WEST)
	var fid_n := FA.seam_neighbour(fid_a, FA.S_NORTH)
	_ok(fid_b >= 0 and fid_s >= 0 and fid_w >= 0 and fid_n >= 0, "G-OR-SEAM: facet %d has all 4 real cardinal neighbours" % fid_a)
	if fid_b < 0 or fid_s < 0 or fid_w < 0 or fid_n < 0:
		return
	var rd := GlobalReliefData.new()
	rd.setup()
	for f in [fid_a, fid_b, fid_s, fid_w, fid_n]:
		rd.bake_facet(f)
	var ring := FacetFarRing.new()
	ring._active_fid = fid_a
	_force_offsurface(ring)
	var relief := FacetOrbitRelief.new()
	relief.setup_instance(ring, fid_a, rd)

	var stride := FOR_.ORBIT_RELIEF_CELLS + 1
	var cells := FOR_.ORBIT_RELIEF_CELLS
	var mid := int(cells / 2)
	var raw_pos: PackedVector3Array = (FOR_.build_tile(fid_a, rd.height_grid(fid_a), PackedColorArray(), 0)["pos"] as PackedVector3Array)
	var a_edge_mid_raw := raw_pos[mid * stride + cells]     # (i=cells, j=mid) — pure EAST-edge INTERIOR node
	var a_corner_raw := raw_pos[0 * stride + cells]          # (i=cells, j=0) — the EAST/SOUTH shared CORNER
	var scale := float(FacetAtlas.R_BLOCKS)

	# Step 1: A alone is dirty/ready; every neighbour is NOT in the committed set yet — every touched node sunk.
	relief._want = {fid_a: true}
	relief._tiles[fid_a] = FOR_.build_tile(fid_a, rd.height_grid(fid_a), PackedColorArray(), relief._alloc_arena_slot(fid_a) * FOR_.VERTS_PER_TILE)
	relief._commit_dirty = true
	relief._commit()
	_ok(relief._committed_tiles.has(fid_a), "G-OR-SEAM: facet A is committed alone")
	var slot_a: int = relief._fid_slot[fid_a]
	var vbase_a := slot_a * FOR_.VERTS_PER_TILE
	var a_edge_mid_before := relief._arena_pos[vbase_a + mid * stride + cells]
	var a_corner_before := relief._arena_pos[vbase_a + 0 * stride + cells]
	var d_edge_before := absf(a_edge_mid_before.length() - a_edge_mid_raw.length())
	var d_corner_before := absf(a_corner_before.length() - a_corner_raw.length())
	_ok(d_edge_before > 1.0, "G-OR-SEAM: A's EAST-edge interior node is SUNK while B is uncommitted — Δ=%.2f" % d_edge_before)
	_ok(d_corner_before > 1.0, "G-OR-SEAM: A's shared corner is also SUNK while every neighbour is uncommitted — Δ=%.2f" % d_corner_before)
	_ok(absf(d_corner_before - d_edge_before) <= EPS * scale,
		"G-OR-SEAM: the corner (on 2 flagged edges) sinks by the SAME single amount as an interior node (on 1) — no double-sink (edge Δ=%.4f corner Δ=%.4f)" % [d_edge_before, d_corner_before])

	# Step 2: admit + commit ONLY B (the EAST neighbour). The pure EAST-edge interior node must now read the TRUE
	# height; the CORNER (still bordering the uncommitted SOUTH neighbour) legitimately stays sunk — but IDENTICALLY
	# on both A's and B's copy, so there is still no crack (the real no-one-sided-cliff invariant).
	relief._want[fid_b] = true
	relief._tiles[fid_b] = FOR_.build_tile(fid_b, rd.height_grid(fid_b), PackedColorArray(), relief._alloc_arena_slot(fid_b) * FOR_.VERTS_PER_TILE)
	relief._commit_dirty = true
	relief._commit()
	_ok(relief._committed_tiles.has(fid_b), "G-OR-SEAM: facet B is now committed")
	var slot_b: int = relief._fid_slot[fid_b]
	var vbase_b := slot_b * FOR_.VERTS_PER_TILE
	var a_edge_mid_after := relief._arena_pos[vbase_a + mid * stride + cells]
	var a_corner_after := relief._arena_pos[vbase_a + 0 * stride + cells]
	var b_corner_after := relief._arena_pos[vbase_b + 0 * stride + 0]     # B's (i=0,j=0) — its WEST edge, same seam node as A's corner
	_ok(a_edge_mid_after.distance_to(a_edge_mid_raw) <= EPS * scale,
		"G-OR-SEAM: once B commits, A's EAST-edge INTERIOR node self-heals to the true un-sunk height (Δ=%.4f)" % a_edge_mid_after.distance_to(a_edge_mid_raw))
	_ok(absf(a_corner_after.length() - a_corner_raw.length()) > 1.0,
		"G-OR-SEAM: the shared corner correctly STAYS sunk (its SOUTH neighbour is still uncommitted) — Δ=%.2f" % absf(a_corner_after.length() - a_corner_raw.length()))
	_ok(a_corner_after.distance_to(b_corner_after) <= EPS * scale,
		"G-OR-SEAM: A and B agree EXACTLY at the shared corner even while both still sink it — no one-sided cliff (Δ=%.6f)" % a_corner_after.distance_to(b_corner_after))

	# Step 3: commit A's remaining neighbours (S/W/N) too — every one of A's edges is now resolved, so even the
	# corner must fully self-heal — the complete closure of the self-heal property.
	for f in [fid_s, fid_w, fid_n]:
		relief._want[f] = true
		relief._tiles[f] = FOR_.build_tile(f, rd.height_grid(f), PackedColorArray(), relief._alloc_arena_slot(f) * FOR_.VERTS_PER_TILE)
	relief._commit_dirty = true
	var iterations := 0
	while relief._commit_dirty and iterations < 10:
		relief._commit()
		iterations += 1
	var a_corner_final := relief._arena_pos[vbase_a + 0 * stride + cells]
	_ok(a_corner_final.distance_to(a_corner_raw) <= EPS * scale,
		"G-OR-SEAM: once ALL of A's neighbours are committed, even the shared corner fully self-heals to the true height (Δ=%.4f)" % a_corner_final.distance_to(a_corner_raw))

	ring.free()

# --- G-OR-COMMIT-COST (WS1b): O(≤batch), never O(resident-set); no merge_tiles re-scan in _commit() -------------------
func _gate_commit_cost() -> void:
	# Static source check: _commit()'s body never calls FacetSmoothV2.merge_tiles (the O(resident-set) re-merge
	# the arena replaces) and never touches SurfaceTool/generate_normals (the earlier perf fix, still true).
	var f := FileAccess.open("res://src/world/facet_orbit_relief.gd", FileAccess.READ)
	_ok(f != null, "G-OR-COMMIT-COST: opened facet_orbit_relief.gd for the static source check")
	if f != null:
		var text := f.get_as_text()
		var start := text.find("func _commit()")
		_ok(start >= 0, "G-OR-COMMIT-COST: found _commit()'s definition")
		if start >= 0:
			var next_func := text.find("\nfunc ", start + 1)
			var body := text.substr(start, (next_func - start) if next_func >= 0 else -1)
			_ok(body.find("merge_tiles") == -1, "G-OR-COMMIT-COST: _commit()'s body never calls FacetSmoothV2.merge_tiles (WS1b — no whole-set re-merge)")
			_ok(body.find("SurfaceTool") == -1, "G-OR-COMMIT-COST: _commit()'s body never references SurfaceTool")
			_ok(body.find("generate_normals") == -1, "G-OR-COMMIT-COST: _commit()'s body never calls generate_normals")
			_ok(body.find("add_surface_from_arrays") != -1, "G-OR-COMMIT-COST: _commit() still commits via the SAFE high-level add_surface_from_arrays API")

	# The batch cap: mark the WHOLE 384-tile want-set as already BUILT (bypassing real dispatch — this gate only
	# needs to prove the COMMIT-time batching, not re-prove dispatch pacing, already covered by the dispatch test
	# below) and confirm ONE _commit() call folds at most ORBIT_RELIEF_COMMIT_TILES of them into the arena.
	var fid := 12
	var rd := GlobalReliefData.new()
	rd.setup()
	rd.bake_facet(fid)
	var ring := FacetFarRing.new()
	ring._active_fid = fid
	_force_offsurface(ring)
	var relief := FacetOrbitRelief.new()
	relief.setup_instance(ring, fid, rd)
	var n := CubeSphere.ORBIT_RELIEF_MAX_TILES
	var heights := rd.height_grid(fid)
	for i in range(n):
		var slot := relief._alloc_arena_slot(i)
		relief._tiles[i] = FOR_.build_tile(fid, heights, PackedColorArray(), slot * FOR_.VERTS_PER_TILE)
	relief._commit_dirty = true
	relief._commit()
	_ok(relief._committed_tiles.size() <= CubeSphere.ORBIT_RELIEF_COMMIT_TILES,
		"G-OR-COMMIT-COST: ONE _commit() call admits at most ORBIT_RELIEF_COMMIT_TILES(%d) of the %d-tile burst (got %d)" % [CubeSphere.ORBIT_RELIEF_COMMIT_TILES, n, relief._committed_tiles.size()])
	_ok(relief._committed_tiles.size() == CubeSphere.ORBIT_RELIEF_COMMIT_TILES,
		"G-OR-COMMIT-COST: the burst actually SATURATES the batch cap (proves this isn't a vacuous pass)")
	_ok(relief._commit_dirty, "G-OR-COMMIT-COST: still dirty after one capped commit — the rest of the burst is NOT silently dropped")
	var iterations := 0
	while relief._commit_dirty and iterations < n:
		relief._commit()
		iterations += 1
	_ok(not relief._commit_dirty and relief._committed_tiles.size() == n,
		"G-OR-COMMIT-COST: repeated capped commits eventually converge to the full %d-tile resident set (took %d more commits)" % [n, iterations])
	ring.free()

# --- G-OR-SUSPEND (WS1a): on-surface freezes everything past the initial reap --------------------------------------
func _gate_suspend() -> void:
	var fid := 12
	var rd := GlobalReliefData.new()
	rd.setup()
	rd.bake_facet(fid)
	var ring := FacetFarRing.new()
	ring._active_fid = fid
	# Deliberately do NOT call _force_offsurface — a bare ring's shell_offsurface() is false (on-surface),
	# matching the fixture this gate needs.
	_ok(not ring.shell_offsurface(), "G-OR-SUSPEND: fixture sanity — a bare ring is ON-surface by default")
	var relief := FacetOrbitRelief.new()
	relief.setup_instance(ring, fid, rd)

	# Seed some pending work as if a prior off-surface session left it queued.
	relief._want = {fid: true}
	relief._want_order = [fid]
	var before_committed := relief._committed_tiles.size()
	var before_tiles := relief._tiles.size()
	var before_want := relief._want.duplicate()

	relief.step()   # ON-surface: must be a complete no-op past the (empty) reap.

	_ok(relief._committed_tiles.size() == before_committed, "G-OR-SUSPEND: on-surface step() dispatches/commits NOTHING (committed count unchanged)")
	_ok(relief._tiles.size() == before_tiles, "G-OR-SUSPEND: on-surface step() builds NOTHING (no worker dispatch)")
	_ok(relief._want == before_want, "G-OR-SUSPEND: on-surface step() never recomputes the want-set")

	# set_active while on-surface: records the new fid, does NOT force a recompute.
	relief.set_active(fid + 1)
	_ok(relief._active_fid == fid + 1, "G-OR-SUSPEND: set_active still records the new active fid on-surface")
	_ok(relief._want == before_want, "G-OR-SUSPEND: set_active on-surface does NOT force a want-set recompute (mesh stays frozen)")

	# Now go off-surface: normal operation must resume immediately.
	_force_offsurface(ring)
	relief.step()
	_ok(not relief._want.is_empty(), "G-OR-SUSPEND: the FIRST off-surface step() recomputes a real want-set (resumes normal operation)")

	ring.free()
