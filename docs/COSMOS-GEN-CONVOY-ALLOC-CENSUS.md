# COSMOS-GEN-CONVOY — Per-block heap-allocation CENSUS (read-only)

**Status: CENSUS — code-grounded per-site allocation counts. No implementation.**
Branch: `deploy/perf-plus-sky` (`.claude/worktrees/deploy-cheats`).
Companion design: `docs/COSMOS-GEN-CONVOY-DESIGN.md` (cites this census; where the two disagree on a count,
**this census wins**). Peer feasibility: `docs/COSMOS-GEN-CONVOY-ALLOCATOR-FEASIBILITY.md`.

This counts every heap allocation in the life of ONE 16³ near block during a ground-walk gen-burst, with
`file:line` evidence, thread, whether it hits the global dlmalloc lock, and whether it fires on the WALK
path (vs de-orbit / skin-bake). "LOCK op" = one acquisition of dlmalloc's single global pthread_mutex on
the threaded WASM heap (`malloc`/`free`/`realloc` each take it once; `USE_SPIN_LOCKS=0`). Route for every
count below: `ZN_ALLOC`/`memnew`/`std::operator new` → `Memory::alloc_static` → the `-sMALLOC` allocator.

Two facts frame the whole census:
- **The live generator is the compiled C++ `VoxelGeneratorCosmos` (FP_CPPGEN), not the GDScript one.**
  Resolved statically (all four `setup()` refusal gates pass for this faceted-flat world) and confirmable
  at zero cost from existing telemetry — see §0. This makes the per-gen-task cost ~1 alloc/block, NOT the
  ~800/block the GDScript generator would cost; the H2 (fallback) column is included only for contrast.
- **The VoxelBuffer channel — the single biggest per-block byte count — is ALREADY POOLED** through
  `VoxelMemoryPool`, so it does NOT contribute to the steady-state lock traffic. Do not double-count it as
  a win for any new allocator front-end (§3.a).

---

## 0. Which generator is live (the fork that sets the per-task cost)

`module_world.gd:4101` runs `VoxelGeneratorCosmos` iff `FP_CPPGEN` (baked ON in the live deploy) AND
`ClassDB.class_exists("VoxelGeneratorCosmos")` AND `cgen.call("setup", cfg)` returns true; else
`push_warning` (`module_world.gd:4162`) and fall back to the GDScript generator.

**Verdict: C++ generator LIVE.** The cfg built at `module_world.gd:4110-4164` passes every `setup()`
refusal gate (`voxel_generator_cosmos.cpp` setup(), patch 0007) for FACETED=true / flat_world=true:

| setup() refusal gate | cfg source | result |
|---|---|---|
| any of 6 noises null | `TerrainConfig.noise_stack()` returns all 6 (`terrain_config.gd:495-502`) | PASS |
| `cube_arid.size()==0 \|\| block_ids.size()==0` | baked LRID table + `appearance_surface_materials()` (`module_world.gd:4140-4141`) | PASS¹ |
| `!flat_world` (CURVED branch un-ported) | `cfg["flat_world"]=true` | PASS |
| faceted atlas malformed / gen_facet OOB / `facet_r_blocks<=0` | `FacetAtlas.frozen_atlas()` (`facet_atlas.gd:200-205`), `R_BLOCKS=6371.0` (`facet_atlas.gd:13`) | PASS |

¹ The only realistic refusal is transient: cube_arid/block_ids empty before the cold library bake
finishes. Handled — `_heal_generators_post_cold_bake()` (`module_world.gd:1225-1247`) rebuilds the
generators once tables fill. Steady-state walk ⇒ tables baked ⇒ accepts.

**Zero-cost runtime confirmation (no rebuild):** the T1 gen-class telemetry `gen_ct_0..3`/`gen_ms_0..3`
(`remote_bridge.gd:846-872`) is incremented ONLY by the GDScript generator's `_gen_acc`. The C++ generator
binds setup/is_ready/get_setup_digest/sample_columns/_generate_block/column_profile/slope_run_of/
resolve_cell/bake_far_tile but **no `gen_stats`** (grep count 0 across all 12 patches), and
`gen_class_stats()` (`module_world.gd:2468`) skips any generator without `gen_stats`. Therefore:
**C++ live ⇒ `gen_ct_*` fields ABSENT from the relay; GDScript fallback ⇒ `gen_ct_*` present and nonzero
while walking.** Read the existing no-village capture to confirm empirically.

