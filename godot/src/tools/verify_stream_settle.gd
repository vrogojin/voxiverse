extends SceneTree
## COSMOS STREAM-SETTLE gate — G-STREAM-SETTLE (feat/voxiverse-stream-settle).
##
## The bug: a dev teleport / fast-travel to a FRESH FAR facet re-seeds the player pose + active facet, but the
## near voxel field (the godot_voxel VoxelViewer's terrain) is a POOL keyed to a facet — nothing re-designated it
## onto the new facet, so the meshed near bubble stayed stranded on the OLD facet (the live "player in space,
## draws≈43, near field elsewhere, never streams in" symptom) and the player was handed control while dropped into
## un-streamed void. This gate proves the two-part fix WITHOUT a browser / GPU / relay / human:
##   1. RE-ANCHOR: after a teleport that changes facet, the near pool re-designates onto the NEW sub-player facet
##      NOW (module.pool_active re-derives), the single VoxelViewer follows (same instance, not stranded), and the
##      active facet matches — so streaming loads the correct area immediately, not the old spot.
##   2. SETTLE: a GROUND teleport HOLDS the player hovering at the analytic surface_y (no fall, control held) until
##      the near-coverage probe says their column is meshed OR a hard cap (SETTLE_CAP_S = 6 s) elapses — then it
##      snaps onto the surface, arms the fall-through guard, and releases. A HIGH set_alt (intended hover) is NOT
##      force-landed. The cap guarantees a teleport can never HANG on a probe that never passes.
##
## Gates (unit tier runs on the shipped FLAT tree; the re-anchor tier only fires FACETED + module):
##   (1) PLUMBING       — world exposes dev_reanchor_near / near_column_meshed / near_coverage_available; the player
##                        exposes _settle_begin / _settle_step; the module exposes player_column_meshed.
##   (2) SETTLE HOLD    — while settling with covered=false the player is PINNED at surface_y (no fall, v=0) and stays
##                        active; the tick covered flips true it RELEASES grounded (y==surface_y) with the guard armed.
##   (3) SETTLE CAP     — settling with covered=false FOREVER still releases within SETTLE_CAP_S (never before, never a
##                        hang), grounded, guard armed.
##   (4) HIGH-ALT FREE  — a high set_alt never engages the settle (not force-landed); a new placement supersedes a
##                        prior settle hold (no re-trap).
##   (5) RE-ANCHOR      — (FACETED only) a teleport to a different facet re-derives the active facet to the target, the
##                        near pool re-designates onto it (FP_M1_POOL), the viewer follows (same instance id), the
##                        ground teleport engages the settle, and the settle rides the cap to release (no hang).
##
## RUN — unit tier (shipped FLAT tree, no toggles):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_stream_settle.gd 2>/dev/null | grep -E "VERIFY|FAIL"
## RUN — re-anchor tier (sed FACETED=true, FP_M1_POOL=true, +the deploy set like verify_alt_regime):
##   sed -i 's/const FACETED := false/const FACETED := true/'   godot/src/cosmos/cube_sphere.gd
##   sed -i 's/const FP_M1_POOL := false/const FP_M1_POOL := true/' godot/src/cosmos/cube_sphere.gd
## Exits 0 all-pass / 1 on any failure.

const PlayerCls := preload("res://src/player/player.gd")

var _pass := 0
var _fail := 0
var _wm: Node = null

func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	_run()

