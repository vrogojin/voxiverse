# COSMOS-GEN-CONVOY — Ground-walk generation convoy: mechanism + staged attack plan

**Status: DESIGN ONLY — no implementation in this document's branch.**
Branch context: `deploy/perf-plus-sky` worktree (`.claude/worktrees/deploy-cheats`).
Companion census: `docs/COSMOS-GEN-CONVOY-ALLOC-CENSUS.md` (per-site allocation counts, written in parallel —
this design cites its targets; where the census and this doc disagree on a count, the census wins).

This is layer **(B)** of the 2026-08-30 three-layer ground-jerkiness attribution
(`[[voxiverse-ground-walk-perf]]`): the near-terrain chunk-gen convoy that persists with villages OFF —
`worst_ms` spikes ~every 3 s while walking; at the spike frame `wf_vox_gen` = 1000–2186 queued generation
tasks, `wf_pool_active` = 6 (every voxel worker busy), `wf_t_stream_us` ≈ 22 000 (GDScript streaming
orchestration, `player.gd:922` segment timer), yet `worst_ms` ≈ 498 ms — **~430 ms of the worst frame is
unmetered by every named bucket**.

---

## 0. Executive summary

- **Mechanism (grounded §2):** walking crosses a 16-voxel data-block boundary every ~3–4 s; the sliding
  data/mesh boxes release a strip of new blocks per pooled terrain, and 6 workers + the main thread
  serialize on the **single global dlmalloc lock** of the threaded WASM heap. The browser main thread
  cannot `Atomics.wait`, so a contended acquisition on main **busy-spins**; the ~430 ms unmetered gap is
  the sum of main-thread allocation stalls across the frame — main is the *victim* of the worker storm on
  its **own** unrelated allocations. Spike telemetry localizes the storm to the **generation path**:
  `tasks.generation` high (mean 157 / max 2003) while `tasks.meshing` stays low (mean ≈2) — mesh tasks
  are data-dependency-gated during a strip fill, so few mesher allocations co-occur with the spike.
- **THE FORK — RESOLVED (§2.3): H1 holds.** The per-gen-task alloc count differed by ~2 orders of
  magnitude depending on which generator the served pck runs: H1 = C++ `VoxelGeneratorCosmos` (FP_CPPGEN)
  live, ~1 generator alloc/block; H2 = silent fallback to the GDScript generator
  (`module_world.gd:4162` — `setup()` refused ⇒ `push_warning` nobody sees ⇒ ~800 allocs/block, the
  `versions.env` "~500–2000 heap ops" storm). **Measured this session: `verify_cppgen.gd` headless on the
  toolchain editor = 58/0, 0/141 840 cells mismatched, `VoxelGeneratorCosmos` compiled in (8 symbols) and
  `setup()` ACCEPTS the live worldgen config ⇒ the C++ generator is LIVE; H2 is ruled out.** There is no
  no-rebuild escape: the storm is the **per-gen-task engine-side allocation cycle** (task object +
  `VoxelBuffer` object/`shared_ptr` + channel traffic where not pooled/uniform) × 1000–2186 tasks × 2–3
  live pool slots — NOT the generator body (~1 alloc) and NOT the mesher (few mesh tasks at the spike,
  `wf_vox_mesh`≈2). A permanent liveness gate (§7.3) keeps H2 ruled out forever.
- **Order of attack (§5), aligned with the allocator-feasibility verdict
  (`docs/COSMOS-GEN-CONVOY-ALLOCATOR-FEASIBILITY.md`: no stock `-sMALLOC` gives both low contention and
  bounded heap — the win must come from our code, by cutting lock TRAFFIC):** Stage 1 = the
  **per-gen-task small-object diet** (§4.B): `thread_local` the generator's `profs` vector, recycle the
  `VoxelBuffer` wrapper+`shared_ptr` control block and the `GenerateBlockTask` object (module-side
  freelists — or, if that lifecycle-threading is invasive, the generic core small-object front-end §4.C
  as Candidate B), plus a `VoxelMemoryPool` peak pre-warm so first crossings don't spill channel data to
  dlmalloc; ~75% of persistent worker lock traffic, heap ≤ +25 MB, multiplied by the 2–3 live pool-slot
  terrains that step boxes together (§1.2). Stage 2 = the mesher CoW-materialization collapse (§4.B′).
  The full-band allocator-lock partition (§4.C, budgeted ≤ +63 MB shared-slab / ≤ +96 MB sharded
  worst-case vs the +120 MB NEVER-OOM ceiling) is the **escalation** — an emmalloc arm rides the build
  matrix as a free falsification datapoint (predicted negative: single global spinlock, same one-lock
  shape) — worker-cap and the full interleaved handoff stage last.
- **Probe (§6):** per-thread-class allocation wall-time counters + a dequeue-loop timer (engine rebuild,
  byte-off) — the ONE instrumentation that converts "~430 ms unmetered" into measured lock-stall, and
  later proves (or falsifies) whichever lever ships. It rides the same S1 rebuild as the dormant levers,
  so the rebuild is paid once.
- **Not worth doing (§8):** mimalloc or any global allocator swap (measured +398–430 MB over ceiling,
  twice), more GDScript admission pacing (FP_INFLIGHT_GATE / FP_STREAM_TICK_ONCE / FP_FT_MOVE_HYST /
  FP_MOVE_PROBE_CACHE / FP_CTRL_ADAPTIVE are all ON live and the convoy persists), worker scratch arenas
  (already `thread_local` upstream), apply-slicing as a perf lever (apply already budgeted; kept only as
  a blind-spot timer).

---

## 1. The confirmed problem

### 1.1 Live signature (definitive, 2026-08-30 no-village arm)

