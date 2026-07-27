# COSMOS main-thread orchestration — "the main thread deals ONLY with the orchestration of other threads"

Status: DESIGN (no implementation). Audited at `deploy/cheats-eyeball` (dd6bd6b, the live tip).
Companion to docs/COSMOS-PERF-POSTPORT-DESIGN.md (apply-bound inversion) and
docs/COSMOS-LOD-TEXTURE-DESIGN.md (the bake this design offloads first).

## 0. The directive and the one hard constraint

The pilot's architectural directive: **the main thread should do nothing but orchestrate other
threads.** On the threaded Web export that has exactly one immovable boundary: **GPU resource
commits — mesh RID creation/`add_surface_from_arrays`, `Texture2DArray.create_from_images` /
`update_layer`, material/shader-param sets, and anything that touches the scene tree — happen on
the main/render thread.** The project already codifies this: the far-ring async path documents
"`commit_to_arrays` … touches NO RenderingServer" for the worker and "the ONLY RenderingServer
touch of the async path" for the main-thread swap (`godot/src/world/facet_far_ring.gd:860-863,
937-939`).

So "orchestration only" concretely means:

* **workers do all COMPUTE** — worldgen, meshing/`SurfaceTool`, the FP_FACET_TEX satellite bake
  (sampling, box-average, premultiply, mip generation), far-ring cache warm/env-envelope builds,
  manifest **model construction**, env sims;
* **main does only**: (a) dispatch (freeze inputs, `WorkerThreadPool.add_task`), (b) the minimal
  final GPU upload of finished buffers under an explicit per-frame commit budget, (c) input /
  camera / the analytic player physics.

Everything below is ranked by measured/estimated main-thread impact on the live build, where the
recurring calibration is **web ≈ ×25 native for GDScript compute** (docs/COSMOS-GEN-EFFICIENCY-
DESIGN.md; re-confirmed across FP_ENV_ALL and the fall-collapse fixes).

## 1. AUDIT — what heavy work runs on the MAIN thread today

Thread inventory first (the budget everything must fit into):

| Pool | Size (web) | Who uses it | Where pinned |
|---|---|---|---|
| Emscripten pthread pool | **16, fixed at engine build** (`PTHREAD_POOL_SIZE=16`, engine patch 0001) | everything below | `godot/project.godot` `[voxel]` comment block |
| godot_voxel VoxelEngine task pool | 3–10 by cores (hw≥14 → 10) | worldgen (`VoxelGeneratorCosmos.generate_block`, FP_CPPGEN) + near meshing | `godot/project.godot` `voxel/threads/count/*`; `godot/src/world/voxel_module/module_world.gd:18-25` |
| `WorkerThreadPool` | 2 slots budgeted | far-ring async mesh build (`facet_far_ring.gd:858`) | project.godot ledger: "voxel(≤10) + WorkerThreadPool(2) + audio/IO/spare(≤3) = 15 < 16" |
| Dedicated `Thread` | 1 (FP_WEATHER_THREAD) | `EnvSimWorker` weather sweep (`godot/src/sim/env_sim_worker.gd`) | `world_manager.gd:328-332` |

**Design law derived from this table: no new dedicated `Thread`s.** The pool is fixed at 16 and
already ledgered at 15 worst-case (+1 weather). Every new offload in this design multiplexes onto
the existing 2 `WorkerThreadPool` slots through one job lane (§3). Exhausting the pool is the
known catastrophic failure ("thread pool is exhausted → meshing deadlock → blank world",
`module_world.gd:18-21` / project.godot).

### J1 — FP_FACET_TEX satellite bake: **ALL compute on main** (the live proc_ms 140 spike)

Where it runs now: `WorldManager.update_streaming` calls `FacetTexBaker.update(...)` once per
physics tick on the main thread (`godot/src/world/world_manager.gd:915-929`). Inside
`facet_tex_baker.gd` everything is main-thread:

* `sample_fine` / `_bake_closeup_slice` — the GDScript packed-array build (1024 / 2048 columns of
  `_bilerp` + `_pack_xz` per unit) + ONE C++ `sample_columns` call, then a GDScript
  `set_pixel` composite loop (`facet_tex_baker.gd:145-193, 413-452`);
* `_recompute_want` / `_next_base_fid` — 6·K²=3456-facet dot scans (`:273-295, 318-343`);
* `_flush_base_uploads` / `_flush_closeup_uploads` — **`premultiply_alpha()` +
  `generate_mipmaps()` on the CPU, then** `Texture2DArray.update_layer` (`:299-311, 481-493`).

Compute vs GPU-commit split: only `update_layer` / `create_from_images` (a few lines) is a GPU
commit. Sampling, box-average, premultiply and mip generation — the overwhelming bulk — are pure
CPU.

Why the budget slicing is not enough: the budget (`FACET_TEX_BAKE_BUDGET_MS := 2.0`,
`godot/src/cosmos/cube_sphere.gd:539`) is correctly checked BEFORE each unit, so the worst frame
is *budget + one unit*. But units were calibrated **native**: a whole-facet base bake ≈ 0.9 ms, a
16-row close-up slice ≈ 0.5 ms (`cube_sphere.gd:542`). At web ×25 one unit is **12–25 ms**, so the
baker alone legally spends ~14–27 ms on a spike frame, plus the flush's premultiply+mips on a 384²
page, plus the want-scan — stacked on the far ring's own `_process` work (J2) during the same
descent/orbit phases. That is the observed proc_ms 140 / fps 40 signature while the bake runs.

Can the compute move to a worker? **YES, cleanly.** The two thread-safety facts:
1. The baker owns a **private** compiled `VoxelGeneratorCosmos` instance
   (`_sampler_obj = FacetSkinTier._build_cpp_gen(active_fid)`, `facet_tex_baker.gd:90-95`) — not
   shared with the streaming generator. `sample_columns` is a pure read of tables frozen at
   compile; the *same C++ class* already runs concurrently on the godot_voxel worker pool for
   worldgen, so calling it from one bake worker is the already-proven contract.
2. `Image` is a plain CPU resource; `set_pixel`/`premultiply_alpha`/`generate_mipmaps` on a
   worker-owned `Image` touch no server. Single-writer discipline (the in-flight gate of §3)
   removes any concurrent access.

Marshalling plan: main freezes `{emit_axis, offsurface, want-set changes}` and dispatches; the
worker bakes N units into **its own staging Images** (the same fixed pages/layers, single writer),
finishing with premultiply+mips; main polls completion and pays **only `update_layer`** (≤1 base
page and/or ≤2 close-up layers per frame). Double-buffering is implicit exactly as the far ring's:
the currently bound texture stays live and correct (coverage-alpha) while the worker runs.

Expected main-thread reduction: the whole 2–27 ms/frame bake path collapses to ≤~1–2 ms of
`update_layer` on flush frames and ~0 otherwise. **This is the single biggest live win.**

### J2 — FacetFarRing warm/rebuild: **half offloaded, half still main**

Already OFF main (keep): the async mesh build — `_dispatch_async_rebuild` freezes inputs on main,
`_async_build_worker` does SurfaceTool emit + normals + `commit_to_arrays` + (under
FP_ENV_WARM_ASYNC) up to `ENV_WARM_BATCH=12` env-cache builds **on a WorkerThreadPool worker**
(`facet_far_ring.gd:828-935`), and `_swap_in_arrays` pays only the ~0.23 ms mesh swap on main
(`:937-983`). This is the reference pattern for the whole design.

Still ON main (the residue to move):

| Site | What | Cost on main |
|---|---|---|
| `_boot_warm_step` (`facet_far_ring.gd:291-311`) | FP_BOOT_ASYNC initial-hemisphere warm — explicitly "Runs on the main thread — no worker" — **plus a synchronous `_rebuild_full()` every `SHELL_REEMIT_GROWTH=64` newly cached facets** | `WARM_BUDGET_MS=3` + one unit per frame; each progressive re-emit is a full SurfaceTool emit + `generate_normals` + mesh create on main during the first minute of play |
| `_warm_front` / `_warm_front_true_budget` (`:988-1008, 1038+`) | surface + S1b-orbit cache warm (`_ensure_cached` ≈ 25 profile samples; env-envelope variant 16–40 ms/facet) | 3 ms/frame budget + one unit; the env unit at web ×25 is the historical 51 ms orbit stall (fixed for orbit by FP_ENV_WARM_ASYNC, **still live for the floored/surface paths**) |
| `_prewarm_step` (`:487-515`) | S2 one-shot whole-planet warm (skipped when env-async on) | 3 ms/frame budget + one unit |
| `_rebuild_full` sync call sites (`:1231-1264`) — boot progressive re-emits, `force_rebuild`, non-async fallback | whole-front SurfaceTool emit + normals + ArrayMesh create | tens of ms per re-emit on web |

Can the compute move? **YES — proven by its own codebase.** The exact same builders
(`_ensure_cached`, `_ensure_backstop_cached`, `_env_weld_grid`, chord fills) already execute on
the WorkerThreadPool worker under FP_ENV_WARM_ASYNC (`:872-926`) with the frozen-inputs /
single-writer / `_async_building`-gate contract. The offload is *routing*, not new threading: make
the boot warm, the surface/floored warm and the S2 prewarm enqueue the same worker dispatch
instead of running units inline, and replace every remaining synchronous `_rebuild_full` trigger
with `_begin_rebuild()`'s async path (the sync body remains only as the flag-off/headless
fallback).

Marshalling: unchanged from the shipped async path (worker writes `_pos_cache`/`_bpos_cache`/
`_async_arrays`; main swaps). Expected reduction: the steady 3 ms/frame warm slices + the
boot-phase re-emit spikes (the biggest remaining `_process` line items after J1) leave main;
main keeps the 0.23 ms swap.

### J3 — Manifest bake (VoxelBlockyLibrary): **main, multi-second frames**

Where it runs now: `_build_gen_manifest` builds thousands of models synchronously at setup, then
`library.bake()` (`godot/src/world/voxel_module/module_world.gd:976-1075`). FP_MANIFEST_SLICE
defers the cold-biome bulk to `_manifest_cold_step` — **one helper per `_process` frame, "each is
a multi-second synchronous bake"** (`module_world.gd:1086-1106`): four seconds-long main-thread
frames after essential-ready (wet → comps → ~5160-model slope → re-`bake()` + remesh).

Compute vs GPU-commit split — three distinct parts:
1. **Model/mesh construction** (`_build_*_manifest`, `_make_shape_model`, SurfaceTool/ArrayMesh
   assembly, GDScript loops) — pure CPU, the bulk of the seconds. **CAN move to a worker.**
   Resources (`ArrayMesh`, `VoxelBlockyModel`) can be constructed off-thread as long as exactly
   one thread owns them until publication (ResourceLoader does this routinely).
2. **`library.add_model` + `library.bake()`** — **CANNOT move as-is**, two reasons:
   (a) the module's own comment: "each baked model triggers a GPU geometry readback
   (`getBufferSubData`)" (`module_world.gd:982-984`) — the bake reads mesh surfaces back through
   the renderer, which is render-thread work by construction; (b) once the terrain is wired the
   voxel mesher workers **read** the baked library concurrently — re-baking it from a second
   worker would race them (godot_voxel does not document `bake()` as thread-safe; assume NOT).
3. The `_manifest_remesh_near` view-ramp — cheap orchestration, stays.

Plan: worker constructs the model set (per-stage) into a handoff array; main drains it with
**per-model slicing** (N `add_model` per frame under a ms budget — the current slicing is
per-*helper*, 3 orders of magnitude too coarse), then one `bake()`. Attack the `bake()` seconds
directly by eliminating the GPU readback: keep the CPU-side surface arrays that built each mesh
and hand models arrays instead of letting `bake()` read the mesh back (a godot_voxel-side patch —
we carry patches already, cf. patch 0004/0005). A `bake()`-on-worker native spike is worth one
experiment but the design does not depend on it.

Expected reduction: the four multi-second frames become worker seconds + bounded (~2 ms) drain
frames + one final `bake()` — itself shrunk if the readback patch lands.

### J4 — Env-warm (FP_ENV_ALL / FP_ENV_WARM_ASYNC): **already async in orbit — confirm + close the gap**

Confirmed: under env_all + orbit + async, env-envelope cache builds run inside the far-ring
worker (`facet_far_ring.gd:872-926`), batch-bounded (`ENV_WARM_BATCH=12`, `:25`), with chord
fallbacks so coverage never waits (FP_ENV_FALLBACK_EMIT). The remaining main-thread env work is
exactly the J2 residue (floored/surface warm paths + boot). No separate work item — J2 covers it.

### J5 — Worldgen (FP_CPPGEN): **already off main — no action**

`VoxelGeneratorCosmos.generate_block` runs on godot_voxel's own worker pool by architecture; the
main thread only sees applied mesh blocks. The frozen-table publication discipline is documented
at `module_world.gd:157-224` ("baked + FROZEN at setup before the worker wires"). The main-thread
cost of the near field is the *apply/upload* side (docs/COSMOS-PERF-POSTPORT-DESIGN.md) — a GPU
commit, kept bounded by FP_INFLIGHT_GATE + the load controller, i.e. already in its target shape.

### J6 — Weather (FP_WEATHER_THREAD): **already off main — the model to copy**

`EnvSimWorker` (`godot/src/sim/env_sim_worker.gd`) runs the sweep on a dedicated thread with a
front/back double buffer and a single quiesced pointer flip; the main thread pays only `poll()`
(`world_manager.gd:529-541`). Gates G-WTHREAD-SAFE/-MAINCOST/-EVOLVE prove it. Residue: the
one-time `build_init` basis is main-sliced (bounded, acceptable). Its double-buffer contract is
the second marshalling pattern this design generalises (§3).

### J7 — Snowfall sim: **main thread, small but nonzero**

`_snowfall.process(delta, pos)` runs each `_process` on main (`world_manager.gd:515-521`),
already regime-gated (R2/R3: skipped airborne/frozen) and spike-attributed (`_snow_us_max`).
Can it move? **Not verbatim**: it reads AND writes the edit overlay (`WorldManager._edits`) that
gameplay (break/place, collapse, `block_id_at`) touches — rule 1 of the architecture. Offload
requires the EnvSimWorker double-buffer plus a **command-queue publication** (worker computes
cell deltas against a frozen overlay snapshot; main applies the bounded delta list at the flip).
Real work, modest payoff — staged last.

### J8 — FacetSkinTier (F1, currently disabled live): same shape as J1

`update()` bakes heightfield tiles from its **own** `_build_cpp_gen` sampler under a main-thread
budget (`godot/src/world/facet_skin_tier.gd:120-135, 170+`). When task #60 re-enables it, route
its tile bakes through the same job lane as J1 — same sampler-ownership argument, same
Image/mesh-data marshalling. Also the future FacetBlockLod downscale bakes (#76) belong here.

### Ranked offload list (biggest main-thread win first)

1. **J1 texture-bake compute → worker** — kills the live 140 ms spikes (TH1).
2. **J2 far-ring warm/boot/prewarm → the existing worker path; retire sync `_rebuild_full` residue** — kills the 3 ms/frame steady tax + boot re-emit spikes (TH2).
3. **J3 manifest model-construction → worker + per-model drain + readback elimination** — kills the multi-second cold-bake frames (TH3).
4. **J7 snowfall → EnvSimWorker + command queue; J8 skin/block-LOD onto the lane** (TH4, opportunistic).
5. J4/J5/J6 — already correct; hold as the reference patterns.

## 2. Target architecture

```
MAIN (orchestrator)                        WORKERS
────────────────────                       ─────────────────────────────
input / camera / analytic physics          godot_voxel pool (3-10): worldgen + near meshing   [unchanged]
per-frame:                                 WorkerThreadPool (2 slots), ONE JobLane multiplexer:
  1. poll finished jobs                        - far-ring mesh build + env warm   [exists]
  2. GPU-commit budget: ≤1 mesh swap,          - far-ring boot/surface warm       [TH2]
     ≤1 texture page + ≤2 layers,              - facet-tex base/close-up bakes    [TH1]
     ≤N add_model, per frame                   - manifest model construction      [TH3]
  3. freeze inputs + dispatch next jobs        - skin tiles / block-LOD bakes     [TH4]
  4. HUD/telemetry reads               EnvSimWorker Thread (1): weather sweep     [unchanged]
                                               (+ snowfall via double buffer)     [TH4]
```

### The marshalling pattern (one law, two variants — both already shipped somewhere)

**Variant A — job dispatch (far-ring style), for bursty bakes/builds:**
1. MAIN freezes every input the job reads into job-owned state (the `_async_fids` /
   `_async_backstop` discipline, `facet_far_ring.gd:831-857`) and sets an in-flight gate bool.
2. WORKER computes into buffers only it touches while in flight (caches keyed single-writer, or
   job-private staging `Image`s / packed arrays). It never touches RenderingServer or the tree.
3. MAIN polls `WorkerThreadPool.is_task_completed` (then `wait_for_task_completion` to reclaim —
   never blocks, `:940-949`), and pays the bounded GPU commit. The previous GPU resource stays
   assigned throughout — double-buffering by construction (mesh: old `_mi.mesh`; texture: the
   coverage-alpha page).
4. One job in flight per subsystem; a re-request while in flight sets `pending`, never
   re-dispatches (`:550-552`).

**Variant B — free-running sim (EnvSimWorker style), for continuous field sims:** front/back
double buffer, single quiesced pointer flip on main, sim-time-driven determinism
(`env_sim_worker.gd` header). For sims that must write shared gameplay state (snowfall): the
worker emits a **bounded command list** of cell deltas against its frozen snapshot; main applies
it at the flip through the normal edit-overlay API, so `block_id_at` remains the single truth.

Web/SharedArrayBuffer note: GDScript workers share the WASM heap — handing an `Image` or
`PackedVector3Array` across is a pointer move, not a copy. The price is the shared allocator
(§5.1), which is why the lane rule below exists.

**JobLane rules** (the thin new piece, ~100 lines): a priority queue of `{dispatch: Callable,
commit: Callable}` jobs multiplexed onto ≤2 WorkerThreadPool tasks; per-subsystem in-flight
gates; commits drained on main under a per-frame ms budget with the existing spike-attribution
telemetry (`take_perf_attrib`). Priorities: crossing-critical (far-ring rebuild) > texture bake >
manifest > opportunistic.

## 3. What MUST stay on the main thread — and how it is kept bounded

| Main-thread commit | Bound |
|---|---|
| `_mi.mesh` swap / `add_surface_from_arrays` (far ring, skin, clouds) | ≤1 swap/frame/subsystem (measured 0.23 ms) |
| `Texture2DArray.update_layer` / `create_from_images` | ≤1 base page + ≤2 close-up layers per frame (`_flush_*` already batch this way — keep the cadence, move the premultiply/mips OFF) |
| godot_voxel mesh-block apply/upload | existing FP_INFLIGHT_GATE + controller credit (unchanged) |
| `library.add_model` + `library.bake()` (until the readback patch) | N models/frame under a ms budget; `bake()` sliced/eliminated per J3 |
| Scene-tree/`transform` touches (`_placement_xform`, node adds) | O(1) each, keep |
| Shader/material param sets (`set_facet_tex`, sky params) | O(1) each, keep |
| ShaderPrewarm pipeline compiles | inherently render-thread (GL program compile); already masked behind the boot hold |

Every stage's headless gate asserts the main-thread per-frame number (the subsystem's
`worst_frame_ms`-style surface) drops to the commit-only bound.

## 4. NEVER-OOM

Offload moves *compute*, never *allocation*: the worker writes into the **same fixed ledgers**
that exist today (6 base pages + 64 close-up layers ≤ 20 MB, `facet_tex_baker.gd:609-623`;
fid-keyed far-ring caches ≤ 6·K² ≈ 2.4 MB; the manifest's fixed ARID tables). In-flight staging
adds at most one unit's transient buffers (a 32²/2048-column packed array, one 128² Image), which
are **preallocated and reused across jobs** — an alloc diet that is also the dlmalloc mitigation
(§5.1). LRU/eviction rules are untouched. The JobLane itself holds only Callables + gate bools.

## 5. Honest risks

### 5.1 The dlmalloc convoy — the single biggest risk, named explicitly

The WASM build shares ONE allocator lock across main + all workers; the walk-perf root cause
(2026-07-17) was precisely workers and main throttling each other on it. **Moving MORE compute
onto workers does not reduce allocation — it moves the contention to run concurrently with the
frame**, so a naïve port could make main-thread `proc_ms` *worse* via alloc stalls than the
compute it removed. Weighing it: the moved jobs (J1/J2) are allocation-light per unit once the
staging buffers are preallocated (the C++ `sample_columns` fills caller-provided packed arrays;
`set_pixel` writes in place), and they currently run on main anyway — the same allocations under
the same lock, just serialized with the frame. The design therefore (a) mandates the reuse/alloc
diet above as part of TH1/TH2, not a follow-up; (b) requires each stage's live A/B to watch the
*main-thread* worst-frame, not the subsystem's own timer, so a convoy regression is caught at the
gate; (c) notes the standing escape hatch: the mimalloc template rebuild (walk-perf L2) if convoy
pressure reappears.

### 5.2 API thread-safety (what forces main-thread)

* `VoxelBlockyLibrary.bake()` — GPU geometry readback + concurrently-read by mesher workers:
  treated as NOT offloadable (J3). Any claim otherwise needs a native spike + a godot_voxel
  source read, not hope.
* RenderingServer from workers — Godot 4.4 nominally queues server calls from threads, but on
  the threaded web export + GL-compat this is exactly the territory of undocumented breakage;
  project law stays "GPU commits on main" (the far-ring comments already encode it).
* `SurfaceTool`/`Image`/packed arrays — safe off-thread under single-owner discipline (proven
  live by J2/J5/J6).
* Sampler lifetime: every worker job must hold a strong ref to its compiled generator
  (`_sampler_obj` pattern — a Callable does NOT keep it alive, `facet_skin_tier.gd:122-125`), and
  the freeze-gate must prevent `setup()`-epoch swaps while a job is in flight.

### 5.3 Scheduling

* 2 WorkerThreadPool slots now serve 4+ producers → a long manifest-construction job could
  starve a crossing-critical ring rebuild. The JobLane priority + preemption point (manifest jobs
  are chunked per-stage) addresses it; the gate for TH3 asserts ring-rebuild latency is unmoved.
* Results land ≥1 frame later than the synchronous path. For J1 that is invisible (coverage-alpha
  blend-in). For J2 crossings, `force_rebuild`'s synchronous path is retained for the frames
  where correctness demands same-frame geometry (it already joins the worker first,
  `facet_far_ring.gd:1371-1379`).

## 6. Staged, flag-gated plan (each default-off, byte-identical off, FLAT 6042/0)

| Stage | Flag | Content | Gate |
|---|---|---|---|
| TH0 | `FP_JOB_LANE` | JobLane + per-subsystem `main_commit_ms` telemetry; nothing routed | byte-off; G-TH0 lane unit test (dispatch/poll/priority) |
| **TH1** | `FP_TEX_BAKE_WORKER` | J1: base+close-up bake units, premultiply, mips → worker; main = `update_layer` only | G-TH1: scripted drive asserts (a) texel output byte-identical to the synchronous baker (pure sampler ⇒ exact), (b) main-thread per-update cost ≤ upload-only bound, (c) `FACET_TEX_BYTES_MAX` ledger unmoved |
| TH2 | `FP_RING_WARM_WORKER` | J2: boot warm + surface/floored warm + S2 prewarm route through the async dispatch; boot progressive re-emits use `_begin_rebuild` async | G-TH2: extends G-L1-FARRING-ASYNC (arrays bit-identical) + asserts no `_rebuild_full` sync call during a scripted boot/orbit drive + main-frame budget |
| TH3 | `FP_MANIFEST_WORKER` | J3: model construction on worker, per-model budgeted drain, single `bake()`; separately the godot_voxel readback patch | G-TH3: identical `_gen_arid`/`_snow_arid`/ARID tables; no frame > budget during cold bake; live A/B on boot timeline |
| TH4 | `FP_SNOW_WORKER` / lane reuse | J7 snowfall double-buffer + command queue; J8 skin/block-LOD jobs when re-enabled | G-WTHREAD-* pattern for snowfall determinism; edit-overlay deltas applied only via the overlay API |

Rollout per stage: headless gates green → FLAT 6042/0 byte-off → deploy flag-on → live A/B
watching **main-thread** worst-frame + the convoy signature (§5.1) → keep or revert by flag.
