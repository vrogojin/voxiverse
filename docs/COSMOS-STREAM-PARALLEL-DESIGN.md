# COSMOS — Streaming Priority + Parallel-Thread Design (fresh-reload fix, all-neighbour near blocks, worker model)

**Status: DESIGN (research only — nothing here is implemented).** Task #102.
Author: Fable (perf architect). Tree: `deploy/cheats-eyeball` @ G3 merge.

Three coupled goals, one lever (honest parallelism on ~2-4 real web cores):

1. **Fix the slow fresh reload** — ~2-3 min at 4-28 fps before the world is usable.
2. **Full-res near blocks on ALL neighbouring facets** — no far-tier see-through at facet seams.
3. **Keep the nearest-first view priority queue** and feed 1+2 through it using the
   WorkerThreadPool **without** re-triggering the WASM dlmalloc convoy (SETTLED root cause of
   walk-perf: workers + main contend on the shared allocator; memory `voxiverse-walk-perf-root-cause`).

Everything below is flag-gated, byte-off, NEVER-OOM-ledgered, per repo law.

---

## 1. Root cause of the slow fresh reload

### 1.1 What is on the main thread during a fresh load

Every physics tick the player drives `WorldManager.update_streaming` (`player/player.gd:803`).
During the load window that one call carries, **all on the main thread**:

| Contender | Where | Bound? |
|---|---|---|
| godot_voxel mesh **apply/upload** | engine, `threads/main/time_budget_ms=6` (`godot/project.godot:114`) | yes, 6 ms |
| FacetTexBaker colour-skin bake (coarse/base/band slicing + fine-map `update_layer` upload of a 2.36 MB page every 15 frames) | `world_manager.gd:1221` → `facet_tex_baker.gd` | budget 5 ms **checked BEFORE each unit** (`cube_sphere.gd:1775`) — a unit can overrun it |
| **GlobalReliefData.step — the G2 DEM bake** | `world_manager.gd:1239-1249` → `global_relief_data.gd:247-257` | **gated, NOT bounded** (see 1.2) |
| far-ring re-emit catch-up per baked DEM facet | `world_manager.gd:1249` → `facet_far_ring.gd:1269` `_drain_relief_dirty` (rate-limited ≥ `CULL_REBUILD_MS`) | batched, still main-thread mesh re-emits |
| ShaderPrewarm / splash machinery | `main.gd` boot path | one-off |

### 1.2 Answers to the investigation questions

**Is `GlobalReliefData.step` frame-budget-bounded?** No — it is frame-budget **gated**, which is a
different thing. The only guard is `if frame_ms >= CubeSphere.BG_FRAME_BUDGET_MS: return -1`
(`global_relief_data.gd:252`, budget 22 ms, `cube_sphere.gd:1175`), where `frame_ms` is the
**previous** inter-call wall delta (`world_manager.gd:1240-1244`). Once admitted, the work unit
itself has no budget and is unbounded:

* `_next_unbaked` (`global_relief_data.gd:219-240`): a full **O(3456)** GDScript scan per admitted
  step while the view cone has unbaked facets — each iteration calls `_centre_dir(fid)`
  (`global_relief_data.gd:209-214`), which fetches `FacetAtlas.facet_corner_dirs` (allocates a
  `PackedFloat64Array`) and normalizes. Nothing is cached. On web GDScript (measured ×25 vs native,
  memory `voxiverse-gen-class-costs`) this alone is estimated **10-30 ms per admitted step** — and
  it also churns 3456 small allocations into the shared WASM allocator per call, feeding the
  dlmalloc convoy against the voxel gen workers.
* `bake_facet` (`global_relief_data.gd:177-205`): one `bake_smooth_tile` C++ call — "~ms/facet"
  native (class doc §5 comment, line 39), so **~5-25 ms on web**.
* Under `FP_SKIN_RELIEF_SHADE`: a 1089-node GDScript hillshade loop + 1089 `encode_s16` writes
  (`global_relief_data.gd:197-202`) — a few more ms on web.

