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
var _win := PackedFloat64Array()               # sliding frame-cost window (CTRL_WINDOW_FRAMES measured frame-delta samples)
var _win_i := 0
var _win_fill := 0
var _frame_worst_ema := 0.0                    # EMA of the window p90 (§P2, was max) — the setpoint-comparison signal
var _backlog := 0                              # last polled vox_gen backlog (feed-forward)
var _last_tick_s := -1.0                       # injected-clock time of the last control update (−1 = not started)
var _promote_hold_s := 0.0                     # seconds credit has sat ≥ CTRL_PROMOTE_CREDIT with the backlog gate open
var _headroom_hold_s := 0.0                    # seconds credit has sat ≥ CTRL_PROMOTE_CREDIT IGNORING the backlog gate —
                                               # the IMMINENT-promote sustain (W1): the ridge you are crossing must promote
                                               # on frame HEADROOM alone (vox_gen naturally sits 1500-2800 while walking, so
                                               # the raw backlog gate would otherwise suppress it → silent spawn-at-cross).
var _overload_hold_s := 0.0                    # seconds of sustained credit-0 overload (drives demote_pressure)
var _ticks := 0                                # control ticks since start (diagnostics)
var _overload := false                         # last control tick's overload verdict (diagnostics)
# L5 (COSMOS-PERF §1.2): the ADAPTIVE floor-relative overload setpoint. `_adaptive` defaults to the const so the LIVE
# controller (created only under FP_M2_LOD) picks it up with no wiring; the gates override it per-controller via
# set_adaptive() so each gate pins the exact mode it asserts. `_floor` is a long rolling frame-sample window whose p10
# is this client's achievable floor; `_setpoint_ms` is the last effective overload threshold (const 18 in absolute mode,
# clamp(floor_p10 × margin, 18, 45) in adaptive mode) — exposed via stats() for the gate + PerfHUD.
var _adaptive: bool = CubeSphere.FP_CTRL_ADAPTIVE
var _floor := PackedFloat64Array()             # rolling frame-cost window for the best-floor p10 (CTRL_FLOOR_WINDOW_FRAMES)
var _floor_i := 0
var _floor_fill := 0
var _setpoint_ms := CubeSphere.CTRL_FRAME_BUDGET_MS

func _init() -> void:
	_win.resize(CubeSphere.CTRL_WINDOW_FRAMES)
	_floor.resize(CubeSphere.CTRL_FLOOR_WINDOW_FRAMES)

## Inject the load source (§6.5.7). `src` is duck-typed: `poll() -> Dictionary {"frame_ms": float, "backlog": int}`.
## Live: `StreamLoadController.LiveSource.new()` (reads Performance + VoxelEngine). Headless: a synthetic source.
## null → the controller reads a neutral zero-load signal and credit floats to 1 (the flag-off / no-source default).
func set_input_source(src: Object) -> void:
	_src = src

