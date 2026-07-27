extends SceneTree
## COSMOS TEXTURED-LOD V4 gate (docs/COSMOS-TEXTURED-LOD-DESIGN.md §2V.2/§2V.5: FP_SKIN_SSE). Runs with FACETED = true
## (FLAT_WORLD = true) and FP_FACET_TEX + FP_SHELL_ABSOLUTE + FP_BLOCK_DETAIL + FP_FACET_TEX_CLOSEUP + FP_BAND_BLOCK_MAP +
## FP_SKIN_SSE sed-toggled ON. The V4 law replaces the REGIME-keyed skin fidelity (which DROPS every close-up promotion to
## the 26-blk biome-color base at surface entry — the user's Bug 1) with a continuous SCREEN-SPACE promotion ramp:
##
##   G-VD-MONO   — THE KEY ONE. A scripted PURE-VERTICAL descent from orbit to ground along the nadir facet's axis (the
##                 exact Bug-1 scenario: the axis is constant, only cam_dist shrinks). At each altitude the baker is
##                 settled and the RESOLVED skin fidelity tier of the nadir facet is sampled. Asserts it is MONOTONE
##                 NON-DECREASING across the whole descent (never regresses to a coarser tier / flat color) AND that it is
##                 a real RAMP (base→close-up→band, 1→2→3, not a constant). FALSIFY: re-invoking the deleted regime
##                 _evict_all_closeup at a mid-descent altitude REGRESSES the tier (2→≤1) — the assertion has teeth and the
##                 evict IS the bug.
##   G-VD-BUDGET — the per-frame promotion work stays bounded: across the descent driven at the REAL bake budget, the
##                 worst update() ≤ budget + one bake unit, and the promotions that turn resident per frame are bounded
##                 (no unbounded promotions/frame from the largest-deficit-first scan).
##   G-VD-OFF    — SAFE-DEGRADED / byte-identity: with cam_dist ≤ 0 (the shell driver never armed) the SSE law is INERT
##                 even under the flag → update() runs the shipped REGIME path (on-surface evict-all intact), so a build
##                 with the flag off is byte-identical (FLAT 6042/0 is the companion proof). With a real cam_dist the same
##                 on-surface call does NOT evict (the SSE path is live) — the two paths are cleanly separated.

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
	print("=== verify_skin_sse (TEXTURED-LOD V4 / FP_SKIN_SSE) ===")
	if not CubeSphere.FACETED or not CubeSphere.FLAT_WORLD:
		print("  FAIL: this gate must run with FACETED = true (FLAT_WORLD = true) — sed-toggled.")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	TC.warm_up()
	FA.warm_up()
	BlockCatalog.ensure_ready()
	FarPalette.ensure_ready()
	FarPalette.ensure_detail_ready()
	var fid := FA.spawn_facet()
	TC.set_active_facet(fid)
	var tex_on := CubeSphere.FP_FACET_TEX and CubeSphere.FP_SHELL_ABSOLUTE
	var cu_on := CubeSphere.FP_FACET_TEX_CLOSEUP
	var bm_on := CubeSphere.FP_BAND_BLOCK_MAP and CubeSphere.FP_BLOCK_DETAIL
	var sse_on := CubeSphere.FP_SKIN_SSE
	print("  flags FP_FACET_TEX=%s CLOSEUP=%s BAND=%s FP_SKIN_SSE=%s, spawn facet=%d (K=%d, R=%.0f)"
		% [str(tex_on), str(cu_on), str(bm_on), str(sse_on), fid, FA.K, FA.R_BLOCKS])

	if not (tex_on and cu_on and bm_on and sse_on):
		print("  (V4 path OFF — G-VD-MONO/BUDGET need FP_FACET_TEX+SHELL_ABSOLUTE+CLOSEUP+BAND+BLOCK_DETAIL+FP_SKIN_SSE on)")
		print("  (OFF-identity is the FLAT verify_feature 6042/0 companion — the SSE branch is never entered off the flag)")
		print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
		quit(1 if _fail > 0 else 0)
		return

	_gate_mono(fid)
	_gate_budget(fid)
	_gate_off(fid)

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Facet `fid`'s centre DIRECTION (unit) — the average of its 4 planar corners, normalized (mirrors FacetTexBaker's
## _ensure_centre_pack). The nadir descent axis: the sub-camera direction of a player falling straight onto this facet.
func _centre_dir(fid: int) -> Vector3:
	var s := Vector3.ZERO
	for ci in range(4):
		var c := FA.facet_planar_corner(fid, ci)
		s += Vector3(float(c[0]), float(c[1]), float(c[2]))
	return s.normalized()

