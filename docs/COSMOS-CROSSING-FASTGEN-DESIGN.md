# COSMOS — Crossing residual (obs 2) + fast-move "fall-through" (obs 3)

Investigation by the `crossing-fastgen` agent (27,922 telemetry rows / 13 crossings, 2026-07-16 session). Read-only; this doc persists the findings for implementation.

## Obs 3 — "fall-through when moving fast" is a VISUAL see-through, NOT a physics fall

Ruled out with code evidence:
- **(a) GroundCollider lag — NO.** The GroundCollider is wood-debris-only (`ground_collider.gd:7-8`, gated off unless an awake `VoxelBody` is near, `:169-175`). The player's `collision_mask = WOOD_LAYER_MASK` only (`player.gd:143`) — the player never touches it; movement is analytic.
- **(b) Analytic-query / memo outrun — NO.** `world.floor_under()` / `blocked()` / `ceiling_scan()` (`player.gd:402,351-360,499`) resolve through `cell_value_at` = edit-overlay-else-`TerrainConfig.generated_cell` (`world_manager.gd:607-624,2634`) — a **pure function of the global cell**. The only cache is a per-call dict the floor/blocked queries don't even pass. **No persistent memo a fast player can outrun; the query is instant + streaming-independent.**
- **(c) Streamed RENDER MESH missing — YES.** With (a),(b) excluded, the "fall-through" is the near-field **mesh** not existing yet — the 2 web workers are saturated (`vox_gen` backlog 2,520–4,576 at crossings vs `CTRL_BACKLOG_MAX`=300). Meshes land in a burst → visible holes to the void / far-ring behind. **The player stands on analytic ground the whole time — it only *looks* like falling.**

Telemetry: `worst_ms` p50 37 / p90 86 stationary vs **p50 83 / p90 185 moving >8 u/s** — movement ~doubles the worst frame.

**Consequence: obs 3 is a RENDER-COVERAGE problem, not a collider fix and not a hard collision-throughput problem.** ⇒ **`FP_FARRING_FULL_COVER` (obs 1) fixes obs 3 too** — when the near mesh lags, the sunk far-ring backstop shows plausible ground instead of void.

## Obs 2 — residual crossing spike (post_worst 95–300 ms)

The imminent facet's **meshes are already pre-warmed** during approach (`POOL_CROSSING_PREGEN`, `cube_sphere.gd:298`; view 96→128 in `set_imminent_fid`; committed ramp full-pace `CTRL_IMMINENT_COMMIT_PACE`=1.0, `module_world.gd:463-469`). At the crossing `redesignate` just relabels → **zero new mesh on the crossing frame** (`transform_ms=0`, `crossing_ms` 1.7–19 ms all 13 crossings). The residual is the **annulus that didn't finish meshing** because 2 workers can't drain the queue.

### Why `stream_credit` is still pinned at 0 (99.3% of rows) — a feedback trap
Adaptive setpoint = `clamp(floor_p10×1.3, 18, 45)`; measured `floor_p10`=17.5 ms → setpoint ≈ **22.8 ms**. But the client's frame exceeds 22.8 ms in **52%** of windows (p50 23.2 / p90 50.5). The window-p90 EMA sits above the setpoint almost always → permanently "overloaded" → credit 0. The 40–50 ms frames are the mesh-upload spikes the credit is *meant* to throttle, but throttling admission doesn't clear a render/GPU-upload tail → self-sustaining pin. Cost: `promote_imminent_admitted()` needs credit ≥0.5 → never fires → the imminent promotes only via geometric fallback (`ridge < POOL_D_COMMIT`=64, `world_manager.gd:2012`) instead of `D_WARM`=96 → **~3.4 s less gen lead** at run speed.

## Ranked fixes (all flag-gated, byte-safe off, NEVER-OOM)

Obs 3 (after N1 far-ring cover lands — it's the primary fix):
1. **Soft speed-clamp** coupled to near-field mesh coverage (`module_world.area_meshed(pos+v·t)`, `:1688-1700`) — cap effective speed when the terrain ahead isn't meshed. Zero memory. *CHANGES FEEL → user decision.* Likely unnecessary once N1 shows ground-not-void.
2. **Velocity-aware predictive streaming** — scale `POOL_D_COMMIT`/`D_WARM` with `|v|` (`d = base + k·|v|`) → earlier promote → more gen lead. Helps obs 2 + 3. SAFE.

Obs 2:
1. **Un-pin the controller** — raise the adaptive margin 1.3 → ~2.0 (`FP_CTRL_ADAPTIVE`) so credit floats up → imminent promotes at `D_WARM` (+3.4 s lead), 2nd/corner volume spreads into headroom. Tune from the live setpoint/credit trace. SAFE (flag-gated).
2. **Lower `POOL_IMMINENT_PREFILL_BLOCKS` 128 → 112** — strictly reduces bytes (~40→30 MB) + approach backlog, for a tiny 112→128 annulus hidden behind fog/curved far-ring. SAFE.

## Instrumentation gap (do this — cheap, unblocks future diagnosis)
The bridge emits only `credit`, not `setpoint_ms`/`frame_worst_ema`/`floor_p10`/`backlog_gated` (all present in `stream_load_controller.gd:225-231`, telemetry at `remote_bridge.gd:544`). Add them so "adaptive off" vs "on but genuinely over setpoint" is directly readable. Also: record the exported `FP_*` flag set in `BUILD-INFO.txt` (deploy flips them via sed but leaves no provenance).
