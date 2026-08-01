extends SceneTree
## G-LV — FP_FARRING_LEVEL (COSMOS TEXTURED-LOD U3, docs/COSMOS-TEXTURED-LOD-DESIGN.md §2U.3, live correction 3b:
## SAME LEVEL, not sink). Today the far ring is emitted radially SUNK ≈ 13 blocks below the near surface
## (TierPlace.backstop_sink() at R=6371). U2 (FP_FARRING_CULL_COVERED) removed the sink's HIDE job structurally — a
## covered cell is no longer emitted at all — so this stage removes the ~13-block VISUAL sink: the sink COLLAPSES to
## the ENV_EPS_G correctness guard only (max(ENV_EPS_G, ENV_EPS_FRAC×cell); the same between-fine-sample floor the
## min-envelope uses), so the far ring reads at the near blocks' LEVEL. Fringe z-order at the thin un-culled seam
## rides the ALREADY-SHIPPED FAR_BIAS_K window-space depth bias, not a deep sink.
##
##   G-LV-DEP     — the dependency + self-disable: TierPlace.level_on() == (FP_FARRING_LEVEL ∧ FP_FARRING_CULL_COVERED),
##                  the reduction is REAL (backstop_sink_level < backstop_sink), and the far ring's runtime gate
##                  (_level_on) ADDITIONALLY requires a VALID coverage probe — a ring with NO cover query emits the
##                  FULL sink (INERT), one with a valid query emits the LEVEL sink. Proves "requires U2 / self-disables".
##   G-LV-NOPROT  — RADIALLY (far radius vs the near true surface radius at the same in-plane param, the comparison the
##                  design specifies — the radial-vs-normal skew is U3's depth-bias job, not the sink's), the LEVEL far
##                  ring never protrudes above the near surface beyond the ε guard: worst (r_far − r_near) ≤ ENV_EPS_G.
##                  Atop the deployed min-envelope (FP_ENV_ALL) the cell is a lower bound, so the small guard suffices.
##                  FALSIFIED by dropping the min-envelope+guard: the un-enveloped chord protrudes radially (> ENV_EPS_G).
##   G-LV-SEAM    — at the seam the far cell top meets the near terrain FLUSH (same level within the guard): the
##                  applied radial offset == level_sink EXACTLY (a tiny ε), and the far top lands within
##                  level_sink + 1-block RELIEF quantization of the near block top — NOT the ~13-block step the full
##                  sink leaves (printed as the contrast the U3 stage removes).
##
## Byte-off (both flags default false ⇒ _sunk_positions uses the full backstop_sink verbatim) is covered by
## verify_feature (FLAT 6042/0). Exits 0 all-pass, 1 on any failure.
##
## RUN (green): the DEPLOYED no-protrusion set + U2 + U3 — sed true: FACETED, FP_FARRING_FULL_COVER, FP_SHELL_WELD,
##   FP_TIER_ENVELOPE, FP_ENV_ALL, FP_TIER_STICKY_BACKSTOP, FP_TIER_WARM_CONVERGE, FP_TIER_DEPTH_BIAS,
##   FP_FARRING_CULL_COVERED, FP_FARRING_LEVEL. Under FP_ENV_ALL backstop_sink() is the conservative ~11.7-block sink
##   (0.45×cell, covering the radial-vs-normal skew geometrically); U3 collapses it to the radial ε guard (0.2×cell ≈
##   5.2) and hands the skew to the shipped FAR_BIAS_K depth bias. (The RADIAL no-protrusion needs the min-envelope, so
##   this is the deployed config — matching verify_no_protrusion's RUN set.)
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_farring_level.gd

const FA := preload("res://src/cosmos/facet_atlas.gd")
const FFR := preload("res://src/world/facet_far_ring.gd")
const N_PROBE := 12000            # random directions per facet
const M_FACETS := 24              # curvature-selected facets (where the chord over-estimate / poke lives)

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

var _rng := RandomNumberGenerator.new()

## A VALID coverage callable (stands in for module_world.skin_near_meshed) — its mere validity engages _cull_on()/
## _level_on(); returning true/false does not affect the position caches this gate reconstructs.
func _cover_true(_fid: int, _aabb: AABB) -> bool: return true

