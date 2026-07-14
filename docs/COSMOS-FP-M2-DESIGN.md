# COSMOS-FP-M2-DESIGN — FacetLodMesher: LOD-mesh neighbours, the SSE selector, and the end of the 5-live-terrain throughput ceiling

Status: **implementation-ready design** (Fable design gate, task #95). Realizes
COSMOS-MULTIFACET-STREAMING-REVIEW §5(b)/§6.3 (the decoupled multi-LOD blocky-mesh layer)
as milestone FP-M2, on top of the shipped FP-M1c Planet Assembly (docs/COSMOS-FP-M1-DESIGN.md,
pool + re-designation crossing, live). Every claim is grounded in file:line of branch
`feat/voxiverse-cosmos-m5`, in the FP-R0 measurements of record (`verify_fp_r0.gd`), or in
the live web telemetry quoted in §1.2.

FP-M2 must remove the **generation-throughput ceiling** that survives FP-M1c — the
border-approach jerk — by making non-imminent facets stop being live full-res VoxelTerrains
and become **true blocky meshes at screen-space-error-selected LOD**, built entirely off the
voxel worker pool. It must do so under the NEVER-OOM rule (memory safety outranks visual
quality; new memory flag-gated OFF behind a measured browser-heap A/B; explicit ceilings,
LRU, lifetime caps) and with FLAT byte-identity (6027/0) and the shipped faceted gates green
at every sub-stage.

---

## 0. Executive verdict (decisions up front)

1. **Live-terrain population: Z1-hybrid as the steady-state CEILING of a ladder** (§3).
   Every facet sits on a representation ladder — quad → ℓ3 → ℓ2 → ℓ1 → live full-res
   terrain — and **climbs it only as fast as measured main-thread headroom allows**
   (the §6.5 load-adaptive controller; the user's directive: "constantly measuring main
   thread load … never overload the main thread"). The SSE selector + pool policy set each
   facet's *target rung*; the controller sets the *pace*. The targets converge, with ample
   headroom, to: **1 active full-res terrain + 1 live full-res neighbour** (the
   imminent-crossing facet by `own_dist`, target-live inside `POOL_D_WARM` = 96 as today),
   plus **a second live neighbour ONLY when a second ridge is within
   `POOL_D_WARM2 := 48`** (the corner approach). Every other facet's ladder tops out at a
   FacetLodMesher tier (or the quad). Worst-case concurrent generation volume drops from
   FP-M1c's ≈ 2.1× single-terrain to ≈ 1.56× (corner) / 1.28× (steady walking) — the
   throughput fix — while the shipped invariant "the ridge you are about to cross is
   full-res on both sides, `redesignate` always hits the pool on the walking path" is
   preserved. Strict Z0 (zero live neighbours, promote-at-cross) is rejected as a
   *ceiling*: it saves only the last 0.28× and pays a promote-latency window +
   LOD-rendered ground under the player's feet at the exact place users test (§3.3) —
   though under sustained overload the controller's pace naturally *behaves* Z0-ward
   (holds a neighbour at a coarse rung longer) without ever stalling a frame.
2. **Build pipeline: one persistent background GDScript `Thread`** (§4) running the
   *productized* FP-R0 probe recipe — per-facet frozen generator
   (`_make_generator(fid, lod_probe=true)`, `module_world.gd:2171`) →
   `generate_block(buffer, origin, ℓ)` at stride 2^ℓ → a builder-owned
   `VoxelMesherBlocky.build_mesh(buffer, …)` → ArrayMesh — **never the voxel worker pool**
   (REVIEW risk #2). Apply on the main thread under a 2 ms/frame budget. LOD0 stride output
   is byte-identical to the shipped generator (already gate-proven, `verify_fp_r0.gd:164-167`;
   re-pinned by G-M2-ID).
3. **Shipped LOD tiers ℓ ∈ {1, 2, 3}** (`LOD_MAX_TIER := 3`); the FacetFarRing quad stays as
   the ℓ=∞ coarsest tier and the universal fallback. FP-M3 raises the tier cap to 5 for
   orbit/telescope — the selector/budgeter machinery built here already handles it (§6).
4. **Seam treatment at ℓ>0: uniform conservative EROSION + the RIDGE APRON** (§7). A
   megablock survives only if its whole s-cube footprint is interior to the facet's 4
   ridge planes; no junction sentinels are emitted at ℓ>0. At a **live↔LOD** ridge the
   live facet's carve bevel reaches the welded plane exactly and the seam reads clean —
   erosion alone suffices there. At a **LOD↔LOD** ridge, both sides retreat ≤ s and the
   resulting hairline is **NOT accepted** (user decision): it is covered by a **ridge
   apron** — a terrain-coloured strip built from the welded ring line spanning both
   sides' retreat — as PRIMARY M2b scope (§7.4). No interpenetration into live facets
   (gate-asserted), no z-fight, **no visible LOD↔LOD hairline at any tier**
   (gate-asserted). ℓ0 LOD meshes are **not shipped** — full resolution is exclusively
   the live-terrain representation.
5. **Selector = screen-space error, budgeter = request-grant** (§6). One rule
   `p = (2^ℓ·viewport_h)/(2·d·tan(fov/2)) ≤ τ` (τ := 3 px) covers walk / low flight /
   near orbit / telescope; the budgeter grants under hard caps with coarse-to-fine
   progressive refinement (first cover ≤ ~2 s at ℓ3, refined toward the granted tier when
   the build queue is idle). The selector can *request* anything; only the budgeter
   *allocates* (REVIEW risk #4).
6. **The budgeter is a CLOSED-LOOP controller on measured main-thread load** (§6.5), not a
   fixed schedule. Measured signal: EMA + worst-in-window of the main-thread frame cost
   (the PerfHUD's `proc`/`worst` monitors) with the live `vox_gen`/`vox_mesh` backlogs as
   feed-forward. Setpoint: worst frame ≤ `CTRL_FRAME_BUDGET_MS := 18` ms with margin.
   Control action: a per-tick admission credit ∈ [0, 1] that scales how much NEW work is
   admitted — LOD apply-ms, build-job grants, the pool terrains' view-ramp rate, and
   live-terrain promote admission — down to zero under load, recovering when headroom
   returns. Promotions, once granted, are paced but never yanked (anti-oscillation, §6.5.4).
   NEVER-OOM memory caps stay hard and controller-independent.
7. **Crossing = promote/demote choreography over the existing `redesignate`** (§9): the ONE
   `PlanetRoot.transform` write moves every LOD mesh rigidly (they are facet-anchored
   children); zero LOD rebuilds at a crossing (gate-asserted by a build counter). Promote
   keeps the facet's LOD mesh until the live terrain's seam band is meshed; demote builds
   the LOD mesh *before* retiring the terrain. Both directions are hole-free.
8. Everything behind **`CubeSphere.FP_M2_LOD := false`** (requires FACETED + FP_M1_POOL);
   committed OFF, flipped by sed at export (the established deploy pattern). Module render
   path only; the GDScript fallback keeps ChunkStreamer/ChunkMesher + quads, untouched.
   FLAT and curved non-faceted paths byte-identical at every stage. emsdk stays 3.1.64.

---

## 1. Ground truth

### 1.1 What ships today (FP-M1c, live)

- Planet Assembly behind `FP_M1_POOL` (`cube_sphere.gd:63`): `PlanetRoot @ T_active⁻¹`
  holding FacetSlots (`module_world.gd:1420-1439` `_pool_init_active`, `:1354-1401`
  `_pool_build_slot`), each a bounds-clamped VoxelTerrain (`_apply_bounds`,
  `module_world.gd:1406-1415`) with its own frozen-fid generator + carve mesher, sharing
  the ONE baked library and ONE global player VoxelViewer. Pool policy in WorldManager
  (`world_manager.gd:1427-1463`): spawn when a ridge `own_dist < POOL_D_WARM` (96), retire
  past `POOL_D_RETIRE` (128) after `POOL_MIN_LIVE_S` (10 s), ≤ 1 op/s, hard cap
  `POOL_MAX_NEIGHBOURS` = 4 (`cube_sphere.gd:71-77`).
- Crossing = re-designation (`module_world.gd:1483-1514` `redesignate`; called from
  `maybe_cross_facet`, `world_manager.gd:1389-1401`, with pool-miss → `pool_spawn` →
  `redesignate` → `pool_reset` ladder). Per-slot view ramps (`_ramp_pool_step`,
  `module_world.gd:373-402`, one growing slot per frame) fixed the *burst*.
- Non-pooled facets: FacetFarRing flat coloured quads (`facet_far_ring.gd`, CELLS=4,
  deferred budgeted rebuild `WARM_BUDGET_MS` = 3 ms, camera far 9000), excluded-set fed by
  `pool_neighbour_fids` via `set_pool_excluded` (`facet_far_ring.gd:71-78`,
  `world_manager.gd:1474-1475`).
- Generator stride support **already exists**: `_generate_block(buffer, origin_in_voxels,
  lod)` (`module_world.gd:2229`) strides column sampling by `s = 1 << lod` when
  `gen_lod_probe` is set (`:2233-2237`); `_make_generator(facet_override, lod_probe)`
  (`:2171`) freezes any fid. At lod 0 every `*s` is a no-op — byte-identical, gate-proven.
- Web threads (FP-M1b): PTHREAD_POOL_SIZE 16, voxel workers adaptive 3‥10
  (min 3 / ratio 0.7 / margin 1, hw clamp 14 via patch 0005), main-thread mesh-apply
  budget 6 ms/frame.

### 1.2 The measured problem (live web logs, FP-M1c deployed)

The border-approach jerk is **generation-throughput-bound, not meshing-bound**:

- `vox_mesh` backlog ≈ 0 throughout; `vox_gen` backlog **1500–2800 tasks**, draining
  **~40–100 tasks/s** (≈ 30–70 s to clear), whenever a neighbour spawns / the player moves
  near a seam. `proc` bursts 100–330 ms; `worst` frame 40–50 ms sustained during movement.
- Root cause: even bounds-clamped to its ~201²-column slab, each live terrain is a full-res
  generation *producer*, and up to **5 producers (active@128 + 4 neighbours@96)** feed ONE
  shared WASM worker pool. The FP-M1c per-slot ramp shapes the *burst*; the *steady-state
  arrival rate* of 2–5 producers still exceeds the pool's drain rate. The fix must reduce
  the **volume generated at full resolution**, not re-schedule it. That is FP-M2.

### 1.3 The cost model (FP-R0 measurements of record, `verify_fp_r0.gd:169-208`)

- One 34³ padded buffer (`generate_block` + `build_mesh`): **≈ 1.0–1.7 s at ANY ℓ**
  (native headless) — the per-column profile pass dominates (~34² = 1156 columns
  → **≈ 0.9–1.5 ms/column**; WASM ≈ 2–3× slower, ~2–4 ms/column). `build_mesh` < 1 ms.
- Therefore **per-facet build cost scales as 1/4^ℓ** (stride s samples (extent/s)²
  columns). Facet slab ≈ 221 columns across (edge ≈ 201 + 2×MARGIN_CELLS 8 + seam slack,
  `facet_atlas.gd:12-15,163-166`):

  | ℓ | stride | columns/facet | build (native) | build (WASM, ×2.5) | mesh est. |
  |---|---|---|---|---|---|
  | 1 | 2 | ≈ 12.2 k | ≈ 12–18 s | ≈ 30–45 s | ≈ 3.4 MB, ~26 k tris |
  | 2 | 4 | ≈ 3.1 k  | ≈ 3–5 s   | ≈ 8–12 s  | ≈ 0.9 MB, ~6.6 k tris |
  | 3 | 8 | ≈ 760    | ≈ 0.8–1.2 s | ≈ 2–3 s | ≈ 0.22 MB, ~1.7 k tris |
  | 4 | 16 | ≈ 190   | ≈ 0.2–0.3 s | ≈ 0.5–0.8 s | ≈ 55 KB |
  | 5 | 32 | ≈ 48    | ≈ 0.05–0.08 s | ≈ 0.15–0.2 s | ≈ 14 KB |

  (Mesh bytes: ~1.3·(201/s)² visible faces × ~4 verts × 64 B/vert + indices — the FP-R0
  vertex model, `verify_fp_r0.gd:29-30`. All to be re-measured by the G-M2-BUILD gate;
  these are planning numbers.)
- Consequences baked into this design: (a) whole-facet ℓ1 is *expensive* (~30–45 s WASM on
  one thread) → progressive refinement + idle-only fine grants (§6.4); (b) ℓ3 is the
  "instant cover" tier (~2 s); (c) a live neighbour's D_WARM band (half-disk r=96 ≈ 14.5 k
  full-res columns **on the worker pool**) costs more than an entire ℓ2 facet **off** it —
  the arbitrage the whole milestone monetizes.

---

## 2. Architecture — where FacetLodMesher sits

```
WorldManager
 └─ module_world
     └─ PlanetRoot (Node3D @ T_active⁻¹ — unchanged, the ONE crossing write)
         ├─ FacetSlot[active]      VoxelTerrain (composite = identity, editable)
         ├─ FacetSlot[imminent]    VoxelTerrain (rotated, render-only)          } §3: ≤2
         ├─ FacetSlot[corner-2nd]  VoxelTerrain (rotated, render-only, rare)    }
         └─ FacetLodMesher (Node3D @ identity)
             ├─ LodFacet_<fid> (Node3D @ facet_transform(fid))
             │    └─ MeshInstance3D per tile (scale = s, origin = tile lattice corner)
             └─ …
    FacetFarRing stays a sibling of module_world (its own T_active⁻¹, `facet_far_ring.gd:56`)
    — the ℓ=∞ tier; its excluded set = pool fids ∪ LOD-covered fids (§5.5).
```

- FacetLodMesher is a child of PlanetRoot: a crossing's single `PlanetRoot.transform`
  write re-places every LOD mesh rigidly, exactly like the FacetSlots
  (`module_world.gd:1489-1492`). LOD geometry is authored in **facet-lattice coordinates**
  and placed by `facet_transform(fid)` (`facet_atlas.gd:309-316`) — identical frame
  discipline to FP-M1c terrains; §8 proves orientation correctness.
- **Module-only.** FacetLodMesher requires `ClassDB.class_exists("VoxelMesherBlocky")`,
  a live `module_world` with its baked library, and the probe generator factory. On the
  GDScript fallback path none of this exists: the fallback keeps its ChunkStreamer/
  ChunkMesher and the FacetFarRing quads unchanged (the live web path is the module,
  `module_in_web=yes`).
- Rule-1 untouched: FacetLodMesher is render-only. `block_id_at`/`cell_value_at`, DDA,
  GroundCollider, collapse never read it; analytic physics is exactly as today.

---

## 3. THE CRUX — how many live full-res terrains survive

### 3.1 The options, quantified

Let V = the generation volume of the active facet at view 128 (its slab ∩ 128-disk).
A live neighbour at view 96, bounds-clamped beyond the shared ridge, generates roughly a
half-disk of radius 96 in its own slab ≈ 0.28 V (≈ 14.5 k columns). Per-facet LOD builds
cost per §1.3 **and run off the pool entirely** — they are free from the worker pool's
point of view.

| Option | Live terrains (steady / worst) | Pool gen volume (steady / worst) | Crossing on the walking path | Seam band under the player |
|---|---|---|---|---|
| FP-M1c (shipped) | 2–3 / 5 | 1.28 V / ≈ 2.1 V | pool hit (redesignate) | full-res both sides |
| **Z1-hybrid (chosen)** | 2 / 3 | **1.28 V / ≈ 1.56 V** | pool hit (redesignate) | full-res both sides |
| Z1 strict (cap 1) | 2 / 2 | 1.28 V / 1.28 V | pool hit mid-edge; pool-MISS at corners | full-res except 2nd corner ridge (LOD ℓ1 at ≤ 60 blocks — visible) |
| Z0 (zero neighbours) | 1 / 1 | 1.0 V / 1.0 V | **promote window on EVERY crossing** | LOD megablocks under feet until promote completes |

### 3.2 Decision: Z1-hybrid

- **Imminent neighbour** — the nearest ridge with `own_dist < POOL_D_WARM` (96) — is a live
  full-res terrain, exactly today's spawn trigger narrowed to ONE winner
  (`world_manager.gd:1441-1456` becomes "spawn only the best candidate"). Selection
  hysteresis: an incumbent is only displaced when the challenger's ridge distance is
  smaller by `POOL_SWITCH_MARGIN := 16` blocks (or the incumbent has passed `POOL_D_RETIRE`)
  — a displaced incumbent retires through the normal demote path (§9.2). `POOL_MIN_LIVE_S`
  (10 s) and the ≤ 1 op/s amortization stay in force.
- **Second live slot, corners only**: when a *second* ridge's distance < `POOL_D_WARM2 := 48`,
  its facet also spawns. Walking mid-edge this never fires (the other ridges are ≥ ~100
  away); it fires exactly on a corner approach, where the user will look across both
  ridges from close range and where a crossing might commit to either. The diagonal facet
  is **never** live (LOD/quad only) — a diagonal crossing resolves through an edge facet,
  and containment already defers corner landings (`world_manager.gd:1364-1373`).
- **Effective cap `FP2_LIVE_CAP := 2`** live neighbours (a policy const beside the POOL_*
  family in `cube_sphere.gd`; `POOL_MAX_NEIGHBOURS` = 4 stays as the unchanged hard
  backstop asserted by G-M1-POOL). With `FP_M2_LOD` OFF the policy reverts to shipped
  FP-M1c verbatim — the cap is only consulted under the flag.

### 3.3 Why not Z0, why not strict Z1

- **Z0** deletes the last 0.28 V but converts *every* crossing into a promote: a fresh
  terrain spawning at the crossing moment, streaming its seam band while the player stands
  on it. Physics is analytic (safe), but the player's ground is *rendered* as ℓ1/ℓ2
  megablocks that disagree with collision by up to 2–4 blocks — floating/clipping visuals
  at the exact moment and place (the seam) users judge the engine. It also re-introduces a
  latency race the shipped design just eliminated (FP-M1c exists *because* spawn-at-cross
  was the R2/R3 failure), and it would rewrite `redesignate`'s contract (`to` must be
  pooled) rather than extend it. The remaining 0.28 V is not the bottleneck once the other
  three neighbours stop generating: one producer's half-band at distance-priority is
  exactly the load FP-S1's gate already proved drains in ≤ ~10 s.
- **Strict Z1 (cap 1)** starves the corner approach: the second ridge's facet would be LOD
  ℓ1 at ≤ 60 blocks (selector *wants* ℓ0 there; §6.2) — 2-block megablocks and an
  apron-covered coarse seam in the player's face, and a guaranteed pool-miss
  (spawn-at-cross ladder, `world_manager.gd:1392-1401`) when the player crosses the second
  ridge. The hybrid's second slot costs 20 MB + 0.28 V *only near corners* and removes
  both artifacts.
- Degrade/upgrade dial (pre-agreed, NEVER-OOM ladder §11): if the live A/B still shows gen
  backlog > target, `POOL_D_WARM2` 48 → 0 turns the hybrid into strict Z1 (one const); if
  throughput headroom is abundant post-M1b on big machines, nothing changes — the cap is
  not adaptive (determinism over cleverness).

### 3.4 What this buys (the fix, quantified)

Worst-case producers on the pool drop 5 → 3, and the two neighbour producers are
half-bands, not full facets: worst pool volume ≈ 1.56 V vs ≈ 2.1 V shipped — and the
*common* walking case is 1.28 V with the other three ring-1 facets now costing the pool
**zero** (they are LOD meshes on the builder thread). The `vox_gen` backlog target in the
FP-M2e gate is **≤ 300 sustained** during a border approach (vs 1500–2800 measured).

### 3.5 The ladder reframe: Z-modes are ceilings, the controller is the pace

Z0/Z1/hybrid are not mode switches — they are **steady-state ceilings on a per-facet
representation ladder**:

```
quad (ℓ=∞) → ℓ3 → ℓ2 → ℓ1 → live terrain @48 → @96 (imminent) → @128 (active)
```

Two orthogonal authorities govern movement on the ladder:

- **Target rung** (WHAT the facet should be): the SSE selector (§6.1) for the LOD rungs;
  the Z1-hybrid pool policy (§3.2) for the live rungs. Targets are pure geometry/camera
  functions — deterministic, load-independent.
- **Climb pace** (WHEN it gets there): the §6.5 load-adaptive controller. Every upward
  move — a finer-ℓ build grant, a live spawn, a view-ramp growth step — is *admitted* only
  against measured main-thread headroom. Under sustained load a neighbour holds at ℓ2/ℓ1
  (or a live terrain holds its current view radius) instead of stalling the frame; when
  headroom returns, the climb resumes. Downward moves (demote, retire, view shrink) are
  cheap unloads and are never load-throttled.

The throughput arithmetic of §3.1–3.4 is unchanged — it describes the converged state
with ample headroom. What the reframe adds is the guarantee *during* convergence: the
system is never committed to a schedule the main thread cannot afford this second, on
this machine. A full-res promotion is granted only when BOTH the pool policy demands it
(imminent/corner-second) AND the controller reports sustained headroom
(`CTRL_PROMOTE_SUSTAIN_S`, §6.5); once granted it is paced, not cancelled (§6.5.4).

---

## 4. The off-terrain build pipeline

### 4.1 The job

A build job = `(fid, ℓ, tile)` → one ArrayMesh. Executed entirely on the builder thread:

1. **Generator**: per-facet frozen probe generator, created once per facet on first use and
   cached: `_make_generator(fid, true)` (`module_world.gd:2171` — `facet_override=fid`,
   `lod_probe=true` publishes `gen_lod_probe=true`, `:2213`). Identical construction to a
   pool slot's generator except the stride unlock; worker-safety inherits the frozen-epoch
   contract (frozen `gen_facet`, GenCtx per call, frozen tables — `module_world.gd:2283-2310`).
   The builder must **only** call `generate_block` on probe generators; never the 2-arg
   analytic TerrainConfig wrappers (those read main-thread mutables `_active_facet`/
   `_shape_memo` — the audit line, §14.2).
2. **Buffer**: `VoxelBuffer.create(nx+2, ny+2, nz+2)`, `set_channel_depth(0, DEPTH_16_BIT)`
   (ARIDs exceed 8 bits — the FP-R0 recipe, `verify_fp_r0.gd:186-190`). Interior dims per
   axis `n = ceil(extent/s)` capped at 32 (tile when exceeded). Origin =
   `tile_corner − (s, s, s)` so the 1-cell pad samples the neighbouring megablocks —
   correct face occlusion at tile seams within the same ℓ.
3. **Generate**: `gen.generate_block(buf, origin, ℓ)` — buffer cell (x,y,z) reads LOD0
   lattice voxel `(ox + x·s, oy + y·s, oz + z·s)` (`module_world.gd:2229-2237,2306-2310`).
   The existing early-outs apply unchanged: `MAX_SURFACE_Y`/`BEDROCK_FLOOR` constants
   (`:2269-2272`) and `block_all_air` **which already takes the stride** (`:2280`,
   `facet_atlas.gd:559-573`) — all-air / all-foreign tiles cost ~16 flops.
4. **Mesh**: the builder owns ONE `VoxelMesherBlocky` sharing the baked library
   (`spike_library` accessor pattern, `verify_fp_r0.gd:171-176`); `build_mesh(buf, [], {})`
   → ArrayMesh (< 1 ms). No carve params are pushed to the builder mesher: at ℓ>0 no
   junction sentinels are generated (§7.2), and ℓ0 is never meshed here (§0.4), so the
   carve blob is irrelevant. Should FP-R0's `build_mesh(buf, [], {})` call shape prove to
   return material-less surfaces in a live scene, the fallback is
   `surface_set_material` from the library models — FP-M2a's first gate settles this
   before any scene work (§13).
5. **Handoff**: push `{fid, ℓ, tile, mesh, tris, bytes}` onto a Mutex-guarded done-queue.

### 4.2 Tiling and the vertical span

- xz: the facet's domain slab `dom_min(fid)..dom_max(fid)` (`facet_atlas.gd:541-544`,
  MARGIN_CELLS already included) − eroded content never exceeds the polygon anyway.
- y: `[LOD_FLOOR_Y := −24, MAX_SURFACE_Y + max(TreeGen.MAX_ABOVE_SURFACE,
  SNOW_FILL_MAX_CELLS)]` — the same top the pool bounds use (`module_world.gd:1411-1412`).
  `LOD_FLOOR_Y` is a NEW analytically-proven **lower** bound on the visible surface
  (mirror of `MAX_SURFACE_Y`'s discipline, `terrain_config.gd:159-167`): min height ≈
  BASE_HEIGHT 5 + min continent offset −14 − HILLS 3 − DETAIL 1 ≈ −13, margin to −24;
  a large-sample min-assert lands in verify beside the existing max-assert. The bottom pad
  row (below −24) is generated solid → no bottom faces → no under-planet holes. This
  halves the resolve_cell work per column vs meshing to bedrock.
- Tiles per facet: ℓ1 ≈ 4×4 xz × 3 y = 48 buffers (most all-air/foreign → early-out
  cheap; ~16–20 pay the column pass); ℓ2 ≈ 2×2×2 = 8; **ℓ≥3 = 1 buffer per facet**
  (extent/s ≤ 28 ≤ 32).

### 4.3 The builder thread (pthread accounting)

- **Exactly ONE persistent `Thread`**, started when `FP_M2_LOD` && module path && FACETED,
  looping on a Semaphore-fed job queue; never spawn-per-job; `wait_to_finish` only at
  teardown. Jobs are per-tile (≤ ~1.7 s native each) so cancellation (facet evicted while
  queued) is responsive between tiles; a cancelled facet's remaining tiles are dropped at
  dequeue.
- Pool accounting (FP-M1 §9.1): worst = voxel ≤ 10 + WorkerThreadPool 2 + audio 1 +
  voxel-IO 1 + **builder 1** = 15 ≤ 16, consuming the previous spare slot. Pre-agreed
  fallback if "thread pool is exhausted" ever appears in the load gate: drop the patch-0005
  web hardware_concurrency clamp 14 → 13 (one const; voxel max 10 → 9). Gate FP-M2a
  asserts the string is absent from a live-web boot log.
- Thread-safety inventory (all already proven for 4+ concurrent voxel workers; the builder
  is one more pure reader): frozen FacetAtlas packed arrays, frozen edge tables, frozen
  noise singletons + BlockCatalog ids (warmed in `warm_up`, `terrain_config.gd:347-358`),
  frozen generator tables (`module_world.gd:2176-2224`). New objects created per job
  (VoxelBuffer, GenCtx, ArrayMesh) are thread-local. ArrayMesh construction off-main is
  supported Godot practice; the MeshInstance3D node is created/attached **only** in the
  main-thread apply step.

### 4.4 Main-thread apply

Per frame, under `LOD_APPLY_BUDGET_MS := 2.0`: pop finished tiles; on a facet's **last**
tile, atomically swap the facet's LodFacet node content (build the new MeshInstance3D set
hidden, then show-new + free-old in one frame — no partial-facet frames, no flicker).
MeshInstance transform: `Transform3D(Basis.from_scale(Vector3.ONE * s), tile_origin_lattice)`
under `LodFacet_<fid> @ facet_transform(fid)` — build_mesh outputs buffer-local unit cells,
so uniform scale s + lattice translation places megablocks exactly (§8 gate). Apply also
maintains the byte/tri ledgers (§11).

---

## 5. FacetLodMesher — class sketch

`godot/src/world/facet_lod_mesher.gd`, `class_name FacetLodMesher extends Node3D`.

```gdscript
# ---- policy consts (asserted by verify_fp_m2) ----
const LOD_MAX_TIER := 3            # shipped tiers ℓ∈{1..3}; FP-M3 raises to 5
const LOD_TAU_PX := 3.0            # SSE threshold (px per megablock)
const LOD_HYST_BAND := 0.25        # ℓ_c must cross a boundary by this to re-tier (§6.3)
const LOD_APPLY_BUDGET_MS := 2.0   # main-thread apply budget
const LOD_MAX_FACETS := 64         # hard cap: facets holding LOD meshes
const LOD_MAX_TRIS := 3_000_000    # hard cap: total triangles
const LOD_MAX_BYTES_MB := 96       # hard cap: CPU-side mesh bytes (ledger, §11)
const LOD_QUEUE_MAX_JOBS := 16     # tiles queued (not yet building)
const LOD_QUEUE_MAX_EST_S := 30.0  # est. build seconds in flight — grant admission bound
const LOD_IDLE_DEMOTE_S := 30.0    # unselected-at-tier facets demote one ℓ after this
const LOD_FLOOR_Y := -24           # proven min-visible-surface bound (§4.2)

# ---- state ----
var _cache: Dictionary        # fid -> {lod:int, node:Node3D, tiles:int, tris:int, bytes:int,
                              #          last_want_ms:int, building_lod:int|-1}
var _queue: Array             # pending jobs [{fid, lod, tile_aabb, est_cols}]
var _done_mutex: Mutex        # guards _done (builder -> main handoff)
var _done: Array
var _thread: Thread
var _sem: Semaphore
var _gen_cache: Dictionary    # fid -> frozen probe generator (built lazily, main thread)
var _mesher: Object           # builder-owned VoxelMesherBlocky (shared baked library)
var _build_count := 0         # diagnostics: total tile builds (G-M2-XPD asserts no
                              # rebuilds across a crossing)

# ---- API (all main-thread unless noted) ----
func setup(module_world) -> bool          # library + generator factory hookup; starts thread
func set_camera(cam: Camera3D) -> void    # selector input (fov, viewport_h, position)
func set_load_controller(c) -> void       # StreamLoadController (§6.5): credit scales
                                          # apply-ms + grants; promote gate consults it
func tick() -> void                       # selector + budgeter(×credit) + apply, per frame
func want(fid: int, lod: int) -> void     # selector-internal request (never allocates)
func covered_fids() -> Array              # for the far-ring exclusion merge (§5.5)
func on_promote(fid: int) -> void         # §9.1: keep mesh until terrain seam band meshed
func on_demote_request(fid: int) -> int   # §9.2: returns ticket; retire when mesh applied
func evict(fid: int) -> void              # frees node + ledgers (LRU / promote completion)
func stats() -> Dictionary                # gates + PerfHUD: counts, tris, bytes, backlog
```

### 5.1 Cache policy

One tier per facet at a time (`_cache[fid].lod`); a re-tier builds the replacement fully,
then swaps (§4.4) — the old tier is never removed first. LRU on `last_want_ms` funds
grants (§6.4); `LOD_IDLE_DEMOTE_S` proactively demotes facets the selector stopped wanting
at their tier (memory returns without pressure). Eviction frees the node subtree and
subtracts ledgers; a facet in `_cache` is by definition excluded from the far ring (§5.5).

### 5.2 Caps are load-bearing

Every const above is asserted headless (G-M2-CAPS): a scripted request storm (the
telescope burst) must leave counts/tris/bytes AT their caps with excess requests degraded
one-ℓ-coarser (never queued unboundedly, never allocated). The projection of record
(FP-R0 B2, `verify_fp_r0.gd:305-318`) already showed the 512-reach LOD layer fits well
inside these numbers (~50 MB steady per §1.3 estimates; 96 MB cap gives 2× headroom).

### 5.3 What FacetLodMesher does NOT do

No physics, no edits (LOD meshes are pure worldgen; a player crater is invisible at LOD
distance — the same acceptance the flat FarTerrain ADR made; documented user-visible),
no cross-facet junction geometry at ℓ>0 (§7), no voxel-worker-pool usage (asserted:
`vox_gen`/`vox_mesh` stats untouched by a pure-LOD soak).

### 5.4 Trees and snow at stride

Stride sampling keeps whatever the sampled LOD0 cell holds: tree trunks/canopy survive
where the stride lattice hits them (sparser, shimmering distant forests — accepted,
LOD-RESEARCH §2.3); snow caps/layers ride resolve_cell unchanged. No special-casing.

### 5.5 FacetFarRing subsumption

The ring stays (the ℓ=∞ tier + the universal fallback + the hemisphere at boot).
WorldManager merges `pool_fids ∪ FacetLodMesher.covered_fids()` into ONE excluded set fed
through the existing deferred/budgeted `set_pool_excluded` path (`facet_far_ring.gd:71-78`)
— never a synchronous rebuild on a grant (the FP-S1(d) discipline). Gate: no facet is ever
in both the ring's emitted set and the covered set after a `force_rebuild()`.

---

## 6. Selector (screen-space error) + budgeter (request-grant) + the load-adaptive controller

### 6.1 The one rule

Projected megablock size in pixels for facet f at tier ℓ:

```
p(ℓ, f) = (2^ℓ · viewport_h) / (2 · d(f) · tan(fov_v / 2))
```

`d(f)` = distance from the camera to the facet's bounding sphere (centre =
`facet_transform(fid)` applied to the cached centre cell; radius = half the slab diagonal
≈ 155 blocks), clamped ≥ 1. Desired tier = the largest ℓ with `p ≤ LOD_TAU_PX`, i.e.
`ℓ_c = log2(τ · 2 · d · tan(fov/2) / viewport_h)`, desired = `clamp(floor(ℓ_c), 0, LOD_MAX_TIER)`
— and a desired 0 is *representable only by a live terrain*, so the LOD grant floor is 1
(the live pool covers the true-ℓ0 need per §3).

Worked thresholds (h = 1080, fov 70° → coefficient ≈ 771, τ = 3): ℓ1 from d ≈ 514, ℓ2 from
≈ 1028, ℓ3 from ≈ 2056 — i.e. ring-1 facets *desire* ℓ0–ℓ1, the horizon desires ℓ3+,
the planet's far limb (~2R = 6144) desires ℓ4 (clamped to 3 until FP-M3).

### 6.2 The four regimes, one rule

- **Walk**: adjacent facets d ≈ 100–400 → desire ℓ0–1; the imminent (live) facet covers
  true ℓ0; the others get ℓ1 when idle, ℓ2–3 under pressure. Megablock detail on ≥ 3
  facets at once at every seam — R1-at-distance.
- **Low flight**: nadir facets d ≈ 200–1000 → ℓ1–2; horizon coarsens automatically.
- **Near orbit**: d ≈ 1000–6000 → ℓ3 (…5 at FP-M3); frustum + front-hemisphere cull bound
  the request set.
- **Telescope**: zoom shrinks `fov_v` → p rises → finer ℓ requested for exactly the facets
  in the magnified frustum. The budgeter (§6.4) is what makes this safe.

No special-case code per regime — the camera parameters ARE the regime.

### 6.3 Hysteresis

Re-tier only when the continuous `ℓ_c` crosses the current tier's boundary by more than
`LOD_HYST_BAND` (0.25): promote-to-finer at `ℓ_c < lod − 0.25`, demote at
`ℓ_c > lod + 1.25`. A camera oscillating on a boundary flips at two different thresholds →
no thrash (G-M2-SEL sweeps d both ways and asserts ≤ 1 transition per direction).

### 6.4 The budgeter (request-grant, never selector-driven-unbounded)

Per `tick()`:

1. Collect wants: for every front-hemisphere, in-frustum facet not live in the pool,
   desired tier per §6.1 (floor 1, cap `LOD_MAX_TIER`), stamped `last_want_ms`.
2. Sort by *error excess* `p_current / τ` descending (worst-looking first; a facet with no
   mesh has p_current from the quad tier = worst).
3. Grant while: queue jobs < `LOD_QUEUE_MAX_JOBS` AND estimated in-flight build seconds
   (Σ est_cols × measured ms/col) < `LOD_QUEUE_MAX_EST_S` AND post-grant ledgers ≤ caps
   (evict LRU non-wanted facets first to fund; if funding requires evicting a
   *currently-wanted* facet, degrade the grant one tier instead — never evict wanted for
   wanted).
4. **Progressive refinement**: a facet with no mesh is granted `max(desired, 3)` first
   (~2 s to cover), then re-granted one tier finer per pass **only while the queue is
   idle** (backlog < 25% of caps). Fine tiers are an idle-time luxury by construction;
   under sustained pressure everything converges to ℓ3 + quads, never to OOM.
5. Degradation ladder (NEVER-OOM order): deny-fine → demote one ℓ → quad. Never a hole
   (the quad tier is always resident behind an evicted facet after the exclusion re-emit).

The ms/col estimate is self-calibrating: seeded from the FP-R0 numbers, updated by an EWMA
of actual job times (so WASM/native and fast/slow machines converge without config).

### 6.5 The load-adaptive admission controller (closed loop, first-class)

The budgeter's per-tick grant volume is not a fixed const — it is the control action of a
**closed-loop controller on measured main-thread load** (the user's directive: replace
low-res neighbour terrain with high-res *gradually*, "constantly measuring main thread
load and ensuring we're not saturating"). One small shared class,
`godot/src/world/stream_load_controller.gd` (`class_name StreamLoadController`), owned by
WorldManager, read by FacetLodMesher (grants + applies) and module_world (ramp pace).

**6.5.1 Measured signal** (all already surfaced by the PerfHUD / module stats — no new
instrumentation class):

- `frame_ema` — EMA (half-life ≈ 0.5 s) of the main-thread frame cost:
  `Performance.TIME_PROCESS` + `TIME_PHYSICS_PROCESS` (the PerfHUD's `proc`/`phys`).
- `frame_worst` — worst actual frame delta over a sliding `CTRL_WINDOW_FRAMES := 30`
  window (the PerfHUD's `worst`). The binding signal: jerk is a worst-frame phenomenon.
- Feed-forward: the voxel engine task backlogs (`vox_gen`, `vox_mesh`) and the engine's
  main-thread apply spend, from the same `VoxelEngine`/terrain statistics the HUD logs.
  Backlog is not main-thread cost *yet* — it is the queue that will become long
  mesh-apply trains and starved active-facet streaming — so it gates *generation-producing*
  admissions specifically (below).

**6.5.2 Setpoint.** `CTRL_FRAME_BUDGET_MS := 18.0` on `frame_worst` (hold ≥ ~55 fps with
margin), evaluated every `CTRL_TICK_S := 0.25` s. Headroom
`H = CTRL_FRAME_BUDGET_MS − frame_worst_ema` (EMA'd so a single spike is noise, §6.5.4).

**6.5.3 Control action — one scalar credit, four admission surfaces.** The controller
maintains `credit ∈ [0, 1]` by AIMD: multiplicative decrease on overload
(`frame_worst_ema > setpoint` → `credit ×= 0.5`, floor 0), additive increase under
headroom (`credit += 0.1` per tick, cap 1) — bounded, anti-windup by construction
(the clamp; paused ticks accumulate no debt). Credit scales, downward only from the hard
consts:

1. **LOD apply budget**: `LOD_APPLY_BUDGET_MS × credit` ms/frame (0 → applies pause,
   finished meshes wait in the done-queue — bounded, they are already built).
2. **Build-job grants**: grants admitted per tick = `ceil(2 × credit)`; at credit 0 the
   budgeter stops enqueueing (the builder finishes in-flight tiles and idles).
3. **Pool view-ramp pace**: module_world gains `set_stream_pace(f: float)`; the FP-M1c
   per-slot ramp (`_ramp_pool_step`, `module_world.gd:373-402`) multiplies its per-frame
   step by `f` — `RAMP_SECONDS` becomes the *minimum* ramp duration, stretched under load,
   ramp fully held at 0. Shrinks (unloads) are never throttled.
4. **Promote admission**: a live-terrain spawn (or a finer-ℓ grant for an already-covered
   facet) additionally requires `credit ≥ 0.5` sustained for `CTRL_PROMOTE_SUSTAIN_S :=
   1.5` s — promotions start only into real headroom.

Plus the feed-forward gate: while `vox_gen backlog > CTRL_BACKLOG_MAX := 300` (the same
number as the M2e definition of done), surfaces 3 and 4 are held at zero regardless of
frame time — new full-res volume is never admitted onto a pool that has not drained,
which is verbatim the user's "keep the pace of streaming of the neighbour chunks such
that we never overload". Surfaces 1–2 (builder-thread work) stay frame-time-governed
only; they do not touch the pool.

**6.5.4 Stability (no promote/demote oscillation).**

- All decisions read EMA'd signals on the 0.25 s tick — one bad frame moves nothing.
- **A granted promotion is never yanked.** A spawning terrain or in-flight build finishes
  at reduced pace (down to held-at-zero), it is not cancelled/retired by load. The only
  load-driven *demotion* trigger is sustained overload ≥ `CTRL_OVERLOAD_SUSTAIN_S := 3.0`
  s at credit 0, and even then the response is ordered pause-first: hold all climbs →
  (if still saturated) demote the least-wanted LOD facet one tier — live terrains are
  never retired by the controller (pool retirement stays purely geometric, §3.2/§9.2).
- SSE-driven re-tiers keep their own hysteresis (§6.3); the two loops act on different
  inputs (camera vs load) and only ever *lower* each other's admissions, so they cannot
  chase each other upward.

**6.5.5 Interaction with `voxel/threads/main/time_budget_ms = 6`.** The engine's apply
budget bounds how much the engine spends *draining its own queues* per frame; it stays 6
and is not touched. The controller sits ABOVE it: it governs how much NEW work is
admitted (grants, ramp growth, LOD applies) so the engine's queues never grow to where
the 6 ms drain is saturated for long stretches. No double-counting: the controller's
measured signal is the TOTAL main-thread frame cost, which already *includes* the ≤ 6 ms
apply spend — when applies eat the frame, credit falls and admissions stop, which is the
correct composed behaviour, not a conflict.

**6.5.6 Scope.** The controller governs CPU/main-thread saturation ONLY. The NEVER-OOM
ledgers (§11) are hard, independent, and checked *after* the controller: full credit can
never admit past a memory cap, and zero credit never exempts eviction. Flag-gated with
FP_M2_LOD; with the flag off, `set_stream_pace` is never called and the shipped fixed
ramp is byte-identical.

---

## 7. Seam treatment at ℓ > 0

### 7.1 The problem

At ℓ0 the two facets' cut faces weld exactly (carve sentinels + coplanar-opposite-winding,
REVIEW §6.1, gates G-J1/G-M1-SEAM). At ℓ>0 a megablock straddling the ridge cannot be cut
by the standalone mesher: `build_mesh` has no block origin, so the patch-0004 carve blob
cannot locate cells in lattice space — and per-sample `junction_modify`
(`facet_atlas.gd:516-538`) would make the mask decision for ONE sampled LOD0 cell while
rendering an s³ megablock: overlaps poke through the live facet's true geometry (risk #3),
gaps open slits.

### 7.2 The rule: uniform conservative erosion

In the stride generator path, **for lod > 0 only**, replace the per-cell
`junction_modify` call (`module_world.gd:2381-2382`) with a footprint test:

```
FacetAtlas.cell_interior_scaled(fid, wx, wy, wz, s) -> bool
    # for each of the 4 ridge planes: min over the s-cube [w, w+s]³ of own(x,y,z)
    # = A·wx + B·wy + C·wz + D + s·(min(0,A) + min(0,B) + min(0,C))  ≥ −SEAM_EPS
```

A megablock survives only if **fully interior** to all 4 planes; anything straddling or
beyond becomes AIR. No junction modifier is ever emitted at ℓ>0. Pure frozen-atlas
arithmetic (the `block_all_air` family, `facet_atlas.gd:559-573`) — worker/builder-safe,
facet-static (no re-generation when pool membership changes — the reason erosion is
UNIFORM rather than per-ridge-mode). **At lod == 0 the shipped `junction_modify` path runs
verbatim** — LOD0 byte-identity is preserved by construction (G-M2-ID pins it).

### 7.3 What the ridge looks like

- **Live facet ↔ LOD facet** (the common case: the active facet borders LOD ring-1
  facets directly): the live side renders full-res with its exact carve bevel reaching the
  plane; the LOD side retreats ≤ s blocks and its boundary megablocks emit vertical wall
  faces (masked pad = AIR → side faces are meshed, never a see-through hole). Net: a
  ≤ s-block shelf at the ridge, at a distance where a megablock subtends ≤ τ px — i.e.
  ≤ ~3 px of wall. **No interpenetration into the live facet is possible** (erosion keeps
  every solid strictly inside its own half-space; the planes are exact complements,
  `own_A = −own_B`, G-J1) → no double-render, no z-fight.
- **LOD ↔ LOD**: both sides erode → without treatment, a ≤ 2s-block open slit along the
  ridge. **The user has REJECTED this hairline** — it is designed out, not accepted: every
  LOD↔LOD ridge is covered by a **ridge apron** (§7.4), primary M2b scope. The erosion
  contract itself is unchanged (it is what guarantees zero interpenetration); the apron
  covers the retreat gap on top of it.
- **Twist / singular vertices (risk #5)**: erosion needs no cross-facet junction geometry
  at all, so the 8 singular cube-corner vertices need nothing special at LOD — each
  facet's own 4 planes are well-defined everywhere (`facet_atlas.gd:199-240`). The FP-M1
  skips stand: no live neighbour across a twist seam (never the imminent facet there —
  `FACET_TWIST` false, no diagonal at 3-facet corners, `SINGULAR_EXCLUDE` complementarity
  exclusions carried over). Asserted by skipping, exactly as FP-M1 §8. Aprons at twist
  seams use the same per-seam ring/m̂ data and need no lattice alignment — covered, not
  special-cased.

### 7.4 The ridge apron (PRIMARY for LOD↔LOD ridges — M2b scope)

One apron per **seam** whose BOTH adjoining facets are LOD-mesh-covered (a live side needs
none — its bevel reaches the plane; a quad side needs none — the quad is built from the
planarized corners and reaches the ridge exactly). Ownership: the **lower fid** of the
pair builds it (no double-draw), keyed by (owner_fid, slot) in the FacetLodMesher cache.

- **Geometry.** Let `s_max = max(s_A, s_B)` (the coarser of the two sides' strides). Walk
  the welded ring segment `[r0, r1]` (`seam_ring`, `facet_atlas.gd:355-358`) at pitch
  `s_max`; at each sample take the surface height from `TerrainConfig.profile_at_dir` at
  the sample's radial direction (the FacetFarRing recipe, `facet_far_ring.gd:154-179`)
  and the FarPalette colour. Emit **two quad strips**, one per side: from the ridge line
  inward `s_max` along each facet's plane (direction = that facet's `seam_mhat`,
  `facet_atlas.gd:360-362`), with the strip top snapped UP to the side's megablock-top
  grid (`ceil` to its own s — the outward-rounding discipline of `junction_q_of`:
  overlap-not-gap, the strip meets or tucks just under the megablock tops). The strips'
  outer edges drop a short vertical skirt (~s_max blocks) to tuck under the megablock
  wall faces, killing any residual sliver from height mismatch. Vertices are expressed in
  the OWNER facet's lattice coords (`world_to_lattice64`) under its `LodFacet` node —
  the apron therefore moves rigidly with PlanetRoot at a crossing like every other LOD
  mesh, zero rebuild.
- **Build/pace.** Built on the BUILDER thread as a job appendix of the owner facet
  (pure frozen-atlas data + `profile_at_dir` — the same thread-safety class as
  `generate_block`; ~⌈201/s_max⌉ profile samples ≈ tens-to-200 ms, far too heavy for a
  main-thread frame). Applied in the facet's atomic swap. Rebuilt (cheap, one strip job)
  when either adjoining facet re-tiers or gains/loses LOD coverage; paced by the load
  controller like any other LOD work (§6.5) — an apron job is just a small build job.
- **Cost (ledgered).** Per seam ≈ 2 strips × ⌈201/s_max⌉ segments × 2 tris + skirts ≈
  ≤ 500 tris at ℓ1, ~130 at ℓ2, ~70 at ℓ3; ≤ 2 aprons owned per LOD facet (4 ridges,
  half owned) → at `LOD_MAX_FACETS` = 64 worst ≈ 128 aprons ≈ ≤ 65 k tris, ≤ ~2 MB —
  inside the existing `LOD_MAX_TRIS`/`LOD_MAX_BYTES_MB` caps (counted in the same
  ledgers; NEVER-OOM unchanged, §11).

### 7.5 The seam gates

**G-M2-SEAM (headless)**: for ≥ 3 ridges (one cube-edge seam, one flanking a singular
vertex): build both sides at mixed tiers (ℓ1 vs ℓ2); assert (a) every LOD mesh vertex
satisfies `own_dist ≥ −1e-3` in its own lattice for all 4 planes (zero protrusion — the
erosion contract); (b) wall faces present at the eroded boundary (no open edge loops
facing the ridge); (c) **NO LOD↔LOD hairline**: the apron exists for every LOD↔LOD seam,
spans the full retreat gap on BOTH sides (every ridge-line sample within the domain has
covering geometry within ε — ray/coverage test against apron + megablock tops), and its
vertices stay within the ±s_max coverage window; (d) exactly one apron per seam (lower-fid
ownership — no double-draw); (e) on the live meshers, carve sentinels resolved
(non-negative slots) and `oob_seen == 0` (the patch-0004 diagnostics — unchanged from
G-M1-SEAM-2). **Live seam soak**: stand at a live↔LOD ridge and fly along a LOD↔LOD
ridge — no flicker (nothing coplanar by construction), no console errors, no visible slit
at any tier.

---

## 8. Frame / orientation correctness

- Faceted mode has **no window rotation**: the faceted GenCtx keeps `jinv_d4 = 0`
  (`module_world.gd:2300-2305` — "jinv stays 0 (no window rotation in flat/faceted)"), so
  generated modifiers need no de-rotation and the LOD path introduces no orientation state.
  Geometry is a pure function of `(SEED, fid, x, y, z)` — stronger than curved's frozen
  epoch (`facet_atlas.gd:1-10`).
- Placement composes exactly like FP-M1c terrains: `PlanetRoot @ T_active⁻¹` ×
  `LodFacet @ facet_transform(fid)` × `tile @ (scale s, lattice origin)`. The active facet's
  own LOD node would compose to identity (but the active facet never has one — it is live).
  A crossing's transform write re-places all LOD meshes rigidly with zero re-meshing —
  the FacetFarRing "absolute coords + rigid re-place" insight, generalized
  (`facet_far_ring.gd:49-57`).
- **G-M2-FRAME**: place a probe-built tile for facet f; assert a known solid cell's world
  AABB equals `facet_transform(f)` applied to its lattice cell within 1e-3 — evaluated
  under TWO different active facets (before/after a scripted `redesignate`) so
  orientation-correct-from-every-viewer is pinned, not assumed. Uniform scale s under the
  rotated parent is a plain invertible similarity — no engine terrain is involved, so the
  "never hand godot_voxel a singular transform" boundary (REVIEW §3.3) is not even
  adjacent.

---

## 9. Crossing = promote / demote (extends FP-M1c `redesignate`, does not replace it)

### 9.1 Promote (LOD → live terrain)

Trigger: the pool policy elects fid (imminent / corner-2nd, §3.2) AND the load controller
admits it (credit ≥ 0.5 sustained + backlog gate, §6.5.3.4) → `pool_spawn(fid)`
(`module_world.gd:1444-1463`, unchanged: view 48→96 ramp, now paced by
`set_stream_pace`). The D_WARM lead (≥ 10 s walking) is what gives the controller room to
defer a spawn through a load spike without missing the crossing. NEW choreography:

- The facet's LOD mesh **stays visible** while the terrain streams (they overlap; megablock
  tops may poke ≤ s−1 through fresh full-res — a transient, milder than the hole today's
  quad exclusion leaves). When the terrain reports `is_area_meshed` over its **seam-side
  half-band** (the D_WARM band, converted terrain-LOCAL — the FP-M1 §12.5 helper), call
  `FacetLodMesher.evict(fid)` in the same frame the far-ring exclusion updates. Hard
  timeout `PROMOTE_EVICT_MAX_S := 20` → evict anyway (never let a laggard mesh block pin
  double geometry — lifetime cap discipline).
- A crossing to a pooled facet is `redesignate(to)` **unchanged** (`module_world.gd:
  1483-1514`): ONE PlanetRoot write + view rebalance + editable designation. The LOD layer
  participates passively: meshes move rigidly; the selector re-evaluates distances next
  tick; `_build_count` must not change across the crossing (G-M2-XPD — no rebuild storm).
- Pool-miss ladder (`world_manager.gd:1392-1401`, teleports/corner-diagonals) unchanged;
  under FP-M2 the miss lands on a facet that usually already has an ℓ1–3 mesh → the
  spawn-at-cross fill happens behind megablocks instead of behind a quad. Gate keeps the
  "miss count ≈ 0 in soaks" assert.

### 9.2 Demote (live terrain → LOD)

Trigger: pool policy retires fid (ridge > D_RETIRE, or displaced incumbent §3.2). NEW:

- **Build first, retire second**: request `on_demote_request(fid)` — the budgeter enqueues
  fid at its granted tier at top priority; when applied, `pool_retire(fid)`
  (`module_world.gd:1467-1477`, unchanged) frees the terrain the same frame the exclusion
  set re-merges. Hard timeout `DEMOTE_RETIRE_MAX_S := 20` → retire anyway and let the quad
  cover until the normal grant lands (never let a stuck build pin a 20 MB terrain —
  NEVER-OOM outranks the pop).
- The old active after a crossing is simply the new imminent neighbour (distance ≈ 0) —
  it stays live and demotes later through this same path when the player walks on. No
  crossing-frame work.

### 9.3 Ordering invariant

At every instant each facet has exactly ONE primary representation — live terrain, LOD
mesh, or quad — plus at most one *overlapping transient* during a promote/demote window,
bounded by the 20 s timeouts. G-M2-XPD asserts the state machine: no facet ever quad-only
while pooled, never LOD+quad simultaneously emitted, object counts return to baseline
after a promote/demote cycle (the anti-leak pattern from G-M1-POOL).

### 9.4 Controller synergy: the crossing is a small delta, not a burst

Because the imminent neighbour has been climbing the ladder under the controller since it
entered D_WARM (LOD mesh → live @48 → ramping toward 96, each step admitted against real
headroom), by the time the player reaches the ridge the facet is already at or near its
view-96 rung. The crossing's `redesignate` then adds only the 96→128 delta annulus —
itself paced by the same `set_stream_pace` surface — so the promote step at the crossing
is the *smallest* increment on the ladder rather than the largest. This is the closed-loop
generalization of the FP-M1c ramp insight: FP-M1c spread the burst over fixed time; the
controller spreads it over measured headroom, which on a fast idle machine converges
faster than 1.5 s-per-leg and on a saturated 4-core web tab stretches instead of jerking.

---

## 10. Off-surface active-facet designation (risk #6 — stubbed, FP-M3 owns locomotion)

- The selector is already viewer-relative pure camera math — it needs no "active facet".
- The stub FP-M2 ships: `FacetAtlas.facet_of_dir(d: DVec3) -> int` — classify the viewer's
  radial direction via `CubeSphere.dir_to_face_cell(d, K)` (`cube_sphere.gd:299-313` at
  n = K) → `fid = (face·K + i)·K + j`. Pure f64, frozen tables.
- FP-M2 uses it only defensively: if the camera's radial facet differs from the active
  facet AND altitude above the facet plane exceeds `OFFSURFACE_Y := 256` (flight), the
  pool policy freezes spawns (no thrash from a flying viewer skimming ridges) — crossing
  detection (`maybe_cross_facet`) is player-position-driven and unchanged.
- **G-M2-DIR gate**: `facet_of_dir(cell_dir(fid, centre_cell(fid))) == fid` for all 3456
  facets (exact round-trip); selector outputs finite and monotone along a scripted
  ascent-to-orbit camera path (no NaN/thrash off-surface). Gravity/locomotion off-facet is
  explicitly FP-M3.

---

## 11. NEVER-OOM ledger

| Item | Budget | Basis |
|---|---|---|
| Pool worst (1 active @128 + 2 neighbours @96, Z1-hybrid) | 80 MB | FP-M1 ledger (40 + 2×20); DOWN from 120 |
| LOD mesh cache (CPU arrays) | ≤ `LOD_MAX_BYTES_MB` = 96 MB | §1.3 estimates: steady ≈ 50 MB (8×ℓ1 + 16×ℓ2 + ~40×ℓ3); cap = 2× headroom; GPU ≈ ×1 measured by the live A/B |
| LOD triangles | ≤ 3 M | FP-R0 B2 web ceiling analysis (`verify_fp_r0.gd:320-323`) |
| Ridge aprons (§7.4) | ≤ ~65 k tris / ≤ ~2 MB worst (128 aprons @ ℓ1) | counted INSIDE the LOD tri/byte caps above, not additional; per-seam cost table §7.4 |
| Build queue | ≤ 16 jobs / ≤ 30 est-s | grant admission (§6.4) |
| Builder thread stack | 2 MB | one persistent pthread (§4.3) |
| Far ring, atlas, probe generators | < 3 MB | FP2 ledger + ~1 KB/frozen generator × cached facets |

Rules of force: `FP_M2_LOD` default **OFF**; default-ON only after the FP-M2e live A/B —
browser heap (`performance.memory` + `wasm memory.buffer.byteLength`, the PerfHUD sampler)
delta vs FP-M1c baseline ≤ **+120 MB**, slope flat over a 15-min soak **including a
scripted telescope burst**, LOD caps never exceeded (stats() sampled). Degradation is
always one-ℓ-coarser → quad, never unbounded (§6.4.5); every transient (promote/demote
overlap) carries a hard lifetime cap (§9). Net worst-case vs FP-M1c: pool −40 MB, LOD
+96 MB cap, thread +2 MB → ceiling shift ≈ +58 MB with the *common* case ≈ +30 MB.

---

## 12. Verify gates

New `godot/src/tools/verify_fp_m2.gd` (the `verify_fp_r0.gd` pattern: sed-toggle FACETED +
FP_M1_POOL + FP_M2_LOD, exit 0/1) + extensions to `verify_faceted.gd`. Inventory:

- **G-M2-ID (LOD0 byte-identity)**: probe generator (stride unlocked) vs shipped generator,
  TYPE-channel equality over ≥ 3 34³ boxes including a seam-straddling one (carve
  sentinels equal) and a tree canopy — the FP-R0 B0 assert re-pinned as a permanent gate.
- **G-M2-BUILD**: off-thread pipeline produces non-empty meshes at ℓ ∈ {1,2,3} for ≥ 3
  facets (incl. one flanking a singular vertex); per-job time/tris/bytes recorded (the
  §1.3 table re-measured); built entirely on the builder Thread (main-thread id assert);
  voxel-pool stats untouched (`vox_gen` task delta == 0 during a pure-LOD build).
- **G-M2-FRAME**: §8 placement round-trip under two active facets.
- **G-M2-SEAM**: §7.5 headless asserts (zero protrusion; walls present; **no LOD↔LOD
  hairline** — apron present per seam, spans the retreat gap both sides, one owner,
  within the ±s_max window; carve sentinels resolved + `oob_seen == 0` on live meshers;
  singular-vertex facets excluded from the complementarity form, included in the
  no-protrusion + apron-coverage forms).
- **G-M2-SEL**: selector table-driven unit gate — (d, fov, h) → expected tier incl. the
  four regime archetypes; monotone in d; hysteresis two-threshold sweep; telescope fov
  shrink raises requested tiers for in-frustum facets only.
- **G-M2-CAPS**: request storm (scripted telescope burst) → counts/tris/bytes pinned at
  caps, queue bounded, grants degraded not queued, LRU evicts only non-wanted, idle demote
  fires after `LOD_IDLE_DEMOTE_S`.
- **G-M2-XPD**: promote keeps mesh → evicts on seam-band meshed (object counts baseline);
  demote applies mesh before retire; timeouts enforced; a scripted `redesignate` with a
  populated LOD layer: node ids stable, ONE transform write, `_build_count` unchanged,
  exclusion sets consistent (no facet in ring-emitted ∩ covered).
- **G-M2-DIR**: §10 round-trip over all 3456 facets + orbit-path sanity.
- **G-M2-POLICY**: Z1-hybrid — scripted mid-edge walk holds live neighbours == 1; corner
  approach == 2 (both < 48); diagonal never live; switch margin honoured (no incumbent
  thrash in a diagonal-walk sweep); with `FP_M2_LOD` off, policy byte-matches FP-M1c
  (the shipped G-M1-POOL gate re-run unchanged).
- **G-M2-CTRL (the closed loop)**: headless, with a synthetic main-thread load injector
  (busy-wait raising frame cost above/below the setpoint on a square wave) and a
  synthetic backlog feed: (a) credit falls to 0 within ≤ 4 ticks of sustained overload
  and admissions (applies, grants, ramp pace, promotes) measurably stop; (b) credit
  recovers and admissions resume after load removal; (c) under square-wave load the
  grant/pace trace shows NO promote→demote→promote cycle — a granted promotion completes
  (paced) across the load pulses; (d) the backlog gate holds surfaces 3–4 at zero while
  `vox_gen > CTRL_BACKLOG_MAX` even at full frame headroom; (e) at credit == 1 the NEVER-OOM
  ledgers still bind (a request storm cannot exceed caps regardless of controller state);
  (f) flag-off: `set_stream_pace` never called, ramp timing byte-matches FP-M1c.
- **Ledger asserts**: `LOD_FLOOR_Y` large-sample min-height bound (beside the
  MAX_SURFACE_Y assert); all §5 consts present and within the §11 ledger.
- **Unconditional**: FLAT `verify_feature` **6027/0** every sub-stage; `verify_faceted`
  (incl. all FP-M1 gates) green with FP_M2_LOD off AND on; flag-off scene-graph identity.

Live (per sub-stage, §13): the FP-M1 soak protocol (≥ 15 min, heap sampled 10 s, flat
slope, no console storms, no blank) + the stage-specific soak named below.

---

## 13. Sub-stages FP-M2a‥e — each independently shippable, toggles committed OFF

- **FP-M2a — off-terrain build pipeline + LOD0 identity.** Productize the probe:
  `_make_generator(fid, true)` factory access for FacetLodMesher, `cell_interior_scaled`,
  `LOD_FLOOR_Y` + its bound-assert, the builder Thread + buffer/tiling + build_mesh call
  shape settled (materials question, §4.1.4), NO scene consumer (verify-only).
  **Gate:** G-M2-ID, G-M2-BUILD, the thread-pool boot assert (§4.3); FLAT 6027/0.
  Ships as dead code behind `FP_M2_LOD` (byte-identical deploy).
- **FP-M2b — FacetLodMesher node + cache/caps + static tiers + the RIDGE APRON.** The
  class (§5), apply/swap, ledgers, LRU, far-ring exclusion merge; tier selection is a
  fixed per-ring table (ring-1 → ℓ1, ring-2 → ℓ2, else ℓ3) — no SSE yet. Replaces quads
  for covered facets. The §7.4 apron ships HERE (primary scope, user decision): built as
  a builder-thread job appendix, one per LOD↔LOD seam, counted in the LOD ledgers —
  no LOD↔LOD hairline from the first deployed LOD build onward.
  **Gate:** G-M2-CAPS, G-M2-FRAME, G-M2-SEAM headless (incl. the no-hairline/apron
  asserts); live deploy (flag flipped at export): megablock detail visible on ≥ 3 facets
  at a ridge, no visible ridge slit, heap-flat soak.
- **FP-M2c — SSE selector + budgeter + the load controller core.** §6 in full: camera
  input, hysteresis, request-grant, progressive refinement, idle demote, `facet_of_dir`
  stub + off-surface spawn freeze; `StreamLoadController` (§6.5) with surfaces 1–2 wired
  (apply-ms + grants — the LOD-side loop closes here). **Gate:** G-M2-SEL, G-M2-DIR,
  G-M2-CTRL(a–c, e–f for surfaces 1–2), G-M2-CAPS re-run under the selector (the
  telescope burst now organic); live fly-hack altitude soak holds frame rate with tiers
  visibly re-selecting.
- **FP-M2d — pool integration (the Z1-hybrid) + promote/demote + controller surfaces 3–4.**
  §3 policy in WorldManager (`_pool_policy` rework: imminent-winner + D_WARM2 + switch
  margin), §9 choreography wired into `pool_spawn`/`pool_retire`/`redesignate` call
  sites, `module_world.set_stream_pace` + the promote admission gate + the backlog
  feed-forward (§6.5.3.3–4). **Gate:** G-M2-POLICY, G-M2-XPD, G-M2-CTRL in full
  (incl. (d) and the ramp-pace surface), G-M2-SEAM live seam soak; scripted sprint
  crossing on live web — PerfHUD max frame ≤ 50 ms, `is_area_meshed` B-core at commit,
  no `facet cross` storms, pool-miss count 0.
- **FP-M2e — memory A/B + walk-the-planet + default-ON.** The §11 browser-heap A/B
  (FP-M1c baseline vs FP-M2), a ≥ 30-min walk crossing ≥ 6 seams incl. a cube-edge seam
  and a corner, telemetry: **`vox_gen` backlog ≤ 300 sustained during border approach**
  (the milestone's definition of done — vs 1500–2800 measured), `proc` bursts ≤ 100 ms,
  **worst-frame histogram ≤ `CTRL_FRAME_BUDGET_MS` for ≥ 99% of frames** (the controller's
  live proof, sampled by the PerfHUD alongside the credit trace), LOD stats within caps
  throughout. Run once on a ≤ 4-core machine — the controller must degrade pace there,
  not frame rate. Then the sed-at-export flip ships FP_M2_LOD ON
  (FACETED + FP_M1_POOL + FP_M2_LOD), repo consts stay OFF.

Every stage exits through the §12 unconditional gates. Revert at any stage = the flag
(or, for M2e, re-export without the sed line).

---

## 14. Where this breaks at 3 a.m. (adversarial)

1. **Thread-pool exhaustion at 16/16.** The builder consumes the last pthread slot
   (§4.3). If any transient engine thread appears (resource loader, etc.), boot may log
   "thread pool is exhausted" → meshes stall. Mitigation is pre-agreed and one-const
   (voxel hw clamp 14→13); the FP-M2a gate asserts the clean boot log on live web BEFORE
   any scene work depends on the thread.
2. **A hidden main-thread-only static on the builder path.** The generator's reader set is
   proven for voxel workers, but the builder calls it via `Object.call` from a GDScript
   Thread — any future edit that lets the probe path touch `_active_facet`, `_shape_memo`
   or `_analytic_ctx` (`terrain_config.gd:566-591`) is a corruption. Defence: the §4.1
   audit line is codified as a gate — G-M2-BUILD runs the builder concurrently with a
   main-thread analytic query storm and a live terrain streaming, and asserts identical
   output to a solo run (the verify_cosmos_race pattern).
3. **ℓ-boundary popping / re-tier churn.** A facet at a tier boundary rebuilding 48 ℓ1
   tiles repeatedly would eat the builder for a minute. Hysteresis (§6.3) + idle-only fine
   grants (§6.4.4) + the switch ledger in G-M2-SEL bound it; the EWMA cost model keeps the
   in-flight bound honest on slow machines.
4. **The telescope memory burst.** A zoom sweep across the limb requests fine tiers for
   dozens of facets. Request-grant + eviction-funded grants + the 16-job/30-s queue bound
   the damage to "the telescope image sharpens facet by facet"; caps are asserted, and the
   A/B soak includes the scripted burst. The selector CANNOT allocate — only the budgeter.
5. **Promote-window visuals.** Between `pool_spawn` and seam-band-meshed, megablocks poke
   ≤ s−1 through fresh full-res terrain (§9.1). Bounded by D_WARM lead time (≥ 10 s
   walking, FP-M1 §4.3) and the 20 s timeout; judged in the M2d live soak. If rejected:
   hide the LOD mesh's *near-band tiles only* at spawn (tile granularity exists) — specced
   fallback, not built.
6. **Apron weld defects.** The apron replaces the (rejected) LOD↔LOD hairline, so its own
   failure modes inherit the seam's visibility: (a) a height-mismatch sliver where the
   strip top misses a megablock top — countered by the ceil-to-s snap + the outer skirt
   (§7.4), asserted by G-M2-SEAM(c)'s coverage test at MIXED tiers (ℓ1 vs ℓ2, the worst
   case); (b) a stale apron after one side re-tiers (s_max changed) — the rebuild trigger
   is keyed on both neighbours' cache entries, and a stale window is bounded by one
   builder job; (c) double-draw if ownership breaks at a fold-adjacent seam —
   G-M2-SEAM(d) asserts exactly one apron per seam. The erosion contract itself is
   untouched — the apron only covers it, never substitutes for the zero-protrusion
   guarantee.
7. **`build_mesh` API drift / materials.** The exact script-call shape is proven only by
   FP-R0 headless (dummy renderer). If live surfaces come back unshaded, the
   surface_set_material fallback lands in FP-M2a (its live smoke covers it) — before any
   dependent stage.
8. **Twist-seam 8× (risk #5).** Out of scope and *skipped by construction*: erosion needs
   no cross-facet geometry (§7.3), no live neighbour ever spawns across a twist seam, the
   diagonal-detect bail and `SINGULAR_EXCLUDE` asserts carry over from FP-M1 §8. FP5 owns
   the junction polish; G-M2-SEAM documents the exclusions explicitly so they cannot rot
   into silent coverage gaps.
9. **Edits invisible at LOD** (a demoted facet "heals" its craters from a distance). By
   design (§5.3, the FarTerrain ADR precedent) — but it must be SAID to the user before
   default-ON, not discovered. Listed in the M2e A/B sign-off notes.
10. **Controller pathologies.** (a) *Starvation by chronic overload*: on a machine that
    never has headroom, credit pins at 0 and the imminent neighbour never goes live — the
    crossing then rides the pool-miss ladder (spawn-at-cross behind an existing LOD mesh,
    §9.1) — degraded but hole-free and honest: that machine could not have afforded the
    live neighbour anyway. Gated on the ≤ 4-core M2e run. (b) *Measurement pollution*:
    the controller's own apply work raises the very signal it reads — bounded because the
    apply surface is credit-scaled (a shrinking fraction of a shrinking budget converges,
    it cannot self-oscillate past the AIMD floor); G-M2-CTRL(c)'s square-wave trace is
    the regression net. (c) *Signal aliasing with GC/browser jank*: an unrelated 200 ms
    browser pause reads as overload and pauses climbs for a few ticks — the correct
    conservative response; only *sustained* misreads would matter, and those ARE load.
    (d) *Fighting the FP-M1c one-slot-per-frame ramp serializer*: it composes — the
    serializer bounds WHICH slot grows per frame, the pace scalar bounds HOW MUCH; both
    only reduce work; asserted byte-identical at flag-off (G-M2-CTRL(f)).

---

## 15. Decisions ledger (delta to FP-M1 §13 / REVIEW §9)

| # | Decision | Status after FP-M2 |
|---|---|---|
| 1 | Up to 4 live neighbour terrains at D_WARM (FP-M1c §4.3) | **Superseded** — Z1-hybrid: 1 imminent + 1 corner-second (< 48); `FP2_LIVE_CAP := 2` under the flag; POOL_MAX_NEIGHBOURS stays the hard backstop |
| 2 | FacetFarRing quads as the only off-pool representation | **Superseded** — FacetLodMesher tiers ℓ∈{1..3}; the quad remains the ℓ=∞ tier + fallback (REVIEW §9.4 completed) |
| 3 | Generator `lod != 0` early-out (shipped) / probe-only stride | **Superseded** — stride productized behind FP_M2_LOD; LOD0 byte-identity pinned by a permanent gate |
| 4 | Junction sentinels at every ridge cell | **Scoped** — ℓ0/live only; ℓ>0 uses uniform conservative erosion (`cell_interior_scaled`), no sentinels |
| 5 | ℓ0 as a LOD-mesh tier (REVIEW §6.3 sketch) | **Rejected** — full-res is exclusively the live-terrain representation; the LOD floor is ℓ1 |
| 6 | FP-M2 tier reach | ℓ∈{1..3} + quad; ℓ∈{4,5} + zoom input + distant-planet math are FP-M3 (machinery ready) |
| 7 | Fixed-schedule streaming pace (FP-M1c `RAMP_SECONDS` legs, fixed const budgets) | **Superseded** — closed-loop admission on measured main-thread load (§6.5); `RAMP_SECONDS` becomes the *minimum* leg duration, stretched (never compressed below it) by the controller; fixed consts remain as the hard upper bounds the credit scales within |
| 8 | LOD↔LOD erosion hairline as an accepted artifact (this doc's first revision) | **Rejected by the user** — designed out: the ridge apron (§7.4) is PRIMARY M2b scope; the remaining accepted-artifact set is (b) transient promote/demote megablock overlap and (c) player edits invisible/healed at LOD distance |
