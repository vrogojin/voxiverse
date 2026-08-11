# COSMOS SHARP-SLOPE FACET PARITY — mountain ladder + fall-under root cause & fix design

Status: ROOT-CAUSED (measured against the served pck, 2026-08-11). Fix design behind `FP_SLOPE_MANIFEST_HEAL`.
Symptom (live, user-reported): on a snowy mountain (facet 578, NAV ~13051,102,8088 / close-up 13038,69,8156)
the player (1) sinks/falls UNDER the slope while walking on it, and (2) the slope renders LADDER-style
(stepped full cubes) instead of the SHARP-SLOPE 45° carve shipped in `feat/voxiverse-sharp-slope` (8b26257).

## 1. What was ruled OUT first (do not re-litigate)

* **"slope_run is not wired on the faceted/analytic path" — FALSE.** `resolve_cell`'s `slope_run = -1`
  default does NOT disable the carve; it recomputes it per cell via `_slope_fires_only` /
  `_slope_whole_targets` (`godot/src/world/terrain_config.gd:1355-1364`), byte-identical to the hoisted
  worker pack. The GDScript module worker hoists and passes a real run
  (`godot/src/world/voxel_module/module_world.gd:3645,3659`); the analytic funnels recompute it. Both agree.
* **"the C++ generator (FP_CPPGEN) lacks the carve" — FALSE.** Patch
  `docker/engine/patches/godot_voxel/0007-cosmos-cpp-generator.patch` ports `_corner_targets`,
  `_slope_fires_only` (incl. the B_MOUNTAINS 1–2 blk/cell gate), `slope_run_pack/targets`, and the
  resolve_cell slope branch line-for-line (patch hunks at ~:846-925, :1621-1660).
* **"the carve does not fire on this mountain" — FALSE.** Probed against the SERVED pck
  (build/web/index.pck, flags baked: FACETED=true, FP_CPPGEN=true, FP_MANIFEST_SLICE=true):
  facet 578 region x∈[13020,13070] z∈[8080,8170]: **955 of 1125 columns fire** (biome B_MOUNTAINS=9 on
  1119/1125). The close-up column (13038,8155): `g=67 biome=9 srun=0x14665 fires=true`,
  whole targets (68,69,69,67).

## 2. Root cause (one cause, both symptoms)

**The SHARP-SLOPE mesh models never reach the live generators: `FP_MANIFEST_SLICE` (ON live) defers the
slope-manifest bake past generator construction, and every generator freezes the still-EMPTY slope ARID
tables. Every generated SLOPE cell therefore takes the "unbaked → plain cube" fallback in the RENDER,
while the ANALYTIC collision (TerrainConfig, always exact) carves the plane. Render is a ladder of full
cubes 1–3 blocks ABOVE the physics floor → the player stands inside/under the rendered slope.**

The chain, file:line:

1. `module_world.setup()` calls `_build_gen_manifest(library)` (`module_world.gd:351`). With
   `FP_MANIFEST_SLICE` ON the slope bake is **skipped there**:
   `var slope := 0 if slice else _build_slope_manifest(library, total)` (`module_world.gd:1116`;
   likewise wet `:1094` and snow-fill composites `:1112`). `_slope_arid` / `_snow_slope_arid` are still
   the **empty default arrays** (`module_world.gd:213-214`; only `_build_slope_manifest` ever resizes
   them, `:1428-1433`).
2. `setup()` then builds the generator (`module_world.gd:356` → `_make_generator` `:3212`), which
   **freezes** the tables: `gen.set("slope_arid", _slope_arid)` / `gen.set("snow_slope_arid", …)`
   (`:3984,3987`) and `gen.set("model_count", _library_model_count())` (`:4017`). Under FP_CPPGEN the
   compiled `VoxelGeneratorCosmos` copies them into its immutable `Parameters`
   (`:4069-4070` → patch 0007 `:421-422`). Pool-slot generators (FP_M1_POOL / FP_NB_FULLRES neighbours)
   are frozen the same way at slot spawn (`module_world.gd:1871`), largely during boot prewarm.
3. The deferred cold bake later runs (`begin_deferred_boot_work` → `begin_deferred_manifest_bake`,
   `world_manager.gd:1393-1397`, `module_world.gd:1159-1185`) and `_build_slope_manifest` **reassigns**
   `_slope_arid = PackedInt32Array()` (`:1428`) before filling it. PackedInt32Array is copy-on-write:
   the module's MEMBER now points at the filled table, but **every already-built generator keeps the old
   empty array** (and a stale `model_count` fence that would clamp the new ARIDs anyway).