func _initialize() -> void:
	print("=== verify_farring_level (G-LV: FP_FARRING_LEVEL — far ring at the near level) ===")
	if not CubeSphere.FACETED or not CubeSphere.FP_FARRING_FULL_COVER:
		print("  FAIL: needs FACETED + FP_FARRING_FULL_COVER sed-toggled true.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	if not CubeSphere.FP_FARRING_LEVEL or not CubeSphere.FP_FARRING_CULL_COVERED:
		print("  FAIL: needs FP_FARRING_LEVEL + FP_FARRING_CULL_COVERED sed-toggled true (U3 requires U2).")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	TerrainConfig.warm_up()
	FA.warm_up()
	_rng.seed = 0x0C0FFEE
	var active := FA.spawn_facet()
	TerrainConfig.set_active_facet(active)
	var full := TierPlace.backstop_sink()
	var level := TierPlace.backstop_sink_level()
	print("  flags: FP_FARRING_LEVEL=%s FP_FARRING_CULL_COVERED=%s level_on=%s | full sink=%.2f  LEVEL sink=%.2f blocks (R=%.0f)" % [
		str(CubeSphere.FP_FARRING_LEVEL), str(CubeSphere.FP_FARRING_CULL_COVERED), str(TierPlace.level_on()),
		full, level, FA.R_BLOCKS])

	_gate_dep(active, full, level)
	var sel := _select_curved_facets(M_FACETS, active)
	print("  selected %d curvature facets: %s" % [sel.size(), str(sel)])
	_gate_noprot(active, sel, level, full)
	_gate_seam(active, sel, full, level)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# =====================================================================================================
# G-LV-DEP — the dependency (requires U2) + the runtime self-disable (requires a valid coverage probe).
# =====================================================================================================
func _gate_dep(active: int, full: float, level: float) -> void:
	print("  --- G-LV-DEP: requires U2 + self-disables without a valid coverage probe ---")
	# Static flag-level dependency: level_on() is the conjunction of the two flags (U3 requires U2).
	_ok(TierPlace.level_on() == (CubeSphere.FP_FARRING_LEVEL and CubeSphere.FP_FARRING_CULL_COVERED),
		"level_on() == (FP_FARRING_LEVEL ∧ FP_FARRING_CULL_COVERED) — U3 gated on U2")
	# The reduction is REAL: the level sink is the small ε guard, strictly below the full ~13-block visual sink.
	_ok(level < full and level >= TierPlace.ENV_EPS_G,
		"backstop_sink_level (%.2f) < backstop_sink (%.2f) and ≥ ENV_EPS_G (%.2f) — real collapse to the ε guard" % [
			level, full, TierPlace.ENV_EPS_G])

	# Runtime self-disable — reconstruct the SAME dense backstop cache on two rings and compare the applied sink.
	var fid := active
	# (a) NO cover query ⇒ _level_on() false ⇒ the FULL sink is applied (inert; today's behaviour on the fallback path).
	var ring_off: Node3D = _mk_ring(active)
	_ok(not ring_off._level_on(), "no coverage probe ⇒ _level_on() false (INERT — self-disables to today's sink)")
	ring_off._ensure_backstop_cached(fid)
	var raw: PackedVector3Array = ring_off.backstop_raw_positions(fid)
	var rend_off: PackedVector3Array = ring_off.backstop_rendered_positions(fid)
	var off_sink := _mean_radial_offset(raw, rend_off)
	_ok(absf(off_sink - full) < 0.05,
		"INERT ring applies the FULL sink (%.2f ≈ backstop_sink %.2f)" % [off_sink, full])
	ring_off.free()

	# (b) VALID cover query ⇒ _level_on() true ⇒ the LEVEL sink is applied (U3 active).
	var ring_on: Node3D = _mk_ring(active)
	ring_on.set_cover_query(Callable(self, "_cover_true"))
	_ok(ring_on._level_on(), "valid coverage probe + both flags ⇒ _level_on() true (U3 active)")
	ring_on._ensure_backstop_cached(fid)
	var raw2: PackedVector3Array = ring_on.backstop_raw_positions(fid)
	var rend_on: PackedVector3Array = ring_on.backstop_rendered_positions(fid)
	var on_sink := _mean_radial_offset(raw2, rend_on)
	_ok(absf(on_sink - level) < 0.05,
		"ACTIVE ring applies the LEVEL sink (%.2f ≈ backstop_sink_level %.2f) — far at the near level" % [on_sink, level])
	print("    applied radial sink: inert(no-probe)=%.2f  active(U3)=%.2f  (full=%.2f level=%.2f)" % [
		off_sink, on_sink, full, level])
	ring_on.free()

# =====================================================================================================
# G-LV-NOPROT — RADIALLY, the LEVEL far ring never rises above the near true surface beyond the ε guard. The comparison
# is r_far vs r_near at the SAME in-plane param (the radial-vs-normal skew is U3's depth-bias job, not the sink's). Atop
# the deployed FP_ENV_ALL min-envelope the far cell is a lower bound, so the small guard suffices; FALSIFIED by the
# un-enveloped chord (reconstructed in-gate), which protrudes radially past the guard.
# =====================================================================================================
func _gate_noprot(active: int, sel: Array, level: float, full: float) -> void:
	print("  --- G-LV-NOPROT: LEVEL far ring radially ≤ near truth + ε at the SEAM; bounded on curvature (%d dirs each) ---" % N_PROBE)
	if not TierPlace.env_all_on():
		print("    NOTE: FP_ENV_ALL off — the radial no-protrusion needs the min-envelope (see RUN set).")
	var ring: Node3D = _mk_ring(active)
	ring.set_cover_query(Callable(self, "_cover_true"))       # engage the LEVEL sink (U3 active)
	_ok(ring._level_on(), "G-LV-NOPROT: ring on the U3 level path")
	var eps: float = TierPlace.ENV_EPS_G
	# (A) At the near/far SEAM (the active facet + its ring-1 neighbours — the transition the player crosses, representative
	# terrain), the LEVEL far ring radius ≤ near true surface radius + ε: the far meets the near flush with no protrusion.
	var seam := [active]
	for slot in range(4):
		var nb := FA.seam_neighbour(active, slot)
		if nb >= 0 and not seam.has(nb):
			seam.append(nb)
	var seam_worst := -1.0e30
	var seam_fid := -1
	for fid in seam:
		var sp: PackedVector3Array = ring.backstop_rendered_positions(fid)          # min-envelope − LEVEL sink
		var m := _radial_probe(fid, sp, CubeSphere.BACKSTOP_CELLS, N_PROBE)
		if m > seam_worst:
			seam_worst = m; seam_fid = fid
	_ok(seam_worst <= eps,
		"G-LV-NOPROT: SEAM far radius ≤ near truth + ε (worst radial protrusion %+.2f ≤ %.2f, facet %d)" % [seam_worst, eps, seam_fid])
	# (B) On the globally-WORST curvature facets, the LEVEL protrusion is a small BOUNDED sub-cell decimation residual —
	# strictly within the band the deployed full sink reserved (≤ full_sink), so U2's cull (culled ⊆ covered, G-CV-SAFE)
	# and the FAR_BIAS_K depth bias hide it. FALSIFIED against the un-enveloped chord (reconstructed in-gate), which
	# protrudes far worse: the min-envelope + level guard is load-bearing.
	var worst := -1.0e30
	var worst_fid := -1
	var chord_worst := -1.0e30
	var chord_fid := -1
	for fid in sel:
		var lp: PackedVector3Array = ring.backstop_rendered_positions(fid)
		var m := _radial_probe(fid, lp, CubeSphere.BACKSTOP_CELLS, N_PROBE)
		if m > worst:
			worst = m; worst_fid = fid
		var chord := _exact_positions(fid, CubeSphere.BACKSTOP_CELLS, 0.0)           # raw chord, no min, no sink
		var cm := _radial_probe(fid, chord, CubeSphere.BACKSTOP_CELLS, N_PROBE)
		if cm > chord_worst:
			chord_worst = cm; chord_fid = fid
	_ok(worst < full,
		"G-LV-NOPROT-BOUNDED: worst curvature LEVEL protrusion %+.2f < full sink %.2f — within the deployed sink band (U2 cull + depth bias hide it, facet %d)" % [
			worst, full, worst_fid])
	_ok(chord_worst > worst,
		"G-LV-NOPROT-GUARD: the un-enveloped chord protrudes worse (%+.2f > %+.2f) — the min-envelope + level guard is load-bearing (facet %d)" % [
			chord_worst, worst, chord_fid])
	print("    SEAM worst = %+.2f (≤ %.2f); curvature LEVEL worst = %+.2f (< %.2f); un-enveloped chord CONTRAST = %+.2f" % [
		seam_worst, eps, worst, full, chord_worst])
	ring.free()

# =====================================================================================================
# G-LV-SEAM — the far cell top meets the near terrain FLUSH (same level within the guard). Isolated to the SINK (not
# the inherent decimation chord error) by comparing at the GRID VERTICES, where the far cache is an EXACT profile
# sample: far_level top radius == near block top within level_sink + 1-block RELIEF quantization — NOT the ~13-block
# full-sink step (the contrast the U3 stage removes).
# =====================================================================================================
func _gate_seam(active: int, sel: Array, full: float, level: float) -> void:
	print("  --- G-LV-SEAM: far cell top flush with the near block top within the guard (not the %.1f-block sink) ---" % full)
	var ring: Node3D = _mk_ring(active)
	ring.set_cover_query(Callable(self, "_cover_true"))
	# Seam-adjacent facets: the active facet's ring-1 neighbours (where near meets far) + the curvature set.
	var probe := []
	for slot in range(4):
		var nb := FA.seam_neighbour(active, slot)
		if nb >= 0 and not probe.has(nb):
			probe.append(nb)
	for f in sel:
		if not probe.has(int(f)):
			probe.append(int(f))
	var worst_off := 0.0                                      # per-vertex |applied offset − level_sink| (uniform ε)
	var worst_gap := 0.0                                      # far LEVEL top vs near block top (g+1) at each vertex
	var worst_gap_fid := -1
	var worst_full_gap := 0.0                                 # CONTRAST: far FULL-sink top vs near block top (the step)
	for fid in probe:
		ring._ensure_backstop_cached(fid)
		var raw: PackedVector3Array = ring.backstop_raw_positions(fid)       # exact profile-sample surface (sink 0)
		var lvl: PackedVector3Array = ring.backstop_rendered_positions(fid)  # LEVEL sink applied
		for i in range(raw.size()):
			var raw_r := raw[i].length()                                     # near surface radius at this vertex dir
			var near_top := raw_r + 1.0                                       # near block top = one block above the sample
			# (1) the applied radial offset is EXACTLY the level sink at every vertex (uniform ε, not a deep sink).
			worst_off = maxf(worst_off, absf((raw_r - lvl[i].length()) - level))
			# (2) the far LEVEL top sits within level_sink + quantization of the near block top → flush, same level.
			var gap := absf(near_top - lvl[i].length())
			if gap > worst_gap:
				worst_gap = gap; worst_gap_fid = fid
			# CONTRAST: the shipped FULL sink leaves the far top ≈ full sink below the near top (the visible step).
			worst_full_gap = maxf(worst_full_gap, absf(near_top - (raw_r - full)))
	var quant := 1.0                                          # near block top is quantized to whole blocks (g+1)
	var flush_tol := level + quant + 0.25                     # same level within the guard + 1-block RELIEF quantization
	_ok(worst_off < 1.0e-2,
		"G-LV-SEAM: applied radial offset == level_sink at every vertex (worst dev %.4f < 1e-2)" % worst_off)
	_ok(worst_gap <= flush_tol,
		"G-LV-SEAM: far cell top FLUSH with near block top (worst gap %.2f ≤ %.2f = level %.2f + quant %.1f, facet %d)" % [
			worst_gap, flush_tol, level, quant, worst_gap_fid])
	# The full-sink contrast MUST show a real step the guard-level does not — proves U3 removed a visible sink.
	_ok(worst_full_gap > flush_tol,
		"G-LV-SEAM-CONTRAST: the FULL sink leaves a %.1f-block step (%.2f > %.2f) — U3 collapses it to the guard" % [
			full, worst_full_gap, flush_tol])
	print("    offset dev = %.4f ; far-top gap LEVEL = %.2f (≤ %.2f) ; full-sink CONTRAST = %.2f blocks" % [
		worst_off, worst_gap, flush_tol, worst_full_gap])
	ring.free()

# --------------------------------- reconstruction / probe helpers (mirror verify_no_protrusion) ---------------------------------

## Mean radial pushdown (blocks) between a raw cache `a` and a sunk cache `b` = mean(|a_i| − |b_i|) — the applied sink.
func _mean_radial_offset(a: PackedVector3Array, b: PackedVector3Array) -> float:
	if a.size() == 0 or a.size() != b.size():
		return -1.0
	var s := 0.0
	for i in range(a.size()):
		s += a[i].length() - b[i].length()
	return s / float(a.size())

## Worst positive RADIAL margin (r_far − r_near) over N random interior points of facet `fid`. Bilerp the far grid to an
## interior point (radius r_far), reconstruct the near TRUE surface radius at the SAME planar param (the facet's planar
## anchor + radial relief from the one generator, profile_at_dir), and compare radii. margin > 0 ⇔ the far cell rises
## above the near surface radially. This is the design's radial comparison — the radial-vs-normal skew is excluded.
func _radial_probe(fid: int, gp: PackedVector3Array, cells: int, n: int) -> float:
	var c0 := FA.facet_planar_corner(fid, 0)
	var c1 := FA.facet_planar_corner(fid, 1)
	var c2 := FA.facet_planar_corner(fid, 2)
	var c3 := FA.facet_planar_corner(fid, 3)
	var worst := -1.0e30
	for i in range(n):
		var s := _rng.randf() * float(cells)
		var t := _rng.randf() * float(cells)
		var P := _bilerp_vec3(gp, cells, s, t)
		var r_far := P.length()
		# near true surface radius at the SAME planar param (s,t normalized to 0..1).
		var us := s / float(cells)
		var vt := t / float(cells)
		var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], us, vt)
		var by := _bilerp(c0[1], c1[1], c2[1], c3[1], us, vt)
		var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], us, vt)
		var bln := sqrt(bx * bx + by * by + bz * bz)
		var dx := bx / bln; var dy := by / bln; var dz := bz / bln
		var g := int(TerrainConfig.profile_at_dir(dx, dy, dz, FA.R_BLOCKS).x)
		var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL))
		var nx := bx + dx * relief; var ny := by + dy * relief; var nz := bz + dz * relief
		var r_near := sqrt(nx * nx + ny * ny + nz * nz)
		var margin := r_far - r_near
		if margin > worst:
			worst = margin
	return worst