## L5 (COSMOS-PERF §1.2): pin the overload setpoint mode for THIS controller, overriding the FP_CTRL_ADAPTIVE default.
## true → floor-relative adaptive setpoint (overload ⇔ worse than this client's own floor); false → the absolute
## CTRL_FRAME_BUDGET_MS. The gates call this to assert each mode deterministically regardless of the shipped const.
func set_adaptive(on: bool) -> void:
	_adaptive = on

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
	# push this frame's measured cost into the sliding window (the binding statistic is the p90 over the window, §P2)
	_win[_win_i] = fm
	_win_i = (_win_i + 1) % CubeSphere.CTRL_WINDOW_FRAMES
	_win_fill = mini(_win_fill + 1, CubeSphere.CTRL_WINDOW_FRAMES)
	# L5: push the same sample into the long best-floor window (its p10 is the adaptive setpoint's floor). Inert with the
	# flag off — it never touches credit — so this is byte-identical to shipped when _adaptive is false.
	_floor[_floor_i] = fm
	_floor_i = (_floor_i + 1) % CubeSphere.CTRL_FLOOR_WINDOW_FRAMES
	_floor_fill = mini(_floor_fill + 1, CubeSphere.CTRL_FLOOR_WINDOW_FRAMES)
	if _last_tick_s < 0.0:
		_last_tick_s = now_s
		_frame_worst_ema = fm
		return
	var dt := now_s - _last_tick_s
	if dt < CubeSphere.CTRL_TICK_S:
		return
	_last_tick_s = now_s
	_ticks += 1
	# W2 — the sustain accumulators must accrue in REAL-TICK units, never a background-gap of raw wall-clock. A tab
	# backgrounded / a GC pause on web produces ONE giant tick (dt tens of seconds); advancing a hold by the full raw
	# dt would instantly "satisfy" a sustained-for-N-seconds condition → a spurious spawn/demote on refocus. Two guards:
	#  (1) clamp the per-tick increment to CTRL_TICK_S, so a hold reflects the NUMBER of real control ticks it survived;
	#  (2) a giant tick is a DISCONTINUITY, not evidence — RESET every hold (a gap is not sustained load).
	var adt := minf(dt, CubeSphere.CTRL_TICK_S)
	var gap := dt > CubeSphere.CTRL_TICK_S * 4.0
	# frame_worst = the window p90 (COSMOS-FP-M2-CONTROLLER-FIX §P2 — was max), EMA'd so a single spike is noise
	# (§6.5.2/§6.5.4). Deterministic order statistic: sort the filled window, index ceil(PCTL·fill)−1. A *max* holds
	# overload forever off one browser-normal dropped frame per half-second (§1.2); p90 tolerates ≤3 stutter frames per
	# window while still reading a sustained 30 fps (all deltas 33 ms → p90 = 33 > 18) as overload. Under a CONSTANT
	# signal p90 ≡ max, so every G-M2-CTRL square-wave credit trace is bit-identical to the pre-change max statistic.
	var worst := 0.0
	if _win_fill > 0:
		var samp := PackedFloat64Array()
		samp.resize(_win_fill)
		for i in range(_win_fill):
			samp[i] = _win[i]
		samp.sort()
		var idx := int(ceil(CubeSphere.CTRL_WINDOW_PCTL * float(_win_fill))) - 1
		worst = samp[clampi(idx, 0, _win_fill - 1)]
	_frame_worst_ema = _frame_worst_ema + _EMA_ALPHA * (worst - _frame_worst_ema)
	# L5 (COSMOS-PERF §1.2): the overload setpoint. Absolute (shipped) = CTRL_FRAME_BUDGET_MS. Adaptive = relative to
	# THIS client's own achievable floor (floor_p10 × margin, clamped [BUDGET, ADAPTIVE_MAX]) so a 30-fps-floor client at
	# a steady 33 ms is NOT flagged overloaded (setpoint ≈ 43) — un-pinning credit — while a genuine spike above its floor
	# still is. The clamp floor == CTRL_FRAME_BUDGET_MS ⇒ adaptive is never STRICTER than shipped (only relaxes upward).
	_setpoint_ms = CubeSphere.CTRL_FRAME_BUDGET_MS
	if _adaptive:
		_setpoint_ms = clampf(_floor_p_low() * CubeSphere.CTRL_ADAPTIVE_MARGIN,
			CubeSphere.CTRL_FRAME_BUDGET_MS, CubeSphere.CTRL_ADAPTIVE_MAX_MS)
	# AIMD (§6.5.3): multiplicative decrease on overload, additive increase under headroom. Anti-windup by the clamp.
	_overload = _frame_worst_ema > _setpoint_ms
	if _overload:
		_credit *= CubeSphere.CTRL_CREDIT_MDF
		if _credit <= _CREDIT_ZERO_SNAP:
			_credit = 0.0
	else:
		_credit = minf(1.0, _credit + CubeSphere.CTRL_CREDIT_AI)
	if gap:
		# discontinuity: the sustain evidence prior to the gap does not carry across it — restart every hold fresh.
		_promote_hold_s = 0.0
		_headroom_hold_s = 0.0
		_overload_hold_s = 0.0
		return
	# imminent-promote sustain (W1): credit ≥ PROMOTE_CREDIT, IGNORING the backlog gate (the ridge we are crossing is
	# exempt from the raw vox_gen gate — it must go full-res on frame headroom alone, §3.2/§6.5.3.4).
	if _credit >= CubeSphere.CTRL_PROMOTE_CREDIT:
		_headroom_hold_s += adt
	else:
		_headroom_hold_s = 0.0
	# corner/2nd-promote sustain: credit ≥ PROMOTE_CREDIT WITH the backlog gate OPEN for CTRL_PROMOTE_SUSTAIN_S (§6.5.3.4)
	if _credit >= CubeSphere.CTRL_PROMOTE_CREDIT and not backlog_gated():
		_promote_hold_s += adt
	else:
		_promote_hold_s = 0.0
	# demote pressure: only SUSTAINED credit-0 overload (≥ CTRL_OVERLOAD_SUSTAIN_S) — pause-first, never a spike (§6.5.4)
	if _overload and _credit <= 0.0:
		_overload_hold_s += adt
	else:
		_overload_hold_s = 0.0

