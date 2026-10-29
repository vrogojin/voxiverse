---
name: voxiverse-forest-snow-warmskip
description: "2026-08-12 SHIPPED+MERGED PR #56 (main 72453ee) FP_SNOW_PRECIP_GATE — warm-forest snow_ms 18-44ms ROOT = SnowfallSystem steps every biome unconditionally (zero writes); fix = whitelist process only when is_snowing AND ts<0, snow/edit-holding columns keep shipped path (melt-on); LIVE snow_ms→0.02-0.44ms; CAVEAT forest fps STILL ~30 (snow NOT the limiter — residual render/vsync floor, see #119)"
metadata: 
  node_type: memory
  type: project
---

2026-08-12 live warm forest (facet 1754, 18.8°C, fully prebaked) snow_ms bursts 18-44 ms on the
main thread; windows with snow_ms>10 have proc_ms p50 54.9 vs 27.7 without. ROOT (measured with
godot/src/tools/probe_snow_cost.gd — warm zero-write step = 6.4 ms NATIVE): the SnowfallSystem
0.5 s step runs in EVERY biome; a warm column pays 2× unmemoized faceted column_profile
(snowfall_system.gd:235 + per_voxel_environment.gd:123 via apply_state_transitions→sample;
facet_profile has NO memo, terrain_config.gd:1058) + 2-3 cell_value_at→generated_cell resolves
(tree canopy in forest) + the M1 evaluator, then writes nothing. FP_SNOW_SLICED (R2, task #55)
is default-off and NOT flipped in the deploy sed (live burst signature ≠ 8-col drain); R2 never
moved the sim off-thread, only de-bursts.

**Why:** dormant-by-default was enforced spatially (region+caps) but never THERMALLY — no
biome/temperature suppressor existed (only airborne/orbital/load-defer, world_manager.gd:790-800).

**How to apply:** fix v2 (user-directed whitelist) = FP_SNOW_PRECIP_GATE in _process_column
after the FP_SEASONS ts (snowfall_system.gd:241): unedited columns (no _edits at (x,g,z) or
(x,g+1,z)) skip UNLESS (ts<SNOW_T0 AND is_snowing) — with the warm+baseline-snow escape
(snow_stack_at!=0 ⇒ full path so seasonal thaw melts). PROVEN no-op elision incl. the cold+dry
case (melt unreachable at ts<0, grow gated by is_snowing at :255; stale freeze bits + dynamic
snow always live in _edits via set_state→_write_cell wm:2043; worldgen is the M1 fixed point
wm:2049) ⇒ byte-equal world, ~4-5µs vs ~90-200µs/col. SNOW_T0=0.0 (terrain_config.gd:82) IS the
user's 0°C and the one freeze authority (precip kind uses same crossing, pve.gd:245).
Precipitation state = is_snowing (SEED+105 noise 0.47µs; FP_PRECIP ANDs the weather grid
cloud_water_at_dir, pve.gd:232-245). MELT DECISION (a): snow/edit-holding columns keep the
shipped path (self-extinguishing) — flagged for user confirmation; literal all-disable would
leave permanent snow. Also route :235 t-read via analytic_column_profile (same .w, memoized).
Gates G-PGATE-EQUIV/COLD-PRECIP/COLD-DRY/WARM/MELT via _gate_enabled instance var
(process_sliced direct-drive pattern). Design doc docs/COSMOS-FOREST-SNOW-PROC-DESIGN.md. ALSO learned:
smooth_v2_commit_ms 22.38 pinned = LATCHED last-commit duration (facet_smooth_v2.gd:634), not
per-frame; proc_ms = TIME_PROCESS = whole-frame on threaded web ([[voxiverse-web-time-process-
invalid]]); residual worst_ms p50 36 unattributed (render submit/vsync/alloc — next hunt).
Related [[voxiverse-unattended-perf-2026-07-21]] [[voxiverse-fast-load]].

**SHIPPED+MERGED PR #56 (main 72453ee, 2026-08-12), bundled with [[voxiverse-mesa-viewband]].** Melt=(a) user-confirmed. LIVE A/B warm forest facet 1754: snow_ms 18-44ms → 0.02-0.44ms (steady, fully baked). Gates verify_snow_precip_gate 30/0 off / 29/1 on (1=deliberate default-false ship-guard), byte-equal fingerprint both states, FLAT 6042/0, verify_climate 20/0. **KEY LESSON: snow was NOT the forest-fps limiter** — fixing snow_ms→0 left forest fps UNCHANGED at ~30 (proc_ms ~90ms is the invalid whole-frame metric). The real ceiling = a separate residual (gl_compat render-submit + far-trees tier + vsync ladder + phys spikes) → dispatched as the forest-fps deep-dive (task #119, [[voxiverse-web-perf-architecture]]).
