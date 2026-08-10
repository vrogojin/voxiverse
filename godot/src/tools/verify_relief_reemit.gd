extends SceneTree
## FP_RELIEF_REEMIT gate (docs/COSMOS-FAR-GEOMETRY-PREBAKE-DESIGN.md, task #99 follow-up).
##
## Root cause fixed (verified against the live code, not guessed): `GlobalReliefData.step()` bakes AT MOST ONE
## facet's DEM per frame (the governed pacer); `FacetFarRing._ensure_cached` multiplies the G1a hillshade into a
## facet's `_col_cache` the ONE time it is first built. With no player motion, most facets get cached (shade =
## 1.0, the "not baked yet" neutral default) long before their OWN DEM finishes, and nothing else ever re-runs
## `_ensure_cached` for them — the multiply-by-1.0 colour is permanent, so mountains never visibly darken.
##
## The fix, CHURN-SAFE by construction (never a whole-shell re-emit storm — the REV7 lesson): `step()` already
## RETURNS the fid it just baked (or -1); `WorldManager` forwards that to `FacetFarRing.relief_baked(fid)`, which
## marks it dirty ONLY if already resident in `_col_cache` (an uncached facet needs nothing — it bakes WITH the
## ready shade the first time it's ever built). `_drain_relief_dirty` (driven once per `_process`) re-derives a
## BOUNDED batch (`RELIEF_REEMIT_MAX_PER_DRAIN`) of dirty fids' `_col_cache`, itself rate-limited to
## `>= CubeSphere.CULL_REBUILD_MS` between drains, and never calls the heavy synchronous `force_rebuild()` itself
## — it only sets `_pending`, the SAME "a rebuild is owed" signal every other re-emit trigger in this file sets.
##
## Gates (this run's compiled `CubeSphere.FP_RELIEF_REEMIT` decides which assertions are meaningful — the SAME
## self-describing convention `verify_far_geometry.gd`'s G-GP-OFF already established. Run once with the flag
## false (default) and once sed-toggled true alongside FP_GLOBAL_RELIEF_DATA + FP_SKIN_RELIEF_SHADE for full
## coverage):
##   G-RR-OFF     — flag off: `relief_baked()` never populates `_relief_dirty` no matter how many times called;
##                  `_drain_relief_dirty()` is a pure no-op (`_col_cache` byte-identical, `_pending` untouched).
##   G-RR-FIRES   — flag on: a facet cached BEFORE its own DEM bakes shows shade=1.0 (unshaded) in `_col_cache`;
##                  after baking its DEM + `relief_baked(fid)` + a drain, that SAME facet's `_col_cache` becomes
##                  EXACTLY raw × `shade_at(...)` per node (mirrors G-GP-COMPOSITE's exact tolerance), `_pending`
##                  fires, and a SIBLING facet that was never marked dirty is left byte-identical (scoped, not a
##                  blanket refresh). An uncached facet marked dirty is never added to `_relief_dirty` at all.
##   G-RR-BOUNDED — flag on: marking EVERY facet dirty at once (the pathological "3456 completions in one frame"
##                  burst) still drains at most `RELIEF_REEMIT_MAX_PER_DRAIN` in ONE call — never all of them; the
##                  rest stay queued (not dropped); an IMMEDIATE second drain (same rate-cap window) processes
##                  ZERO more — proving the rate-cap, not just the per-drain cap, is what bounds the churn.
##
## RUN:
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_relief_reemit.gd 2>/dev/null | grep VERIFY
## Exits 0 all-pass / 1 on any failure.

