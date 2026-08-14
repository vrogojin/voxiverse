# COSMOS SLOPE-MATERIAL — smooth slope carve for ALL natural terrain (root cause & fix design)

Status: ROOT-CAUSED (task #122, 2026-08-12). Fix design behind `FP_SLOPE_ALL_MATERIALS` (byte-off).
Symptom (live, user-reported): on a steep slope, STONE assembles into the proper smooth sub-voxel
slope carve, while an adjacent steep MUD (dirt/sand/grass/…) slope still renders LADDER-style
(full cubes stepping). Owner decision: extend the smooth carve to ALL natural terrain materials;
player-placed blocks stay CUBIC.

## 1. Root cause — it is a BIOME gate, not a material gate

There is no per-material carve gate anywhere in the mesher. The SHARP-SLOPE model bake is already
**complete for every natural surface material**: `all_slope_materials()` returns
GRASS, DIRT, STONE, SAND, RED_SAND, MUD, SNOW, PODZOL (`godot/src/world/terrain_config.gd:2896-2901`),
and `emitted_slope_pairs()` bakes the FULL cross product `materials × all_slope_payloads()`
(`terrain_config.gd:2911-2925`, SHARP-SLOPE §4.1 DEFECT 1). A firing mud slope cell already renders
smooth today. What differs per material is **whether the column FIRES at all**.

The firing predicate `_slope_fires_only` (`terrain_config.gd:1720-1762`) has a two-window rule:

* Corner-target plane escapes the TWO-cell window `[g, g+2]` (a >2 blk/cell face) → **fires in ANY
  biome** (`terrain_config.gd:1745` falls through). This is why very steep mud/badlands walls do
  carve.
* Plane escapes only the ONE-cell window `[g, g+1]` — the **1–2 blk/cell, ~45° band** — → fires
  **ONLY in B_MOUNTAINS**:

  ```gdscript
  if int(column_profile(x, z, pcache).y) != B_MOUNTAINS:
      return false        # 1–2 block/cell band off the mountains → leave hills alone
  ```
  (`terrain_config.gd:1749-1750`; rationale comment `:1728-1738` — SHARP-SLOPE DEFECT 2
  "don't touch hills", deliberately confining the 45°-band widening to keep every non-mountain
  hill byte-identical to the pre-widening build.)

Off B_MOUNTAINS, a 1–2 blk/cell face falls to legacy smoothing, whose half-block corner grid
saturates in that band → a full-cube riser per cell — exactly the reported **ladder**. B_MOUNTAINS'
top skin is STONE (`_biome_top`, `terrain_config.gd:2285-2286`), so the user perceives
"stone = smooth, mud = ladder": the correlation is biome→material, and the reported mud ladder is a
45°-band slope in a swamp/mangrove column (B_SWAMP top = MUD, `terrain_config.gd:2279-2280`).

The C++ generator (FP_CPPGEN, the served render path) ports the gate line-for-line:
`docker/engine/patches/godot_voxel/0007-cosmos-cpp-generator.patch` `slope_fires_only`, hunk ~:865-902 —

```cpp
if (int(column_profile_core(p, fid, x, z).y) != cosmos::B_MOUNTAINS) {
    return false; // the 1-2 block/cell band off the mountains -> leave hills alone
}
```
(patch ~:888-890). Render and physics agree today — both ladder off-mountains — so this is a
**consistent design limitation**, not a parity bug like #111.

Two layers, for the record (both must pass for a smooth slope):
1. **Firing** — `_slope_fires_only` (the biome gate above). THE bug.
2. **Baked-pair coverage** — an emitted slope cell whose `(material, payload)` pair is unbaked
   cube-falls-back in `cell_to_arid` (`module_world.gd` GDScript twin ~:1733-1737 / ~:835-840;
   C++ patch FAM-SLOPE branch → `cube_arid[id]`). Already complete for the 8 natural materials;
   only the badlands terracotta/sandstone **carve bands** are deliberately unbaked
   (`terrain_config.gd:2893-2895`, accepted Risk 2).

## 2. Render ↔ physics parity (the #111/#112 lesson) — why this fix is parity-safe by construction

`_slope_fires_only` is the ONE shared predicate. Every consumer routes through it:

* **Render, C++ (live)**: `slope_run_core` → `slope_fires_only` (patch ~:917-925), plus the
  quantization fires-stencil `col_fires` (patch ~:1504).
* **Render, GDScript module worker** (FP_CPPGEN off): hoisted run via `TerrainConfig.slope_run_of`
  (`terrain_config.gd:1844-1852` → `_slope_fires_only:1850`).
* **Render, fallback mesher**: `world.col_slope_run_of` (`world/fallback/chunk_mesher.gd:226`).
* **Physics**: `floor_under` / `blocked` / DDA via `_occ_span(cell_value_at(...))`
  (`world_manager.gd:4274-4318`), the shape memo (slope run in bits 40..56,
  `terrain_config.gd:1952-1956`), and `GroundCollider` slope prisms via
  `world.col_slope_run_of` (`physics/ground_collider.gd:566`,
  `world_manager.gd:1788-1794` → `TerrainConfig.slope_run_of` + `rotate_slope_run`).

Widening the gate inside `_slope_fires_only` therefore moves render AND collision **together**:
the carved surface is lower than the ladder, and `floor_under`/`GroundCollider` track it through
the same predicate — no fall-through opens, by the same ONE-predicate contract that SHARP-SLOPE §3
was built on.

**The one real parity hazard**: the GDScript predicate and the C++ port are two implementations.
If `FP_SLOPE_ALL_MATERIALS` is added only to `terrain_config.gd`, the ANALYTIC collision widens
while the compiled RENDER keeps the B_MOUNTAINS gate → render ladder floats above a carved physics
floor — the exact #111 sink/fall-under class ([[voxiverse-sharp-slope-manifest-stale]]). The fix
MUST land in patch 0007 in the same change, plumbed like `m5c_corner`
(patch `p.m5c_corner` read at ~:440, Parameters field ~:2450), and the flag must be passed in
`_make_cpp_generator`'s cfg (`module_world.gd:4125-4126` is the mirror site). This requires an
**engine rebuild** (`scripts/build.sh`) — a GDScript-only deploy of this feature is forbidden.

Secondary interactions, checked:
* **#112 FP_SEAM_SLOPE_WELD** (`cube_sphere.gd:3317`): the seam floor band takes a cross-frame max —
  material/biome-agnostic; newly-firing border columns are welded the same way. No change.
* **#111 FP_SLOPE_MANIFEST_HEAL** (`cube_sphere.gd:2291`): widened biomes emit models from the SAME
  already-baked slope manifest; the deferred-bake staleness heal applies unchanged. Dependency:
  the live build must keep it ON (it is), else widened cells cube-fallback like #111 did.
* **Rim quantization**: `_quantized_targets`' 3×3 fires stencil (`terrain_config.gd:1779-1790`)
  reads the same predicate — rim cells next to newly-firing columns switch to whole-block corners
  identically on both sides. Crack-free by the existing construction.
* **Flag freeze**: FP flags are export-baked consts; the C++ Parameters copy frozen at generator
  build can never go stale at runtime.

## 3. Fix design — `FP_SLOPE_ALL_MATERIALS` (byte-off flag in cube_sphere.gd)

Widen the 45°-band biome gate from `== B_MOUNTAINS` to "all Earth land biomes except B_BADLANDS".
Four lines of predicate change + flag plumbing; **zero new models, zero new tables** (the bake is
already complete — that is the pleasant surprise of this root cause).

1. **GDScript** — `terrain_config.gd:1749`:
   ```gdscript
   var b := int(column_profile(x, z, pcache).y)
   if b != B_MOUNTAINS and not (CubeSphere.FP_SLOPE_ALL_MATERIALS and b != B_BADLANDS):
       return false
   ```
   (`CubeSphere.<flag>` from a static TerrainConfig func follows the `_is_pillar_column` precedent,
   `terrain_config.gd:1718`.)
2. **C++** — patch 0007 `slope_fires_only` (~:888): same condition on `p.slope_all_biomes`;
   add `bool slope_all_biomes = false;` to `Parameters` (~:2450) and
   `p.slope_all_biomes = bool(config.get("slope_all_biomes", false));` in setup (~:440).
3. **Plumbing** — `module_world.gd`: `gen.set("slope_all_biomes", CubeSphere.FP_SLOPE_ALL_MATERIALS)`
   next to `radial_datum` (~:4071) and `cfg["slope_all_biomes"] = ...` in `_make_cpp_generator`
   (~:4126). `verify_cppgen`'s test cfg must pass the flag too (see gate 3).
4. **Nothing else changes.** `all_slope_materials()`, the payload set, the bake, the memo pack,
   ATLAS, colliders: untouched.

### Who carves, who stays blocky (the honest material verdict)

| Surface | Biome(s) | 45°-band result with flag ON | Why |
|---|---|---|---|
| STONE | B_MOUNTAINS | smooth (unchanged) | shipped |
| GRASS | plains/forest/savanna/jungle/taiga | **smooth** | top+DIRT filler baked |
| MUD | B_SWAMP | **smooth** | MUD top + MUD/DIRT filler baked |
| SAND | B_BEACH/B_DESERT | **smooth** | SAND top+filler (depth ≤ 3) baked |
| SNOW / PODZOL | B_SNOWY/B_TAIGA | **smooth** (incl. snow-capped composites) | `_snow_slope_arid` cross product baked |
| RED_SAND / terracotta | **B_BADLANDS** | **stays laddered (excluded)** | sub-`g` run cells hit the terracotta bands (`_biome_filler` `terrain_config.gd:2345-2346`, filler depth 12), which are deliberately NOT in `all_slope_materials()` (`:2893-2895`) — widening there would mass-produce the render-above-physics cube-fallback sink (the #111 symptom). Mesa terraces are also the biome's visual signature. Follow-up option: bake the 7 terracotta ids (+~7×|payloads| library models) and lift the exclusion. |
| Moon regolith | B_MOON_* | out of scope automatically | moon columns exit `resolve_cell` before the slope branch (`terrain_config.gd:1344-1345`) |
| B_PILLAR bedrock | monument | full cubes (unchanged) | `_is_pillar_column` guard `:1723` |
| Under a tree | any | full top (unchanged) | TreeGen guard `:1725-1726` |
| GRAVEL / underwater | g < SEA_LEVEL | out of scope | land-only guard `:1721` |

### Player-placed blocks stay cubic — no work needed, by construction

The carve is worldgen-only. `_slope_fires_only` reads only `height_at`/TreeGen (`:1709`), never the
edit overlay. A placed block is written into the voxel data as its plain cube ARID
(`module_world.gd:698` `vt.call("set_voxel", cell, arid)`), and `WorldManager.block_id_at` serves
edits-first from `_edits` (`world_manager.gd:247`, the `_write_cell` choke point `:202`). A wall
built on a carved hillside renders and collides as full cubes today for stone slopes in mountains;
the widened biomes inherit exactly that behaviour. Digging into a carved slope likewise leaves the
un-edited neighbours carved. Gate 4 pins this anyway.

### Contracts

* **Byte-off**: flag off ⇒ `b != B_MOUNTAINS and not (false and …)` ≡ shipped condition;
  C++ default `slope_all_biomes = false` ⇒ shipped branch. Bit-for-bit.
* **NEVER-OOM**: no new models, meshes, or tables; slope cells replace cube cells one-for-one.
* **Perf**: the biome probe was already on the narrow-band path (`:1737-1738`, pcache-memoized);
  the predicate cost is unchanged. More columns fire → slope models instead of cubes at similar
  triangle counts; the manifest bake size is identical. gl_compat untouched (no shader change).
* **Visual scope (intended, large)**: every 1–2 blk/cell hill face in every non-badlands biome
  becomes a carved ramp — this deliberately supersedes SHARP-SLOPE DEFECT 2's "don't touch hills",
  per the owner decision. The flag is the A/B lever.

## 4. Gate plan (verify_slope_materials.gd; extend verify_slope_heal / verify_cppgen)

1. **OFF byte-identity**: flag off ⇒ `_slope_fires_only` decisions identical over a seeded column
   census spanning all biomes (pin fires-count per biome); FLAT gate + verify_feature +
   verify_slope_heal + verify_seam_slope_weld unchanged.
2. **ON — firing widened, correctly bounded**: on a synthetic/seed-found 1–2 blk/cell face in
   B_SWAMP (mud), B_DESERT (sand), plains (grass), B_SNOWY (snow): `slope_run_fires` true and
   `resolve_cell` emits FAM-SLOPE cells whose material is the biome skin; the SAME face in
   B_BADLANDS still does NOT fire; a B_MOUNTAINS face is byte-identical to flag-off; a tree-topped
   swamp column still does not fire.
3. **ON — C++ parity (the hazard gate)**: verify_cppgen with `slope_all_biomes` in its cfg —
   GDScript vs compiled buffers byte-equal over widened-biome slope regions. This is the gate that
   catches a GDScript-only deploy: run it against the ACTUAL built engine before deploy.
4. **ON — render==physics, no fall-through**: for sampled firing mud/sand/grass columns, every run
   cell's emitted ARID is a SLOPE model (`!= cube_arid[mat]`), and the model's ShapeCodec surface
   height at 4 footprints equals analytic `floor_under`/`_occ_span` within ε=0.01 (the #111 gate-3
   model, re-run per biome). Place a block on a carved mud slope → that cell's value is the cube
   pack, collision span = full cube.
5. **Live A/B** (deploy, remote): steep mud slope renders smooth (screenshot vs ladder baseline);
   remote-walk it with `pos.y − floor_p10 < 0.2` while `on_ground` (no sink/fall-through); stone
   mountain slope unchanged; a placed wall on the slope stays blocky; fps within noise (draws/verts
   telemetry before/after).

## 5. Rollout order

patch 0007 + GDScript in one branch → `scripts/build.sh` (warm rebuild) → headless gates 1–4 →
export + deploy flag OFF (byte-parity smoke) → bake flag ON → live A/B (gate 5). If the live A/B
finds a biome that reads badly smooth (aesthetics), the biome-exception list in the ONE predicate
is the single knob — both sides move together by construction.