---

## 1. Life of one 16³ near block — per-site census (C++ gen live)

Counted as (alloc + free) LOCK ops. `M` = number of distinct materials with geometry in the block (one
mesh surface per material; near-surface blocks typically `M≈3-6`: e.g. grass, dirt, stone, water, wood,
leaves). Working scratch that is `thread_local`/pooled is called out as **reused** (0 lock ops/block).

### (a) VoxelBuffer allocation / clear — worker

| # | Site | Per block | Thread | Lock? | Pooled? | Notes |
|---|---|---|---|---|---|---|
| a1 | `generate_block_task.cpp:48` `make_shared_instance<VoxelBuffer>(ALLOCATOR_POOL)` | 2 alloc (+2 free) | worker | **YES** | no | object memnew + shared_ptr control block; fresh per task, freed on stream-out |
| a2 | `generate_block_task.cpp:49` `_voxels->create(16,16,16)` | 0 | worker | — | — | sets size + `clear()` → channels stay COMPRESSION_UNIFORM (no data alloc until first non-default write) |
| a3 | channel data: `voxel_buffer.cpp:779-790` `create_channel_noinit` → `:14-25` `allocate_channel_data` → `VoxelMemoryPool.allocate` (`voxel_memory_pool.cpp:99-153`) | 1 pooled | worker | **only on pool miss** | **YES** | blocky uses **only CHANNEL_TYPE**, DEPTH_16_BIT → 8192 B → pool class 13. Free-list hit ⇒ 0 malloc; miss ⇒ 1 malloc |
| a4 | second buffer `generate_block_task.cpp:151` `voxels_copy` | 0 on walk | worker | — | — | guarded by `stream->get_save_generator_output()` = **false** for regenerate-on-the-fly VOXIVERSE ⇒ never fires on walk |

Channels per block: **1** (TYPE). Not SDF/COLOR/INDICES/WEIGHTS (transvoxel/smooth-mesher channels).

### (b) The C++ generator itself — worker

| # | Site | Per block | Thread | Lock? | Pooled? | Notes |
|---|---|---|---|---|---|---|
| b1 | `voxel_generator_cosmos.cpp:2243-2244` `std::vector<Vector4> profs; profs.resize(size.x*size.z)` (=256) | 1 alloc (+1 free) | worker | **YES** | no | the ONE generator alloc/block; NOT `thread_local`, NOT pooled → top single-line diet target |
| b2 | per-cell `resolve_cell`/`column_profile`/`slope_run` | 0 | worker | — | — | pure value math (Vector4 inline); the pcache memo is absent in C++ (a pure-function cache, omitted) |

This is the whole of "gen is ~1 alloc/block". (H2 contrast: the GDScript generator would instead cost
**~800 allocs/block** — the 9-bool `f` Array per cell `terrain_config.gd:1846-1852` ≈ 512/block + the
per-column memo Dictionary churn `terrain_config.gd:877-878` ≈ 330/block + `profs=[]`/pcache. Not live.)

### (c) The mesher — VoxelMesherBlocky::build — worker

| # | Site | Per block | Thread | Lock? | Pooled? | Notes |
|---|---|---|---|---|---|---|
| c1 | `voxel_mesher_blocky.cpp:663-666` `get_tls_cache()` `thread_local Cache` (working `arrays_per_material`) | 0 (reused) | worker | — | — | Zylann's TLS scratch — grows to high-water, never per-block alloc |
| c2 | **materialization** `voxel_mesher_blocky.cpp:1176-1207`, per non-empty material: `Array mesh_arrays; resize(ARRAY_MAX)` + `copy_to` into `PackedVector3Array positions/normals`, `PackedVector2Array uvs`, `PackedColorArray colors`, `PackedInt32Array indices` (+ optional `PackedFloat32Array tangents`) | **~7 alloc × M** (+~7×M free) | alloc worker / **free main** | **YES** | no | **THE BULK.** CoW backings materialized on the worker, escape to main, freed after apply. `:1173` TODO: "single byte array + Mesh::add_surface" = the collapse lever |
| c3 | `voxel_mesher_blocky.cpp:1209` `output.surfaces.push_back(Surface())` | ~amortized | worker | rare | no | std::vector growth |

