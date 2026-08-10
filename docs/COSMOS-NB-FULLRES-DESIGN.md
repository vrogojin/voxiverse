# COSMOS — FP_NB_FULLRES: full-res near blocks on ALL 4 edge-neighbour facets

**Status: DESIGN, implementation-ready (nothing here is implemented).** Task #102 Phase C.
Author: Fable (perf architect). Parent: `docs/COSMOS-STREAM-PARALLEL-DESIGN.md` §3 / Phase C —
this doc turns that skeleton into the concrete spec. Tree: `deploy/cheats-eyeball`.

Goal (user, full-coverage): near a facet boundary, **all 4 edge neighbours** of the active facet
render real full-res blocks across their seams instead of the far tier ("seam see-through").
Some fps cost is accepted; NEVER-OOM (2048 MB heap ceiling, live vmem ~180-210 MB) is a hard
limit and the neighbour budget must be **measured bytes**, not estimates.

---

## 1. The machinery as it exists today (the residency law, mapped)

All paths below are `godot/src/…`.

### 1.1 Pool state and constants

| Thing | Where |
|---|---|
| Pool map `_pool: {fid → {terrain, slot, mesher, generator, view_f, view_target, ramp_from, editable, spawn_ms}}` | `world/voxel_module/module_world.gd:2047-2054` (active seed), `:2083` (neighbour) |
| `pool_spawn(fid)` — builds a live neighbour VoxelTerrain: **own generator** (`_make_generator(fid)` `:1827`), own facet-carve mesher, `generate_collisions = false` (`:1837`), bounds clamped to the facet domain slab, **no extra viewer** (`:2056-2058`) | `module_world.gd:2059-2087` |
| Spawn view: starts `RAMP_START_BLOCKS = 48` (`:103`), ramps to `nb_target = 96` (`:2078`); committed imminent ramps to the active radius instead (`POOL_CROSSING_PREGEN`, `:2079-2080`) | `module_world.gd:2066-2082` |
| Ramp pacing: `_ramp_pool_step` advances **at most ONE slot per frame** over `RAMP_SECONDS = 1.5` (`:100-104`), grow leg scaled by controller `stream_pace` (`:1952-1956`), inflight-gated via `_inflight_main_q()` (`:598-612`) | `module_world.gd` |
| `pool_retire(fid)` — never the active; queue_frees the whole slot | `module_world.gd:2091-2103` |
| `redesignate(to)` — the crossing: ONE PlanetRoot transform write (skipped under fixed frame, `:2123-2127`), `to` ramps 96→near radius, `from` shrinks to 96 (paced under `FP_SHRINK_PACED`, `:2138-2145`) | `module_world.gd:2109-2174` |
| Caps: `POOL_D_WARM 96` / `POOL_D_RETIRE 128` / `POOL_MIN_LIVE_S 10` / `POOL_MAX_NEIGHBOURS 4` / `POOL_SPAWN_INTERVAL_S 1.0` / `POOL_D_WARM2 48` / **`FP2_LIVE_CAP 2`** / `POOL_D_COMMIT 64` | `cosmos/cube_sphere.gd:71-88, 1892` |

### 1.2 The per-tick manager (WorldManager)

`_manage_facet_pool` (`world/world_manager.gd:2813-2839`), every physics tick from
`update_streaming`, suspended off-surface/high-altitude (`:1262-1264`):

1. **Want-set** — already computes **all 4 edges**: for `slot in 4`,
   `nb = FacetAtlas.seam_neighbour(active, slot)`, `d = FacetAtlas.own_dist(...)` →
   `want = {nb: ridge_dist}` (`world_manager.gd:2821-2828`). The diagonal is never a
   `seam_neighbour`, so it can never enter `want` (Z1 law).
2. **Target selector** `z1_live_targets(want, off_surface, live_now, speed)`
   (`world_manager.gd:2953-2983`, **static**, gate-drivable): off-surface → `[]`;
   else `[imminent (D_WARM shell + incumbent hysteresis)] + [corner-second under D_WARM2]`,
   capped at **`FP2_LIVE_CAP = 2`**. ⇒ **steady state = 1 active + 1 imminent (+ 1
   corner-second)** — this is why the other ~3 edges show the far tier.
