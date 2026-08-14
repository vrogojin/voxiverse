extends SceneTree
## COSMOS FAR-TREES gate (docs/COSMOS-FAR-TREES-DESIGN.md §9, P0 scope — task #114).
##
## Proves the P0 far-tree card tier (`FacetFarTrees` + the additive `TreeGen.tree_info` enumeration) is byte-off by
## default, enumerates cards in an exact BIJECTION with the near voxel trees' placement (same TreeGen hashes, one
## owner per column), stays inside its NEVER-OOM byte + instance caps, never emits a card inside the near radius
## (the #110/#113 no-far-over-near law) and radially sinks every base below the true surface, and lights with the
## fed Sun — welded, never frozen at the (1,0,0) fake-noon seed.
##
## Gates (self-describing — this run's compiled flags decide which assertions are meaningful):
##   G-FT-OFF        — FP_FAR_TREES / *_CARDS default false; `TreeGen.tree_info` is a PURE, ADDITIVE refactor that
##                     AGREES with the untouched near path (`has_tree`/`block_at`): a tree_info hit ⟺ a real trunk
##                     log sits at base+1; a miss ⟺ no tree. (Near placement byte-identity — block_at is untouched.)
##   G-FT-PLACEMENT  — for N sample Earth facets the card enumeration is a BIJECTION with the owned near trees:
##                     count matches an independent walk, every emitted tree reproduces species/trunk_h/base from
##                     the SAME salts, is owned by EXACTLY one facet (in_polygon), no submerged base, no SP_NONE.
##   G-FT-LEDGER     — `total_bytes()` ≤ FAR_TREES_BYTES_MAX matches the real arithmetic; the facet LRU truncates
##                     to FAR_TREES_CACHE_FACETS; the card buffer/cap arithmetic == §6; a synthetic over-cap rebuild
##                     fills nearest-first and clamps `visible_instance_count` to FAR_TREES_CARD_INST_MAX.
##   G-FT-NOPROTRUDE — a rebuild with the camera ON a tree emits ZERO cards inside near_render_radius() (the near
##                     field owns that view); every enumerated base is radially sunk BELOW the true surface (BURY).
##   G-FT-SUNWELD    — `set_sun_dir` drives the material uniform; `make_material` seeds from `TierPlace.last_sun_dir`
##                     under FP_FAR_TERMINATOR_WELD (never (1,0,0) when a live Sun was noted), the shipped seed off.
##
## RUN (ON-path needs FACETED + FP_FAR_TREES + FP_FAR_TREES_CARDS sed-toggled true; FP_CLIMATE_BIOMES /
## FP_FAR_TERMINATOR_WELD optional — the gate self-describes):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_far_trees.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const FT := preload("res://src/world/facet_far_trees.gd")
const FA := preload("res://src/cosmos/facet_atlas.gd")

# The LIVE deploy flag fingerprint this gate models for its baseline pins — NOT CubeSphere.FP_* (repo-default
# false would silently void a pin). The ON assertions read CubeSphere.FP_FAR_TREES directly (sed-toggled).
const LIVE_FACETED := true
const LIVE_FAR_TREES := true
const LIVE_FAR_TREES_CARDS := true
const LIVE_FAR_TREES_MESH := true             # rung-1 archetype meshes ship ON (P1)
const LIVE_FAR_TREES_FADE := true             # dither cross-fades ship ON (P2)
const LIVE_FAR_TREES_SNOW := true             # snow-dusted variant ships ON (P3)
const LIVE_FAR_TREES_COLORFIX := true         # the mesh COLOR-slot fix ships ON (this change)
const LIVE_FAR_TREES_DELTA := true            # the rebuild-on-change gate ships ON (task #119)

var _pass := 0
var _fail := 0
## G-FTD edit-revision stub: the DELTA gate mutates this and hands the tier a Callable that returns it — a fresh chop
## bumps it, mirroring WorldManager.edit_count(). A method (not a captured local) so the lambda-capture-by-value trap
## ([[voxiverse-gdscript-closure-trap]]) can't freeze it.
var _fake_edits_rev := 0
func _fake_edit_count() -> int:
	return _fake_edits_rev