## Settle the baker at a fixed altitude: pump update() until the tracked facet's resolved tier is stable and no bake is
## in flight (bounded pump). Large budget so the nearest (highest-priority) facet's tiers resolve within a few frames.
func _settle(baker: FacetTexBaker, axis: Vector3, offs: bool, active_fid: int, cam_dist: float, track_fid: int) -> int:
	var last := -1
	var stable := 0
	for _i in range(60):
		baker.update([axis.x, axis.y, axis.z], offs, 100.0, active_fid, cam_dist)
		var t := baker.resolved_tier(track_fid)
		if t == last:
			stable += 1
			if stable >= 3:
				return t
		else:
			stable = 0
			last = t
	return last

# --- G-VD-MONO: the monotone descent ramp + the evict falsifier ---------------------------------------------------
func _gate_mono(fid: int) -> void:
	var axis := _centre_dir(fid)
	var r := FA.R_BLOCKS
	# Prewarm ONLY the nadir facet's base map so the tracked facet's floor is tier 1 immediately (keeps the settle loop
	# fast); the close-up/band tiers still promote purely by the screen-space law. The ramp then reads 1 → 2 → 3.
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	baker.prewarm(PackedInt32Array([fid]))
	_ok(baker.resolved_tier(fid) == 1, "G-VD-MONO: baseline — nadir facet base-baked (tier 1), never below")

	# Pure-vertical descent (constant axis, shrinking altitude) — the Bug-1 scenario. Altitudes straddle the close-up
	# (CLOSEUP_FAR) and band (CLOSEUP_NEAR) screen thresholds so the ramp must climb 1→2→3.
	var alts: Array = [15000.0, 8000.0, 5000.0, 4500.0, 4000.0, 3000.0, 2000.0, 1400.0, 1200.0, 900.0, 500.0, 200.0]
	var seq: Array = []
	var monotone := true
	var prev := 0
	for h in alts:
		var cam_dist := r + float(h)
		var offs := float(h) > CubeSphere.OFFSURFACE_Y     # realistic regime flag (SSE ignores it; fed for honesty)
		var tier := _settle(baker, axis, offs, fid, cam_dist, fid)
		seq.append(tier)
		if tier < prev:
			monotone = false
		prev = tier
	print("    [G-VD-MONO] descent tiers (orbit→ground) = %s  (0=none 1=base 2=close-up 3=band)" % str(seq))
	_ok(monotone, "G-VD-MONO: the nadir skin tier is MONOTONE NON-DECREASING across the whole descent (never a flat-color drop)")
	_ok(int(seq[0]) <= 1 and int(seq[seq.size() - 1]) == 3 and int(seq[seq.size() - 1]) > int(seq[0]),
		"G-VD-MONO: a real RAMP — starts ≤ base (%d) at orbit, reaches band (%d) at the ground (not a constant)" % [int(seq[0]), int(seq[seq.size() - 1])])
	# The close-up tier is actually reached mid-descent (the middle stage is a SHARPER picture, never the biome-color base).
	_ok(seq.has(2), "G-VD-MONO: the close-up tier (2) is resident at mid-altitudes — the descent sharpens, never coarsens")

	# FALSIFY — re-invoke the DELETED regime _evict_all_closeup at a mid-descent altitude where the nadir is close-up
	# resident: the tier REGRESSES to the base map (the exact Bug-1 flat-color drop). This proves (a) the evict is the bug
	# and (b) the monotone assertion above would catch it. Fresh baker settled to tier 2, then evicted.
	var fb := FacetTexBaker.new()
	fb.setup(fid)
	fb.prewarm(PackedInt32Array([fid]))
	var mid_cam := r + 2000.0                             # h = 2000 → close-up band (CLOSEUP_NEAR < 2000 ≤ CLOSEUP_FAR)
	var before := _settle(fb, axis, true, fid, mid_cam, fid)
	_ok(before == 2, "G-VD-MONO falsify: at h=2000 the nadir is close-up resident (tier %d)" % before)
	fb._evict_all_closeup()                               # the removed regime dump — the descent flat-color mechanism
	var after := fb.resolved_tier(fid)
	_ok(after < before, "G-VD-MONO falsify: re-invoking the deleted _evict_all_closeup REGRESSES the tier (%d → %d) — the evict IS Bug 1" % [before, after])