3. **Spawn** (`world_manager.gd:2899-2917`): ≤1 per `POOL_SPAWN_INTERVAL_S`, iterates
   `targets` in priority order, breaks at `FP2_LIVE_CAP`; admission =
   `promote_admit_imminent(ctrl, d, speed)` for `targets[0]` (headroom OR geometric commit
   `d < POOL_D_COMMIT`, `:3006-3009`) else `promote_admit(ctrl)` (credit AND
   `not backlog_gated()`, `:2988-2991`) — the AIMD `StreamLoadController`
   (`world/stream_load_controller.gd:217-241`).
4. **Distance-retire** (`world_manager.gd:2928-2940`): a live neighbour **not in `targets`**
   with `d > POOL_D_RETIRE` and age ≥ `POOL_MIN_LIVE_S`, ≤1 per interval, first-found order.
5. On any change → `_facet_ring_sync_exclusion()` (`world_manager.gd:3051-3066`):
   far-ring excluded set = live pool fids ∪ LOD-covered fids, **whole-facet binary**,
   deferred/budgeted rebuild (`world/facet_far_ring.gd:1241-1249`).

### 1.3 Facts the spec builds on (verified)

* **One shared player viewer, no per-neighbour viewers** — the viewer localises into each
  slot's rotated placement, which is what makes cross-terrain priorities comparable:
  godot_voxel orders block loads by distance-to-viewer, so **nearest-first stays global by
  construction** (`module_world.gd:50-53, 2056-2058`). Corollary: a neighbour whose ridge is
  farther than its `max_view_distance` **streams zero blocks** (its slab-clamped bounds are
  out of viewer reach) — a mid-facet player pays ~node overhead only for a live-but-empty
  neighbour.
* **Neighbour gens are already stone-fill-cheap**: every pool slot's own generator snapshots
  `fp_colbulk = CubeSphere.FP_COLBULK` and `fp_stamp = CubeSphere.FP_STAMP` at
  `_make_generator` (`module_world.gd:3873-3874`); the C++ column-bulk path
  (`:3384-3460`) applies to pool neighbours identically. **Nothing new to wire** — Phase C
  just requires those flags on live (they are, since STREAM-SCHED R1/R7).
* **`VoxelTerrain.get_statistics()` has NO resident-memory counters** — only
  `time_*` process timings + `dropped_block_loads/dropped_block_meshs/updated_blocks`
  (engine `voxel_terrain.cpp:599-613`). (Side finding: `_pool_block_sum`
  `module_world.gd:2188-2200` sums those *event counters*, not resident blocks — its
  `blocks_replaced` telemetry is mislabeled; fix opportunistically.)
* **`VoxelEngine.get_stats().memory_pools` IS real measured bytes**: `voxel_used` /
  `voxel_total` (VoxelMemoryPool = all voxel **data** blocks engine-wide) + `block_count`
  (engine `voxel_engine_gd.cpp:144-160`). This, plus `OS.get_static_memory_usage()` (the
  WASM malloc'd-bytes reading the existing G-M1-MEM gate uses,
  `tools/verify_faceted.gd:994-1007`), are the two measured sources for the ledger.
* `pool_seam_meshed(fid, player_pos)` — is the neighbour's cross-ridge band meshed near the
  player (C++ `is_area_meshed` over a 64×80×64 box) — exists at `module_world.gd:1940-1950`.
  Caution: returns `true` when `fid` is not pooled — always AND with `pool_has(fid)`.

---

## 2. The FP_NB_FULLRES spec

`const FP_NB_FULLRES := false` in `cosmos/cube_sphere.gd` (byte-off; live enable via the
deploy sed, as established). New consts (same block as the POOL_* family,
`cube_sphere.gd:71-88`):

```gdscript
const FP_NB_FULLRES := false
const NB_BAND_BLOCKS := 64.0        # view target for non-imminent edge neighbours
const NB_POOL_BYTES_CAP := 32 * 1048576   # measured post-settle growth budget for the widened pool
const NB_BYTES_REHYST := 8 * 1048576      # re-admission hysteresis below the cap
const NB_EXCL_RELEASE := 96.0       # ridge distance beyond which a band facet re-enters the far ring
```

