class_name PerfProbe
extends RefCounted
## SN_PERF_PROBE — THROWAWAY per-subsystem frame TIMING + MEMORY-DELTA probe (2026-07-18). NOT a shipped
## feature: it exists only to localize the touchdown FREEZE. The timing pass proved the freeze is NOT a
## GDScript compute cost (every pp_* block stayed ≤5 ms while worst_ms doubled to 16000 ms) — instead
## vmem_mb (RENDER_VIDEO_MEM_USED) grows ~0.8 MB EVERY frame while the player is stationary, and the clean
## frame-time doubling is the classic WASM heap-grow/GC thrash off that per-frame leak. So this second pass
## measures MEMORY DELTA per subsystem to pin WHICH block allocates the 0.8 MB.
##
## USAGE (at each call site — capture before, mark after; all locals are ints so NO heap alloc in the hot path):
##     var t0 := PerfProbe.t()
##     var v0 := PerfProbe.vmem()
##     var s0 := PerfProbe.smem()
##     <the block to time>
##     PerfProbe.mark("move", t0)           # worst frame TIME  → pp_move (ms)
##     PerfProbe.mark_mem("move", v0, s0)   # worst +VIDEO/+STATIC mem delta → pp_mem_move (KB) / pp_smem_move (KB)
##
## TWO memory counters, on purpose:
##   • VIDEO  (RENDER_VIDEO_MEM_USED, the SAME counter vmem_mb reads) — where the 0.8 MB is visible. Emitted
##     per subsystem as pp_mem_<name>. CAVEAT: this counter is maintained by the RenderingServer, which runs
##     on its OWN thread in the threaded web export and commits queued mesh/texture uploads at frame boundaries
##     — so a mesh CREATED inside GDScript block X may not register until a later block or the next frame. The
##     per-subsystem VIDEO deltas can therefore UNDER-attribute (read ~0) even when a GDScript block is the
##     true owner. Treat pp_mem_<name> as a positive-signal only: a non-zero one PINS the owner; all-zero does
##     NOT prove "module-side" on its own — cross-check pp_smem_<name>.
##   • STATIC (MEMORY_STATIC / Godot's tracked CPU heap) — updates SYNCHRONOUSLY on every Godot alloc, so a
##     block that RETAINS a Godot object (ArrayMesh, Image, PackedArray, Node) shows a positive delta in that
##     block the same frame. Emitted per subsystem as pp_smem_<name>. CAVEAT: it does NOT count native/module
##     allocations (godot_voxel std::vector, raw malloc, or GPU-only RID uploads) — those live in WASM linear
##     memory outside Godot's static tracker. So a leak that is module-side/GPU-only reads as pp_smem_<name>≈0
##     AND pp_smem_delta≈0 while pp_vmem_delta stays ~0.8 MB — which is itself the answer (fix is module-side).
##
## DECISION TREE for the pilot (compare within ONE telemetry record; pp_vmem_delta / pp_smem_delta are the
## WHOLE-FRAME deltas emitted by RemoteBridge, NOT per-subsystem — no subsystem is named "delta"):
##   pp_vmem_delta ≈ 0.8 MB confirms the per-frame video leak.
##   → some pp_mem_<name> ≈ pp_vmem_delta ....... that GDScript subsystem owns it (best case).
##   → all pp_mem_<name> ≈ 0 but a pp_smem_<name> spikes + pp_smem_delta ≈ that ... that GDScript subsystem
##     owns it (video counter just lagged; the static backstop caught it).
##   → all pp_mem_<name> ≈ 0 AND all pp_smem_<name> ≈ 0 AND pp_smem_delta ≈ 0 while pp_vmem_delta ≈ 0.8 MB ...
##     the leak is GPU-only / native, inside the godot_voxel MODULE or engine, OUTSIDE GDScript → module-side fix.
##
## GATING / ZERO-OVERHEAD: everything hangs off SN_PERF_PROBE (captured into `enabled` at class load). With the
## flag OFF, vmem()/smem() return 0 and mark*/take early-return — the only residual is a few int reads per site,
## no dict writes, no allocation. FLAT verify_feature stays 6035/0 (it never runs the frame loops anyway).
##
## SELF-POLLUTION NOTE: the probe must not itself grow memory each frame, or it would corrupt the very signal.
## The three dicts hold a FIXED, small key set (~18 subsystem names each) — after the first window every key
## exists, so the per-frame marks are int-compare + write-to-existing-key ONLY (no alloc). take()'s string/float
## work runs once per telemetry window (4 Hz), AFTER the deltas are latched. So in steady state (the spiral the
## pilot measures) the probe adds zero per-frame Godot-heap growth. REMOVE this file once the leak is localized.

## Captured once from the compile-time flag. A pure diagnostic switch — deploy flips SN_PERF_PROBE via sed.
static var enabled := CubeSphere.SN_PERF_PROBE

## name (String) -> worst value in the CURRENT window; cleared by take(). _worst=usec, _vworst/_sworst=+bytes.
static var _worst: Dictionary = {}
static var _vworst: Dictionary = {}
static var _sworst: Dictionary = {}


## Start-of-block timestamp (usec). Cheap enough to call unconditionally; the gating is in mark().
static func t() -> int:
	return Time.get_ticks_usec()


## Current VIDEO memory (bytes) — the SAME counter vmem_mb reads. 0 with the flag off (zero-overhead).
static func vmem() -> int:
	if not enabled:
		return 0
	return int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))


## Current STATIC (Godot CPU-heap) memory (bytes). 0 with the flag off.
static func smem() -> int:
	if not enabled:
		return 0
	return int(Performance.get_monitor(Performance.MEMORY_STATIC))


## Fold this block's elapsed time into the window maximum for `name`. No-op with the flag off.
static func mark(name: String, t0: int) -> void:
	if not enabled:
		return
	var d := Time.get_ticks_usec() - t0
	if d > int(_worst.get(name, 0)):
		_worst[name] = d


## Fold this block's POSITIVE video + static memory deltas into the per-name window maxima. v0/s0 are the
## before-snapshots; the after-values are read here. Negative deltas (a free during the block) are ignored —
## we hunt monotonic growth, so only positive retention is folded. No-op with the flag off.
static func mark_mem(name: String, v0: int, s0: int) -> void:
	if not enabled:
		return
	var dv := int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) - v0
	if dv > int(_vworst.get(name, 0)):
		_vworst[name] = dv
	var ds := int(Performance.get_monitor(Performance.MEMORY_STATIC)) - s0
	if ds > int(_sworst.get(name, 0)):
		_sworst[name] = ds


## Latch + RESET the window. Returns {pp_<name>: worst_ms, pp_mem_<name>: +video_KB, pp_smem_<name>: +static_KB}
## and clears the accumulators. {} when nothing was recorded (flag off / no marks) so the RemoteBridge merge
## adds nothing (byte-identical with the flag off).
static func take() -> Dictionary:
	if _worst.is_empty() and _vworst.is_empty() and _sworst.is_empty():
		return {}
	var out: Dictionary = {}
	for k in _worst:
		out["pp_" + String(k)] = snappedf(float(_worst[k]) / 1000.0, 0.01)
	for k in _vworst:
		out["pp_mem_" + String(k)] = snappedf(float(_vworst[k]) / 1024.0, 0.1)
	for k in _sworst:
		out["pp_smem_" + String(k)] = snappedf(float(_sworst[k]) / 1024.0, 0.1)
	_worst.clear()
	_vworst.clear()
	_sworst.clear()
	return out
