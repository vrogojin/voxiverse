---
name: voxiverse-deorbit-shell-reemit
description: 2026-08-23 de-orbit stall ROOT (matched live A/B) = far-ring SHELL RE-EMIT burst at the anchor-release knee (~alt 590, sh_emit 1386, ~1M prims, ~1200-2400ms), NOT the near-field gen flood; C-lite (FP_REENTRY_*) gave NO improvement (worse) — shelved default-off
metadata:
  node_type: memory
  type: project
---

2026-08-23. Matched live consent-gated de-orbit A/B (dlmalloc, same freeze-release protocol: warm → set_alt 2500
+ freeze → release → fall → walk), BASE (FP_REENTRY_* off) vs CLITE (on). VERDICT: **the dominant de-orbit stall
is the far-ring SHELL RE-EMIT at the anchor-release knee, NOT the near-field GenerateBlock flood.** C-lite is a
correct fix for the wrong bottleneck.

MEASURED (worst_ms = window-worst frame, rate-robust; 1Hz relay, telem=10hz never engaged on the relay this
session either):
| metric | BASE | CLITE |
| worst_ms @ ~590 | 1158ms | 2368ms |
| peak vox_gen | 408 | 705 |
| sh_emit at stall | 1386 | 1386 |
Cost attribution of the worst frame (both arms): vox_gen=0, sh_emit=1386, prims≈1.08M, objects=132 (STABLE, not
a structure-count spike), all main-thread buckets small (phys ~40ms, t_stream ~12ms, smooth ~10ms, tex ~5ms) —
frame_ms ≫ Σbuckets = the WASM convoy, but driven by the SHELL re-emit alloc storm, not voxel gen. Stalls cluster
tightly at alt 560-596 = the S1 approach-anchor RELEASE knee (ANCHOR_REL_LO/HYST ≈ 609) where the far-ring shell
opens from orbit-collapsed to full-hemisphere in ONE burst (sh_emit 1386 > the 790 orbit-cap).