4. Stage 3 of the cold bake re-bakes the library and re-ramps the near view to force re-generation
   (`_manifest_cold_step` `:1178-1184`, `_manifest_remesh_near` `:1192`) — but re-generation runs the
   SAME stale generator objects, so slope cells still emit the cube fallback. **Nothing ever refreshes a
   live generator's frozen tables**; the only heals are full generator rebuilds (`restream()` `:2698`,
   a fresh pool-slot spawn `:1871`), which don't happen for the boot-spawned active/pooled facets.
5. Cube fallback site, C++ (the served render path): patch 0007 `cell_to_arid` FAM-SLOPE branch —
   `pslot = id*SLOPE_STRIDE + (modifier & 0xFFF)`; snow-state → `snow_slope_arid[pslot]`, else
   `slope_arid[pslot]`, **else `cube_arid[id]` — a FULL CUBE** (patch hunk at ~:1893-1900; `nslope==0`
   live, so the fallback is taken for every slope cell). GDScript twin: `module_world.gd:1733-1737` and
   `:835-840`.
6. The ANALYTIC collision path never touches ARIDs: `floor_under`/`blocked`/DDA evaluate
   `_occ_span(cell_value_at(...))` (`world_manager.gd:4229-4273`) on the TRUE resolve_cell value, and
   `GroundCollider` builds real slope prisms from `col_slope_run_of`
   (`ground_collider.gd:566-624`, `world_manager.gd:1761-1767`). Collision = the carved plane. Correct.

### Quantified divergence at the repro column

Column (13038, 8155), fid 578: `g=67`, run `0x14665` → whole corner targets (68,69,69,67), run cells
y∈{67,68}. **Render** (cube fallback): two stacked full cubes → visible top at y=69 across the whole
cell. **Collision**: the clipped-plane surface, as low as y=67.0 at the low-corner footprint.
**Gap ≈ 2 blocks here; bounded by SLOPE_MAX_SPREAD = 3** (`terrain_config.gd:98`). The player walks the
rendered top, physics settles them onto the plane below → camera ends up inside the cubes — exactly the
mtn-pan-1.jpg capture (pos y=69, aim block at y=68 reads as a wall). With 955/1125 columns firing, the
whole flank renders as the pre-8b26257 ladder while physics walks the carved ramp underneath.

The neighbour column set also explains the "snowy" specificity: cold columns additionally lose the
deferred snow-fill COMPOSITE models (`:1112`) and wet models (`:1094`) to the same staleness — more
cube-fallback where snow planes should render, same render-above-physics direction.

### Why the gates missed it

* `verify_cppgen` compares C++ vs GDScript **resolve_cell values / buffers with tables passed at test
  setup** — both sides get whatever tables the test bakes; it never runs the FP_MANIFEST_SLICE deferred
  lifecycle.
* `verify_manifest_slice` asserts the **module's member tables** go from 0 → baked
  (`manifest_baked_count` `:1213`) — it never inspects a generator's FROZEN copy, which is the one the
  workers read.
* The original parity proof (cd11ba0) predates both FP_CPPGEN's frozen Parameters and FP_MANIFEST_SLICE.
  The regression is the **manifest lifecycle**, introduced by FP_MANIFEST_SLICE (load-profile round 4,
  `cube_sphere.gd:2173-2185`) after the faceted pivot — not the sharp-slope worldgen, which is intact.

## 3. Fix design — `FP_SLOPE_MANIFEST_HEAL` (byte-off flag in cube_sphere.gd)

Restore parity by making the deferred bake actually reach the render: **after the cold bake completes,
rebuild and swap the generator on every live terrain, then let the existing stage-3 re-ramp regenerate.**
Pushing tables into live generator objects is rejected: the GDScript gen is read by running voxel
workers (data race), the C++ `Parameters` are deliberately immutable, and the stale `model_count` OOB
fence would clamp the new ARIDs regardless. Whole-generator swap is the epoch-safe pattern the code
already uses (`restream()` `:2689-2709`).

Injection point — `_manifest_cold_step` stage 3 (`module_world.gd:1178`), AFTER `library.bake()` and
BEFORE `_manifest_remesh_near()`:

```gdscript
if CubeSphere.FP_SLOPE_MANIFEST_HEAL:
    _heal_generators_post_cold_bake()
```

`_heal_generators_post_cold_bake()`:
1. Active single-terrain path: `_set_if(_terrain, "generator", _make_generator())`; keep `_generator`
   in sync.
2. Pooled facets (FP_M1_POOL / FP_NB_FULLRES): for each spawned slot in `_pool`, swap
   `_make_generator(slot_fid)` onto its terrain (the slot records its fid; same call as spawn `:1871`).
3. `_make_generator` reads the NOW-FILLED member tables and the CURRENT `_library_model_count()`
   (`:3984-4017`), and under FP_CPPGEN builds a fresh `VoxelGeneratorCosmos` with correct frozen tables
   (`:4026-4030`) — one code path heals GDScript and C++ identically.
4. The already-existing stage-3 re-ramp (`_manifest_remesh_near` `:1192`) then drops + regenerates the
   near annulus with the healed generators — it finally upgrades slope cells instead of re-emitting
   cubes. Pool slots not re-ramped regenerate on their normal streaming; optionally kick the active
   slot only (bounded work, matches today's stage-3 cost envelope).

Contracts respected:
* **Analytic collision untouched** — no trimesh, no physics change; the fix moves the RENDER to where
  physics already is (physics is the correct one).
* **NEVER-OOM** — no new caches; a generator is a parameter holder (COW refs to existing tables); the
  old generator frees. The ~5160 slope models were already budgeted by SHARP-SLOPE §4.1 / the ATLAS
  ledger (`:1444-1449` keeps slopes per-material, off the atlas).
* **Web perf** — one-time swap after essential-ready, off the boot critical path (the whole point of
  FP_MANIFEST_SLICE is preserved); regeneration cost is the stage-3 re-ramp that already runs today.
* **Byte-off** — flag off ⇒ no swap, shipped behaviour bit-for-bit (stage 3 unchanged).

## 4. Gate plan (verify_slope_parity.gd; extend verify_manifest_slice.gd)

1. **OFF byte-identity**: flag off ⇒ existing suites unchanged (FLAT gate, verify_manifest_slice,
   verify_cppgen all as-is); `_manifest_cold_step` stage sequence identical.
2. **ON — frozen-table heal** (the new claim, closing the verify gap named above): run the
   FP_MANIFEST_SLICE lifecycle headlessly (core bake → build generator → cold bake → heal); assert
   the ACTIVE terrain generator's `get("slope_arid")` baked count equals the member's
   `manifest_baked_count("slope") > 0`, ditto `snow_slope_arid`, and `get("model_count") ==
   _library_model_count()`; under FP_CPPGEN assert the compiled generator's debug dict
   `slope_arid_size`/`snow_slope_arid_size` (patch 0007 `:554-555`) are non-zero. Repeat for one pooled
   slot.
3. **ON — render/physics parity** (the cd11ba0 model, per-cell): for the pinned repro column
   fid 578 (13038,8155) plus a sampled set of firing B_MOUNTAINS columns, generate the containing block
   through the healed generator and assert every run cell's emitted ARID is a SLOPE model
   (`!= cube_arid[mat]`), and that the model's ShapeCodec surface height at 4 footprints equals the
   analytic `floor_under` / `_occ_span` height within ε=0.01 — rendered top == physics floor.
4. **Carve-fires pin** (guards the biome gate from silent drift): assert `slope_run_fires` at
   (13038,8155) with targets (68,69,69,67), and fires-count > 0 over the census window, on B_MOUNTAINS
   kind-1.
5. **Live eyeball**: redeploy, remote-walk the repro slope; assert `pos.y − floor_p10 < 0.2` while
   `on_ground`, and screenshot shows the carved 45° ramp (no ladder).

## 5. Residuals / notes

* The same heal fixes the deferred WET and SNOW-FILL COMPOSITE staleness for free (same frozen-table
  mechanism, `:1094/:1112`) — snowy ramps stop cube-falling-back too.
* Columns like (13051,8088) (raw targets within [g, g+1]) are LEGACY smoothing by design (all-biome
  ≤1 blk/cell staircase) — not part of this bug; their dry shapes bake synchronously (core manifest).
* If a future flag re-orders generator construction before ANY manifest bake, gate 2 catches it — it is
  the only gate that reads the generator's frozen copy rather than the module member.
