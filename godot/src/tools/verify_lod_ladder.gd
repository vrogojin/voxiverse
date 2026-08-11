extends SceneTree
## Task #107 N0 — G-LAD gate (docs/COSMOS-LOD-LADDER-MIDBAND-DESIGN.md §4), GATE-BEFORE-FIX baseline pin.
##
## Law-level reconstruction of the FRONTMOST terrain cover along the player→summit ray at the repro pose
## (facet 772, lattice -30970,7161). No scene / no rendering: each tier's residency + rendered height comes
## from its documented LAW, all heights from the ONE sampler (TerrainConfig.profile_at_dir), so the gate is
## deterministic and headless. PIN SEMANTICS (the FS0/verify_facet_seams pattern): this N0 gate exits 0 while
## TODAY's non-monotone ladder is measurably present — G-LAD-MONO-PIN (26-blk backstop frontmost on the pool
## shoulder, coarser than the 8-blk smooth tier BEHIND it) and G-LAD-SUMMIT-PIN (M2 ℓ3 quantized top protrudes
## above the smooth TIN at the fid-797 summit). When FP_SMOOTH_V2_NEARCOVER / FP_M2_SMOOTH_DEFER /
## FP_M2_EDGE_DIST land (N1/N1b), the pinned sub-gates flip to asserting the FIXED (monotone) ladder under
## flags-on, and this header is updated. If a pin goes green early, the ladder changed without this gate —
## investigate before trusting either state.
##
## Documented approximations (all conservative for the pin):
##  - Applied near-mesh reach = APPLIED_PROBE_MAX (112) horizontal blocks around the player (the probe's cap;
##    the live probed radius is ≤ this at settle).
##  - Smooth TIN height at a point = bilinear of its cell's 4 node heights (node = weld-law dir at V2_CELLS
##    grid, g via profile_at_dir). True TIN is the 2-triangle split of the same 4 nodes; |bilinear − TIN| is
##    bounded by the diagonal-split difference, ≪ the ≥2-block protrusion margin asserted.
##  - M2 megablock top at tier ℓ (pitch s=2^ℓ) = (floor(g_s/s)+1)·s with g_s the surface height at the
##    s-aligned sample column containing the point (generate_block at stride s samples the strided column;
##    the rendered top cell is the up-quantized multiple). Granted tier law = max(desired_tier, 3): the
##    budgeter's progressive first-cover floor (facet_lod_mesher.gd:333-338) — the pessimistic steady state
##    under load, which is exactly the live symptom being pinned.

const PFID := 772
const PX := -30970.0
const PZ := 7161.0
const APPLIED_R := 112.0            # APPLIED_PROBE_MAX — the near full-res reach law (see header)
# The PIN models the LIVE deploy fingerprint (2026-08-11 pck dump: FP_NB_FULLRES=true), NOT the repo's
# default-false consts — the symptom exists in the deployed config. When the N1 flags land, the flag-on
# sub-gates read the real CubeSphere consts instead.
const LIVE_NB_FULLRES := true
const M2_FIRST_COVER_TIER := 3      # budgeter max(target, l3) first-cover floor
const SUMMIT_G_CUT := 66            # the g>=66 summit cluster (measured: g 66-72 on fid 797)

var _fails := 0
var _checks := 0

