---
name: voxiverse-live-review-2026-07-20
description: 2026-07-20/21 live-review deploy chain (seams-v2 + streaming + ATMO2) + confirmed live regressions and the fix agents in flight
metadata: 
  node_type: memory
  type: project
---

Live-review session on `deploy/perf-plus-sky`. Deploy chain (each verified FLAT 6042/0 byte-off, flags baked ON at export via sed wrappers in scratchpad `deploy_seams.sh`/`deploy_atmo2.sh`):

- **Deploy 1** (rebuild — C++ patch 0010 datum-bake hook, `module_in_web=yes`): FS2′ `FP_DATUM_BAKE` (continuous unrounded datum, RETIRES integer `FP_RADIAL_DATUM`; seam step 5.30→0.043) + `FP_CROSS_CORNER_COMMIT` (invisible wall) + `FP_TWIST_FRAME_AWARE` (crossing heading) + `FP_LANDING_STREAM_KICK` (near-field streams after de-orbit land — resident slot had no pace-floor) + `SN_FOFF_RADIAL_FALL` (F-off straight-down landing).
- **Deploy 2** (shader-only, no rebuild): ATMO2 B0-B5 ON — `FP_SUN_PATHLIGHT` (optical-path sun color: white space→pale noon→red horizon, retires Kasten-Young), `FP_SUN_APPARENT` (SphereMesh-0.5 size fix), `FP_ATMO_PATH_SHELL` (bounded shell, was 6-80× hot), `FP_NEAR_DAYLIGHT` (near blocks+clouds night-shade — they were UNSHADED), `FP_MOON_PRESENCE` (earthshine + 5.1° incl), `FP_FOG_ARBITER`. Clouds/precip/storms HELD OFF (isolate sky review). HDR verdict: NONE on WebGL2/gl_compat (R10G10B10A2 tonemapped-sRGB) → authored LDR luminance budget instead. Full design docs/COSMOS-ATMO2-DESIGN.md.

**Tiling verdict** (docs/COSMOS-FACET-TILING-RESEARCH.md): KEEP square cube-sphere. Octagons reduce to cut-corner cube (same seams). Cube optimally saturates the 90° grid-singularity budget (8 corners → all seams zero-rotation, 1:1 columns — why the datum works). Hex/Goldberg SMEARS grid-rotation onto every seam (~42k-block grain boundaries) + 12 pentagon singularities; user's "clip squares into hexagons" hybrid: interior works, seams fail. User's reported artifacts are all crossing-layer, tiling-independent. Chamfered-cube deferred (only 8 corners benefit, already ocean-drowned).

**LIVE REGRESSIONS confirmed 2026-07-21 (telemetry+frames, tools/remote-bridge/results/) — fix agents in flight:**
- 3b (SERIOUS) render≠collision fall-through: player alt −18 on_ground embedded below rendered surface = `FP_DATUM_BAKE` lifts render/skin but collision floor not matching per-column. → agent fix/voxiverse-seams-live.
- 2 (SERIOUS) crossing heading wrong: `FP_TWIST_FRAME_AWARE` wrong branch/sign under live FIXED_FRAME+KEEP_HEADING. → same agent.
- 3a far-in-front-of-near depth: `sh_wfail` thrash-loop in FP_SHELL_WELD (facet_far_ring.gd ~719-755) mis-sorts far ring over near. → same agent.
- 1 night blue-halo (shell not →0 at night), 4 green day sky + ugly sun halo (scatter channel wrong), 5 moon color INVERTED (red-high/white-low; should be white-high/red-low like sun — μ or eclipse-factor sign), malformed dart impostor (B1 SphereMesh). → agent fix/voxiverse-atmo2-live (shader-only).

