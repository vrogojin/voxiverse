---
name: voxiverse-prebake-pacing-p7
description: 2026-08-22 P7 prebake pacing/scoping SHIPPED — coast-cap + view-scope end the orbit fine-map grind convoy (worst frame 147→43ms)
metadata: 
  node_type: memory
  type: project
---

2026-08-22 (branch perf/prebake-pacing off main c489de6, after the P0-P4 batch PR #78 + P6 mimalloc REJECTED).
The residual ~4-5 hitches/s at orbit were root-caused (clean-browser telemetry) to the MEMORY-BANDWIDTH CONVOY of
the whole-planet fine-map prebake: worst frames cluster where fm_baked is LOW (grind in progress), bg_inflight ~1.9,
proc_ms broadly elevated (91 vs 25 median), t_stream/t_nav/t_sky all ~2-3x — NOT a single commit spike, NOT the
allocator. While bakers grind 4096-column tiles, ALL main-thread work slows. [[voxiverse-walk-perf-root-cause]]

TWO byte-off flags (facet_tex_baker.gd, commit 9e4b66e + tune):
- **FP_PREBAKE_VIEW_SCOPE** (PREBAKE_SCOPE_DOT): `_next_fine_fid` had NO cutoff — it ground all ~3456 facets incl.
  the ~half on the OCCLUDED far side of the planet (never visible → pure convoy). Off-surface, skip facets with
  centre-dir·view-axis < PREBAKE_SCOPE_DOT and return -1 once the in-cone set is baked (no fall-through to the
  whole-planet cursor sweep) ⇒ grind ENDS at cone coverage, steady-state bakers → 0. `fine_pending` made
  scope-aware via a single reused `_next_fine_fid` probe (`_fine_next`) so the band reclaims slots (else it
  starves — the size sentinel would stay true forever). TUNED **0.0 → 0.5**: the visible horizon cap at alt 2500
  is only ~44° (cos θ = R/(R+h)); a 0.5 dot = ~60° cone covers it with margin while cutting the scoped set
  ~1728 (near hemisphere) → ~800. LIVE-VERIFIED no base-blur at the cone edge (nadir + edge-on limb screenshots
  crisp to the horizon against space).
- **FP_PREBAKE_COAST_CAP**: the PROACTIVE twin of P4 (FP_BG_OFFSURF_CALM). P4 caps only REACTIVELY after an
  over-budget frame → a healthy frame refills the pool to _pbm_n and the NEXT frame hitches (a 1↔4 sawtooth).
  This caps off-surface fine-mode in-flight to BG_MAX_INFLIGHT_OFFSURF_BUSY (=1) UNCONDITIONALLY ⇒ steady single
  baker. LIVE-VERIFIED: bg_inflight rock-steady 1.0 (was sawtoothing 1↔4).

RESULT (live A/B vs P0-P4 dlmalloc baseline, matched village→alt2500 scene): worst frame **147 → 43 ms** (in-game
HUD, no relay overhead; a 3× cut — the "jerkiness" is the frame MAGNITUDE, and it's crushed), hitch rate roughly
halved DURING the grind, fps ~44, and the grind ENDS ~4× sooner (3456→~800 facets) so steady-state goes smooth.
heap normal (~495, dlmalloc). Trades fill SPEED for smoothness = the user's stated preference.

GATES: FLAT verify_feature 6042/0 (both flags default FALSE ⇒ byte-identical). verify_bg_prebake extended with
G-PBS-SCOPE / G-PBS-BACKSIDE / G-PBS-COAST (ON arm 8/0, OFF arm 10/0; parametric on PREBAKE_SCOPE_DOT). NOTE:
G-BGP-OSCALM's "full pool" arms had to be guarded with `not FP_PREBAKE_COAST_CAP` (both flags cap off-surface —
non-orthogonal gate configs). GDScript-only, NO engine rebuild (deploy = export+deploy on the dlmalloc templates).

GOTCHA: telemetry.jsonl ACCUMULATES across browser sessions — whole-tail fm_baked/bg_inflight/hitches stats are
polluted by prior runs (saw a phantom fm_baked=1728 leftover from the dot=0.0 run). Filter to the current session
(contiguous tail after the last fm_baked<5 reset) for clean reads. Relay telem_ms (~13-23ms/emit) also inflates
frame_ms vs real play — the in-game PERF HUD "worst" is the truer number.

FLY-AROUND / FAR-SIDE (user asked "will it look ok flying around?"): live-verified GOOD. Baked fine tiles PERSIST
(only chop-invalidation erases; `_fine_baked.erase` at facet_tex_baker.gd:1829 is the ONLY eviction) + the
whole-planet BASE tier always covers (shader fine→band→base fallback) ⇒ a fresh region shows coarse-but-COLOURED
base briefly, never black/broken, then sharpens + persists. The baker (~1-2/s) LEADS orbital motion (sub-point
crosses ~1 facet/2s; cone extends ~11 facets ahead) so exploring stays crisp. Antipode teleport screenshot
(daylight, alt 2530): fully crisp per-block to the atmosphere-rim limb after ~1-2 min dwell; only INSTANT teleport
to a never-visited spot shows the brief coarse-base. RELAY GOTCHA: `look` pitch/yaw is NOT planet-radial after a
far teleport — at a new location nadir needs steeper pitch (-60..-80), and teleport-direct-to-alt carries the old
orientation (aim at space); use teleport-to-alt-3-then-set_alt so the frame re-orients. Also set_time is
per-player-LOCAL, so the antipode of a local-noon spot is MIDNIGHT (dark, not a render bug).

STATUS: MERGED to main 2026-08-22 — PR #79 (squash 1c76461). Branch perf/prebake-pacing (2 commits: 9e4b66e +
80439a1). Live at 12:55 GMT + verified. patches unchanged (GDScript-only). deploy_cheats CS_FLAGS has both flags.
[[voxiverse-bg-prebake-design]] [[voxiverse-orbit-perf-farring-churn]] [[voxiverse-mimalloc-reab-rejected]]