## The plain EXACT-height chord for facet `fid` (profile_at_dir per grid vertex, radial relief, pushed in by `sink`) —
## the shipped un-enveloped placement, reconstructed in-gate as the radial-protrusion contrast (independent of any flag).
func _exact_positions(fid: int, cells: int, sink: float) -> PackedVector3Array:
	var c0 := FA.facet_planar_corner(fid, 0)
	var c1 := FA.facet_planar_corner(fid, 1)
	var c2 := FA.facet_planar_corner(fid, 2)
	var c3 := FA.facet_planar_corner(fid, 3)
	var stride := cells + 1
	var out := PackedVector3Array()
	out.resize(stride * stride)
	for gj in range(stride):
		for gi in range(stride):
			var s := float(gi) / float(cells)
			var t := float(gj) / float(cells)
			var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
			var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
			var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
			var ln := sqrt(bx * bx + by * by + bz * bz)
			var dx := bx / ln; var dy := by / ln; var dz := bz / ln
			var g := int(TerrainConfig.profile_at_dir(dx, dy, dz, FA.R_BLOCKS).x)
			var relief := maxf(0.0, float(g - TerrainConfig.SEA_LEVEL))
			var vx := bx + dx * relief; var vy := by + dy * relief; var vz := bz + dz * relief
			var vln := sqrt(vx * vx + vy * vy + vz * vz)
			out[gj * stride + gi] = Vector3(vx - vx / vln * sink, vy - vy / vln * sink, vz - vz / vln * sink)
	return out

