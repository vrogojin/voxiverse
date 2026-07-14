class_name StreamLoadController
extends RefCounted
## COSMOS FP-M2c (docs/COSMOS-FP-M2-DESIGN.md §6.5) — the closed-loop load-adaptive admission controller. ONE small
## shared object, OWNED by WorldManager, READ by FacetLodMesher (LOD apply-ms + build grants, surfaces 1-2) and
## module_world (the pool view-ramp pace, surface 3). It converts a measured main-thread load signal into a single
## admission `credit ∈ [0,1]` by AIMD (×0.5 on overload, +0.1 under headroom) and exposes the FOUR admission
## surfaces (§6.5.3) as pure accessors. NEVER-OOM caps are checked AFTER the controller and are independent (§6.5.6):
## full credit cannot admit past a memory cap, zero credit cannot exempt eviction.
##
## DETERMINISM (§6.5.7): the controller is the ONLY load-adaptive element and reads its inputs through an INJECTABLE
## source (`set_input_source`) and an INJECTED clock (`tick(now_s)`) — never the wall clock. Live web passes a real
## Performance/VoxelEngine source + real time; the headless gates pass a synthetic square-wave source + a synthetic
## fixed-step clock, so the whole credit trace is bit-reproducible and machine-speed cannot perturb a gate. The inner
## feed-forward bounds the budgeter uses (queue caps, est-seconds, tier targets, memory ledgers) are FIXED and
## load-independent, so every non-controller gate runs the controller forced fully-open (credit pinned 1).

# ---- controller-internal tuning (implementation detail; the §6 policy consts live in cube_sphere.gd) ----
const _EMA_ALPHA := 0.5           # per-tick EMA weight for frame_worst — half-life ≈ one CTRL_TICK_S (§6.5.1 "≈0.5s")
const _CREDIT_ZERO_SNAP := 0.1    # below this the multiplicative decrease snaps to 0 (so credit reaches 0 in ≤4 ticks)

# ---- state ----
var _src: Object = null                        # injectable input source (duck-typed: poll() -> {frame_ms, backlog})
var _credit := 1.0                             # the AIMD admission credit ∈ [0,1]
var _win := PackedFloat64Array()               # sliding worst-frame window (CTRL_WINDOW_FRAMES frame-cost samples)
var _win_i := 0
var _win_fill := 0
var _frame_worst_ema := 0.0                    # EMA of the window's worst frame — the setpoint-comparison signal
var _backlog := 0                              # last polled vox_gen backlog (feed-forward)
var _last_tick_s := -1.0                       # injected-clock time of the last control update (−1 = not started)
var _promote_hold_s := 0.0                     # seconds credit has sat ≥ CTRL_PROMOTE_CREDIT with the backlog gate open
var _overload_hold_s := 0.0                    # seconds of sustained credit-0 overload (drives demote_pressure)
var _ticks := 0                                # control ticks since start (diagnostics)
var _overload := false                         # last control tick's overload verdict (diagnostics)

func _init() -> void:
	_win.resize(CubeSphere.CTRL_WINDOW_FRAMES)

## Inject the load source (§6.5.7). `src` is duck-typed: `poll() -> Dictionary {"frame_ms": float, "backlog": int}`.
## Live: `StreamLoadController.LiveSource.new()` (reads Performance + VoxelEngine). Headless: a synthetic source.
## null → the controller reads a neutral zero-load signal and credit floats to 1 (the flag-off / no-source default).
func set_input_source(src: Object) -> void:
	_src = src

## Advance one FRAME. `now_s` is the INJECTED clock (live: Time in seconds; gates: a synthetic fixed step) so the
## run is machine-speed-independent. Samples the source every call (feeding the worst-frame window) but only
## recomputes the credit every CubeSphere.CTRL_TICK_S — one bad frame never moves the credit on its own (§6.5.4).
func tick(now_s: float) -> void:
	var fm := 0.0
	var bk := 0
	if _src != null:
		var d: Dictionary = _src.call("poll")
		fm = float(d.get("frame_ms", 0.0))
		bk = int(d.get("backlog", 0))
	_backlog = bk
	# push this frame's cost into the sliding window (worst = max over the window)
	_win[_win_i] = fm
	_win_i = (_win_i + 1) % CubeSphere.CTRL_WINDOW_FRAMES
	_win_fill = mini(_win_fill + 1, CubeSphere.CTRL_WINDOW_FRAMES)
	if _last_tick_s < 0.0:
		_last_tick_s = now_s
		_frame_worst_ema = fm
		return
	var dt := now_s - _last_tick_s
	if dt < CubeSphere.CTRL_TICK_S:
		return
	_last_tick_s = now_s
	_ticks += 1
	# frame_worst = the slowest frame in the window; EMA'd so a single spike is noise (§6.5.2/§6.5.4).
	var worst := 0.0
	for i in range(_win_fill):
		worst = maxf(worst, _win[i])
	_frame_worst_ema = _frame_worst_ema + _EMA_ALPHA * (worst - _frame_worst_ema)
	# AIMD (§6.5.3): multiplicative decrease on overload, additive increase under headroom. Anti-windup by the clamp.
	_overload = _frame_worst_ema > CubeSphere.CTRL_FRAME_BUDGET_MS
	if _overload:
		_credit *= CubeSphere.CTRL_CREDIT_MDF
		if _credit <= _CREDIT_ZERO_SNAP:
			_credit = 0.0
	else:
		_credit = minf(1.0, _credit + CubeSphere.CTRL_CREDIT_AI)
	# promote sustain: credit must sit ≥ PROMOTE_CREDIT with the backlog gate OPEN for CTRL_PROMOTE_SUSTAIN_S (§6.5.3.4)
	if _credit >= CubeSphere.CTRL_PROMOTE_CREDIT and not backlog_gated():
		_promote_hold_s += dt
	else:
		_promote_hold_s = 0.0
	# demote pressure: only SUSTAINED credit-0 overload (≥ CTRL_OVERLOAD_SUSTAIN_S) — pause-first, never a spike (§6.5.4)
	if _overload and _credit <= 0.0:
		_overload_hold_s += dt
	else:
		_overload_hold_s = 0.0

