---
name: voxiverse-postport-apply-bound
description: Post-C++-port (2026-07-17 PM) perf verdict — streaming is now APPLY/upload-bound not gen-bound; crossing C1=343ms; periodic 2s-capture + 0.5s-snowfall spikes; plan in COSMOS-PERF-POSTPORT-DESIGN.md
metadata: 
  node_type: memory
  type: project
---

Post-FP_CPPGEN landscape (measured 2026-07-17 evening, docs/COSMOS-PERF-POSTPORT-DESIGN.md):
gen drains 322–964 blocks/s (was 26–34), backlog nonzero only 21% of active windows — supply ≥
demand everywhere, [[voxiverse-web-perf-architecture]]'s "permanent scarcity" premise is INVERTED.
The pipeline pacer moved to the main thread: quantized ramp shells (p50 270 blocks/window) arrive
as compressed mesh-apply/upload bursts; vox_main (never nonzero pre-port) spikes to 87 inside the
300–881 ms frames. Every crossing has a ≥290 ms frame in ±2 s (C1 p50=343); part of the crossing
stall happens with ALL voxel queues zero — prime suspect far-ring re-emit single add_surface swap
(needs T2e GDScript timer to convict). vt_* reads only the ACTIVE terrain (module_world.gd:1990) —
imminent-slot cost invisible; gen_ct_*/gen_ms_* telemetry DEAD under FP_CPPGEN (GDScript timer
bypassed). Periodic standing spikes: 2 s remote-bridge capture readback ~35 ms (skip-gate at 45 ms
manufactures alternation → pollutes all evenness data; use ?frames=0 for metric runs) + 0.5 s
snowfall step (≤4 remeshes). Standing 30 fps floor = HOST throttling (floor_p10 drifts 15→31 ms on
a frozen scene) — interleave A/B arms in one session. Plan: T2 instrument batch first (flag
provenance, far-ring timer, all-terrain vt, engine timespread/receive/upload_bytes + heap line),
then P1 FP_INFLIGHT_GATE (admit by gen+mesh+K·main, not vox_gen>300), P2 crossing spreading
(prefill-128 under fixed frame, ramped from-shrink, chunked ring swap), P3 apply-order
gaze/nearest-first engine patch + R9 idle-lead. R4 cancel patch and R6 gaze viewer DEMOTED;
"continuous re-prioritization" now means reordering APPLIES, not gen.