## Light ring init (mirrors verify_no_protrusion): seed exactly the role state _is_backstop reads (active + sticky
## ring-1). The lazy cache accessors build only the facets we probe.
func _mk_ring(active: int) -> Node3D:
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.set("_active_fid", active)
	ring.call("_recompute_sticky")
	return ring

## SELECT the M worst facets by profile CURVATURE (concave sag) — where the between-sample chord over-estimates and
## the guard-dropped raw surface pokes. Excludes the active facet + its 4 seam neighbours. (Mirrors verify_no_protrusion.)
func _select_curved_facets(m: int, active: int) -> Array:
	var avoid := {active: true}
	for slot in range(4):
		var nb := FA.seam_neighbour(active, slot)
		if nb >= 0:
			avoid[nb] = true
	var k := FA.K
	var ng := 5
	var ranked := []
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				if avoid.has(fid):
					continue
				var grid := []
				grid.resize(ng * ng)
				var lo := 1 << 30
				var hi := -(1 << 30)
				for gj in range(ng):
					for gi in range(ng):
						var g := _g_at(_col_dir(fid, float(gi) / float(ng - 1), float(gj) / float(ng - 1)))
						grid[gj * ng + gi] = g
						lo = mini(lo, g); hi = maxi(hi, g)
				var curv := 0
				for gj in range(ng):
					for gi in range(1, ng - 1):
						curv = maxi(curv, abs(grid[gj * ng + gi - 1] - 2 * grid[gj * ng + gi] + grid[gj * ng + gi + 1]))
				for gi in range(ng):
					for gj in range(1, ng - 1):
						curv = maxi(curv, abs(grid[(gj - 1) * ng + gi] - 2 * grid[gj * ng + gi] + grid[(gj + 1) * ng + gi]))
				ranked.append([curv * 8 + (hi - lo), fid])
	ranked.sort_custom(func(x, y): return x[0] > y[0])
	var out := []
	for i in range(mini(m, ranked.size())):
		out.append(int(ranked[i][1]))
	return out

