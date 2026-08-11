# COSMOS SUMMIT-STREAM-PRIORITY — root cause + fix design (task #109)

Investigator: Fable architect (session 2026-08-11). Source of truth: the LIVE-served build =
worktree `deploy-cheats`, branch `deploy/cheats-eyeball` @ 74d3a66 with the deploy_cheats.sh
flag bake (see §2). Repro: standing on a mountain summit (fid 748, BCI ≈ [−5429, 1694, −2957],
radial alt 66), the near-field voxel blocks arrive tens of seconds late while the smooth relief
tile covers the summit; telemetry shows the queue IDLE (vox gen/mesh/main/gpu all 0) with
`stream_credit = 0`, `setpoint_ms ≈ 31`, `vt_dropped_loads = 1257`, `smooth_v2_res = 41`.

## 1. Verdict up front

1. **#107 is NOT the cause — pre-existing.** Smooth residency (`FacetFarRing.is_smooth_resident`,
   facet_far_ring.gd:1047) is consulted ONLY by the blocky-LOD tiers: `facet_lod_mesher.gd:49-127`,
   `facet_block_lod_ring.gd:83-94`, `facet_block_lod_ladder.gd:37-46` (wired at
   world_manager.gd:412-459). **No near-field (VoxelTerrain) load, priority, ramp, or coverage path
   reads smooth residency** — grep-proof: the only `set_smooth_query` consumer inside module_world
   forwards to `_lod_mesher` (module_world.gd:2066-2069). What #107 changed is the *clothing* of the
   stall: pre-#107 the un-streamed summit showed giant coarse blocky-LOD tiles (bug #107 itself);
   post-#107 it shows the smooth relief tile. The stall itself predates #107.