**ALL 6 regressions FIXED + deployed (Deploy 3 @ 21aaa10 + Deploy 4 @ ad1f874, WASM 15:33Z 2026-07-21, no rebuild):**
- 2 heading: FP_TWIST_FRAME_AWARE had inverted sign (+yaw_delta→−yaw_delta; 116°→0.045° error; 180° cube-fold seams were sign-degenerate so wrong sign shipped). Fixed heading+velocity together.
- 3b fall-through: NOT real — collision provably correct (floor==render 0.00000/217 cols); the "sunken" look was the VISUAL consequence of 3a.
- 3a far-over-near: ring-1 ridge-neighbour far facets only sink under FP_TIER_STICKY_BACKSTOP+FP_TIER_ENVELOPE (were off); G-TIER-ENVELOPE poke at facet 3058 = env fine-grid ε-guard didn't scale with R=6371 (fixed ENV_EPS_FRAC=0.2×cell). New FP_TIER_WARM_CONVERGE fixes sh_wfail weld thrash (progressive emit, filter uncached backstops vs draw stale unsunk). Baked ON (depth_bias left off).
- 1 night blue-halo + 2/4 green day sky + rainbow band: ONE root cause — A6 shell read sun-angle from infinite-line closest-approach (horizon for surface cams) → sunset tint everywhere + lit night zenith. Fixed to chord-MIDPOINT (shell_view_mu). Calm blue day, black night.
- 5 moon color inverted: moon got NO path-transmittance, only eclipse-redden + coplanar orbit → red-when-high. Added moon_path_albedo (same path law as sun: white overhead, red horizon); eclipse now rare via 5.1° incl.
- "dart" = unlit crescent moon on the blown sky, not a broken mesh.

GODOT SHADER GOTCHA (Deploy 5 @ b52d73c, WASM 19:46Z): the FP_NEAR_DAYLIGHT atlas-cube twin wrote `ALPHA = t.a;` — writing ALPHA in a Godot spatial shader FORCES the transparent pipeline (no depth-write, per-object depth sort), so the OPAQUE ground drew over near blocks and swapped on strafe (user's "ground behind tree stump rendered in front, strafe to observe"). Fix = drop the spurious ALPHA write (atlas is opaque-only). block_materials opaque twin was already correct (no ALPHA); only block_atlas.gd _NEAR_DAYLIGHT_SHADER had it. Lesson: opaque near-material shader twins must NOT write ALPHA.

CONCURRENT-WORKTREE HAZARD: isolation:"worktree" agents can scramble branch refs (fix branch names pointed at wrong commits; deploy branch ref didn't advance). ALWAYS verify by commit hash + grep the actual deploy tree for each fix before deploying, not by branch name.

FALL-FROM-ORBIT perf + slow-fall (Deploy 6 @ 34a5c29, WASM 20:28Z): fall was ~5fps / 220-540ms frames — NOT gen (gen/mesh=0, 32 draws); the ORBIT far-ring branch (facet_far_ring _shell_orbit) re-scanned the whole planet (6·K² dot-scan) EVERY airborne frame (surface path already idled, orbit path didn't). Fix FP_SHELL_ORBIT_IDLE (converged-idle short-circuit). The "fall accel 10× too slow" (~0.8 vs 9.8 b/s²) was NOT a gravity bug — the coast integrator clamps dt to MAX_NAV_DT=1/30s and DROPS the remainder + max_physics_steps_per_frame=2, so at 5fps game-time dilates to ~1/6 real. Fix FP_COAST_FULL_DT (substep full real dt, N≤30 substeps ≤1/30s each, cap COAST_CATCHUP_MAX=1.0s; gate G-COAST-FULLDT proves dt-invariance). Both baked ON.
STILL OPEN: ~1.3s freeze on WALK facet-crossing is SEPARATE — FP_FARRING_ASYNC_REBUILD is ALREADY baked on, so it's the near-field restream/PlanetRoot re-place ([[voxiverse-crossing-phys-spike]]), not the sync far-ring rebuild. snow_ms≤145ms (SnowfallSystem main-thread) minor separate contributor. Both need a follow-up crossing-cost pass.

User decision this session: "keep smooth build live, fix forward" (no interim rollback of the crossing flags). Next: (1) walk-crossing 1.3s spike + snow_ms pass; (2) clouds re-enable (clouds2 vol+slow, already in tree, FP_CLOUDS off). See [[voxiverse-overnight-2026-07-19]], [[voxiverse-facet-seams]], [[voxiverse-atmo2-design]], [[voxiverse-remote-telemetry-launch]].
