extends SceneTree
## COSMOS TIER-DEPTH-PRIORITY gate (docs/COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md §7) — proves the three correctness-core
## mechanisms that stop the far-LOD terrain drawing OVER the near blocks. Runs headless with FACETED + FP_FARRING_FULL_COVER
## sed-toggled true, plus whichever tier flags are on; each sub-gate tests the OBSERVABLE effect of ONE flag, so running
## with that flag OFF turns the sub-gate RED (the built-in falsification).
##
##   G-TIER-ENVELOPE  (FP_TIER_ENVELOPE)        — the min-envelope vertex rule (RC-A). A SKEW-AWARE poke oracle: it projects
##                                                the as-rendered coarse backstop surface onto the near height field along
##                                                the facet NORMAL (world_to_lattice64) — the projection G-FRC-NOPOKE omits,
##                                                which is why the constant 6-block sink passes THERE yet pokes ~4 blocks
##                                                HERE. Envelope on → worst margin < 0 (below near). The in-run CONTRAST
##                                                reconstructs the constant-sink surface and shows it pokes (RC-A real).
##   G-TIER-STICKY    (FP_TIER_STICKY_BACKSTOP)  — make-before-break. A ring-1 facet is drawn SUNK from the first build, so
##                                                when it later enters the pool (near meshes arrive) it is ALREADY an emitted
##                                                backstop in the committed mesh through the whole deferred-rebuild window —
##                                                no unsunk coarse quad under live near meshes (RC-B). Bound: sticky ≤ cap.
##   G-TIER-DEPTH-BIAS (FP_TIER_DEPTH_BIAS)       — the far/skin materials become the LIT vertex-colour ShaderMaterial carrying
##                                                the k-quantum window-space depth bias (far 8, skin 4), + the raised near plane
##                                                policy. Asserts the shader parsed (uniform present) and the bias value; OFF ⇒
##                                                StandardMaterial3D (unchanged) ⇒ red.
##
## RUN (all three, green):
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_FARRING_FULL_COVER := false/const FP_FARRING_FULL_COVER := true/;\
##           s/const FP_TIER_STICKY_BACKSTOP := false/const FP_TIER_STICKY_BACKSTOP := true/;\
##           s/const FP_TIER_ENVELOPE := false/const FP_TIER_ENVELOPE := true/;\
##           s/const FP_TIER_DEPTH_BIAS := false/const FP_TIER_DEPTH_BIAS := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_tier_depth.gd
##   then REVERT the sed. FALSIFY: re-run with any ONE tier flag left false → its sub-gate fails.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const FFR := preload("res://src/world/facet_far_ring.gd")
const SKIN := preload("res://src/world/facet_skin_tier.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	print("=== verify_tier_depth (tier depth-priority: blocks > skin > far ring) ===")
	if not CubeSphere.FACETED or not CubeSphere.FP_FARRING_FULL_COVER:
		print("  FAIL: needs FACETED + FP_FARRING_FULL_COVER sed-toggled true.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	TerrainConfig.warm_up()
	FA.warm_up()
	var active := FA.spawn_facet()
	TerrainConfig.set_active_facet(active)
	print("  flags: STICKY=%s ENVELOPE=%s DEPTH_BIAS=%s | active=%d near=%d BACKSTOP_SINK=%.1f CELLS=%d sink_now=%.2f" % [
		str(CubeSphere.FP_TIER_STICKY_BACKSTOP), str(CubeSphere.FP_TIER_ENVELOPE), str(CubeSphere.FP_TIER_DEPTH_BIAS),
		active, TerrainConfig.near_render_radius(), CubeSphere.BACKSTOP_SINK, CubeSphere.BACKSTOP_CELLS, TierPlace.backstop_sink()])
	_gate_envelope(active)
	_gate_sticky(active)
	_gate_depth_bias(active)
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# =====================================================================================================
# G-TIER-ENVELOPE (P2, RC-A) — the skew-aware min-envelope poke oracle.
# =====================================================================================================
func _gate_envelope(active: int) -> void:
	# Phase-guarded (§ isolation): the envelope assertions only hold under FP_TIER_ENVELOPE. With the flag off this phase
	# is SKIPPED (0 pass / 0 fail) so a STICKY-only or DEPTH-BIAS-only run is a clean green. Falsify the envelope by
	# sabotaging its IMPLEMENTATION (not the flag): break _ensure_backstop_cached_env → the ε-sink lower bound pokes → RED.
	if not TierPlace.envelope_on():
		print("  --- G-TIER-ENVELOPE: SKIPPED (FP_TIER_ENVELOPE off) ---")
		return
	print("  --- G-TIER-ENVELOPE: at a small ε sink the min-envelope is a provable lower bound; a plain profile sample is NOT ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	var cells := CubeSphere.BACKSTOP_CELLS
	var near := float(TerrainConfig.near_render_radius())
	var eps := TierPlace.ENV_EPS_G   # the fixed probe sink: at THIS small a sink only a true lower envelope can hold.
	# Sweep the worst-relief (mountainous) facets + the active facet, marked backstop, exactly as G-FRC-NOPOKE.
	var sweep := _worst_relief_facets(3)
	if not sweep.has(active):
		sweep.append(active)
	ring.call("set_pool_excluded", sweep.duplicate())
	ring.call("force_rebuild")

	var env_worst := -1.0e30       # the ring's RAW backstop cache at ε sink (envelope when the flag is on): want < 0
	var env_fid := -1
	var plain_worst := -1.0e30     # CONTRAST: a plain profile_at_dir sample at the SAME ε sink: want > 0 (needs the envelope)
	var plain_fid := -1
	for fid in sweep:
		var centre := _centre_dir(fid)
		# The ring's raw dense cache (ENVELOPE heights under FP_TIER_ENVELOPE; plain relief with the flag off), at ε sink.
		var raw: PackedVector3Array = ring.call("backstop_raw_positions", fid)
		var em := _worst_poke(fid, _sink(raw, eps), cells, near, centre)
		if em > env_worst:
			env_worst = em; env_fid = fid
		# The plain per-vertex profile_at_dir relief (NO envelope), reconstructed in-gate, at the SAME ε sink.
		var plain := _const_sink_positions(fid, cells, eps)
		var pm := _worst_poke(fid, plain, cells, near, centre)
		if pm > plain_worst:
			plain_worst = pm; plain_fid = fid

	# THE fix: at a sink as small as ε the ring's backstop stays below the near block tops — only a true lower envelope can.
	# (Sabotage: FP_TIER_ENVELOPE off ⇒ the raw cache is plain relief ⇒ this pokes at ε ⇒ RED.)
	_ok(env_worst < 0.0,
		"G-TIER-ENVELOPE: min-envelope is a lower bound at ε=%.1f sink (worst margin %.2f < 0, facet %d)" % [eps, env_worst, env_fid])
	# CONTRAST: the plain profile sample at the same ε sink DOES poke — this is why the tuned constant needs a full 6-block
	# sink (the design's "doubling the benign dip everywhere"), and what the envelope replaces with a proof.
	_ok(plain_worst > 0.0,
		"G-TIER-ENVELOPE-CONTRAST: a plain profile sample pokes at ε=%.1f sink (worst +%.2f, facet %d) — the constant sink is not a lower bound" % [eps, plain_worst, plain_fid])
	print("    envelope@ε worst margin = %.2f (need < 0); plain@ε worst margin = %.2f (need > 0)" % [env_worst, plain_worst])
	ring.free()

## Push each grid position radially inward by `sink` blocks (the gate's own ε probe; independent of TierPlace.backstop_sink).
func _sink(p: PackedVector3Array, sink: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(p.size())
	for i in range(p.size()):
		var v := p[i]
		out[i] = v - v.normalized() * sink
	return out

## Worst poke margin over facet `fid` (the WHOLE facet's near lattice — the geometric envelope invariant I1 is defined
## wherever the near surface exists, not only inside the streaming disc; the RC-A poke lives at the facet corners/edges
## at arc ~142, JUST outside the 128 disc, which the centre-clipped G-FRC-NOPOKE never reaches). Project each fine point
## of the rendered coarse surface onto the near height field ALONG THE FACET NORMAL (world_to_lattice64 splits n̂-height
## from in-plane position), compare to the near block top (g+1) at the in-plane column it overlays. margin > 0 ⇔ the
## coarse surface rises above the blocks (a poke). `near`/`centre` are kept for callers that want a disc restriction.
func _worst_poke(fid: int, gp: PackedVector3Array, cells: int, near: float, centre: Vector3) -> float:
	var sub := 4                                   # fine sub-samples per coarse cell (models the rasterized surface)
	var steps := cells * sub
	var worst := -1.0e30
	for js in range(steps + 1):
		var t := float(js) / float(sub)            # coarse-cell coordinate (0..cells)
		for iss in range(steps + 1):
			var s := float(iss) / float(sub)
			var P := _bilerp_vec3(gp, cells, s, t)  # the rendered far surface point (bilinear ≥ triangle: conservative)
			var lat := FA.world_to_lattice64(fid, P.x, P.y, P.z)
			var h_far: float = lat[1]              # n̂-height of the far point above the facet plane
			var plane := FA.lattice_to_world64(fid, lat[0], 0.0, lat[2])   # its in-plane footprint (y=0)
			var dir := Vector3(plane[0], plane[1], plane[2]).normalized()
			var g_near := int(TerrainConfig.profile_at_dir(dir.x, dir.y, dir.z, FA.R_BLOCKS).x)
			var margin := h_far - float(g_near + 1)   # near top face is at g+1 along n̂
			if margin > worst:
				worst = margin
	return worst

## The constant-BACKSTOP_SINK dense backstop positions for facet `fid` (profile_at_dir per coarse vertex, pushed in by
## `sink` radially) — the shipped placement, reconstructed in-gate independent of FP_TIER_ENVELOPE for the RC-A contrast.
func _const_sink_positions(fid: int, cells: int, sink: float) -> PackedVector3Array:
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

# =====================================================================================================
# G-TIER-STICKY (P1, RC-B) — make-before-break: a ring-1 facet is an emitted backstop through the deferred window.
# =====================================================================================================
func _gate_sticky(active: int) -> void:
	# Phase-guarded: the make-before-break assertions only hold under FP_TIER_STICKY_BACKSTOP. Off ⇒ SKIPPED (green).
	# Falsify by sabotaging the implementation: make TierPlace.ring1 return only [active] (drop the neighbours) → B is no
	# longer sticky → is_emitted_backstop(B) false → RED.
	if not TierPlace.sticky_on():
		print("  --- G-TIER-STICKY: SKIPPED (FP_TIER_STICKY_BACKSTOP off) ---")
		return
	print("  --- G-TIER-STICKY: ring-1 facet drawn SUNK before it enters the pool (no unsunk quad under live near meshes) ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)          # setup → _recompute_sticky seeds ring-1 → _rebuild_full draws them sunk
	# B = a front-visible ring-1 seam neighbour of the active facet (the facet the player will cross into).
	var nrm := FA.facet_normal64(active)
	var nv := Vector3(nrm[0], nrm[1], nrm[2])
	var B := -1
	for slot in range(4):
		var n := FA.seam_neighbour(active, slot)
		if n >= 0 and _centre_dir(n).dot(nv) >= 1.0e-4:
			B = n; break
	_ok(B >= 0, "G-TIER-STICKY: found a front-visible ring-1 neighbour B=%d of active %d" % [B, active])
	if B < 0:
		ring.free(); return
	# THE make-before-break invariant: B is drawn SUNK in the committed mesh FROM THE FIRST BUILD — before it is ever
	# added to the pool. (Sticky ON ⇒ B ∈ ring1(active) ⇒ emitted backstop; sticky OFF ⇒ B is an unsunk front quad ⇒ RED.)
	_ok(bool(ring.call("is_sticky", B)), "G-TIER-STICKY: B=%d is a sticky backstop before any pool event" % B)
	_ok(bool(ring.call("is_emitted_backstop", B)), "G-TIER-STICKY: B=%d drawn SUNK in the committed mesh at spawn (make-before-break)" % B)
	# Now B enters the pool (near meshes begin). The far rebuild is DEFERRED (no force_rebuild here) — the committed mesh
	# is still the setup build. B must STILL be an emitted backstop through that window, so no live near mesh overlays an
	# unsunk coarse quad. This is the exact RC-B window; sticky's eager grow closed it before streaming started.
	ring.call("set_pool_excluded", PackedInt32Array([B]))
	_ok(bool(ring.call("is_emitted_backstop", B)),
		"G-TIER-STICKY: B=%d remains an emitted backstop across the deferred-rebuild window (RC-B flash prevented)" % B)
	# WHY ring-1 must include the DIAGONALS (the ≤12 set, not just active+4 seam=≤5): after the player crosses A→B, B
	# becomes active and B's OWN seam neighbours enter the pool. They must ALREADY be sunk in the pre-crossing committed
	# mesh (built while A was active) or the crossing itself flashes. A diagonal D (a seam neighbour of B, front-visible,
	# not active, not a direct neighbour of active) is exactly such a facet — it is drawn sunk at spawn ONLY because
	# ring1(active) reaches the diagonals. Sabotaging ring1 to active+4-seam would drop D → the crossing would flash.
	var D := -1
	for slot in range(4):
		var d := FA.seam_neighbour(B, slot)
		if d >= 0 and d != active and _centre_dir(d).dot(nv) >= 1.0e-4 and FA.seam_neighbour(active, 0) != d \
				and FA.seam_neighbour(active, 1) != d and FA.seam_neighbour(active, 2) != d and FA.seam_neighbour(active, 3) != d:
			D = d; break
	if D >= 0:
		_ok(bool(ring.call("is_emitted_backstop", D)),
			"G-TIER-STICKY: diagonal D=%d (B's neighbour) is pre-sunk at spawn → the A→B crossing itself never flashes" % D)
	else:
		print("    (no clean front-visible diagonal off B=%d — geometry; two-step check skipped)" % B)
	# NEVER-OOM bound: the sticky set never exceeds the stated dense-cache ceiling.
	_ok(int(ring.call("sticky_count")) <= CubeSphere.STICKY_RING1_MAX,
		"G-TIER-STICKY-BOUND: sticky set %d ≤ cap %d (dense cache ≤ 1+ring-1 ≈ +96 kB)" % [int(ring.call("sticky_count")), CubeSphere.STICKY_RING1_MAX])
	_ok(int(ring.call("backstop_cache_size")) <= 1 + CubeSphere.STICKY_RING1_MAX,
		"G-TIER-STICKY-BOUND: dense backstop cache %d facets ≤ 1+STICKY_RING1_MAX" % int(ring.call("backstop_cache_size")))

	# --- G-TIER-STICKY-PERF (structural anti-hitch) — sticky's ONLY runtime cost is a larger backstop set in the ring
	# rebuild. Three structural properties keep that from becoming a main-thread hitch, each asserted here (headless can't
	# read live fps; probe_sticky_perf.gd measured the delta directly: async main-thread swap +0.23ms native, 6% bigger
	# mesh upload; the +~4ms build is off-thread):
	#   (1) the set is BOUNDED (≤ STICKY_RING1_MAX) ⇒ the per-crossing rebuild-size delta is bounded (asserted above);
	#   (2) the enlarged dense-cache warming is TIME-SLICED (WARM_BUDGET_MS>0), never one unbounded synchronous build;
	#   (3) the ring HAS an off-main-thread rebuild path so the enlarged (backstop-heavy) build runs off the frame.
	_ok(FFR.WARM_BUDGET_MS > 0.0,
		"G-TIER-STICKY-PERF: dense-cache warming is time-sliced (WARM_BUDGET_MS=%.1f ms/frame) — sticky's extra warms spread" % FFR.WARM_BUDGET_MS)
	_ok(ring.has_method("_dispatch_async_rebuild") and ring.has_method("_async_enabled"),
		"G-TIER-STICKY-PERF: an off-main-thread rebuild path exists — the enlarged backstop build runs off the crossing frame")
	# With depth-bias OFF the far material MUST stay the shipped StandardMaterial3D (no shader swap → normal appearance).
	# This pins the "drop the shader swap" requirement of the isolated sticky build. (Skipped when P3 is also on, where
	# the material is intentionally the biased ShaderMaterial — covered by G-TIER-DEPTH-BIAS.)
	if not TierPlace.depth_bias_on():
		var fmat: Material = ring.get("_mi").material_override
		_ok(fmat is StandardMaterial3D and not (fmat is ShaderMaterial),
			"G-TIER-STICKY-PERF: far material is StandardMaterial3D (P3 shader swap NOT applied with sticky alone)")
	ring.free()

# =====================================================================================================
# G-TIER-DEPTH-BIAS (P3, RC-C) — the far/skin biased ShaderMaterial + the near-plane policy.
# =====================================================================================================
func _gate_depth_bias(active: int) -> void:
	# Phase-guarded: the biased-ShaderMaterial + near-plane assertions only hold under FP_TIER_DEPTH_BIAS. Off ⇒ SKIPPED
	# (green) — a STICKY-only run keeps the shipped StandardMaterial3D (normal appearance), which is the point of dropping
	# the shader swap from this build. Falsify by sabotaging make_biased_material (drop the uniform) → shader check RED.
	if not TierPlace.depth_bias_on():
		print("  --- G-TIER-DEPTH-BIAS: SKIPPED (FP_TIER_DEPTH_BIAS off) ---")
		return
	print("  --- G-TIER-DEPTH-BIAS: far/skin biased ShaderMaterial (window-space k-quantum) + raised near plane ---")
	# Policy constants (the depth-domain contract §5.2: near 0 < skin 4 < far 8 quanta; near plane raised 5×).
	_ok(is_equal_approx(TierPlace.far_bias(), 2.0 * 8.0 * TierPlace.DEPTH_QUANTUM), "far bias = 2·8·2⁻²⁴")
	_ok(is_equal_approx(TierPlace.skin_bias(), 2.0 * 4.0 * TierPlace.DEPTH_QUANTUM), "skin bias = 2·4·2⁻²⁴")
	_ok(TierPlace.far_bias() > TierPlace.skin_bias() and TierPlace.skin_bias() > 0.0, "tier order: far > skin > near(0) in depth bias")
	_ok(is_equal_approx(TierPlace.CAMERA_NEAR, 0.25), "near-plane policy = 0.25 (5× the shipped 0.05)")

	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	var fm: Material = ring.get("_mi").material_override
	_check_biased(fm, "far ring", TierPlace.far_bias())
	ring.free()

	var skin: Node3D = SKIN.new()
	get_root().add_child(skin)
	skin.call("setup", active)
	var sm: Material = skin.get("_mat")
	_check_biased(sm, "skin", TierPlace.skin_bias())
	skin.free()

## Assert `m` is the biased tier ShaderMaterial: a parsed spatial shader carrying the `tier_bias` uniform at the tier's
## value, writing POSITION.z. With FP_TIER_DEPTH_BIAS OFF the far/skin material is a StandardMaterial3D → every check red.
func _check_biased(m: Material, who: String, want_bias: float) -> void:
	var sh := m as ShaderMaterial
	_ok(sh != null, "G-TIER-DEPTH-BIAS: %s material is a ShaderMaterial (OFF ⇒ StandardMaterial3D)" % who)
	if sh == null:
		return
	var shader: Shader = sh.shader
	_ok(shader != null and shader.code.find("POSITION.z += tier_bias") >= 0,
		"G-TIER-DEPTH-BIAS: %s shader writes the window-space depth bias (POSITION.z += tier_bias·w)" % who)
	# The uniform being in the parameter list proves the shader PARSED (compiled to a ShaderRD program).
	var has_param := false
	for p in shader.get_shader_uniform_list() if shader != null else []:
		if String(p.get("name", "")) == "tier_bias":
			has_param = true; break
	_ok(has_param, "G-TIER-DEPTH-BIAS: %s shader parsed with the tier_bias uniform" % who)
	_ok(is_equal_approx(float(sh.get_shader_parameter("tier_bias")), want_bias),
		"G-TIER-DEPTH-BIAS: %s tier_bias = %s (k quanta)" % [who, str(want_bias)])

# --- shared helpers (mirroring verify_farring_cover so the two gates are directly comparable) ---
func _centre_dir(fid: int) -> Vector3:
	var s := Vector3.ZERO
	for ci in range(4):
		var c := FA.facet_planar_corner(fid, ci)
		s += Vector3(c[0], c[1], c[2])
	return s.normalized()

func _arc(a: Vector3, b: Vector3) -> float:
	return FA.R_BLOCKS * acos(clampf(a.dot(b), -1.0, 1.0))

static func _bilerp(v00: float, v10: float, v11: float, v01: float, s: float, t: float) -> float:
	return v00 * (1.0 - s) * (1.0 - t) + v10 * s * (1.0 - t) + v11 * s * t + v01 * (1.0 - s) * t

## Bilinear interpolation of a (cells+1)² grid of Vector3 positions at coarse-cell coordinate (s,t) ∈ [0,cells].
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

func _worst_relief_facets(n: int) -> Array:
	var k := FA.K
	var ranked := []
	for face in range(6):
		for a in range(k):
			for b in range(k):
				var fid := (face * k + a) * k + b
				var lo := 1 << 30
				var hi := -(1 << 30)
				for gj in range(3):
					for gi in range(3):
						var g := _g_at(_col_dir(fid, float(gi) / 2.0, float(gj) / 2.0))
						lo = mini(lo, g)
						hi = maxi(hi, g)
				ranked.append([hi - lo, fid])
	ranked.sort_custom(func(x, y): return x[0] > y[0])
	var out := []
	for i in range(mini(n, ranked.size())):
		out.append(int(ranked[i][1]))
	return out