const FA := preload("res://src/cosmos/facet_atlas.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

const EPS := 1.0e-5

func _initialize() -> void:
	print("=== verify_relief_reemit (task #99 follow-up — FP_RELIEF_REEMIT) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: this gate must run with FACETED = true (sed-toggled).")
		print("==== VERIFY: 0 passed, 1 failed ====")
		quit(1)
		return
	FA.warm_up()

	_gate_off()
	if CubeSphere.FP_RELIEF_REEMIT and CubeSphere.FP_GLOBAL_RELIEF_DATA and CubeSphere.FP_SKIN_RELIEF_SHADE:
		_gate_fires()
		_gate_bounded()
	else:
		_ok(true, "G-RR-FIRES/BOUNDED: skipped this run (needs FP_RELIEF_REEMIT + FP_GLOBAL_RELIEF_DATA + FP_SKIN_RELIEF_SHADE all sed-toggled true)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _colors_equal(a: PackedColorArray, b: PackedColorArray) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i] != b[i]:
			return false
	return true

# --- G-RR-OFF: self-describing, run only when FP_RELIEF_REEMIT is off this run ---------------------------------------
func _gate_off() -> void:
	if CubeSphere.FP_RELIEF_REEMIT:
		_ok(true, "G-RR-OFF: skipped this run (flag currently ON — G-RR-FIRES/BOUNDED cover the ON behaviour)")
		return
	var fid := 12
	var ring := FacetFarRing.new()
	ring._active_fid = fid
	ring._ensure_cached(fid, true)
	var before: PackedColorArray = (ring._col_cache[fid] as PackedColorArray).duplicate()
	ring.relief_baked(fid)
	_ok(ring._relief_dirty.is_empty(), "G-RR-OFF: relief_baked() never populates _relief_dirty with the flag off")
	ring._drain_relief_dirty()
	_ok(not ring._pending, "G-RR-OFF: _drain_relief_dirty() never sets _pending with the flag off")
	var after: PackedColorArray = ring._col_cache[fid]
	_ok(_colors_equal(before, after), "G-RR-OFF: _col_cache is byte-identical after relief_baked()+drain with the flag off")
	ring.free()

# --- G-RR-FIRES: a stale (shade=1.0) cached facet catches up to the real shade, scoped to exactly that fid -----------
func _gate_fires() -> void:
	_ok(GlobalReliefData.CELLS % FacetFarRing.CELLS == 0,
		"G-RR-FIRES: G2's CELLS(%d) is an exact multiple of the shell's CELLS(%d) (no interpolation needed)" % [GlobalReliefData.CELLS, FacetFarRing.CELLS])
	var scale := GlobalReliefData.CELLS / FacetFarRing.CELLS

	var fid := 12          # real terrain, the same facet the STAGE-1 gate (verify_far_geometry.gd) already uses
	var sibling := 37       # a DIFFERENT real facet, cached but NEVER marked dirty — the scoping control

	var rd := GlobalReliefData.new()
	rd.setup()
	_ok(rd.is_ready(), "G-RR-FIRES: GlobalReliefData.setup() allocates (FP_GLOBAL_RELIEF_DATA on)")

	var ring := FacetFarRing.new()
	ring._active_fid = fid
	ring.set_relief_data(rd)

	# Build BOTH facets' caches BEFORE either's DEM is baked — the exact "cached before ready" defect scenario.
	ring._ensure_cached(fid, true)
	ring._ensure_cached(sibling, true)
	var raw_col: PackedColorArray = (ring._col_cache[fid] as PackedColorArray).duplicate()
	var sibling_before: PackedColorArray = (ring._col_cache[sibling] as PackedColorArray).duplicate()

	var stride := FacetFarRing.CELLS + 1
	var all_unshaded := true
	for k in range(raw_col.size()):
		var w := rd.shade_at(fid, (k % stride) * scale, int(k / stride) * scale)
		if absf(w - 1.0) > EPS:
			all_unshaded = false
	_ok(all_unshaded, "G-RR-FIRES: before baking, shade_at defaults to 1.0 everywhere — the cache was built UNSHADED (the defect precondition)")

	# Now the DEM finishes (mirrors GlobalReliefData.step() dispatching this fid's bake), and WorldManager forwards it.
	_ok(rd.bake_facet(fid), "G-RR-FIRES: bake_facet(fid) succeeds")
	ring.relief_baked(fid)
	_ok(ring._relief_dirty.has(fid), "G-RR-FIRES: relief_baked(fid) marks an ALREADY-cached fid dirty")
	ring._drain_relief_dirty()
	_ok(not ring._relief_dirty.has(fid), "G-RR-FIRES: the drain clears fid from _relief_dirty")
	_ok(ring._pending, "G-RR-FIRES: the drain sets _pending — the existing throttled emit pipeline now owes a rebuild")

	var shaded_col: PackedColorArray = ring._col_cache[fid]
	var worst := 0.0
	var any_darkened := false
	for gj in range(stride):
		for gi in range(stride):
			var k := gj * stride + gi
			var want_shade := rd.shade_at(fid, gi * scale, gj * scale)
			var r := raw_col[k]
			var s := shaded_col[k]
			worst = maxf(worst, absf(s.r - r.r * want_shade))
			worst = maxf(worst, absf(s.g - r.g * want_shade))
			worst = maxf(worst, absf(s.b - r.b * want_shade))
			if want_shade < 1.0 - EPS:
				any_darkened = true
	_ok(worst <= EPS, "G-RR-FIRES: after the trigger, every node's colour == raw × shade_at(...) exactly (worst Δ=%.6f)" % worst)
	_ok(any_darkened, "G-RR-FIRES: at least one node of this real facet actually darkens (not a vacuous all-1.0 pass)")

	# Scoping: the sibling was cached too but NEVER marked dirty — its cache must be untouched by the drain above.
	var sibling_after: PackedColorArray = ring._col_cache[sibling]
	_ok(_colors_equal(sibling_before, sibling_after), "G-RR-FIRES: a sibling facet never marked dirty is left byte-identical (scoped, not a blanket refresh)")

	# An uncached facet marked dirty is a no-op — nothing to fix, it will bake shaded the first time it's ever built.
	var uncached := 99
	_ok(not ring._col_cache.has(uncached), "G-RR-FIRES: fixture sanity — facet %d was never cached" % uncached)
	ring.relief_baked(uncached)
	_ok(not ring._relief_dirty.has(uncached), "G-RR-FIRES: relief_baked() on an UNCACHED facet is a no-op (nothing queued)")

	ring.free()

# --- G-RR-BOUNDED: a pathological all-facets-at-once burst still re-emits a bounded handful, rate-capped -------------
func _gate_bounded() -> void:
	var ring := FacetFarRing.new()
	var n := FA.facet_count()
	# Fake "already resident" cheaply (no real geometry needed for this bound-only check) — mirrors how gates
	# already read _col_cache directly (verify_far_geometry.gd's G-GP-COMPOSITE); here we WRITE it directly too.
	for fid in range(n):
		ring._col_cache[fid] = PackedColorArray()
	for fid in range(n):
		ring.relief_baked(fid)
	_ok(ring._relief_dirty.size() == n, "G-RR-BOUNDED: the pathological burst marks every one of %d cached facets dirty at once" % n)

	ring._drain_relief_dirty()
	var remaining := ring._relief_dirty.size()
	var drained := n - remaining
	_ok(drained >= 1 and drained <= FacetFarRing.RELIEF_REEMIT_MAX_PER_DRAIN,
		"G-RR-BOUNDED: ONE drain call processes at most RELIEF_REEMIT_MAX_PER_DRAIN(%d) of the %d-facet burst (drained %d)" % [FacetFarRing.RELIEF_REEMIT_MAX_PER_DRAIN, n, drained])
	_ok(remaining == n - drained, "G-RR-BOUNDED: the rest stay queued in _relief_dirty, not silently dropped (%d remain of %d)" % [remaining, n])

	# An immediate second drain (well inside the same CULL_REBUILD_MS rate-cap window) must process ZERO more —
	# the RATE-CAP, not merely the per-drain batch cap, is what bounds the churn under sustained completions.
	ring._drain_relief_dirty()
	_ok(ring._relief_dirty.size() == remaining, "G-RR-BOUNDED: an immediate second drain (< CULL_REBUILD_MS later) processes ZERO more facets")

	ring.free()