### (d) Main-thread mesh apply / upload — main

| # | Site | Per block | Thread | Lock? | Pooled? | Notes |
|---|---|---|---|---|---|---|
| d1 | `voxel_terrain.cpp:1869` `apply_mesh_update` → `:1908` `build_mesh(...)` | ArrayMesh + RID + upload | **main** | some | no | web has `is_threaded_graphics_resource_building` DISABLED ⇒ build_mesh runs on MAIN, under the per-frame time budget (`voxel_engine.cpp:308`). The c2 Packed backings are **freed here** (counted in c2) |
| d2 | the c2 surface arrays freed post-upload | (= c2 frees) | **main** | **YES** | no | why main busy-waits: main frees 7×M CoW backings/block through the same lock the workers hold |

### (e) Task objects — worker/main

| # | Site | Per block | Thread | Lock? | Notes |
|---|---|---|---|---|---|
| e1 | `GenerateBlockTask` (`voxel_generator.cpp:21`) | 1 alloc (+1 free) | worker | YES | scheduler churn |
| e2 | `MeshBlockTask` (`voxel_terrain.cpp:1816`) | 1 alloc (+1 free) | worker | YES | |
| e3 | `ApplyMeshUpdateTask` (`voxel_terrain.cpp:80`) | 1 alloc (+1 free) | main | YES | enqueue is `push_back` under a mutex, no per-task alloc inside the runner |

### (f) Worker tile/skin bake LUTs (0011/0012 `sample_columns`/`bake_far_tile`) — NOT on the walk path

Gated behind `FP_CPP_TILE_BAKE` / `FP_SKIN_TIER` / `FP_CPPGEN`-instantiated far-bake callers. The
per-call `std::vector<int64_t> keys/vals + uint8_t used` + `out.resize(tex*tex)` (patch 0011:591-593,664)
fire on the **far-tier skin/texture bake**, a SEPARATE system (already characterized under the far-tier
walk-churn work, `[[voxiverse-ground-walk-perf]]`), **not** the near-block gen-burst. Excluded from the
walk-path ranking; listed so it is not conflated with (a)-(e).

---

## 2. Ranked convoy contributors (per near block, C++ gen live)

Ranked by lock-op volume per block. Annotated with **which path** each concentrates on — decisive because
the live telemetry shows the spike is **generation-concentrated** (`tasks.generation` mean 157 / max 2003;
`tasks.meshing` mean ≈2): gen-path allocs land in the deep 1000–2186 queue at the spike frame, whereas
mesh-path allocs spread as the (short) mesh queue drains behind it.

| Rank | Contributor | Allocs/block | Path (spike weight) | Lock | Pooled | Cheapest lever |
|---|---|---|---|---|---|---|
| **1** | Mesher CoW surface materialization (c2) | **~7 × M** (~21–42) | mesh (spread) | yes | no | collapse to single-buffer / `Mesh::add_surface` per the `:1173` TODO, or move materialization to main |
| **2** | VoxelBuffer wrapper + ctrl block (a1) | 2 | **gen (concentrated)** | yes | no | recycle a per-worker VoxelBuffer object pool (channel data already pooled; only the wrapper churns) |
| **3** | Task objects (e1+e2+e3) | 3 | gen+mesh+apply | yes | no | pool/recycle the 3 task structs |
| **4** | `profs` std::vector (b1) | 1 (+1 free) | **gen (concentrated)** | yes | no | `thread_local` reuse — one-line module diet |
| **5** | Channel data (a3) | 1 **pooled** | gen | **only on cold/drained pool** | **YES** | already covered by `VoxelMemoryPool`; a one-time pre-warm to peak in-flight count kills the first-crossing spill (pre-warm CONFIRMED SAFE — §3(a)) |
| — | Tile/skin bake LUTs (f) | 0 on walk | far-tier (separate) | — | — | out of scope |

**Per-block total (C++ gen live):** `≈ 6 + 7M` allocs (a1 2 + b1 1 + e 3 = 6 gen/task-side, + ~7M mesh),
so `M≈4` ⇒ **~34 allocs + ~34 frees ≈ 68 lock ops/block**. Mesh CoW dominates by volume; the gen-side
~6/block dominates the *visible spike* because it is concentrated in the deep gen queue.

