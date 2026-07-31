extends SceneTree
## COSMOS FAR-CRUISE NEVER-BLACK gate (fix/voxiverse-farcruise-black) — proves FP_FARRING_ACTIVE_NOBLACK guarantees the
## sub-camera (active) facet ALWAYS paints an opaque backstop on the floored surface, with NO warm-lag black gap and NO
## sunk well where the near voxel field is absent (the far-cruise "black substance"). Runs headless with FACETED +
## FP_FARRING_FULL_COVER sed-toggled true, and BRANCHES on FP_FARRING_ACTIVE_NOBLACK:
##
##   flag ON  — G-FC-IMMEDIATE  the guarantee force-builds the active facet's dense backstop cache the instant it is
##                              missing (no warm-lag), so the cache-filtered emit (visible_fids(true)) INCLUDES it.
##              G-FC-NOBLACK    with the near field reporting NOT-meshed at the active facet, the far ring's visible +
##                              emitted set INCLUDES the active facet drawn as a backstop (it would draw, not black).
##              G-FC-UNSINK     that emitted active facet is UN-SUNK (its emitted radii sit ABOVE the shipped sunk
##                              backstop by ~BACKSTOP_SINK — true surface, not a well).
##              G-FC-COVERED    with the near field reporting MESHED, the active facet stays the shipped SUNK backstop
##                              (_noblack_unsink_fid == -1) — no un-sink, no regression / z-fight near spawn.
##   flag OFF — G-FC-FALSIFIER  the SHIPPED bug is reproduced: a cache-filtered emit with the active facet's dense cache
##                              absent DROPS it from visible_fids(true) (the BLACK), and the guarantee is fully inert
##                              (_noblack_unsink_fid stays -1) → byte-identical.
##
## RUN (flag ON):
##   sed -i 's/const FACETED := false/const FACETED := true/;s/const FP_FARRING_FULL_COVER := false/const FP_FARRING_FULL_COVER := true/;s/const FP_FARRING_ACTIVE_NOBLACK := false/const FP_FARRING_ACTIVE_NOBLACK := true/' \
##       godot/src/cosmos/cube_sphere.gd
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/verify_farcover.gd
##   then REVERT the sed. RUN (flag OFF falsifier): sed FACETED + FP_FARRING_FULL_COVER only. Exits 0 all-pass / 1 on any failure.

const FA := preload("res://src/cosmos/facet_atlas.gd")
const FFR := preload("res://src/world/facet_far_ring.gd")

var _pass := 0
var _fail := 0
func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

# Coverage callables the gate injects for skin_near_meshed: "false" = near field ABSENT (the cruise gap), "true" = meshed.
func _cover_false(_fid: int, _aabb: AABB) -> bool: return false
func _cover_true(_fid: int, _aabb: AABB) -> bool: return true

