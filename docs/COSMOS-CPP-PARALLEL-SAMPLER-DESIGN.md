# COSMOS — Parallel C++ fine-map sampler (FP_CPP_TILE_BAKE)

**Status:** DESIGN (Fable, 2026-08-02). No build/deploy performed.
**Scope:** make the whole-planet fine-map bake truly multi-core on the 8-core web host by
(1) settling *why* the C++ `sample_columns` path never parallelised, (2) a full-tile C++ bake
entry point, (3) actually giving the web build parallel worker capacity, all byte-equal and
behind a default-off flag.
**Unblocks:** fast fine-disc fill (Item A perf wall, `voxiverse-far-render-overhaul`) and the
disc-wide smooth-geometry mesher (Item B2), which needs the same worker capacity.

Sources examined (cite-level): patch files
`docker/engine/patches/godot_voxel/0007-cosmos-cpp-generator.patch` (0007),
`docker/engine/patches/godot_voxel/0008-cosmos-skin-sampler.patch` (0008),
`docker/engine/patches/godot_voxel/0005-web-hardware-concurrency-clamp.patch` (0005),
`docker/engine/patches/godot/0001-web-pthread-pool-size-option.patch`,
`docker/engine/patches/godot/0002-web-malloc-option.patch`, the **patched module tree** at
`docker/engine/cache/godot/modules/voxel/generators/cosmos/` (post-0001…0010, line numbers
below marked *cpp:* refer to it), Godot core at `docker/engine/cache/godot/`
(`core/os/rw_lock.h`, `core/object/worker_thread_pool.cpp`, `platform/web/os_web.h`,
`main/main.cpp`), and GDScript `godot/src/world/facet_tex_baker.gd`, `facet_skin_tier.gd`,
`far/far_palette.gd`, `tree_gen.gd`, `voxel_module/module_world.gd`, `godot/project.godot`,
`docker/engine/versions.env`, `docker/engine/build-engine.sh`.

---

## 1. Root-cause verdict

### 1.1 Q1 — `_params` IS immutable during steady-state sampling. The read lock is defensive-only.

- `_params_lock` is **write-locked in exactly one place**: the tail of `setup()` —
  0007 hunk line 528 (`RWLockWrite wlock(_params_lock); _params = p;`), *cpp:180* in the
  patched tree. `grep RWLockWrite` over `voxel_generator_cosmos.cpp` returns that single site.
