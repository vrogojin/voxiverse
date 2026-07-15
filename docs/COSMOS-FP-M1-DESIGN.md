# COSMOS-FP-M1-DESIGN — the Planet Assembly: pooled rotated facet terrains, re-designation crossings, and the web thread-pool rebuild

Status: **implementation-ready design.** Realizes COSMOS-MULTIFACET-STREAMING-REVIEW §6
(the Planet Assembly) as milestone FP-M1, incorporating the post-mortem of the FP-R0
*visual* spike that failed live exactly as REVIEW §7.2 warned (worker-pool starvation /
memory accumulation → blank after minutes). Every claim is grounded in file:line of
branch `feat/voxiverse-cosmos-m5` or the vendored engine source
(`docker/engine/cache/godot`, Godot 4.4.1-stable + godot_voxel v1.4.1 + patches 0001–0004).

FP-M1 must fix the two live complaints — (i) two-plus neighbour facets never render
voxels together, (ii) a crossing freezes ~10 s and restreams the active facet from zero —
**without ever reproducing the spike's blank-out**, under the never-OOM web rule
(memory safety outranks visual quality; new memory flag-gated OFF behind a measured A/B
gate; explicit ceilings and lifetime caps) and the "live demo outranks feature depth" gate.

---

## 0. Executive verdict

