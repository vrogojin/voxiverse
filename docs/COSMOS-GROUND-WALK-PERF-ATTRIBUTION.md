# COSMOS — Ground-Walk-Near-Village Perf Attribution: the Movement Frame Cost

**Status:** analysis + instrumentation design (no implementation in this pass). Branch
`deploy/perf-plus-sky`, worktree `deploy-cheats`.
**Scope fence:** this doc owns the **per-frame MOVEMENT cost** (streaming tail / move-probe /
physics / near-field generation admission) for walking near a village. It does NOT cover
draw-call/chunk-baking architecture (a parallel agent's brief) or the LOD-ladder tree/house
flicker (another parallel agent's brief). It is the walking-specific sibling of
`docs/COSMOS-PERF-POSTPORT-DESIGN.md` (crossing-focused, same session) and reuses that doc's
cost model where it applies.

---

## 0. The measured problem

Walking near a village: `worst_ms` median **150 ms / p90 238 / max 378** (~7 fps effective;
38 fps at rest). The worst-378ms-window's telemetry bundle:

```
draws=83  prims=569k  objects=154  vox_gen=151  t_stream_us=18861  t_move_us=19780
phys_ms=28.6  st_bms=12.8  smooth_v2_commit_ms=11.8  vt_total_ms=1.42  main_commit_ms=0.02
```

Sum of every named main-thread bucket: 19.78 + 18.86 + 28.6 + 12.8 + 11.8 + 1.42 + 0.02 =
**≈93.3 ms**, against a **378 ms** frame. **~285 ms (75 %) is unattributed to any named
bucket.**

---

## 1. First correction: these numbers do not even prove co-occurrence

Before attributing the 285 ms gap, a more basic problem: **the fields quoted above are not
all samples of the same frame**, so the 93.3 ms "main-bucket sum" is already an
*upper bound*, not a measured total. Reading the actual telemetry code
(`godot/src/net/remote_bridge.gd`):

- **`worst_ms`** (`_win_worst`, line 467) is a genuine **window MAX** of the true wall-clock
  frame delta — correctly the worst single frame in the ~250 ms emission window.
- **`vt_total_ms`** (`_win_vt_total`, line 614) is *also* a genuine window MAX (of the active
  `VoxelTerrain::_process` four-timer sum) — the code comment at line 191-192 explicitly says
  it is "directly comparable against worst_ms for the SAME window", i.e. this is the ONE
  field in the bundle actually built to be compared against `worst_ms`. And it is **1.42 ms**
  — meaning the active near-terrain's own C++ `_process` (its mesh-apply/upload path) is
  *acquitted* for this window. (Caveat below: it only covers the *active* terrain slot, not
  imminent/neighbour pool slots.)
- **`t_move_us` / `t_stream_us`** (`player.gd` `_ft_max`, confirmed by
  `verify_fall_timing.gd:54` — "PLUMBING: t_move_us holds the window MAX") are **also**
  independent per-window maxima — but each is maxed over its *own* segment across whatever
  frame produced the local peak for *that* segment. Two different frames in the same window
  can each contribute one of these maxima; nothing proves they landed in the same physical
  frame as `worst_ms`.
- **`phys_ms`**, `draws`, `prims`, `objects`, `vox_gen` are **not window statistics at all** —
  they are `Performance.get_monitor(...)` / `VoxelEngine.get_stats()` reads taken once, at the
  4 Hz telemetry-emission instant (`remote_bridge.gd:754-765`). They describe *whatever frame
  happened to be current when the timer fired* — which, in a 250 ms window containing one
  378 ms outlier among ~15 other frames, is very likely **not** the outlier frame.
- **`st_bms`** (`_dbg_stage_ms_last`, `facet_far_structures.gd:524`) and
  `smooth_v2_commit_ms` are **last-value** snapshots (whatever the most recent pass cost when
  polled), not maxima either.

So the 93.3 ms figure is best read as "the largest plausible main-bucket contribution this
window could have produced, generously assuming every bucket's local peak landed on the worst
frame" — and even under that generous assumption, **~75 % of the worst frame is unexplained**.
This is itself the headline finding of §3 (telemetry insufficiency) and is why the fix in §4
leads with instrumentation before further tuning.

---

## 2. Reading the hot paths

### 2.1 `update_streaming` — the per-physics-tick orchestration tail (`world_manager.gd:1348+`)

Called once per physics tick from `player.gd:921` (wrapped in `t_stream_us`). It is a ~450-line
function (`world_manager.gd:1348-1800+`) that, every tick, touches: the chunk streamer /
`GroundCollider` center, `FP_VEL_PREDICT` speed EMA, `FP_ENV_FALL_HOLD`/`FP_LAND_RAMP_HOLD`
fall-speed EMA, `_update_alt_regime`, `_update_approach_anchor`, the skin-tile scheduler
(`_skin.update`), far-ring coverage/seam/band query wiring, the facet-texture baker's governed
pacer (`_facet_tex.update`), the DEM/relief pacer (`_relief_data.step`), and — further down,
not shown in the excerpt above — the neighbour-pool manager (`world_manager.gd:3267`,
run every tick). Each individual piece is a cheap no-op-when-idle check, but there are a
*dozen-plus* of them, every physics tick, with no batching/skip logic beyond
`FP_STREAM_TICK_ONCE` deduping the tail to once per render frame (not once per N frames).
18.9 ms is the accumulated cost of this whole per-tick sweep under load (many subsystems
doing real work simultaneously: the skin tiles scheduling, the texture baker's budgeted bake,
the DEM pacer, the pool manager) — it is real GDScript-interpreter cost, but it is one
function running its designed job, not a leak.

### 2.2 The move-probe (`player.gd:1856-1951`, wrapped in `t_move_us`, sub-timed as `t_probe_us`/`t_floor_us`)

`_move()` runs the six analytic wall probes (`world.blocked(...)`, cacheable —
`FP_MOVE_PROBE_CACHE`), gravity integration, the swept-ceiling scan, and
`world.floor_under(...)` (the landing query). `FP_MOVE_PROBE_CACHE` (per-physics-tick memo of
`cell_value_at` under `world_manager.gd:343,1643-1664`) exists specifically to remove the
repeated-probe cost here, but **defaults `false` in the repo**
(`cosmos/cube_sphere.gd:4306`) — its live-deploy state is unverified (same "gap" class as
`FP_CPPGEN` in `COSMOS-PERF-POSTPORT-DESIGN.md` §0: repo consts are `false`, the deploy flips a
subset via sed, and the flags-stamp doesn't currently capture this one). All six wall probes
plus the floor scan route through `WorldManager.block_id_at` / `cell_value_at`, which is
edits-overlay-else-generated (`world_manager.gd` — `_edits` dict lookup, else
`TerrainConfig.generated_block`). Near a village the edits/structure density is higher, but
the probe count per tick is fixed (6 + 1), so the 19.8 ms here is more likely either (a) the
cache genuinely being off live, or (b) `cell_value_at`'s generated-fallback path being
comparatively expensive near a village specifically because uncached columns require a fresh
`generated_block` evaluation.

### 2.3 Physics (`phys_ms` — `Performance.TIME_PHYSICS_PROCESS`, `remote_bridge.gd:755`)

This is the **engine's own physics-server step time**, not GDScript — it covers `GroundCollider`
(the small local blocky-shape collider re-centered on the player every tick,
`world_manager.gd` — "GroundCollider local blocky physics collider around the player") plus any
live `VoxelBody` rigid bodies. A village plausibly has more nearby collidable geometry
(structure-adjacent blocky shapes, any loose/broken debris) than open terrain, inflating this
figure; it is also, per §1, a same-instant *snapshot* rather than a value proven to belong to
the worst frame.

### 2.4 Near-field generation triggered by walking (`vox_gen=151`)

Near-terrain streaming is **not driven by any of the above GDScript timers** — it is
`godot_voxel`'s own C++ `VoxelViewer`/`VoxelTerrain` machinery: as the player's global
`VoxelViewer` (`module_world.gd:3084-3109`) moves, the engine autonomously streams/generates
blocks around it on worker threads and applies finished meshes on the main thread via its own
internal `VoxelEngine::process` / time-spread task runner — entirely outside GDScript, and
therefore outside every bucket named in §0. This is exactly the mechanism
`COSMOS-PERF-POSTPORT-DESIGN.md` (same session, dated same day) already root-caused for the
**crossing** case: post the `FP_CPPGEN` C++ generator port (patch
`docker/engine/patches/godot_voxel/0007-cosmos-cpp-generator.patch`, compiled into the engine
at `docker/engine/cache/godot/modules/voxel/generators/cosmos/voxel_generator_cosmos.cpp`),
generation itself is fast (300-964 blocks/s) and no longer the bottleneck — **the pipeline's
pacer moved from the workers to the main thread**: each admitted burst of blocks lands as a
compressed mesh-apply/upload burst (`vox_main` observed spiking 17-87 *inside* the worst
frames, `voxel_terrain.cpp:1901-1920` + `mesh_storage.cpp:219-276`), and *that* stage has **no
GDScript-visible timer at all** (§3). `vox_gen=151` here is well under the legacy admission
gate's `CTRL_BACKLOG_MAX=300` (`cube_sphere.gd:2520`) — i.e. even the shipped backlog gate
would not have throttled this — consistent with "generation supply ≥ demand"; the burst that
matters is downstream of generation, in mesh + apply.

### 2.5 Why a village specifically (`st_bms=12.8`)

`st_bms` is nonzero **only** under `FP_STRUCT_BAKE_STAGE`
(`facet_far_structures.gd:527-532`) — its presence in this session's telemetry is itself proof
structures are live in this deploy. `FacetFarStructures.step()` runs every render frame from
`FacetFarRing._process` (`facet_far_ring.gd:1529-1530`), **not** from `update_streaming`/
`_physics_process` — it is a *separate* main-thread cost bucket, additive to the
`_physics_process` buckets, not overlapping with them. Near a village it does real work: probing
near-coverage per registered structure (`_probe_pass`), running the staged bake drain
(`_drain_bakes`, time-boxed at `STRUCT_BAKE_STAGE_MS` but guaranteed ≥`STRUCT_BAKE_STAGE_MIN`
fresh bakes per call — i.e. it can and will exceed its nominal budget to guarantee forward
progress), and rebuilding the merged LOD-A structure mesh. Village structures are (per
`world_manager.gd:310-316`, `FP_STRUCT_GEN`) **procedurally declared but not (in P0) folded
into the block generator itself** — `FP_STRUCT_GEN` is "declared, unused in P0"
(`cube_sphere.gd:1238`) — so the extra near-village generation load is not structure-sampling
inside `GenerateBlock`; it is (a) ordinary streaming into a less-visited area plus (b) this
independent far-structures render/bake pass running concurrently.

---

## 3. Is the current telemetry sufficient to isolate the movement worst-frame cost?

**No.** Two distinct gaps, both established above:

1. **No worst-frame-keyed decomposition.** Every field in §0 except `worst_ms` (and
   `vt_total_ms`, which is comparable but ~0) is either an independently-maxed segment or an
   instantaneous snapshot at the telemetry-tick boundary — none of them are captured *at the
   moment the worst frame is identified*. `worst_ms` is already tracked continuously
   (`remote_bridge.gd:467`, `if real_delta > _win_worst: _win_worst = real_delta`) but nothing
   is captured alongside that comparison.
2. **No visibility into the apply/upload/receive stage.** The mesh-apply burst
   (`VoxelEngine::process`, the time-spread task runner, inline `glBufferData` uploads) is
   entirely internal to the engine and untimed by any exposed stat today; `vt_total_ms` only
   covers the *active* `VoxelTerrain`'s own `_process`, not the imminent/neighbour pool slots
   or the engine-global receive/apply loop (`COSMOS-PERF-POSTPORT-DESIGN.md` §2.2c/§3, items
   T2a/T2b — already scoped, not yet implemented). This is the same gap that doc names as "the
   biggest single unknown" for crossings; it applies identically here, since the mechanism
   (admitted blocks → compressed apply burst) is not crossing-specific.

### Proposed instrumentation (design only — byte-off, no engine rebuild required for the first cut)

**`FP_WORST_FRAME_ATTR`** (new flag, default `false`) — a pure-GDScript worst-frame-keyed
snapshot, piggybacking on the exact comparison `remote_bridge.gd:467` already performs:

```gdscript
# inside RemoteBridge._process, right where _win_worst updates:
if real_delta > _win_worst:
    _win_worst = real_delta
    if CubeSphere.FP_WORST_FRAME_ATTR:
        _win_worst_snapshot = _capture_worst_frame_snapshot()   # cheap: one dict build, only on a NEW worst
```

`_capture_worst_frame_snapshot()` reads, all at the instant the new worst is recognized (same
frame, not the next telemetry tick):
- `VoxelEngine.get_stats()` → `tasks.generation/meshing/main_thread/gpu` (this frame's true
  in-flight counts — currently only sampled at the 250 ms boundary), `thread_pools.general.
  {thread_count, active_threads, task_names}` (the existing dlmalloc-convoy discriminator,
  `remote_bridge.gd:703-726` — already computed for the emit path, just not keyed to the worst
  frame),
- `Performance.get_monitor(TIME_PHYSICS_PROCESS/RENDER_TOTAL_DRAW_CALLS_IN_FRAME/
  RENDER_TOTAL_PRIMITIVES_IN_FRAME/OBJECT_NODE_COUNT)` (same calls already made for the emit
  path, called here instead at the correct instant),
- the **live** value of `st_bms`/`smooth_v2_commit_ms`/`main_commit_ms` (whatever they hold
  *right now*, which — since this fires within the same frame the delta was measured — is a
  much tighter correlation than the current 250 ms-later snapshot),
- if `FP_FALL_TIMING` is also on: the current (in-progress, not yet window-flushed) values in
  `Player._ft` for `t_move_us`/`t_stream_us`/`t_probe_us`/`t_floor_us`, via a new read-only
  accessor (they are usually mid-window at this point, so this still isn't a perfect per-frame
  cut, but it narrows the correlation window from 250 ms to "since last new-worst").

Emit once per telemetry window as `wf_*`-prefixed fields (`wf_vox_gen`, `wf_pool_active`,
`wf_draws`, …) alongside the existing `worst_ms`, so the analyst can finally ask "what did
*this specific* worst frame actually look like" instead of "what did some frame in this window
look like". Cost: one dict build per **new window maximum** (rare — at most a handful of times
per 250 ms window, typically once), not per frame. NEVER-OOM: zero (no growing state).

This is a walking-specific generalization of `COSMOS-PERF-POSTPORT-DESIGN.md`'s T2a/T2b/T2e
(engine apply/receive/upload meter, all-pool `vt_*`, far-ring re-emit timer) — those remain the
correct **second** step (they require an engine patch and answer "why is the apply burst
costly", not just "was there one"); `FP_WORST_FRAME_ATTR` is the **zero-engine-rebuild first
step** that would already, on the very next live session, tell us whether the 285 ms gap is
(a) a `vox_gen`/`vox_mesh`/`vox_main` burst that just missed the 250 ms sample, (b)
`pool_active ≈ pool_threads` (the dlmalloc-convoy signature — threads running but crawling,
already the H-A/H-B discriminator `remote_bridge.gd:703-706`), or (c) something with all voxel
queues at zero (the postport doc's unattributed §2.2c stall, prime-suspected as far-ring
re-emit — also plausible here independent of crossings, since `st_bms`/structure rebuilds and
`smooth_v2_commit_ms` both fire from the same `_process` tail).

---

## 4. Attribution verdict

**Dominant cost = (c), a mix, with the convoy/apply-burst term dominant by a wide margin.**

- Named main-thread GDScript buckets (`t_move` + `t_stream` + `phys_ms` + `st_bms` +
  `smooth_v2_commit_ms` + `vt_total_ms` + `main_commit_ms`) sum to **≈93 ms**, generously
  assuming co-occurrence (§1 shows this assumption is itself unproven and probably an
  overestimate).
- **≈285 ms (≥75 % of the 378 ms frame) is unattributed** by any exposed instrument.
- `vox_gen=151` is well inside the C++-generator's healthy drain range and under the legacy
  admission ceiling — generation *supply* is not the bottleneck (matches
  `COSMOS-PERF-POSTPORT-DESIGN.md`'s explicit, measured verdict for the same code path in the
  crossing case: "Generation is a minor term now").
- The unattributed remainder's most likely home, by elimination and by the sibling doc's
  measured mechanism, is the **mesh-apply/upload burst** inside `VoxelEngine::process` /
  the time-spread task runner (uninstrumented on the GDScript side, `vox_main` observed
  spiking 17-87 *inside* worst frames in the crossing study) — a burst admitted because there
  is currently **no admission signal keyed to that stage**: `stream_pace()`/`backlog_gated()`
  still gate on raw `vox_gen` alone by default (`FP_INFLIGHT_GATE := false`,
  `cube_sphere.gd:2714`), which the C++ port made an unreliable proxy for main-thread pressure.
  A secondary, additive contributor is the structures far-render pass (`st_bms`,
  §2.5) running concurrently and independently of the streaming tail. The residual dlmalloc
  single-worker-lock convoy (established this session's earlier work,
  `voxiverse-walk-perf-root-cause.md`) remains a plausible amplifier of whichever burst is
  dominant, but cannot itself be confirmed or excluded without §3's instrumentation
  (`pool_active` vs `pool_threads` at the actual worst frame, not a 250 ms-displaced sample).

---

## 5. Ranked fix recommendation

| rank | fix | targets | impact | effort | status |
|---|---|---|---|---|---|
| **1** | **Flip `FP_INFLIGHT_GATE` on, A/B live** (`cube_sphere.gd:2714-2717`, wired end-to-end in `stream_load_controller.gd:29-33,83-91,219,242-244` and `LiveSource.poll` `:294`) | (a) admission pacing keyed to the real choke point | **High** — this is the general, always-on (not crossing-only) version of "pace producers by consumer backlog"; `stream_pace()` already gates the near-field view-ramp GROW leg (`module_world.gd:440`) on it, so it directly bounds how fast walking can admit new gen→mesh→apply volume. Already projected by the sibling doc (P1, §4): walking-leg M1 13.5 %→≤6 %, `vox_main` peak 87→<20 | **Zero new code** — const flip + live-flag deploy sed + A/B | **Already implemented, shipped OFF.** Highest leverage per effort in the whole plan. |
| 2 | Ship `FP_WORST_FRAME_ATTR` (§3) before further tuning | instrumentation, not a fix | N/A — decisive for validating #1 and for correctly prioritizing #3-6 | Small (~30-40 lines GDScript, no engine rebuild) | Design only (this doc) |
| 3 | Confirm/flip `FP_MOVE_PROBE_CACHE` (`cube_sphere.gd:4306`) + `FP_STREAM_TICK_ONCE` (`cube_sphere.gd:1325`) live state; ship if off | (d) move-probe cost, (c) streaming-tail dedupe | Low-medium — even fully eliminating both buckets recovers ≤38.7 ms of a 378 ms frame (~10 %); real but far below #1's ceiling | Low — flags already coded and designed (`FP_MOVE_PROBE_CACHE` §6.3/§6.5 in `world_manager.gd`) | Live deploy state unverified — same "gap" class as `FP_CPPGEN` was pre-T2d |
| 4 | `FP_STRUCT_BAKE_STAGE` budget tuning (`STRUCT_BAKE_STAGE_MS`/`_MIN`) for the village case specifically | the `st_bms=12.8 ms` slice | Low — bounds one ~13 ms bucket already inside a staged, self-limiting drain | Low | Already staged; only a constants tune, gate on #2's data before touching |
| 5 | Ship the T2a engine-side apply/receive/upload meter (`COSMOS-PERF-POSTPORT-DESIGN.md` §3) | confirms/prices the mesh-apply-burst hypothesis precisely, unlocks P5 (mesh_block_size, receive cap, byte budget) | Decisive for follow-up work, not itself a frame-time fix | Medium — one engine patch batch | Design only, in the sibling doc |
| 6 | (b) Cut per-block gen alloc volume | near-field `GenerateBlock` heap cost | **Explicitly deprioritized.** The C++ port (`FP_CPPGEN`) already moved generation to 300-964 blocks/s, well above measured walking demand (`vox_gen=151` < `CTRL_BACKLOG_MAX=300`). The sibling doc's own verdict: "Gen-side micro-optimization of the C++ generator — supply ≥ demand at every speed measured; further gen speed buys nothing the eye can see." | — | Do not pursue before #2's data contradicts this |

**Top recommendation:** flip `FP_INFLIGHT_GATE` on and A/B it on the walking-near-village
route. It is the only item on this list that targets the ~285 ms unattributed majority of the
frame (by pacing the stage the postport analysis and this doc both converge on — the
mesh-apply/upload burst — rather than the ~93 ms of named GDScript buckets), it requires zero
new code, and its mechanism (`stream_pace()` already gates the ordinary walking view-ramp grow
leg, not just crossings) generalizes cleanly to the village-walking scenario measured here.
Pair it with `FP_WORST_FRAME_ATTR` (rank 2) in the same deploy so the A/B has a real per-worst-
frame breakdown instead of another window-displaced sample set.

---

## 6. Files referenced

- `godot/src/net/remote_bridge.gd` — telemetry emission (`_process:450-479`, `worst_ms`/
  `vt_total_ms` window-max tracking `:467,614`, snapshot fields `:746-793`, `vox_gen`/pool-
  thread discriminator `:700-731`).
- `godot/src/player/player.gd` — `_physics_process:885-1023` (the `t_move_us`/`t_stream_us`
  wrap sites), `_move` wall-probes + floor query `:1856-1954`, `_ft_max`/`fall_timing`
  `:2976-2994`.
- `godot/src/world/world_manager.gd` — `update_streaming:1348+`, edit-overlay `_edits`/
  `_edits_by_fid`/`_structure_tracker`/`_gen_index` `:280-320`, `structure_cell_at:3983`.
- `godot/src/world/voxel_module/module_world.gd` — `_make_generator:3286+`, `FP_CPPGEN`
  compiled-generator swap `:4094-4105`, `attach_viewer`/near-field streaming `:3084-3109`,
  `set_stream_pace`/`_ramp_pool_step` `:2106,510`.
- `godot/src/world/facet_far_ring.gd` — `_process:1490+` (structures/smooth-v2/orbit-relief/
  far-trees step calls, `:1503-1530`).
- `godot/src/world/facet_far_structures.gd` — `step:211-254`, `_drain_bakes`/`st_bms`
  `:506-532`.
- `godot/src/world/stream_load_controller.gd` — the AIMD admission controller,
  `FP_INFLIGHT_GATE` wiring `:29-33,83-91,219,242-244`, `LiveSource.poll:280-295`.
- `godot/src/cosmos/cube_sphere.gd` — flag defaults: `FP_CPPGEN:224`, `FP_INFLIGHT_GATE:2714`
  + `INFLIGHT_MAX/MIN/MAIN_K:2715-2717`, `FP_MOVE_PROBE_CACHE:4306`, `FP_STREAM_TICK_ONCE:1325`,
  `FP_STRUCT_*:1225-1278`, `CTRL_BACKLOG_MAX:2520`.
- `docs/COSMOS-PERF-POSTPORT-DESIGN.md` — the crossing-focused sibling analysis this doc
  builds on (same C++-port cost-landscape shift, same unattributed-apply-burst mechanism).
- `docker/engine/patches/godot_voxel/0007-cosmos-cpp-generator.patch`,
  `docker/engine/cache/godot/modules/voxel/generators/cosmos/voxel_generator_cosmos.cpp` — the
  compiled-in C++ generator `FP_CPPGEN` switches to.