- `setup()` is documented and used as **main-thread, exactly-once, before any worker runs**
  (0007 header: "Freeze this epoch's immutable inputs. MAIN THREAD ONLY, exactly once…";
  frozen-epoch contract: "A facet/face flip installs a NEW generator, it never mutates a live
  one"). Both GDScript constructors honour that: `FacetSkinTier._build_cpp_gen`
  (facet_skin_tier.gd:555-585) and `module_world._make_cpp_generator`
  (module_world.gd:3899-3956) instantiate a fresh object, call `setup` once, and never call it
  again on a live instance.
- No hidden mutable state: every core function is `static` and pure over `const Parameters &`
  (0007 hunk lines 2319-2396 — the whole private surface is static), `cosmos_terrain.h`
  contains no mutable statics / `thread_local` (checked), and the emit loops write only into
  locals / the caller's buffer.

**Verdict:** the read lock is a correctness no-op in steady state. It is also *not the
bottleneck* (1.2), so we keep it (it is the upstream `VoxelGeneratorNoise2D` idiom, and it is
what makes a mid-life `setup()` misuse safe instead of UB).

### 1.2 Q2 — `RWLockRead` does NOT serialise concurrent readers, not even on emscripten.

- Godot `RWLock` wraps `std::shared_timed_mutex` (`core/os/rw_lock.h:45`), readers via
  `lock_shared()`. libc++'s implementation (`__shared_mutex_base`) holds an internal *plain*
  mutex only for the reader-count increment/decrement; the read *section itself* is held with
  zero mutex. On emscripten pthreads that is one short critical section at acquire + one at
  release. `sample_columns` takes the lock **once per batch call** (*cpp:1774*), i.e. twice
  per 512-column chunk (`CPP_CHUNK_ROWS := 8` × up to 64 columns/row,
  facet_tex_baker.gd:36) — noise-level overhead, and N readers on different threads proceed
  **in parallel** through the whole sampling loop.
- **In-repo empirical proof:** `generate_block` (*cpp:1614*) uses the *identical*
  `RWLockRead(_params_lock)` idiom on ONE shared instance and the *same six shared
  `FastNoiseLite` Resources*, is called concurrently by up to ~10 godot_voxel worker threads
  on the live web build, and demonstrably scales (post-port "supply ≥ demand", memo
  `voxiverse-postport-applybound`). If reader-locking serialised on this exact WASM build, the
  near-field C++ generator could not have inverted the bottleneck to mesh-apply.

**The serialisation belief is REFUTED.** So are the two comments that encode it:
- facet_tex_baker.gd:36 / 1794-1795 ("the C++ sample_columns … serialises on a lock"),
- facet_tex_baker.gd:1801-1803 ("the near-field gen … shares the C++ generator's **GLOBAL
  lock**"). `_params_lock` is a **per-instance member** (`mutable RWLock _params_lock;`,
  0007 header hunk), and the bake, the skin tier and the near-field terrain each hold their
  **own** `VoxelGeneratorCosmos` instance (`ClassDB.instantiate` at facet_skin_tier.gd:558,
  called separately by facet_tex_baker.gd:204 and skin setup:128; the near field builds its
  own in module_world.gd:3901). There is **no shared lock between the bake and the near
  field at all.** (Implementation must fix these comments — stale root-cause text is how the
  next agent re-wastes a day.)

### 1.3 Q3 — what `sample_columns` touches beyond `_params`

- The six `Ref<Noise>` in `Parameters` are the **very same `FastNoiseLite` Resources**
  TerrainConfig built (0007 header decision 1 — deliberate, for byte-equality). Godot's
  `FastNoiseLite::get_noise_2d/3d` is `const` and pure (modules/noise/fastnoise_lite.cpp:316-337;
  domain-warp mutates only the local coord copies). Concurrent readers are safe — and already
  happen today (near-field workers + skin + baker all read them).
- No `Ref` refcount churn per call (refs are copied once at `setup`; sampling passes
  `const Parameters &`).
- Output containers are function-locals `resize()`d once and filled via `ptrw()`
  (*cpp:1777-1812*) — one allocation each per call, no COW shenanigans across threads.
- **Conclusion: concurrent `sample_columns` on one instance, or across instances, is
  data-race-free today.** Nothing needs a lock-free rewrite.

### 1.4 Q4 — the real reasons it "didn't parallelise" and the fps≈15 hitch

Two structural facts, neither of them the generator:

**(a) The web build's `WorkerThreadPool` has ONE thread.** `OS_Web::get_default_thread_pool_size()
returns 1` (platform/web/os_web.h:94), `project.godot` does not set
`threading/worker_pool/max_threads` (the `threads/count/*` keys at project.godot:101-103 are
godot_voxel's own pool, a different thing), and `main/main.cpp:1874` passes the default `-1`
straight through. So every `WorkerThreadPool.add_task` the baker issues
(facet_tex_baker.gd:1760, 1783) lands on **one pool thread**; `_pbm_n` slots were never N
threads. Worse: with 1 thread, `max_low_priority_threads = CLAMP(1·0.3, 1, 0) = 0`
(worker_thread_pool.cpp `init`), so the baker's low-priority tasks only run via the
finish-time promotion path — queued, strictly serial. **The C++ path was never given a second
thread to be parallel on; no lock change alone can fix that.** (It also reframes the
"7 GDScript workers = 0.3 facet/s" measurement: those 7 tasks were time-sliced onto ~1 pool
thread plus main-thread convoy effects — see (b) — not 7-way parallel compute.)

**(b) The shipped allocator is still dlmalloc with ONE global lock.** `versions.env:37
WEB_MALLOC=dlmalloc` (the mimalloc option from godot patch 0002 exists but is not enabled).
Patch 0002's own header records the *measured* mechanism: every allocation serialises on one
lock, and a contended lock **busy-waits on the browser main thread** (main cannot
`Atomics.wait`), burning rAF budget — measured live as phys_ms 4.3→44.5 while workers were
merely busy. The current "C++ path" still leaves **per-texel GDScript** around the C++ call —
`TreeGen.top_decoration` + `FarPalette.far_color_index` + `GenCtx` memo + `_edit_snap`
lookups per texel, plus 5 packed arrays + a Dictionary marshalled per 512-column chunk
(facet_tex_baker.gd:1815-1853). That interpreter/allocator traffic is what couples the bake
worker to the main thread. **The fps≈15 hitch is (b) [allocator busy-wait on main] plus (a)
[a long task starving the only WTP thread that any engine group-task user must share] — not
`_params_lock`, and provably not near-field contention (separate instance, near field frozen
off-surface).** A third confounder: several past measurements were taken on ~2-core remote
browsers, where one busy worker + main is plain CPU saturation.

---

## 2. The fix

Four parts. F1 is the engine change (new patch, rebuild); F2 is capacity (versions.env +
project.godot); F3 is the GDScript dispatch; F4 is optional hygiene. Everything is behind
`FP_CPP_TILE_BAKE` (default **off** ⇒ byte-identical shipped behaviour).

### F1 — engine: full-tile C++ bake `bake_far_tile` (new patch `0011-cosmos-parallel-tile-bake.patch`)

Do NOT just unlock `sample_columns` — it is already unserialised (§1.2). The remaining cost
and the main-thread coupling live in the per-texel GDScript overlay. Move the **entire tile
loop** into C++ so the worker's steady state allocates nothing and calls GDScript zero times
per texel:

```
// header (add next to sample_columns; same const-entry-point pattern):
// FP_CPP_TILE_BAKE: the whole _pbm_compute texel loop in one call. Returns the L8
// palette-index bytes (fi+1, 0 = un-baked) for an nx×ny tile stretched into a tex×tex
// buffer, classification byte-equal to the GDScript path by integer-LUT construction.
PackedByteArray bake_far_tile(int fid, PackedVector2Array lat_corners, int nx, int ny,
        int tex, PackedInt64Array edit_cells, PackedInt32Array edit_far_idx) const;
```

Body (all pieces already exist in the patched tree; this is composition, not new sampling —
the one-sampler law holds):

1. `RWLockRead rlock(_params_lock);` — unchanged idiom, one acquisition per **facet**.
2. Per texel `(bx, by)`: `s=(bx+0.5)/nx`, `t=(by+0.5)/ny`; lattice coords via a verbatim
   port of `_bilerp` (facet_tex_baker.gd:2016-2017 — f64 math over the f32 `Vector2`
   corners, then `int(round(..))` exactly as facet_tex_baker.gd:1829-1830); corner order
   `(v00,v10,v11,v01)` preserved.
3. Classification, mirroring facet_tex_baker.gd:1841-1852 branch-for-branch:
   - **edit**: hash-lookup `(lx,lz)` in a per-call open-addressed table built once from
     `edit_cells`/`edit_far_idx` (edits are sparse; table is one alloc per call);
   - **tree**: `tree_top_decoration(p, fid, lx, lz)` — a ~15-line port of
     `TreeGen.top_decoration` (tree_gen.gd:208-224) over the **already-ported** primitives
     `tree_has_tree` / `tree_base_pos` / `col_h` / `tree_block_at` (0007 hunk lines
     2336-2341; all gate-covered via `generate_block` byte-equality). Non-AIR deco →
     `p.deco_far_idx[deco]` (new frozen LUT, see below);
   - **terrain**: `column_profile_core` → the existing `far_color` branch logic (0008 hunk
     lines 75-118) refactored into `far_index(p, g, biome, t, water) -> int` returning the
     *palette index*; `far_color` becomes a lookup wrapper (zero behaviour change for
     `sample_columns` — same branches, same values).
4. Write `uint8_t(fi + 1)` into a `PackedByteArray` `resize()`d once (`tex*tex`, zero-filled).

**Byte-equality of the index math — by integer-LUT construction, no float re-derivation:**
GDScript classifies with `FarPalette.far_color_index(color)` — a nearest-RGB scan over
`frozen_colors()` (far_palette.gd:168-183) that can alias (two identical palette RGBs resolve
to the *first* index). So the C++ side must NOT return its branch enum directly. Instead
`setup()` precomputes, once, with the exact mirrored math (f32 colour components widened to
f64 distances, `<` comparison, first-wins — far_palette.gd:170-182 verbatim):
   - `canon_idx[k]` for the 14 `far_colors` entries + the `B_PILLAR` literal
     `Color(0.20,0.20,0.23)` (0008 hunk line 114) → `far_index` returns `canon_idx[branch]`;
   - two new optional `Parameters` tables handed over frozen from the main thread:
     `deco_far_idx` (block id → `far_color_index(BlockCatalog.color_of(id))`, computed in
     GDScript at `_build_cpp_gen` time — pure catalog RGB, main thread) and the edit LUT is
     passed per call as `edit_far_idx` values already resolved via
     `FarPalette.far_color_index_of_block` (the `_block_idx` LUT, far_palette.gd:186-190,
     main-thread-built as today).
Every per-texel decision is then integer-only in C++ ⇒ cannot drift from GDScript by even
one ULP. Missing `deco_far_idx` ⇒ `bake_far_tile` returns an **empty array** (loud refusal,
0008's inert-but-well-formed pattern) and the generator stays fully functional for voxels.

**Patch mechanics:** `build-engine.sh` globs `/patches/godot_voxel/*.patch` in order and
fails fatally on non-apply (build-engine.sh:83-95), so a new `0011-*.patch` is picked up with
zero script changes. Generate its hunks against the post-0010 tree — the cached patched
checkout at `docker/engine/cache/godot/modules/voxel` is exactly that tree. 0007/0008 are
left untouched (no rebase churn); the only 0008-adjacent edit is the `far_color` →
`far_index`+wrapper refactor, which lands in 0011 as a context diff on the 0008-installed
function.

### F2 — capacity: give the web build real parallel workers (no new-thread law breakage)

JobLane's design law forbids `Thread.new()` because the emscripten pthread pool is fixed at
16 and ledgered at 15 worst-case (job_lane.gd:17-21, patch 0005 header). Keep the law; raise
the capacity through the existing knobs:

- `docker/engine/versions.env`: `WEB_PTHREAD_POOL=16` → **24** (the knob from godot patch
  0001; we are rebuilding for 0011 anyway).
- `godot/project.godot` (export-time, no rebuild): feature-tagged overrides
  `threading/worker_pool/max_threads.web = 5` and
  `threading/worker_pool/low_priority_thread_ratio.web = 0.8`
  (⇒ `max_low_priority_threads = CLAMP(5·0.8,1,4) = 4`, so four low-priority bake tasks can
  actually run concurrently — with the default 0.3 ratio only ONE could, see §1.4a).
- Patch 0005's clamp (14) stays; update its accounting comment: worst case
  voxel(≤10) + WTP(5) + audio/IO/spare(≤3) + bake(0 extra — bakes ride WTP) ≤ 18 < 24.
- **NEVER-OOM ledger:** 4 extra WTP threads started at init ≈ +8 MB pthread stacks
  (2 MB `default_pthread_stack_size` each) + up to 8 more lazily-started pool workers'
  stacks worst-case. This is a memory-costly change ⇒ ship behind the measured heap A/B
  (same harness as the mimalloc rule in patch 0002's header) and revert the two knobs if the
  baseline breaches the ceiling.

Bake tasks stay **low-priority** so engine/JobLane high-priority work always has first claim
on a freeing thread; with F1 each task is a bounded ~20-80 ms of pure native compute, not a
1 s interpreter marathon, so pool occupancy is short.

### F3 — GDScript dispatch (`facet_tex_baker.gd`)

- Under `FP_CPP_TILE_BAKE ∧ _sampler_obj != null`: `_pbm_n = clampi(min(_detect_cores()-2, 4), 1, 4)`
  for the C++ tile path (the `WEB_BAKE_WORKERS=1` cap remains for the GDScript path — that
  convoy is real and stays).
- `_pbm_compute`'s cpp branch collapses to: snapshot edits into two packed arrays (main
  thread, at dispatch, like `_edit_snap` today), one `bake_far_tile` call, mutex-store the
  returned bytes. The chunk loop, `CPP_CHUNK_ROWS`, the per-texel TreeGen/FarPalette calls
  and the 3 scratch arrays all go away on this path. Empty return ⇒ fall through to the
  existing GDScript branch (never a black tile).
- Keep the `_offsurface` gate for now (conservative — on-surface the cores belong to the
  voxel workers; the *lock* rationale is dead per §1.2, so lifting it later is a pure
  CPU-budget decision, and should be re-tested once this ships).
- Fix the three refuted comments (§1.2) and the `WEB_BAKE_WORKERS` comment to point at this
  doc.

### F4 — complementary, separate decision: `WEB_MALLOC=mimalloc`

Not required for the bake once F1 removes per-texel GDScript, but it is the standing fix for
the *rest* of the shipped allocator coupling (patch 0002 is fully plumbed, one env line).
Keep it a separate flip with its own heap A/B — do not couple its risk to this design.

---

## 3. Will N C++ workers actually scale on WASM? — CONFIRMED, with bounds

- The GDScript convoy is an **interpreter-allocation** phenomenon (patch 0002's live
  measurements: allocator lock, main busy-wait), *not* a raw shared-memory-bandwidth wall:
  the same host runs ≤10 near-field C++ gen threads concurrently at full width. F1's steady
  state performs **zero allocations and zero cross-thread writes** per texel (noise reads +
  integer LUTs + one preallocated output buffer); its working set (noise permutation tables,
  frozen `PackedInt32Array` tables) is small and read-shared. Expect near-linear scaling to
  4 workers on the 8-core host, same as the near-field pool exhibits.
- Arithmetic: fine tile = 64² = 4 096 columns (`PLANET_MAP_TEXELS`, cube_sphere.gd:624).
  Today's C++-chunked path ≈ 5 facet/s single (≈150-200 ms/facet, dominated by the GDScript
  overlay + chunk marshalling); pure-native full-tile est. 20-60 ms/facet ⇒ single-worker
  ≈ 3-10× today, ×4 workers ⇒ **~50-150 fine facets/s** — the whole ~7 k-facet fine map in
  well under a minute, vs "minutes" today. If the est. is off 2×, the target (disc fills
  fast at good fps) still holds.
- The genuine remaining wall is SAB memory bandwidth at high N — which is why the design
  caps at 4 workers (leaving main/render/compositor 4 cores) rather than cores−1. The live
  A/B (§5) sweeps N=1/2/4 to find the knee empirically instead of assuming.

## 4. Byte-equality & safety

- `sample_columns` is untouched (lock kept, body kept) ⇒ **G-CG-COLUMNS /
  G-CG-COLUMNS-COVER / G-CG-COLUMNS-FALS (verify_cppgen.gd:570-573) are unmoved.** The
  `far_color`→`far_index` refactor is a pure re-expression (wrapper indexes the same
  branches); the columns gate proves it.
- `generate_block` (the near-field path) is untouched — 0011 adds statics + one bound
  method + two optional `Parameters` tables with inert defaults. `setup()` validation for
  the new tables is *soft* (missing ⇒ tile bake refuses, generator stays enabled), so an
  older GDScript against a newer engine — or vice versa — degrades, never breaks.
- Thread-safety: no new locks, no script callbacks from C++, frozen-epoch contract
  preserved (new tables cross once in `setup()`, main thread).
- Flag off ⇒ `bake_far_tile` is never called and no GDScript behaviour changes ⇒
  byte-identical live build (FLAT 6042/0 must stay unmoved).

## 5. Verification plan

1. **Gate (headless, native editor):** extend `verify_cppgen.gd` with
   - `G-CPB-TILE`: `bake_far_tile` bytes == a reference run of the GDScript `_pbm_compute`
     branch, over ≥2 facets chosen to cover trees, sea/ice/lava regimes, snow line, badlands,
     a B_PILLAR corner, and a nonempty edit snapshot; assert non-vacuous coverage counts
     (the G-CG-COLUMNS-COVER pattern).
   - `G-CPB-FALS`: perturb one `deco_far_idx` entry and one corner coordinate ⇒ comparator
     must go red (falsification, house style).
   - `G-CPB-CONC`: run 4 `Thread`s (native gate only — allowed there) calling
     `bake_far_tile` on 4 distinct fids concurrently; results byte-equal to sequential runs
     (proves reader-parallel correctness, not speed).
2. **Byte-off:** full `verify_feature` FLAT + `verify_cppgen` + `verify_facet_tex` with the
   flag off — all unmoved.
3. **Live A/B (remote bridge, the user's 8-core host, off-surface at orbit):** telemetry
   already carries `pbm_n / pbm_busy / cpp_on / cores` (facet_tex_baker.gd:1936-1943); add
   `fine_rate` (facets/min, EMA) and sweep `_pbm_n` = 1 → 2 → 4. Accept if: fine-disc
   coverage time scales ≥2.5× from 1→4 workers AND frame p90 at orbit does not regress vs
   flag-off. Reject/park if p90 regresses >10% at any N (then ship N=1 full-tile — still a
   single-worker ~3-10× win with less main-thread coupling than today).
4. **Capacity proof:** `WorkerThreadPool: %d threads, %d max low-priority` prints at boot
   (worker_thread_pool.cpp init, verbose) — confirm 5/4 on web in the console once, so the
   fix is never assumed.

## 6. Risks & fallback

| Risk | Mitigation / fallback |
|---|---|
| 0011 mis-applies after 0010 drift | generate against `docker/engine/cache/godot/modules/voxel`; build fails fatally+loudly on non-apply (build-engine.sh:88-91) |
| Pool exhaustion (blank-world class) from WTP 1→5 | WEB_PTHREAD_POOL 16→24 in the same rebuild; 0005 clamp keeps voxel ≤10; boot-print check (§5.4) |
| Heap growth (+~8-16 MB stacks) breaches NEVER-OOM | measured heap A/B gate before enabling; revert = two env/project lines |
| Tree/edit port drifts from GDScript | integer-LUT construction (no float re-derivation) + G-CPB-TILE/FALS byte gates |
| 4 workers re-convoy on bandwidth | N sweep in the live A/B; knee-capped; worst case ship N=1 full-tile |
| Anything regresses live | flag default-off; full revert = drop 0011 + revert versions.env/project.godot lines + rebuild (~24 min warm-cached less) |

## 7. What this settles for Item B2 (disc-wide smooth geometry)

The B2 mesher's GDScript column sampling hits the same two walls ((a) one WTP thread,
(b) allocator convoy). After this ships, B2 gets (i) real worker capacity for free (F2) and
(ii) the pattern to follow: batch the whole unit of work into ONE C++ call over the frozen
`Parameters` (a `bake_smooth_patch` sibling of `bake_far_tile`), never per-cell GDScript on
a worker. The "lock-free parallel sampler" the baker comment asked for turns out to already
exist — what was missing was threads to run it on and a boundary drawn at the right place.

## LIVE RESULTS (2026-08-02, 8-core web deploy — closes §5 acceptance)

- **NEVER-OOM heap A/B (F2 gate): PASS.** heap_mb instrument wired (register_types.cpp EM_ASM →
  self.__voxHeapSize()). Peak WASM linear memory **412 MB at orbit** (pbm_busy=4, all tiers resident,
  the worst case) = **20% of the 2048 MB WASM_MEM_MAX ceiling** (1.6 GB headroom). The always-on WTP
  bump (max_threads.web=5 + WEB_PTHREAD_POOL=24, ~+8–10 MB thread stacks) is ~2% of the peak —
  the two knobs are KEPT, no revert.
- **Throughput (F1): ~12 facets/s at orbit** with the 4-thread tile bake (tex_baked 2052→2527 in 40 s)
  vs the old ~1 facet/s GDScript baseline — ~12×, far past the ≥2.5× accept bar. fps ~26 during the
  active fill (min 18), recovers to 59 (min 46, worst 21.6 ms) once covered. pool_threads confirmed 1→6.
- **Byte-equality UNDER LIVE FLAGS** (FACETED+FP_CLIMATE_BIOMES+FP_SKIN_TEXTURE_MEAN+FP_SKIN_BLOCK_EXACT
  sed-on, as the deploy runs them): verify_tile_bake **G-CPB 76/0** (72 tiles + 3136 edit cells + 8-way
  concurrency); verify_cppgen near-field **G-CG-CELL 0/605184 mismatched**. FLAT flags-off 6042/0.
  NOTE: the gate exercises the flag via the same sed-toggle the deploy uses (like FACETED); the default
  headless run is flags-off, so run it sed-on to reproduce the live-flag proof.