So an **admitted step frame costs ~20-60 ms**. The 22 ms gate then produces a textbook duty-cycle
oscillation: bake frame (slow) → next step sees frame_ms ≥ 22 → skip → frame recovers → step sees
headroom → bake again. Every recovering frame gets re-spiked. That sawtooth **is** the observed
4-28 fps signature, and it lasts until all 3456 facets bake: at ~1 facet per 2 frames at a degraded
~15-25 fps, the full planet takes **~4-8 minutes**; the view cone (the facets that make the visible
far shell stop churning re-emits) completes in **~2-3 minutes** — matching the live measurement.

Two aggravations:

* **First-call loophole:** `_g2_last_frame_usec == 0` on the first streaming tick ⇒ `frame_ms = 0.0`
  ⇒ the gate always admits a bake on the single busiest frame of the boot.
* **The G3 on-surface suspend does NOT cover the DEM.** `FacetOrbitRelief.step()` suspends
  recompute/dispatch/commit while `!shell_offsurface()` (`facet_orbit_relief.gd:619-646` — "this
  alone was the dominant ground-level stall, proc_ms ≈240 live"), but `GlobalReliefData.step` has
  **no on-surface / settle condition at all** — it bakes the whole planet on the ground, during the
  near-field load, exactly as the symptom states.

**Is it main-thread or worker?** Entirely **main-thread by design** — the class doc explicitly opted
out of WorkerThreadPool ("fast enough to run synchronously on main", `global_relief_data.gd:39-41`).
That assumption is native-calibrated; on web it is wrong by an order of magnitude.

**Does it need to run at all during the near-field load?** Almost not. Its only **on-surface**
consumer is the far ring's G1a shade multiply in the vertex-colour bake
(`facet_far_ring.gd:3133-3139`), which self-degrades to `shade = 1.0` for unbaked facets and is
caught up later by `relief_baked` → re-emit. The other consumer, the G3 relief mesh
(`facet_orbit_relief.gd`), is off-surface-only. So during the load window the DEM buys **zero
player-visible value** for its 20-60 ms/frame price, plus re-emit churn as facets land.

### 1.3 The broader fresh-load convoy

The C++ worldgen port inverted the bottleneck: gen is fast, the **main-thread apply/upload stage is
the choke** (memory `voxiverse-postport-applybound`; `FP_INFLIGHT_GATE` machinery in
`stream_load_controller.gd:229-237`, `module_world.gd:581-604`). During a fresh load the main
thread's ~16 ms frame must fit: engine apply 6 ms + tex bake 5 ms (overrunnable) + DEM 20-60 ms
(admitted every other frame) + prewarm + game logic. The DEM is the only unbounded, deferrable
item — it is the root cause; the rest is the (already budgeted) baseline.

**Verification before attributing the win:** confirm the live pck actually bakes
`FP_GLOBAL_RELIEF_DATA`/`FP_SKIN_RELIEF_SHADE` on (repo consts are `false`,
`cube_sphere.gd:732-733`; live deploys sed-flip flags — use the established pck flag-dump technique,
memory `voxiverse-atmo-sky-design`), and land the boot-window telemetry of §6 Phase A before/after.

---

## 2. The priority-ordered load pipeline

One global order, admitted top-down; a lower band never runs while a higher band is
admission-starved. Bands P0-P2 flow through the **existing voxel viewer priority queue** (all
terrains share the ONE player viewer; godot_voxel priorities are distance-to-viewer, so
nearest-first ordering is preserved **by construction** — hard constraint honored). Bands P3-P5 flow
through **JobLane** (`world/job_lane.gd`), which is already priority-drained
(`job_lane.gd:22-25,106-111`).

| Band | Work | Mechanism | Runs on |
|---|---|---|---|
| **P0** | Active-facet near field, view ramp 48→128 (`module_world.gd:95-104,373-378`) | voxel pool, nearest-first | voxel workers + 6 ms main apply |
| **P1** | Imminent/committed neighbour prefill (Z1-hybrid, `world_manager.gd:2861+`) | pool spawn + relief-floored ramp | voxel workers |
| **P2** | **NEW: remaining edge neighbours full-res** (§3) | same pool, controller-admitted | voxel workers |
| **P3** | Colour skin: base/band for the view cone (existing 5 ms budget + WTP band slots) | FacetTexBaker | WTP + main slices |
| **P4** | **DEM, demand-driven**: only facets the far ring actually asked shade for (§4.2) | JobLane `PRIORITY_OPPORTUNISTIC` | WTP (1 bg token) |
| **P5** | Whole-planet prebake (DEM sweep + fine map): **off-surface or post-settle idle only** | JobLane opportunistic | WTP (1 bg token) |

Admission for P1-P5 goes through the existing `StreamLoadController` credit/AIMD + inflight gate
(`stream_load_controller.gd:186-243`) — no new governor is invented; the design only **routes the
DEM and the neighbour spawns through the governor they currently bypass**.

"Settled" = the existing `initial_view_meshed` 64³ probe (`world_manager.gd:1281-1290`) plus the
`main.gd` world-settled timer already used for boot telemetry (`world_manager.gd:1292-1300`).

---

## 3. Neighbour-facet full-res block streaming (Goal 2)

### 3.1 What exists today (and why seams show the far tier)

* Each facet is a decorrelated lattice (±32768 offsets); crossing is the two-phase
  `set_active_facet`/`apply_reframe`, and the pooled path replaces teardown with `redesignate` —
  ONE PlanetRoot transform write (`module_world.gd:2105-2119`, the known 200-772 ms spike class,
  memory `voxiverse-crossing-phys-spike`).
* `FP_M1_POOL`/`FP_M2_LOD` Z1-hybrid already spawns **real neighbour VoxelTerrains**
  (`module_world.gd:2059-2087` `pool_spawn`: own generator + facet-carve mesher, ramped 48→96,
  **no extra viewer** — the one player viewer localises into each slot's rotated placement, which is
  what makes cross-terrain priorities comparable and nearest-first global).
* But the **steady state is 1 active + 1 imminent live neighbour** (spawn only when the ridge is
  inside `POOL_D_WARM = 96`, `cube_sphere.gd:71`; one spawn per `POOL_SPAWN_INTERVAL_S`; controller
  `promote_admitted` gated; the diagonal is *never* live, `world_manager.gd:2807-2808`). Every other
  neighbour renders as far tier — exactly the seam see-through the user reports.
* The far ring excludes live facets (`_facet_ring_sync_exclusion`, `world_manager.gd:2827`), so
  once a neighbour is live its seam shows real blocks.

### 3.2 The design: `FP_NB_FULLRES`

The user's previously-directed shape (memory `voxiverse-neighbour-underground-direction`:
**neighbours full-res; underground stone-fill + lazy exposure regen**) is confirmed as right — it
attacks the two real costs (gen volume and underground's 51% gen share) without inventing a new
render path.

1. **Want-set widening:** after "settled", the pool wants **all 4 edge neighbours** live, not just
   the imminent one. `POOL_MAX_NEIGHBOURS = 4` (`cube_sphere.gd:74`) already is the geometric cap —
   no cap change. Spawn stays ≤1 per interval, each admitted by `promote_admitted()` (the imminent
   keeps its headroom-only exemption `promote_imminent_admitted()`), so the fill is a paced trickle:
   worst case 4 spawns × ramp ≈ tens of seconds after settle, invisible because the far quad covers
   each rim until it meshes (the existing M2d contract).
2. **Retire policy change:** distance-based retire (`POOL_D_RETIRE`) is disabled for edge
   neighbours under the flag — they stay warm (they are always "adjacent"). Retire happens only on
   crossing rebalance (the new active's 4 neighbours differ — old far-side facets retire, LRU) or on
   ledger breach (§5).
3. **Underground stone-fill:** neighbour generators run with `FP_COLBULK` (+`FP_STAMP` for
   losslessness) on (`module_world.gd:3873`, `cube_sphere.gd:139-154`): deep columns bulk-fill
   stone/deepslate in C++, cutting the 51% underground gen share for volume the player can only
   reach by digging — at which point normal edit/regen applies (the "lazy exposure regen" already
   inherent in the edit overlay + restream path).
4. **Seam-band view shaping (byte bound):** a neighbour's marginal *rendered* volume is only the
   across-ridge sliver (facet-carve clips each terrain to its wedge), but its *generated/resident*
   volume is the localized viewer sphere at `view_target = 96`. Keep 96 for the imminent; for the
   other 3, a reduced `NB_BAND_BLOCKS` (init 64) view target bounds bytes — the player standing
   mid-facet (K=24 ⇒ facet edge ~1000+ blocks) usually has NO neighbour within view anyway, so the
   localized viewer naturally streams nothing until they approach a ridge. The flag therefore
   mostly changes behaviour **near ridges** — precisely where the seams show.
5. **Corner/diagonal:** stays non-live (Z1 law). The corner wedge shows the two edge neighbours'
   carved terrains meeting over the far quad; acceptable residue, revisit only if the eyeball says
   otherwise.

### 3.3 Memory bound (NEVER-OOM)

Estimate per live neighbour at view 64-96: ~150-300 resident data blocks × 16³ × ~2 B ≈ **2-4 MB
data + 2-4 MB mesh**, i.e. ~**5-8 MB each, ×3 extra ≈ 15-24 MB worst-case, only when standing at a
ridge/corner**. These are estimates — the rollout gates on a **measured** ledger: a
`NB_POOL_BYTES_CAP` (init 32 MB) checked from `VoxelEngine.get_stats()` memory counters; at breach,
spawn refusal first, then LRU retire of the farthest non-imminent neighbour. Caps are checked after
admission, independent of controller credit (the §6.5.6 law in `stream_load_controller.gd:7-8`).

---

## 4. The parallel-thread model (Goal 3)

### 4.1 The honest 2-core reality — the thread ledger

Web pthread pool is FIXED at `WEB_PTHREAD_POOL=24` **seats**, but seats ≠ cores. Real cores:
`navigator.hardwareConcurrency` (read as in `facet_tex_baker.gd:202-207`; Godot's own
`OS.get_processor_count()` under-reports on web), typically **2-8, design floor 2**. Current
runnable-thread sources:

| Pool | Size | Where |
|---|---|---|
| voxel gen/mesh workers | `clamp(round(0.7·hw), 3, hw−1)` — **≥3 even on 2 cores** | `godot/project.godot:101-103` |
| WorkerThreadPool | 5 (4 low-prio) on web | `godot/project.godot:131-132` |
| smooth-V2 / orbit-relief slots | `min(cores−1, 8)` (within WTP) | `facet_smooth_v2.gd:368`, `facet_orbit_relief.gd:511` |
| tex fine-bake workers | `WEB_BAKE_WORKERS = 1` — already convoy-tuned down | `facet_tex_baker.gd:37` |

On 2 real cores that is main + up to ~8 runnable workers timeslicing one spare core through a
shared dlmalloc. The three proven failure modes this design must not reproduce: (a) the dlmalloc
convoy (mimalloc tried + reverted for NEVER-OOM; heap gate task #5 still pending); (b) the shared
C++ generator lock that serialised `FP_CPP_FINE_BAKE` workers (fixed by per-instance generators +
reader-parallel RWLockRead in patches 0011/0012 — `facet_tex_baker.gd:1935-1940`); (c) worker-count
over-provisioning (the N=6→3 A/B in `project.godot:90-100` — **note: that comment argues ratio 0.4
yet the checked-in value is 0.7 (line 102); re-A/B this discrepancy as part of Phase A
telemetry**).

### 4.2 The model: one background token, JobLane as the only multiplexer

**Law 1 — the voxel pool belongs to the near field (P0-P2).** Nothing else ever uses it. Its
nearest-first internal priority is the preserved Goal-3 queue.

**Law 2 — every non-voxel background compute goes through ONE JobLane instance** owned by
WorldManager (`job_lane.gd` is built for exactly this and spawns zero threads,
`job_lane.gd:16-20`). Priorities: crossing-critical (100) > block-LOD (80) > texture (70) >
manifest (40) > DEM/prebake (10).

**Law 3 — one on-surface background token.** Generalize `BG_MAX_INFLIGHT_SURFACE = 1`
(`cube_sphere.gd:1176`): while on-surface, the lane's `max_inflight` is 1 **total** across DEM,
fine-tex, and any future prebake — a single low-priority task at a time is all a 2-core client can
hide. Off-surface (near field frozen by `FP_ALT_REGIME`) the lane may open to 2 and the voxel pool
is idle, so the whole-planet sweeps (P5) get real parallel capacity exactly when the player cannot
feel it.

**Law 4 — C++-sized work units, allocation-flat buffers.** A worker task is one whole facet tile in
native code (`bake_smooth_tile` / `bake_far_tile` on an instance the job owns — the reader-parallel
per-instance pattern), writing into a preallocated per-slot buffer; the main-thread commit is a
bounded memcpy/flag-flip. Per-texel or per-node GDScript on a worker is banned (that is the convoy).

**DEM specifically (`FP_DEM_ASYNC`):**
* dispatch: worker calls `bake_smooth_tile(corner_dirs, r_datum, 32)` on GlobalReliefData's own
  `_cpp_gen` (`global_relief_data.gd:82-83` — already a private instance; corner dirs are read-only
  FacetAtlas statics) + computes the hillshade **on the worker** into a per-job `PackedInt32Array`/
  `PackedByteArray` the job owns single-writer.
* commit (main, bounded): 1089 `encode_s16` + shade memcpy + `_baked[fid]=1` **last**, then
  `_facet_ring.relief_baked(fid)`. The `height_grid` cache stays main-thread-only and only caches
  post-commit (`global_relief_data.gd:115-126` contract unchanged).
* No module (native fallback): the GDScript oracle path stays main-thread but is **off-web only**;
  on web the module is always present (`module_in_web=yes`).

**DEM demand-driven ordering (`FP_DEM_DEFER`):** on-surface the DEM serves a small want-list of
fids the far ring's vertex-colour bake actually touched while unbaked (pull model at
`facet_far_ring.gd:3133-3139`), nearest-first; the O(3456) `_next_unbaked` scan is replaced by a
setup-time `PackedVector3Array` of centre dirs (3456 × 12 B ≈ 41 KB, allocation-free scan) used
only for the off-surface sweep. The first-call `frame_ms = 0` loophole closes (require ≥1 real
sample).

### 4.3 Why this cannot starve the near view

The lane's single on-surface token consumes at most one WTP slot; the voxel pool is untouched; the
main thread pays only `COMMIT_BUDGET_MS = 2 ms`-bounded commits (`job_lane.gd:43-44`). The
StreamLoadController keeps its independent authority: at credit 0 the pool ramps hold, and the
lane's opportunistic band can additionally be paused on `relief_only()` — background work never
outranks first-cover.

---

## 5. Flags, gates, NEVER-OOM budget

All new flags are `const … := false` in `cube_sphere.gd` (byte-off; live enable via the deploy sed,
as established).

| Flag | Effect |
|---|---|
| `FP_DEM_DEFER` | DEM step: no bake before settle; on-surface demand-driven want-list only; scan de-alloc + first-call fix |
| `FP_DEM_ASYNC` | DEM bake compute on JobLane worker; bounded main commit |
| `FP_BG_ONE_TOKEN` | the shared on-surface background inflight token (lane max_inflight 1 ⇄ 2 off-surface) |
| `FP_NB_FULLRES` | all-edge-neighbour live pool policy + no-distance-retire + `NB_BAND_BLOCKS` view shaping |
| (existing) `FP_COLBULK`+`FP_STAMP` | flip on for neighbour generators (stone-fill underground) |

Gates (new `verify_stream_parallel.gd`, pattern of `verify_far_geometry.gd`):
* **G-SP-OFF** — all flags off ⇒ byte-identical (`verify_feature.gd` full pass).
* **G-SP-DEM-DEFER** — synthetic un-settled world: `step()` bakes nothing; after settle signal,
  serves the want-list before the sweep; no allocation in the scan (allocation counter).
* **G-SP-DEM-EQ** — async DEM produces byte-equal `_heights`/`_shade` vs the sync path (same
  law, G-GP-DATA-EQ extended).
* **G-SP-TOKEN** — with N jobs submitted on-surface, lane inflight ≤ 1 at every pump.
* **G-SP-NB** — headless settle ⇒ 4 live neighbours reached, spawn pacing ≥ interval, cap +
  ledger-breach refusal/retire honored, far-ring exclusion synced.
* **G-SP-PRIO** — under a synthetic overload trace, pool ramps hold (credit 0) while lane
  opportunistic band idles — near-first ordering provable.

NEVER-OOM byte budget (delta over shipped):

| Item | Bytes |
|---|---|
| DEM + shade (existing when flags on) | 7.5 + 3.6 MB (unchanged) |
| centre-dir table + want-list + job buffers | ≈ 50 KB |
| JobLane | ≈ 0 (pooled jobs, `job_lane.gd:27-29`) |
| 3 extra live neighbours (est., **measured before enable**) | est 15-24 MB, hard cap `NB_POOL_BYTES_CAP = 32 MB` |

---

## 6. Phased rollout (smallest safe first)

* **Phase A — the reload win (`FP_DEM_DEFER`)**: tiny diff (GlobalReliefData + one call-site
  condition), no threading change. Expected: the 2-3 min sawtooth collapses to the baseline
  apply-bound ramp (tens of seconds). Ship + live A/B on boot telemetry (`world_settled` timer,
  fps p10 during first 120 s). Also: pck flag-dump to confirm the live flag set, and the
  worker-ratio 0.7-vs-0.4 re-check.
* **Phase B — `FP_DEM_ASYNC` + `FP_BG_ONE_TOKEN`**: DEM off main; whole-planet completes in
  background off-surface. Gates G-SP-DEM-EQ/G-SP-TOKEN.
* **Phase C — `FP_NB_FULLRES` (+ colbulk for neighbours)**: want-set widening, retire policy,
  ledger. Headless G-SP-NB first, then live eyeball at a ridge + corner.
* **Phase D — residue**: crossing transform-spike interaction (redesignate now re-places more live
  mesh blocks — measure `redesig_ms`; the structural fix remains the ActiveFrame/fixed-frame
  design, `docs/COSMOS-FIXED-FRAME-DESIGN.md`), corner-wedge eyeball, optional neighbour view
  promotion near ridges.

## 7. The three hardest risks — and how the design kills them

1. **Re-igniting the dlmalloc convoy** (more live terrains + background tasks on 2 cores):
   one background token total on-surface; voxel pool reserved for near field; C++ whole-tile work
   units with preallocated buffers (zero worker-side GDScript allocation); all admission through
   the existing AIMD controller; every phase lands behind a measured live A/B.
2. **Cross-thread data race on the DEM arrays** (`_heights` is live-written): single-writer job
   buffers, commit on main, `_baked` flag flipped last, `height_grid` cache main-thread-only and
   post-commit — plus a byte-equality gate (G-SP-DEM-EQ) so any race would surface as inequality.
3. **Crossing spike scaling with pool size** (`redesignate`'s one-transform re-place is per live
   mesh block): neighbour view targets capped (`NB_BAND_BLOCKS`), Phase C gated on measured
   `redesig_ms` not regressing, and the fixed-frame design is the acknowledged structural
   dependency if it does.