2. **Root mechanism = a chain of three throttles, all in the near-field admission path**, detailed
   in §3: (A) the chronic credit-0 controller state on a ~40 fps client, (B) the pace floors that
   were built to protect the active facet from (A) being **disabled whenever an imminent neighbour
   is selected** (≈⅔ of every facet's area), and (C) the **approach-anchor law pinning the streaming
   viewer to the DATUM, not to the sub-player ground** — at a 66-block summit the VoxelViewer is
   dragged 62 blocks below the player's feet, so godot_voxel's distance-based load priority serves
   the invisible mountain interior first and the visible summit surface last.

## 2. The live flag set (why the repo consts lie)

`godot/src/cosmos/cube_sphere.gd` in-tree has every FP_ const `false`. The served build is baked by
`scratchpad/deploy_cheats.sh` (sed-flip at export, git-checkout revert after). Relevant flags ON
live: `FP_M2_LOD`, `FP_CTRL_ADAPTIVE`, `FP_INFLIGHT_GATE`, `FP_PREFILL_112`,
`FP_LANDING_STREAM_KICK`, `FP_LOAD_RAMP`, `FP_SHRINK_PACED`, `FP_LAND_RAMP_HOLD`,
`FP_APPROACH_ANCHOR`, `FP_VIEWER_RELIEF_REACH`, `FP_NB_FULLRES`, `FP_NB_WELD`, `FP_LOAD_DEFER`,
`FP_SMOOTH_V2_*`, and the #107 trio `FP_M2_SMOOTH_DEFER` / `FP_M2_EDGE_DIST` /
`FP_SMOOTH_V2_NEARFILL`. Telemetry cross-checks: `setpoint_ms = 31 ≠ 18` ⇒ adaptive on;
`smooth_v2_res = 41` ⇒ near-fill on.

## 3. The throttle chain (file:line)

### 3.A The controller is chronically at credit 0 on this client

`StreamLoadController` (stream_load_controller.gd): overload ⇔ EMA(window p90 of measured frame
delta) > setpoint (l.141). Adaptive setpoint = clamp(floor_p10 × 2.0, 18, 45)
(l.136-139; CTRL_ADAPTIVE_MARGIN=2.0 cube_sphere.gd:2022). Live: setpoint 31 ⇒ floor_p10 ≈ 15.5 ms,
while the client's p90 sits ≈ 32 ms (PERF HUD: FPS 41.5, worst 32.2, hitches 3512). A client whose
frame-time *variance* exceeds 2× its own best-decile is **permanently "overloaded"**: AIMD halves
credit to 0 (l.142-145) and additive +0.1/tick can never survive the next 0.25 s tick. Consequence:
`stream_pace() = 0` (surface 3, l.211-212) is pushed to the module every frame
(world_manager.gd:822-827 → module_world.set_stream_pace, module_world.gd:2053).
This is the *same* feedback trap noted in the fast-load design (setpoint is a target, not a cost);
the a80a46e "un-pin" (adaptive setpoint) only helps clients whose p90/p10 ratio < 2.

### 3.B The active-facet pace floors are dead in the near-ridge band

The near view radius is grown per-slot by `_ramp_pool_step` (module_world.gd:510-599); the grow leg
is multiplied by `_stream_pace` (l.577,596) — pace 0 **holds** the grow. Two repair floors exist:

* imminent floor (l.578-582) — only for the slot that IS the imminent neighbour;
* `FP_LANDING_STREAM_KICK` floor for the resident active slot (l.589-595) **guarded by**
  `(_imminent_fid < 0 or _imminent_fid == _pool_active)`, and the same guard on the collapsed-
  view_target repair (l.522-528).

But under the live pool policy an imminent neighbour is selected whenever the player is within
`POOL_D_WARM = 96` blocks of any ridge (world_manager.gd:2995-3006 publishes `targets[0]`;
z1_live_targets world_manager.gd:3185-3226). Facet edge ≈ 417-450 blocks ⇒ the warm band covers
≈ ⅔ of the facet's area — **the guard turns the landing-kick floor off for most of every walk**,
including the entire climb up a mountain flank near a ridge. While it is off and credit = 0:
the active slot still *wins* the single grow channel (l.553-560, "active wins") and advances at
pace 0 — freezing not just itself but every other ramping slot (the channel is burned each frame).
Measured for the repro summit itself (headless probe, `probe_summit_dist.gd`): fid 748, min ridge
distance 141 > 96 ⇒ at the summit point `_imminent_fid = −1` and the floor re-arms — the freeze
binds on the approach, not at the peak — but the peak then still waits ≥ RAMP_SECONDS/0.25 ≈ 6 s
per ramp leg *plus* everything §3.C below.

### 3.C The approach anchor pins the streamed viewer to the DATUM, not the ground under the player

This is the summit-specific inversion the user described. `_update_approach_anchor` runs **every
streaming tick, grounded or not** (world_manager.gd:1186 → 674-702; FP_APPROACH_ANCHOR on live).
Its altitude input is the **radial altitude above the datum sphere** (`_radial_altitude_lattice`,
world_manager.gd:630-637 — |world| − R), NOT height above local terrain. The offset law
(cube_sphere.gd:2231-2232):

```
offset_y = max(min(o_base − h, o_base), −h + 4)
```

pins the viewer's world radial altitude to `o_base`. Live `o_base = 0` (FP_VIEWER_RELIEF_REACH ⇒
`clamped_viewer_offset_y() = 0`, terrain_config.gd:226-227). Standing on the 66-block summit:
h = 66 ⇒ **offset_y = −62** — the VoxelViewer node sits 62 blocks *below the player's feet*, at
datum+4, inside the mountain. Verified consequences:

* **Load priority inversion.** godot_voxel prioritises strictly by 3D distance from the block to
  the closest viewer position: `PriorityDependency::evaluate`, priority_dependency.cpp:7-57
  (band0 = BAND_MAX − distance≫4), viewer positions synced from the VoxelViewer node
  (voxel_engine.cpp:340-344). With the viewer at datum+4, the *nearest* blocks are the invisible
  mountain interior; the visible summit surface is ~62+ blocks away and drains **last**. On flat
  ground the viewer sits at ground level, so the visible surface is nearest and drains **first** —
  exactly the asymmetry the user reported ("the top of the mountain should be prioritized in the
  same way as any other surface we are standing over").
* **Wanted-set edge effects.** The streamed ellipsoid (±128 vertical under FP_VIEWER_RELIEF_REACH,
  terrain_config.gd:242-243, VIEWER_RELIEF_REACH_BLOCKS=128 cube_sphere.gd:1531) is dragged down
  62: at the summit-surface altitude its horizontal reach shrinks 128 → ≈112, and the summit cap
  sits in the ellipsoid's top margin where mesh blocks additionally wait on top-neighbour data —
  the arrive-last band right in front of the camera. The facet bounds slab
  (module_world.gd:1893-1902, y ∈ [BEDROCK_FLOOR, MAX_SURFACE_Y(116)+canopy]) clips both variants
  to the same solid volume, so the anchor's harm is *ordering + margin*, not total volume.
* **Drop churn.** `vt_dropped_loads` counts arrivals no longer wanted / cancelled-but-expected
  (re-request!) — voxel_terrain.cpp:1635, 1647, 1672; the drop-and-requeue path (1619-1638) adds a
  full queue round-trip per drop. The anchored viewer + the 100 ms-debounced anchor rewrites
  (world_manager.gd:680-683) plus paced shrinks/retires keep this counter climbing (1257 lifetime),
  each drop wasting scarce web supply (~23-35 blocks/s measured).

### 3.D Why a summit specifically (Q4 quantification)

A summit column stack is bedrock→66 ≈ 130 solid blocks vs ≈ 70 on flat lowland; the near box over a
peak is ~75 % solid (every solid data block needs real generation + neighbour-complete meshing)
vs ~50 % cheap all-air early-outs over flat ground (TerrainConfig height-cap skip). The wanted set
is therefore roughly 1.5-2× more *expensive* per horizontal disc, at the same 23-35 blocks/s
supply — and §3.C orders the only part the player can see to the very end of that longer drain.
The queue-idle snapshot (gen/mesh/main/gpu = 0 with the dome still smooth) is consistent with the
ramped `max_view_distance` still being small at that moment (§3.B freeze on the approach + 6 s
floored legs), so the dome was not yet *wanted* — and with drop-requeue gaps; the live capture in
§6 discriminates the two directly.

## 4. Fix design — FP_SUMMIT_STREAM (byte-off), three independent sub-fixes

All three are cheap priority/order corrections, not supply increases; none touches NEVER-OOM caps,
the settle gate (FP_LOAD_DEFER), or queue budgets. Ship as one flag or as S1+S2 first (S3 optional).

### S1 — anchor to the sub-player GROUND (the core summit fix; pure reorder)

`world_manager.gd _apply_approach_anchor` (l.688-702): replace the offset/release input `h`
(radial-above-datum) with height-above-ground `h_eff = max(h − ground_h, 0)` where `ground_h` is
the analytic surface height above datum at the player's column — read through the existing memoized
analytic column (`FP_ANALYTIC_COL_MEMO` path; the same TerrainConfig surface the physics already
queries every tick, so zero new cost). Grounded on ANY terrain ⇒ h_eff ≈ 0 ⇒ offset_y ≈ o_base ⇒
the streamed ellipsoid re-centres on the player and godot_voxel's own distance priority makes the
surface under/around the player nearest-first — identical behaviour on a summit and on a plain.
Airborne, h_eff is the true camera-to-ground distance, which is what the S1 release law always
meant ("camera-to-plate distance ≈ h" holds by construction now). Gate the substitution on
`FP_SUMMIT_STREAM`; off ⇒ byte-identical inputs.
Perf: strictly *reduces* churn (fewer marginal-band drops); no new wanted volume (bounds slab
unchanged). Risk: during a fly-up the plate now releases relative to ground — the ANCHOR_REL knees
(700/900) are far above any terrain relief, so behaviour there is unchanged to first order.

### S2 — un-dead the active-slot pace floor (the approach-freeze fix; 3-line guard change)

`module_world.gd:593-595` (and the target-repair guard l.522-523): drop the
`_imminent_fid < 0 or _imminent_fid == _pool_active` condition under the flag — floor the RESIDENT
ACTIVE slot's grow pace at `CTRL_RELIEF_FLOOR` (0.25) **always** (`up_fid == _pool_active` is the
only guard left). Rationale: the guard was meant to avoid interfering with the imminent slot's own
floor, but `maxf` composes; as written it turns the landing-kick off across the entire 96-block
warm band of every ridge — the player's own footprint facet must never be pace-zero while they
stand on it. Bounded: the single-grow-channel serialization (l.475-480) is untouched; worst case
the active fills 48→128 in RAMP_SECONDS/0.25 = 6 s — exactly the bound FP_LANDING_STREAM_KICK
already ships for the landed case. No convoy: this is the same floor value, just reachable.