func _init() -> void:
	FacetAtlas.warm_up()
	var pw := FacetAtlas.lattice_to_world64(PFID, PX, 50.0, PZ)
	var ppos := Vector3(pw[0], pw[1], pw[2])
	var hop := _hop_map(PFID, 6)
	var pool := _pool_set(PFID)
	# --- locate the summit (self-contained; mirrors probe_lod_ladder) ------------------------------------------
	var summit := _find_summit(ppos)
	_check("G-LAD-SCENE summit exists (g>=%d within 300..600 blk)" % SUMMIT_G_CUT, summit.size() > 0)
	if summit.is_empty():
		_finish()
		return
	var sfid := _owning_fid(summit[0], summit[1], summit[2], hop)
	var shop: int = hop.get(sfid, -1)
	print("summit: d=%.0f g=%d fid=%d hop=%d" % [summit[3], summit[4], sfid, shop])
	_check("G-LAD-SCENE summit on a hop-2 NON-pool facet (fid 797 class)", shop == 2 and not pool.has(sfid))
	# --- the rung table along the player->summit ray -----------------------------------------------------------
	var dir_l := Vector2(summit[5] - PX, summit[6] - PZ).normalized()   # lattice-plane ray direction
	var rows: Array = []
	for d in [60.0, 100.0, 130.0, 200.0, 300.0, 430.0, float(summit[3]), 600.0, 800.0]:
		rows.append(_rung_at(d, dir_l, hop, pool))
	print("rung table (d, fid, hop, tier, pitch):")
	for r in rows:
		print("  d=%4.0f fid=%d hop=%d cover=%s pitch=%.1f" % [r[0], r[1], r[2], r[3], r[4]])
	# G-LAD-MONO-PIN: today the pitch sequence toward the camera is NOT monotone — a pool-facet rung at
	# BACKSTOP pitch (26) sits IN FRONT of the smooth 8-blk rung. Assert the inversion is present.
	var inv := false
	for i in range(rows.size() - 1):
		if float(rows[i][4]) > float(rows[i + 1][4]) + 0.5:     # nearer row coarser than a farther row
			inv = true
	_check("G-LAD-MONO-PIN baseline inversion present (nearer rung coarser than farther)", inv)
	var shoulder_backstop := false
	for r in rows:
		if pool.has(int(r[1])) and String(r[3]) == "backstop" and absf(float(r[4]) - _backstop_pitch()) < 1.0:
			shoulder_backstop = true
	_check("G-LAD-MONO-PIN pool-facet rung IS the %.1f-blk backstop" % _backstop_pitch(), shoulder_backstop)
	# G-LAD-SUMMIT-PIN: at the summit sample, SmoothV2 is resident (hop in [V2_HOP_B..hop_h]) AND the M2
	# first-cover l3 quantized top protrudes >= 2 blocks above the smooth TIN interpolant.
	var v2_res := shop >= CubeSphere.V2_HOP_B and shop <= _v2_hop_h()
	var tin := _smooth_tin_g(sfid, summit[0], summit[1], summit[2])
	var m2top := _m2_top_g(sfid, summit[0], summit[1], summit[2], M2_FIRST_COVER_TIER)
	print("summit: smoothV2_resident=%s tin_g=%.2f m2_l3_top_g=%.2f (true g=%d)" % [str(v2_res), tin, m2top, summit[4]])
	_check("G-LAD-SUMMIT-PIN smooth tile resident on the summit facet", v2_res)
	_check("G-LAD-SUMMIT-PIN M2 l3 top protrudes >=2 blk above the smooth TIN", m2top >= tin + 2.0)
	# VIEWPORT INDEPENDENCE (twin review): the DESIRED SSE tier flips with the canvas (vh 540 vs 1080 gives
	# lc ~2.1 vs ~1.1 at the summit distance), but the PINNED granted law is max(desired, l3) — the budgeter's
	# first-cover floor — which dominates both. Assert that explicitly for BOTH capture geometries so the pin
	# can never silently depend on one canvas size; the N1 flag-on rows (where desired matters) must keep
	# testing both vh values.
	for vh in [540.0, 1080.0]:
		var lc := _sse_lc(summit[3], deg_to_rad(75.0), vh)
		var granted := maxi(clampi(int(floor(lc)), 1, 3), M2_FIRST_COVER_TIER)
		print("summit sse @vh=%d: lc=%.2f desired=l%d granted=l%d" % [int(vh), lc, clampi(int(floor(lc)), 1, 3), granted])
		_check("G-LAD-SUMMIT-PIN granted tier is l3 under vh=%d (first-cover floor dominates)" % int(vh),
				granted == M2_FIRST_COVER_TIER)
	_finish()