| Signal | Value at spike | Meaning |
|---|---|---|
| `worst_ms` (1 Hz window-worst) | ~498 ms, ~every 3 s while walking | the hitch |
| `wf_vox_gen` | 1000–2186 (mean 157 / max 2003 across spikes) | generation tasks in flight/queued at the worst frame |
| `wf_vox_mesh` | LOW (mean ≈2) | meshing is data-dependency-gated during the strip fill — the storm is gen-side |
| `wf_pool_active` | 6 | ALL voxel workers busy (laptop hw≈8 ⇒ pool 6) |
| `wf_vox_main` | mean 1 / max 60, ≈0 on most spikes | main-thread task queue **empty** — budgeted apply exonerated |
| `wf_t_stream_us` | ~22 000 | GDScript `update_streaming` segment (`player.gd:922`) |
| named buckets total | ~70 ms | t_stream + phys + smooth_v2 + st_bms |
| **unmetered** | **~430 ms** | not in any bucket — the convoy |

Snapshot source: `godot/src/net/remote_bridge.gd:661-707` (`FP_WORST_FRAME_ATTR` — captured AT the frame a
new window maximum is recognized, `remote_bridge.gd:473-476`; `wf_vox_*` = `VoxelEngine.get_stats().tasks`,
`wf_pool_*` = `thread_pools.general`).

### 1.2 Why the cadence is ~3 s

The near `VoxelTerrain` streams by **sliding boxes stepped in 16-voxel data-block units**
(`docker/engine/cache/godot/modules/voxel/terrain/fixed_lod/voxel_terrain.cpp`, `process_viewers()` —
data box / mesh box diff per paired viewer). Walk speed ≈ 4–5 vox/s ⇒ one boundary crossing every
16 / 4.5 ≈ **3.6 s**. Each crossing releases a strip: view radius 128 vox (`terrain_config.gd:171`
`near_render_radius()`, faceted) ⇒ a ~17-block cross-section × vertical band, **multiplied by the FP_M1
neighbour-pool terrains**: up to 1 active + `POOL_MAX_NEIGHBOURS`=4 slots (`cube_sphere.gd:73`), tightened
to **~2–3 live slots steady-state** by `FP2_LIVE_CAP`=2 (`cube_sphere.gd:121`; 5 only transiently at a
facet crossing) — exactly ONE global player `VoxelViewer` serves them all (`module_world.gd:52,1881`) but
each pooled facet terrain pairs it separately, steps its own bounds-clamped data/mesh boxes, and owns its
own generator+mesher — and by mesh-block padding dependencies (mesh blocks are 32³, `module_world.gd:393`,
each needing its 16³ data neighbourhood). That ×2–3 slot multiplication is what turns a few-hundred-block
strip into the observed 1000–2186 `wf_vox_gen` — and it equally multiplies whatever per-block alloc diet
ships (§4.B). This cadence is **geometry, not a bug**
— the design goal is to make the burst *cheap*, not to eliminate the step (the admission layer already
shapes it as far as GDScript can, §3.4).

### 1.3 Prior art this design must honor

- dlmalloc convoy previously convicted: `[[voxiverse-walk-perf-root-cause]]` (phys_ms of unchanged code
  7.4→31 ms when workers busy; pool 6/6 active yet ~40 blocks/s drain pre-port), and in-repo at
  `docker/engine/versions.env` (WEB_MALLOC block: "~500–2000 heap ops per generated block … workers + main
  thread convoy on that lock … contended locks BUSY-WAIT on main"). Note the "~500–2000 heap ops" figure
  was written for the **GDScript** generator era — it is the H2 number, not the H1 number (§2.3).
- mimalloc **REJECTED twice on heap**: peak 842 MB vs dlmalloc 412 (+430 MB = 3.6× the +120 NEVER-OOM
  ceiling); the arena_reserve 128→16 MiB cap changed nothing (`[[voxiverse-mimalloc-arena-root]]`,
  `versions.env` mimalloc-FIT block). **Global allocator identity is settled: dlmalloc stays.**
- FP_CPPGEN (patch 0007) shipped byte-equal, 8–20× native — and its liveness, long "unprovable from
  telemetry" (`[[voxiverse-postport-applybound]]`), is now MEASURED live (§2.3: `verify_cppgen` 58/0 +
  symbol audit + absent GDScript-gen counters in the walk capture). The provenance stamp (§5 S0a) makes
  it permanently observable.
- Post-port bottleneck inversion → FP_INFLIGHT_GATE + AIMD controller landed and are **ON live** — and
  the walk spike persists.

---

## 2. Mechanism: where a walking gen-burst actually allocates

Life of one 16³ near block during a burst, with every heap touchpoint. "LOCK" = one global-dlmalloc-lock
acquisition on the WASM heap (`malloc`/`free`/`realloc` each take it once; Godot routes through
`Memory::alloc_static` → `malloc`, `core/os/memory.cpp:99-126`; module code routes `ZN_ALLOC/ZN_NEW` →
`memalloc/memnew` → same path, `modules/voxel/util/memory/memory.h:13-17`; GDScript Variants, Arrays and
Dictionaries route through the same `Memory` API).

### 2.1 Admission (main thread)

`VoxelTerrain::process_viewers()` diffs the boxes and emits load requests; task objects are created
(`ZN_NEW(GenerateBlockTask)` — 1 LOCK each) and enqueued (`VoxelEngine::push_async_task` →
`ThreadedTaskRunner::enqueue`, `engine/voxel_engine.cpp:263-269`). A 1000–2000-task strip ⇒ 1000–2000
small allocations **on main** in the step frame(s), plus queue growth (amortized).

### 2.2 Worker: generation under H1 (C++ generator live) — near-clean

`GenerateBlockTask::run` (`generators/generate_block_task.cpp:39-66`):
- `_voxels = make_shared_instance<VoxelBuffer>(ALLOCATOR_POOL)` — 1 LOCK (control block + object; the
  *channel data* goes through `VoxelMemoryPool`, §3.2, ~0 LOCK at steady state).
- `VoxelGeneratorCosmos::generate_block` (patch 0007, `generators/cosmos/voxel_generator_cosmos.cpp`):
  **~1 LOCK** — the per-column profile cache `std::vector<Vector4> profs; profs.resize(size.x*size.z)`
  (≈ line 2243). All tables are frozen `Parameters` built once in `setup()`; the emit loops are
  stack/scalar; `set_voxel` writes into the caller's pooled buffer.