func _run() -> void:
	print("=== verify_stream_settle (G-STREAM-SETTLE) ===")
	print("  flags: FACETED=%s FP_M1_POOL=%s FLAT_WORLD=%s" % [
		str(CubeSphere.FACETED), str(CubeSphere.FP_M1_POOL), str(CubeSphere.FLAT_WORLD)])
	TerrainConfig.warm_up()
	if CubeSphere.FACETED:
		FacetAtlas.warm_up()
		TerrainConfig.set_active_facet(FacetAtlas.spawn_facet())
	_wm = WorldManager.new()
	_wm.name = "StreamSettleWorld"
	get_root().add_child(_wm)
	await process_frame

	_gate_plumbing()
	_gate_settle_hold()
	_gate_settle_cap()
	_gate_high_alt_free()
	if CubeSphere.FACETED:
		_gate_reanchor()
	else:
		print("  (gate 5 RE-ANCHOR skipped — FLAT tree; the near-field pool + module viewer are FACETED-only)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Build a fresh Player over the world at the spawn column, engine-frozen (the gate drives the settle itself).
func _make_player() -> Node:
	var pl = PlayerCls.new()
	pl.world = _wm
	get_root().add_child(pl)                                # fires _ready
	pl.frozen = true
	pl.flying = false
	var sx := 0.0
	var sz := 0.0
	if CubeSphere.FACETED:
		var cc := FacetAtlas.centre_cell(TerrainConfig.active_facet())
		sx = float(cc.x); sz = float(cc.y)
	pl.position = Vector3(sx + 0.5, _wm.surface_y(sx + 0.5, sz + 0.5), sz + 0.5)
	_wm.on_player_ready(pl)                                 # same spawn hand-off the game uses (viewer attach, frame)
	return pl

# ── (1) PLUMBING — the coverage + re-anchor surface exists ───────────────────────────────────────────
func _gate_plumbing() -> void:
	print("  --- (1) PLUMBING: coverage + re-anchor API present ---")
	_ok(_wm.has_method("dev_reanchor_near"), "world exposes dev_reanchor_near")
	_ok(_wm.has_method("near_column_meshed"), "world exposes near_column_meshed")
	_ok(_wm.has_method("near_coverage_available"), "world exposes near_coverage_available")
	var pl := _make_player()
	_ok(pl.has_method("_settle_begin"), "player exposes _settle_begin")
	_ok(pl.has_method("_settle_step"), "player exposes _settle_step")
	# near_column_meshed must never crash and returns a bool on any path (false when the module can't answer).
	var c = _wm.near_column_meshed(pl.position)
	_ok(c is bool, "near_column_meshed returns a bool (%s)" % str(c))
	pl.free()

# ── (2) SETTLE HOLD → RELEASE ON COVERAGE ────────────────────────────────────────────────────────────
func _gate_settle_hold() -> void:
	print("  --- (2) SETTLE HOLD: pinned at surface_y until coverage, then grounded + guard armed ---")
	var pl := _make_player()
	var px: float = pl.position.x
	var pz: float = pl.position.z
	var sy: float = _wm.surface_y(px, pz)
	pl.position.y = sy
	pl.velocity = Vector3(3.0, -50.0, 2.0)                  # poison: a carried fall the settle must suppress
	pl._settle_begin(sy)
	_ok(pl._settle_active, "settle engaged")
	var held_ok := true
	for i in 5:
		var released: bool = pl._settle_step(0.1, false)   # coverage NOT yet present
		if released or not pl._settle_active:
			held_ok = false
		if absf(pl.position.y - sy) > 1e-4:
			held_ok = false                                # must stay pinned at the surface (never fall)
		if pl.velocity != Vector3.ZERO:
			held_ok = false                                # velocity held at zero (no fall integration)
	_ok(held_ok, "settle HELD across 5 un-covered ticks: pinned at surface_y, velocity zero, still active")
	var rel: bool = pl._settle_step(0.1, true)             # coverage arrives
	_ok(rel, "settle RELEASED the tick coverage arrived")
	_ok(not pl._settle_active, "settle no longer active after release")
	_ok(absf(pl.position.y - sy) < 1e-4, "released grounded exactly at surface_y (%.3f == %.3f)" % [pl.position.y, sy])
	_ok(pl._dev_land_guard, "fall-through guard ARMED on release (catches any residual below-surface drop)")
	pl.free()

# ── (3) SETTLE CAP — releases within the cap even if coverage never comes (no hang) ──────────────────
func _gate_settle_cap() -> void:
	print("  --- (3) SETTLE CAP: releases within SETTLE_CAP_S even if coverage never arrives ---")
	var pl := _make_player()
	var sy: float = _wm.surface_y(pl.position.x, pl.position.z)
	pl.position.y = sy
	pl._settle_begin(sy)
	var cap: float = pl.SETTLE_CAP_S
	var dt := 0.5
	var elapsed := 0.0
	var released := false
	var released_early := false
	var steps := 0
	# Drive with coverage FOREVER false; assert it never releases before the cap and DOES release by it.
	while steps < int(ceil(cap / dt)) + 4:
		var r: bool = pl._settle_step(dt, false)
		elapsed += dt
		steps += 1
		if r:
			released = true
			if elapsed < cap - 1e-6:
				released_early = true
			break
	_ok(released, "settle released under a never-covered probe (no hang)")
	_ok(not released_early, "settle did NOT release before the cap (%.1fs)" % cap)
	_ok(elapsed <= cap + dt + 1e-6, "settle released by the cap (elapsed %.1fs, cap %.1fs)" % [elapsed, cap])
	_ok(not pl._settle_active, "settle cleared after the cap release")
	_ok(pl._dev_land_guard, "guard armed on the cap release too")
	pl.free()

# ── (4) HIGH-ALT FREE — a high placement is never force-landed; a new placement supersedes a settle ──
func _gate_high_alt_free() -> void:
	print("  --- (4) HIGH-ALT FREE: high set_alt not settled; new placement supersedes a prior hold ---")
	var pl := _make_player()
	# Prime a settle hold, then place high — the new placement must CLEAR it (no re-trap at the surface).
	pl._settle_begin(_wm.surface_y(pl.position.x, pl.position.z))
	_ok(pl._settle_active, "settle primed")
	var ok_hi: bool = pl.remote_set_alt(3000.0)
	_ok(ok_hi, "remote_set_alt(3000) returned true")
	_ok(not pl._settle_active, "high set_alt did NOT engage/keep a settle (intended hover not force-landed)")
	var sy_hi: float = _wm.surface_y(pl.position.x, pl.position.z)
	_ok(pl.position.y > sy_hi + 100.0, "player left at altitude (%.0f above surface), not dropped to the ground" % (pl.position.y - sy_hi))
	pl.free()

# ── (5) RE-ANCHOR — teleport to a fresh facet re-derives the near field to the new sub-player point ──
func _gate_reanchor() -> void:
	print("  --- (5) RE-ANCHOR (FACETED): near pool + viewer follow the teleport to the target facet ---")
	var pl := _make_player()
	var mw = _wm.get("_module_world")
	var have_module: bool = mw != null and mw.has_method("pool_active")
	var spawn := TerrainConfig.active_facet()
	var from_pool := int(mw.call("pool_active")) if have_module else -1
	var vid_before := int(mw.call("viewer_instance_id")) if (have_module and mw.has_method("viewer_instance_id")) else 0
	# Pick a DIFFERENT target facet (an edge neighbour of spawn) and its centre-surface landing.
	var nb := FacetAtlas.seam_neighbour(spawn, 0)
	if nb < 0 or nb == spawn:
		nb = FacetAtlas.seam_neighbour(spawn, 1)
	_ok(nb >= 0 and nb != spawn, "resolved a distinct target facet %d (from spawn %d)" % [nb, spawn])
	var cc := FacetAtlas.centre_cell(nb)
	var cx := float(cc.x) + 0.5
	var cz := float(cc.y) + 0.5
	# surface_y reads the ACTIVE facet's column → set active to nb to sample the target column height, then restore
	# spawn so the module's pool is still on `spawn` when _dev_reposition drives the re-anchor (from != to).
	TerrainConfig.set_active_facet(nb)
	var syb: float = _wm.surface_y(cx, cz)
	TerrainConfig.set_active_facet(spawn)
	# Ground teleport onto the fresh facet.
	pl._dev_reposition(nb, Vector3(cx, syb, cz))
	_ok(TerrainConfig.active_facet() == nb, "active facet re-derived to the target (%d)" % nb)
	if have_module and CubeSphere.FP_M1_POOL:
		_ok(int(mw.call("pool_active")) == nb,
			"near POOL re-designated onto the target facet (pool_active %d -> %d)" % [from_pool, nb])
		if mw.has_method("viewer_instance_id"):
			_ok(int(mw.call("viewer_instance_id")) == vid_before,
				"the SAME single VoxelViewer followed the teleport (not stranded/re-created)")
	else:
		print("  (pool_active/viewer assertions need FACETED + FP_M1_POOL + module — skipped in this config)")
	_ok(pl._settle_active, "ground teleport onto the fresh facet ENGAGED the settle hold (never dropped into void)")
	# Even with the real module never reporting the column meshed headlessly, the settle must release by the cap.
	var cap: float = pl.SETTLE_CAP_S
	var released := false
	var elapsed := 0.0
	for i in int(ceil(cap / 0.5)) + 3:
		if pl._settle_step(0.5, _wm.near_column_meshed(pl.position)):
			released = true
			break
		elapsed += 0.5
	_ok(released, "settle released (coverage or the cap) — no hang after a fresh-facet teleport")
	pl.free()
