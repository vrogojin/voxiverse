---
name: voxiverse-orbit-decay
description: "2026-07-18 O-orbit decay root cause = coast stored in ROTATING lattice frame → 1-tick spin desync pumps eccentricity; fix = carry [p,v] in f64 BCI + prograde station-keeping"
metadata: 
  node_type: memory
  type: project
---

ORBIT_COAST "descends to the antipode and stops" root cause (feat/voxiverse-odecay, merged to deploy/perf-plus-sky 17b5e70, live 2026-07-18 16:35):

**Root cause (MEASURED, not the f32 hypothesis):** `_coast_step` stored the orbit position in the BODY-FIXED (rotating) lattice `position` and re-read it each tick, so position was rotated by one tick of planet spin (ω·dt≈8.7e-5 rad) relative to the un-rotated f64 velocity. The (p,v) desync PUMPS eccentricity — apoapsis rises, PERIAPSIS drops every orbit — and the low point is on the FAR side of the release point → player sinks to the antipode until the atmosphere/surface handoff arrests it. f32 was only a minor secondary; the classifier (H3) was falsified (never misclassifies mid-orbit).

**Fix:** carry `_coast_p_bci` in f64 mirroring `_coast_v_bci`; integrate the pure BCI [p,v] pair in `_coast_step_kepler`; write lattice `position` as DISPLAY-ONLY, never read back. Measured: periapsis drop 24.3 blocks/60 orbits (shipped, ~2579 orbits-to-atmosphere) → 0.00000 (fix, ~infinite). Pure correctness inside ORBIT_COAST ⇒ no new flag, byte-identical off.

**Prograde station-keeping (dev assist, ORBIT_COAST only):** when specific energy falls below circular-energy at the SAFE radius (R_vox+ATMO_TOP+384) AND sub-circular (apoapsis arc), a periodic small prograde Δv (4 b/s every 0.35s along v̂) tops energy to the safe target and STOPS (self-limiting, a bounded at safe ⇒ no escape). CRITICAL design point: target the safe-altitude ENERGY, NOT local v_circ — capping at local v_circ merely re-circularises at the sinking radius and still crashes. Gate: drag-decaying r0=3756 enters atmosphere in ~21 orbits without boost; with boost holds 1200 orbits (apoapsis bounded 3922).

**HONEST GAP:** the faithful headless composite does NOT reproduce the LIVE "half-orbit and stop" — only the slow ~2579-orbit pump. Live has an extra amplifier (web dt-jitter with the 1-frame integration-vs-spin-clock offset, or a live-only sub-circular seed) the constant-dt harness can't capture. Station-keeping is the robust net regardless of the true live rate. Live re-fly pending user (test prograde AND retrograde — pump sign flipped with direction pre-fix).

**Verify harness trap caught:** GDScript lambdas capture locals BY VALUE — a closure-based per-tick driver silently re-ran from the seed every tick (false "0.0000% hold" for all configs). Use plain inline loops. Also: ALWAYS `git checkout -- cube_sphere.gd` before a FLAT byte-identity run — leaving FACETED sed'd true from other gates gives a spurious 6020/15 (clean base is 6035/0). Gates: verify_odecay 42/0, verify_ocoast 24/0, FLAT 6035/0. See [[voxiverse-orbital-shell]] (deployed together), [[voxiverse-spacenav-design]].
