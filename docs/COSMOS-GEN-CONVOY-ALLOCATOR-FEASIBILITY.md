# COSMOS GEN-CONVOY — allocator feasibility verdict

**Question this doc answers (and ONLY this):** is there a **bounded-heap** (≤ +120 MB peak over
the ~412 MB dlmalloc baseline, the hard NEVER-OOM ceiling) way to **partition / relieve the WASM
allocator lock** for the voxel worker transient allocations, so the gen-burst convoy goes away
without the mimalloc heap blow-up?

Scope: emsdk **3.1.64**, wasm32 + `-pthread`, the pinned toolchain. Build knob already plumbed by
`docker/engine/patches/godot/0002-web-malloc-option.patch` (`malloc ∈ dlmalloc|mimalloc|emmalloc`,
scons option, default dlmalloc). All findings below are grounded in the actual allocator sources
inside the toolchain image `voxiverse/godot-build:4.4` (`/emsdk/upstream/emscripten/system/lib/…`)
and Godot 4.4.1 core, not from memory.

> This doc is feasibility only. The mechanism/rollout design lives in
> `COSMOS-GEN-CONVOY-DESIGN.md` (peer-owned) — not touched here.

---

## TL;DR ranked verdict

| Rank | Option | Low-contention? | Bounded ≤ +120 MB? | Change surface | Build cost |
|---|---|---|---|---|---|
| **1** | **Module transient-alloc diet** (thread_local reuse + object recycle + collapse the 6-7 PackedArray materializations) — attacks lock **traffic**, not the lock | **Yes** (~75 % fewer lock acquisitions/block) | **Yes — heap DROPS** (fewer live transients; no new reserve) | **godot_voxel only**, no core patch, no build knob | 1× 24-min relink |
| 2 | **Sharded small-object free-list front-end** over `Memory::alloc_static` (new core patch), HARD per-thread cap | **Yes** (true lock partition, incl. PackedArray backing) | **Yes if cap ≤ ~4 MB/thread** (24×4 = +96 MB worst case) | **Godot core patch** (0003) + sizing risk | 1× 24-min relink |
| 3 | **emmalloc** (`WEB_MALLOC=emmalloc`, existing knob) | **NO — single global spinlock, busy-wait** (source-confirmed; predicted *worse* than dlmalloc on workers) | Yes (smaller, sbrk, can trim) | build knob only | 1× 24-min relink |
| ✗ | **mimalloc** (any arena cap / decommit) | Yes | **NO — source-confirmed decommit/reset are no-ops on wasm** → never returns memory; measured 842 MB peak | build knob | already rejected |

**Cheapest thing to A/B-build first:** **Option 1** (module-only diet). It is on the critical
path regardless, is bounded *by construction* (it removes allocations, it does not reserve
anything), carries **zero** OOM risk, and needs no core patch. Pair it in the **same** 24-min build
matrix with an **emmalloc arm** (one scons flag, free) purely to bank a heap-footprint datapoint and
falsify the "a lighter single-lock allocator is enough" hypothesis — but expect the emmalloc arm to
lose on frame time (see §3).

---

## The lock landscape (source-grounded)

All three Emscripten allocators are **single-global-lock** under `-pthread`. None is per-thread. The
only per-thread-heap allocator Emscripten ships is **mimalloc**, and that is exactly the one that
blows the heap. This is the crux: **on this toolchain, "low contention" and "bounded heap" are not
both available from any stock `-sMALLOC` choice.**

- **dlmalloc (current)** — `dlmalloc.c:31-33`: under `__EMSCRIPTEN_PTHREADS__`, `USE_LOCKS=1` and
  **`USE_SPIN_LOCKS=0` → a single global `pthread_mutex_t`** guards every `malloc`/`free`. On the
  browser main thread a contended emscripten pthread mutex cannot `Atomics.wait`, so it **busy-waits
  on main**, burning the rAF budget — this is the measured convoy (`COSMOS-WALK-PERF-DESIGN.md`).
- **emmalloc** — `emmalloc.c:124-128`: under `__EMSCRIPTEN_SHARED_MEMORY__` it uses
  **`MALLOC_ACQUIRE()` = `while (__sync_lock_test_and_set(&multithreadingLock,1)) {…spin…}`** — a
  single global **spinlock**, i.e. *also* one lock for the whole heap, and a pure busy-spin with no
  OS wait on *any* thread. See §3.
- **mimalloc** — per-thread heaps (no shared lock on the fast path) — the textbook fix, but see §4.

So attacking the **lock** via the build knob can only pick a *different* single lock (emmalloc) or
the unbounded per-thread-heap allocator (mimalloc). The bounded win has to come from **our own
code**: either allocate less through the shared lock (Option 1) or install our own bounded
per-thread front-end (Option 2).

---

## What actually hits the lock per meshed 16³ block (recap from the census)

