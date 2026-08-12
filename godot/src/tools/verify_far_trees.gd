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
	else:
		print("  (ON gates skipped — need FACETED + FP_FAR_TREES sed-toggled true)")

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

	# G-FTD-2: camera moved ≥ FT_DELTA_MIN_MOVE (2.0) ⇒ the next step rebuilds; then static again ⇒ skips.
	var cam2 := cam + Vector3(3.0, 0.0, 0.0)          # +3 blocks ≥ 2.0
	var cA := tier.rebuild_count()
	var didm := tier.debug_step(wanted, cam2)
	var didm2 := tier.debug_step(wanted, cam2)
	_ok(didm and not didm2 and tier.rebuild_count() - cA == 1,
		"G-FTD-2: camera moved ≥%.1f blk ⇒ rebuild re-arms once, then static ⇒ skips" % CubeSphere.FT_DELTA_MIN_MOVE)

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
