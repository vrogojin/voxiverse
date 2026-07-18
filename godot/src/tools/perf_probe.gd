class_name PerfProbe
extends RefCounted
## SN_PERF_PROBE — THROWAWAY per-subsystem frame-timing probe (2026-07-18). NOT a shipped feature: it exists
## only to localize the unsolved landing FREEZE (on touchdown, player STATIONARY, frame time DOUBLES
## 200→…→16000 ms and never recovers, yet every existing cost is idle — vox_gen=0, draws flat, vt_total≈0).
## The culprit is therefore an UN-instrumented per-frame GDScript subsystem whose work scales with the frame
## delta. This probe wraps each candidate per-frame block in a usec timer, keeps the WORST single-frame ms per
## named block over the current telemetry window, and RemoteBridge emits each as a `pp_<name>` field — so a
## live spiral shows WHICH subsystem's ms is doubling.
##
## USAGE (at each call site):
##     var t0 := PerfProbe.t()
##     <the block to time>
##     PerfProbe.mark("move", t0)
##
## GATING / ZERO-OVERHEAD: everything hangs off SN_PERF_PROBE (captured into `enabled` at class load). With the
## flag OFF, mark() early-returns without touching the dict and take() returns {} (merges nothing), so the only
## residual is a pair of Time.get_ticks_usec() reads per site — no state change, no allocation. FLAT
## verify_feature stays 6035/0 (it never runs the frame loops anyway). REMOVE this file once the freeze is found.
##
## THREADING: all call sites are on the main/physics thread (single-threaded w.r.t. these timers), so the plain
## Dictionary needs no lock. `_worst` holds a FIXED, small set of keys (~16 subsystem names) with int values, so
## even if take() is never called (SN_PERF_PROBE on but no RemoteBridge active) it stays bounded — never OOMs.

## Captured once from the compile-time flag. A pure diagnostic switch — deploy flips SN_PERF_PROBE via sed.
static var enabled := CubeSphere.SN_PERF_PROBE

## name (String) -> worst usec observed for that block in the CURRENT window. Cleared by take() each window.
static var _worst: Dictionary = {}


## Start-of-block timestamp (usec). Cheap enough to call unconditionally; the gating is in mark().
static func t() -> int:
	return Time.get_ticks_usec()


## Fold this block's elapsed time into the window maximum for `name`. No-op with the flag off.
static func mark(name: String, t0: int) -> void:
	if not enabled:
		return
	var d := Time.get_ticks_usec() - t0
	if d > int(_worst.get(name, 0)):
		_worst[name] = d


## Latch + RESET the window: return {"pp_<name>": worst_ms, …} (0.01 ms precision) and clear the accumulator.
## Returns {} when nothing was recorded (flag off, or no marks this window) so a RemoteBridge merge adds nothing.
static func take() -> Dictionary:
	if _worst.is_empty():
		return {}
	var out: Dictionary = {}
	for k in _worst:
		out["pp_" + String(k)] = snappedf(float(_worst[k]) / 1000.0, 0.01)
	_worst.clear()
	return out