Per block, per worker, through the one global lock (`ZN_ALLOC`/`memnew`/std `operator new` all route
to `Memory::alloc_static` → `malloc()` → the `-sMALLOC` allocator):

1. `std::vector<Vector4> profs` in the C++ generator — `voxel_generator_cosmos.cpp:2243` (1 alloc +
   1 free). **Not pooled, not thread_local.**
2. `make_shared_instance<VoxelBuffer>` — object + shared_ptr control block, 2 allocs
   (`generate_block_task.cpp:48`).
3. Task objects `ZN_NEW(GenerateBlockTask/MeshBlockTask)` — 1 each.
4. VoxelBuffer **channel data** — already pooled through `VoxelMemoryPool` (per-power-of-two
   free-list, `storage/voxel_memory_pool.cpp`); pool-hit = no `malloc`, pool-miss = 1 `malloc`.
5. **6-7 CoW `Packed*Array` surface arrays** materialized on the worker —
   `voxel_mesher_blocky.cpp:1184-1205` (`positions/uvs/normals/colors/indices/tangents`), each a
   fresh `CowData` backing allocation. **This is the bulk of the lock traffic.**

The mesher's *working* buffers (`StdVector<Arrays>`) are already `thread_local`
(`voxel_mesher_blocky.cpp:664`) and only grow — they are not the problem. The problem is the
per-surface **materialization** into Godot CoW types at the worker→main hand-off.

---

## §1 — Option 1: module transient-alloc diet (RANK 1)

Cut the **count** of lock acquisitions per block instead of partitioning the lock. Same contention
relief mechanism as partitioning (fewer threads × fewer allocs colliding on the mutex), and it is
**bounded by construction because it reserves nothing** — peak heap can only go *down*.

Concretely, all `godot_voxel`-only:
- **(a)** `profs` → `static thread_local std::vector<Vector4>` reused across calls
  (`voxel_generator_cosmos.cpp:2243`). Removes 1 alloc + 1 free per block per worker; zero heap
  (one buffer/thread, grows once).
- **(b)** Recycle the `VoxelBuffer` **object** and the `GenerateBlockTask`/`MeshBlockTask` objects
  via a small bounded `thread_local` free-list (a few in flight per worker). These are fixed-size
  objects — ideal slab targets. Removes ~4 allocs/block.
- **(c)** The big one: **stop materializing 6-7 `Packed*Array` per surface on the worker.** The
  mesher already has the vertex data in `thread_local StdVector<Vector3f>` etc. Options: (i) defer
  the CoW conversion to the main thread inside `apply_mesh_update` (where allocation is already
  serialized under the time-budget, so it adds no *new* contention — it moves it off the workers);
  or (ii) pack into a single interleaved byte buffer + `RenderingServer::mesh_add_surface` (the TODO
  already noted at `voxel_mesher_blocky.cpp:1173`) — one alloc instead of seven.

**Heap accounting:** strictly ≤ baseline. Reusing transients and recycling objects *reduces* live
allocation; nothing is reserved. Trivially passes ≤ +120 MB (expected roughly −5…−20 MB).
**Contention:** cuts per-block lock acquisitions from ~8 to ~2 (≈ 75 %), and — via (c) — pulls the
heaviest allocations off the worker threads entirely. That is the convoy mechanism defused.
**Ceiling on the win:** it cannot make PackedArray backing *free*; if the residual convoy is still
dominated by CoW backing that (c-i) merely relocates to main, escalate to Option 2. But (c-ii) does
remove them.
**Cost:** no core patch, no new build knob, no OOM exposure. One 24-min relink to A/B.

## §2 — Option 2: sharded small-object free-list front-end (RANK 2)

The only way to **truly lock-partition the PackedArray backing** (which we do *not* control — see the
obstacle below) is to intercept the allocator underneath Godot. A **thread-sharded small-object
front-end** installed at `Memory::alloc_static`/`free_static` (Godot core, new patch 0003):

- Each thread keeps `thread_local` segregated free-lists for the hot small size-classes (the block
  channel size, the CoW backing sizes). Alloc/free of those sizes hit the thread-local list with **no
  shared lock**; everything else and any overflow **falls through to dlmalloc**.