- completion: push to `_completed_tasks` under the pool mutex (amortized); main later runs
  `apply_result()` (data-map insert ≈1–2 LOCK) + `ZN_DELETE(task)` + `shared_ptr` releases (≈2 LOCK, on
  main).

**H1 total: ≈5–8 LOCK per block** — modest on paper. Two engine facts sharpen where Stage 1 digs
(both verified in source): (a) the runtime **never flushes** `VoxelMemoryPool` — the only
`clear_unused_blocks()` caller is the editor vox importer (`editor/vox/vox_mesh_importer.cpp:318`) — so
channel recycling is a grow-only cache and should be near-100% hits once warm; (b) blocks that generate
fully-uniform (all air above the surface band, all stone deep) compress to a uniform channel = **zero
channel allocation**, so only the surface-band fraction of a strip carries channel traffic at all. If the
census confirms ≈5–8, the convoy's arithmetic is carried by lock *hold time* (dlmalloc bin scans / sbrk /
coalesce under KB-churn) × the 6-worker duty cycle × the 2–3-slot burst size — which is precisely what
the §6 probe measures before any lever is declared sufficient. (Census refinement: blocky uses exactly
ONE channel — TYPE, 8 KiB/block — pooled and self-warming, so channel-pool enlargement is NOT the fix;
the persistent traffic is the un-pooled small objects of §4.B.)

### 2.3 The generator fork — checked and RESOLVED (H1)

The risk investigated: `_make_generator` can **silently** hand the terrain the GDScript generator — if
`ClassDB.class_exists("VoxelGeneratorCosmos")` fails (stock-template build) or `cgen.setup(cfg)` refuses
(one missing/renamed config key suffices), `module_world.gd:4162` push-warns and returns null, a warning
nobody sees on the live rig. The GDScript path would cost ~800+ LOCK/block (fresh 9-element Array per
cell in `_quantized_targets`, `terrain_config.gd:1846-1852`; per-column memo Dictionary inserts,
`terrain_config.gd:877-878`; Variant churn) — the exact "~500–2000 heap ops per generated block"
`versions.env` storm.

**Resolution (this session): H2 ruled out.** `verify_cppgen.gd` run headless on the toolchain editor:
58 passed / 0 failed, 0/141 840 cells mismatched, `VoxelGeneratorCosmos` present (8 symbols), and
`setup()` **accepts** the live worldgen config. The served gen path is C++. Consequences: (a) the storm
must be explained by the **per-gen-task engine-side cycle** (§2.2's ≈5–8 LOCK/block — with the honest
caveat that this arithmetic alone looks thin, which is exactly what the §6 probe and the census's exact
per-task VoxelBuffer number must close); (b) the silent-downgrade *class* of bug remains real — §7.3
makes generator liveness a permanent asserted gate, the same failure class as the `_target_arg` silent
downgrade (`[[voxiverse-agent-autonomy-design]]`).

### 2.4 Worker: meshing — real but SECONDARY at the spike

`MeshBlockTask` → `VoxelMesherBlocky::build`: build scratch is `thread_local` and reused
(`meshers/blocky/voxel_mesher_blocky.cpp:663`, `voxel_mesher_blocky.h:152-161`) ⇒ ~0 LOCK; the **output
materialization** (`voxel_mesher_blocky.cpp:1176-1213`) allocates fresh CoW arrays per non-empty surface —
`Array mesh_arrays` + `PackedVector3Array positions/normals` + `PackedVector2Array uvs` +
`PackedColorArray colors` + `PackedInt32Array indices` (+tangents), each `copy_to` = one CowData backing
alloc + memcpy (`util/godot/core/packed_arrays.cpp:11-29`) ⇒ **~7–9 LOCK per surface**, escaping the
worker (freed later on main). Real traffic — but `wf_vox_mesh` ≈ 2 at the spikes says few mesh tasks run
*inside* the spike frames (mesh needs the full 3³ data neighbourhood, so meshing trails the gen strip).
The mesher levers therefore stage AFTER the gen-cycle diet (§4.B′ Stage 2, §4.H last).

### 2.5 Main thread: receive + upload (budgeted, but a lock-contender)

`VoxelEngine::process()` (`engine/voxel_engine.cpp:288-316`) dequeues completed tasks and runs
`apply_result()` inline (`:301-304`), then runs the time-spread queue under
`_main_thread_time_budget_usec` (`:308`; `project.godot:121` `threads/main/time_budget_ms=6`). On our web
target `is_threaded_graphics_resource_building_enabled()` is **false** (gl_compatibility hard-returns
false, `engine/voxel_engine.cpp:87-117`), so `ArrayMesh` building + `add_surface_from_arrays` (which
**re-copies** the worker arrays into RenderingServer buffers — the web double-copy) happens on main, but
time-budgeted, and the TimeSpread runner holds its mutex only around queue pops. **The apply is bounded
and is NOT the 430 ms** (`wf_vox_main`≈0 live). But every alloc/free it performs — plus main's unrelated
per-frame allocations (render server, GDScript, physics) — takes the same global dlmalloc lock the
workers are storming.

### 2.6 Why main loses ~430 ms

Emscripten's dlmalloc serializes on one lock; on the **browser main thread** a contended acquisition
cannot `Atomics.wait` and **busy-spins** (documented in-repo: `versions.env` WEB_MALLOC block; measured:
phys_ms of unchanged code 7.4→31 ms when workers are busy). During a burst the workers cycle the lock —
at H2 rates, tens of thousands of acquisitions/s — while main performs hundreds of its own alloc/frees
per frame; each can queue behind the storm. Sum over a frame ⇒ hundreds of ms attributed to **no**
GDScript bucket. Two observability holes the S0/§6 instrumentation closes:
- `wf_vox_main` counts the time-spread queue length, not lock waits; `vt_*` covers `VoxelTerrain::process`
  only — `VoxelEngine::process` (the dequeue+apply loop, `voxel_engine.cpp:301-304`) sits outside every
  existing timer.