## L5: this client's achievable floor — the p10 of the long rolling frame window. Deterministic order statistic (same
## sort-then-index form as the window p90, §P2): under a CONSTANT signal p10 ≡ the constant, so a gate square wave is
## bit-reproducible. Empty window → CTRL_FRAME_BUDGET_MS (the setpoint then clamps to the absolute budget — conservative
## until enough samples accrue). A single early 0.0 sample cannot lower p10 once the window holds ≥10 real samples.
func _floor_p_low() -> float:
	if _floor_fill <= 0:
		return CubeSphere.CTRL_FRAME_BUDGET_MS
	var samp := PackedFloat64Array()
	samp.resize(_floor_fill)
	for i in range(_floor_fill):
		samp[i] = _floor[i]
	samp.sort()
	var idx := int(ceil(CubeSphere.CTRL_FLOOR_PCTL * float(_floor_fill))) - 1
	return samp[clampi(idx, 0, _floor_fill - 1)]

# ---- the ONE credit + the four admission surfaces (§6.5.3) ----

## The raw AIMD admission credit ∈ [0,1].
func credit() -> float:
	return _credit

## Surface 1 — the LOD main-thread apply budget: base × max(credit, RELIEF_FLOOR). Floored at the relief credit (§P3a)
## so built meshes still swap in at credit 0 (base 2 ms → 0.5 ms/frame); the mesher's relief-only candidate restriction
## keeps this bounded to COVERAGE, not refinement luxury. NEVER-OOM caps are still checked after admission (§4).
func apply_budget_ms(base_ms: float) -> float:
	return base_ms * maxf(_credit, CubeSphere.CTRL_RELIEF_FLOOR)

## Surface 2 — build-job grants admitted this tick: ceil(base × max(credit, RELIEF_FLOOR)). Floored at the relief credit
## (§P3a) so the budgeter still enqueues ≥1 coverage grant/tick at credit 0 (base 2 → 1 grant); the relief-only
## restriction bounds it to meshless facets + the imminent ridge. Denials still funnel through the ledger/LRU path (§4).
func grant_count(base: int = 2) -> int:
	return int(ceil(float(base) * maxf(_credit, CubeSphere.CTRL_RELIEF_FLOOR)))

## §P3a — relief mode: credit below the relief floor. The mesher restricts its budgeter to COVERAGE (meshless facets +
## the imminent ridge) while this holds — the floor buys first-cover, never SSE refinement of already-covered scenery.
func relief_only() -> bool:
	return _credit < CubeSphere.CTRL_RELIEF_FLOOR

## Surface 3 — the pool view-ramp pace fed to module_world.set_stream_pace: the credit, HELD AT ZERO while the
## vox_gen backlog gate is closed (new full-res volume is never admitted onto a pool that has not drained, §6.5.3.4).
func stream_pace() -> float:
	return 0.0 if backlog_gated() else _credit

