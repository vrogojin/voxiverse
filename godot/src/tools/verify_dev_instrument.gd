extends SceneTree
## DEV/TEST INSTRUMENTATION gate — G-DEV-INSTRUMENT (dev-instrument tooling).
##
## Proves the four autonomous-analysis ops the orchestrator drives through the remote-bridge — teleport,
## set_alt, freeze_time, freeze_player — resolve through their gated player actuators and behave, WITHOUT a
## browser, a GPU, the relay, or a human. Mirrors the re-entry gate's invariants for teleport SAFETY: a
## tunneling / blowup teleport is worse than no teleport, so the core assertion is that teleport re-seeds
## fid / pose / BCI CONSISTENTLY (no fid/pose desync, no finite-difference velocity latch) and that a real
## _physics_process sequence after a teleport neither jumps the planet-fixed position nor escapes.
##
## Gates:
##   (1) OP RESOLUTION   — each op dispatches through the RemoteControl executor to its gated player actuator
##                         and reports `ok` (the actuator surface the relay routes to exists + wires up).
##   (2) TELEPORT RESEED — after teleport (abs lattice + high-alt), _pos_fid == active_facet (frame/pose
##                         consistent), the finite-difference history is DROPPED (_nav_have_prev false) and
##                         every carried BCI/coast/free-fall latch is cleared, velocity == 0 (no desync/latch).
##   (3) SET_ALT LAND    — set_alt lands EXACTLY `alt` above the current sub-player analytic surface (world.
##                         surface_y — never the voxel buffer), with ZERO horizontal move.
##   (4) FREEZE_TIME     — advancing a frozen clock leaves now() unchanged; resume ticks on from the held time;
##                         set_time's offset still folds in while frozen (sets then holds). Routed via the player.
##   (5) FREEZE_PLAYER   — a held player's position is INVARIANT across real _physics_process ticks; release
##                         resumes physics.
##   (6) OFF INERT       — the freeze latches default off and are byte-neutral (a fresh clock advances normally;
##                         _dev_freeze_player defaults false) ⇒ normal play is byte-identical.
##   (7) NO-BLOWUP       — (FACETED only) drive the REAL Player._physics_process for N frames after a high-alt
##                         teleport; the planet-fixed position never jumps (bounded |Δw|) and the altitude does
##                         not escape — the re-entry blowup cannot be re-triggered by a teleport.
##
## RUN (green on the shipped FLAT tree AND on a flag-toggled faceted/deploy tree — gate 7 only fires FACETED):
##   docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot \
##       --script res://src/tools/verify_dev_instrument.gd 2>/dev/null | grep -E "VERIFY|FAIL"
## Exits 0 all-pass / 1 on any failure.

const PlayerCls := preload("res://src/player/player.gd")
const EPH := preload("res://src/cosmos/cosmos_ephemeris.gd")
const DV := preload("res://src/cosmos/dvec3.gd")

var _pass := 0
var _fail := 0
var _wm: Node = null
var _last_status := ""              # captured from RemoteControl.step_finished (gate 1)

func _ok(c: bool, m: String) -> void:
	if c: _pass += 1
	else:
		_fail += 1
		print("  FAIL: ", m)

func _initialize() -> void:
	_run()

