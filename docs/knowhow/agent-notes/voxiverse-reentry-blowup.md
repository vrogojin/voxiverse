---
name: voxiverse-reentry-blowup
description: "2026-07-19 de-orbit teleport root cause (fid/pose desync + FD-velocity latch) + headless live-scene gate pitfalls (import cache, in-tree/global_position no-op)"
metadata: 
  node_type: memory
  type: project
---

2026-07-19 game-breaking re-entry blowup, root-caused + fixed on feat/voxiverse-reentry (verify_reentry.gd, 20/0):

- ROOT CAUSE class: `maybe_cross_facet` is TWO-PHASE — `TerrainConfig.set_active_facet(to)` commits at world_manager.gd:~1823, the PLAYER reframe is applied by the caller only after return, with a fallible pipeline (redesignate/pool/far-ring/restream) between. Any abort ⇒ fid/pose desync ⇒ the stale lattice pose read in the new facet's decorrelated frame (`_off` ±32768) = a one-frame teleport of |Δframe| blocks (11081 live, 25.7k for the spawn 2→26 pair). The SN2 finite-difference then reads Δp/dt (642074 b/s live) and `fall_seed(_nav_last_v_bci)` ADOPTS it after the walk-path handoff clears `_fall_have_v` — the escape latch. Fixed: `_pos_fid` + `_heal_frame_desync()` invariant, `CosmosNav.sane_v/FD_SPEED_MAX/clamp_bci_state` guards.
- The nav "stuck low_orbit" at alt 11473 was CORRECT classification (r ≤ 4R vicinity ⇒ LOW_ORBIT by design); at 160-224k it was DWELL STARVATION: NavState dwell accumulated CLAMPED dt (1/30 per frame) so 14–27 s wall frames never reached the 2 s dwell — FIXED (commit 10dcaf8): dwell now gets real frame dt capped at NAV_DWELL_DT_MAX=1.0. Classifier bands are ratio-based ⇒ scale-free, provably correct post-rescale.
- Slowness data: the player-side physics tick is FLAT with altitude (0.31–0.43 ms native, 2k→160k blocks) — the live 27 s frames were the garbage-velocity state (21k-block viewer teleports/frame ⇒ full restream+far-ring churn every frame), not altitude per se.

Headless live-scene gate pitfalls (cost hours):
- A fresh worktree lacks `godot/.godot/imported` — run `godot --headless --path godot --import` FIRST or verify_feature fails exactly 15 texture asserts (6027/15 instead of 6042/0) and every run spams ctex load errors.
- A Node NOT inside the tree/world makes `global_position = x` writes SILENT NO-OPS and `get_world_3d()` null — a synchronous `_initialize()` harness must `get_root().add_child()` + `await process_frame` once before driving player physics, else you fabricate teleports that are pure harness artifacts.
- Player harness pattern: `pl.frozen = true` lets the gate drive the exact `_physics_process` sub-sequence manually (per-sub-call |Δworld| attribution) while the engine's own callback no-ops. Faceted gates run "sed-toggled" (flip `const FACETED := true` etc. in cube_sphere.gd, run, `git checkout` restore) — deploy bakes flags at export OUTSIDE git; the deploy branch source has all flags false.

2026-07-20 LANDING follow-up (feat/voxiverse-landing, verify_landing 14/0):
- The telemetry "facet 2810→2 jump at landing" was a PAGE RELOAD (post-jump record byte-identical to the session-start spawn record: pos [4125.55,−3876.29,−2939.07], alt 7.4, facet 2, nav None) — NOT a crossing desync. Check for session restarts before chasing facet jumps in telemetry.jsonl.
- The REAL landing bug: near-field streaming WEDGE — player stood 13 min on the CORRECT facet 2810's analytic floor (on_ground true) with vt_* counters fully idle (zero load requests), prims pinned 22k (far ring only) vs 100-270k healthy; handed to the streaming owner. Suspects: `_ramp_pool_step` pace hold (only `_imminent_fid` is floored — no imminent exists after landing), slot bounds/state after 400+ rapid orbital redesignations. Shell weld churn in same window (sh_wfail 77k, sh_reemit 851).
- A LANDED player's |v_bci| == |ω×p| spin carrier (13-14.5 b/s, latitude-dependent) — never 0; HUD must show frame_v (surface frame). Fixed in nav_speed_bci().
- Harness lesson: an `await process_frame` after add_child lets the ENGINE tick the player once at the DEFAULT (0,0,0) position — whose lattice maps to alt ~34k on offset facets → pre-seeds free-fall state. Reset `_fall_have_v=false` when staging descent scenarios.

See [[voxiverse-sn1-orbital-substrate]], [[voxiverse-spacenav-design]].