### S3 (optional) — footprint-first boost

While grounded and `near_column_meshed(player_pos)` (world_manager.gd:754, existing probe) is
false, hold the active slot's pace floor at 1.0 instead of 0.25 (one `maxf` input in
`_ramp_pool_step`). Self-clearing the moment the standing column meshes; bounded by the same
single-channel pacing. Take only if S1+S2 leave a visible gap in the live A/B.

## 5. Gate plan — `verify_summit_stream.gd`

* **G-SS-OFF (byte identity):** flag off ⇒ (a) `approach_offset_y` input equals the shipped
  radial-h for a synthetic summit pose (assert the exact offset −(h−o_base) value); (b)
  `_ramp_pool_step` pace == 0 for the active slot with a scripted controller pinned credit-0 and an
  imminent neighbour set (the shipped dead-floor behaviour, asserted as the baseline).
* **G-SS-ANCHOR (S1 discriminates):** flag on, summit pose (ground_h = h = 66) ⇒ viewer offset ==
  o_base (not o_base − 66); flying pose (h = ground_h + 300) ⇒ offset/release equal the shipped
  values at d = 300 (the airborne law preserved).
* **G-SS-FLOOR (S2 discriminates):** scripted pool {active cur 48 < tgt 128, imminent = neighbour
  fid, credit 0} ⇒ active slot pace ≥ CTRL_RELIEF_FLOOR under the flag (0 without); assert the
  ramp completes within RAMP_SECONDS/CTRL_RELIEF_FLOOR synthetic seconds.
* **G-SS-ORDER (priority law pin):** for the summit pose, assert the viewer-to-standing-surface
  distance ≤ o_base + ε under the flag (the priority proxy — we cannot read C++ band0 from GDScript,
  so pin the input that determines it), vs ≥ h − o_base without.
* **G-SS-BUDGET (no frame-budget regression):** pace never exceeds 1.0; single-grow-channel
  invariant holds (≤ 1 slot advanced per tick); view_target never exceeds near_render_radius
  (NEVER-OOM assertion); no new allocations in the per-frame path (reuse existing verify_fp_m2
  helpers).

## 6. Live captures requested (to pin the shot-1 queue-idle state)

While re-reproing the summit wait, sample each second: `module pool_view_stats` (per-slot
view_f/view_target/pool_active), `viewer_offset_y()` + `viewer_view_distance()`
(module_world.gd:502-506), controller `stats()` (credit, setpoint, frame_worst_ema, backlog_gated,
inflight_gated), and `get_statistics().dropped_block_loads` delta. Expected under this diagnosis:
offset_y ≈ −62 the whole time; during the climb view_f frozen < 128 with `_imminent_fid ≥ 0`;
at the summit `_imminent_fid = −1`, view_f growing ≈ 13 blocks/s; drops incrementing without
backlog. An A/B with FP_SMOOTH_V2_NEARFILL off should show the SAME arrival timing (blocks), only
uglier cover — confirming the #107 verdict of §1.

## 7. Residuals / adjacent findings

* Task #105 (pool-miss crossing → pool_reset teardown) can still strand the active facet at
  RAMP_START — S2's repair (view_target un-collapse, l.522-528, guard also relaxed) covers the
  ramp side; the teardown itself stays #105.
* The §3.A credit trap (p90 > 2×p10 clients pinned at 0 forever) deserves its own follow-up: a
  variance-aware setpoint (e.g. margin on p50, or clamp floor_p10 from below by the EMA median)
  would un-pin high-jitter clients globally; out of scope here because S1+S2 make the near field
  independent of it for the standing facet.
* `dropped_block_loads` is lifetime-cumulative for VoxelTerrain (no per-frame reset in
  voxel_terrain.cpp, unlike voxel_lod_terrain.cpp:1171) — the remote bridge's per-window max
  (remote_bridge.gd:515) therefore reports a monotone counter; worth a delta-per-window fix in
  telemetry before using it as a rate signal.