# ---- the ONE credit + the four admission surfaces (§6.5.3) ----

## The raw AIMD admission credit ∈ [0,1].
func credit() -> float:
	return _credit

## Surface 1 — the LOD main-thread apply budget: base × credit (0 → applies pause; built meshes wait, bounded).
func apply_budget_ms(base_ms: float) -> float:
	return base_ms * _credit

## Surface 2 — build-job grants admitted this tick: ceil(base × credit) (credit 0 → the budgeter stops enqueueing).
func grant_count(base: int = 2) -> int:
	return int(ceil(float(base) * _credit))

## Surface 3 — the pool view-ramp pace fed to module_world.set_stream_pace: the credit, HELD AT ZERO while the
## vox_gen backlog gate is closed (new full-res volume is never admitted onto a pool that has not drained, §6.5.3.4).
func stream_pace() -> float:
	return 0.0 if backlog_gated() else _credit

## Surface 4 — is a live-terrain promote (or a finer-ℓ grant for an already-covered facet) admitted? Requires the
## backlog gate open AND credit ≥ CTRL_PROMOTE_CREDIT sustained for CTRL_PROMOTE_SUSTAIN_S — promotions start only
## into real headroom (§6.5.3.4). Consumed by the M2d pool policy.
func promote_admitted() -> bool:
	return (not backlog_gated()) and _promote_hold_s >= CubeSphere.CTRL_PROMOTE_SUSTAIN_S and _credit >= CubeSphere.CTRL_PROMOTE_CREDIT

# ---- feed-forward + stability introspection ----

## The vox_gen feed-forward gate: true while the backlog exceeds CTRL_BACKLOG_MAX (holds surfaces 3-4 at zero).
func backlog_gated() -> bool:
	return _backlog > CubeSphere.CTRL_BACKLOG_MAX

## Sustained-overload demote pressure (§6.5.4): true only after CTRL_OVERLOAD_SUSTAIN_S of continuous credit-0
## overload. The M2d controller then demotes the least-wanted LOD facet ONE tier (pause-first) — live terrains are
## never retired by the controller. A single spike never trips this (it reads the EMA'd overload on the 0.25s tick).
func demote_pressure() -> bool:
	return _overload_hold_s >= CubeSphere.CTRL_OVERLOAD_SUSTAIN_S

## Gate + PerfHUD snapshot.
func stats() -> Dictionary:
	return {
		"credit": _credit, "frame_worst_ema": _frame_worst_ema, "backlog": _backlog,
		"backlog_gated": backlog_gated(), "overload": _overload, "ticks": _ticks,
		"promote_hold_s": _promote_hold_s, "overload_hold_s": _overload_hold_s,
	}

# ============================ live input source (§6.5.1) ============================

## The LIVE measured-load source: the main-thread frame cost (Performance TIME_PROCESS + TIME_PHYSICS_PROCESS, the
## PerfHUD's proc/phys) + the vox_gen backlog (VoxelEngine.get_stats().tasks.generation). Read every frame by tick()
## on the main thread — the SAME reading logic the PerfHUD uses (perf_hud.gd is not modified; this replicates it).
## The headless gates DO NOT use this — they inject a deterministic synthetic source instead.
class LiveSource extends RefCounted:
	var _ve: Object = null
	func _init() -> void:
		if Engine.has_singleton("VoxelEngine"):
			_ve = Engine.get_singleton("VoxelEngine")
	func poll() -> Dictionary:
		var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		var backlog := 0
		if _ve != null and _ve.has_method("get_stats"):
			var st: Dictionary = _ve.call("get_stats")
			backlog = int((st.get("tasks", {}) as Dictionary).get("generation", 0))
		return {"frame_ms": proc_ms + phys_ms, "backlog": backlog}