# --- the per-distance rung law (today's tiers; frontmost = highest rendered surface) --------------------------
## Returns [d, fid, hop, cover_name, pitch] for the sample point at lattice distance `d` along `dir_l`.
func _rung_at(d: float, dir_l: Vector2, hop: Dictionary, pool: Dictionary) -> Array:
	var lx := PX + dir_l.x * d
	var lz := PZ + dir_l.y * d
	var w := FacetAtlas.lattice_to_world64(PFID, lx, 0.0, lz)
	var fid := _owning_fid(w[0], w[1], w[2], hop)
	var h: int = hop.get(fid, -1)
	# near full-res: inside the applied reach AND on a live-pool facet (active or 4 edge neighbours)
	if d <= APPLIED_R and pool.has(fid):
		return [d, fid, h, "near", 1.0]
	# smooth v2 annulus (hop in [V2_HOP_B..hop_h]) — 8-blk relief TIN, draws over the shell
	if h >= CubeSphere.V2_HOP_B and h <= _v2_hop_h():
		# M2 also covers non-pool facets; it is frontmost only where its quantized top protrudes above the TIN —
		# per-point test (the summit sub-gate asserts the repro case explicitly; here it refines the rung).
		var tin := _smooth_tin_g(fid, w[0], w[1], w[2])
		var m2t := _m2_top_g(fid, w[0], w[1], w[2], M2_FIRST_COVER_TIER)
		if not pool.has(fid) and m2t >= tin + 2.0:
			return [d, fid, h, "m2_l%d" % M2_FIRST_COVER_TIER, float(1 << M2_FIRST_COVER_TIER)]
		return [d, fid, h, "smooth_v2", _facet_edge() / float(CubeSphere.V2_CELLS)]
	# live-pool facet beyond the applied reach (or hop-1 gap): the dense blocky backstop at 26-blk TRUE heights
	if pool.has(fid) or h <= 1:
		return [d, fid, h, "backstop", _backstop_pitch()]
	# beyond the annulus: M2 (first-cover l3) over the horizon quad
	return [d, fid, h, "m2_l%d" % M2_FIRST_COVER_TIER, float(1 << M2_FIRST_COVER_TIER)]

# --- tier height laws -----------------------------------------------------------------------------------------
## Smooth-V2 TIN height (g-space) at world point: bilinear of the 4 V2_CELLS-grid node heights of its cell.
func _smooth_tin_g(fid: int, wx: float, wy: float, wz: float) -> float:
	var cells: int = CubeSphere.V2_CELLS
	var cd := FacetAtlas.facet_corner_dirs(fid)
	var uv := _facet_param(fid, wx, wy, wz)
	var u := clampf(uv.x, 0.0, 0.9999) * float(cells)
	var v := clampf(uv.y, 0.0, 0.9999) * float(cells)
	var i := int(floor(u)); var j := int(floor(v))
	var fu := u - float(i);  var fv := v - float(j)
	var g00 := _node_g(cd, float(i) / cells, float(j) / cells)
	var g10 := _node_g(cd, float(i + 1) / cells, float(j) / cells)
	var g01 := _node_g(cd, float(i) / cells, float(j + 1) / cells)
	var g11 := _node_g(cd, float(i + 1) / cells, float(j + 1) / cells)
	return lerpf(lerpf(g00, g10, fu), lerpf(g01, g11, fu), fv)

## M2 megablock rendered top (g-space) at tier `l`: up-quantized surface of the s-aligned sample column.
func _m2_top_g(fid: int, wx: float, wy: float, wz: float, l: int) -> float:
	var s := 1 << l
	var lat := FacetAtlas.world_to_lattice64(fid, wx, wy, wz)
	var ax := float(int(floor(lat[0] / s)) * s + (s >> 1))   # strided sample column (cell centre)
	var az := float(int(floor(lat[2] / s)) * s + (s >> 1))
	var w2 := FacetAtlas.lattice_to_world64(fid, ax, 0.0, az)
	var ln := sqrt(w2[0] * w2[0] + w2[1] * w2[1] + w2[2] * w2[2])
	var g := TerrainConfig.profile_at_dir(w2[0] / ln, w2[1] / ln, w2[2] / ln, FacetAtlas.R_BLOCKS).x
	return float((int(floor(g / s)) + 1) * s)

func _node_g(cd: PackedFloat64Array, s: float, t: float) -> float:
	var ux := _bilerp(cd[0], cd[3], cd[6], cd[9], s, t)
	var uy := _bilerp(cd[1], cd[4], cd[7], cd[10], s, t)
	var uz := _bilerp(cd[2], cd[5], cd[8], cd[11], s, t)
	var ln := sqrt(ux * ux + uy * uy + uz * uz)
	return TerrainConfig.profile_at_dir(ux / ln, uy / ln, uz / ln, FacetAtlas.R_BLOCKS).x