- A secondary same-pool serializer: the periodic priority re-sort holds the tasks mutex while sorting
  ~2000 items (`util/tasks/threaded_task_runner.cpp:221-253`) — worker-side only, but it inflates worker
  wall-time during bursts and will show up in the probe as non-alloc time.

### 2.7 Same-pool co-tenants

The far-skin/tile bakes run on the same pool during walking (far tier re-arms on movement — layers
(A)/(C), separate designs). Patches 0011/0012 allocate per call: the hash-LUT
`std::vector<int64_t> keys / <int32_t> vals / <uint8_t> used` + `out.resize(tex*tex)` PackedByteArray
(patch 0011 hunks ~591–593, 664; same pattern in 0012), and `sample_columns()` rebuilds the same LUT per
call (`voxel_generator_cosmos.cpp:2429-2465`). Cheap, bounded, worth the `thread_local` diet (§4.G).

---

## 3. Already-mitigated surfaces (do NOT re-fix)

1. **Mesher scratch**: `thread_local` cache, cleared not freed (`voxel_mesher_blocky.cpp:663`,
   `voxel_mesher_blocky.h:152-161`); likewise `modifiers/voxel_modifier_stack.cpp:11-192`,
   `streams/voxel_block_serializer.cpp:29-221`, clipbox/update-task tls vectors. A new "worker scratch
   arena" would win ~nothing.
2. **Gen channel data**: `VoxelBuffer(ALLOCATOR_POOL)` → `VoxelMemoryPool` power-of-two freelists with
   per-size-class mutexes (`storage/voxel_buffer.cpp:14-38`, `storage/voxel_memory_pool.h:48-108`);
   `generate_block_task.cpp:48,151` and the whole load path already use it. At steady state channel
   alloc/free costs a short pool-mutex hold, not a dlmalloc hit. (This in-module pattern is the
   proof-of-concept for §4.C.) S0 must still verify the pool's live hit-rate — `get_stats()` exposes
   `memory_pools` counters (`[[voxiverse-nb-fullres-design]]`).
3. **Main-thread apply**: time-budgeted (`voxel_engine.cpp:308`, 6 ms — `project.godot:121`) and
   exonerated live (`wf_vox_main`≈0 at spikes). Do not build an apply-slicing lever; only add the §6
   timer for the untimed dequeue loop.
4. **GDScript admission/pacing — ALL ON LIVE and insufficient**: FP_INFLIGHT_GATE
   (`cube_sphere.gd:2751-2768`, F = gen + mesh + 2·main, close >192 / reopen <64, feed-forward pace cut),
   the AIMD `StreamLoadController` (0.25 s tick, p90-vs-18 ms budget, credit ∈[0,1], sustain-gated:
   `CTRL_OVERLOAD_SUSTAIN_S`=3.0 / `PROMOTE_SUSTAIN_S`=1.5 so no single window flips it; four throttle
   surfaces — apply budget ×max(credit,0.25), grant floor ≥1, `stream_pace`=0 while `backlog_gated`,
   promote at credit ≥0.5; `FP_CTRL_ADAPTIVE` setpoint clamp(floor_p10×2, 18, 45)), FP_STREAM_TICK_ONCE
   (`world_manager.gd:1403` — orchestration tail once per render frame), FP_FT_MOVE_HYST (far-tree re-arm
   2→12 blk), FP_MOVE_PROBE_CACHE, FP_CTRL_ADAPTIVE — all in the deployed flag set. The convoy fires
   **inside an admitted burst** faster than the 0.25 s sustain-gated controller can react; no admission
   policy can fix per-allocation contention. Every lever below must *cooperate* with
   the controller (strictly reduce per-block cost or contention; never add a second admission authority).

---

## 4. Interventions evaluated (census-ordered)

### 4.A — H2 remedies — MOOT (fork resolved to H1); retained as record + one optional hygiene flag

The planned H2 levers (repair a `setup()` refusal at `module_world.gd:4162`; a no-rebuild GDScript
alloc-diet) are **not the fix** — §2.3 proved the C++ generator live. What survives:
- the **liveness gate** (§7.3) — the silent-downgrade bug class is real even though it isn't firing;
- *(optional, low priority)* `FP_GEN_ALLOC_DIET` for the configurations that legitimately run the
  GDScript generator (FLAT mode, stock-template fallback): `_quantized_targets`'s fresh 9-element Array →
  9 local bools (`terrain_config.gd:1846-1852`), memo Dictionary pre-size (`:877-878`). Byte-off flag,
  zero heap, low risk — but it does not touch the live convoy; schedule it as opportunistic hygiene only.

### 4.B — LEAD (Stage 1): per-gen-task small-object diet + pool pre-warm

**What the persistent per-task convoy actually is (census-refined).** The channel data (blocky = exactly
ONE channel, TYPE, 8 KiB/block) is already pooled and **self-warming** — `VoxelMemoryPool` free-lists
grow to the high-water mark and the runtime never trims them (§2.2(a): sole `clear_unused_blocks()`
caller is the editor vox importer — confirmed no-bug), so channel-pool enlargement is NOT the fix. The
traffic that hits the global dlmalloc lock on **every** task, forever, is the un-pooled small objects:
  (a) the `VoxelBuffer` wrapper object + `shared_ptr` control block —
      `make_shared_instance<VoxelBuffer>(ALLOCATOR_POOL)` per task (`generate_block_task.cpp:48`),
      memnew'd fresh, freed on stream-out (~1–2 allocs/block);
  (b) the generator's `std::vector<Vector4> profs` resize (1 malloc + 1 free/block,
      `voxel_generator_cosmos.cpp:2243`);
  (c) the `GenerateBlockTask` object itself (`ZN_NEW`/`ZN_DELETE`, delete lands on main);
  (d) the escaping mesh surface arrays (§2.4 — secondary at the spike, `wf_vox_mesh`≈2).
