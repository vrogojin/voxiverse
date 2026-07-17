# COSMOS — Streaming Scheduler Redesign: Surface-First Generation, Priority/Drop Policy, and the Trick Catalogue

**Status:** implementation-ready design (no implementation in this pass). Branch
`deploy/perf-plus-sky`, 2026-07-17.
**Author:** Fable (design pass), commissioned on the user's direction (surface-first fill, heavy
near-prioritization, lazy background streaming, fast-movement drop/re-target) + the explicit
addendum: *assess the user's tricks, invent more, design to build-from detail — Opus implements
directly from this doc.*
**Ground truth (all measured on the user's laptop, 2026-07-17):** supply ≈ **23–35 blocks/s**
(N=3→6 workers), per-block ≈ **130 ms @N=3 / 173 ms @N=6** vs **13.7 ms native** (~10×
WASM/GDScript penalty); walking demand ≈ **90–100 blocks/s gross**; more workers measurably do
not help; mimalloc moved only worst p50 −23%. **Supply < demand, always** — the scheduler must be
designed for permanent scarcity, not a transient backlog.

> **Headline.** The user's four ideas are structurally right, and two are cheaper than they
> assumed: terrain collision is **analytic** (no collision meshes exist to "keep producing",
> §1.1), and the engine **already re-sorts the whole generation queue by live
> distance-to-player every 200 ms** (§3.1). The big invented additions on top of their list:
> **(R1) column-granular bulk fill** — ~65–75 % of per-block work resolves interior cells that
> are invisible until dug; filling them per-column roughly **doubles supply**; **(R7) blob
> stamping** — strata/ore are containment-clamped lattices, so scatter-stamping them instead of
> per-cell hash-testing makes underground generation **byte-identical at ~fill speed**,
> eventually retiring the bulk-fill appearance loss entirely; **(R3) a profile-only skin tier**
> that covers the full 256-block disc with exact-silhouette relief in **~1–2 s instead of
> ~45 s**, for ~50× less work per column than voxels; **(R4) a ~30-line engine patch** wiring
> the existing-but-unwired `TaskCancellationToken` so fast movement stops burning workers on
> stale blocks. Everything is flag-gated OFF == byte-identical, NEVER-OOM-ledgered, and judged
> on **integrated whole-walk metrics** (§8) designed to auto-reject the L4b class of error.

Reading map: §1 assess the user's tricks · §2 cost model + generation tricks · §3 engine
machinery · §4 scheduling model · §5 skin tier · §6 full trick catalogue (invented + rejected)
· §7 ranked plan · §8 measurement protocol · §9 implementation change map (build from this)
· §10 SOTA · §11 risks.

---

## 1. The user's four tricks — verdicts

| # | user's idea (verbatim intent) | verdict | disposition |
|---|---|---|---|
| 1 | Fill terrain quickly with just block SURFACES, "still keep producing the respective collision structures" | **Right direction, one wrong premise, and cheaper than they think.** There are no collision structures: every terrain has `generate_collisions=false` (`module_world.gd:366,1587,2116,2217`), the viewer `requires_collisions=false` (`:2534`); physics is fully analytic (`WorldManager.block_id_at → resolve_cell`). The mesh is purely cosmetic — surface-first has **zero** physics risk. Second correction: inside the voxel field, "surfaces instead of full blocks" does not need a new representation — the mesher already emits only visible faces; what costs is *resolving invisible interior cells*, so the win is making interiors cheap (R1/R7), not meshing differently. Beyond the voxel field, the render-tier version of the idea is the skin (R3). | → R1, R7, R3 |
| 2 | Heavily prioritize background streaming; only the chunk immediately around the player FULLY generated | **Mostly already true; the "full" tier dissolves.** Nearest-first is engine-native, re-sorted every 200 ms (§3.1). And even the immediate chunk doesn't need interior detail up front: digging restores truth (lazy exposure regen — and with R7, interiors are byte-exact from the start anyway). What the immediate ring uniquely needs is codified as the T0 sacred set (§4). | → T0, §3.1 |
| 3 | Lazy streaming scheduler: lower-priority chunks only once immediate neighbours are done | **Adopted.** The engine has no dependency-gating, but pace-gating the neighbour-slot view ramps on active-field saturation achieves it with shipped machinery (`_ramp_pool_step` + `StreamLoadController`). This attacks the real demand pathology: gross walking demand 90–100 blocks/s vs a bare viewer-ellipsoid need of 15–20. | → R2 |
| 4 | If moving fast, DROP/repurpose in-flight tasks; re-target standing → looking → around; continuously re-shuffle the queue | **Half exists, half missing.** Re-shuffle: engine-native (200 ms live-distance resort, §3.1) — standing-over and around-us ordering is automatic. Missing: (a) cancellation of submitted tasks — the token exists but `VoxelTerrain` passes an empty one (§3.3) → engine patch R4; (b) looking-at priority — no direction term in the engine → gaze viewer R6; (c) the shed policy under sustained overload → R5 control law with hysteresis. | → R4, R5, R6 |

---

## 2. The cost model and the generation-side tricks

### 2.1 Where a block's milliseconds go (measured, `COSMOS-GEN-EFFICIENCY-DESIGN.md` §0)

```
land column ≈ 319 µs = 7 µs overhead (profile 2.0 + slope_run 5.0)
                    + 244 µs underground resolve_cell (84 cells × 2.9 µs)
                    + 68 µs surface/above (snow/cap/tree/slope)
fully-underground 16³ block ≈ 13.7 ms; bulk-qualified (FP_BULK_UNDERGROUND) ≈ 0.6 ms;
surface-crossing ≈ 5–15 ms; web ≈ ×10 (GDScript-VM-on-WASM + SMT oversubscription).
```

Of the 84 underground cells per column, only the top `_filler_depth(biome)` ≤ 12
(`terrain_config.gd:1937-1948`; typical biomes 3–4, badlands 12) can be seen without digging.
**≈ 65–75 % of a land column's work resolves cells that are invisible until dug.** That is the
largest recoverable term left in the generator, and the user's trick #1 in its correct form.

### 2.2 What 2.9 µs/cell actually buys (the deep path, code-read)

Per deep cell, `resolve_cell` runs: `_surface_rule` branch → STONE (`terrain_config.gd:1894-1903`)
→ `_deep_family` (`:1975-1993`): deepslate banding + a **strata lattice probe** (`_strata_at`,
`:1995-2020`: 3 `floori` + 1 existence hash, then on the ~25 % hit 6 more hashes + a sphere test)
→ `_ore_at` (`:2023-2050`: 3 `floori` + existence hash, on the ~45 % hit 6 more hashes + a sphere
test + `_pick_ore`'s weight loop). So ~5–10 `_hash01_3d` calls plus GDScript VM dispatch per
cell — asked **once per cell, 4096 times per block**, even though the answers are blob-shaped.

### 2.3 R1 — `FP_COLBULK`: column-granular bulk fill (the cheapest big win)

`FP_BULK_UNDERGROUND` fills only blocks whose **whole box** clears `min_h − 12` and the
−24..−16 dither band (`module_world.gd:2887-2910`). Everything else — surface blocks and every
underground block under rough terrain that fails the `min_h` gate — runs the unconditional
per-cell loop over all 4096 cells (`:2930-2955`). Confirming the team brief: **a surface block
resolves every cell, including its whole sub-surface portion.**

R1 moves the gate inside the emit loop, per column (mechanical spec in §9.2):

```
per column (g known from profs[]):
  deep run  [oy , min(by_top, g−12)):  fill_area STONE above −16 / DEEPSLATE below −24;
                                       the 8-cell dither band −24..−16 stays per-cell;
                                       blocks touching bedrock (−59) keep per-cell there
  exact band [g−12 , col_top]:         per-cell resolve_cell — unchanged, byte-exact
  air        (col_top , by_top):       skipped (R1b, §2.4)
  slope_run_of computed ONLY if the exact band intersects the block (lazy)
```

Faceted safety: v1 applies column bulk only when the whole block passes the existing
`FacetAtlas.cell_interior_scaled` gate (`module_world.gd:2903-2906`) — ridge-straddling blocks
stay fully per-cell. Appearance class: identical to the shipped, user-accepted
`FP_BULK_UNDERGROUND` loss (interior strata/ore variants until dug; the dig path restores truth)
— and R7 (§2.5) later removes even that loss.

**Per-class effect (native; web ≈ ×10):**

| block class | today | R1 | factor |
|---|---|---|---|
| underground, bulk-qualified | 0.6 ms | 0.6 ms | 1× |
| underground, **gate-failed** (rough `min_h` / dither straddle) | **13.7 ms** | ~1–3 ms | **5–14×** |
| surface-crossing | 5–15 ms | ~4–11 ms | ~1.3× |

Mix model (walking mix ≈ 30 % air/cheap, 25 % bulk-qualified, 25 % gate-failed, 20 % surface):
native average 5.7 → 2.5 ms ⇒ **supply 23–35 → ~50–80 blocks/s (~2–2.5×)**. The mix is the soft
spot; the T1 per-class timer verifies it before R1 is judged.

### 2.4 R1b/R1c — two free riders on the same edit

- **R1b, per-column air ceiling.** The y-loop resolves above-surface cells to the block top; the
  block-level early-out uses block-wide `max_h + max_above`. Per column the sound ceiling is
  `max(g over the 3×3 neighbourhood) + max_above` (canopy/snow reach only within the stencil
  `slope_run_of` already covers), further maxed with `SEA_LEVEL` for underwater columns (sea
  cells must still emit, `terrain_config.gd:1880-1891`). v1 applies it only to interior columns
  (x,z ∈ 1..14, 3×3 available from `profs[]`); edge columns keep the full loop.
- **R1c, provable-deep skip.** After R1, a bulk block's residual cost IS its 256-column profile
  pass (~0.5 ms). Introduce a verified global lower bound `MIN_SURFACE_Y` (mirror of
  `MAX_SURFACE_Y`; the LOD builder already asserts a −24 min-visible-surface bound,
  `facet_lod_builder.gd:22`): blocks with `by_top ≤ MIN_SURFACE_Y − 12` (and above bedrock,
  ridge-interior) fill **without any profile pass** → 0.6 → ~0.05 ms. Stateless; supersedes most
  of what the once-skipped Fix B memo would buy (R8 stays conditional, §6).

### 2.5 R7 — `FP_STAMP`: the gather→scatter inversion (invented; byte-identical underground)

The structural fact that unlocks it: **both strata and ore blobs are containment-clamped to
their lattice cell** — centre jitter is clamped so `centre ± r` stays inside the cell, which is
why a per-cell query consults exactly ONE lattice cell (`terrain_config.gd:2001-2007` strata,
`:2031-2036` ore). Therefore the inverse enumeration is exact and local: the only blobs that can
touch a block live in the lattice cells overlapping the block itself.

Instead of 4096 × (strata probe + ore probe), do once per block, after the R1 deep fills:

```
for each strata lattice cell (16³ pitch → 1–8 cells) overlapping the block's deep region:
    reproduce the existence/radius/centre/variant hashes  → stamp the sphere ∩ block
      (deepslate-region rule: only sulfur/cinnabar override deepslate, terrain_config.gd:1985-1990)
for each ore lattice cell (6³ pitch → ~27 cells, ~45 % active) overlapping the deep region:
    reproduce blob params; per COLUMN in the blob's bbox fetch (biome,c) from profs[] and
      evaluate the ore type once (`_pick_ore(cy, biome, c, …)` is query-column-dependent,
      terrain_config.gd:2044-2047); per cell apply the y-band `_ore_density` clip and the
      stone/deepslate host variant
```

Cost: ~1–3 k cheap ops ≈ **0.3–0.8 ms/block** vs 11.9 ms per-cell — and the output is
**byte-identical** to the per-cell path *by shared construction* (§9.6 factors the blob-parameter
derivation into `TerrainConfig` statics that both paths call). Consequences:

- The gate is a **hard equality assert** (N random blocks, fill+stamp == per-cell), far stronger
  than the lossy-bulk acceptance.
- Applied to both R1's deep runs and the shipped whole-block `FP_BULK` fill, underground
  generation becomes exact everywhere → the lazy-exposure-regen machinery and the "wrong wall
  until regen" transient become removable (follow-up cleanup, not in this pass).
- It also answers the addendum's "progressive refinement" question by mooting it: nothing needs
  refining if the cheap path is already exact (§6, rejected list).

R7 is R1's v2 — same edit site, replaces the lossy fills with fill+stamp. Ship R1 first (simpler,
carries the throughput), then R7 behind its own flag with the equality gate.

---

## 3. The engine machinery as it actually is (godot_voxel v1.4.1, our patched tree)

The honest boundary between "reachable from GDScript today" and "needs an engine patch".

### 3.1 Ordering: distance-to-nearest-viewer, continuously re-evaluated — already 80 % of "re-shuffle"

- Task priority: `band0 = 255 − (distance_to_nearest_viewer >> (4+lod))` — **16-block buckets**,
  closer wins (`priority_dependency.cpp:47`); `band1` LOD; `band2` a **constant 10** for
  load/gen/mesh (`voxel_constants.h:62-64`) — no game-steerable class exists.
- Viewer positions sync into shared data **every frame** (`voxel_engine.cpp:313,318-351`); the
  pool re-computes every queued task's priority, deletes cancelled tasks, and re-sorts every
  **200 ms** (`voxel_engine.cpp:62`, `threaded_task_runner.cpp:216-248`); workers pop best-first
  and re-check `is_cancelled()` immediately before running (`threaded_task_runner.cpp:332`).
- ⇒ "standing-over first, then the ring around us" is already the engine's behaviour at 5 Hz.

### 3.2 GDScript-reachable steering today

- **Viewer position** is the priority origin. One global `VoxelViewer` rides the player
  (`module_world.gd:2515-2538`). **Correction to the walk-perf doc:** `FP_VEL_PREDICT` /
  `vel_lead()` only lead facet promote/commit distances (`cube_sphere.gd:355`,
  `world_manager.gd:2007,2059`) — **the viewer node is never offset; engine streaming has zero
  velocity awareness today.** (`FP_VIEWER_LOOKAHEAD` from PERF-NEXT §2.3.2 was never shipped.)
  This is a free lever → R9.
- **Per-slot `max_view_distance` ramps** (`_ramp_pool_step`, `module_world.gd:426-471`) + the
  `StreamLoadController` pace — the demand shaper → R2 hooks here.
- **Multiple viewers** are supported (union of boxes; min-distance priority,
  `priority_dependency.cpp:21-27`; `spike_static_viewer` proves mechanics,
  `module_world.gd:2129-2141`). The "exactly ONE viewer ever" rule (`module_world.gd:1550`) is a
  design comment, not an engine constraint — R6 amends it knowingly.

### 3.3 Dropping: what exists, what is dead weight, what needs the patch

- **Auto-drop is unreachable at our scales:** a queued task self-cancels only beyond a radius
  **baked at request time** as `2·highest_view_distance + 2·block_radius`
  (`voxel_terrain.cpp:908-912`, `voxel_engine.cpp:351`) ≈ 312 blocks at view 128. Shrinking the
  view distance later does not shrink already-queued tasks' baked radii.
- **Box changes discard results, not work:** blocks leaving the data box are pruned from
  `_blocks_pending_load` and erased from `_loading_blocks` (`voxel_terrain.cpp:1494-1520`), but a
  submitted task **runs to completion** and its result is dropped on arrival
  (`voxel_terrain.cpp:1645-1648`). Each stale task burns a worker-slot × 130–173 ms.
- **The cancellation primitive exists, unwired:** `TaskCancellationToken`
  (`util/tasks/cancellation_token.h`) is honoured by `GenerateBlockTask::is_cancelled()`
  (`generate_block_task.cpp:177-185`), but `VoxelTerrain` always passes an empty token
  (`voxel_terrain.cpp:951`; the generator path never sets `params.cancellation_token`).
- ⇒ **R4 (patch 0007):** token per `LoadingBlock`, cancelled where `_loading_blocks.erase`
  fires (§9.7). **No-rebuild decision gate first:** `dropped_block_loads` is already in
  `get_statistics()` (`voxel_terrain.cpp:608`) — T1 puts it in telemetry; if stale arrivals are
  <5 % of completions during SW-1's moving legs, R4 isn't worth its rebuild (expect 10–30 %).
- **Optional P-DROP-LIVE** (~5 lines): read `shared->highest_view_distance` live in
  `evaluate()` instead of the baked copy → a GDScript view-distance shrink becomes an engine-side
  queue flush within ≤200 ms. Only wanted if R5 ships; bundle into patch 0007 if so.

### 3.4 Engine-fixed (and mostly not worth patching)

Per-block priority classes (band2 is compile-time), direction weighting in `evaluate()`
(ViewersData carries positions only — a direction-boost patch is R6's fallback), submission-order
control (irrelevant; the 200 ms sort imposes order). Task granularity is fixed at one block —
whole-column-stack tasks would need deep engine surgery; R1c+R8 capture most of that value
script-side.

---

## 4. The scheduling model

Four visual tiers, one contract each; a mode machine moves budget between them.

```
T0  SACRED     standing 3×3 column stack to −40 + committed-imminent ridge band
               → never shed, never cancelled; ~10–20 blocks
T1  VOXEL      full-res near field (128 active / 96 neighbour, ramped), R1-cheap interiors
               → nearest-first by the engine's 200 ms resort; the ONLY tier the player may outrun
T2  SKIN       profile-only relief tiles, 1–2-block pitch, sunk, disc to 256 (§5)
               → dedicated thread; must never lag the player by more than ~2 s
T3  FAR RING   whole-planet coarse relief + backstop (shipped) → static, unoutrunnable
```

**Scarcity contract:** physics — never outrun (analytic, by construction). T3 — never (static).
T2 — repaints incrementally; its worst case (full-disc rebuild) is ~1–2 s. T0 — ~0.3–0.8 s at
today's supply, less after R1. **T1 may be outrun**, and outrunning it degrades to "slightly
sunken exact-silhouette ground" instead of a hole — the honest best under permanent scarcity.

- **R2 `FP_LAZY_NB` (user #3):** non-imminent neighbour-slot ramps hold pace 0 until the active
  field is saturated (`vox_gen` below a hysteresis band, §9.3). The committed imminent slot is
  exempt (keeps `CTRL_IMMINENT_COMMIT_PACE`, `module_world.gd:460-468`) — the crossing keystone
  is untouched. Expected: walking demand 90–100 → ~30–45 blocks/s ⇒ with R1, **backlog stops
  growing at walking speed**.
- **R9 `FP_IDLE_LEAD` (invented; the addendum's "speculative pre-generation"):** offset the
  *engine viewer* (not the facet-commit distances) along velocity by
  `lead = min(K·speed, 48) · idle_factor`, `idle_factor = 1 − clamp(vox_gen/150, 0, 1)`,
  exp-smoothed (τ≈0.5 s). The idle scaling resolves the classic tension: lead only spends the
  *spare* budget (settled state is 60 fps — there is headroom); under load the viewer snaps back
  to the player so T0 keeps absolute priority. Zero memory; ~15 lines (§9.4).
- **R5 `FP_SPRINT_SHED` (user #4a policy half):**
  `NORMAL→SPRINT: speed>6.0 vox/s sustained 0.5 s AND vox_gen>200` → active view_target ramps to
  80 (skin covers 80–256), non-imminent pace 0, box-diff cancellation (R4) flushes;
  `SPRINT→NORMAL: speed<3.5 sustained 2.0 s` → ramped regrow. Thrash guards: the backlog entry
  condition (shed only when drowning — cancelling loses ~nothing), asymmetric thresholds, 2 s
  dwell. Ships only if R1–R3 leave sprint janky.
- **R6 `FP_GAZE_VIEWER` (user #4b):** second small viewer at `player + look·L` (L≈48–64,
  r≈32) — looked-at blocks jump the queue while under-feet keeps absolute-nearest rank (beats
  offsetting the main viewer, which trades T0 away). Cost: the union box adds demand — ships
  after R1+R2 headroom exists, pre-registered kill rule on M4.

---

## 5. The skin tier (R3 `FP_SKIN_TIER`) — the 256-constraint answer

### 5.1 What it is — and why it is not the removed near-LOD

A per-facet grid of relief tiles: 64×64-block patches sampled from the faceted profile at 1–2
block pitch (heights + `FarPalette` colours, water clamped to sea level as
`facet_far_ring.gd:397` does), min-biased and **sunk ~1.5 blocks** so voxel meshes always
overdraw (the proven `FP_FARRING_FULL_COVER` contract at ~25× finer pitch), covering the disc to
256, repainted incrementally. Today's 128→256 cover is the backstop at ~12.6-block cells
(`BACKSTOP_CELLS := 16`, `cube_sphere.gd:217`) / 50-block cells off-facet (`CELLS := 4`,
`facet_far_ring.gd:19`) — coverage exists; the skin is the fidelity upgrade.
The **removed** near-LOD (`FP_NO_NEAR_LOD`, user's call) was coarse LOD-ℓ voxel megablocks —
wrong-scale cubes next to the real field. The skin is exact-height 1× surface relief: the far
ring's representation, not the LOD mesher's; it resurrects nothing. Known deltas at pitch 1–2:
no trees, no carve mouths, stepped instead of SHARP-SLOPE cells — all ≥ 96–128 blocks from the
eye and overdrawn as T1 arrives. (v2 option if tree absence reads badly: instanced impostor
trunks from the TreeGen column hash — deferred, own flag.)

### 5.2 Cost and ledger

- Sampling: profile ≈ 2.29 µs/col + colour lookup, **no `resolve_cell`** ⇒ ~40–60× cheaper per
  column than voxel gen; per covered *area* vs a depth-40 voxel stack ≈ **50–100×**. One 64×64
  tile @2-block pitch = 33² samples ≈ 2.5 ms native ≈ 15–25 ms web; full 256-disc ≈ ~50 tiles ≈
  **1–2 s on ONE dedicated GDScript thread** (the `FacetLodBuilder` pattern,
  `facet_lod_builder.gd:1-60`, proves frozen-table profile reads are thread-safe off-main). The
  voxel workers never see the skin.
- Memory (**NEVER-OOM ledger**): positions+colours grid mesh (`facet_far_ring.gd:333`
  precedent): @2-block pitch ≈ 30 KB/tile; @1-block ≈ 118 KB/tile. Proposal: 1-block pitch inside
  r<176, 2-block beyond → **~3–4 MB steady; explicit ceiling 8 MB; tile ring-buffer hard cap;
  default OFF until the wasm-heap instrument (task #5) lands** — the one memory-costly item here.
  A blocky-step variant (vertical skirts) costs 4–6× vertices (~12–20 MB) — A/B-only fallback if
  the smooth skin reads badly, not the default candidate.

### 5.3 What it buys

Time-to-cover-256 at spawn/crossing: today the near field alone is a 1 300–1 400-block backlog at
26–34 blocks/s ≈ **40–55 s** (and 128–256 never exceeds backstop fidelity); with the skin ≈
**1–2 s to exact-silhouette cover of the full disc**. Sprint holes become "sunken correct-shape
ground". And it is the precondition for R5's radius shed and the U2 near-radius knob (§6).

---

## 6. The trick catalogue (addendum deliverable: assess + invent)

**Adopted — each is a plan item:** R1 column bulk (§2.3), R1b air ceiling, R1c provable-deep
skip (§2.4), R7 blob stamping (§2.5), R2 lazy neighbours, R9 idle velocity lead, R3 skin tier,
R4 cancellation patch, R5 sprint shed, R6 gaze viewer.

**Adopted as user-decision knobs (need taste sign-off, all cheap):**

- **U1 — adaptive fog:** thicken distance fog slightly while backlog is high / in SPRINT so
  pop-in resolves inside haze (draw-distance fog is the genre-standard mask). One curve on the
  existing environment fog; flag `FP_ADAPTIVE_FOG`; judged on screenshots.
- **U2 — forward-biased coverage / near-radius trade (needs R3 live):** replace the single
  128-disc with base viewer r=96 + forward viewer r=64 at +48·v̂: **−18 % demand area** with
  *more* forward reach (112+), rear covered by skin. Or simply active 128→96 (−44 % area). Both
  change the sideways/rear look (skin instead of voxels at 96–128) — the t=5 s screenshot A/B is
  the decision artifact.
- **U3 — downward-reach trim:** `VIEWER_DOWNWARD_REACH_BLOCKS` 40→24 (fewer underground layers
  streamed; lazy-deepen on dig). Small after R1/R1c; keep in pocket.

**Assessed and REJECTED (with the reason, so they stay dead):**

| trick (incl. addendum candidates) | verdict |
|---|---|
| Progressive in-place refinement (cheap block now, refine when idle) | Mechanically possible (`VoxelTool.paste` rewrites + remeshes; interior-only changes produce an identical mesh → no visible pop) — but **superseded**: R7 makes the cheap path byte-exact, and dig-time regen already covers the pre-R7 window. Refinement would spend scarce supply on invisible work — the exact sin R1 removes. |
| Coarse-stride profile + interpolation where smooth | The profile is noise; an exactness guard requires full-resolution sampling to verify — self-defeating. Striding is legitimate only where approximation is by design: the skin (R3) already does it. |
| Reuse/symmetry across facets | Terrain fields are facet/fid-hashed on the true global column — no symmetry exists to exploit. Cross-block reuse within a facet is R1c/R8's territory. |
| Cache generated blocks across facet re-designations | Memory class (≈8 KB/block ⇒ MBs for a useful set) versus a benefit only on cross-back patterns; deterministic regen at post-R1 cost beats the ledger. |
| Occlusion-based deferral (skip blocks hidden by nearer terrain) | Re-affirmed dead: over a 128-block radius on R=3072 the horizon drops ~2.7 blocks — nothing is hidden (`COSMOS-PERF-NEXT-ARCHITECTURE.md` §2.1); CPU occlusion costs wasm cycles to cull work we don't have. |
| Skip/deprioritize blocks behind the player | The engine streams a box; union viewers can only ADD coverage, not subtract rear. The honest form is U2's forward-biased composition (smaller base + forward bubble). A rear-shrink patch would fight the 200 ms resort for marginal area. |
| Per-frame budget tuning, more workers, 64³ mesh blocks, 256 full-res, 2D-noise-for-speed, VoxelLodTerrain, WebGPU-now | All previously measured/adjudicated dead ends — verdicts unchanged (`COSMOS-WALK-PERF-DESIGN.md` §3/§4). |

**Conditional:** **R8 — per-worker persistent column-profile memo** (the GEN-EFFICIENCY Fix B
that was rightly skipped at <1 %): after R1 the profile pass *is* the bulk-block cost, so the
economics flip — but R1c (stateless) captures the deepest layer first. Revisit only if T1 shows
the profile pass >25 % of post-R1 worker time; mechanism already designed
(`COSMOS-GEN-EFFICIENCY-DESIGN.md` Fix B retained detail).

---

## 7. Ranked plan

All flags in `godot/src/cosmos/cube_sphere.gd`, `const`, default **OFF**, OFF == byte-identical;
FLAT `verify_feature` 6035/0 must hold (6056/0 orbital).

| # | change | expected effect (number to beat) | flag / patch | NEVER-OOM | integrated kill metric (§8) |
|---|---|---|---|---|---|
| **T1** | telemetry: per-class gen timer, `dropped_block_loads`, skin counters | verifies §2.3 mix; R4 go/no-go stale share | none (additive) | n/a | instrument |
| **R1** (+b,c) | column bulk + air ceiling + provable-deep skip | **supply ×~2–2.5 (23–35 → 50–80 blocks/s)** | `FP_COLBULK` | zero | M4 −50 %+, supply ×≥1.8; FP_BULK truth gates green |
| **R2** | lazy neighbour ramps | walking demand → ~30–45/s ⇒ **backlog flat at 3.4 vox/s** | `FP_LAZY_NB` | zero | M4 stops diverging on walk leg; crossing worst_ms no regression |
| **R9** | idle velocity lead on the viewer | ahead-of-player first-mesh latency −30 %+; M5 − during walk | `FP_IDLE_LEAD` | zero | M5/M1 improve, M4 flat (lead must not add net demand) |
| **R3** | skin tier | **time-to-cover-256 ≈ 45 s → ≤3 s (M3)** | `FP_SKIN_TIER` | **+3–4 MB, ceil 8 MB, OFF until heap instrument** | M3 ≤3 s AND M1/M2 unchanged-or-better; t=5 s screenshot |
| **R4** | P-CANCEL engine patch | reclaim measured stale share (**+10–30 % effective supply while moving**) | patch 0007 | zero | stale arrivals → ~0; M1/M2 no regression |
| **R7** | blob stamping (byte-identical underground) | gate-failed class ~1–3 → ~0.8–1.5 ms AND loss class retired | `FP_STAMP` | zero | hard equality gate (stamp == per-cell, N random blocks); supply not worse than R1 |
| **R5** | sprint shed control law | sprint-leg M1 19.2 % → <8 % | `FP_SPRINT_SHED` | zero | sprint M1 <8 % AND M4 recovers ≤10 s post-stop AND M5=0 |
| **R6** | gaze viewer | crosshair time-to-mesh −30–50 % at equal M4 | `FP_GAZE_VIEWER` | ~zero (bounded union box) | kill if M4 worsens >10 % |
| **R8** | per-worker profile memo | conditional (§6) | `FP_GEN_PROF_MEMO` | bounded dict (cap+evict) | only if T1 shows profile >25 % post-R1 |

The `WALK-PERF` ladder (L3 allocation diet, L5 C++ port) stays orthogonal; **re-decide L5 after
R1+R7 land** — they remove exactly the work L5 would port.

**Staging:** S1 = T1 (deploy, measure mix + stale share) → S2 = R1(+b,c) → S3 = R2 + R9 (one
deploy; both tiny) → S4 = R3 (behind heap instrument) → S5 = R4 (batch patch 0007 with the
task-#5 heap-stat line; one rebuild) → S6 = R7 → S7 = conditionals (R5/R6/R8, U1–U3 by user
taste). Each stage ships alone, measured on SW-1 before the next.

---

## 8. Measurement protocol — integrated, un-conditionable (the L4b lesson)

L4b's error: conditioning stats on `vox_gen>200` rewarded configs that stream worse for longer.
Every metric below is an integral over a **fixed scripted route**, unconditioned — jank per
frame × time spent janky lands in one number.

**SW-1 route (remote-drive, repeatable):** fresh reload → stand 10 s → walk straight 90 s held-W
(~3.4 vox/s) → stop 30 s → 360° look 15 s → sprint 30 s → stop 30 s. Same spawn, same heading.

| metric | definition | catches |
|---|---|---|
| **M1** | % of 250 ms windows with `worst_ms > 100`, whole route | freeze frequency (the complaint) |
| **M2** | fps p10, whole route, unconditional | sustained smoothness |
| **M3** | seconds from reload to ≥99 % visual cover of the 256-disc (skin tile present OR `is_area_meshed`), + screenshots at t=5/15/45 s | the 256-quickly constraint |
| **M4** | `∫ vox_gen dt` over the route + time-to-drain-to-50 after each stop | **the L4b killer** — quality-for-throughput trades explode M4 |
| **M5** | hole-windows: forward screenshot probe shows void/backstop-through | the see-through class |

Ship rule: an item lands only if its named kill metric improves **and no other M regresses
>10 %**. L4b replayed here: N=3 slightly improves M1/M2, M4 diverges on the walk leg → rejected
automatically.

---

## 9. Implementation change map (Opus builds from this section)

General rules: every flag is a `const bool := false` in `cube_sphere.gd` with a doc-comment
pointing at this file's section; OFF paths must be textually unchanged (byte-identity by
construction, not by testing); all new telemetry fields are additive; run
`docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script
res://src/tools/verify_feature.gd` after every stage (must stay 6035/0 flags-off).

### 9.1 T1 — telemetry (no flag)

- `godot/src/world/voxel_module/module_world.gd`, `_make_generator` source string: add to the
  generated class vars `var gen_us := PackedInt64Array()` (size 4) + `var gen_ct :=
  PackedInt64Array()` (size 4) — classes: 0=air/early-out, 1=whole-block bulk, 2=underground
  per-cell, 3=surface-crossing. In `_generate_block`, `Time.get_ticks_usec()` at entry; at each
  `return` / loop end, add the delta into the class bucket (classification: early-outs → 0; the
  `buffer.fill` return → 1; else `oy+size.y <= min_h` → 2 else 3). Cross-thread reads of these
  arrays are the same tolerated-tearing class as the E9 pattern — document that in the comment.
  Expose `func gen_stats() -> Dictionary` on the generator.
- `godot/src/net/remote_bridge.gd` `_send_telemetry` (~:437-467): add
  `vox_dropped` = active terrain `get_statistics()["dropped_block_loads"]` (and its per-tick
  delta), plus the generator class buckets (via a new `module_world.gd`
  `func gen_class_stats() -> Dictionary` summing over the active + pool generators), plus
  (post-R3) `skin_tiles`, `skin_cover_pct` from `FacetSkin.stats()`.

### 9.2 R1/R1b/R1c — `FP_COLBULK` (all inside the `_make_generator` source string)

- `cube_sphere.gd`: `const FP_COLBULK := false`. The generated source reads it via the same
  loader-injected pattern as `fp_bulk` (find every site the loader sets `fp_bulk` on a generator
  instance and mirror it with `fp_colbulk`).
- `terrain_config.gd`: new `const MIN_SURFACE_Y := <derived>` next to `MAX_SURFACE_Y`, derived
  the same way its upper twin was (worst-case negative amplitude sum of the height stack); add a
  verify assertion sampling ≥10⁴ random columns across biomes asserting
  `height_at ≥ MIN_SURFACE_Y` (mirror the existing MAX assertion in
  `godot/src/tools/verify_feature.gd`). **If no clean bound derives, drop R1c** (doc §11) — R1
  and R1b stand alone.
- In `_generate_block`, guarded by `fp_colbulk and s == 1 and flat_world` **and** the same
  `interior` predicate the whole-block fill uses (`FacetAtlas.cell_interior_scaled(gen_facet,
  ox, oy, oz, size.x)` when `gen_facet >= 0`, hoisted once per block before the emit loop):
  1. **R1c pre-pass** (before the profile pass): if `oy + size.y <= MIN_SURFACE_Y −
     BULK_MAX_FILLER and oy >= BULK_BEDROCK_TOP_Y` → emit the deep material by y-band: at most
     two `fill_area` calls (stone for the y>−16 portion, deepslate for the y<−24 portion) plus a
     per-cell loop over only the −24..−16 dither rows (via `resolve_cell` — correctness first;
     optimize the dither rows only if T1 says they matter); `return`. (When `FP_STAMP` is also
     on, run §9.6 stamping before returning.)
  2. **Emit-loop split** (replaces the unconditional `for y in range(size.y)` body per column):
     ```
     var deep_top = g - BULK_MAX_FILLER                  # world-y; cells strictly below are deep
     var col_hi   = <R1b ceiling, item 3>                # one past the last cell to resolve
     # deep run: [oy, min(by_top, deep_top)) minus the dither band −24..−16 and bedrock rows
     #   → fill_area per contiguous run (stone / deepslate); dither + bedrock rows per-cell
     # exact band: [max(oy, deep_top), min(by_top, col_hi)) → the existing per-cell body, verbatim
     # above col_hi: skip
     ```
     `fill_area(arid, Vector3i(x, y0−oy, z), Vector3i(x+1, y1−oy, z+1), ch)` — **buffer-local**
     coordinates (same convention as the existing `set_voxel` writes). Compute
     `srun = TerrainConfig.slope_run_of(...)` **only if** the exact band is non-empty (move the
     existing call inside that condition — the only structural change flag-on).
  3. **R1b ceiling:** for interior columns (`x in 1..size.x−2 and z in 1..size.z−2`):
     `col_hi = min(by_top, max(profs 3×3 max + max_above, sea) + 1)`; edge columns:
     `col_hi = by_top` (unchanged). Precompute the per-column 3×3 max in one pass over `profs`.
- **Gates:** (a) flags-off textual identity; (b) flag-on: extend the existing FP_BULK truth
  verify with a COLBULK case asserting, for N random blocks: every *exact-band* cell equals
  per-cell `resolve_cell`, every deep-run cell equals its fill material class, and
  `block_id_at` unchanged everywhere (physics ground truth); (c) the no-fall-through invariant
  is untouched (the analytic path never reads the buffer) — keep the existing
  `height_at == worker surface` sample assert green.

### 9.3 R2 — `FP_LAZY_NB`

- `cube_sphere.gd`: `const FP_LAZY_NB := false`, `const LAZY_NB_OPEN_BACKLOG := 64`,
  `const LAZY_NB_CLOSE_BACKLOG := 150`, `const LAZY_NB_SUSTAIN_S := 1.0`.
- `godot/src/world/stream_load_controller.gd`: add `func lazy_open() -> bool` — true once the
  backlog it already reads has been `< LAZY_NB_OPEN_BACKLOG` for `LAZY_NB_SUSTAIN_S`; stays open
  until backlog `> LAZY_NB_CLOSE_BACKLOG` (hysteresis both ways; state advanced in the existing
  controller tick, `CTRL_TICK_S` cadence).
- `module_world.gd` `_ramp_pool_step` (~:426-471), at the site that already special-cases
  `up_fid == _imminent_fid` (`:460-468`), AFTER the imminent floor (exemption wins):
  ```
  if CubeSphere.FP_LAZY_NB and up_fid != _imminent_fid and _load_ctrl != null \
      and not _load_ctrl.lazy_open():
      pace = 0.0
  ```
- **Gates:** flags-off identity; flag-on SW-1 crossing legs — the imminent slot must still
  prefill (compare `pool_view` ramps in telemetry) and crossing worst_ms must not regress.

### 9.4 R9 — `FP_IDLE_LEAD`

- `cube_sphere.gd`: `const FP_IDLE_LEAD := false`, `const IDLE_LEAD_K := 2.0`,
  `const IDLE_LEAD_MAX := 48.0`, `const IDLE_LEAD_BACKLOG := 150.0`,
  `const IDLE_LEAD_TAU_S := 0.5`.
- `module_world.gd`: in `attach_viewer` (:2515), when the flag is on call
  `(_viewer as Node3D).set_as_top_level(true)`; add
  `func update_viewer_lead(player_pos: Vector3, vel: Vector3, backlog: int, dt: float)`:
  ```
  target = vel.normalized() * minf(IDLE_LEAD_K * vel.length(), IDLE_LEAD_MAX) \
           * clampf(1.0 - backlog / IDLE_LEAD_BACKLOG, 0.0, 1.0)   # Vector3.ZERO if vel ~ 0
  _lead = _lead.lerp(target, 1.0 - exp(-dt / IDLE_LEAD_TAU_S))
  _viewer.global_position = player_pos + Vector3(0, <clamped offset y, as :2538>, 0) + _lead
  ```
  Flag off: viewer stays a plain child — today's code untouched.
- `world_manager.gd`: call it each physics frame from the per-frame pass that already computes
  `_player_speed`, passing the controller backlog.
- **Gates:** flags-off identity; flag-on: M4 flat on SW-1 (the lead adds no *net* demand — the
  trailing box edge unloads what the leading edge adds), M5/first-mesh-ahead improves.

### 9.5 R3 — `FP_SKIN_TIER`

- New file `godot/src/world/facet_skin.gd` (`class_name FacetSkin extends Node3D`), modeled on
  `facet_lod_builder.gd` (thread/queue/done-drain shape) + `facet_far_ring.gd` (mesh emission):
  - consts: `TILE_BLOCKS := 64`, `PITCH_NEAR := 1` (r<176), `PITCH_FAR := 2`, `SINK := 1.5`,
    `COVER_R := 256.0`, `EVICT_R := 320.0`, `MEM_CEIL_MB := 8`.
  - one persistent `Thread` + `Semaphore`; job = (fid, tile_i, tile_j, pitch). The worker
    samples `TerrainConfig.column_profile(x, z, TerrainConfig.GenCtx.new(0, fid))` per vertex —
    the exact voxel-worker call path (frozen-table thread safety per the FacetLodBuilder
    precedent) — min-of-5-taps bias (vertex + 4 half-pitch offsets), radial sink by `SINK`,
    colour = `FarPalette.color_for(g, biome, t, g < SEA_LEVEL)`; builds positions+colors
    PackedArrays (no normals — `facet_far_ring.gd:333` precedent) and returns via the
    done-queue; the main thread wraps them in an ArrayMesh + ONE shared unshaded vertex-colour
    material and parents them in the same planet-frame the far ring renders in (tile vertex
    positions via the `facet_planar_corner` bilinear recipe, `facet_far_ring.gd:178-191`).
  - scheduling: wanted-set = tiles intersecting the `COVER_R` disc around the player (player
    pos + active fid pushed in per frame by WorldManager); build **nearest-first, re-picking the
    nearest pending job at each dequeue** (queue ≤ a few hundred; O(n) scan is fine); evict
    beyond `EVICT_R` (free mesh + arrays); maintain a running byte estimate (verts × 28)
    enforced against `MEM_CEIL_MB` — at ceiling, evict farthest before building nearer.
  - `func stats() -> Dictionary` → `{tiles, bytes, cover_pct}` for T1/M3.
- `world_manager.gd`: create next to the far-ring creation site when `CubeSphere.FP_SKIN_TIER`;
  per-frame `skin.update(player_world_pos, active_fid)`; forward crossing redesignations the
  same way the far ring receives them.
- **Gates:** flags-off identity (node never created); flag-on: M3 ≤ 3 s on SW-1; M1/M2 within
  10 % of flag-off; heap delta within ledger via the task-#5 instrument; t=5 s screenshot A/B
  for the user. Sink-order sanity: `SINK` must be strictly less than the FULL_COVER backstop's
  sink so the layering reads skin-over-backstop-under-terrain — read the backstop sink constant
  and assert the ordering in a comment at the const.

### 9.6 R7 — `FP_STAMP`

- `terrain_config.gd`: factor the blob-parameter derivation out of `_strata_at`/`_ore_at` into
  statics both paths share (byte-identity by construction):
  - `static func strata_blob(lx, ly, lz) -> PackedInt32Array` returning
    `[exists, cx, cy, cz, r, variant_id]` — exactly the hashes at `:1999-2015`; re-implement
    `_strata_at` as: lattice cell → `strata_blob` → sphere test → deepslate-dominance rule
    (`:1985-1990`). Output must be byte-identical (covered by the equality gate below).
  - `static func ore_blob(lx, ly, lz) -> PackedInt32Array` (`:2027-2040` hashes) and
    `static func ore_type_at(cy, biome, c, lx, ly, lz) -> int` (wrapping `_pick_ore`);
    re-route `_ore_at` through them identically. `_ore_density` is already a callable static.
- Generator source (`FP_STAMP` requires `FP_COLBULK`; assert at load): after each deep-run fill
  (§9.2) and after the R1c / whole-block fill, stamp **into the filled deep region only**:
  ```
  for each strata lattice cell overlapping the block (16³ pitch):
      b = TerrainConfig.strata_blob(lx,ly,lz);  if !exists: continue
      for cells in blob-sphere ∩ block ∩ deep-region:
          apply variant per the dominance rule (host stone above −16 / deepslate below −24;
          skip dither rows −24..−16 — they were emitted per-cell)
  for each ore lattice cell overlapping the block (6³ pitch):
      b = TerrainConfig.ore_blob(...);  if !exists: continue
      per COLUMN in blob bbox ∩ block: ore = TerrainConfig.ore_type_at(cy, profs biome, profs c, …)
      per cell in sphere ∩ deep-region: if TerrainConfig._ore_density(ore, y) > 0:
          write _ORE_STONE/_ORE_DEEP variant per the cell's host
  ```
  Stamp order = the per-cell precedence: base fill → strata → ore (`resolve_cell` runs
  `_deep_family` then `_ore_at`; ore replaces stone/deepslate hosts only,
  `terrain_config.gd:2024-2026` — read `resolve_cell`'s exact call order before coding and
  mirror it; note the ore host must be the *post-strata* material where strata stamped stone
  variants — check whether `_ore_at`'s host test sees the strata variant (it does: host ≠
  stone/deepslate → returns host) and replicate: **cells stamped with a strata variant are NOT
  ore-hosts** unless the variant is stone/deepslate itself).
- **Gate (the whole point):** a verify pass generating N ≥ 64 random blocks both ways
  (per-cell vs fill+stamp) asserting **byte equality of every cell**, spanning depth bands
  (above −16 / dither / below −24 / near bedrock) and facet-interior positions. Plus flags-off
  identity.

### 9.7 R4 — engine patch 0007 (`docker/engine/patches/godot_voxel/0007-cancel-on-unview.patch`)

- `terrain/fixed_lod/voxel_terrain.h`: add `TaskCancellationToken cancellation_token;` to
  `LoadingBlock`.
- `voxel_terrain.cpp`:
  - creation site (`process_viewer_data_box_change`, the "First viewer to request it" branch,
    ~:1550-1558): `new_loading_block.cancellation_token = TaskCancellationToken::create();`
  - unview site (~:1494-1520, where refcount hits 0 before `_loading_blocks.erase`):
    `loading_block.cancellation_token.cancel();`. Also the wholesale `_loading_blocks.clear()`
    sites (`:699`, `:735` region): iterate and cancel each before clearing.
  - `send_data_load_requests` / `request_block_load` (:915-976): add a
    `TaskCancellationToken` parameter; at the call site look up the `_loading_blocks` entry for
    `block_pos` and pass its token; plumb into `LoadBlockDataTask` (replacing the empty token at
    :951) and into `params.cancellation_token` for the generator path (:960-972).
  - optional P-DROP-LIVE (bundle only if R5 is planned): compute the drop threshold in
    `PriorityDependency::evaluate` from `shared->highest_view_distance` live instead of the
    baked `drop_distance_squared` (keep the baked field as fallback if `shared` is null).
- Batch with the task-#5 heap line (`mem["wasm_heap"] = emscripten_get_heap_size()` under
  `__EMSCRIPTEN__` in the stats patch) — **one 24-min rebuild for both**.
- **Gates:** native `verify_feature` (the patch affects native + web alike); SW-1 before/after:
  T1's stale-arrival delta → ~0 while moving; no M regression. Race note for the reviewer: the
  token is an atomic-bool shared_ptr designed for cancel-vs-complete races
  (`cancellation_token.h`); the drop path already tolerates late arrivals
  (`voxel_terrain.cpp:1619-1637`).

### 9.8 R5 / R6 (compact — build only if their §7 trigger fires)

- **R5 `FP_SPRINT_SHED`:** state machine in `world_manager.gd`'s per-frame pass (it owns
  `_player_speed` and the controller): consts `SPRINT_V_IN := 6.0`, `SPRINT_V_OUT := 3.5`,
  `SPRINT_T_IN := 0.5`, `SPRINT_T_OUT := 2.0`, `SPRINT_BACKLOG_MIN := 200`,
  `SPRINT_VIEW := 80.0`. On enter: `module_world.set_sprint_shed(true)` — active slot
  `view_target` → `SPRINT_VIEW` (a shrink applies on the next box diff), non-imminent pace
  forced 0 (composes with R2's gate). On exit: restore; the existing ramp regrows. Requires R3
  on (skin covers 80–256); R4 makes the shrink actually free workers.
- **R6 `FP_GAZE_VIEWER`:** `module_world.gd` — second `VoxelViewer`, `view_distance := 32`,
  `requires_collisions = false`, top-level; per-frame
  `global_position = player + look_dir * GAZE_LEAD (48)` (camera basis passed via
  WorldManager). Amend the one-viewer comment at `module_world.gd:1550` to name this flag as
  the sanctioned exception. Pre-registered kill rule: M4 +10 % ⇒ revert.

---

## 10. SOTA (what ports to godot_voxel 1.4.1 + WebGL2 + 6 workers @130 ms/block)

| source | technique | verdict here |
|---|---|---|
| **Minecraft (Java) ticket system** | chunk tickets with levels; level = generation stage (border→full) and lifetime | §4's tiers ARE a ticket system (T0 inner / T1 full / T2 skin-stage; R2 = level gating). Staged chunk status ("surface-only exists as a stage") is R1's insight at scheduling level. Ports conceptually; implemented as radii+pace, not per-chunk state. |
| **Minecraft/Bedrock load order** | nearest-first spiral; Bedrock favours the view frustum | Nearest-first: engine-native (§3.1). Frustum-favoured: R6, no engine change. |
| **Distant Horizons "Distant Generation"** | far LODs generated **heightmap-only**, never full chunk gen; separate cheap render path; accepted failure mode = outrun → soft pop-in | Strongest external validation of R3 (skin = LOD-from-heightmap; `facet_profile` is our heightmap) and of §4's scarcity contract (holes never, pop-in allowed). |
| **Veloren** | `lod_terrain` from a downsampled heightmap under chunks; meshing jobs **cancelled when out of range**; nearest-first pool | Both halves port: R3 and R4. Its wgpu off-thread buffer building does not (GL compat). |
| **No Man's Sky (GDC'17)** | small resumable prioritized tasks under budgets; rings; deterministic regen | Already VOXIVERSE's architecture; confirms, adds nothing new. |
| **Sodium** | upload-duration estimates + per-frame budgets + deferral | Orthogonal mesh-apply lane, already `WALK-PERF` L6; not re-proposed. |
| **Teardown / GPU worldgen** | GPU generation / raymarch | No compute in WebGL2; godot_voxel GPU gen needs RD renderers. Does not port. |
| **Bedrock server pipeline** | dedicated per-stage threads | Does not port: 6 shared WASM workers at 10× penalty; the right adaptation is cheaper tasks (R1/R7), not more pipeline. |
| **"Generate only what the camera proves" (strict lazy)** | visibility-driven generation | Our analytic physics makes it *safe* (nothing but looks depends on gen) — R2/U2/U3 are the bounded version; full laziness rejected because turning must not cost seconds (the skin caps that instead). |

Cross-cutting: every shipping streamer pairs an **uncancellable cheap visual tier** with a
**cancellable expensive detail tier** and lets the player outrun only the latter. VOXIVERSE has
the far ring (too coarse) and the voxel field (too expensive, uncancellable). R3+R4 add exactly
the two missing properties; R1/R7 shrink the expensive tier's unit cost so the gap the cheap
tier must hide stays small.

---

## 11. Risk register

| risk | exposure | mitigation |
|---|---|---|
| R1 mix model wrong (gate-failed share smaller than assumed) | supply gain <2× | T1 ships first; R1 judged on the measured class histogram |
| R1 column fill vs ridge `junction_modify` | wrong solids beyond a ridge | whole-block `cell_interior_scaled` gate retained; straddlers stay per-cell; equality gates |
| R1 misses an undocumented deep-path feature (e.g. future caves below the filler) | wrong fills | the shipped FP_BULK gate embodies the same assumption and its truth gate is green; R1 extends the same predicate — add a note at both gates that any future deep carver must update them together |
| R7 stamp ≠ per-cell (precedence/ordering, `_pick_ore` column dependence, strata-as-ore-host) | silent world diff | the shared-derivation refactor (§9.6) + the N-block byte-equality verify are the contract; ship OFF until it passes 64/64 |
| Skin z-fight / poke-through in valleys | visual class the far ring already solved | same min-bias + sink discipline as FULL_COVER; M5 + screenshots judge |
| Skin memory on weak clients | NEVER-OOM | default OFF until heap instrument (task #5); 8 MB ceiling + ring-buffer; measured A/B |
| R2 starves neighbours → cold unplanned 90° turns | pop-in on turns | imminent machinery re-targets within one pool pass; skin covers; SW-1 crossing legs gate |
| R9 lead thrashes the data box | churn | exp smoothing (τ 0.5 s) + idle_factor → lead ≈ 0 under load; M4 gate |
| P-CANCEL races (cancel vs completing task) | crash class | atomic token built for this; late-arrival drop path already exists (`voxel_terrain.cpp:1619-1637`); native verify + web soak |
| R5 shed/regrow churn | repeated re-gen of an annulus | backlog-gated entry + 2 s dwell + ramped regrow; M4 measures the churn |
| Gaze viewer demand under scarcity | worse M4 | ships last; pre-registered M4 +10 % kill rule |
| This doc's own weakest links | — | (a) §2.3's mix is modeled, not measured — T1 exists to fix that before R1 is judged; (b) skin look at pitch 1–2 is a taste call — the t=5 s screenshot A/B is the decision artifact, not this doc; (c) `MIN_SURFACE_Y` must be *derived and asserted*, never guessed (§9.2) — if no clean bound exists, R1c is dropped and R8 takes its slot |