Effective condition everywhere: `nb_fullres_on() := FP_NB_FULLRES and settled and not off_surface`,
where **settled** = a WorldManager latch `_nb_settled` set the first time
`initial_view_meshed(player)` returns true (`world_manager.gd:1293-1301`) — the near view is
up before any widening begins (the fresh-load window stays Phase-A's).

### 2.1 Want-set → targets (the residency change)

`want` is already the 4 edges (`world_manager.gd:2821-2828`) — unchanged.
`z1_live_targets` grows one flag-gated tail (signature gains `fullres: bool = false`, stays
static/gate-drivable):

* Shipped head unchanged: off-surface → `[]`; imminent with incumbent hysteresis; then
* **fullres tail** (replaces the corner-second branch when `fullres`): append every remaining
  fid of `want` in ascending `d` order — i.e. `targets` = imminent first, then the other 3
  edges nearest-first. Cap: `POOL_MAX_NEIGHBOURS` (4).
* `fullres = false` ⇒ byte-identical shipped output (G-M2-POLICY untouched).

Cap read at `world_manager.gd:2904` becomes `_z1_live_cap()`:
`POOL_MAX_NEIGHBOURS if nb_fullres_on() else CubeSphere.FP2_LIVE_CAP`.

**Spawn pacing is untouched**: still ≤1 spawn per `POOL_SPAWN_INTERVAL_S`, still
`promote_admit_imminent` for `targets[0]` and the **full** `promote_admit`
(credit + backlog gate) for every widened spawn — the fill is a controller-paced trickle,
worst case 4 × (interval + ramp) ≈ 10-15 s after settle, covered by the far ring meanwhile
(the M2d contract). No burst; the dlmalloc-convoy lesson is honored by construction.

### 2.2 Retire law

The existing code already does the right thing once `targets` contains all 4 edges:

* **Distance-retire self-disables for edges** — `world_manager.gd:2929-2931`
  `if targets.has(nb): continue` skips every edge neighbour. They stay live. No code change.
* **Crossing REBALANCE is the existing path**: `redesignate` flips `_pool_active`; next tick
  `want` is recomputed from the **new** active's 4 slots. The old active is itself an edge of
  the new active (stays live, already shrunk by redesignate); the old active's other 3
  neighbours are not in the new `want` → `d = 1e30 > POOL_D_RETIRE` → retired at ≤1/interval
  with `POOL_MIN_LIVE_S` anti-thrash. Convergence ≈ 3 retires + 3 spawns interleaved over
  ~3-6 s (separate spawn/retire timers `world_manager.gd:122-123`).
* **Two changes needed** in the retire block (`:2928-2940`), both flag-gated:
  1. **Farthest-first**: pick the non-target with max `d` instead of first-found (dict
     order), so the most useless facet frees its slot first.
  2. **Imminent-priority eviction**: if the spawn loop wants `targets[0]` (the crossing
     target) but `pool_neighbour_count() >= POOL_MAX_NEIGHBOURS`, retire the farthest
     non-target **immediately in the same tick** (bypassing the retire interval for this one
     case, MIN_LIVE_S still honored). Without this, 3 stale post-crossing neighbours + the
     old active fill the cap and can delay the next imminent spawn — a pool-miss risk the
     shipped 2-cap never had.
* **Ledger breach** retires are §2.5.

### 2.3 Render band (how the 3 non-imminent edges actually mesh the seam)

Per-slot view targets, all through the existing ramp machinery:

* `pool_spawn` (`module_world.gd:2078-2081`): `nb_target = 96.0` becomes —
  committed imminent → prefill (unchanged); else if `FP_NB_FULLRES` and `fid != _imminent_fid`
  → `NB_BAND_BLOCKS` (64); else 96 (shipped).
* `set_imminent_fid` demote of an outgoing imminent (`module_world.gd:1985-1992`) and
  `redesignate`'s `from`-shrink (`:2138-2151`): demote target 96 becomes `NB_BAND_BLOCKS`
  under the flag (shrink-paced, `FP_SHRINK_PACED` path unchanged).
* Promotion to imminent (`:1992-1998`) already raises the target — works for a
  band-resident neighbour as-is (ramp_from = current view_f).

**No viewer work at all.** The one player viewer localises into each slot; with
`max_view_distance = 64` a neighbour streams nothing until the player is within ~64 blocks
of its ridge, then fills exactly the cross-ridge band nearest the player — nearest-first
globally, bytes ∝ proximity, automatic hysteresis as the player leaves (blocks unload).
`NB_BAND_BLOCKS` is the perf/byte knob: band volume scales ~cubically (64→48 ≈ ×0.42).

### 2.4 Far-ring exclusion must become band-conditional (NEW — corrects the parent §3.1)

Today's exclusion is whole-facet binary (`world_manager.gd:3059`,
`facet_far_ring.gd:1241-1249`). Under FULLRES that is **wrong twice**:

* A live-but-**empty** neighbour (player mid-facet, viewer out of reach) would lose its far
  tile ⇒ its visible ridge region renders backstop-only — a **regression** vs today.
* A band facet whose player walks away **unloads its band** (localized viewer departs) —
  static exclusion would leave a hole where the band was.

**Law**: under `nb_fullres_on()`, `_facet_ring_sync_exclusion` excludes a live neighbour only
when its seam band is actually up, with geometric release hysteresis:

```
excluded(nb) := lod_covered(nb)                       # unchanged
             or nb == imminent/committed              # shipped behaviour for the crossing target
             or (pool_has(nb) and _nb_excl_latch[nb])
latch set:    pool_seam_meshed(nb, player_pos) true   # probed in the pool pass, ≤1 fid/tick
latch clear:  want[nb] > NB_EXCL_RELEASE (96)         # geometric, no mesh probe; also on retire
```

This is the **established** cover-until-meshed contract (promote-HOLD / W10,
`world_manager.gd:3024-3049`; `pool_spawn` far-quad-covers-the-rim comment
`module_world.gd:2069`) extended to the widened pool — no new artifact class: the flip
moment is exactly today's imminent-goes-live flip. `_skin_candidate_fids`
(`world_manager.gd:3071-3077`) follows the same conditional set.
Implementation checkpoint: verify the interim tile-over-partial-band window under
`FP_NO_NEAR_LOD` looks like today's promote window at a ridge (it uses the same cover).

### 2.5 The memory ledger (NEVER-OOM, measured bytes)

Two measured sources, both real: `VoxelEngine.get_stats().memory_pools.voxel_used`
(voxel data bytes, engine-wide) and `OS.get_static_memory_usage()` (WASM malloc'd bytes —
meshes, nodes, everything). Per-terrain resident bytes are **not** exposed by the engine
(§1.3), so the enforcing ledger is a **post-settle growth budget**, which is deliberately
conservative:

* At the `_nb_settled` latch (before any widened spawn), snapshot
  `B0 = voxel_used + static_mem`.
* `nb_pool_growth() := (voxel_used + static_mem) − B0` (recompute ≤1/pool pass).
* **Admission predicate** (checked *in addition to* controller admission, per the
  caps-independent law `stream_load_controller.gd:7-8`): every **non-imminent** widened
  spawn AND every non-imminent NB ramp-grow step requires
  `nb_pool_growth() + NB_SPAWN_EST ≤ NB_POOL_BYTES_CAP` (NB_SPAWN_EST = 4 MB headroom).
  The imminent keeps its shipped path (it is the crossing invariant and exists at cap 2
  today).
* **Breach ladder**: (1) refuse further widened spawns; (2) freeze non-imminent NB grow
  (`view_target = min(view_target, view_f)`); (3) if still breached next interval,
  LRU/farthest retire of one non-imminent neighbour per interval. **Re-admission** only
  below `NB_POOL_BYTES_CAP − NB_BYTES_REHYST` (no thrash).
* **Absolute backstop** (independent of B0 drift):
  `static_mem > NB_ABS_HEAP_MB (1600 MB)` ⇒ ladder step (3) immediately. (Task #5's
  `emscripten_get_heap_size` patch strengthens this when it lands; not a dependency.)