C-lite DID work mechanically (rg_desc latch armed the WHOLE descent alt 2495→13 — freeze-independent arming is
real, unlike dead attempts #1/#2; rg_last_vd grew step-clamped 0→36→72→128; no walk-wedge, final rgvd=128). But it
gave NO net improvement and likely WORSENED this fast fall: FP_REENTRY_REGROW_DEFER holds near view at 64 during
the fast plunge then releases it all at alt 460, CONCENTRATING the near-field emit right where the shell also
re-emits → two stacked bursts (vox_gen 705 vs BASE 408). Deferral helps a SLOW descent (spreads load) but piles up
a FAST one. ⇒ **C-lite shelved default-off** (committed feat/voxiverse-fall-clite, byte-clean, Opus-reviewed, gate
verify_reentry_pace ON 25/0 — a documented negative result + a correct tool for the slow-flood case; do NOT ship ON).

STAGING FIX (FP_SHELL_STAGE_REEMIT) — BUILT + MEASURED-REJECTED 2026-08-23/29. Fable-designed sector-staging
(budget ≤112 facets/dispatch, docs/COSMOS-DEORBIT-SHELL-STAGING-DESIGN.md), Opus-implemented (commit 5c67a20 on
feat/voxiverse-fall-clite), all gates green (FLAT 6042/0; verify_shell_staging 29/0 incl. stale-wedge regression;
probe_calm; shell), Opus-reviewed (no P0, byte-clean). LIVE natural de-orbit A/B: **DID NOT FIX the knee** — knee
worst_ms 2662 @ alt 596 (vs BASE 2440), `sh_stage_on=0` AT THE KNEE (staging never fired there), sh_emit=sh_visN=927
(full avalanche in one frame), sh_applied_r=0. ROOT of the miss = the Opus review's Finding F1, confirmed live: the
design assumed the knee is a class-1 REPLACEMENT burst of resident sectors, but sh_applied_r=0 proves **the shell is
COLLAPSED at orbit and OPENS at the release knee = a class-0 GROWTH burst** (sectors never-built / gaining members).
Class-0 is EXEMPT from the budget (deferring it would open a hole), so staging engaged elsewhere on descent (son=1 at
alt~249) but skipped the knee entirely. The design's premise "the cap SHRINKS at the knee (θ_h falls)" was WRONG —
at the RELEASE knee the shell OPENS. Also transient holes seen during growth phases (sh_emit<sh_visN on climb). Live
reverted to BASE; FP_SHELL_STAGE_REEMIT stays default-off (committed record, doesn't fix the target).

CORRECTED REAL FIX DIRECTION (not yet attempted): the knee stall is the shell rebuilding from a COLLAPSED orbit state
(applied_r 0→full) in ONE frame. Attack WHEN it builds, not how much per frame: (A) don't fully collapse the shell at
orbit (keep applied_r>0 so the release is a light class-1 replacement, trading some orbit cost) — OR (B) PRE-BUILD/warm
the shell sectors DURING the descent, ahead of the release knee, so they're resident (class-1) by the release and the
existing sector machinery absorbs it — OR (C) budget class-0 growth too, accepting a transient partial shell for ~0.4s
IF the backstop/orbit-relief/chord under-layers actually cover (the climb holes suggest they may NOT — verify first).
(B) or (A) look most promising; (C) fights the hole tradeoff that exempted class-0 in the first place. This is the
[[voxiverse-orbit-perf-farring-churn]] family. sh_applied_r + sh_stage_on + sh_emit/sh_visN are the key telemetry.
DIRECTION-B PRE-WARM (FP_SHELL_PREWARM_DESCENT) — BUILT + MEASURED-WIN 2026-08-29 (the 4th attempt, FIRST
positive). Fable-designed (docs/COSMOS-DEORBIT-SHELL-PREWARM-DESIGN.md), Opus-impl (commit 00924db on
feat/voxiverse-fall-clite), all gates green (FLAT 6042/0; verify_shell_prewarm 36/0 with load-bearing proof —
neutering E8 regresses 31/5, the 1472-facet avalanche returns; staging 29/0; probe_calm; shell), independent
FLAT 6042/0, Opus-reviewed (no P0/P1; HIGH = gate doesn't drive the integrated E6/E7 runtime path, covered by
the live A/B telemetry). MECHANISM: engage on `_cam_set ∧ _shell_orbit() ∧ reentry_descent_step Schmitt latch
(REUSES C-lite's pure static — nothing wasted) ∧ alt∈[650,1300]`; paced `_shell_snapshot` refreshes (SRC_PREWARM)
keep the wanted set current DURING descent + the shipped FP_SHELL_STAGE_REEMIT builds it with class-0 growth
budget-ELIGIBLE during voluntary pre-warm dispatches (E8, guarded vs _mi-resident hole). So the shell stays
resident down the descent instead of collapsing→reopening at the knee. LIVE A/B (natural de-orbit, deployed
BASE+STAGE+PREWARM = 212 flags): **WIN** — sh_pwd_snaps fired, max sh_reemit 139/183 (vs BASE 927 one-frame
avalanche), shell resident (sh_emit=sh_visN) crossing the knee, knee band worst_ms **215-644ms** (vs BASE
sustained **2440-2662ms**). The 927-facet avalanche = ELIMINATED. Residual: ~400-644ms transient knee hitches
(the bounded sunk-transition emit sh_stage_emit≈130 + concurrent-worker convoy — small, not the avalanche); a
2130ms first-fall spike was NON-REPRODUCIBLE (fall-2 same band = 644ms max), a one-off bake/GC. Test caveat: the
natural fall climbs-then-releases (partly pre-builds on climb); a freeze-release repro would be cleaner but the
STAGE-only run on the SAME profile still hit 2662ms, so pre-warm caused the drop. STATUS: shippable win, default-off,
committed; PR-ready. FOUR attempts total: 3 rejected (mimalloc/C-lite/staging) + pre-warm WIN.

SLICE-SMOOTHING (FP_SHELL_SECTOR_FINE 24→96 sectors + FP_FARRING_EMIT_ACCUM alloc-diet + FP_SV2_SHELL_YIELD,
commit 376ec5b) — 5th cycle, WIN: shell per-slice hitches 284-1041ms → median 153ms/p90 295ms (sh_stage_emit
≤39). Gates green (FLAT 6042/0, farring-emit fine+accum 36/0, staging/prewarm regression), Opus-reviewed no-P0.
User VISUAL confirm: NO seams/height-steps/stale-ground — visually clean, PR-ready. Seam invariant = sector-
INDEPENDENCE of emit (far-ring facets abut but don't weld bitwise; finer grid = same facet-emits across more
MeshInstances, no new seam).

STRUCTURE (village) tier — 6th cycle, corrected attribution: the residual de-orbit spike (3555ms @ alt ~598) is
NOT near-render promotion — it's the FacetFarStructures **zone-B WAKE bake at FT_SHELL_HIDE_ALT=600** (first live
tier step after orbit synchronously bakes ~300-900 GEN houses × 2-6ms). `objects` telemetry = scene-node count
(the 133→152 jump was near-facet re-grow, NOT houses — 1 node each). ALSO the user-reported "houses disappear
during descent" = a CONFIRMED live HOLE: facet_far_structures.gd _cull_emit's probe-free band floor (dist<r0 ⇒
return false) drops the far model while the near build lags. FIX (commit 67eedeb): FP_STRUCT_NEAR_HOLD (far model
HOLDS-until-COVERED probe — closes the hole; every hide routes through a real is_area_meshed COVERED so the near
mesh provably exists) + FP_STRUCT_BAKE_STAGE (drain the wake bake nearest-first ≥2 houses/≤8ms per pass, ~4-8s;
_has_bake skip ⇒ staging only DELAYS ADDITION, never removes a shown house). Gates green (FLAT 6042/0, structures
OFF 80/0 ON 94/0 with G-ST-HOLD+G-ST-STAGE real-path load-bearing, shell gates no cross-regression), independent
FLAT 6042/0, Opus-reviewed no-P0/P1 (HIDE direction airtight; residual unbaked-inside-r0 gap is bounded + already
a hole in shipped code + not hit on natural descent). A/B PENDING user reload (village fall; watch knee worst_ms
drop from 3555 + NO house blanking). SIX cycles: 3 rejected + pre-warm/slice/structure WINs. Whole de-orbit
(shell+structures) fix lives on feat/voxiverse-fall-clite (7 flags, all default-off); PR-ready pending the
structure A/B. Deploy set for the win = the 7 CLITE_FLAGS in deploy_cheats.sh.
[[voxiverse-fall-mesh-stall]] [[voxiverse-mimalloc-fit-build]] [[voxiverse-walk-perf-root-cause]]