# --- G-VD-BUDGET: bounded per-frame promotion work across the descent (THE HARD PERF CONSTRAINT) ------------------
# V4 is a PROMOTION-LAW change; the underlying bake machinery (base facet / close-up 128² row-slice / band 32-row slice)
# is shipped and unchanged. So this gate proves the two things V4 owns: (1) the new per-frame promotion-LAW overhead (the
# O(facets) screen-space want scans + largest-deficit sort) is small and bounded, independent of any bake; (2) the
# check-BEFORE-slice invariant still holds on the SSE path — the worst frame never exceeds budget + ONE bake unit (it
# never STARTS a second unit past the budget line), so cost is bounded regardless of the (coarse, pre-existing, worker-
# offloaded in production) band-slice granularity. Plus promotion churn + residency stay within the fixed pools.
func _gate_budget(fid: int) -> void:
	var axis := _centre_dir(fid)
	var r := FA.R_BLOCKS
	var budget := CubeSphere.FACET_TEX_BAKE_BUDGET_MS
	var all_fids := PackedInt32Array()
	for i in range(6 * FA.K * FA.K):
		all_fids.append(i)

	# (1) V4 PROMOTION-LAW OVERHEAD, isolated: at a high altitude nothing is within a promotion threshold (nadir dist >
	# CLOSEUP_FAR) so NO tier bakes; with the base map fully prewarmed, an update() is PURE V4 work — the two screen-space
	# want scans + sorts. Measure it is small (≪ the frame budget): the new per-frame law cost is bounded and cheap.
	var law := FacetTexBaker.new()
	law.setup(fid)
	law.prewarm(all_fids)
	var law_worst := 0.0
	for _i in range(20):
		var t0 := Time.get_ticks_usec()
		law.update([axis.x, axis.y, axis.z], true, budget, fid, r + 6000.0)   # h=6000 > CLOSEUP_FAR → no bakes, only the law
		law_worst = maxf(law_worst, float(Time.get_ticks_usec() - t0) / 1000.0)
	_ok(law.closeup_resident_count() == 0 and law.band_resident_count() == 0,
		"G-VD-BUDGET: at orbit (h=6000 > CLOSEUP_FAR) no tier is promoted — the screen-space law admits nothing (%d/%d resident)"
		% [law.closeup_resident_count(), law.band_resident_count()])
	_ok(law_worst <= budget, "G-VD-BUDGET: the V4 promotion-LAW overhead (screen-space want scans + sort, no bake) is bounded ≤ budget (%.3f ms ≤ %.1f)" % [law_worst, budget])

	# (2) ONE bake UNIT ceiling, measured: check-before-slice means a frame runs at most ONE bake unit that STARTED before
	# the budget line. Measure one unit as a COLD single update at the real budget in each tier's range — the FIRST update
	# starts one unit (a close-up 128² slice at h=2000, or the coarsest: one band 32-row slice at h≤800) then the budget
	# check stops it. Take the max as the ceiling. (The band slice is the shipped band tier's granularity, worker-offloaded
	# in production; V4 does not change it — it drives the SAME unit whether promotion is regime- or screen-keyed.)
	var unit_ceil := 0.0
	for h in [2000.0, 800.0, 400.0]:
		var bu := FacetTexBaker.new(); bu.setup(fid); bu.prewarm(all_fids)
		var t1 := Time.get_ticks_usec()
		bu.update([axis.x, axis.y, axis.z], true, budget, fid, r + float(h))
		unit_ceil = maxf(unit_ceil, float(Time.get_ticks_usec() - t1) / 1000.0)
	unit_ceil = unit_ceil * 1.3 - budget                 # subtract the budget already counted in the cold-update wall time; +30% margin
	var bound := budget + unit_ceil

	# The full orbit→ground descent at the REAL budget (base fully prewarmed so this measures only the SSE tiers). Assert
	# NO frame exceeds budget + one measured unit (the check-before-slice bound), churn is bounded, residency ≤ the pools.
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	baker.prewarm(all_fids)
	var worst_ms := 0.0
	var over := 0
	var worst_promote := 0
	var last_res := 0
	for f in range(240):
		var frac := float(f) / 239.0
		var cam_dist := r + lerpf(15000.0, 150.0, frac)
		var offs := cam_dist - r > CubeSphere.OFFSURFACE_Y
		var t0 := Time.get_ticks_usec()
		baker.update([axis.x, axis.y, axis.z], offs, budget, fid, cam_dist)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		worst_ms = maxf(worst_ms, ms)
		if ms > bound:
			over += 1
		var res := baker.closeup_resident_count() + baker.band_resident_count()
		worst_promote = maxi(worst_promote, res - last_res)   # newly-resident tiles this frame (promotion churn)
		last_res = res
	_ok(over == 0, "G-VD-BUDGET: worst per-frame update = %.3f ms ≤ budget %.1f + one bake unit %.1f = %.1f ms over 240 descent frames (%d overruns) — check-before-slice holds"
		% [worst_ms, budget, unit_ceil, bound, over])
	_ok(worst_promote <= 4, "G-VD-BUDGET: promotions turning resident per frame stay bounded (peak %d ≤ 4) — no unbounded largest-deficit sweep" % worst_promote)
	_ok(baker.closeup_resident_count() <= CubeSphere.CLOSEUP_MAX and baker.band_resident_count() <= CubeSphere.BAND_LAYERS,
		"G-VD-BUDGET: residency stays within the fixed layer pools (close-up %d ≤ %d, band %d ≤ %d)"
		% [baker.closeup_resident_count(), CubeSphere.CLOSEUP_MAX, baker.band_resident_count(), CubeSphere.BAND_LAYERS])
	_ok(baker.total_bytes() <= FacetTexBaker.FACET_TEX_BYTES_MAX + 3 * 1024 * 1024,
		"G-VD-BUDGET: total_bytes = %.2f MB stays bounded (fixed-size pools, NEVER-OOM)" % [float(baker.total_bytes()) / 1048576.0])
	print("    [G-VD-BUDGET] law-overhead worst = %.3f ms (≤ budget %.1f); one-unit ceiling = %.2f ms (coarsest = band 32-row slice, worker-offloaded live)" % [law_worst, budget, unit_ceil])
	print("    [G-VD-BUDGET] descent worst-frame = %.3f ms ≤ bound %.1f ms; peak promotion churn %d; final residency close-up %d / band %d" %
		[worst_ms, bound, worst_promote, baker.closeup_resident_count(), baker.band_resident_count()])