static func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

func _bilerp_vec3(gp: PackedVector3Array, cells: int, s: float, t: float) -> Vector3:
	var stride := cells + 1
	var fs := clampf(s, 0.0, float(cells))
	var ft := clampf(t, 0.0, float(cells))
	var ci := mini(int(fs), cells - 1)
	var cj := mini(int(ft), cells - 1)
	var ls := fs - float(ci)
	var lt := ft - float(cj)
	var v00 := gp[cj * stride + ci]
	var v10 := gp[cj * stride + ci + 1]
	var v11 := gp[(cj + 1) * stride + ci + 1]
	var v01 := gp[(cj + 1) * stride + ci]
	return v00 * (1.0 - ls) * (1.0 - lt) + v10 * ls * (1.0 - lt) + v11 * ls * lt + v01 * (1.0 - ls) * lt

func _g_at(d: Vector3) -> int:
	return int(TerrainConfig.profile_at_dir(d.x, d.y, d.z, FA.R_BLOCKS).x)

func _col_dir(fid: int, s: float, t: float) -> Vector3:
	var c0 := FA.facet_planar_corner(fid, 0)
	var c1 := FA.facet_planar_corner(fid, 1)
	var c2 := FA.facet_planar_corner(fid, 2)
	var c3 := FA.facet_planar_corner(fid, 3)
	var bx := _bilerp(c0[0], c1[0], c2[0], c3[0], s, t)
	var by := _bilerp(c0[1], c1[1], c2[1], c3[1], s, t)
	var bz := _bilerp(c0[2], c1[2], c2[2], c3[2], s, t)
	return Vector3(bx, by, bz).normalized()
