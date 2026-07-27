extends SceneTree
## FP_BOOT_ASYNC gate — G-BOOT-ASYNC (flag CubeSphere.FP_BOOT_ASYNC; perf/voxiverse-load-profile).
##
## The bug: FacetFarRing.setup() runs a SYNCHRONOUS _rebuild_full that caches EVERY front-hemisphere facet (~1716) in one
## main-thread call before the game can proceed — ~90s on web (the ×25 per-facet env/column warm). FP_BOOT_ASYNC caches
## only a bounded PROXIMITY SEED (BOOT_SEED_FACETS) synchronously, then warms the rest across frames in _process, so the
## player reaches essential-ready in seconds and the far hemisphere fills in the background. Final coverage is identical.
##
## This gate stands up a real FacetFarRing (FACETED only; skips otherwise), calls setup(), and asserts:
##   • FP_BOOT_ASYNC ON  → after setup the cached count is BOUNDED (== the seed, ≪ the full front set) and it is still
##     warming; driving _process GROWS the cache monotonically and it CONVERGES to the full front count (nothing lost).
##   • FP_BOOT_ASYNC OFF → after setup the FULL front set is cached in one call, not warming (the byte-identical build).
##
## RUN — prove the deferral (needs FACETED; sed FP_BOOT_ASYNC on):
##   sed -i 's/const FACETED := false/const FACETED := true/' godot/src/cosmos/cube_sphere.gd
##   sed -i 's/const FP_BOOT_ASYNC := false/const FP_BOOT_ASYNC := true/' godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_boot_async.gd
## RUN — the byte-identical baseline (FACETED only, FP_BOOT_ASYNC off): same command without the second sed.
## Exits 0 all-pass / 1 on any failure. SKIPS (pass) when FACETED is off (no far ring to test).

const FFR := preload("res://src/world/facet_far_ring.gd")
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
	print("=== verify_boot_async (FP_BOOT_ASYNC: G-BOOT-ASYNC) ===")
	print("  flags: FP_BOOT_ASYNC=%s FACETED=%s far_ring_enabled=%s" % [
		CubeSphere.FP_BOOT_ASYNC, CubeSphere.FACETED, FacetFarRing.ENABLED])

	if not (CubeSphere.FACETED and FacetFarRing.ENABLED):
		print("  SKIP: no far ring without FACETED — nothing to assert.")
		print("=== VERIFY: %d passed, %d failed (skipped) ===" % [_pass, _fail])
		quit(0)
		return

	TC.warm_up()
	FA.warm_up()
	if TC.active_facet() < 0:
		TC.set_active_facet(FA.spawn_facet())
	var active := TC.active_facet()

	var ring = FFR.new()
	ring.name = "FarRingGate"
	get_root().add_child(ring)
	ring.setup(active)

	var front_total: int = ring.boot_front_total()
	var cached0: int = ring.boot_cached_count()
	var warming0: bool = ring.boot_warming()
	print("  front_total=%d  cached_after_setup=%d  warming=%s  seed=%d" % [
		front_total, cached0, warming0, CubeSphere.BOOT_SEED_FACETS])
	_ok(front_total > CubeSphere.BOOT_SEED_FACETS, "front hemisphere (%d) exceeds the seed (%d) — a meaningful test" % [
		front_total, CubeSphere.BOOT_SEED_FACETS])

	if CubeSphere.FP_BOOT_ASYNC:
		# ON: setup caches only the bounded seed and is still warming.
		_ok(cached0 <= CubeSphere.BOOT_SEED_FACETS + 1, "ON: setup cached only the bounded seed (%d ≤ %d), NOT the full %d" % [
			cached0, CubeSphere.BOOT_SEED_FACETS, front_total])
		_ok(cached0 < front_total, "ON: setup did NOT cache the whole hemisphere synchronously")
		_ok(warming0, "ON: boot warm is armed after setup")
		# Drive _process: the cache must grow monotonically and converge to the full front count.
		var prev := cached0
		var monotone := true
		var iters := 0
		while ring.boot_warming() and iters < 20000:
			ring._process(0.016)
			var c: int = ring.boot_cached_count()
			if c < prev:
				monotone = false
			prev = c
			iters += 1
		_ok(monotone, "ON: cached count grows monotonically across frames (never drops)")
		var cachedN: int = ring.boot_cached_count()
		_ok(cachedN > cached0, "ON: cache GREW after ticks (%d → %d)" % [cached0, cachedN])
		_ok(not ring.boot_warming(), "ON: boot warm completed within the iteration cap (%d frames)" % iters)
		_ok(cachedN >= front_total, "ON: converged to the FULL front coverage (%d ≥ %d) — nothing lost" % [cachedN, front_total])
	else:
		# OFF: the shipped synchronous full build cached everything at setup, not warming (byte-identical).
		_ok(cached0 >= front_total, "OFF: setup cached the FULL front set (%d ≥ %d) in one synchronous build" % [cached0, front_total])
		_ok(not warming0, "OFF: no boot warm armed (byte-identical shipped build)")

	ring.queue_free()
	print("=== VERIFY: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