1. **Viewer model: exactly ONE global `VoxelViewer` — the player's — serves every facet
   terrain. Per-terrain static viewers (the spike's choice) are the central error and are
   banned** (§2, §3). VoxelViewers are engine-global: every terrain pairs with every
   viewer (`voxel_terrain.cpp:1213-1218` localizes each viewer through
   `get_global_transform().affine_inverse()`), so the spike's 4 static viewers × ~5
   terrains created ~25 permanently-pinned stream fields, most of them foreign masked-AIR
   territory, on a fixed 4-worker WASM pool with a 6 ms/frame apply choke. The single
   player viewer localizes into each rotated neighbour lattice essentially undistorted
   (dihedral at k=24 is 90°/24 = 3.75°/seam; at 96 blocks from a ridge the out-of-plane
   error is ≈ 96·tan 3.75° ≈ 6.3 blocks, deep inside the ±64-block vertical stream slab),
   and streams from each neighbour exactly the across-the-seam band the player can see.
2. **Streaming scope is clamped twice**: the generator's block-domain early-out
   (FP-S1(b), `module_world.gd:1927`) kills the *compute*; a per-terrain
   **`bounds` AABB clamp** (engine-supported: `voxel_terrain.cpp:2249-2251,2391`; view
   boxes are `.clipped(bounds_in_*_blocks)` at `voxel_terrain.cpp:1296,1314`) kills the
   *bookkeeping* — no data/mesh block is ever created outside a facet's own domain slab.
   The early-out alone is NOT sufficient (the spike proved it: block/mesh map entries and
   empty-mesh tasks still accumulate and still occupy workers).
3. **Crossing = re-designation** (§5): the neighbour terrain is already live, so a
   crossing is one root-transform assignment + the existing f64 player reframe + a
   view-distance rebalance (delta annulus) + an edit-designation swap. No generator
   created, no terrain freed, no far-ring regenerated. The ~10 s freeze and the
   restream-from-zero are removed categorically.
4. **Thread rebuild** (§9): patch the engine (new `docker/engine/patches/godot/` series,
   mirroring the godot_voxel one) to make `PTHREAD_POOL_SIZE` a scons option; ship **16**
   (was 8, hard-coded at `platform/web/detect.py:232`). Voxel workers become
   per-visitor-adaptive: `minimum=3, ratio_over_max=0.7, margin_below_max=1`
   (`project.godot`) + a one-line godot_voxel patch clamping web
   `Thread::get_hardware_concurrency()` (`util/thread/thread.cpp:97-98`, today uncapped)
   to ≤14 → voxel workers scale 3‥10 by visitor cores, hard-bounded so
   voxel(≤10) + WorkerThreadPool(2) + audio/IO/spare(≤3) ≤ 15 < 16. Our build does
   **not** use PROXY_TO_PTHREAD (default False, `detect.py:56-60`; `build-engine.sh:131`
   never sets it), so main costs no pool slot — one input claim corrected.
5. **Memory ledger** (§10): pool cap 1 active + ≤4 neighbours; budgets 40 MB active +
   4×20 MB neighbours = 120 MB ⇒ ceiling const 128 MB, anchored to the FP-R0 live
   measurement (≈18 MB/terrain at view 96, unclamped). All of it flag-gated OFF
   (`CubeSphere.FP_M1_POOL := false`) until the live A/B soak passes.

---

## 1. Ground truth (verified, file:line)

### 1.1 What ships today (FP-S1, live)

- One `VoxelTerrain` (`module_world.gd:270-300`), `max_view_distance =
  near_render_radius()` = **128** in faceted mode (`terrain_config.gd:138-141`,
  FP-S1(a)), `mesh_block_size` 32, `generate_collisions` false. One `VoxelViewer` on the
  player at view 128, vertical ratio 0.5 (`module_world.gd:1667-1678`,
  `terrain_config.gd` VIEWER_VERTICAL_RATIO).
- Crossing (`world_manager.gd:1290-1340`): one-sided detection at `own_dist <
  -FACET_CROSS_HYST` (0.1, `world_manager.gd:42`), FP-S1(c) cooldown
  (`:1299-1301`, `FACET_CROSS_COOLDOWN := 6` at `:49`) and containment check
  (`:1315-1321`), then `TerrainConfig.set_active_facet(to)` (`:1324`),
  `module_world.set_facet(to, old_mod_pos)` (`:1329-1331`) → `_push_facet_carve()` +
  `restream()` (`module_world.gd:1248-1250`) which **frees the terrain and builds a
  fresh one** ramping 48 → 128 over 1.5 s (`module_world.gd:1372-1419`, `:54-55`),
  deferred far-ring re-emit (`facet_far_ring.gd:54-58`, FP-S1(d)), `_flip_settling`
  re-mirror on ramp-done (`world_manager.gd:1334-1335`, `:305-315`). The player
  teleports via `Player.apply_reframe` (`player.gd:136-139`) after the call returns
  (`player.gd:229-231`). This teardown is what FP-M1 §5 eliminates.
- Generator: compiled once, instantiated per epoch with a **frozen `gen_facet`**
  (`module_world.gd:2180-2215`); block-domain all-air early-out before the column pass
  (`module_world.gd:1927`, `FacetAtlas.block_all_air` in `facet_atlas.gd`); per-cell
  junction authority `FacetAtlas.junction_modify` at the buffer-write exit
  (`module_world.gd:2028-2029`) and the analytic exit (`world_manager.gd:343-344`).
- FP-CARVE (patch 0004): the seam bevel is a **per-mesher** clip —
  `VoxelMesherBlocky.set_facet_carve` takes the facet's own-side ridge planes as f64
  (`module_world.gd:1256-1268`, `FacetAtlas.seam_planes_f64`); has_method-guarded, cube
  lip fallback on an unpatched binary (never a hole).
- Edits: `_edit_key(cell)` in faceted mode returns the raw active-lattice `Vector3i`
  (`world_manager.gd:388-391` — chart is null under FACETED) — the FACETED-IMPL §6.2
  `(fid, cell)` key debt, still open. Corruption-across-crossing is latent today.
- Physics is analytic: floor/blocked/DDA/collider/collapse all route through
  `cell_value_at`/`block_id_at` (`world_manager.gd:333-398`); the terrain has no
  collider (`generate_collisions=false`).

### 1.2 The engine facts FP-M1 stands on

- **Viewers are global; every terrain pairs with every viewer.** Each terrain localizes
  each viewer's world position into its own frame and scales view distance by the basis
  (orthonormal ⇒ ×1): `voxel_terrain.cpp:1213-1218` (`get_global_transform().affine_inverse()`,
  `view_distance_scale`), `:1255` (`world_to_local_transform.xform(viewer.world_position)`),
  `:1257-1263` (per-terrain distance = min(viewer distance, terrain
  `_max_view_distance_voxels`)).
- **`bounds` is a first-class clamp**: `VoxelTerrain.bounds` (AABB property,
  `voxel_terrain.cpp:2391`, setter `:2034-2044`, binding `:2249-2251`); both the data box
  and the mesh box are `.clipped()` against it (`voxel_terrain.cpp:1296,1314`). Blocks
  outside bounds are never requested, never allocated, never meshed.
- **A transform change re-places all mesh blocks rigidly** (NOTIFICATION_TRANSFORM_CHANGED
  handler, `voxel_terrain.cpp:867-882` — REVIEW §3.1); FP-R0 proved det=+1 rotated
  streaming live with zero det==0 spam.
- Web thread reality: `PTHREAD_POOL_SIZE=8` hard-coded (`platform/web/detect.py:232`);
  pool observed non-growable (over-request → "thread pool is exhausted",
  `project.godot:59-61`); `WASM_MEM_MAX=2048MB` (`detect.py:233`);
  `DEFAULT_PTHREAD_STACK_SIZE=2048KB` (`detect.py:43,231`). Godot's own web
  `get_processor_count()` is capped at **2** (`platform/web/js/libs/library_godot_os.js:343-346`
  — "TODO Godot core needs fixing to avoid spawning too many threads"), so
  WorkerThreadPool sizes to 2; godot_voxel bypasses that cap via
  `std::thread::hardware_concurrency()` = `navigator.hardwareConcurrency`, **uncapped**
  (`modules/voxel/util/thread/thread.cpp:97-98`). Voxel worker count formula:
  `clamp(round(ratio_over_max·hw), minimum, max(hw−margin_below_max, minimum))`
  (`modules/voxel/engine/voxel_engine.cpp:49-52`); settings read via `ps.get(...)`
  (`voxel_engine_gd.cpp:62-69`) — plain `ProjectSettings::_get`, **feature overrides NOT
  resolved** (`core/config/project_settings.cpp:352-360` vs `get_setting_with_override`
  `:362-372`), so `.web`-suffixed setting overrides cannot steer godot_voxel without a
  module patch. Today `[voxel] threads/count/minimum=4, ratio_over_max=0.0,
  margin_below_max=0` (`project.godot:69-71`; the gd reader clamps margin to ≥1) ⇒ 4
  workers on every machine. `proxy_to_pthread` defaults False (`detect.py:56-60`) and the
  template build never enables it (`build-engine.sh:127-132`) — **main runs on the browser
  main thread and consumes no pool slot** (correcting the task brief's "PROXY_TO_PTHREAD
  main" assumption).
- Patch mechanism: `build-engine.sh:53-59` does `git checkout -f` + `git clean -fdq` on
  **both** checkouts; the patch loop (`build-engine.sh:73-90`, `PATCH_DIR=/patches/godot_voxel`)
  applies **only to the module**. An edit to `detect.py` is wiped every build → §9.3.

### 1.3 Measurements of record (FP-R0)

- Live web spike: a rotated neighbour terrain at view 96 (unclamped bounds) ≈ **18 MB**
  (operator-measured; the headless instrument is `verify_fp_r0.gd:107,149-162`, and the
  planning figure it embeds is 15 MB/terrain at `verify_fp_r0.gd:316` — we budget on the
  larger live number).
- LOD-stride probe (`verify_fp_r0.gd:169-208`): GDScript generator ≈ 1–1.7 s per 32³
  mesh-block region (any ℓ — the column pass dominates); `build_mesh` < 1 ms; per-mesh
  bytes small (KB-scale). Consequence for FP-M1: **anything built per-frame must never
  wait on generation**, and the FP-M2 LOD layer must be background-threaded; FP-M1 itself
  adds no LOD meshes.
- Spike failure signature (live): rendered correctly, then progressive drop-out to blank
  over minutes; recovery only by revert to FP-S1 (no spike). Root cause analysis in §2.

---

## 2. Spike post-mortem — why it blanked (REVIEW §7.2, realized)

The FP-R0 *visual* wiring (`world_manager.gd:246-271`) did, per edge neighbour:
`module_world.spike_rotated_neighbour(nb, 96)` (`module_world.gd:1281-1327`) **plus a
dedicated static `VoxelViewer` at the neighbour's centre-surface**
(`module_world.gd:1334-1345`, planted from `world_manager.gd:260-265`). Compounding
defects, in causal order:

1. **Viewer multiplication.** 4 static viewers + the player's = 5 viewers × 5 terrains =
   ~25 paired stream fields (§1.2 fact 1). Each static viewer sits at a *foreign* facet's
   centre; localized into every *other* terrain's lattice it lands tens-to-hundreds of
   blocks outside that facet's domain and pins a 96-view box of masked-AIR territory.
2. **No bounds clamp.** The early-out (`module_world.gd:1927`) skips the column *compute*
   but the engine still allocates data blocks, map entries, and empty-mesh bookkeeping
   for every block in every box — and schedules the load/mesh tasks that carry them.
3. **No retirement, no caps.** Static viewers never move ⇒ boxes never shrink ⇒ nothing
   unloads (unload happens only on box change, `process_viewers` prev/new diff). Memory
   is monotone; the task queue's steady-state arrival rate exceeds 4 workers × available
   throughput with a 6 ms/frame apply choke (`project.godot:81`), so the active facet's
   remesh/stream tasks queue behind foreign work — progressive starvation → drop-out.

**Design consequences (binding):** exactly one viewer (assert `viewer count == 1` in the
gate); per-terrain `bounds` clamp; a bounded pool with spawn/retire hysteresis and
lifetime caps; workers sized to the machine (§9). Each consequence maps 1:1 to a defect
above; all four are enforced by named gates in §11.

---

## 3. HARD INPUT #1 resolved — the viewer + scope model

### 3.1 One global player viewer serves all facet terrains

- Geometry: the player approaches ridge R between active A and neighbour B. B's terrain
  localizes the player's world position into B's lattice (`voxel_terrain.cpp:1255`).
  Because the seam is a weld of two planes tilted by the dihedral 3.75° (k=24), the
  localized point is in-plane accurate and out-of-plane off by `d·tan 3.75°` ≤ 6.3 blocks
  at d = 96 — negligible against the vertical stream slab (min(viewer vertical 64,
  terrain cap) around the localized y). So B streams **exactly the band of B nearest the
  player** — the part visible across the seam. That is the correct semantics for R1-near;
  everything farther is the far ring (FP-M2 upgrades it to megablock LOD meshes).
- The per-terrain reach is controlled by `max_view_distance` per terrain
  (`voxel_terrain.cpp:1257-1263` takes the min with the viewer's 128): active 128,
  neighbours 96. Rebalancing at a crossing is two property writes, no viewer touch.
- What the single viewer does NOT do: stream a neighbour's *far side* or its centre band
  while the player is mid-facet. It must not — that was the spike's death. From the facet
  centre (ridge ≥ ~100 blocks for edge ≈ 201) neighbours retire entirely (§4.3) and the
  far ring covers them. This bounds the "≥2 facets voxel-real" promise honestly: **real
  voxels on 2–4 facets simultaneously whenever the player is within ~96 blocks of a ridge
  or corner** — which is exactly where complaint (i) is experienced.

### 3.2 The double clamp on foreign territory

- Keep FP-S1(b) `block_all_air` (compute early-out, `module_world.gd:1927`).
- NEW: every pool terrain gets `bounds` = its facet's domain slab at spawn:
  `AABB(x: dom_min.x-2 … dom_max.x+2, y: Y_MIN … Y_MAX, z: dom_min.y-2 … dom_max.y+2)`
  with `dom_min/dom_max` from `facet_atlas.gd` (domain already includes MARGIN_CELLS = 8;
  +2 covers the seam strip), `Y_MIN/Y_MAX` the worldgen vertical envelope (bedrock −64 …
  max surface + tallest tree, from TerrainConfig consts; assert `Y_MAX − Y_MIN ≤ 256`).
  Engine clips every view box against it (`voxel_terrain.cpp:1296,1314`) — zero foreign
  blocks exist, and per-terrain memory has a *geometric* ceiling independent of viewer
  behavior. Apply the same bounds to the active terrain (its masked-AIR halo outside the
  domain is pure waste today); flag-gated with the pool flag so the shipped build is
  untouched until A/B.

### 3.3 Answers to the posed questions

- *Were static viewers the error?* Yes — the multiplier and the pinning (§2 defects 1+3).
  They are deleted with the spike code; FP-M1 adds no new viewer type.
- *Can the single global viewer serve all facet terrains?* Yes, per §3.1; the 3.75° tilt
  makes localization benign for the ≤ 96-block band FP-M1 needs. (At larger k the angle
  shrinks further; this never gets worse.)
- *Is `block_all_air` sufficient?* No — necessary but not sufficient; bounds clamping is
  mandatory (§2 defect 2).
- *Retirement/hysteresis and caps:* §4.3 and §10.

---

## 4. Scene & lifecycle — the Planet Assembly

### 4.1 Scene shape (inside `module_world`; world frame unchanged)

```
WorldManager
 └─ module_world (Node3D @ ZERO in faceted mode — unchanged)
     └─ PlanetRoot (Node3D, transform = FacetAtlas.facet_transform(active).affine_inverse())
         ├─ FacetSlot[A]  (Node3D @ facet_transform(A)) ─ VoxelTerrain  ← active: composite = identity
         ├─ FacetSlot[n1..n4] (Node3D @ facet_transform(ni)) ─ VoxelTerrain  ← render-only neighbours
         └─ (FP-M2: FacetLodMesher lives here too)
    FacetFarRing stays a sibling (its own T_active⁻¹ placement, `facet_far_ring.gd:39`),
    excluded-set = the live pool fids (the spike's `set_excluded` wiring, kept:
    `world_manager.gd:269-270`, `facet_far_ring.gd:62`).
```

- **World frame invariant:** world coords = active facet lattice, exactly as today. The
  active slot's composite transform is `T_active⁻¹ · T_active = I` **by construction** —
  the editable terrain is axis-aligned and `block_id_at`/DDA/GroundCollider/collapse are
  untouched (CLAUDE.md rule 1; `world_manager.gd:333-398`). Nothing in analytic physics
  reads a node transform, so re-designation cannot perturb it.
- Each pool terrain carries: its own generator instance frozen on its fid
  (`_make_generator(fid)`, `module_world.gd:1818,2214` — already supports the override),
  its own `VoxelMesherBlocky` with its own carve blob (`set_facet_carve` with
  `seam_planes_f64(fid)` — the spike's proven recipe, `module_world.gd:1284-1304`), the
  ONE shared baked `VoxelBlockyLibrary`, `mesh_block_size` 32, `generate_collisions`
  false, and its §3.2 bounds. Carve is pushed **once at spawn** — per-mesher planes are
  facet-static, so crossings never re-push (`_push_facet_carve` becomes spawn-time;
  cheaper than today's per-crossing push at `module_world.gd:1248-1249`).

### 4.2 Pool designation

`module_world` keeps `_pool: Dictionary[fid → FacetSlot]`. The active designation is a
fid, not a node identity: `_terrain` (used by edits/`area_meshed`/statistics,
`module_world.gd:1685-1688`) becomes an accessor for `_pool[active].terrain`. Legacy
`set_facet`+`restream` (`module_world.gd:1248-1250,1372+`) is **kept intact** as the
pool-miss fallback and the flag-OFF path.

### 4.3 Spawn / retire policy (lifetime caps)

- **Spawn** neighbour fid when the player's own-side ridge distance
  (`FacetAtlas.own_dist`, already computed per tick in `maybe_cross_facet`,
  `world_manager.gd:1303`) < `D_WARM := 96` for that slot's seam. Spawn is amortized:
  at most ONE terrain instantiated per second (a spawn is node + generator instance +
  mesher — milliseconds; the *streaming* then rides the worker pool at
  distance-priority).
- **Retire** (queue_free + null every ref) when ridge distance > `D_RETIRE := 128`
  (32-block hysteresis ≫ any jitter) **and** the terrain has been live ≥ `MIN_LIVE_S :=
  10 s` (anti-thrash when skirting the D_WARM shell). At most one retire per second.
- **Hard caps:** `POOL_MAX_NEIGHBOURS := 4` (const, asserted). Geometry guarantees ≤ 3
  wanted concurrently (edge ≈ 201 > 2·D_WARM, so at most 2 ridges + 1 diagonal are within
  96 blocks — §8), so 4 is slack, and an LRU eviction backs the cap anyway.
- **Why `D_WARM` stays 96 (lead-time analysis, FP-M1c(v2)).** With the per-slot spawn ramp
  (§5.1c) a neighbour now needs only `RAMP_SECONDS` (1.5 s) of lead to finish its view ramp,
  and streaming rides distance-priority behind the far-ring cover. At D_WARM = 96 the lead
  from the shell to the ridge is 96 / speed = **17.5 s walking** (5.5 b/s), **10.1 s running**
  (9.5 b/s), **6.0 s flying** (16 b/s) — all ≫ 1.5 s, so the ramp always completes before the
  crossing and the border cross finds `to` already at full 96-stream (only the small ramped
  96→128 grow remains). Raising D_WARM is *counter-productive*: the facet HALF-edge is ≈ 100
  blocks (edge ≈ 201), so D_WARM ≳ 100 would put ALL FOUR ridge-neighbours inside the warm
  shell whenever the player is near the facet centre → 4 live neighbours constantly → the full
  `1×40 + 4×20 = 120 MB` worst case pinned at all times, hard against the `POOL_MEM_BUDGET_MB
  := 128` ceiling (§10) with no headroom, and thrash pressure at the shell. 96 is the sweet
  spot the geometry already dictates; **the ramp, not the lead time, is the freeze fix.**
- **Diagonal facets** (share only a corner): FP-M1c ships edge neighbours only (the
  corner hole is covered by the far-ring quad + both edge terrains); FP-M1d adds the
  diagonal (fid = neighbour-of-neighbour across the two flanking slots) when BOTH flanking
  ridge distances < D_WARM. At the 8 singular cube-corner vertices there is no diagonal
  (3 facets meet) — nothing to add (§8).
- Neighbour terrains are **render-only**: no edits routed to them in FP-M1c;
  FP-M1d mirrors their fid's existing edits into them at spawn (§6.4).

### 4.4 What stays byte-identical

The whole assembly is behind `CubeSphere.FP_M1_POOL := false` (new const beside FACETED
at `cube_sphere.gd:47`). Flag OFF ⇒ today's single-terrain scene graph, teardown
crossing, and FLAT `verify_feature` 6027/0 byte-identity (all new code is
FACETED-and-flag-gated). The M4 cover/ramp machinery is untouched (curved-mode-only
users remain, REVIEW §7.7).

---

## 5. Crossing = re-designation (kills the freeze and the restream-from-zero)

### 5.1 The new `maybe_cross_facet` tail (steps, vs today)

Detection, cooldown, containment, `set_active_facet`, far-ring `set_active`, player
reframe, and the return contract are **unchanged** (`world_manager.gd:1290-1324,
1332-1339`; `player.gd:136-139,229-231`). The replaced part is `:1329-1331`
(`module_world.set_facet` → teardown). New tail, in order:

1. `TerrainConfig.set_active_facet(to)` — unchanged (`world_manager.gd:1324`; memo
   clears per `terrain_config.gd:585-588`). The analytic world (cell_value_at, floor,
   walls) is now B's lattice — same as today.
2. `module_world.redesignate(to)`:
   a. If `to` not in `_pool` (teleport, pool-miss edge): **fallback** to legacy
      `set_facet(to, pos)` teardown (`module_world.gd:1248-1250`) + immediate pool spawn —
      degraded to FP-S1 behavior, never a blank. Gate counts these (must be ~0 in soaks).
   b. `PlanetRoot.transform = FacetAtlas.facet_transform(to).affine_inverse()` — ONE
      assignment. Every child slot re-composes rigidly; B's composite becomes identity
      (axis-aligned, editable), A's becomes the rotated render-only neighbour. The engine
      re-applies the parent transform to all mesh blocks (`voxel_terrain.cpp:867-882`) —
      sub-frame, no meshing.
   c. Rebalance (**FP-M1c(v2) per-slot ramp — the border-hitch fix**): `to`'s view
      TARGET becomes 128 and RAMPS up from its current 96 over `RAMP_SECONDS` (1.5 s),
      driven one-slot-per-frame in `module_world._ramp_pool_step`
      (`module_world.gd`, `_process`) — NOT jammed in one write. Jamming the 96→128 delta
      annulus in a single process pass re-queues its whole rim at once → a generation burst
      → the main-thread mesh-apply (`voxel/threads/main/time_budget_ms`) spikes → the freeze
      the user saw *when crossing a facet border*. `from` shrinks to 96 immediately (a shrink
      only UNLOADS blocks — cheap). The engine diffs prev/new boxes (`process_viewers`) — only
      the delta annulus streams/unloads. No teardown. Likewise a NEIGHBOUR SPAWN builds at
      `RAMP_START_BLOCKS` (48) and ramps 48→96 (same step), so *approaching* a border no longer
      bursts either. The ramp is the exact load-shaping the active-facet restream already used
      (`:54-73`), generalized per-slot.
   d. Designate edits: `_terrain` accessor now returns `_pool[to]`; pending VoxelTool
      writes route there. Edit keys are `(fid, cell)`-global (§6) — nothing migrates.
3. `_facet_ring.set_active(to)` — unchanged deferred re-emit (`facet_far_ring.gd:54-58`),
   plus the excluded-set update for the (unchanged-membership) pool.
4. Player reframe + cooldown — unchanged.

Deleted from the faceted crossing path (kept for curved/fallback): `_flip_settling`,
`_remirror_module_edits` (nothing was dropped — no restream happened), the ramp, the
carve re-push, the generator build. **A faceted crossing performs zero allocation of
terrain-scale objects.**

### 5.2 No-near-hole argument (sprint and fly)

- B's terrain has been live and streaming since ridge distance < 96. Walking (5.5 b/s)
  or sprinting (9.5 b/s, `player.gd:17-18`) from the D_WARM shell to the ridge takes
  ≥ 10 s; the B-side band inside view 96 ∩ B-bounds is roughly half a 96-disk — less
  work than the fresh-spawn 128-disk that FP-S1's gate fills in ≤ ~10 s on 4 workers,
  and streamed at distance-priority (nearest first), so the seam-adjacent core is meshed
  long before arrival. Post-§9 (6–10 workers on typical visitors) the margin widens.
- Even in the adversarial cases — fly-hack at 32 b/s (`player.gd:19,259`: fly 16 ×2)
  crossing the shell in 3 s, or a spawn near a ridge — there is **no frame where geometry
  is removed**: A's fully-streamed field persists (rotated), B fills nearest-first, the
  analytic floor carries physics regardless (`world_manager.gd` rule-1 stack). The R3
  blank mechanism (free-all + view-48 restart, REVIEW §4) no longer exists in the code
  path. Worst case is "B's far side pops in over a few seconds" — cosmetic, gated.
- Gate quantifies it: scripted sprint crossing on live web, PerfHUD max frame ≤ 50 ms,
  `is_area_meshed` over the B-side 24-block core true at commit (converted to B-local —
  the spike's AABB lesson, `module_world.gd:1690-1693` pattern), zero `facet cross` log
  storms.

---

## 6. `(fid, cell)` global edit keys (FACETED-IMPL §6.2 debt — prerequisite)

### 6.1 Why first

Active-lattice `Vector3i` keys (`world_manager.gd:388-391`) are re-interpreted in B's
lattice after any crossing — silent corruption, masked today only by B's domain masking
(REVIEW §1.4). Re-designation makes edits *first-class across facets* (A's terrain keeps
rendering after a crossing), so the debt becomes user-visible. Land it before any pool
work.

### 6.2 Key spec

- `FacetAtlas.edit_key(fid: int, cell: Vector3i) -> int` (pure, static):
  `((fid·2^18 + (cell.x + 131072))·2^18 + (cell.z + 131072))·2^11 + (cell.y + 512)`.
  Ranges: fid < 4096 (3456 facets), |x|,|z| < 131072 (decorrelation offset O pushes
  lattice coords to ~3·10⁴, `facet_atlas.gd:107-108` — 4× headroom), y ∈ [−512, 1535].
  Total 59 bits — a plain GDScript int. Plus `edit_key_unpack(key) -> [fid, Vector3i]`.
- `WorldManager._edit_key` (`world_manager.gd:388-391`) grows the branch:
  `if CubeSphere.FACETED: return FacetAtlas.edit_key(TerrainConfig.active_facet(), cell)`.
  Ownership is total and unique: edits are active-facet-only, the DDA cannot cross a
  ridge (beyond-ridge cells are masked AIR — FACETED-IMPL §6.3), and junction-strip
  cells are no-build (FP4 rule); assert in `_write_cell` that no `Vector3i` key ever
  enters `_edits` under FACETED (the IMPL §6.4 gate).
- Read path: `cell_value_at` (`world_manager.gd:334`) composes the same key — an A-edit
  is invisible from B-active sessions *by key*, matching the domain mask (correct: that
  cell is masked AIR in B's lattice anyway).
- Window-keyed PERF indexes (`_edit_columns`, `_placed_top`) are rebuilt at each
  crossing by filtering `fid == active` (the `_rebuild_window_indices` pattern,
  `world_manager.gd:1376-1379`) — bounded by edit count, deferred off the crossing frame
  if it ever shows in PerfHUD.
- Curved mode keeps the 43-bit chart key; FLAT non-faceted keeps `Vector3i`
  (byte-identity).

### 6.3 Save-format note

`save_edits`/`load_edits` (`world_manager.gd:1580,1605`) are key-agnostic (IMPL §6.2) and
no user-facing persistence ships today (the M2 region machinery is in-memory). Rule of
record: faceted bundles henceforth carry `key_format = "fidcell-v1"`; a loader
encountering a FACETED bundle without it must refuse (there are none in the wild — this
is a fence, not a migration).

### 6.4 Neighbour-terrain edit mirroring (FP-M1d)

A neighbour terrain is pure worldgen; a crater the player dug on B while B was active
would visually heal when B is seen from A. Fix (cheap, bounded): at spawn of fid N,
iterate `_edits`, unpack, and for `fid == N` apply the value via N's terrain VoxelTool —
the stored cell IS N-lattice, no transform. While N is a live *neighbour*, new edits
cannot target it (active-only), so spawn-time mirroring is complete. Gate: mirror parity
(neighbour terrain voxel == `cell_value_at`-with-N-active for every edited cell).

---

## 7. Seam correctness with two live voxel facets

Mechanism (proven by FP-R0 + FP-CARVE): each terrain's generator masks beyond its own
ridges (`junction_modify` on its frozen fid, `facet_atlas.gd:junction_modify`); the two
welded planes are exact complements (`own_A(p) = −own_B(p)`, gate G-J1 at
`verify_faceted.gd:396-397`); each mesher clips its junction sentinels to its OWN planes
(patch 0004, per-mesher blob). The two cut faces at a ridge are **coplanar with opposite
windings** — with back-face culling each is visible only from its own side: no z-fight,
no double-solid.

New gates (headless, `verify_faceted.gd`, driven via the retained spike probes
`spike_library`/`_make_generator(fid)` under the FP_M1_POOL flag):

- **G-M1-SEAM-1 (mesh-level complementarity):** for ≥ 3 sampled ridges (incl. one
  cube-edge seam and one flanking a singular corner), `generate_block` + `build_mesh`
  the straddling 32³ regions from BOTH sides; extract faces lying on the seam plane;
  assert (a) A-side and B-side cut faces are coplanar within 1e-3 in world space
  (compose through both facet transforms), (b) normals oppose, (c) no vertex of either
  mesh penetrates beyond its own plane by > 1e-3 (no double-geometry lip).
- **G-M1-SEAM-2 (carve resolved both sides):** both meshers report their carve blob
  enabled and every junction sentinel resolved (non-negative slot; `oob_seen == 0` —
  the patch-0004 diagnostics, docs/COSMOS-FACETED-CARVE.md C4), on an unpatched binary
  the gate SKIPs with the cube-lip note rather than fails.
- **Live seam soak:** stand at a ridge with both fields meshed ≥ 5 min; no flicker
  (z-fight would strobe), no console errors, heap flat (§11 soak protocol).

Carve/edit "re-designation" at a crossing is a no-op by construction: planes are
per-mesher facet-static (§4.1), edit keys are global (§6).

---

## 8. Corner and twist-singularity policy (bound FP5, don't solve it)

- **Ordinary facet corners (4 facets meet):** pool = the 2 flanking edge neighbours
  (FP-M1c) + the diagonal (FP-M1d, §4.3). Crossing containment (`world_manager.gd:
  1315-1321`) already defers uncontained corner landings; unchanged. Gate: walk all 4
  corners of the spawn facet — no storm (`facet cross` lines ≤ 1 per genuine crossing),
  no pool over-cap.
- **The 8 singular cube-corner vertices (3 facets, quarter-index holonomy — IMPL §8):**
  - Live terrains across the two *edge* seams are safe — rotation is rigid and each
    terrain is self-consistent in its own lattice; lattice incompatibility across the
    seam is a *junction-geometry* problem, not a rendering one.
  - There is no diagonal facet; never spawn one (the neighbour-of-neighbour walk must
    detect the 3-cycle and bail — assert it).
  - Junction cells within `SINGULAR_EXCLUDE := 4` cells of the singular vertex keep
    today's single-plane rendering (`junction_modify` picks the nearest seam,
    `facet_atlas.gd` corner-cell note) and are EXCLUDED from G-M1-SEAM-1's
    complementarity assert (FP5 owns their polish).
  - Crossing near a singular vertex: containment defers exactly as at ordinary corners.
    Gate: a scripted walk around one singular vertex — no storm, no blank, pool ≤ 1+2
    there.
- Twist-field (`FACET_TWIST`, IMPL §8.1) remains false; FP-M1 introduces no dependency
  on lattice alignment between facets — the assembly is compatible with a future twist
  bake by construction (all cross-facet math routes through `facet_transform`).

---

## 9. HARD INPUT #2 — the web thread-pool rebuild

### 9.1 Sizing (the accounting)

Pool consumers on our build (no PROXY_TO_PTHREAD, §1.2): Godot WorkerThreadPool = 2
(web `get_processor_count()` cap, `library_godot_os.js:346`), audio mix ≤ 1, voxel
general pool = N (+ the "I/O thread counts as one" note, `voxel_engine.cpp:47-48` —
budget 1), transient/spare 1. Non-voxel budget **R = 5**.

- **`PTHREAD_POOL_SIZE = 16`** (was 8). Ceiling logic: N_voxel ≤ 16 − R = 11; we cap
  N_voxel at 10 (below). Idle preallocated Workers cost browser-side JS only; wasm
  stacks (2 MB each, `detect.py:43,231`) are allocated per *running* thread — worst
  ≈ 15 × 2 MB = 30 MB against `WASM_MEM_MAX=2048MB` (`detect.py:233`). Boot cost of 8
  extra Workers is gated (load-time delta ≤ 1 s).
- **Voxel auto-scale (per-visitor):** `project.godot [voxel]`:
  `threads/count/minimum=3`, `threads/count/ratio_over_max=0.7`,
  `threads/count/margin_below_max=1` — shared native+web (native simply scales; the
  4-pin was only ever a web constraint, `project.godot:50-62`).
- **The absolute web cap** (formula has no absolute-max knob and hw is uncapped,
  §1.2): godot_voxel patch **0005** — in `util/thread/thread.cpp:97-98`, under
  `#ifdef __EMSCRIPTEN__`, return `min(std::thread::hardware_concurrency(), 14u)`.
  Resulting N_voxel by visitor cores (formula `voxel_engine.cpp:49-52`):
  hw=2 → 3 (min clamps; 1-core oversubscription accepted, pool has room), hw=4 → 3,
  hw=8 → 6, hw=12 → 8, hw≥14 → 10. Worst pool occupancy 10 + 5 = **15 ≤ 16** ✓.
  (Feature-tag `.web` overrides can NOT do this — godot_voxel reads raw `ps.get`,
  §1.2 — and patching the read to `get_setting_with_override` is a larger surface than
  one clamped line.)
- `threads/main/time_budget_ms` stays 6 (raise only behind the existing smoothness
  gate, REVIEW §7.2).

### 9.2 Why this is the spike-crux's other half

FP-M1's steady state adds up to 4 neighbour delta-annulus streams to the active facet's
load. On the pinned 4 workers a burst (crossing rebalance + two spawns) transiently
queues behind ~1–1.7 s/block generation (§1.3). At 6–10 workers the same burst clears
proportionally faster, and the §3/§4 clamps bound the queue's *size*. Pool cap (5
terrains) and worker ceiling (10) are co-designed: even a pathological all-terrains-dirty
state is ≤ 5 concurrent box-diffs on ≥ 3 workers with distance priority — the active
field always holds the nearest tasks.

### 9.3 Persisting the `detect.py` edit (the patch mechanism)

`build-engine.sh:53-59` resets BOTH checkouts (`git checkout -f` + `git clean -fdq`);
the existing loop patches only `/patches/godot_voxel` (`build-engine.sh:73-90`). A sed
in build-engine.sh would rot silently against upstream changes. **Recommended: a Godot
engine patch series mirroring the module one** —

- `docker/engine/patches/godot/0001-web-pthread-pool-size-option.patch`: adds a scons
  option `pthread_pool_size` (default **8** — upstream-identical) to
  `platform/web/detect.py` and replaces the literal at `:232` with it.
- `build-engine.sh`: after the godot clone_pinned, apply `${PATCH_ROOT}/godot/*.patch`
  to `${SRC}` with the same FATAL-on-fail + sha256-into-BUILD-INFO discipline
  (`build-engine.sh:73-90`); pass `pthread_pool_size="${WEB_PTHREAD_POOL}"` in
  `build_web_templates` (`build-engine.sh:127-132`).
- `versions.env` gains `WEB_PTHREAD_POOL=16` (single source of truth, per its charter).
- `scripts/build.sh` already mounts `${ENGINE_DIR}/patches:/patches:ro`
  (`scripts/build.sh:61`) — no plumbing change.
- `EMSDK_VERSION=3.1.64` stays pinned (`versions.env` — the #1 web failure mode).

### 9.4 COOP/COEP + export dependency

Unchanged and load-bearing: threads ⇒ SharedArrayBuffer ⇒ cross-origin isolation; the
runtime container already sends COOP/COEP on every response and `deploy.sh` verifies it.
The bigger pool changes nothing about headers. Note the operational split: the
PTHREAD_POOL_SIZE change requires the ~24-min `scripts/build.sh` + re-export; the
`[voxel]` settings changes require **only** `scripts/export-web.sh` (baked into the
exported project, `project.godot:62` note) — stage them together (§11 FP-M1b) but know
the revert knobs are independent.

---

## 10. Memory ledger (never-OOM)

| Item | Budget | Basis |
|---|---|---|
| Active terrain, view 128, bounds-clamped | 40 MB | 18 MB @ 96 (FP-R0 live) × (128/96)² ≈ 32, +25% margin |
| Neighbour terrain, view 96, bounds-clamped | 20 MB each | 18 MB measured **without** bounds clamp — clamp strictly reduces |
| Pool worst case (1 + 4) | **120 MB** ⇒ ceiling const `POOL_MEM_BUDGET_MB := 128` | asserted headless (static-heap delta per spawn, `verify_fp_r0.gd:107-162` instrument) + live A/B |
| Thread stacks (§9) | +30 MB worst | 15 threads × 2 MB |
| Far ring, atlas, carve blobs | < 2 MB | FP2 ledger (IMPL §9) |

Rules of force: `FP_M1_POOL` default **OFF**; default-ON only after the live A/B soak
(§11) shows pool-ON heap delta ≤ 150 MB and a flat slope. Caps are consts asserted in
verify (`POOL_MAX_NEIGHBOURS`, `POOL_MEM_BUDGET_MB`, `D_WARM/D_RETIRE/MIN_LIVE_S`);
retirement is prompt (§4.3) and refs nulled (leak class #1, §12.1). GPU-side buffers are
not measurable headless — the live A/B (browser `performance.memory` + wasm
`memory.buffer.byteLength`, sampled by the existing PerfHUD) is the authority, per the
never-OOM rule.

---

## 11. Sub-stages — each independently shippable, demo never regresses

Common exit gates for EVERY stage: `verify_faceted` all-green (extended per stage),
FLAT byte-identity `verify_feature` **6027/0**, flag-OFF byte-identity where a flag
exists, live-web deploy loads and plays, and the **soak protocol**: ≥ 15 min unattended
on the deployed build with the stage's feature active — sampled every 10 s: wasm heap +
JS heap (flat slope, < ±10% band after warm-up), active-facet `area_meshed` over the
player core stays true, zero console error storms, no blank. This is precisely the axis
the spike failed on; no stage ships without it.

- **FP-M1a — `(fid, cell)` edit keys** (§6). Pure debt; no visual change.
  Gates: **G-M1-KEY** — headless cross-and-return (two seams) with edits placed on both
  facets pre-cross: every edit, every sampled cell, player position round-trip exact;
  `_write_cell` asserts no `Vector3i` key under FACETED; index-rebuild parity
  (`_edit_columns`/`_placed_top` re-derived == incremental). Live: smoke only.
- **FP-M1b — the thread rebuild** (§9). Engine patch series + patch 0005 + `[voxel]`
  scaling + `WEB_PTHREAD_POOL=16`. Gates: BUILD-INFO records both patch series with
  hashes; FLAT 6027/0 re-run **on the new binary**; `verify_faceted` green; live soak on
  a ≤ 4-core and a ≥ 12-core machine — logged voxel thread count matches the §9.1 table
  (verbose "automatic thread count"), no "thread pool exhausted", load-time delta ≤ 1 s;
  crossing-refill wall-clock measurably ≤ FP-S1 baseline. Revert knob: `WEB_PTHREAD_POOL=8`
  + settings revert (independent, §9.4).
- **FP-M1c — Planet Assembly + re-designation** (§3, §4, §5), flag `FP_M1_POOL` OFF→A/B→ON.
  The single user-facing stage: **both live complaints fixed together** — real voxels on
  2–3 facets at every ridge/corner approach, and a sub-frame crossing.
  Gates: **G-M1-POOL** (exactly 1 VoxelViewer in-tree; pool ≤ 1+4; every terrain's
  bounds ⊆ its facet slab; spawn/retire hysteresis honored under a scripted ridge-skirt
  walk; retired terrains freed — Object count returns to baseline); **G-M1-XDES**
  (re-designation frees no terrain — node ids stable; PlanetRoot transform assigned
  once; active composite == identity to 1e-9; containment landing interior);
  **G-M1-MEM** (per-spawn heap delta ≤ budget; pool total ≤ `POOL_MEM_BUDGET_MB`);
  **G-M1-SEAM-1/2** (§7, headless); cross-and-return byte-identity re-run (now with the
  pool live). Live A/B soak (§10) + scripted sprint crossing: PerfHUD max frame ≤ 50 ms,
  B-core meshed at commit, ≥ 2 facets visibly voxel-real at a ridge, pool-miss fallback
  count 0. Then default-ON.
- **FP-M1d — hardening + debt burn-down.** Diagonal-corner neighbour (§4.3);
  neighbour edit mirroring (§6.4) with the mirror-parity gate; awake-debris re-frame at
  re-designation via `crossing_transform` on the `m5c_glue_bodies` walk (IMPL §6.1
  step 5 — bounded inventory); singular-corner asserts (§8); quarantine the faceted
  teardown path to fallback-only and mark the superseded decisions (§13) in
  COSMOS-FACETED-IMPL §4.2/§5.2/§6.1 and the stale "can't rotate" comments
  (`module_world.gd:345-349`, `main.gd:118`, `world_manager.gd:946` per REVIEW §8
  FP-M4 list — pull forward). Gates: corner + singular-vertex walk soaks (§8); live
  soak ≥ 30 min with ≥ 6 crossings including a cube-edge seam.

Sequencing: M1a unblocks everything and is invisible; M1b is the ~24-min rebuild —
land early so every later soak runs on the real thread model; M1c is deliberately the
first scene-touching stage AND the one that delivers both user fixes (they are coupled:
re-designation is only safe *because* the pool exists, and the pool is only worth its
memory *because* crossings stop paying teardown); M1d makes it boringly solid. A revert
at any stage is one flag (M1c/M1d) or one versions.env value + export (M1b).

---

## 12. Adversarial review of this design (where it breaks at 3 a.m.)

1. **Minute-30 leak candidates, ranked:** (a) retired terrains kept alive by a stray
   GDScript ref (pool dict, closure, the far-ring excluded list) — engine maps free on
   node free, but only if the last ref drops; gate counts live VoxelTerrain objects.
   (b) Ridge-skirt thrash at D_WARM: spawn/retire cycling per second — the 32-block +
   10 s hysteresis and 1/s amortization bound it; the skirt-walk gate measures churn.
   (c) Far-ring re-emit churn per pool change — reuse the FP-S1(d) deferred/budgeted
   path only. (d) The engine unloads only on box *change*: an AFK player accumulates
   nothing new (boxes static) — safe; but an AFK player parked exactly on a ridge keeps
   5 live terrains forever — that IS the steady state the ceiling is sized for.
2. **Corner re-designation landing outside all of B's ridges:** containment
   (`world_manager.gd:1315-1321`) defers it — same shipped behavior; the residual risk
   is a player wedged past two ridges where every slot defers while analytic ground is
   masked AIR. The blocked()-wall prelude (IMPL §5.3) still stands in FP-M1 and fires
   *before* the wedge is reachable at HYST 0.1. Gate walks all four corners + one
   singular vertex; if a deferral loop is ever observed, the resolution is the diagonal
   commit (M1d) — designed, not improvised.
3. **The pool cap vs "≥ 2 neighbours" under the ceiling:** if live A/B shows per-terrain
   cost ≫ 18 MB (e.g. ANGLE shadow copies of vertex buffers), the mitigation ladder is
   ordered and pre-agreed: neighbour view 96 → 64 (−56% area), tighten the bounds
   y-slab, cap 4 → 2 (mid-ridge UX intact; corners lose the diagonal). The user-visible
   promise degrades gracefully and never below "the facet you're walking toward is real
   voxels". Never-OOM outranks the want — that trade is locked by the project rule.
4. **The thread rebuild breaks the web gate:** the three real hazards are (i) emsdk
   drift — pinned, untouched; (ii) some browser throttling 16 Workers at boot — gated
   load-time delta + tested on Chromium/Firefox/WebKit before default-ON, revert is one
   env value; (iii) oversubscription on 4-core devices (3 voxel + 2 WTP + audio + main
   > 4 cores) — identical to today's shipped 4-pin (4+2+1+main), i.e. no regression,
   and ratio-scaling *improves* it on 2-core devices vs today.
5. **`is_area_meshed` frame confusion** (the spike's own bug class): every new gate/HUD
   box on a *neighbour* terrain must convert world→terrain-local
   (`module_world.gd:1690-1693` pattern). Centralize in one helper
   (`_area_meshed_local(terrain, world_aabb)`); forbid raw calls by review.
6. **Byte-identity erosion:** reparenting the active terrain under PlanetRoot changes
   node paths and transform-notification timing even at identity composite. All of it
   is flag-gated; the flag-OFF assert (scene-graph shape == shipped) is part of
   G-M1-POOL, and FLAT 6027/0 runs per stage. The one shared-file hazard is
   `project.godot [voxel]` (native+web) — M1b's native verify runs cover it.
7. **What this design does NOT deliver (honest scope):** voxel detail on facets beyond
   ~96 blocks of a ridge (far ring quads until FP-M2's LOD mesher), cross-seam
   break/place (FP4), debris correctness far from the player, and the FP5 singular
   junctions. Each has a named owner-stage; none blocks the two complaints FP-M1 fixes.

---

## 13. Superseded-decisions ledger (delta to REVIEW §9)

| # | Decision | Status after FP-M1 |
|---|---|---|
| 1 | Per-terrain static VoxelViewers (FP-R0 visual spike) | **Rejected permanently** — one global player viewer; viewer-count==1 asserted (G-M1-POOL) |
| 2 | Unbounded terrain streaming domains | **Superseded** — per-terrain `bounds` slab is mandatory for every pool terrain (§3.2) |
| 3 | Crossing = `set_facet` teardown + restream (`module_world.gd:1248-1250`) | **Superseded** for faceted (fallback-only, M1d); re-designation (§5) is the path |
| 4 | Voxel workers pinned to 4 / PTHREAD_POOL_SIZE=8 (`project.godot:69-71`, `detect.py:232`) | **Superseded** — pool 16, adaptive 3‥10 workers, web hw clamp 14 (§9) |
| 5 | Active-lattice `Vector3i` edit keys under FACETED (`world_manager.gd:388-391`) | **Corrected** — `(fid, cell)` 59-bit int keys (§6), `fidcell-v1` fence |
| 6 | Engine (Godot) source is never patched (`build-engine.sh` module-only loop) | **Superseded** — `patches/godot/` series with the same FATAL + hash discipline (§9.3) |