- **Bounded by a HARD per-thread cap** (unlike mimalloc's per-growth-step reserve): once a thread's
  cache holds `CAP` bytes, further frees go back to dlmalloc. Heap ceiling = `Σ threads CAP`,
  fixed and known at build time.

**Why this is the real answer to the literal "partition the lock" question:** it is the only bounded
design that also captures the `Packed*Array` CoW backing, because it sits *below* Godot's allocator.

**The obstacle it clears (and why Option 1(c) exists as the cheaper alternative):** the 6-7 surface
arrays are Godot CoW types; their backing is allocated by `CowData` via
`Memory::alloc_static` (`core/templates/cowdata.h:313,368,424`) → `malloc()`
(`core/os/memory.h:113`). You **cannot** redirect an individual `PackedVector3Array`'s backing to a
module-side pool without patching `CowData`/`Memory` core — the type hard-codes `Memory::alloc_static`.
A front-end at `alloc_static` is the non-invasive-per-callsite way to pool them, but it *is* a core
patch.

**Heap accounting:** worst case = all threads' caches full simultaneously = `WEB_PTHREAD_POOL(24) ×
CAP`. `CAP = 4 MB → +96 MB` (≤ +120, passes with margin). `CAP = 2 MB → +48 MB`. In practice only the
~6-10 hot voxel threads fill their cache; WTP/audio/IO threads stay near-empty, so live peak is well
under worst case — but it **must be sized for worst case** to be safe. Feasible ≤ +120 MB with
`CAP ≤ ~4 MB`; halve it by pairing with the worker-ratio knob (fewer hot threads).
**Contention:** true per-thread fast path for the hot sizes → convoy eliminated for exactly the
allocations that cause it, dlmalloc mutex only for the cold tail.
**Cost:** Godot **core** patch (0003), plus real tuning risk (size-class choice, cap sizing, the
free-on-overflow path). Higher risk than Option 1; do it only if Option 1's residual proves the CoW
backing on the worker is still the limiter and (c-ii) is insufficient.

## §3 — Option 1-of-the-knob: emmalloc (RANK 3 — predicted negative)

`-sMALLOC=emmalloc` is a **one-flag** build via the existing 0002 knob, so it is nearly free to add
to a build matrix. But the source is decisive: emmalloc is **single-global-locked with a busy
spinlock** in shared-memory builds (`emmalloc.c:124-128`, `MALLOC_ACQUIRE` = test-and-set spin).
That is *not* lock partitioning — it is the same one-lock-for-the-whole-heap shape as dlmalloc, and a
spinlock is typically **worse** under a multi-worker alloc-storm than dlmalloc's `pthread_mutex_t`,
because every contender **busy-burns** instead of yielding. Predicted result: **no convoy relief,
likely a frame-time regression on the workers.**

Its one virtue is **heap footprint**: emmalloc is the minimal-footprint allocator (tight sbrk
regions, and it *can* trim/return top-of-heap memory — `emmalloc.c:1163-1236`), so peak heap should
be **≤ dlmalloc**, comfortably bounded. Net: run it only to bank a heap datapoint and to *falsify*
the "lighter single-lock allocator helps" idea — not as the fix.

## §4 — mimalloc, capped or otherwise (REJECTED — source-confirmed unbounded on wasm)

Already measured-rejected (peak 842 MB vs dlmalloc 412 = +430 MB = 3.6× the ceiling;
`versions.env` WEB_MIMALLOC_ARENA_RESERVE_KIB block, memory `voxiverse-mimalloc-arena-root`). The
source confirms *why it is fundamentally unbounded here* and cannot be rescued by a cap or purge:

`/emsdk/upstream/emscripten/system/lib/mimalloc/src/prim/emscripten/prim.c`:
- `_mi_prim_decommit()` → **`return 0` no-op** (`needs_recommit=false`),
- `_mi_prim_reset()` → **no-op**,
- `_mi_prim_commit()` → **no-op**.

So on wasm **reserve == committed linear-heap growth, and nothing is ever given back**. `arena_reserve`
is a per-growth-**step size**, not a total cap (capping it 128→16 MiB only trims rounding slack —
measured identical 842 vs 834 MB peak). Purge/decommit/reset knobs are all inert. Per-thread working
set across the worker pool at flood demand (~+420 MB) is intrinsic. `MIMALLOC_RESERVE_HUGE_OS_PAGES`
maps to `_mi_prim_alloc_huge_os_pages` → **`ENOSYS`** (also inert). **No mimalloc configuration hits
+120 MB on this toolchain. Dead end. Do not ship.**

---

## Recommended build order

1. **Build A/B matrix #1 (one 24-min cycle):**
   - **Arm B (primary): Option 1 module diet** — start with (a)+(b)+(c-i) [defer CoW to main] as the
     lowest-risk cut; keep (c-ii) [single-buffer `mesh_add_surface`] staged as the follow-up if the
     residual convoy is still CoW-bound.
   - **Arm E (free rider): `WEB_MALLOC=emmalloc`** — no code, banks a heap datapoint, falsifies the
     single-lock-allocator hypothesis.
   - Measure: worst-frame ms during a walk gen-burst **and** peak `heap_mb` during a warm de-orbit
     flood (the NEVER-OOM gate), both arms vs the dlmalloc baseline.
2. **Only if** Arm B's residual proves worker-side CoW backing is still the limiter *and* (c-ii)
   isn't enough → escalate to **Option 2** (core patch 0003, `CAP ≤ 4 MB/thread`), its own build.

**Do not** spend the rebuild on any mimalloc arm — it is source-confirmed unbounded on wasm.