func _initialize() -> void:
	print("=== verify_farcover (far-cruise NEVER-BLACK: FP_FARRING_ACTIVE_NOBLACK) ===")
	if not CubeSphere.FACETED:
		print("  FAIL: CubeSphere.FACETED is false — sed-toggle FACETED = true to run this gate.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	if not CubeSphere.FP_FARRING_FULL_COVER:
		print("  FAIL: FP_FARRING_FULL_COVER is false — this fix layers on the full-cover backstop; sed-toggle it true.")
		print("==== VERIFY: 0 passed, 1 failed ===="); quit(1); return
	TerrainConfig.warm_up()
	FA.warm_up()
	var active := FA.spawn_facet()
	TerrainConfig.set_active_facet(active)
	print("  atlas: k=%d, R=%.0f, active=%d, FULL_COVER=%s, NOBLACK=%s, sink=%.2f, BACKSTOP_CELLS=%d" % [
		FA.K, FA.R_BLOCKS, active, str(CubeSphere.FP_FARRING_FULL_COVER),
		str(CubeSphere.FP_FARRING_ACTIVE_NOBLACK), TierPlace.backstop_sink(), CubeSphere.BACKSTOP_CELLS])
	if CubeSphere.FP_FARRING_ACTIVE_NOBLACK:
		_gate_immediate_and_noblack(active)
		_gate_unsink(active)
		_gate_covered(active)
	else:
		_gate_falsifier(active)
	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# ---------- G-FC-IMMEDIATE + G-FC-NOBLACK (flag ON): active facet built immediately + always in the emit set ----------
func _gate_immediate_and_noblack(active: int) -> void:
	print("  --- G-FC-IMMEDIATE / G-FC-NOBLACK: near ABSENT ⇒ active facet built now + emitted (not black) ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	ring.call("set_cover_query", Callable(self, "_cover_false"))   # near field NOT meshed at the active facet (cruise gap)

	# Reproduce the pre-fix hazard state: the active facet's dense cache absent AND the emit is cache-filtered.
	ring.set("_bpos_cache", {})
	ring.set("_emit_cached_only", true)
	_ok(not (ring.get("_bpos_cache") as Dictionary).has(active), "setup: active facet dense cache starts ABSENT (the warm-lag window)")

	# The guarantee runs (as _process would) BEFORE the emit. It must force-build the cache immediately.
	var p: Array = ring.call("_cull_params")
	ring.call("_noblack_guarantee", p)
	_ok((ring.get("_bpos_cache") as Dictionary).has(active),
		"G-FC-IMMEDIATE: active facet dense cache force-built the instant it was missing (no warm-lag black)")
	_ok(int(ring.get("_noblack_unsink_fid")) == active,
		"G-FC-NOBLACK: near-absent ⇒ active facet marked to emit UN-SUNK (_noblack_unsink_fid == active)")

	# The CACHE-FILTERED emit set (the path that dropped it → BLACK) now INCLUDES the active facet.
	var vis_cached: PackedInt32Array = ring.call("visible_fids", true)
	var cset := {}
	for f in vis_cached: cset[int(f)] = true
	_ok(cset.has(active), "G-FC-NOBLACK: cache-filtered visible_fids(true) INCLUDES the active facet (it would draw, not black)")

	# And a real rebuild emits it as a backstop.
	ring.call("force_rebuild")
	_ok(bool(ring.call("is_emitted", active)) and bool(ring.call("is_backstop", active)),
		"G-FC-NOBLACK: after rebuild the active facet is EMITTED as a backstop")
	ring.free()

# ---------- G-FC-UNSINK (flag ON): the emitted active facet sits at the true surface, above the sunk backstop ----------
func _gate_unsink(active: int) -> void:
	print("  --- G-FC-UNSINK: near ABSENT ⇒ active facet emitted UN-SUNK (radii above the sunk backstop) ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	ring.call("_ensure_backstop_cached", active)   # build the dense cache directly

	# Emit the active facet SUNK (shipped) and UN-SUNK (near-absent) and compare mean vertex radius.
	ring.set("_noblack_unsink_fid", -1)
	var r_sunk := _emit_mean_radius(ring, active)
	ring.set("_noblack_unsink_fid", active)
	var r_unsunk := _emit_mean_radius(ring, active)
	var sink := TierPlace.backstop_sink()
	_ok(r_unsunk > r_sunk + 0.5 * sink,
		"G-FC-UNSINK: un-sunk mean radius %.2f > sunk %.2f by ~sink %.2f (true surface, not a well)" % [r_unsunk, r_sunk, sink])
	# The un-sunk emit sits EXACTLY the sink amount above the sunk emit (same triangulation both sides, so the per-vertex
	# radial push is the only difference) — proves the un-sink removes the full BACKSTOP_SINK, not a partial reduction.
	_ok(absf((r_unsunk - r_sunk) - sink) < 0.5,
		"G-FC-UNSINK: un-sunk radius is exactly ~sink (%.2f) above the sunk radius (Δ=%.2f) — full sink removed" % [sink, r_unsunk - r_sunk])
	ring.free()

# ---------- G-FC-COVERED (flag ON): near MESHED ⇒ shipped sunk backstop, no un-sink (no regression) ----------
func _gate_covered(active: int) -> void:
	print("  --- G-FC-COVERED: near MESHED ⇒ active facet stays the shipped SUNK backstop (no un-sink) ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	ring.call("set_cover_query", Callable(self, "_cover_true"))   # near field IS meshed under the camera
	ring.set("_bpos_cache", {})
	var p: Array = ring.call("_cull_params")
	ring.call("_noblack_guarantee", p)
	_ok(int(ring.get("_noblack_unsink_fid")) == -1,
		"G-FC-COVERED: near-meshed ⇒ NO un-sink (_noblack_unsink_fid == -1) — shipped sunk backstop kept (no z-fight)")
	# Coverage still guaranteed: the cache is built so the facet is never dropped, but it emits sunk.
	_ok((ring.get("_bpos_cache") as Dictionary).has(active), "G-FC-COVERED: active facet cache still guaranteed present (never dropped)")
	ring.free()

# ---------- G-FC-FALSIFIER (flag OFF): the shipped bug reproduces + the guarantee is inert (byte-identical) ----------
func _gate_falsifier(active: int) -> void:
	print("  --- G-FC-FALSIFIER (flag off): cache-filtered emit DROPS an uncached active facet (the BLACK) ---")
	var ring: Node3D = FFR.new()
	get_root().add_child(ring)
	ring.call("setup", active)
	ring.call("set_cover_query", Callable(self, "_cover_false"))
	ring.set("_bpos_cache", {})
	ring.set("_emit_cached_only", true)
	# The guarantee is fully inert with the flag off.
	var p: Array = ring.call("_cull_params")
	ring.call("_noblack_guarantee", p)
	_ok(int(ring.get("_noblack_unsink_fid")) == -1, "byte-identity: guarantee inert (_noblack_unsink_fid == -1)")
	_ok(not (ring.get("_bpos_cache") as Dictionary).has(active), "byte-identity: no cache force-built (flag off ⇒ zero effect)")
	# THE BUG the flag fixes: the active facet is a backstop but its dense cache is absent, so the cache-filtered emit
	# set DROPS it → nothing drawn → BLACK. (This is exactly what FP_FARRING_ACTIVE_NOBLACK prevents when on.)
	var vis_cached: PackedInt32Array = ring.call("visible_fids", true)
	var cset := {}
	for f in vis_cached: cset[int(f)] = true
	_ok(bool(ring.call("is_backstop", active)) and not cset.has(active),
		"G-FC-FALSIFIER: uncached active backstop is DROPPED from cache-filtered emit (the shipped BLACK the flag fixes)")
	ring.free()

# --- helpers ---

## Emit facet `fid` alone through _emit_cached (sunk=true honours _noblack_unsink_fid) and return the mean vertex radius.
func _emit_mean_radius(ring: Node3D, fid: int) -> float:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	ring.call("_emit_cached", st, fid, true)
	var mesh: ArrayMesh = st.commit()
	if mesh.get_surface_count() == 0:
		return 0.0
	return _mean_radius(mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX])

func _mean_radius(pos: PackedVector3Array) -> float:
	if pos.size() == 0:
		return 0.0
	var s := 0.0
	for v in pos:
		s += (v as Vector3).length()
	return s / float(pos.size())