All ×1000–2186 tasks ×2–3 live pool slots per burst.

**Sub-levers (one rebuild, one flag family):**
1. **`profs` → `thread_local`** cleared-not-freed (the module idiom,
   `streams/voxel_block_serializer.cpp:29-39`): kills (b). Trivial, no lifecycle risk.
2. **Small-object recycling for (a)+(c)** — two implementation candidates, pick the cheaper that stays
   byte-off and ≤ +120 MB:
   - *Candidate A (module-side, targeted):* per-type lock-striped freelists (the `VoxelMemoryPool`
     idiom) for the task objects and the buffer wrapper+control pair (`make_shared_instance` → pooled
     `allocate_shared`). Tasks have a single-owner protocol (`threaded_task_runner.h:60-66`) but the
     buffer wrapper's lifetime crosses into the data map and frees on stream-out — if threading that
     recycle hook through the map lifecycle turns invasive, prefer:
   - *Candidate B (core, generic):* the §4.C bucketed front-end with its band widened down to ~64 B —
     covers (a)–(d) **generically in one single-file patch** with a hard cache cap, no module lifecycle
     surgery at all. Given the churn is many small *heterogeneous* objects, B may be the cheaper honest
     lever despite touching core — the census's exact per-site counts make the call.
3. **`VoxelMemoryPool` peak pre-warm** (cheap, complementary, same build): pre-reserve the 8 KiB class to
   the expected peak in-flight block count (≈2500 × 8 KiB ≈ 20 MB, counted in the heap budget) so the
   FIRST crossing — or any burst exceeding the prior high-water mark — doesn't spill channel allocs to
   dlmalloc mid-spike. Config-gated, default off.