## Surface 4 — is a live-terrain promote (or a finer-ℓ grant for an already-covered facet) admitted? Requires the
## backlog gate open AND credit ≥ CTRL_PROMOTE_CREDIT sustained for CTRL_PROMOTE_SUSTAIN_S — promotions start only
## into real headroom (§6.5.3.4). Consumed by the M2d pool policy.
func promote_admitted() -> bool:
	return (not backlog_gated()) and _promote_hold_s >= CubeSphere.CTRL_PROMOTE_SUSTAIN_S and _credit >= CubeSphere.CTRL_PROMOTE_CREDIT

## Surface 4 (imminent, W1) — is the SINGLE highest-priority imminent live-terrain promote admitted? The ridge the
## player is committed to crossing is EXEMPT from the raw vox_gen backlog gate (while walking vox_gen naturally sits
## 1500-2800, which would otherwise suppress the crossing promote → silent fall-back to spawn-at-cross + a pool-miss);
## it requires only sustained frame HEADROOM (credit ≥ PROMOTE_CREDIT for CTRL_PROMOTE_SUSTAIN_S). The 2nd/corner
## promote keeps the full promote_admitted() gate — the feed-forward throttle applies to that EXTRA generation volume.
func promote_imminent_admitted() -> bool:
	return _headroom_hold_s >= CubeSphere.CTRL_PROMOTE_SUSTAIN_S and _credit >= CubeSphere.CTRL_PROMOTE_CREDIT

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
		"backlog_gated": backlog_gated(), "overload": _overload, "ticks": _ticks, "relief_only": relief_only(),
		"promote_hold_s": _promote_hold_s, "headroom_hold_s": _headroom_hold_s, "overload_hold_s": _overload_hold_s,
		"adaptive": _adaptive, "setpoint_ms": _setpoint_ms, "floor_p10_ms": _floor_p_low(),
	}

# ============================ live input source (§6.5.1) ============================

## The LIVE measured-load source: the main-thread frame cost as the MEASURED wall delta between successive polls
## (COSMOS-FP-M2-CONTROLLER-FIX §P1) + the vox_gen backlog (VoxelEngine.get_stats().tasks.generation). poll() is called
## exactly once per frame from WorldManager._process, so the inter-poll delta IS the frame period. This REPLACES the
## former Performance.TIME_PROCESS + TIME_PHYSICS_PROCESS read, which on the threaded web export is invalid as a frame
## cost — it folds in the browser present/rAF wait under the emscripten threaded loop and never read below ~18 ms even
## at a demonstrably idle 60 fps (77 ms median in the live telemetry), asserting overload from boot and pinning credit
## at 0 for the whole session (§1.1). Each sample is clamped to CTRL_FRAME_SAMPLE_CLAMP_MS so a backgrounded tab (a
## multi-second inter-poll gap) cannot poison the window; the first poll returns 0.0 (neutral). Wall-clock use stays
## CONFINED to this class, which the headless gates never construct — they inject a deterministic synthetic source, so
## determinism (§6.5.7) is intact.
class LiveSource extends RefCounted:
	var _ve: Object = null
	var _last_usec := -1
	func _init() -> void:
		if Engine.has_singleton("VoxelEngine"):
			_ve = Engine.get_singleton("VoxelEngine")
	func poll() -> Dictionary:
		var now := Time.get_ticks_usec()
		var frame_ms := 0.0
		if _last_usec >= 0:
			frame_ms = minf(float(now - _last_usec) / 1000.0, CubeSphere.CTRL_FRAME_SAMPLE_CLAMP_MS)
		_last_usec = now
		var backlog := 0
		if _ve != null and _ve.has_method("get_stats"):
			var st: Dictionary = _ve.call("get_stats")
			backlog = int((st.get("tasks", {}) as Dictionary).get("generation", 0))
		return {"frame_ms": frame_ms, "backlog": backlog}