## G-NP fake module world: a hermetic stand-in for module_world's near-presence probes (skin_near_meshed +
## meshed_band_y) so the NearPresence tri-state logic is proven WITHOUT a live godot_voxel pool. `meshed` drives the
## is_area_meshed answer; `band` drives the live streamable vertical band.
class FakeWorld extends RefCounted:
	var meshed := false
	var band := Vector2(-64.0, 130.0)
	func skin_near_meshed(_fid: int, _box: AABB) -> bool: return meshed
	func meshed_band_y(_ly: float) -> Vector2: return band
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_far_trees (task #114 P0 — FP_FAR_TREES cards) ===")
	FA.warm_up()
	TerrainConfig.warm_up()   # warms TreeGen species ids too

	_gate_off()
	if CubeSphere.FACETED and CubeSphere.FP_FAR_TREES:
		_gate_placement()
		_gate_ledger()
		_gate_noprotrude()
		_gate_sunweld()
		# G-FT-FADE-OFF (two-state, runs in EVERY ON invocation): the dither DISCARD is spliced into the shaders IFF
		# FP_FAR_TREES_FADE — so with FADE off the card/mesh shaders are the merged P0/P1 strings verbatim (byte-
		# identical), and the P0/P1 gates below stay 28/28. The complement (present under FADE) is the P2 splice.
		_ok(FT.shader_code().contains("_ft_dither") == CubeSphere.FP_FAR_TREES_FADE
			and FT.mesh_shader_code().contains("_ft_dither") == CubeSphere.FP_FAR_TREES_FADE,
			"G-FT-FADE-OFF: shader dither present IFF FP_FAR_TREES_FADE (off ⇒ P0/P1 shaders byte-identical)")
		# G-FT-SNOW-OFF (two-state): the snow-tint splice is present in both shaders IFF FP_FAR_TREES_SNOW, so with
		# SNOW off the shaders (and record col field) are the merged P0/P1/P2 forms verbatim (byte-identical).
		_ok(FT.shader_code().contains("snow_tint") == CubeSphere.FP_FAR_TREES_SNOW
			and FT.mesh_shader_code().contains("snow_tint") == CubeSphere.FP_FAR_TREES_SNOW,
			"G-FT-SNOW-OFF: shader snow-tint present IFF FP_FAR_TREES_SNOW (off ⇒ P0/P1/P2 shaders byte-identical)")
		if CubeSphere.FP_FAR_TREES_SNOW:
			_gate_snow()
		else:
			print("  (P3 snow gates skipped — need FP_FAR_TREES_SNOW sed-toggled true)")
		if CubeSphere.FP_FAR_TREES_MESH:
			_gate_mesh()                                  # P1 assertions (bijection/ledger/handoff/noprotrude)
		else:
			print("  (P1 mesh gates skipped — need FP_FAR_TREES_MESH sed-toggled true)")
		if CubeSphere.FP_FAR_TREES_FADE:
			_gate_fade()                                  # P2 assertions (nopop/thin/chop/splice)
		else:
			print("  (P2 fade gates skipped — need FP_FAR_TREES_FADE sed-toggled true)")
		# G-FT-CFIX (colour-slot fix): two-state stride/use_colors, white-quad + custom-decode parity, snow-not-the-
		# cause regression pin, and the de-orbit hide latch. Runs in BOTH flag states (self-describes off vs on).
		_gate_cfix()
		_gate_cfix_fresh()
		if CubeSphere.FP_FAR_TREES_SNOW:
			_gate_cfix_snow()
		else:
			print("  (G-FT-CFIX-SNOW-WARM skipped — needs FP_FAR_TREES_SNOW sed-toggled true)")
		# G-FTD (FP_FAR_TREES_DELTA): the rebuild-on-change gate. Runs in BOTH flag states (self-describes off vs on).
		_gate_delta()
		# G-FTA (FP_FAR_TREES_ALIGN) + G-FTC (FP_FAR_TREES_NEARCULL) — the #120 weld + handoff cull. Two-state,
		# self-describing (off ⇒ shipped anchor/sink/no-cull; on ⇒ welded + probe-culled).
		_gate_align()
		_gate_cull()
		# G-FTF (FP_FT_FRAME_WELD, #131) — the owner-facet frame weld: anchor datum lift (altitude) + lattice-basis
		# orientation (rotation). Two-state, self-describing (off ⇒ shipped plane anchor + (t1,r,t2) basis).
		_gate_frame_anchor()   # G-FTF-1: anchor + datum
		_gate_frame_basis()    # G-FTF-2: instance basis bit-compare
		_gate_frame_fold()     # G-FTF-3: cross-fold position + rotation weld (+ shipped-yaw>30° bug pin)
		# G-XDC-1 (FP_FT_XFADE_COMPL, #120 residual P0-b): the 448 cross-dither complementary-coverage fix. Two-state
		# shader-string parity + a flag-independent CPU coverage sim that pins BOTH the fix (union 1.0) and the shipped
		# in-phase defect (union max(f) < 1) every run.
		_gate_xfade()
		# G-FTG (FP_FT_NEAR_GUARD, #132 defect-2): the bounded credit-independent double-render guard. Two-state,
		# self-describing (off ⇒ no metadata captured, guard inert, buffers byte-identical).
		_gate_guard()
		# G-FTM-COLOR (FP_FT_TEXMEAN_COLOR, #132 defect-3): far-tree leaf/trunk colour = texture-mean. Two-state.
		_gate_texmean()
		# G-FTS (FP_FT_STALE_REBUILD, #132 P1): the ≤0.5Hz staleness floor — credit-0 rebuild-while-moving. Two-state.
		_gate_stale()
	else:
		print("  (ON gates skipped — need FACETED + FP_FAR_TREES sed-toggled true)")

	# G-NP (NearPresence tri-state) — pure predicate logic, independent of the far-trees flags (shared #120/#121).
	_gate_np()

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---- helpers -------------------------------------------------------------------------------------------------------

## An independent walk of the trees a facet OWNS (the exact convex-quad interior), from the SAME TreeGen law the
## tier uses — the bijection oracle. Returns Array of the tree_info Dictionaries.
func _owned_trees(fid: int) -> Array:
	var ctx = TerrainConfig.GenCtx.new(0, fid) if CubeSphere.FACETED else null
	var dmin := FA.dom_min(fid)
	var dmax := FA.dom_max(fid)
	var g := TreeGen.G
	var out: Array = []
	for gx in range(floori(float(dmin.x) / float(g)), floori(float(dmax.x) / float(g)) + 1):
		for gz in range(floori(float(dmin.y) / float(g)), floori(float(dmax.y) / float(g)) + 1):
			var info := TreeGen.tree_info(gx, gz, ctx)
			if info.is_empty():
				continue
			var base: Vector3i = info["base"]
			if not FA.in_polygon(fid, base.x, base.z, 0.0):
				continue
			out.append(info)
	return out

## Sample Earth facets away from the cube-vertex singularities (mid-face) for stable in-polygon ownership.
func _sample_facets() -> Array:
	var k := FA.K
	var out: Array = []
	for face in range(6):
		out.append(face * k * k + (k / 2) * k + (k / 2))   # face centre facet
	return out

func _fake_ring() -> Node3D:
	var n := Node3D.new()
	get_root().add_child(n)
	return n

# ---- G-FT-OFF ------------------------------------------------------------------------------------------------------

func _gate_off() -> void:
	# The shipped default: both P0 flags false ⇒ FacetFarRing never constructs the tier (byte-off, proven fully by
	# the FLAT verify_feature 6042/0 run). Here we assert the DEFAULTS and that the enumeration refactor AGREES with
	# the untouched near path — a tree_info hit means a real trunk log sits at base+1 (block_at, byte-identical).
	_ok(CubeSphere.FP_FAR_TREES == false or CubeSphere.FP_FAR_TREES == true, "FP_FAR_TREES declared")   # existence pin
	if not CubeSphere.FACETED:
		print("  (G-FT-OFF near-agreement skipped — needs FACETED for GenCtx column resolution)")
		return
	var fid: int = _sample_facets()[0]
	var ctx = TerrainConfig.GenCtx.new(0, fid)
	var dmin := FA.dom_min(fid)
	var g := TreeGen.G
	var checked := 0
	var agree := 0
	var miss_agree := 0
	var misses := 0
	for gx in range(floori(float(dmin.x) / float(g)), floori(float(dmin.x) / float(g)) + 60):
		for gz in range(floori(float(dmin.y) / float(g)), floori(float(dmin.y) / float(g)) + 60):
			var info := TreeGen.tree_info(gx, gz, ctx)
			if info.is_empty():
				# a miss must mean NO trunk at that cell's would-be base column (has_tree false / submerged / SP_NONE)
				if not TreeGen.has_tree(gx, gz, ctx):
					misses += 1; miss_agree += 1
				continue
			checked += 1
			var base: Vector3i = info["base"]
			# tree_info hit ⟺ the untouched block_at places a solid (trunk log) at base+1 — near byte-identity witness.
			if TreeGen.block_at(base.x, base.y + 1, base.z, ctx) != BlockCatalog.AIR:
				agree += 1
	_ok(checked > 0, "G-FT-OFF: sampled tree_info hits (%d)" % checked)
	_ok(agree == checked, "G-FT-OFF: every tree_info hit has a near trunk at base+1 (%d/%d)" % [agree, checked])
	_ok(misses == 0 or miss_agree == misses, "G-FT-OFF: every has_tree-false cell yields empty tree_info")

# ---- G-FT-PLACEMENT ------------------------------------------------------------------------------------------------

func _gate_placement() -> void:
	var ring := _fake_ring()
	var tier = FT.new()
	tier.setup_instance(ring, _sample_facets()[0])
	var total := 0
	var bij_ok := true
	var species_ok := true
	var owner_ok := true
	for fid in _sample_facets():
		var expected := _owned_trees(fid)
		var recs: PackedFloat32Array = tier.enumerate_facet_sync(fid)
		var m := recs.size() / FT.REC_FLOATS
		if m != expected.size():
			bij_ok = false
		total += m
		# species multiset + every base owned + non-submerged + non-none
		var exp_cols := {}
		for info in expected:
			var sp := int(info["species"])
			if sp == TreeGen.SP_NONE:
				species_ok = false
			var base: Vector3i = info["base"]
			if not FA.in_polygon(fid, base.x, base.z, 0.0):
				owner_ok = false
			if base.y <= TerrainConfig.SEA_LEVEL:
				species_ok = false
			exp_cols[sp - 1] = int(exp_cols.get(sp - 1, 0)) + 1
		var got_cols := {}
		for i in range(m):
			var col := int(recs[i * FT.REC_FLOATS + 6]) & 7   # mask the P3 snow bit (bit 3) — species is the low 3 bits
			got_cols[col] = int(got_cols.get(col, 0)) + 1
		if got_cols != exp_cols:
			species_ok = false
	_ok(total > 0, "G-FT-PLACEMENT: enumerated trees across sample facets (%d)" % total)
	_ok(bij_ok, "G-FT-PLACEMENT: card count == owned-tree count on every facet (bijection)")
	_ok(species_ok, "G-FT-PLACEMENT: species multiset reproduces; no submerged/SP_NONE emitted")
	_ok(owner_ok, "G-FT-PLACEMENT: every owned base is in exactly one facet's polygon")
	ring.queue_free()

# ---- G-FT-LEDGER ---------------------------------------------------------------------------------------------------

func _gate_ledger() -> void:
	var ring := _fake_ring()
	var tier = FT.new()
	tier.setup_instance(ring, _sample_facets()[0])
	# Fill the cache with more facets than the LRU cap → assert it truncates.
	for fid in _sample_facets():
		tier.enumerate_facet_sync(fid)
	var b := tier.total_bytes()
	_ok(b <= CubeSphere.FAR_TREES_BYTES_MAX, "G-FT-LEDGER: total_bytes %d <= FAR_TREES_BYTES_MAX %d" % [b, CubeSphere.FAR_TREES_BYTES_MAX])
	# The real buffer arithmetic: cap × 16 floats × 4 B (== §6 ledger's 512 KB at cap 8192).
	var buf_b := CubeSphere.FAR_TREES_CARD_INST_MAX * FT.CARD_STRIDE * 4
	_ok(buf_b == 8192 * 16 * 4 or CubeSphere.FAR_TREES_CARD_INST_MAX != 8192, "G-FT-LEDGER: card-buffer bytes match §6 arithmetic")
	_ok(tier.cached_facets() <= CubeSphere.FAR_TREES_CACHE_FACETS, "G-FT-LEDGER: facet LRU <= FAR_TREES_CACHE_FACETS")
	# Cap enforcement: synthesise a huge cached list on one fid and rebuild with a wide camera → clamp to the cap.
	var big := PackedFloat32Array()
	var far_fid: int = _sample_facets()[0]
	var d := FA.cell_dir(far_fid, (FA.dom_min(far_fid).x + FA.dom_max(far_fid).x) / 2, (FA.dom_min(far_fid).y + FA.dom_max(far_fid).y) / 2)
	var cx := d.x * FA.R_BLOCKS; var cy := d.y * FA.R_BLOCKS; var cz := d.z * FA.R_BLOCKS
	var want := CubeSphere.FAR_TREES_CARD_INST_MAX + 500
	for i in range(want):
		# spread synthetic trees in a BOUNDED ±256-block patch around the facet centre so all sit inside the card
		# band [R0, CARD_MAX] once the camera is ~1500 blocks out — the point is to exceed the instance cap.
		var ox := cx + float(i % 64) * 8.0 - 256.0
		var oz := cz + float((i / 64) % 64) * 8.0 - 256.0
		var p := Vector3(ox, cy, oz)
		var r := p.normalized()
		big.push_back(p.x); big.push_back(p.y); big.push_back(p.z)
		big.push_back(r.x); big.push_back(r.y); big.push_back(r.z)
		big.push_back(0.0); big.push_back(5.0)                       # species col 0, trunk_h 5 + hue 0 (survives thinning)
		big.push_back(0.0); big.push_back(0.0); big.push_back(0.0)   # lattice base (synthetic — no real cell / chop)
	tier.debug_set_cache(far_fid, big)
	# camera far above so nearly all synthetic trees are in [R0, CARD_MAX]
	var cam := Vector3(cx, cy, cz) + Vector3(cx, cy, cz).normalized() * 1500.0
	var vis := tier.debug_rebuild([far_fid], cam)
	_ok(vis <= CubeSphere.FAR_TREES_CARD_INST_MAX, "G-FT-LEDGER: visible instances %d clamped to cap %d" % [vis, CubeSphere.FAR_TREES_CARD_INST_MAX])
	_ok(tier.was_capped(), "G-FT-LEDGER: over-cap rebuild flags capped (nearest-first fill)")
	ring.queue_free()

# ---- G-FT-NOPROTRUDE -----------------------------------------------------------------------------------------------

func _gate_noprotrude() -> void:
	var ring := _fake_ring()
	var tier = FT.new()
	var fid: int = _sample_facets()[0]
	tier.setup_instance(ring, fid)
	var recs: PackedFloat32Array = tier.enumerate_facet_sync(fid)
	var m := recs.size() / FT.REC_FLOATS
	_ok(m > 0, "G-FT-NOPROTRUDE: facet has enumerable trees (%d)" % m)
	# G-FT-MESH-HANDOFF (b) — the card-band inner radius, asserted in BOTH flag states (this gate runs whenever
	# FP_FAR_TREES): MESH on ⇒ cards retreat to FAR_TREES_MESH_MAX (448, exclusive handoff); MESH off ⇒ the P0
	# floor near_render_radius() (128), so the merged [128, CARD_MAX] card band is BYTE-IDENTICAL with meshes off.
	var expect_floor := CubeSphere.FAR_TREES_MESH_MAX if CubeSphere.FP_FAR_TREES_MESH else float(TerrainConfig.near_render_radius())
	_ok(is_equal_approx(tier.card_inner_radius(), expect_floor),
		"G-FT-MESH-HANDOFF(b): card inner radius %.0f == %.0f (retracts to 448 ONLY under MESH; else 128, P0-unchanged)" % [tier.card_inner_radius(), expect_floor])
	# Every base is radially sunk BELOW the true surface world position (the BURY law → never rides a protruding tier).
	var sink_ok := true
	for i in range(m):
		var o := i * FT.REC_FLOATS
		var s := Vector3(recs[o + 0], recs[o + 1], recs[o + 2])
		var r := Vector3(recs[o + 3], recs[o + 4], recs[o + 5])
		# sunk = world - r*BURY ⇒ |sunk| < the un-sunk radius; the base sits inside the true surface radius.
		if s.dot(r) <= 0.0:
			sink_ok = false
	_ok(sink_ok, "G-FT-NOPROTRUDE: every card base is radially inward (BURY sink applied)")
	# Put the camera ON the nearest tree → assert NO card is emitted within near_render_radius() of it.
	if m > 0:
		var cam := Vector3(recs[0], recs[1], recs[2])
		var vis := tier.debug_rebuild([fid], cam)
		var r0 := float(TerrainConfig.near_render_radius())
		var buf: PackedFloat32Array = tier.debug_buffer()
		var protrude := 0
		for i in range(vis):
			var b := i * FT.CARD_STRIDE
			var o := Vector3(buf[b + 3], buf[b + 7], buf[b + 11])   # instance transform origin (row-major x,y,z)
			if o.distance_to(cam) < r0:
				protrude += 1
		_ok(protrude == 0, "G-FT-NOPROTRUDE: 0 cards inside near_render_radius (%.0f) of the camera (had %d)" % [r0, vis])
	ring.queue_free()

# ---- G-FT-SUNWELD --------------------------------------------------------------------------------------------------

func _gate_sunweld() -> void:
	var ring := _fake_ring()
	var tier = FT.new()
	tier.setup_instance(ring, _sample_facets()[0])
	var live := Vector3(0.3, 0.8, 0.5).normalized()
	tier.set_sun_dir(live)
	_ok(tier.sun_dir_telemetry().is_equal_approx(live), "G-FT-SUNWELD: set_sun_dir drives the material uniform")
	# make_material seed: welded from the last live Sun (never (1,0,0)) under FP_FAR_TERMINATOR_WELD; shipped seed off.
	TierPlace.note_sun_dir(live)
	var m2 := FT.make_material()
	var seed: Vector3 = m2.get_shader_parameter("sun_dir")
	if CubeSphere.FP_FAR_TERMINATOR_WELD:
		_ok(seed.is_equal_approx(live), "G-FT-SUNWELD: welded material seeds from TierPlace.last_sun_dir (not (1,0,0))")
	else:
		_ok(seed.is_equal_approx(Vector3(1.0, 0.0, 0.0)), "G-FT-SUNWELD: weld off ⇒ shipped (1,0,0) seed (byte-identical)")
	ring.queue_free()

# ---- G-FT-MESH (P1) ------------------------------------------------------------------------------------------------

func _gate_mesh() -> void:
	var ring := _fake_ring()
	var tier = FT.new()
	var fid: int = _sample_facets()[0]
	tier.setup_instance(ring, fid)
	var r0 := float(TerrainConfig.near_render_radius())
	var d1 := CubeSphere.FAR_TREES_MESH_MAX

	# --- G-FT-MESH-LEDGER: 6 archetype meshes exist, bounded tris, ≤6 draws, total_bytes under cap ---
	var tri_ok := true
	for col in range(6):
		var tc := tier.mesh_tri_count(col)
		if tc <= 0 or tc > 1400:               # ~180 ideal; exposed-face cubes → allow headroom, but bounded
			tri_ok = false
	_ok(tri_ok, "G-FT-MESH-LEDGER: every species archetype mesh has bounded tris (1..1400)")
	var b := tier.total_bytes()
	_ok(b <= CubeSphere.FAR_TREES_BYTES_MAX, "G-FT-MESH-LEDGER: total_bytes %d <= FAR_TREES_BYTES_MAX %d" % [b, CubeSphere.FAR_TREES_BYTES_MAX])

	# --- Build a controlled radial spread of synthetic trees so distances span both bands, then rebuild both ---
	var d := FA.cell_dir(fid, (FA.dom_min(fid).x + FA.dom_max(fid).x) / 2, (FA.dom_min(fid).y + FA.dom_max(fid).y) / 2)
	var centre := Vector3(d.x, d.y, d.z) * FA.R_BLOCKS
	var radial := centre.normalized()
	var up := Vector3(0, 1, 0)
	if absf(radial.dot(up)) > 0.99:
		up = Vector3(1, 0, 0)
	var tangent := radial.cross(up).normalized()
	var synth := PackedFloat32Array()
	var dists := []
	var step := 100
	while step <= 2575:
		var p := centre + tangent * float(step)
		var r := p.normalized()
		synth.push_back(p.x); synth.push_back(p.y); synth.push_back(p.z)
		synth.push_back(r.x); synth.push_back(r.y); synth.push_back(r.z)
		synth.push_back(float((step / 25) % 6))     # cycle species column 0..5
		synth.push_back(5.0)                         # trunk_h=5, hue=0
		synth.push_back(0.0); synth.push_back(0.0); synth.push_back(0.0)   # lattice base (synthetic)
		dists.append(step)
		step += 25
	tier.debug_set_cache(fid, synth)
	var cam := centre                                # camera on the surface at facet centre → dist(cam,p)=step
	tier.debug_rebuild([fid], cam)
	var mesh_live: int = tier.mesh_live_instances()
	var card_live: int = tier.live_instances()
	_ok(tier.mesh_draw_count() <= 6, "G-FT-MESH-LEDGER: mesh draws %d <= 6" % tier.mesh_draw_count())
	if CubeSphere.FP_FAR_TREES_FADE:
		# Under FADE the 448 handoff is a CONTROLLED OVERLAP (cross-dither), not a hard partition — both rungs render
		# in [448±32]. The strict partition/continuity is proven in _gate_fade; here just confirm both bands populate.
		_ok(mesh_live > 0 and card_live > 0, "G-FT-MESH(fade): both rungs populate under the dither overlap (mesh %d, card %d)" % [mesh_live, card_live])
		ring.queue_free()
		return
	var exp_mesh := 0
	var exp_card := 0
	for dd in dists:
		if dd >= r0 and dd < d1: exp_mesh += 1
		elif dd >= d1 and dd <= CubeSphere.FAR_TREES_CARD_MAX: exp_card += 1
	_ok(mesh_live == exp_mesh, "G-FT-MESH-BIJECTION: mesh band [%0.f,%0.f) count %d == expected %d" % [r0, d1, mesh_live, exp_mesh])
	_ok(card_live == exp_card, "G-FT-MESH-HANDOFF: card band [%0.f,CARD] count %d == expected %d (cards retreated)" % [d1, card_live, exp_card])
	_ok(mesh_live + card_live == exp_mesh + exp_card and exp_mesh > 0 and exp_card > 0, "G-FT-MESH-HANDOFF: bands PARTITION the [R0,CARD] set (no double, no gap)")

	# --- Every mesh instance origin is inside the mesh band; every card origin at/beyond the 448 handoff ---
	var mesh_in_band := true
	for col in range(6):
		var buf: PackedFloat32Array = tier.mesh_buffer(col)
		var vis := tier.mesh_visible(col)
		for i in range(vis):
			var o := i * FT.MESH_STRIDE
			var org := Vector3(buf[o + 3], buf[o + 7], buf[o + 11])
			var dist := org.distance_to(cam)
			if dist < r0 or dist >= d1:
				mesh_in_band = false
	_ok(mesh_in_band, "G-FT-MESH-HANDOFF: every mesh instance origin is within [R0, MESH_MAX) (exclusive 448 handoff)")
	var cbuf: PackedFloat32Array = tier.debug_buffer()
	var card_beyond := true
	for i in range(card_live):
		var o := i * FT.CARD_STRIDE
		var org := Vector3(cbuf[o + 3], cbuf[o + 7], cbuf[o + 11])
		if org.distance_to(cam) < d1:
			card_beyond = false
	_ok(card_beyond, "G-FT-MESH-HANDOFF: every card instance origin is >= MESH_MAX (no tree in both bands)")

	# --- G-FT-MESH-NOPROTRUDE: camera ON a real tree ⇒ 0 mesh instances inside near_render_radius ---
	var recs: PackedFloat32Array = tier.enumerate_facet_sync(fid)
	if recs.size() >= FT.REC_FLOATS:
		var cam2 := Vector3(recs[0], recs[1], recs[2])
		tier.debug_rebuild([fid], cam2)
		var protrude := 0
		for col in range(6):
			var buf2: PackedFloat32Array = tier.mesh_buffer(col)
			var vis2 := tier.mesh_visible(col)
			for i in range(vis2):
				var o := i * FT.mesh_stride()   # stride 20 under FP_FAR_TREES_COLORFIX, else 16
				var org := Vector3(buf2[o + 3], buf2[o + 7], buf2[o + 11])
				if org.distance_to(cam2) < r0:
					protrude += 1
		_ok(protrude == 0, "G-FT-MESH-NOPROTRUDE: 0 mesh instances inside near_render_radius (%.0f) of the camera" % r0)
	ring.queue_free()

# ---- G-FT-FADE (P2) ------------------------------------------------------------------------------------------------

func _gate_fade() -> void:
	var r0 := float(TerrainConfig.near_render_radius())
	var d1 := CubeSphere.FAR_TREES_MESH_MAX
	var w := FT.FADE_BAND_W

	# G-FT-FADE-SPLICE: the dither DISCARD is present in both shaders under FADE (byte-identity when OFF is proven by
	# the separate FADE-off gate run — P1 28/28 — where the same shader_code() returns the merged string).
	_ok(FT.shader_code().contains("_ft_dither") and FT.mesh_shader_code().contains("_ft_dither"),
		"G-FT-FADE-SPLICE: card + mesh shaders carry the per-pixel dither under FP_FAR_TREES_FADE")

	# G-FT-FADE-NOPOP — the 448 cross-dither: mesh alpha 1→0, card alpha 0→1, SUM ≈ 1 across [448±W] (no gap/double);
	# alpha is continuous (no hard visibility flip); rung-1 dithers IN over [R0, R0+near] (no pop at the 128 handoff).
	var sum_ok := true
	var cont_ok := true
	var prev := FT.mesh_fade(d1 - w - 6.0)
	var k := 0
	while k <= 130:
		var dd := d1 - w - 6.0 + float(k)
		var mf: float = FT.mesh_fade(dd)
		var cf: float = FT.card_fade(dd, 0.0)
		if dd >= d1 - w and dd <= d1 + w:
			if absf(mf + cf - 1.0) > 0.05:
				sum_ok = false
		if absf(mf - prev) > 0.2:
			cont_ok = false
		prev = mf
		k += 2
	_ok(sum_ok, "G-FT-FADE-NOPOP: mesh+card cross-fade sums to ~1 across the 448 overlap (no gap, no double-bright)")
	_ok(cont_ok, "G-FT-FADE-NOPOP: mesh alpha continuous across the boundary (no hard visibility flip)")
	_ok(FT.mesh_fade(r0 + 1.0) < 0.25 and FT.mesh_fade(r0 + FT.FADE_NEAR_W + 6.0) > 0.9,
		"G-FT-FADE-NOPOP: rung-1 dithers IN over [R0, R0+near] (no pop at 128)")

	# G-FT-FADE-THIN — keep(d) deterministic + monotone; high-survival-hash trees retire FIRST; the far set is thinned.
	var mono := true
	var pk := FT.keep_frac(FT.THIN_START)
	for i in range(0, 61):
		var dd := FT.THIN_START + float(i) * 20.0
		var kv: float = FT.keep_frac(dd)
		if kv > pk + 1.0e-6:
			mono = false
		pk = kv
	_ok(mono, "G-FT-FADE-THIN: keep(d) is monotone non-increasing")
	_ok(FT.keep_frac(600.0) == 1.0 and FT.keep_frac(CubeSphere.FAR_TREES_CARD_MAX) <= FT.THIN_MIN + 1.0e-6,
		"G-FT-FADE-THIN: keep ramps 1.0 (near) → THIN_MIN (fog line)")
	var d_hi := -1.0
	var d_lo := -1.0
	for i in range(0, 140):
		var dd := FT.THIN_START + float(i) * 10.0
		if d_hi < 0.0 and FT.thin_alpha(0.9, dd) <= 0.01:
			d_hi = dd
		if d_lo < 0.0 and FT.thin_alpha(0.2, dd) <= 0.01:
			d_lo = dd
	_ok(d_hi > 0.0 and (d_lo < 0.0 or d_hi < d_lo), "G-FT-FADE-THIN: high-survival-hash trees retire FIRST (stable geomorph)")

	# Count reduction: N synthetic trees at a fixed far distance, hue spread 0..1 → thinned deterministically below N.
	var ring := _fake_ring()
	var tier = FT.new()
	var fid: int = _sample_facets()[0]
	tier.setup_instance(ring, fid)
	var d := FA.cell_dir(fid, (FA.dom_min(fid).x + FA.dom_max(fid).x) / 2, (FA.dom_min(fid).y + FA.dom_max(fid).y) / 2)
	var centre := Vector3(d.x, d.y, d.z) * FA.R_BLOCKS
	var radial := centre.normalized()
	var up := Vector3(0, 1, 0)
	if absf(radial.dot(up)) > 0.99:
		up = Vector3(1, 0, 0)
	var tangent := radial.cross(up).normalized()
	var syn := PackedFloat32Array()
	var nn := 200
	for i in range(nn):
		var p := centre + tangent * 2100.0
		var r := p.normalized()
		syn.push_back(p.x); syn.push_back(p.y); syn.push_back(p.z)
		syn.push_back(r.x); syn.push_back(r.y); syn.push_back(r.z)
		syn.push_back(0.0); syn.push_back(5.0 + float(i) / float(nn))   # hue spread 0..1
		syn.push_back(0.0); syn.push_back(0.0); syn.push_back(0.0)
	tier.debug_set_cache(fid, syn)
	tier.debug_rebuild([fid], centre)
	var thinned: int = tier.live_instances()
	tier.debug_rebuild([fid], centre)
	_ok(thinned > 0 and thinned < nn, "G-FT-FADE-THIN: hash-survival thins the far card set (%d of %d survive at d=2100)" % [thinned, nn])
	_ok(tier.live_instances() == thinned, "G-FT-FADE-THIN: thinning is deterministic (same survivors across rebuilds)")

	# G-FT-FADE-CHOP — a chopped tree (its trunk-base cell flagged by the chop query) is absent from the far set.
	var recs: PackedFloat32Array = tier.enumerate_facet_sync(fid)   # re-enumerate real trees (overwrites the synth cache)
	tier.set_chop_query(func(_f, _c): return false)
	tier.debug_rebuild([fid], centre)
	var c_none: int = tier.live_instances() + tier.mesh_live_instances()
	tier.set_chop_query(func(_f, _c): return true)
	tier.debug_rebuild([fid], centre)
	var c_all: int = tier.live_instances() + tier.mesh_live_instances()
	_ok(c_none > 0 and c_all == 0, "G-FT-FADE-CHOP: chopping every tree removes all far instances (%d → 0)" % c_none)
	var m := recs.size() / FT.REC_FLOATS
	var target := Vector3i(0, 0, 0)
	var found := false
	for i in range(m):
		var o := i * FT.REC_FLOATS
		var s := Vector3(recs[o], recs[o + 1], recs[o + 2])
		var dd := s.distance_to(centre)
		if dd >= r0 and dd <= CubeSphere.FAR_TREES_CARD_MAX:
			target = Vector3i(int(recs[o + 8]), int(recs[o + 9]) + 1, int(recs[o + 10]))
			found = true
			break
	tier.set_chop_query(func(_f, c): return c == target)
	tier.debug_rebuild([fid], centre)
	var c_one: int = tier.live_instances() + tier.mesh_live_instances()
	_ok((not found) or c_one < c_none, "G-FT-FADE-CHOP: chopping ONE tree removes exactly that far instance (%d → %d)" % [c_none, c_one])
	tier.set_chop_query(Callable())
	ring.queue_free()

# ---- G-FT-SNOW (P3) ------------------------------------------------------------------------------------------------

func _gate_snow() -> void:
	var ring := _fake_ring()
	var tier = FT.new()
	tier.setup_instance(ring, _sample_facets()[0])
	var k := FA.K
	# Scan a spread across all 6 faces (incl. the polar faces) to catch BOTH cold (snow) + warm columns.
	var scan: Array = []
	for face in range(6):
		for a in [k / 4, k / 2, 3 * k / 4]:
			for b in [k / 4, k / 2, 3 * k / 4]:
				scan.append(face * k * k + a * k + b)
	var eq_ok := true
	var snow_found := 0
	var bare_found := 0
	for fid in scan:
		var ctx = TerrainConfig.GenCtx.new(0, int(fid))
		var recs: PackedFloat32Array = tier.enumerate_facet_sync(int(fid))
		var m := recs.size() / FT.REC_FLOATS
		for i in range(m):
			var o := i * FT.REC_FLOATS
			var snow_flag := (int(recs[o + 6]) & 8) != 0
			var bx := int(recs[o + 8]); var gy := int(recs[o + 9]); var bz := int(recs[o + 10])
			# The independent FarPalette snow-line predicate (the SAME columns the near/far skin snow-caps).
			var t_col: float = TerrainConfig.column_profile(bx, bz, ctx).w
			var pred := gy >= TerrainConfig.SEA_LEVEL and ClimateModel.surface_temperature(gy, t_col) < 0.0
			if snow_flag != pred:
				eq_ok = false
			if snow_flag: snow_found += 1
			else: bare_found += 1
	_ok(eq_ok, "G-FT-SNOW-FIRES: snow flag == FarPalette snow-line predicate for EVERY far tree (same columns as near)")
	_ok(snow_found > 0, "G-FT-SNOW-FIRES: cold-column far trees ARE snow-dusted (%d found)" % snow_found)
	_ok(bare_found > 0, "G-FT-SNOW-FIRES: warm-column far trees are NOT snow-dusted (%d found)" % bare_found)
	# G-FT-SNOW-LEDGER: the snow variant is a per-instance shader lerp (no snow atlas region) → ~0 added resident
	# bytes; total_bytes stays under the 4 MB ledger.
	var b := tier.total_bytes()
	_ok(b <= CubeSphere.FAR_TREES_BYTES_MAX, "G-FT-SNOW-LEDGER: total_bytes %d <= FAR_TREES_BYTES_MAX %d (snow adds ~0 — shader lerp, no atlas region)" % [b, CubeSphere.FAR_TREES_BYTES_MAX])
	ring.queue_free()

# ---- G-FT-CFIX (FP_FAR_TREES_COLORFIX — the mesh COLOR-slot fix) ----------------------------------------------------

## G-FT-CFIX-OFF / -WHITE. Two-state, self-describing: mesh_stride()/use_colors track the flag; OFF ⇒ 16-float stride
## + use_colors false (byte-identical shipped layout), ON ⇒ 20-float stride + use_colors true with an explicit WHITE
## (1,1,1,1) instance color at [12..15] and the custom quad shifted to [16..19] — proving both that the colour slot is
## an identity multiplier (kills the gl_compat repack-garbage aliasing) AND that the CUSTOM decode
## (delta/hue+2snow/arch/fade the shader's trunk-stretch reads) is intact at its shifted offset (decode parity).
func _gate_cfix() -> void:
	var cfix := CubeSphere.FP_FAR_TREES_COLORFIX
	var want_stride := 20 if cfix else 16
	_ok(FT.mesh_stride() == want_stride,
		"G-FT-CFIX-%s: mesh_stride() == %d (12 xform %s 4 custom)" % ["ON" if cfix else "OFF", want_stride, "+ 4 COLOR +" if cfix else "+"])
	if not CubeSphere.FP_FAR_TREES_MESH:
		print("  (G-FT-CFIX buffer gates skipped — need FP_FAR_TREES_MESH sed-toggled true)")
		return
	var ring := _fake_ring()
	var tier = FT.new()
	var fid: int = _sample_facets()[0]
	tier.setup_instance(ring, fid)
	# The live mesh MultiMesh use_colors flag tracks FP_FAR_TREES_COLORFIX exactly (the root-cause: use_colors=false +
	# a COLOR-reading shader is the aliasing bug; the fix is enabling it so the engine packs the slot properly).
	_ok(tier.mesh_uses_colors() == cfix, "G-FT-CFIX-%s: mesh MultiMesh.use_colors == %s" % ["ON" if cfix else "OFF", str(cfix)])
	# Controlled radial spread INSIDE the mesh band [R0, MESH_MAX) so every species buffer has live instances.
	var d := FA.cell_dir(fid, (FA.dom_min(fid).x + FA.dom_max(fid).x) / 2, (FA.dom_min(fid).y + FA.dom_max(fid).y) / 2)
	var centre := Vector3(d.x, d.y, d.z) * FA.R_BLOCKS
	var radial := centre.normalized()
	var up := Vector3(0, 1, 0)
	if absf(radial.dot(up)) > 0.99: up = Vector3(1, 0, 0)
	var tangent := radial.cross(up).normalized()
	var r0 := float(TerrainConfig.near_render_radius())
	var synth := PackedFloat32Array()
	var stepd := int(r0) + 20
	while stepd < int(CubeSphere.FAR_TREES_MESH_MAX) - 40:
		var p := centre + tangent * float(stepd)
		var r := p.normalized()
		synth.push_back(p.x); synth.push_back(p.y); synth.push_back(p.z)
		synth.push_back(r.x); synth.push_back(r.y); synth.push_back(r.z)
		synth.push_back(float((stepd / 20) % 6))     # species col 0..5 (snow bit 3 unset)
		synth.push_back(5.0)                          # trunk_h 5, hue 0
		synth.push_back(0.0); synth.push_back(0.0); synth.push_back(0.0)   # lattice base (synthetic)
		stepd += 20
	tier.debug_set_cache(fid, synth)
	tier.debug_rebuild([fid], centre)
	var stride: int = FT.mesh_stride()
	var white_ok := true
	var custom_ok := true
	var any := 0
	for col in range(6):
		var buf: PackedFloat32Array = tier.mesh_buffer(col)
		var vis := tier.mesh_visible(col)
		var arch := tier.mesh_arch_trunk(col)
		var exp_delta := 5.0 - arch                    # delta = trunk_h(5) − arch  (the shader's trunk-stretch source)
		for i in range(vis):
			any += 1
			var base := i * stride
			if cfix:
				# COLOR slot [12..15] is an explicit identity white — the whole fix (no repack garbage the ungated
				# `COLOR *= instance_color` would multiply into albedo).
				if not (is_equal_approx(buf[base + 12], 1.0) and is_equal_approx(buf[base + 13], 1.0)
						and is_equal_approx(buf[base + 14], 1.0) and is_equal_approx(buf[base + 15], 1.0)):
					white_ok = false
			# CUSTOM decode parity: custom is at [12..15] OFF / [16..19] ON, and STILL carries (delta, hue+2·snow,
			# arch, fade). trunk_h 5, hue 0, snow 0 ⇒ (5−arch, 0, arch, *). The colour add did NOT corrupt custom.
			var co := base + (16 if cfix else 12)
			if not (is_equal_approx(buf[co + 0], exp_delta) and is_equal_approx(buf[co + 1], 0.0)
					and is_equal_approx(buf[co + 2], arch)):
				custom_ok = false
	_ok(any > 0, "G-FT-CFIX: mesh band populated for the decode-parity scan (%d instances)" % any)
	if cfix:
		_ok(white_ok, "G-FT-CFIX-WHITE: every live mesh instance COLOR slot == (1,1,1,1) identity")
	_ok(custom_ok, "G-FT-CFIX-WHITE: CUSTOM (delta,hue+2snow,arch) intact at %s (decode parity — colour add didn't corrupt it)"
		% ("[16..19]" if cfix else "[12..15]"))
	ring.queue_free()

## G-FT-CFIX-SNOW-WARM (refuted-lead regression pin, needs FP_FAR_TREES_SNOW): snow packs into custom.y (= hue+2·snow)
## and is decided by the FarPalette snow-line predicate — NOT the colour aliasing. Warm facet 1754 (design §1) ⇒ every
## record snow=0 and packed custom.y < 1.5; a cold facet ⇒ ≥1 record snow=1 (packed y ≥ 2.0). Confirms snow is correct
## and stays correct under COLORFIX (the packing is unchanged; only the slot's byte offset moved).
func _gate_cfix_snow() -> void:
	var ring := _fake_ring()
	var tier = FT.new()
	tier.setup_instance(ring, _sample_facets()[0])
	var earth_n := 6 * FA.K * FA.K
	var warm_checked := 0
	var warm_all_bare := true
	if 1754 < earth_n:
		var recs: PackedFloat32Array = tier.enumerate_facet_sync(1754)
		var m := recs.size() / FT.REC_FLOATS
		for i in range(m):
			var o := i * FT.REC_FLOATS
			var snow_bit := (int(recs[o + 6]) & 8) != 0
			var packed_y := (recs[o + 7] - floorf(recs[o + 7])) + (2.0 if snow_bit else 0.0)   # the mesh custom.y pack
			if snow_bit or packed_y >= 1.5:
				warm_all_bare = false
			warm_checked += 1
	_ok(warm_checked == 0 or warm_all_bare,
		"G-FT-CFIX-SNOW-WARM: warm facet 1754 — every far tree snow=0, custom.y<1.5 (%d recs)" % warm_checked)
	# Cold pin: scan the faces (incl. poles) for a facet that yields a snow-dusted far tree (bit 1, custom.y ≥ 2.0).
	var k := FA.K
	var cold_found := false
	for face in range(6):
		if cold_found: break
		for a in [k / 4, k / 2, 3 * k / 4]:
			if cold_found: break
			for bb in [k / 4, k / 2, 3 * k / 4]:
				var fid: int = face * k * k + a * k + bb
				var recs2: PackedFloat32Array = tier.enumerate_facet_sync(int(fid))
				var m2 := recs2.size() / FT.REC_FLOATS
				for i in range(m2):
					if (int(recs2[i * FT.REC_FLOATS + 6]) & 8) != 0:
						cold_found = true
						break
				if cold_found: break
	_ok(cold_found, "G-FT-CFIX-SNOW-WARM: a cold facet yields ≥1 snow far tree (custom.y ≥ 2.0) — snow correct, not the cause")
	ring.queue_free()

## G-FT-CFIX-FRESH (§4.2 de-orbit hide latch). OFF ⇒ visibility is EXACTLY `not offsurf` (byte-identical). ON ⇒ after
## an offsurf→onsurf flip the tier stays invisible until the first completed rebuild clears the latch (correct-or-
## nothing, no stale pre-orbit band frame). Driven via the visibility/rebuild test hooks (no live FacetFarRing).
func _gate_cfix_fresh() -> void:
	var cfix := CubeSphere.FP_FAR_TREES_COLORFIX
	var ring := _fake_ring()
	var tier = FT.new()
	var fid: int = _sample_facets()[0]
	tier.setup_instance(ring, fid)
	tier.debug_apply_visibility(true)      # off-surface: hidden (both states); latches _stale under the flag
	var hid_off := not tier.mmi_visible()
	tier.debug_apply_visibility(false)     # back on-surface, BEFORE any rebuild
	if cfix:
		_ok(hid_off and not tier.mmi_visible(),
			"G-FT-CFIX-FRESH: tier stays invisible after offsurf→onsurf until the first rebuild (no stale-band frame)")
		tier.enumerate_facet_sync(fid)
		tier.debug_rebuild([fid], Vector3.ZERO)   # first completed rebuild clears the latch
		tier.debug_apply_visibility(false)
		_ok(tier.mmi_visible() and not tier.is_stale(),
			"G-FT-CFIX-FRESH: visible again after the first completed rebuild (latch cleared)")
	else:
		_ok(hid_off and tier.mmi_visible(),
			"G-FT-CFIX-FRESH(off): visibility == not offsurf, no stale latch (byte-identical)")
	ring.queue_free()

# ---- G-FTD (FP_FAR_TREES_DELTA — rebuild-on-change) -----------------------------------------------------------------

## docs/COSMOS-FOREST-FPS-DESIGN.md §5 (task #119). Two-state, self-describing. OFF ⇒ every step rebuilds (shipped
## behaviour): rebuild count == step count (G-FTD-5). ON ⇒ a static-camera step SKIPS the rebuild and the skipped
## buffer is BIT-IDENTICAL to a forced rebuild (G-FTD-1), and the rebuild RE-ARMS on camera motion ≥ FT_DELTA_MIN_MOVE
## (G-FTD-2), an edit-revision change / chop (G-FTD-3), and a record-cache epoch bump (G-FTD-4). Driven via the DELTA
## test hook `debug_step` (mirrors step()'s post-rate-cap tail; no live FacetFarRing / no worker).
func _gate_delta() -> void:
	if not CubeSphere.FP_FAR_TREES_CARDS:
		print("  (G-FTD skipped — needs FP_FAR_TREES_CARDS sed-toggled true, the rebuild proxy)")
		return
	var delta := CubeSphere.FP_FAR_TREES_DELTA
	var ring := _fake_ring()
	var tier = FT.new()
	var fid: int = _sample_facets()[0]
	tier.setup_instance(ring, fid)
	tier.set_edits_rev_query(Callable(self, "_fake_edit_count"))
	_fake_edits_rev = 0
	# Warm the cache with the facet's real trees (bumps the DELTA epoch); camera on the facet surface centre so a
	# healthy slice of trees falls inside the card band [R0, CARD_MAX] (near field owns < R0).
	tier.enumerate_facet_sync(fid)
	var d := FA.cell_dir(fid, (FA.dom_min(fid).x + FA.dom_max(fid).x) / 2, (FA.dom_min(fid).y + FA.dom_max(fid).y) / 2)
	var cam := Vector3(d.x, d.y, d.z) * FA.R_BLOCKS
	var wanted := [fid]

	if not delta:
		# G-FTD-5 (flag off): every step rebuilds — the shipped unconditional behaviour (byte-identical hot path).
		var c0 := tier.rebuild_count()
		var r1 := tier.debug_step(wanted, cam)
		var r2 := tier.debug_step(wanted, cam)
		var r3 := tier.debug_step(wanted, cam)
		_ok(r1 and r2 and r3 and tier.rebuild_count() - c0 == 3,
			"G-FTD-5: DELTA off ⇒ every step rebuilds (3 steps → %d rebuilds), shipped behaviour" % (tier.rebuild_count() - c0))
		ring.queue_free()
		return

	# --- flag ON ---
	# G-FTD-1: first step rebuilds; a second identical step SKIPS; the skipped buffer is bit-identical to a forced rebuild.
	var c0 := tier.rebuild_count()
	var did1 := tier.debug_step(wanted, cam)          # first-ever rebuild
	var buf1 := tier.debug_buffer()                    # COW snapshot of the rebuilt card buffer
	var did2 := tier.debug_step(wanted, cam)          # nothing changed → SKIP
	_ok(did1 and not did2 and tier.rebuild_count() - c0 == 1,
		"G-FTD-1: static camera ⇒ 2nd step skips the rebuild (1 rebuild for 2 steps)")
	tier.debug_rebuild(wanted, cam)                    # force a rebuild (bypasses the gate) with the SAME inputs
	var buf3 := tier.debug_buffer()
	_ok(buf1 == buf3, "G-FTD-1: skipped-frame card buffer BIT-IDENTICAL to a forced rebuild (%d floats) — skip is pixel-safe" % buf1.size())

	# G-FTD-2: camera moved ≥ the effective move threshold ⇒ the next step rebuilds; then static again ⇒ skips.
	# FP_FT_MOVE_HYST (F2a, #129): the threshold is FT_DELTA_MOVE_HYST (12) under the flag, else FT_DELTA_MIN_MOVE (2).
	var _move_thr: float = CubeSphere.FT_DELTA_MOVE_HYST if CubeSphere.FP_FT_MOVE_HYST else CubeSphere.FT_DELTA_MIN_MOVE
	# G-FT-MOVEHYST: a move BELOW the threshold must NOT re-arm (proves the hysteresis widened), one AT/ABOVE must.
	var cam_sub := cam + Vector3(_move_thr - 1.0, 0.0, 0.0)   # under the threshold
	var cS := tier.rebuild_count()
	var did_sub := tier.debug_step(wanted, cam_sub)
	_ok(not did_sub and tier.rebuild_count() == cS,
		"G-FT-MOVEHYST: a %0.f-blk move (< %0.f threshold) does NOT re-arm the rebuild (%s)" % [_move_thr - 1.0, _move_thr, "hyst on" if CubeSphere.FP_FT_MOVE_HYST else "shipped"])
	var cam2 := cam + Vector3(_move_thr + 1.0, 0.0, 0.0)          # over the effective threshold
	var cA := tier.rebuild_count()
	var didm := tier.debug_step(wanted, cam2)
	var didm2 := tier.debug_step(wanted, cam2)
	_ok(didm and not didm2 and tier.rebuild_count() - cA == 1,
		"G-FTD-2: camera moved ≥%.1f blk (effective) ⇒ rebuild re-arms once, then static ⇒ skips" % _move_thr)

	# G-FTD-4: a record-cache epoch bump (a facet landed / was evicted) ⇒ the next step rebuilds.
	tier.debug_step(wanted, cam2)                      # ensure latched (static skip)
	var cC := tier.rebuild_count()
	tier.debug_set_cache(fid + 100000, PackedFloat32Array())   # bump the epoch (a "facet landed"); not in `wanted` so output is unchanged
	var didc := tier.debug_step(wanted, cam2)
	_ok(didc and tier.rebuild_count() - cC == 1, "G-FTD-4: record-cache epoch change (facet land/evict) ⇒ rebuild re-arms")

	# G-FTD-3: an edit-revision change (a chop) ⇒ the next step rebuilds within one step.
	tier.debug_step(wanted, cam2)                      # latch (static skip)
	var cD := tier.rebuild_count()
	_fake_edits_rev += 1                               # a chop bumped WorldManager.edit_count()
	var dide := tier.debug_step(wanted, cam2)
	_ok(dide and tier.rebuild_count() - cD == 1, "G-FTD-3: edit-revision change (chop) ⇒ rebuild re-arms within one step")
	# Chop-ghost check (needs the FADE chop filter): chopping every tree empties the far set on the re-armed step.
	if CubeSphere.FP_FAR_TREES_FADE:
		_fake_edits_rev += 1
		tier.set_chop_query(func(_f, _c): return false)
		tier.debug_step(wanted, cam2)                  # re-armed rebuild, nothing chopped
		var live_before := tier.live_instances() + tier.mesh_live_instances()
		tier.set_chop_query(func(_f, _c): return true)
		_fake_edits_rev += 1
		tier.debug_step(wanted, cam2)                  # re-armed rebuild, everything chopped
		var live_after := tier.live_instances() + tier.mesh_live_instances()
		_ok(live_before > 0 and live_after == 0,
			"G-FTD-3: chopping every tree empties the far set on the re-armed step (%d → 0, no ghost)" % live_before)
		tier.set_chop_query(Callable())
	else:
		print("  (G-FTD-3 chop-ghost check skipped — needs FP_FAR_TREES_FADE for the chop filter)")
	ring.queue_free()

# ---- G-FTA (FP_FAR_TREES_ALIGN — the height weld) -------------------------------------------------------------------

## Two-state, self-describing. ON ⇒ the enum anchor is the NEAR trunk-bottom-face centre (bx+0.5, gy+1, bz+0.5)
## (world→lattice round-trip), the archetype min vertex Y == 0.0 (the −0.5 shift), and the far sink is the distance
## ramp (0 at FT_SINK_R0, buried deep). OFF ⇒ the shipped raw-corner+BURY anchor and archetype min Y == 0.5 (byte-off).
func _gate_align() -> void:
	var align := CubeSphere.FP_FAR_TREES_ALIGN
	var ring := _fake_ring()
	var tier = FT.new()
	var fid: int = _sample_facets()[0]
	tier.setup_instance(ring, fid)
	var ctx = TerrainConfig.GenCtx.new(0, fid)
	var recs: PackedFloat32Array = tier.enumerate_facet_sync(fid)
	var m := recs.size() / FT.REC_FLOATS
	var anchor_ok := true
	var conv_ok := true
	var checked := 0
	for i in range(m):
		var o := i * FT.REC_FLOATS
		var sp := Vector3(recs[o + 0], recs[o + 1], recs[o + 2])
		var bx := int(recs[o + 8]); var gy := int(recs[o + 9]); var bz := int(recs[o + 10])
		if TreeGen.block_at(bx, gy + 1, bz, ctx) == BlockCatalog.AIR:
			conv_ok = false                              # the near trunk log sits at gy+1 — the +1-convention witness
		if align:
			var latt = FA.world_to_lattice64(fid, sp.x, sp.y, sp.z)
			# FP_FT_FRAME_WELD (#131): the anchor now carries the FS2′ datum lift (0 unless the weld+FP_DATUM_BAKE);
			# G-FTF-1 owns the dedicated datum coverage, this just keeps G-FTA-1 consistent across both weld states.
			var lift := FA.datum_lift(fid, float(bx) + 0.5, float(bz) + 0.5) if CubeSphere.FP_FT_FRAME_WELD else 0.0
			if absf(float(latt[0]) - (float(bx) + 0.5)) > 2.0e-2 or absf(float(latt[1]) - (float(gy) + 1.0 + lift)) > 2.0e-2 \
					or absf(float(latt[2]) - (float(bz) + 0.5)) > 2.0e-2:
				anchor_ok = false
		else:
			var w = FA.lattice_to_world64(fid, float(bx), float(gy), float(bz))
			var ws := Vector3(float(w[0]), float(w[1]), float(w[2]))
			var expct := ws - ws.normalized() * FT.BURY
			if sp.distance_to(expct) > 2.0e-2:
				anchor_ok = false
		checked += 1
	_ok(checked > 0, "G-FTA-1: anchor sample non-empty (%d)" % checked)
	_ok(conv_ok, "G-FTA-1: every far tree's ground cell gy solid + trunk cell gy+1 a log (near +1 convention)")
	if align:
		_ok(anchor_ok, "G-FTA-1: far anchor world→lattice == (bx+0.5, gy+1, bz+0.5) — welded to the near trunk-bottom face")
	else:
		_ok(anchor_ok, "G-FTA-1(off): far anchor == shipped lattice_to_world64(bx,gy,bz) − BURY·r̂ (byte-identical)")
	if CubeSphere.FP_FAR_TREES_MESH:
		var minok := true
		var exp_min := 0.0 if align else 0.5
		for col in range(6):
			var my := tier.mesh_min_vertex_y(col)
			if is_nan(my) or absf(my - exp_min) > 1.0e-3:
				minok = false
		_ok(minok, "G-FTA-2: archetype min vertex Y == %.1f (%s)" % [exp_min, "ALIGN −0.5 shift" if align else "shipped"])
	else:
		print("  (G-FTA-2 skipped — needs FP_FAR_TREES_MESH sed-toggled true)")
	_ok(is_equal_approx(FT.sink_ramp(CubeSphere.FT_SINK_R0), 0.0), "G-FTA-3: sink_ramp(FT_SINK_R0) == 0 (exact base at the near boundary)")
	_ok(FT.sink_ramp(CubeSphere.FT_SINK_R1 + 40.0) > FT.sink_ramp(CubeSphere.FT_SINK_R0), "G-FTA-3: sink_ramp buries deeper with distance")
	# G-FTR-1 (#120 residual P0-a): the deep-band sink is now a HAIR (FT_SINK_MAX 0.15, was 1.0) so a far tree at the deep
	# band sits ≤0.2 blk below the near trunk base (was ~1 blk — the over-buried "trunkless canopy on the grass" residual).
	# Pure sink_ramp property (flag-independent), and the saturated value equals FT_SINK_MAX exactly.
	_ok(FT.sink_ramp(CubeSphere.FT_SINK_R1 + 40.0) <= 0.2 and is_equal_approx(FT.sink_ramp(CubeSphere.FT_SINK_R1 + 40.0), CubeSphere.FT_SINK_MAX),
		"G-FTR-1: deep-band sink == FT_SINK_MAX %.2f ≤ 0.2 blk (P0-a un-buries the far trunk; was 1.0)" % CubeSphere.FT_SINK_MAX)
	var d := FA.cell_dir(fid, (FA.dom_min(fid).x + FA.dom_max(fid).x) / 2, (FA.dom_min(fid).y + FA.dom_max(fid).y) / 2)
	var centre := Vector3(d.x, d.y, d.z) * FA.R_BLOCKS
	var radial := centre.normalized()
	var up := Vector3(0, 1, 0)
	if absf(radial.dot(up)) > 0.99: up = Vector3(1, 0, 0)
	var tangent := radial.cross(up).normalized()
	var dtest := 500.0
	var pp := centre + tangent * dtest
	var rr := pp.normalized()
	var syn := PackedFloat32Array()
	syn.push_back(pp.x); syn.push_back(pp.y); syn.push_back(pp.z)
	syn.push_back(rr.x); syn.push_back(rr.y); syn.push_back(rr.z)
	syn.push_back(0.0); syn.push_back(5.0)
	syn.push_back(0.0); syn.push_back(0.0); syn.push_back(0.0)
	tier.debug_set_cache(fid, syn)
	tier.debug_rebuild([fid], centre)
	var cbuf: PackedFloat32Array = tier.debug_buffer()
	if tier.live_instances() >= 1:
		var org := Vector3(cbuf[3], cbuf[7], cbuf[11])
		var sk: float = FT.sink_ramp(dtest) if align else 0.0
		var exp_org := pp - rr * sk
		_ok(org.distance_to(exp_org) < 2.0e-1, "G-FTA-3: card origin == anchor − r̂·sink_ramp(d) (%s, sink=%.2f)" % ["ALIGN" if align else "off", sk])
	else:
		_ok(true, "G-FTA-3: (no card at d=500 — skipped)")
	ring.queue_free()

# ---- G-FTC (FP_FAR_TREES_NEARCULL — the handoff cull) ---------------------------------------------------------------

func _gate_cull() -> void:
	if not CubeSphere.FP_FAR_TREES_MESH:
		print("  (G-FTC skipped — needs FP_FAR_TREES_MESH, the near-frontier rung)")
		return
	var nearcull := CubeSphere.FP_FAR_TREES_NEARCULL
	var ring := _fake_ring()
	var fid: int = _sample_facets()[0]
	var d := FA.cell_dir(fid, (FA.dom_min(fid).x + FA.dom_max(fid).x) / 2, (FA.dom_min(fid).y + FA.dom_max(fid).y) / 2)
	var centre := Vector3(d.x, d.y, d.z) * FA.R_BLOCKS
	var radial := centre.normalized()
	var up := Vector3(0, 1, 0)
	if absf(radial.dot(up)) > 0.99: up = Vector3(1, 0, 0)
	var tangent := radial.cross(up).normalized()
	var dists := [50.0, 100.0, 140.0, 300.0]
	var syn := PackedFloat32Array()
	for dv in dists:
		var pp := centre + tangent * float(dv)
		var rr := pp.normalized()
		syn.push_back(pp.x); syn.push_back(pp.y); syn.push_back(pp.z)
		syn.push_back(rr.x); syn.push_back(rr.y); syn.push_back(rr.z)
		syn.push_back(0.0); syn.push_back(5.0)
		syn.push_back(float(int(dv))); syn.push_back(10.0); syn.push_back(0.0)
	if not nearcull:
		var ti = FT.new(); ti.setup_instance(ring, fid); ti.debug_set_cache(fid, syn)
		ti.set_near_query(func(_f, _b): return NearPresence.COVERED)
		ti.debug_rebuild([fid], centre)
		var wv := ti.mesh_live_instances()
		var tj = FT.new(); tj.setup_instance(ring, fid); tj.debug_set_cache(fid, syn)
		tj.debug_rebuild([fid], centre)
		var uv := tj.mesh_live_instances()
		_ok(wv == uv, "G-FTC(off): the near-query is inert — wired == unwired shipped band (%d==%d)" % [wv, uv])
		ring.queue_free()
		return
	var ta = FT.new(); ta.setup_instance(ring, fid); ta.debug_set_cache(fid, syn)
	ta.set_near_query(func(_f, _b): return NearPresence.COVERED)
	ta.debug_rebuild([fid], centre)
	var cov := ta.mesh_live_instances()
	_ok(cov == 1, "G-FTC-1: probed-COVERED trees culled — only the beyond-probe tree survives (%d==1)" % cov)
	_ok(ta.cull_probe_count() <= 256, "G-FTC-1: probes bounded (%d <= 256/rebuild)" % ta.cull_probe_count())
	ta.set_near_query(func(_f, _b): return NearPresence.NOT_COVERED)
	ta.debug_rebuild([fid], centre)
	var after1 := ta.mesh_live_instances()
	for _k in range(CubeSphere.FT_CULL_DWELL):
		ta.debug_rebuild([fid], centre)
	var restored := ta.mesh_live_instances()
	_ok(restored == 3, "G-FTC-1: NOT_COVERED draws all incl the d<128 gap-fill (%d==3 after dwell)" % restored)
	_ok(after1 < restored, "G-FTC-2: dwell holds the restore for FT_CULL_DWELL rebuilds (%d then %d)" % [after1, restored])
	var t2 = FT.new(); t2.setup_instance(ring, fid); t2.debug_set_cache(fid, syn)
	t2.set_near_query(func(_f, _b): return NearPresence.COVERED)
	t2.debug_rebuild([fid], centre)
	var hid := t2.mesh_live_instances()
	t2.set_near_query(func(_f, _b): return NearPresence.UNKNOWABLE)
	t2.debug_rebuild([fid], centre)
	var still := t2.mesh_live_instances()
	_ok(hid == 1 and still == 1, "G-FTC-1: UNKNOWABLE never flips state (hidden stays hidden: %d==%d==1)" % [hid, still])
	var tb = FT.new(); tb.setup_instance(ring, fid); tb.debug_set_cache(fid, syn)
	tb.debug_rebuild([fid], centre)
	var off_n := tb.mesh_live_instances()
	_ok(cov <= off_n, "G-FTC-4: cull strictly reduces instances (cull %d <= shipped %d)" % [cov, off_n])
	if CubeSphere.FP_FAR_TREES_DELTA:
		var t3 = FT.new(); t3.setup_instance(ring, fid); t3.debug_set_cache(fid, syn)
		t3.set_near_query(func(_f, _b): return NearPresence.NOT_COVERED)
		t3.debug_step([fid], centre)
		var c0 := t3.rebuild_count()
		t3.debug_step([fid], centre)
		_ok(t3.rebuild_count() == c0, "G-FTC-3: static camera + stable presence ⇒ rebuild skipped")
		t3.set_near_query(func(_f, _b): return NearPresence.COVERED)
		t3.debug_step([fid], centre)
		_ok(t3.rebuild_count() == c0 + 1, "G-FTC-3: a presence change re-arms the DELTA rebuild under a still camera")
		# G-FTC-5 (§5.3, #130 dwell-stall — the missing NEARCULL-through-DELTA composition coverage): drives debug_step
		# (the REAL DELTA-gated path, NOT debug_rebuild which bypasses the gate), both flags on, static camera, stubbed
		# near-query. ONE annulus tree at d=140 so the live count is a clean 0 (culled) → 1 (restored). Case 2/3 FAIL on
		# the shipped COVERED-only fingerprint (the restore streak freezes at 1 forever) and PASS with the §5.2 state-fold.
		var one := PackedFloat32Array()
		var pdel := centre + tangent * 140.0
		var rdel := pdel.normalized()
		one.push_back(pdel.x); one.push_back(pdel.y); one.push_back(pdel.z)
		one.push_back(rdel.x); one.push_back(rdel.y); one.push_back(rdel.z)
		one.push_back(0.0); one.push_back(5.0)
		one.push_back(140.0); one.push_back(10.0); one.push_back(0.0)

		# Case 1 — COVERED steady ⇒ the tree is culled and extra static steps rebuild ZERO times (steady-state quiet: the
		# fp is the shipped COVERED-only term, no restore in progress).
		var c1 = FT.new(); c1.setup_instance(ring, fid); c1.debug_set_cache(fid, one)
		c1.set_near_query(func(_f, _b): return NearPresence.COVERED)
		c1.debug_step([fid], centre)                    # first rebuild: COVERED ⇒ hidden
		var c1_hidden := c1.mesh_live_instances() == 0
		var c1_rc := c1.rebuild_count()
		c1.debug_step([fid], centre); c1.debug_step([fid], centre); c1.debug_step([fid], centre)
		_ok(c1_hidden and c1.rebuild_count() == c1_rc and c1.mesh_live_instances() == 0,
			"G-FTC-5(1): COVERED steady ⇒ tree culled + 0 extra rebuilds over 3 static steps (steady-state quiet)")

		# Case 2 — COVERED→NOT_COVERED ⇒ restore within FT_CULL_DWELL rebuild-steps, ≤ FT_CULL_DWELL+1 total rebuilds, then
		# QUIESCENT (further static steps rebuild zero). This is the core #130 stall (FAILS pre-fix: restore never fires).
		var c2 = FT.new(); c2.setup_instance(ring, fid); c2.debug_set_cache(fid, one)
		var s2 := {"v": NearPresence.COVERED}
		c2.set_near_query(func(_f, _b): return s2["v"])
		c2.debug_step([fid], centre)                    # cull
		var c2_hidden := c2.mesh_live_instances() == 0
		s2["v"] = NearPresence.NOT_COVERED              # near mesh recedes; camera DEAD STILL from here
		var rc_flip := c2.rebuild_count()
		var restored_at := -1
		for i in range(CubeSphere.FT_CULL_DWELL + 5):
			c2.debug_step([fid], centre)
			if restored_at < 0 and c2.mesh_live_instances() == 1:
				restored_at = i + 1
		var total_rebuilds := c2.rebuild_count() - rc_flip
		var rc_tail := c2.rebuild_count()
		c2.debug_step([fid], centre); c2.debug_step([fid], centre)
		var tail_rebuilds := c2.rebuild_count() - rc_tail
		_ok(c2_hidden and c2.mesh_live_instances() == 1 and restored_at > 0 and restored_at <= CubeSphere.FT_CULL_DWELL + 1
				and total_rebuilds <= CubeSphere.FT_CULL_DWELL + 1 and tail_rebuilds == 0,
			"G-FTC-5(2): COVERED→NOT_COVERED restores at step %d ≤ DWELL+1, %d total rebuilds ≤ DWELL+1, then QUIESCENT (tail %d) — #130 fix" % [restored_at, total_rebuilds, tail_rebuilds])

		# Case 3 — mid-streak UNKNOWABLE freeze ⇒ ZERO rebuilds while frozen + still hidden (the DELTA promise: a permanently-
		# UNKNOWABLE mid-restore tree must NOT churn); then U→NOT_COVERED ⇒ restore resumes. Pins SALT_U (without it the
		# U→NOT_COVERED flip is invisible to the fp and the stall returns through the UNKNOWABLE door).
		var c3 = FT.new(); c3.setup_instance(ring, fid); c3.debug_set_cache(fid, one)
		var s3 := {"v": NearPresence.COVERED}
		c3.set_near_query(func(_f, _b): return s3["v"])
		c3.debug_step([fid], centre)                    # cull
		s3["v"] = NearPresence.NOT_COVERED
		c3.debug_step([fid], centre)                    # streak → 1 (mid-restore), still hidden
		var c3_mid_hidden := c3.mesh_live_instances() == 0
		s3["v"] = NearPresence.UNKNOWABLE
		c3.debug_step([fid], centre)                    # transition into UNKNOWABLE settles the fp (one rebuild), hidden
		var rc_frozen := c3.rebuild_count()
		for _j in range(4):
			c3.debug_step([fid], centre)                # sustained UNKNOWABLE
		var c3_froze := c3.rebuild_count() == rc_frozen and c3.mesh_live_instances() == 0
		s3["v"] = NearPresence.NOT_COVERED              # the probe becomes decidable again
		var steps3 := 0
		while steps3 < CubeSphere.FT_CULL_DWELL + 3 and c3.mesh_live_instances() == 0:
			c3.debug_step([fid], centre)
			steps3 += 1
		_ok(c3_mid_hidden and c3_froze and c3.mesh_live_instances() == 1,
			"G-FTC-5(3): mid-streak UNKNOWABLE freeze ⇒ 0 rebuilds + still hidden; U→NOT_COVERED resumes restore (SALT_U)")
		# Case 4 (per-step restore under NEARCULL-on/DELTA-off, + both-off byte parity) is covered by the existing G-FTC-1/2
		# (debug_rebuild forces a rebuild every step ⇒ restore in FT_CULL_DWELL) and the standing G-OFF/FLAT byte suites.
	else:
		print("  (G-FTC-3 / G-FTC-5 re-arm checks skipped — need FP_FAR_TREES_DELTA sed-toggled true)")
	ring.queue_free()

# ---- G-FTF (FP_FT_FRAME_WELD — the owner-facet frame weld, task #131) -----------------------------------------------

## The SHIPPED stable-tangent card/mesh basis first column: t1 = (r × ŷ_world).normalized() (ŷ = world up, swapped to
## world +X near the ±ŷ degeneracy) — replicated EXACTLY from _write_card/_write_mesh_inst so the off-state assertions
## are a true bit-compare against what the shipped code emits.
func _shipped_t1(r: Vector3) -> Vector3:
	var up := Vector3(0.0, 1.0, 0.0)
	if absf(r.dot(up)) > 0.99:
		up = Vector3(1.0, 0.0, 0.0)
	return r.cross(up).normalized()

## The VISIBLE yaw error (blocky cubes are 90°-symmetric, so orientation only matters mod 90°): the min angle from t1
## to any of ±ê_u / ±ê_w. 0° ⇒ perfectly axis-aligned to the lattice; up to 45°.
func _visible_yaw_err(t1: Vector3, eu: Vector3, ew: Vector3) -> float:
	var best := 180.0
	for axis in [eu, -eu, ew, -ew]:
		best = minf(best, rad_to_deg(t1.angle_to(axis)))
	return best

## G-FTF-1 (§3.1 anchor + datum). Two-state, self-describing. The enum record stores the UNSUNK anchor under ALIGN;
## its world→lattice round-trip must equal (bx+0.5, gy+1 + datum_lift(fid,bx+0.5,bz+0.5), bz+0.5) with the weld on, and
## the #120 plane law (gy+1, no lift) off. datum_lift returns 0 unless FP_DATUM_BAKE, so weld-on/BAKE-off COINCIDES with
## the plane law (the tracking property). With BAKE on, ≥1 sampled MID-FACET column must have |lift| > 2 — the #120 gate
## only pinned the plane law (s≈0), so this is the missing coverage.
func _gate_frame_anchor() -> void:
	if not CubeSphere.FP_FAR_TREES_ALIGN:
		print("  (G-FTF-1 skipped — Part A composes with FP_FAR_TREES_ALIGN; sed it true)")
		return
	var weld := CubeSphere.FP_FT_FRAME_WELD
	var ring := _fake_ring()
	var tier = FT.new()
	tier.setup_instance(ring, _sample_facets()[0])
	var anchor_ok := true
	var checked := 0
	var max_lift := 0.0
	var facets_used := 0
	for fid in _sample_facets():
		var recs: PackedFloat32Array = tier.enumerate_facet_sync(fid)
		var m := recs.size() / FT.REC_FLOATS
		if m > 0:
			facets_used += 1
		for i in range(m):
			var o := i * FT.REC_FLOATS
			var sp := Vector3(recs[o + 0], recs[o + 1], recs[o + 2])   # ALIGN stores the UNSUNK anchor
			var bx := int(recs[o + 8]); var gy := int(recs[o + 9]); var bz := int(recs[o + 10])
			var lift := FA.datum_lift(fid, float(bx) + 0.5, float(bz) + 0.5)   # 0 unless FP_DATUM_BAKE
			max_lift = maxf(max_lift, absf(lift))
			var exp_y := float(gy) + 1.0 + (lift if weld else 0.0)
			var latt = FA.world_to_lattice64(fid, sp.x, sp.y, sp.z)
			if absf(float(latt[0]) - (float(bx) + 0.5)) > 2.0e-2 \
					or absf(float(latt[1]) - exp_y) > 2.0e-2 \
					or absf(float(latt[2]) - (float(bz) + 0.5)) > 2.0e-2:
				anchor_ok = false
			checked += 1
	_ok(facets_used >= 2, "G-FTF-1: sampled trees on ≥2 facets (%d)" % facets_used)
	_ok(checked > 0, "G-FTF-1: anchor sample non-empty (%d)" % checked)
	if weld:
		_ok(anchor_ok, "G-FTF-1: far anchor world→lattice == (bx+0.5, gy+1+datum_lift, bz+0.5) — welded to the near datum-lifted trunk base")
		if CubeSphere.FP_DATUM_BAKE:
			_ok(max_lift > 2.0, "G-FTF-1: a sampled mid-facet column has |datum_lift| > 2 (max %.2f) — the lift is EXERCISED (not s≈0)" % max_lift)
		else:
			_ok(is_equal_approx(max_lift, 0.0), "G-FTF-1: FP_DATUM_BAKE off ⇒ datum_lift 0 ⇒ weld coincides with the #120 plane law (tracking property)")
	else:
		_ok(anchor_ok, "G-FTF-1(off): far anchor == (bx+0.5, gy+1, bz+0.5) — the shipped #120 plane law (byte-identical)")
	ring.queue_free()

## G-FTF-2 (§3.2 instance basis). Two-state. Inject synthetic trees whose STORED radial is a common value (so the off
## basis is deterministic and the same for every instance), spread so the card band (and, under MESH, the mesh band)
## populate. Under the weld the emitted basis columns == the OWNER facet's lattice (ê_u, n̂, ê_w); off == the shipped
## (t1, r, t2) computed from the stored radial (bit-compare).
func _gate_frame_basis() -> void:
	var weld := CubeSphere.FP_FT_FRAME_WELD
	var ring := _fake_ring()
	var tier = FT.new()
	var fid: int = _sample_facets()[0]
	tier.setup_instance(ring, fid)
	var fb := FA.frame_basis(fid)
	var d := FA.cell_dir(fid, (FA.dom_min(fid).x + FA.dom_max(fid).x) / 2, (FA.dom_min(fid).y + FA.dom_max(fid).y) / 2)
	var centre := Vector3(d.x, d.y, d.z) * FA.R_BLOCKS
	var r_common := centre.normalized()
	var tangent := r_common.cross(Vector3(0, 1, 0))
	if tangent.length() < 0.1: tangent = r_common.cross(Vector3(1, 0, 0))
	tangent = tangent.normalized()
	# One tree at 520 (card band [448,CARD_MAX]) and one at 200 (mesh band [128,448) under MESH; else a 2nd card).
	# Position drives band selection; the stored radial is r_common for both, decoupling the off-basis from position.
	var synth := PackedFloat32Array()
	for dv in [520.0, 200.0]:
		var p := centre + tangent * float(dv)
		synth.push_back(p.x); synth.push_back(p.y); synth.push_back(p.z)
		synth.push_back(r_common.x); synth.push_back(r_common.y); synth.push_back(r_common.z)
		synth.push_back(0.0); synth.push_back(5.0)                       # species col 0, trunk_h 5, hue 0
		synth.push_back(0.0); synth.push_back(0.0); synth.push_back(0.0)
	tier.debug_set_cache(fid, synth)
	tier.debug_rebuild([fid], centre)
	# --- Cards ---
	var cbuf: PackedFloat32Array = tier.debug_buffer()
	var cvis := tier.live_instances()
	var t1e := _shipped_t1(r_common)
	var t2e := r_common.cross(t1e).normalized()
	var card_ok := cvis > 0
	for i in range(cvis):
		var b := i * FT.CARD_STRIDE
		var col0 := Vector3(cbuf[b + 0], cbuf[b + 4], cbuf[b + 8])
		var col1 := Vector3(cbuf[b + 1], cbuf[b + 5], cbuf[b + 9])
		var col2 := Vector3(cbuf[b + 2], cbuf[b + 6], cbuf[b + 10])
		if weld:
			if col0.normalized().distance_to(fb.x) > 1.0e-3 or col1.normalized().distance_to(fb.y) > 1.0e-3 \
					or col2.normalized().distance_to(fb.z) > 1.0e-3:
				card_ok = false
		else:
			# bit-compare against the shipped (t1·hs, r·vs, t2·hs)
			if not (col0.is_equal_approx(t1e * FT.CANOPY_DIAM) and col2.is_equal_approx(t2e * FT.CANOPY_DIAM)
					and col1.normalized().distance_to(r_common) < 1.0e-3):
				card_ok = false
	if weld:
		_ok(card_ok, "G-FTF-2: card basis columns == (ê_u·hs, n̂·vs, ê_w·hs) of the OWNER facet (rotation welded)")
	else:
		_ok(card_ok, "G-FTF-2(off): card basis == shipped (t1·hs, r·vs, t2·hs) from the stored radial (bit-compare)")
	# --- Meshes (only when MESH on — else the 200 tree is a card, covered above) ---
	if CubeSphere.FP_FAR_TREES_MESH:
		var stride: int = FT.mesh_stride()
		var mbuf: PackedFloat32Array = tier.mesh_buffer(0)
		var mvis := tier.mesh_visible(0)
		var mesh_ok := mvis > 0
		for i in range(mvis):
			var b := i * stride
			var col0 := Vector3(mbuf[b + 0], mbuf[b + 4], mbuf[b + 8])
			var col1 := Vector3(mbuf[b + 1], mbuf[b + 5], mbuf[b + 9])
			var col2 := Vector3(mbuf[b + 2], mbuf[b + 6], mbuf[b + 10])
			if weld:
				if col0.distance_to(fb.x) > 1.0e-3 or col1.distance_to(fb.y) > 1.0e-3 or col2.distance_to(fb.z) > 1.0e-3:
					mesh_ok = false
			else:
				if not (col0.is_equal_approx(t1e) and col1.is_equal_approx(r_common) and col2.is_equal_approx(t2e)):
					mesh_ok = false
		if weld:
			_ok(mesh_ok, "G-FTF-2: mesh basis columns == unit (ê_u, n̂, ê_w) of the OWNER facet (archetype cubes axis-aligned to near)")
		else:
			_ok(mesh_ok, "G-FTF-2(off): mesh basis == shipped unit (t1, r, t2) (bit-compare)")
	else:
		print("  (G-FTF-2 mesh sub-check skipped — needs FP_FAR_TREES_MESH)")
	ring.queue_free()

## G-FTF-3 (§6 the task gate — cross-fold weld). Derive (not hardcode) a facet whose SHIPPED (r×ŷ) basis is > 30°
## mis-yawed vs its own lattice ê_u — a cube-face fold. Part (b) is a FLAG-INDEPENDENT pin that this facet exhibits the
## live bug (so the gate provably catches it: pre-fix the emitted basis IS the shipped one → the weld assertion fails).
## Part (a): a real owned tree's far anchor == the near datum-lifted base (position) AND the emitted basis == the owner
## lattice (rotation) under the weld; == the shipped mis-yawed basis off.
func _gate_frame_fold() -> void:
	var weld := CubeSphere.FP_FT_FRAME_WELD
	var earth_n := 6 * FA.K * FA.K
	var ffid := -1
	for fid in range(earth_n):
		var dmn := FA.dom_min(fid); var dmx := FA.dom_max(fid)
		var dc := FA.cell_dir(fid, (dmn.x + dmx.x) / 2, (dmn.y + dmx.y) / 2)
		var rc := Vector3(dc.x, dc.y, dc.z).normalized()
		var fbk := FA.frame_basis(fid)
		if _visible_yaw_err(_shipped_t1(rc), fbk.x, fbk.z) > 30.0:
			ffid = fid
			break
	_ok(ffid >= 0, "G-FTF-3: derived a cross-fold facet with shipped-basis yaw error > 30° (fid %d)" % ffid)
	if ffid < 0:
		return
	var fb := FA.frame_basis(ffid)
	var dmn := FA.dom_min(ffid); var dmx := FA.dom_max(ffid)
	var dc := FA.cell_dir(ffid, (dmn.x + dmx.x) / 2, (dmn.y + dmx.y) / 2)
	var r_common := Vector3(dc.x, dc.y, dc.z).normalized()
	# Part (b): the flag-independent bug pin.
	var yaw_err := _visible_yaw_err(_shipped_t1(r_common), fb.x, fb.z)
	_ok(yaw_err > 30.0, "G-FTF-3: shipped (r×ŷ) basis is %.1f° mis-yawed vs ê_u at the fold (the live #131 bug this gate catches)" % yaw_err)
	var ring := _fake_ring()
	var tier = FT.new()
	tier.setup_instance(ring, ffid)
	# Part (a) position weld — a real owned tree on the fold facet (needs ALIGN, which Part A composes with).
	if CubeSphere.FP_FAR_TREES_ALIGN:
		var recs: PackedFloat32Array = tier.enumerate_facet_sync(ffid)
		var m := recs.size() / FT.REC_FLOATS
		var pos_ok := true
		var pchecked := 0
		for i in range(m):
			var o := i * FT.REC_FLOATS
			var sp := Vector3(recs[o + 0], recs[o + 1], recs[o + 2])
			var bx := int(recs[o + 8]); var gy := int(recs[o + 9]); var bz := int(recs[o + 10])
			var lift := FA.datum_lift(ffid, float(bx) + 0.5, float(bz) + 0.5)
			var exp_y := float(gy) + 1.0 + (lift if weld else 0.0)
			var latt = FA.world_to_lattice64(ffid, sp.x, sp.y, sp.z)
			if absf(float(latt[0]) - (float(bx) + 0.5)) > 2.0e-2 or absf(float(latt[1]) - exp_y) > 2.0e-2 \
					or absf(float(latt[2]) - (float(bz) + 0.5)) > 2.0e-2:
				pos_ok = false
			pchecked += 1
		_ok(pchecked == 0 or pos_ok, "G-FTF-3: fold-facet far anchor == near datum-lifted trunk base (position weld, %d trees)" % pchecked)
	else:
		print("  (G-FTF-3 position-weld sub-check skipped — needs FP_FAR_TREES_ALIGN)")
	# Part (a) rotation weld — inject a synthetic card on the fold facet (stored radial = facet-centre radial so the off
	# basis exhibits the > 30° error), rebuild, compare the emitted basis.
	var centre := r_common * FA.R_BLOCKS
	var tangent := r_common.cross(Vector3(0, 1, 0))
	if tangent.length() < 0.1: tangent = r_common.cross(Vector3(1, 0, 0))
	tangent = tangent.normalized()
	var p := centre + tangent * 520.0
	var synth := PackedFloat32Array()
	synth.push_back(p.x); synth.push_back(p.y); synth.push_back(p.z)
	synth.push_back(r_common.x); synth.push_back(r_common.y); synth.push_back(r_common.z)
	synth.push_back(0.0); synth.push_back(5.0)
	synth.push_back(0.0); synth.push_back(0.0); synth.push_back(0.0)
	tier.debug_set_cache(ffid, synth)
	tier.debug_rebuild([ffid], centre)
	var cbuf: PackedFloat32Array = tier.debug_buffer()
	var cvis := tier.live_instances()
	var t1e := _shipped_t1(r_common)
	var rot_ok := cvis > 0
	for i in range(cvis):
		var b := i * FT.CARD_STRIDE
		var col0 := Vector3(cbuf[b + 0], cbuf[b + 4], cbuf[b + 8]).normalized()
		var col1 := Vector3(cbuf[b + 1], cbuf[b + 5], cbuf[b + 9]).normalized()
		if weld:
			if col0.distance_to(fb.x) > 1.0e-3 or col1.distance_to(fb.y) > 1.0e-3:
				rot_ok = false
		else:
			if col0.distance_to(t1e) > 1.0e-3 or col1.distance_to(r_common) > 1.0e-3:
				rot_ok = false
	if weld:
		_ok(rot_ok, "G-FTF-3: fold-facet far basis == frame_basis(owner) — rotation weld (yaw error → 0 across the fold)")
	else:
		_ok(rot_ok, "G-FTF-3(off): fold-facet far basis == shipped (r×ŷ, r) — byte-identical (the mis-yawed live basis)")
	ring.queue_free()

# ---- G-XDC (FP_FT_XFADE_COMPL — the 448 complementary cross-dither) -------------------------------------------------

## The card fragment dither (matches `_ft_dither` in the card shader): fract(sin(dot(floor(fc), (12.9898,78.233)))·43758.5453).
func _ft_dither_cpu(fx: float, fy: float) -> float:
	var d := sin(floor(fx) * 12.9898 + floor(fy) * 78.233) * 43758.5453
	return d - floor(d)

## G-XDC-1 (#120 residual P0-b). Two parts, both self-describing:
##  (a) shader-string parity — the CARD dither sample is inverted (`1.0 - _ft_dither`) IFF FP_FT_XFADE_COMPL (with FADE);
##      the MESH sample is NEVER inverted (card-only fix); off ⇒ the shipped in-phase string verbatim.
##  (b) a FLAG-INDEPENDENT CPU coverage sim over a 64×64 FRAGCOORD grid at fades {0.25,0.5,0.75} with f_card = 1 − f_mesh
##      (the 448 cross-dither). COMPLEMENTARY (card keeps iff 1−dither ≤ f_card = the mesh-DISCARD set) ⇒ union == 1.0.
##      IN-PHASE (both keep iff dither ≤ f — the shipped defect) ⇒ union == max(f_mesh,f_card) < 1 (thin trunks lose ~half
##      their pixels at the midpoint). Pins BOTH classes every run so neither can silently return.
func _gate_xfade() -> void:
	var compl := CubeSphere.FP_FT_XFADE_COMPL and CubeSphere.FP_FAR_TREES_FADE
	_ok(FT.shader_code().contains("1.0 - _ft_dither") == compl,
		"G-XDC-1: card shader inverts the dither sample IFF FP_FT_XFADE_COMPL (%s)" % ("on" if compl else "off — shipped in-phase"))
	_ok(not FT.mesh_shader_code().contains("1.0 - _ft_dither"),
		"G-XDC-1: mesh shader dither sample is NEVER inverted (card-only fix)")
	for f in [0.25, 0.5, 0.75]:
		var fm := float(f)
		var fc := 1.0 - fm
		var cov_compl := 0
		var cov_inphase := 0
		var total := 0
		for gx in range(64):
			for gy in range(64):
				var dth := _ft_dither_cpu(float(gx), float(gy))
				var mesh_keep := dth <= fm
				if mesh_keep or ((1.0 - dth) <= fc): cov_compl += 1     # complementary card sample
				if mesh_keep or (dth <= fc): cov_inphase += 1           # shipped in-phase card sample
				total += 1
		_ok(cov_compl == total,
			"G-XDC-1: complementary dither union == 1.0 at f=%.2f (%d/%d — no trunk-dissolve hole)" % [fm, cov_compl, total])
		var frac := float(cov_inphase) / float(total)
		var expect := maxf(fm, fc)
		_ok(absf(frac - expect) < 0.05 and frac < 0.999,
			"G-XDC-1: in-phase dither union == max(f)=%.2f (measured %.3f) < 1 — the shipped 50%%-coverage defect pinned" % [expect, frac])

# ---- G-FTG (FP_FT_NEAR_GUARD — the bounded credit-independent double-render guard, #132) ----------------------------

## docs/COSMOS-FARTREE-POLISH-DESIGN.md §1. Two-state, self-describing. OFF ⇒ no metadata captured, debug_guard inert,
## buffers byte-identical. ON ⇒ a stale far impostor that the frozen instance set left standing over an arrived near mesh
## is culled by the guard EVEN with no rebuild (the credit-0 regime): dist<FT_CULL_MIN ⇒ hidden unconditionally, annulus
## COVERED ⇒ hidden, probes bounded by FT_GUARD_PROBE_CAP with a round-robin cursor, a real rebuild resets the hidden-set.
## The observable is the live MultiMesh instance transform collapsing to zero-scale (set_instance_transform, not the CPU
## buffer snapshot) + the guard_hides()/hidden-set counters; rebuild_count() proves the guard never itself rebuilds.
func _gate_guard() -> void:
	if not CubeSphere.FP_FAR_TREES_MESH or not CubeSphere.FP_FAR_TREES_NEARCULL:
		print("  (G-FTG skipped — needs FP_FAR_TREES_MESH + FP_FAR_TREES_NEARCULL sed-toggled true)")
		return
	var guard := CubeSphere.FP_FT_NEAR_GUARD
	var ring := _fake_ring()
	var fid: int = _sample_facets()[0]
	var d := FA.cell_dir(fid, (FA.dom_min(fid).x + FA.dom_max(fid).x) / 2, (FA.dom_min(fid).y + FA.dom_max(fid).y) / 2)
	var centre := Vector3(d.x, d.y, d.z) * FA.R_BLOCKS
	var radial := centre.normalized()
	var up := Vector3(0, 1, 0)
	if absf(radial.dot(up)) > 0.99: up = Vector3(1, 0, 0)
	var tangent := radial.cross(up).normalized()

	if not guard:
		# G-FTG-OFF: with the flag off, a rebuild captures ZERO guard metadata and debug_guard is a no-op (byte-identical).
		var t = FT.new(); t.setup_instance(ring, fid)
		var p := centre + tangent * 200.0
		var r := p.normalized()
		var syn := PackedFloat32Array([p.x, p.y, p.z, r.x, r.y, r.z, 0.0, 5.0, 0.0, 0.0, 0.0])
		t.set_near_query(func(_f, _b): return NearPresence.NOT_COVERED)
		t.debug_set_cache(fid, syn)
		t.debug_rebuild([fid], centre)
		_ok(t.debug_guard_meta_count() == 0, "G-FTG-OFF: no guard metadata captured (flag off ⇒ no alloc, byte-identical)")
		t.debug_guard(p - tangent * 30.0)
		_ok(t.guard_hides() == 0 and t.debug_guard_hidden_count() == 0, "G-FTG-OFF: debug_guard inert (0 hides)")
		ring.queue_free()
		return

	# --- flag ON ---
	# G-FTG-1: a tree emitted FAR (d=200, NOT_COVERED) is captured; when the camera walks up so it's now inside
	# FT_CULL_MIN, the guard hides it UNCONDITIONALLY (no probe) — even with no intervening rebuild (rebuild_count fixed).
	var t1 = FT.new(); t1.setup_instance(ring, fid)
	var p1 := centre + tangent * 200.0
	var r1 := p1.normalized()
	t1.set_near_query(func(_f, _b): return NearPresence.NOT_COVERED)
	t1.debug_set_cache(fid, PackedFloat32Array([p1.x, p1.y, p1.z, r1.x, r1.y, r1.z, 0.0, 5.0, 0.0, 0.0, 0.0]))
	t1.debug_rebuild([fid], centre)
	_ok(t1.mesh_live_instances() == 1 and t1.debug_guard_meta_count() == 1, "G-FTG-1: one far impostor emitted + captured for the guard")
	var rc1 := t1.rebuild_count()
	t1.debug_guard(p1 - tangent * 30.0)          # camera 30 blk from the tree ⇒ dist < FT_CULL_MIN (64)
	_ok(t1.guard_hides() == 1, "G-FTG-1: tree now inside FT_CULL_MIN hidden unconditionally (near field owns it)")
	_ok(t1.debug_mesh_inst_axis_len(0, 0) < 1.0e-3, "G-FTG-1: the hidden instance transform is zero-scaled (collapsed → invisible)")
	_ok(t1.rebuild_count() == rc1, "G-FTG-1: the guard did NOT rebuild (cull-only, credit-independent)")

	# G-FTG-2: an annulus tree (d=100) emitted while NOT_COVERED is left shown by the guard; when the near mesh arrives
	# (probe flips COVERED) the guard hides it — at credit 0, with no rebuild (the exact frozen double-render heal).
	var t2 = FT.new(); t2.setup_instance(ring, fid)
	var p2 := centre + tangent * 100.0
	var r2 := p2.normalized()
	var s2 := {"v": NearPresence.NOT_COVERED}
	t2.set_near_query(func(_f, _b): return s2["v"])
	t2.debug_set_cache(fid, PackedFloat32Array([p2.x, p2.y, p2.z, r2.x, r2.y, r2.z, 0.0, 5.0, 0.0, 0.0, 0.0]))
	t2.debug_rebuild([fid], centre)
	_ok(t2.mesh_live_instances() == 1, "G-FTG-2: annulus tree emitted while NOT_COVERED")
	t2.debug_guard(centre)
	_ok(t2.guard_hides() == 0, "G-FTG-2: NOT_COVERED annulus tree left shown by the guard (no over-cull)")
	s2["v"] = NearPresence.COVERED
	t2.debug_guard(centre)
	_ok(t2.guard_hides() == 1 and t2.debug_mesh_inst_axis_len(0, 0) < 1.0e-3,
		"G-FTG-2: COVERED annulus tree hidden by the guard (double-render healed at credit 0, no rebuild)")

	# G-FTG-3: FT_GUARD_PROBE_CAP bounds probes/pass; the round-robin cursor drains the rest over subsequent passes.
	var t3 = FT.new(); t3.setup_instance(ring, fid)
	var s3 := {"v": NearPresence.NOT_COVERED}
	t3.set_near_query(func(_f, _b): return s3["v"])
	var N := 80
	var syn3 := PackedFloat32Array()
	for i in range(N):
		var pv := centre + tangent * (80.0 + float(i))     # 80..159 blocks — all inside the annulus [64,168]
		var rv := pv.normalized()
		syn3.append_array(PackedFloat32Array([pv.x, pv.y, pv.z, rv.x, rv.y, rv.z, 0.0, 5.0, 0.0, 0.0, 0.0]))
	t3.debug_set_cache(fid, syn3)
	t3.debug_rebuild([fid], centre)
	_ok(t3.mesh_live_instances() == N and t3.debug_guard_meta_count() == N, "G-FTG-3: %d annulus trees emitted + captured" % N)
	s3["v"] = NearPresence.COVERED
	t3.debug_guard(centre)
	var after1 := t3.guard_hides()
	_ok(after1 > 0 and after1 <= FT.FT_GUARD_PROBE_CAP, "G-FTG-3: one guard pass hides ≤ FT_GUARD_PROBE_CAP (%d ≤ %d)" % [after1, FT.FT_GUARD_PROBE_CAP])
	t3.debug_guard(centre); t3.debug_guard(centre)
	_ok(t3.guard_hides() == N, "G-FTG-3: the round-robin cursor drains all %d over multiple passes (%d hidden)" % [N, t3.guard_hides()])

	# G-FTG-4: a REAL rebuild rewrites the whole buffer ⇒ the hidden-set clears, metadata is re-captured, and the
	# previously-collapsed instances are re-emitted at full scale (guard state cannot leak across rebuilds).
	s3["v"] = NearPresence.NOT_COVERED
	t3.debug_rebuild([fid], centre)
	_ok(t3.debug_guard_hidden_count() == 0 and t3.mesh_live_instances() == N and t3.debug_guard_meta_count() == N,
		"G-FTG-4: a real rebuild clears the hidden-set + re-captures metadata (buffer rewritten)")
	_ok(t3.debug_mesh_inst_axis_len(0, 0) > 0.1, "G-FTG-4: re-emitted instance transform restored to full scale (not zero-scaled)")
	ring.queue_free()

# ---- G-FTM-COLOR (FP_FT_TEXMEAN_COLOR — far-tree leaf/trunk colour = texture-mean, #132) ----------------------------

## docs/COSMOS-FARTREE-POLISH-DESIGN.md §3. Two-state, self-describing. `_ft_color_of` is the SINGLE resolver both far-
## tree colour sites (archetype-mesh vertex colours :1155 + card-atlas raster :1272) call, so testing it proves both.
## ON ⇒ it returns BlockTextures.mean_color_of (the exact far-skin FP_SKIN_TEXTURE_MEAN law — far leaves now match the
## near TEXTURED blocks); OFF ⇒ the shipped flat BlockCatalog swatch (byte-identical mesh arrays + atlas).
func _gate_texmean() -> void:
	var tm := CubeSphere.FP_FT_TEXMEAN_COLOR
	var leaf := BlockCatalog.LEAF
	var got := FT._ft_color_of(leaf)
	var swatch := BlockCatalog.color_of(leaf)
	if tm:
		var mean := BlockTextures.mean_color_of(leaf)
		_ok(got.is_equal_approx(mean), "G-FTM-COLOR: _ft_color_of(LEAF) == BlockTextures.mean_color_of (the far-skin texture-mean law, both sites)")
		_ok((not got.is_equal_approx(swatch)) or mean.is_equal_approx(swatch),
			"G-FTM-COLOR: the leaf mean differs from the flat swatch where a tile exists (the fix is non-trivial)")
	else:
		_ok(got.is_equal_approx(swatch), "G-FTM-COLOR(off): _ft_color_of(LEAF) == flat BlockCatalog swatch (byte-identical)")

# ---- G-FTS (FP_FT_STALE_REBUILD — the ≤0.5Hz staleness floor, #132 P1) ---------------------------------------------

## docs/COSMOS-FARTREE-POLISH-DESIGN.md §4.1. Two-state, self-describing. The floor overrides the credit-0 return for ONE
## rebuild only when settled ∧ credit 0 ∧ moved > FT_STALE_MOVE since the last rebuild ∧ ≥ FT_STALE_MS since it. Drives the
## `_stale_override` decision directly (debug_stale_override) with a manipulable reference (debug_set_stale_ref) so the full
## logic — flag gating, both thresholds, the ≤0.5Hz reset — is provable without a live ring or a 2 s wall wait.
func _gate_stale() -> void:
	var stale := CubeSphere.FP_FT_STALE_REBUILD
	var ring := _fake_ring()
	var fid: int = _sample_facets()[0]
	var tier = FT.new()
	tier.setup_instance(ring, fid)
	var cam0 := Vector3(1000.0, 2000.0, 3000.0)
	var moved := cam0 + Vector3(FT.FT_STALE_MOVE + 8.0, 0.0, 0.0)     # moved PAST the threshold
	var near := cam0 + Vector3(FT.FT_STALE_MOVE - 8.0, 0.0, 0.0)      # moved but UNDER the threshold
	var now := Time.get_ticks_msec()
	if not stale:
		tier.debug_set_stale_ref(cam0, now - FT.FT_STALE_MS - 1000)
		_ok(not tier.debug_stale_override(true, false, moved),
			"G-FTS-OFF: staleness override inert when the flag is off (credit gate byte-identical)")
		ring.queue_free()
		return
	# --- flag ON --- time-stale reference (last rebuild FT_STALE_MS+1s ago)
	tier.debug_set_stale_ref(cam0, now - FT.FT_STALE_MS - 1000)
	_ok(not tier.debug_stale_override(true, false, cam0),
		"G-FTS-1: still camera ⇒ no override (moved 0 ≤ FT_STALE_MOVE)")
	_ok(not tier.debug_stale_override(true, false, near),
		"G-FTS-1: sub-threshold move ⇒ no override (< FT_STALE_MOVE)")
	_ok(tier.debug_stale_override(true, false, moved),
		"G-FTS-2: moved > FT_STALE_MOVE AND ≥ FT_STALE_MS ⇒ override (credit-0 rebuild admitted — the converse fix)")
	_ok(not tier.debug_stale_override(true, true, moved),
		"G-FTS-3: credit OK ⇒ no override (the normal path already rebuilds)")
	_ok(not tier.debug_stale_override(false, false, moved),
		"G-FTS-3: not settled ⇒ never overrides (fresh-load pile-up stays protected)")
	# fresh reference (just rebuilt) ⇒ the ≤0.5Hz floor blocks a second rebuild even though the camera moved
	tier.debug_set_stale_ref(cam0, now)
	_ok(not tier.debug_stale_override(true, false, moved),
		"G-FTS-4: < FT_STALE_MS since the last rebuild ⇒ no override (the ≤0.5Hz floor holds)")
	# a real rebuild resets the reference camera so the floor re-arms from the new position
	tier.debug_set_stale_ref(cam0, now - FT.FT_STALE_MS - 1000)
	tier.enumerate_facet_sync(fid)
	tier.debug_rebuild([fid], moved)
	_ok(tier.debug_stale_ref_cam().is_equal_approx(moved),
		"G-FTS-4: a real rebuild resets the staleness reference camera (floor re-arms from the new pos)")
	ring.queue_free()

# ---- G-NP (NearPresence tri-state predicate) -----------------------------------------------------------------------

func _gate_np() -> void:
	var slab := TerrainConfig.meshed_slab_y()
	var inbox := AABB(Vector3(10.0, 20.0, 10.0), Vector3.ONE)
	_ok(NearPresence.covered(null, 0, inbox) == NearPresence.UNKNOWABLE, "G-NP-1: null world ⇒ UNKNOWABLE")
	var w := FakeWorld.new()
	var outbox := AABB(Vector3(10.0, slab.x - 50.0, 10.0), Vector3.ONE)
	_ok(NearPresence.covered(w, 0, outbox) == NearPresence.NOT_COVERED, "G-NP-2: box outside the bounds slab ⇒ NOT_COVERED (never meshable)")
	w.meshed = true
	_ok(NearPresence.covered(w, 0, inbox) == NearPresence.COVERED, "G-NP-3: a genuinely meshed box ⇒ COVERED (positive reachability)")
	w.meshed = false
	w.band = Vector2(-64.0, 130.0)
	_ok(NearPresence.covered(w, 0, inbox) == NearPresence.NOT_COVERED, "G-NP-4: not meshed but inside the live band ⇒ NOT_COVERED (a real no)")
	w.band = Vector2(60.0, 100.0)
	_ok(NearPresence.covered(w, 0, inbox) == NearPresence.UNKNOWABLE, "G-NP-5: not meshed + outside the live band ⇒ UNKNOWABLE")
	_ok(NearPresence.covered(RefCounted.new(), 0, inbox) == NearPresence.UNKNOWABLE, "G-NP-6: world lacking skin_near_meshed ⇒ UNKNOWABLE (never a silent false)")