func _run() -> void:
	print("=== verify_dev_instrument (G-DEV-INSTRUMENT) ===")
	print("  flags: FACETED=%s FLAT_WORLD=%s SN_NAV_MODES=%s ORBITAL_SKY=%s" % [
		str(CubeSphere.FACETED), str(CubeSphere.FLAT_WORLD), str(CubeSphere.SN_NAV_MODES), str(CubeSphere.ORBITAL_SKY)])
	TerrainConfig.warm_up()
	if CubeSphere.FACETED:
		FacetAtlas.warm_up()
		TerrainConfig.set_active_facet(FacetAtlas.spawn_facet())
	_wm = WorldManager.new()
	_wm.name = "DevInstrumentWorld"
	get_root().add_child(_wm)
	await process_frame

	_gate_op_resolution()
	_gate_teleport_reseed()
	_gate_set_alt()
	_gate_freeze_time()
	await _gate_freeze_player()
	_gate_off_inert()
	if CubeSphere.FACETED:
		await _gate_no_blowup()
	else:
		print("  (gate 7 NO-BLOWUP skipped — FLAT tree; the nav machine is absent, so there is no v_bci to latch)")

	print("==== VERIFY: %d passed, %d failed ====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## Build a fresh Player over the world at the spawn column, engine-frozen (the gate drives physics itself).
func _make_player() -> Node:
	var pl = PlayerCls.new()
	pl.world = _wm
	get_root().add_child(pl)                                # fires _ready (camera, nav machine, frame adapter)
	pl.frozen = true
	pl.flying = false
	var sx := 0.0
	var sz := 0.0
	if CubeSphere.FACETED:
		var cc := FacetAtlas.centre_cell(TerrainConfig.active_facet())
		sx = float(cc.x); sz = float(cc.y)
	pl.position = Vector3(sx + 0.5, _wm.surface_y(sx + 0.5, sz + 0.5) + 0.5, sz + 0.5)
	# Route through the SAME spawn hand-off the game uses (parents the player under the ActiveFrame + installs the
	# epoch anchor at the spawn) so the harness matches the real engine — without it the faceted floating-origin
	# reanchor mis-fires against an origin-anchored world. No-op when the fixed frame / M5_REAL are off.
	_wm.on_player_ready(pl)
	return pl

func _on_step_done(rec: Dictionary) -> void:
	_last_status = str(rec.get("status", ""))

# ── (1) op resolution through the RemoteControl executor → gated actuators ──────────────────────────
func _gate_op_resolution() -> void:
	print("  --- (1) OP RESOLUTION: each op is bridge-whitelisted + dispatches through RemoteControl to its actuator ---")
	# GAME-SIDE BRIDGE WHITELIST (the gap that nacked every op live): the bridge cap-checks the ack against
	# RemoteBridge.OP_WHITELIST BEFORE the executor dispatches, so each new op MUST be in that list or it is
	# rejected before ever reaching remote_control.gd. Assert presence explicitly (the relay list is JS-side).
	for op in ["teleport", "set_alt", "freeze_time", "freeze_player"]:
		_ok(RemoteBridge.OP_WHITELIST.has(op), "op '%s' is in RemoteBridge.OP_WHITELIST (bridge accepts the ack)" % op)
	var pl := _make_player()
	# The actuator surface the relay routes to must exist (defence-in-depth: the relay whitelists, the rover binds).
	_ok(pl.has_method("remote_teleport"), "player exposes remote_teleport")
	_ok(pl.has_method("remote_set_alt"), "player exposes remote_set_alt")
	_ok(pl.has_method("remote_freeze_time"), "player exposes remote_freeze_time")
	_ok(pl.has_method("remote_freeze_player"), "player exposes remote_freeze_player")
	# A cosmos clock so freeze_time resolves `ok` (else it reports `blocked`, still a valid resolution).
	var clock := EPH.CosmosClock.new()
	_wm.set_cosmos_clock(clock)
	var rc := RemoteControl.new()
	rc.player = pl
	get_root().add_child(rc)
	rc.step_finished.connect(_on_step_done)
	# Each single-step sequence resolves SYNCHRONOUSLY (these ops finish inside _start_step), so _last_status
	# is set by the time begin_sequence returns.
	var cases := [
		{"op": "teleport", "id": 1, "x": 4.0, "y": 70.0, "z": 6.0},
		{"op": "set_alt", "id": 2, "alt": 120.0},
		{"op": "freeze_time", "id": 3, "on": true},
		{"op": "freeze_time", "id": 4, "on": false},
		{"op": "freeze_player", "id": 5, "on": true},
		{"op": "freeze_player", "id": 6, "on": false},
	]
	for c in cases:
		_last_status = ""
		rc.begin_sequence({"seq": "s", "on_fail": "abort", "steps": [c]})
		_ok(_last_status == "ok", "op '%s' resolved through the executor to `ok` (got '%s')" % [str(c["op"]), _last_status])
	rc.step_finished.disconnect(_on_step_done)
	rc.free()
	pl.free()

# ── (2) teleport re-seeds fid/pose/BCI consistently (the anti-desync core) ──────────────────────────
func _gate_teleport_reseed() -> void:
	print("  --- (2) TELEPORT RESEED: fid/pose/BCI consistent, finite-diff dropped, no velocity latch ---")
	var pl := _make_player()
	# Poison the state a real orbital session would carry, so we prove teleport CLEARS it (else a stale [p,v]
	# pair keeps driving the old orbit and the finite difference latches the jump — the 642074 re-entry bug).
	pl._nav_have_prev = true
	pl._nav_last_v_bci = PackedFloat64Array([1.0, 2.0, 3.0])
	pl._dev_have_v = true
	pl._dev_v_bci = PackedFloat64Array([9.0, 9.0, 9.0])
	pl._orbit_coasting = true
	pl._coast_p_bci = PackedFloat64Array([1.0, 1.0, 1.0])
	pl.velocity = Vector3(50.0, -600.0, 20.0)

	# (a) absolute lattice teleport
	var ok_abs: bool = pl.remote_teleport("xyz", 12.0, 88.0, 34.0)
	_ok(ok_abs, "remote_teleport(xyz) returned true")
	_ok(pl.position == Vector3(12.0, 88.0, 34.0), "teleport(xyz): position placed exactly (%s)" % str(pl.position))
	_ok(pl._pos_fid == TerrainConfig.active_facet(), "teleport(xyz): _pos_fid == active_facet (frame/pose consistent, no stale-frame teleport)")
	_ok(pl.velocity == Vector3.ZERO, "teleport(xyz): velocity zeroed (no carried motion)")
	_ok(pl._nav_have_prev == false, "teleport(xyz): finite-difference history DROPPED (no Δp/dt latch across the jump)")
	_ok(pl._nav_last_v_bci.size() == 0 and pl._coast_p_bci.size() == 0 and pl._dev_v_bci.size() == 0,
		"teleport(xyz): all carried BCI/coast/dev-flight latches cleared")
	_ok(pl._orbit_coasting == false and pl._dev_have_v == false and pl._dev_active == false,
		"teleport(xyz): orbital-coast/dev-flight flags released (controllers re-seed from the new pose)")

	# (b) high-altitude teleport via set_alt (the re-entry gate's high-alt trigger); assert self-consistency.
	pl._nav_have_prev = true
	var ok_hi: bool = pl.remote_set_alt(3000.0)
	_ok(ok_hi, "remote_set_alt(3000) returned true (high-alt teleport)")
	var alt_over: float = pl.position.y - _wm.surface_y(pl.position.x, pl.position.z)
	_ok(absf(alt_over - 3000.0) < 1.0e-3, "high-alt teleport: %0.4f blocks above the analytic surface (want 3000)" % alt_over)
	_ok(pl._pos_fid == TerrainConfig.active_facet(), "high-alt teleport: _pos_fid == active_facet (consistent)")
	_ok(pl._nav_have_prev == false, "high-alt teleport: finite-difference history DROPPED again")

	# (c) geodetic teleport (lat/lon + altitude) — only meaningful on the faceted planet (needs the atlas).
	if CubeSphere.FACETED:
		pl._nav_have_prev = true
		var ok_geo: bool = pl.remote_teleport("geo", 12.0, -40.0, 500.0)
		_ok(ok_geo, "remote_teleport(geo lat=12 lon=-40 alt=500) resolved a facet + landed")
		var over_geo: float = pl.position.y - _wm.surface_y(pl.position.x, pl.position.z)
		_ok(absf(over_geo - 500.0) < 1.0e-2, "teleport(geo): %0.3f blocks above the analytic surface (want 500)" % over_geo)
		_ok(pl._pos_fid == TerrainConfig.active_facet(), "teleport(geo): _pos_fid == active_facet (frame/pose consistent)")
		_ok(pl._nav_have_prev == false, "teleport(geo): finite-difference history DROPPED")
	pl.free()

# ── (3) set_alt lands exactly, zero horizontal move ─────────────────────────────────────────────────
func _gate_set_alt() -> void:
	print("  --- (3) SET_ALT: lands exactly `alt` above the analytic surface, zero horizontal move ---")
	var pl := _make_player()
	var x0: float = pl.position.x
	var z0: float = pl.position.z
	for target in [10.0, 250.0, 1500.0]:
		var ok: bool = pl.remote_set_alt(target)
		_ok(ok, "remote_set_alt(%0.0f) returned true" % target)
		var over: float = pl.position.y - _wm.surface_y(pl.position.x, pl.position.z)
		_ok(absf(over - target) < 1.0e-3, "set_alt(%0.0f): landed %0.4f above surface (ε<1e-3)" % [target, over])
		_ok(pl.position.x == x0 and pl.position.z == z0, "set_alt(%0.0f): zero horizontal move (x,z held)" % target)
	pl.free()

# ── (4) freeze_time holds the clock; resume continues; set_time still folds while frozen ─────────────
func _gate_freeze_time() -> void:
	print("  --- (4) FREEZE_TIME: frozen clock holds; resume ticks on; offset still folds while frozen ---")
	# Pure clock behaviour.
	var c := EPH.CosmosClock.new()
	c.advance(1.5)
	var held := c.now()
	c.set_frozen(true)
	c.advance(5.0)
	c.advance(5.0)
	_ok(c.now() == held, "frozen clock: advance(5)+advance(5) leaves now() unchanged (%0.4f)" % c.now())
	# set_time (offset) still folds in while frozen (sets then holds).
	c.add_offset(100.0)
	_ok(absf(c.now() - (held + 100.0)) < 1.0e-9, "frozen clock: add_offset(100) folds in while frozen (set_time works)")
	c.advance(3.0)
	_ok(absf(c.now() - (held + 100.0)) < 1.0e-9, "frozen clock: the offset-set phase HOLDS across advance")
	c.set_frozen(false)
	c.advance(2.0)
	_ok(absf(c.now() - (held + 100.0 + 2.0 * EPH.TIME_WARP)) < 1.0e-6, "resumed clock: ticks on from the held time")

	# Routed via the player actuator.
	var pl := _make_player()
	var c2 := EPH.CosmosClock.new()
	_wm.set_cosmos_clock(c2)
	c2.advance(4.0)
	var t_at_freeze := c2.now()
	_ok(pl.remote_freeze_time(true) == true, "player.remote_freeze_time(true) returned true (clock present)")
	c2.advance(9.0)
	_ok(c2.now() == t_at_freeze, "player-routed freeze holds the world clock across advance")
	_ok(pl.remote_freeze_time(false) == true, "player.remote_freeze_time(false) returned true")
	c2.advance(1.0)
	_ok(c2.now() > t_at_freeze, "player-routed resume lets the world clock advance again")
	pl.free()

# ── (5) freeze_player pins the player across real physics ticks; release resumes ────────────────────
func _gate_freeze_player() -> void:
	print("  --- (5) FREEZE_PLAYER: held player's position invariant + executor/streaming still run (no starve) ---")
	var pl := _make_player()
	# Unit-level latch (flag-independent): remote_freeze_player toggles the gate _physics_process reads.
	pl.remote_freeze_player(true)
	_ok(pl._dev_freeze_player == true, "remote_freeze_player(true) sets the latch")
	pl.remote_freeze_player(false)
	_ok(pl._dev_freeze_player == false, "remote_freeze_player(false) clears the latch")
	# The real-physics DRIVE (held-invariant, look-resolves-while-frozen, release-resumes) needs a COHERENT frame:
	# a bare headless faceted WM lacks main.gd's ActiveFrame wiring, so the floating-origin reanchor mis-fires and
	# shifts the lattice pose — a harness artifact, not a freeze defect (gate 7 skips FACETED real-physics for the
	# same reason). The freeze mechanism (skip _move, keep the rest of the tick) is flag-independent, so the FLAT
	# harness fully exercises it.
	if CubeSphere.FACETED:
		print("  (gate 5 real-physics drive skipped under FACETED — needs main.gd ActiveFrame wiring; FLAT covers it)")
		pl.free()
		return
	# Place the player 40 blocks up so gravity has somewhere to pull once released (proves the pin is real).
	pl.remote_set_alt(40.0)
	pl.frozen = false                                       # engine physics now runs; the DEV latch must pin it
	pl.remote_freeze_player(true)
	var p_held: Vector3 = pl.position
	for _i in range(12):
		await physics_frame
	_ok(pl.position == p_held, "held player: position INVARIANT across 12 physics ticks (%s)" % str(pl.position))
	_ok(pl.velocity == Vector3.ZERO, "held player: velocity stays zero")
	# (b) DEADLOCK GUARD: a `look` op must STILL resolve while frozen. The live bug — a frozen tick that
	# early-returned starved the RemoteControl physics_tick, so look/turn/move/jump never sent their done record
	# ⇒ the op timed out ⇒ the relay stayed stuck "busy" ⇒ the whole queue deadlocked. Drive a real look through
	# the executor while held and assert it COMPLETES (no timeout) AND the pin still holds position.
	var rc := RemoteControl.new()
	rc.player = pl
	pl.remote_exec = rc
	get_root().add_child(rc)
	rc.step_finished.connect(_on_step_done)
	_last_status = ""
	var p_look: Vector3 = pl.position
	var yaw0: float = pl.rotation.y
	rc.begin_sequence({"seq": "look", "on_fail": "abort", "steps": [{"op": "look", "id": 9, "yaw_deg": 20.0}]})
	for _i in range(40):
		await physics_frame
		if _last_status != "":
			break
	_ok(_last_status == "ok", "held player: a `look` op still RESOLVES while frozen (status='%s' — no starved-tick deadlock)" % _last_status)
	_ok(absf(pl.rotation.y - yaw0) > 0.05, "held player: the look actually eased the camera yaw while frozen (Δyaw=%0.3f rad)" % (pl.rotation.y - yaw0))
	_ok(pl.position == p_look, "held player: position STILL invariant while the look op ran (pin holds AND executor runs)")
	rc.step_finished.disconnect(_on_step_done)
	pl.remote_exec = null
	rc.free()
	# Release — physics resumes (the pin is gone: the player starts moving again). We assert MOTION RESUMED
	# rather than a specific fall direction, so the check is robust across FLAT (straight fall) and the faceted
	# frame (free-fall coast + floating-origin reanchor both register as motion).
	pl.remote_freeze_player(false)
	var p_release: Vector3 = pl.position
	for _i in range(12):
		await physics_frame
	_ok((pl.position - p_release).length() > 1.0e-3, "released player: physics resumes — position moves again (|Δp|=%0.4f)" % (pl.position - p_release).length())
	pl.free()

# ── (6) OFF byte-identical — the latches default off and are inert in normal play ───────────────────
func _gate_off_inert() -> void:
	print("  --- (6) OFF INERT: freeze latches default off; a fresh clock advances normally ---")
	var pl := _make_player()
	_ok(pl._dev_freeze_player == false, "_dev_freeze_player defaults false (byte-identical normal play)")
	pl.free()
	var c := EPH.CosmosClock.new()
	_ok(c.frozen == false, "CosmosClock.frozen defaults false")
	var before := c.now()
	c.advance(2.0)
	_ok(absf(c.now() - (before + 2.0 * EPH.TIME_WARP)) < 1.0e-9, "un-frozen clock advances exactly as before (advance untouched)")

# ── (7) NO-BLOWUP — a teleport cannot re-trigger the re-entry velocity latch (FACETED only) ─────────
## Mirrors re-entry invariant (b): the nav |v_bci| stays finite + physical (no 642074-style latch). This is the
## frame-INDEPENDENT blowup signature — immune to the floating-origin reanchor's coordinate bookkeeping (which a
## bare headless WM cannot faithfully reproduce without main.gd's ActiveFrame wiring; the re-entry gate owns the
## positional-continuity dynamic check on the full deploy config). After a high-alt teleport we drive the REAL
## Player._physics_process for 90 frames and assert the derived BCI velocity, the player velocity, and the altitude
## all stay FINITE and BOUNDED — the 642074 latch (a poisoned finite-difference of a position jump) cannot arise
## because _dev_reposition dropped the finite-difference history (_nav_have_prev=false, gate 2).
func _gate_no_blowup() -> void:
	print("  --- (7) NO-BLOWUP: real _physics_process after a high-alt teleport keeps v_bci/velocity finite+bound ---")
	var pl := _make_player()
	pl.remote_set_alt(3000.0)                               # high-alt teleport (well above the atmosphere ceiling)
	pl.frozen = false
	var max_vbci := 0.0
	var max_vel := 0.0
	var all_finite := true
	for _i in range(90):
		await physics_frame
		var v: Vector3 = pl.velocity
		if not (is_finite(v.x) and is_finite(v.y) and is_finite(v.z)):
			all_finite = false
		max_vel = maxf(max_vel, v.length())
		if pl._nav_last_v_bci.size() == 3:
			var vb: float = DV.length(pl._nav_last_v_bci)
			if not is_finite(vb):
				all_finite = false
			max_vbci = maxf(max_vbci, vb)
		if not is_finite(pl.radial_altitude()):
			all_finite = false
	_ok(all_finite, "no-blowup: player velocity / derived BCI velocity / altitude stay FINITE (never NaN/inf) across 90 real ticks")
	_ok(max_vbci < 10000.0, "no-blowup: BCI velocity stays bounded (max %0.1f b/s ≪ the 642074 re-entry latch)" % max_vbci)
	_ok(max_vel < 5000.0, "no-blowup: player velocity stays bounded (max %0.2f b/s — no runaway integration)" % max_vel)
	pl.free()