### Allocs/sec at a 6-worker burst (order-of-magnitude)

A crossing releases a strip (~17-block cross-section × vertical band) **× 2–3 live pool slots**
(`FP2_LIVE_CAP`) ⇒ the observed ~1000–2186 `wf_vox_gen`. Take ~1500 blocks/burst draining over ~1–2 s
across 6 workers: `1500 × ~68 lock ops ≈ 1.0×10⁵ lock ops/burst` → **~50–100 k lock acquisitions/second**
funneled through ONE mutex, 6 workers + main contending — the busy-wait storm. The gen-concentrated subset
(a1+b1+e1 ≈ 6 allocs+6 frees) alone is `1500 × 12 ≈ 1.8×10⁴` lock ops packed into the gen-queue drain.

**Every per-block number above is multiplied by the 2–3 live pool-slot terrains** (§1.2 of the design),
so any per-block diet's absolute saving is likewise multiplied.

---

## 3. Notes that change the picture

**(a) Do not double-count the channel pool.** `VoxelMemoryPool` (per-pow2 free-list + per-bucket mutex +
fall-through, `voxel_memory_pool.cpp`) already recycles the 8 KiB TYPE channel — the biggest per-block byte
count. `recycle()` pushes blocks back (`:155-183`); only `clear_unused_blocks()` frees them, so the pool
self-warms to the high-water mark and stays warm across crossings. Net-new win for any allocator front-end
= the CoW backings (c2) + wrapper/task objects (a1,e) + module `std::vector` (b1), NONE of which the pool
covers. They layer cleanly: the pool sits ABOVE `alloc_static`; channel frees hit `pool.recycle`, never a
new front-end. **Cheap complementary lever — CONFIRMED SAFE:** a one-time pre-reserve sized to peak in-flight blocks
removes the cold-pool channel spill. Verified nothing re-colds the channel between crossings:
`clear_unused_blocks()` has exactly ONE caller in the whole module — `editor/vox/vox_mesh_importer.cpp:318`
(the .vox importer, TOOLS/editor-only) — and zero callers on the runtime streaming path
(terrain/, engine/, storage/) or in `godot/src`. The only other freeing path, `clear()`, runs solely in the
pool dtor at module unregister. So a peak pre-warm holds for the whole session.

**(b) The mesher's working buffers are already `thread_local` (c1)** — the classic "worker scratch arena"
lever is a no-op here. Only the *materialization* (c2) allocates, because the arrays must escape the TLS
cache to reach the main thread.

**(c) Apply is not a lock via busy-wait of its own** — `build_mesh` on main is the c2/d2 **free** traffic
plus ArrayMesh/RID creation, under the frame budget; `wf_vox_main≈0` at spikes confirms the apply *queue*
is not backed up. Main's stall is being the victim that frees 7×M CoW backings/block through the workers'
lock.

**(d) Module `std::vector`/`std_allocator` → `ZN_ALLOC` → `memalloc` → `alloc_static`**, so both b1 and c2
route through the same core allocator a `Memory::alloc_static` front-end would intercept.

---

## 4. Cheapest probes for what is NOT code-derivable

Two numbers set the ranking's absolute scale and need runtime, not source:

1. **`M` (materials-with-geometry per near-surface block)** — sets the c2 multiplier (rank 1). Bound from
   source: ≤ distinct blocky surface materials a 16³ near-surface column stack can contain (grass/dirt/
   stone/sand/water/wood/leaves/snow ⇒ ~3–6). Cheapest runtime pin: a one-shot histogram of
   `output.surfaces.size()` (already computed at `voxel_mesher_blocky.cpp:1209`) — one log line, no rebuild
   of the perf path if added to a debug build; or read it from `vox_std` surface telemetry if surfaced.
2. **blocks-per-crossing × burst duration** — sets allocs/sec. Derivable within a factor of ~2 from the
   existing `wf_vox_gen` depth + drain rate in the 1 Hz relay; no new code.

The **definitive** split of the ~430 ms unmetered frame into lock-wait vs real work is the design's S0
probe: per-thread-class allocation wall-time counters in `alloc_static`/`free_static` (engine rebuild,
byte-off). That is the ONE instrumentation that both proves the convoy mechanism and later scores whichever
lever ships — but note it is NOT needed to act on ranks 1–4, which are code-certain.