**Effect:** removes the persistent ~4–6 LOCK/block gen-cycle traffic (~75% of worker-side steady-state
acquisitions when combined with lever 1), multiplied by the 2–3 live slots; first-crossing spill removed.
**Heap:** ≤ +25 MB (pre-warm ~20 MB + capped freelists few MB) — trivially inside +120 MB; the recycling
itself reserves nothing. Rebuild: yes (module patch next-number in `docker/engine/patches/godot_voxel/`,
plus the core patch if Candidate B; runtime/config-gated, default byte-identical). Risk: LOW-MED
(Candidate A: localized but lifecycle-threading; Candidate B: §4.C's profile). Ship with the §6 probe in
the same rebuild; if the stall survives a measured traffic cut, the residual mechanism is lock *hold
time* / mesh-path CoW ⇒ §4.H mesher collapse, §4.C full-band, or §4.F cap.

### 4.B′ — Stage 2: collapse the worker-side CoW surface materializations (mesh path)

The ~7–9 LOCK/surface of §2.4, staged after 4.B because few mesh tasks co-occur with the spike. Two
alternates, impl picks per census: (a) *defer materialization* — the task hands surfaces as
pool-allocated `StdVector` payloads (VoxelMemoryPool-backed ⇒ no dlmalloc on the worker); the Packed
conversion happens inside the already-time-budgeted main-thread apply (`voxel_engine.cpp:308`, 6 ms —
paced, and near-uncontended once worker traffic drops); or (b) *single-buffer handoff* — the module's own
TODO (`voxel_mesher_blocky.cpp:1173-1174`), one byte-array per surface + low-level `mesh_add_surface`
(§4.H's format work, scoped to positions/uv/color/index).

### 4.C — Candidate B for Stage 1 / general escalation: bounded slab recycler in `Memory::alloc_static` (core patch)

**Dual role:** (i) as 4.B Candidate B with the band floored at ~64 B, it covers the heterogeneous
per-task small objects (a)–(d) generically in one single-file patch; (ii) at full band it is the general
escalation if the module-side diets leave a CoW-bound residual — it attacks contention for every in-band
allocation regardless of origin. Keep dlmalloc as the heap; in front of it, for sizes in a hot band
(default 1 KB–512 KB; floored to ~64 B in the Candidate-B role), a **size-bucketed recycling freelist**
in `core/os/memory.cpp` where all Godot allocations pass (`alloc_static:99` / `free_static:180` /
`realloc_static:128`; CowData backings, memnew objects, Variant payloads — CowData confirmed
`pad_align=false` callers, `core/templates/cowdata.h:297,313,424`).

**Why it partitions the lock:** steady-state in-band traffic becomes freelist recycling — workers pop,
main pushes back the escaped arrays' frees; per-bucket mutexes, ~tens-of-ns critical sections; worker
threads *can* futex-sleep. The global dlmalloc lock sees only misses and out-of-band traffic. This is the
mimalloc win-mechanism (repeat traffic off the global lock) without the mimalloc loss-mechanism
(per-thread reservation): one bounded shared cache, not per-thread segments.

**Mechanics (patch `docker/engine/patches/godot/0003-web-alloc-band-recycler.patch`):**
- Scons option per the `0002-web-malloc-option.patch` template: `alloc_recycler=no` default
  (upstream-safe, byte-identical); `build-engine.sh` passes it from a new `versions.env` knob
  `WEB_ALLOC_RECYCLER=0/1`. Compile for the Linux editor too so the headless gate (§7.2) can exercise it.
- Runtime master switch, default **off** (pass-through verbatim), flipped once at startup.
- **Slab-range discrimination, not header magic.** Release-build `free_static`/`realloc_static` for
  `pad_align=false` callers pass the raw pointer to `free`/`realloc` with no size info
  (`core/os/memory.cpp:128-204`), and probing a magic header at `ptr-16` on a foreign pointer is an
  out-of-bounds read with corruption-on-collision risk. Instead buckets are carved from **dedicated
  slabs** (2 MB, malloc'd lazily, one bucket class per slab, registered in an append-only range table):
  "is this ours" = a lock-free range check (few ns) that deterministically routes `free_static` and
  `realloc_static` (recycler-realloc fast path: new size fits the bucket ⇒ same pointer — *cheaper* than
  dlmalloc realloc for PackedArray growth; else malloc+copy+recycle). Pre-switch or out-of-band blocks are
  never in the table and fall through untouched. Slabs return to dlmalloc only via idle trim.

**Heap vs NEVER-OOM (+120 MB over dlmalloc baseline ~412 MB):** slab cap **48 MB hard** (24 × 2 MB —
a true total, unlike mimalloc's per-step `arena_reserve`); pow-2 rounding waste only on transient live
in-band blocks (est. ≤ +15 MB at burst peak); budget **≤ +63 MB**, gated live (§7.4); cap ladders
48→32→16 before rejection.

**Risk: MED-HIGH severity, well-gated** — sits on the engine's hottest path; a bug is arbitrary
corruption. Mitigations: compile-gated (stock binary available) AND runtime-gated (off ⇒ pass-through);
deterministic slab routing (no probabilistic magic); single-file patch; dedicated storm gate (§7.2).
Engine rebuild: **yes** (ships dormant inside the S1 probe rebuild to pay it once).

### 4.D — Module-local pooling of the surface PackedArrays — REJECTED (infeasible cleanly)

CowData allocates via `Memory::alloc_static` with no allocator hook and a `Packed*Array` cannot wrap
external memory; pooling from inside godot_voxel would force a parallel un-CoW'd handoff protocol through
`apply_mesh_update` and still end in PackedArrays at the RenderingServer boundary. Dominated by 4.C.

### 4.E — Per-worker split heaps (emmalloc/arena per thread) — REJECTED

The hot allocations *escape* their thread (alloc on worker, free on main) ⇒ per-thread heaps need
cross-thread free routing — that is mimalloc's architecture, which is heap-vetoed; a hand-rolled version
converges on the same reservation-per-thread memory shape. Non-escaping allocations are already
`thread_local` (§3.1).

### 4.F — Gen-worker parallelism cap during ground bursts (module patch) — CONDITIONAL

Contention scales with concurrently-allocating threads. Runtime atomic `max_parallel_tasks` honored in
the `ThreadedTaskRunner` pick loop (`util/tasks/threaded_task_runner.cpp:169-333` — a capped thread
re-waits instead of picking a parallel task; serial lane and pool size untouched ⇒ the web
<16-pthread-slot invariant of patches godot/0001 + voxel/0005 is preserved), exposed via a `VoxelEngine`
debug setter, driven from GDScript behind `FP_GEN_WORKER_CAP` (e.g. 6→3 while `on_ground && moving`).
~2× less lock pressure at ~2× burst duration — the right trade for `worst_ms`. Zero heap. Risks:
wake-up/starvation bugs; longer pop-in. Arm only if the probe shows residual worker-side lock dominance
after the Stage-1 diet. The static knobs (`threads/count/*` `project.godot:101-103`,
`WEB_PTHREAD_POOL`) are NOT the lever (§8.5).

### 4.G — Tile-bake LUT `thread_local` diet (module patch, trivial) — ride-along

Patches 0011/0012 + `sample_columns` rebuild hash-LUT vectors per call on the same pool (§2.7). Convert
to `thread_local` cleared-not-freed (the module's own idiom; `streams/voxel_block_serializer.cpp:29-39`
is the template), runtime-gated via a cosmos `setup(config)` key (patch-0007 style) forwarded from a
`FP_BAKE_LUT_TLS` const. Bounded ≤ ~2 MB × pool threads ≤ +20 MB worst-case (realistically ≪). Near-zero
risk; small win; rides whatever rebuild happens anyway.

### 4.H — Kill the web double-copy: interleaved surface handoff (module patch, large) — STAGE-LAST

Upstream's own TODO (`voxel_mesher_blocky.cpp:1173-1174`): emit pre-interleaved vertex/attribute/index
byte arrays and feed `RenderingServer::mesh_add_surface` directly in `apply_mesh_update`, replacing 5–6
typed arrays + main-thread `add_surface_from_arrays` conversion. Cuts worker mesh allocs ~7–9 → ~3–4 per
surface AND deletes main's format-conversion allocs+copies. Cost: reproducing the gl_compat vertex format
exactly (octahedral normals, color packing) — finicky, visual-regression-prone, live-GPU validation only.
Stage last: `wf_vox_mesh`≈2 says the mesher is not the spike driver (§2.4).

### 4.I — Apply-slicing / receive caps — REJECTED as a perf lever

`wf_vox_main`≈0 + the 6 ms budget (§3.3) exonerate the apply. Only the untimed inline dequeue loop
(`voxel_engine.cpp:301-304`) gets a timer (§6); if that timer *surprises* (dequeue ≥100 ms at spikes),
revisit with a count-budget on the dequeue. Instrument first; don't pre-build the lever.

### 4.J — More admission/burst shaping in GDScript — REJECTED

Already deployed to its limit (§3.4); the 16-voxel box step is engine geometry; the convoy is
per-allocation, not per-admission.

### ROI × risk ranking

| Lever | Convoy cut | Heap | Rebuild | Risk | Verdict |
|---|---|---|---|---|---|
| §6 probe (+ S0 stamp/pool-stats) | attribution (enables all) | ~0 | stamp no / probe yes | low | **S0/S1, same rebuild** |
| 4.B small-object diet + pre-warm | ~75% persistent gen-cycle traffic ×2–3 slots | ≤ +25 MB | yes | low-med | **LEAD (Stage 1)** |
| 4.C as Candidate B (64 B floor) | same coverage, generic, one file | ≤ +63 MB capped | yes | med-high, gated | Stage 1 alt if A invasive |
| 4.B′ mesher CoW collapse | ~7–9 LOCK/surface, mesh path | ~0 (goes down) | yes | med | Stage 2 |
| 4.C full-band recycler | ~all in-band steady-state | ≤ +63 MB capped | yes | med-high, gated | escalation |
| emmalloc arm (0002 knob) | predicted NEGATIVE (falsification datapoint) | −small | build-matrix ride | low | free datapoint |
| 4.F worker cap | ~2× pressure @ 2× duration | 0 | yes (small) | med | conditional |
| 4.G LUT tls | small, same-pool | ≤ +20 MB worst | rides | very low | do |
| 4.H full interleaved format | mesh-path count + main copies | ~0 | yes | med-high effort | last |
| 4.A H2 remedies | MOOT (fork resolved H1) | — | — | — | record + §7.3 gate only |
| 4.D / 4.E / 4.I / 4.J | — | — | — | — | rejected |

---

## 5. Staged plan (one lever per A/B)

Deploy mechanics: GDScript-side flags via the **sed-at-export pattern** — sed the `const FP_X := false`
declarations to `true` on `cube_sphere.gd` SOURCE, then `scripts/export-web.sh` + `scripts/deploy.sh
--no-build`, then
revert the source (consts bake into the .pck, so a flip requires re-export; source stays byte-off;
`COSMOS-FALL-CLITE-DESIGN.md` §flag-mechanics, `[[voxiverse-deploy-cheats-pipeline]]`). C++ runtime gates
via a module/cosmos config key forwarded from such a flag; build-knob arms via `versions.env` +
`scripts/build.sh` rebuild (mimalloc-A/B precedent). Metric protocol: `?frames=0`, interleaved arms
(host-throttle drift), fixed walk route away from villages, 1 Hz relay `worst_ms` spike train (~3 s
cadence) + `wf_*`. Baseline arm always = `FP_WORST_FRAME_ATTR` only.

- **S0 — no-rebuild guards (mostly DONE).** The generator fork is resolved (H1, §2.3 — `verify_cppgen`
  58/0 + symbol audit). Remaining: (a) the permanent `wf_gen_cpp` provenance stamp (`module_world`
  exposes the active generator class, folded into the `FP_WORST_FRAME_ATTR` snapshot — GDScript-only,
  deployable immediately) so a silent downgrade can never hide again; (b) read
  `get_stats().memory_pools` live during a walk to record the `VoxelMemoryPool` high-water/used baseline
  (`[[voxiverse-nb-fullres-design]]`).
- **S1 — the instrumented Stage-1 rebuild (ONE engine rebuild carrying everything dormant).** Contents:
  the §6 probe; 4.B lever 1 (`profs` thread_local); 4.B lever 2 (small-object recycle — Candidate A
  module freelists, or Candidate B = §4.C floored at 64 B if A's lifecycle-threading proves invasive at
  impl time; decision recorded in the census); 4.B lever 3 (`VoxelMemoryPool` peak pre-warm); dormant
  4.G LUT-tls. All default-off/byte-identical. A/B ladder on the walk route, one flag per arm:
  1. probe-only arm — expect `wf_alloc_main_ms` ≈ the unmetered ~430 at spikes (convoy metered at last);
     if instead `wf_dequeue_ms` dominates ⇒ reopen 4.I; if neither ⇒ stop, re-attribute, ship nothing;
  2. +4.B arm — gates: spike `worst_ms` ↓ ≥50%, `wf_alloc_workers_n` per spike ↓ ≥70%,
     `wf_alloc_main_ms` ↓ ≥70%, §7.4 heap ceiling holds;
  3. +`FP_BAKE_LUT_TLS` arm (hygiene, cleans same-pool noise).
  Also in the same build matrix, zero extra effort: an **emmalloc datapoint arm** via the existing
  `WEB_MALLOC` scons knob (patch godot/0002) — predicted NEGATIVE (emmalloc's single global spinlock
  busy-waits, same one-lock shape; smaller footprint though); its value is falsification + a free heap
  datapoint, not a candidate fix.
- **S2 — mesher CoW collapse (4.B′)** if the probe shows a mesh-path residual once gen-cycle traffic is
  dieted. Own rebuild+arm; live-GPU visual check (gl_compat).
- **S3 — escalation: full-band 4.C recycler** (`WEB_ALLOC_RECYCLER=1` / runtime switch) if a CoW-bound
  residual remains. Gates: spike `worst_ms` ↓ ≥50% AND `wf_alloc_main_ms` ↓ ≥70%; §7.4 heap gate through
  the warm de-orbit-fall + walk protocol; alloc counters must actually drop (a bucket-mutex convoy would
  show as no-drop ⇒ cap/band retune). Cap ladder 48→32→16 MB; reject if it can't fit — never trade heap
  for frame time past the ceiling.
- **S4 — conditional:** 4.F worker cap (if the probe still shows worker-side lock dominance), then 4.H
  full interleaved handoff (if the residual is mesh-path volume). Each gated on the probe's
  before/after.
- **Merge policy:** a lever graduates from arm → default-ON (CS_FLAGS set / `versions.env`) only after
  its A/B gate passes; source consts stay default-false per byte-off discipline.

---

## 6. The ONE engine instrumentation probe (ships in the S1 rebuild)

**What:** per-thread-class allocation wall-time inside `core/os/memory.cpp`
(`alloc_static`/`free_static`/`realloc_static`), compile-gated (same scons option family as 4.C),
runtime default-off:
- two atomic u64 ns accumulators + call counters {main, other}, classified by a cached main-thread-id
  check;
- surfaced through a patched godot_voxel `VoxelEngine::get_stats()` (weak-linked accessor so the module
  builds without the core patch), landing in the existing `FP_WORST_FRAME_ATTR` snapshot
  (`remote_bridge.gd:665-682`) as `wf_alloc_main_ms` / `wf_alloc_workers_ms` / `wf_alloc_main_n` /
  `wf_alloc_workers_n` — co-occurring with the worst frame like every `wf_*` key;
- plus a timer around the dequeue loop (`voxel_engine.cpp:301-304`) → `wf_dequeue_ms` (closes the §2.6
  observability hole).

**Why this one:** it splits the ~430 ms into (main alloc-stall) vs (inline-apply work) vs (neither) in a
single deploy, and it is the *same* counter that later proves/falsifies 4.B/4.C/4.F. Byte-off: off ⇒ one
branch per call; stock build via the scons option. Overhead when ON: two time-source reads per alloc —
uniform across A/B arms (both arms run the probe). **Needs the engine rebuild** — unavoidable (the stall
is inside the allocator path; no GDScript timer can see it) — which is why S1 carries every dormant C++
lever in the same rebuild.

---

## 7. Gates

1. **Byte-off identity:** all flags/knobs default-off ⇒ FLAT `verify_feature.gd` stays **6042/0**;
   `WEB_ALLOC_RECYCLER=0` build is byte-identical stock (option absent from the build line, 0002
   pattern); runtime switches off ⇒ pass-through wrappers only. The sed-at-export flow reverts source
   after export (flags live only in the transient .pck). Additionally for the optional 4.A hygiene diet:
   FLAT must stay 6042/0 with `FP_GEN_ALLOC_DIET` **ON** (it claims byte-equal output, so it must prove
   it).
2. **Recycler correctness (headless, Linux editor build with the option ON):** new
   `godot/src/tools/verify_alloc_recycler.gd` — enables the runtime switch via the debug setter, then:
   multi-threaded storm (WorkerThreadPool) of PackedArray create/fill/verify/free across the band
   boundaries (1 KB±, 512 KB±, pow2±1) asserting content integrity (fill-pattern hash), the real
   lifecycle (alloc on worker, free on main), realloc across the band boundary, and afterwards:
   `used_blocks == 0` (no leak), `cached_bytes ≤ cap` (bounded), full-trim → ~0 (no permanent hoard),
   plus the discrimination edge: blocks allocated BEFORE the switch flips and freed AFTER route to raw
   `free` via the slab-range miss.
3. **Generator-liveness gate (all branches):** a headless FACETED boot driver asserting the active
   near-terrain generator is `VoxelGeneratorCosmos` when the module is present — the permanent guard
   against the silent `module_world.gd:4162` downgrade — the fork is resolved (H1) and this gate keeps
   it resolved. Existing
   drivers stay green: `verify_feature.gd` 6042/0, `verify_worst_frame_attr.gd` (extended for new `wf_*`
   keys), `verify_fartier_walk` / `verify_structures` / `verify_far_trees` untouched.
4. **Heap ceiling (live):** peak `heap_mb` during the warm de-orbit-fall + walk protocol ≤ dlmalloc
   baseline (~412 MB) **+120 MB** with any C++ lever ON — the same protocol that convicted mimalloc
   (`[[voxiverse-mimalloc-fit-build]]`); plus the recycler's own `cached_bytes ≤ cap` telemetry.
5. **No cross-layer perturbation:** the (A) far-structures and (C) smooth_v2 signals
   (`wf_st_rb`/`wf_ftr_rb`/`wf_smooth_v2_commit_ms`) must stay flat across arms — this design must not
   move the sibling fixes' baselines.

---

## 8. Explicitly NOT worth doing (with the receipts)

1. **mimalloc / any global allocator swap** — measured-rejected twice: +398–430 MB over the NEVER-OOM
   ceiling; the arena_reserve "fit" cap measured-useless (`[[voxiverse-mimalloc-arena-root]]`,
   `versions.env`). Same class: emmalloc-mt (single-lock like dlmalloc), any per-thread-heap scheme
   (§4.E) — that memory shape is *why* mimalloc failed.
2. **More GDScript pacing/admission** — FP_INFLIGHT_GATE, AIMD controller, FP_STREAM_TICK_ONCE,
   FP_FT_MOVE_HYST, FP_MOVE_PROBE_CACHE, FP_CTRL_ADAPTIVE are ON live; the spike persists inside
   admitted bursts. A 0.25 s controller cannot govern a per-allocation phenomenon.
3. **Worker scratch arenas for mesher/generator** — already `thread_local`/pooled upstream (§3.1, §3.2);
   the C++ generator is ~1 alloc/block (§2.2). No scratch storm exists to fix.
4. **Apply-slicing / receive caps as a perf lever** — apply is budgeted and `wf_vox_main`≈0 at spikes
   (§3.3); only the S1 dequeue timer is warranted (§4.I).
5. **Cutting voxel pool size statically** (`threads/count/*`, `WEB_PTHREAD_POOL`) — permanently starves
   fill to fix a burst-time phenomenon, and the pthread-pool/hardware-clamp pair (godot/0001 +
   voxel/0005) encodes a <16-slot invariant that casual retuning breaks (pool exhaustion ⇒ meshing
   deadlock ⇒ blank world). The runtime cap (§4.F) is the correct shape if capping is needed.
6. **Resurrecting superseded framings** — the "2-worker web gen ceiling", "6 ms apply budget is the
   choke", "supply<demand so cut demand": all measured-dead (`[[voxiverse-walk-perf-root-cause]]`,
   `[[voxiverse-postport-applybound]]`).

---

## 9. Open questions (carried into S0/S1)

1. Candidate A vs Candidate B for the 4.B small-object recycle — decided at impl time by how invasive the
   `VoxelBuffer`-wrapper lifecycle-threading turns out (census records the call).
2. The exact per-gen-task alloc count and the mesh-surface-array count — census in flight
   (`COSMOS-GEN-CONVOY-ALLOC-CENSUS.md`); reconcile with §2 before S2+ ships.
3. The §6 probe's split of the ~430 ms — main alloc-stall vs `wf_dequeue_ms` vs neither; the only path
   back to 4.I, and the falsification exit if neither dominates.
4. In-band vs out-of-band split of main's stall — decides the 4.C band floor (64 B vs 1 KB) if the
   escalation arms.
5. Whether the priority-resort mutex hold (§2.6) surfaces once alloc noise is removed — cheap follow-up
   if yes (sort into a scratch outside the lock, swap under it).
6. `VoxelMemoryPool` live high-water baseline (S0b) — sizes the pre-warm target (4.B lever 3).