## Facet param (u,v) in [0,1]^2 of a world point from its lattice coords vs the facet domain.
func _facet_param(fid: int, wx: float, wy: float, wz: float) -> Vector2:
	var lat := FacetAtlas.world_to_lattice64(fid, wx, wy, wz)
	var dmin := FacetAtlas.dom_min(fid)
	var dmax := FacetAtlas.dom_max(fid)
	return Vector2((lat[0] - float(dmin.x)) / float(dmax.x - dmin.x), (lat[2] - float(dmin.y)) / float(dmax.y - dmin.y))

# --- residency/topology helpers -------------------------------------------------------------------------------
func _v2_hop_h() -> int:
	return CubeSphere.V2_HOP_H_REACH if CubeSphere.FP_SMOOTH_V2_REACH else CubeSphere.V2_HOP_H

func _facet_edge() -> float:
	return (PI * 0.5 * FacetAtlas.R_BLOCKS) / float(FacetAtlas.K)

func _backstop_pitch() -> float:
	return _facet_edge() / float(CubeSphere.BACKSTOP_CELLS)

func _pool_set(active: int) -> Dictionary:
	var pool := {active: true}
	if LIVE_NB_FULLRES:
		for slot in range(4):
			var nb := FacetAtlas.seam_neighbour(active, slot)
			if nb >= 0:
				pool[nb] = true
	return pool

func _hop_map(active: int, max_hop: int) -> Dictionary:
	var hop := {active: 0}
	var frontier: Array = [active]
	for h in range(1, max_hop + 1):
		var next: Array = []
		for f in frontier:
			for slot in range(4):
				var nb := FacetAtlas.seam_neighbour(int(f), slot)
				if nb >= 0 and not hop.has(nb):
					hop[nb] = h
					next.append(nb)
		frontier = next
	return hop

func _owning_fid(wx: float, wy: float, wz: float, hop: Dictionary) -> int:
	for fid in hop.keys():
		var l := FacetAtlas.world_to_lattice64(int(fid), wx, wy, wz)
		if FacetAtlas.in_polygon(int(fid), int(round(l[0])), int(round(l[2])), 0.0):
			return int(fid)
	return -1

## Nearest g>=SUMMIT_G_CUT sample 300..600 blk out: [wx,wy,wz, d, g, lx,lz] or [] if terrain changed.
func _find_summit(ppos: Vector3) -> Array:
	var best: Array = []
	var best_d := 1.0e18
	var step := 12.0
	var n := int(600.0 / step)
	for iz in range(-n, n + 1):
		for ix in range(-n, n + 1):
			var dx := float(ix) * step
			var dz := float(iz) * step
			var r2 := dx * dx + dz * dz
			if r2 < 300.0 * 300.0 or r2 > 600.0 * 600.0:
				continue
			var w := FacetAtlas.lattice_to_world64(PFID, PX + dx, 0.0, PZ + dz)
			var ln := sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2])
			var g := int(TerrainConfig.profile_at_dir(w[0] / ln, w[1] / ln, w[2] / ln, FacetAtlas.R_BLOCKS).x)
			if g < SUMMIT_G_CUT:
				continue
			var sp := Vector3(w[0] / ln, w[1] / ln, w[2] / ln) * (FacetAtlas.R_BLOCKS + float(g))
			var d := ppos.distance_to(sp)
			if d < best_d:
				best_d = d
				best = [w[0], w[1], w[2], d, g, PX + dx, PZ + dz]
	return best

## Pure copy of FacetLodMesher.sse_lc (facet_lod_mesher.gd:230-233) — the M2 continuous SSE tier law.
func _sse_lc(d: float, fov_v_rad: float, viewport_h: float) -> float:
	var coeff := 2.0 * maxf(d, 1.0) * tan(fov_v_rad * 0.5) / maxf(viewport_h, 1.0)
	return log(CubeSphere.LOD_TAU_PX * coeff) / log(2.0)

static func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

func _check(name: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("PASS  %s" % name)
	else:
		_fails += 1
		print("FAIL  %s" % name)

func _finish() -> void:
	print("[verify_lod_ladder] %d/%d checks passed (PIN semantics: green = today's inversion measurably present)" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