* Drift honesty: other systems' post-settle growth (weather, edits, textures) debits this
  budget — that only makes NB **more** conservative, never OOM. B0 re-snapshots when the
  widened pool is empty.
* **Attribution telemetry** (not enforcement): per-spawn deltas of both counters recorded
  into `_nb_ledger[fid]` across the spawn→ramp-complete window; surfaced via RemoteBridge
  next to the existing pool stats.

**Byte math (estimate → measured gate)**: a band at the ridge ≈ half-sphere r=64 voxels =
~190 data blocks × (16³ × 2 B + overhead ≈ 10 KB) ≈ 2 MB data + ~2-4 MB mesh ⇒ **~4-6 MB per
band-resident neighbour**; imminent at 96 ≈ 5-8 MB (today's cost). Mid-facet: **~0** (empty
terrains). Worst realistic (standing at a corner: 2 band + 1 imminent-warm): **~10-18 MB**,
vs cap 32 MB. These are estimates; **G-SP-NB-CAP measures before enable** (the existing
G-M1-MEM machinery, `verify_faceted.gd:994-1007`, re-parameterised: 4 spawns, viewer parked
at a corner, per-spawn `voxel_used` + static-heap deltas asserted ≤
`POOL_NEIGHBOUR_MEM_BUDGET_MB = 20`, total ≤ `NB_POOL_BYTES_CAP`).

---

## 3. Change list (file:line)

| Change | Where |
|---|---|
| Flag + 4 consts (§2 header) | `cosmos/cube_sphere.gd:71-88` block |
| `z1_live_targets` fullres tail + `fullres` param | `world/world_manager.gd:2953-2983` |
| `_z1_live_cap()` helper; use at spawn-loop cap check | `world_manager.gd:2904` |
| `nb_fullres_on()` + `_nb_settled` latch (set in the `initial_view_meshed` reveal path) | `world_manager.gd` near `:1293` |
| Retire farthest-first + imminent-priority same-tick eviction | `world_manager.gd:2928-2940` (+ spawn loop `:2899-2917`) |
| Band view targets (spawn / imminent-demote / redesignate-shrink) | `module_world.gd:2078-2081, 1985-1992, 2138-2151` |
| Band-conditional exclusion latch | `world_manager.gd:3051-3066` (+ probe in `_manage_facet_pool`), `_skin_candidate_fids:3071-3077` |
| Ledger: `B0` snapshot, `nb_pool_growth()`, admission + breach ladder | `world_manager.gd` pool section + `module_world.gd` (freeze = view_target clamp; reuse `_inflight_main_q`'s cached `VoxelEngine` singleton `:603-607`) |
| `_pool_block_sum` mislabel fix (telemetry only) | `module_world.gd:2188-2200` |
| Gates | `tools/verify_stream_parallel.gd` (extend), `verify_faceted.gd` G-M1-MEM re-parameterised |

## 4. Gates

All in `verify_stream_parallel.gd` (Phase A conventions; selector gates drive the **static**
`z1_live_targets` directly, pool gates use the verify_faceted G-M1-POOL headless-spawn
pattern):

* **G-SP-NB-OFF** — flag off: selector output byte-identical for a matrix of want/live
  inputs; pool residency law unchanged (steady state ≤ FP2_LIVE_CAP); external pin: FLAT
  `verify_feature.gd` **6042/0** with all new flags false.
* **G-SP-NB-COVER** — flag on + settled: selector returns imminent-first then all remaining
  edges nearest-first; after paced spawns, all 4 edge neighbours live; far-ring excluded set
  contains only band-meshed/imminent fids (empty neighbours keep their far tile).
* **G-SP-NB-CAP** — falsifier: force `nb_pool_growth()` over the cap (shrink
  `NB_POOL_BYTES_CAP` for the test) ⇒ widened spawn refused, grow frozen, LRU retire fires,
  re-admission only below cap − REHYST; **bounded, never OOM**. Plus the measured-bytes
  print (the pre-enable authority).
* **G-SP-NB-PRIO** — selector always yields imminent at index 0; cap-blocked imminent spawn
  triggers same-tick farthest eviction (no pool-miss); one-viewer construction asserted
  (spawn adds no viewer — count viewers).
* **G-SP-NB-REBALANCE** — flip active to a neighbour: new selector output = new active's 4
  edges; old far-side fids leave targets and distance-retire within the pacing law;
  MIN_LIVE_S honored (no thrash on an immediate cross-back).
* Regression: `verify_faceted.gd`, `verify_fp_m2*`, `verify_orbit_relief.gd`,
  `verify_stream_parallel.gd` Phase A section — all byte-off green.

## 5. Perf expectation (honest)

* **Mid-facet (most of the time): ~zero.** 3 extra empty VoxelTerrains cost ~0.1-0.3 ms of
  `_process` bookkeeping total (measurable via the summed `terrain_main_thread_stats`,
  `module_world.gd:2265-2284`) and ~0 bytes.
* **Approaching/along a ridge:** one band fill = a paced 48→64 ramp ≈ an imminent spawn's
  cost at ⅔ view — expect a transient **~2-5 fps** dip during fill (controller-paced), then
  steady-state +1 terrain's draw/apply ≈ 1-2 ms. At a **corner** (2 bands + imminent):
  worst case, expect **~3-8 fps** below today's corner case. `NB_BAND_BLOCKS` is the knob
  (volume ~cubic; 64→48 ≈ ×0.42).
* **Crossing:** `redesignate`'s transform write re-places every live mesh block — with
  bands resident, `blocks_replaced` grows by the side-neighbours' band blocks (hundreds,
  not thousands; mid-facet neighbours hold none). Under the fixed frame
  (`module_world.gd:2123-2127`) the write is skipped entirely. Gate the live A/B on
  `redesig_ms` (existing A1 instrumentation, drained at `world_manager.gd:2774`) **not
  regressing** vs baseline; the structural fallback remains
  `docs/COSMOS-FIXED-FRAME-DESIGN.md`.