# --- G-VD-OFF: cam_dist ≤ 0 ⇒ SSE inert ⇒ shipped regime path (evict-all intact) → byte-identical off ------------
func _gate_off(fid: int) -> void:
	var axis := _centre_dir(fid)
	var r := FA.R_BLOCKS
	# Bring a baker to close-up residency at altitude (SSE path, real cam_dist).
	var baker := FacetTexBaker.new()
	baker.setup(fid)
	baker.prewarm(PackedInt32Array([fid]))
	_settle(baker, axis, true, fid, r + 2000.0, fid)
	var res_before := baker.closeup_resident_count()
	_ok(res_before > 0, "G-VD-OFF: seeded — close-up residency present (%d)" % res_before)

	# ON-surface update with cam_dist = -1 (driver never armed): the SSE law is INERT → the shipped REGIME path runs →
	# on-surface _evict_all_closeup fires → residency dumped. This is EXACTLY the shipped behavior (the flag-off build).
	baker.update([axis.x, axis.y, axis.z], false, 100.0, fid, -1.0)
	_ok(baker.closeup_resident_count() == 0,
		"G-VD-OFF: cam_dist ≤ 0 ⇒ SSE inert ⇒ shipped regime path (on-surface evict-all fires, residency %d) — byte-identical off" % baker.closeup_resident_count())

	# Contrast: re-seed, then the SAME on-surface call WITH a real cam_dist takes the SSE path → NO evict-all (the tier
	# the player is approaching is kept). Proves the two paths are cleanly gated by cam_dist availability.
	var b2 := FacetTexBaker.new()
	b2.setup(fid)
	b2.prewarm(PackedInt32Array([fid]))
	_settle(b2, axis, true, fid, r + 2000.0, fid)
	var seed2 := b2.closeup_resident_count()
	b2.update([axis.x, axis.y, axis.z], false, 100.0, fid, r + 800.0)   # on-surface, but SSE live (near) → keep + promote
	_ok(b2.closeup_resident_count() >= seed2 or b2.band_resident_count() > 0,
		"G-VD-OFF: WITH a real cam_dist the on-surface call does NOT evict-all (SSE monotone: close-up %d kept / band %d) — the paths are distinct"
		% [b2.closeup_resident_count(), b2.band_resident_count()])