## 6. The three hardest risks — and the kill for each

1. **Re-igniting the dlmalloc convoy** (4 neighbour gens on ~2 real cores). Kill: nothing
   new runs concurrently — spawns stay ≤1/interval through the full AIMD admission
   (credit + backlog gate), the pool ramp advances ONE slot per frame
   (`module_world.gd:100-104`) with the inflight feed-forward gate, neighbour gens are
   colbulk stone-fill (the 51% underground share bulk-filled in C++), and mid-facet
   neighbours generate **nothing** (empty-viewer-reach construction, §1.3). The widened pool
   changes *how many facets may hold a band*, not *how fast anything fills*.
2. **Crossing-rebalance churn / imminent starvation** (want-set flips: 3 retires + up to 3
   spawns, cap-full pool blocking the next crossing target). Kill: rebalance rides the
   existing paced retire path (≤1/interval, MIN_LIVE_S, incumbent hysteresis); the old
   active is itself an edge of the new active (no rebuild); and the new **imminent-priority
   same-tick eviction** guarantees the crossing target always finds a slot —
   G-SP-NB-REBALANCE + G-SP-NB-PRIO falsify both directions.
3. **Memory creep / a hole where the ledger lied** (estimates wrong, corner worst-case,
   counter pollution). Kill: enforcement uses only **measured** counters
   (`memory_pools.voxel_used` + static heap) as a post-settle growth budget whose drift
   direction is conservative (foreign growth debits the NB budget → NB retires first,
   never OOM); breach ladder refuse→freeze→LRU-retire with re-admission hysteresis; absolute
   1600 MB backstop; and the pre-enable **measured** G-SP-NB-CAP number replaces the 5-8
   MB/neighbour estimate before the flag ever flips live.

## 7. Rollout

1. Land flag-off + gates (FLAT 6042/0, full regression) → PR.
2. Headless G-SP-NB-* green, record the measured corner-case bytes.
3. Live enable via deploy sed; eyeball at a ridge, a corner, and a crossing;
   A/B `redesig_ms`, fps p10 at a corner, vmem before/after.
4. Tune `NB_BAND_BLOCKS` (64 → 48/80) on the eyeball + fps evidence; Phase D residue
   (corner wedge, fixed-frame) per the parent doc.
