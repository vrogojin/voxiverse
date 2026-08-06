# COSMOS-TREE-BUGS — acacia no-collision + cut-canopy flip/sink: root causes, verdicts, flagged fixes

2026-08-06 · analysis + design (no production code in this change) · author: tree-bugs root-cause agent

Both bugs were reproduced **headlessly**, root-caused to exact lines, and adjudicated against the four
flags this session shipped (`FP_QUERY_FRAME_GUARD`, `FP_FLOOR_SURFACE_WELD`, `FP_UPVECTOR_FACET_HEAL`,
`FP_CAMERA_RADIAL_LEVEL`). **Verdict for both: PRE-EXISTING, not a regression** — every reproduction below
ran with all four flags at their committed defaults (`false`), and neither bug's code path touches the
queries those flags changed. Both bugs date to the 2026-07-19 overnight batch, three weeks before the flags.

Evidence probes (kept, untracked, in `godot/src/tools/`): `probe_acacia.gd` (facet-wide mesh-vs-analytic
sweep), `probe_acacia2.gd` (vertical column dumps), `probe_acacia3.gd` (resolve_cell decomposition),
`probe_treedrop.gd` (synthetic canopy drop — clean baseline), `probe_treechop.gd` (+`2`/`3` controls —
real `break_terrain` chop), `probe_gravbox.gd` (facet-domain vs gravity-box geometry). All run as:

```
docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script res://src/tools/<probe>.gd
```

with `FACETED` + `FP_CLIMATE_BIOMES` (+ for Bug 2: `FP_M1_POOL` + `FP_FIXED_FRAME`) sed'd ON, mirroring live.

---

## Bug 1 — acacia (and jungle) trees have no collision, cannot be broken, player walks through

### Root cause: biome-id collision — savanna/jungle ARE the Moon on the analytic path

Two features landed the same overnight (2026-07-19) from parallel agents, each "appending after the end
of the biome enum":

- `27ff862` (B1 climate biomes): `B_SAVANNA := 11`, `B_JUNGLE := 12` — `godot/src/world/terrain_config.gd:303-304`
- `318dd2a` (O4b walkable Moon): `B_MOON_MARIA := 11`, `B_MOON_HIGHLANDS := 12`, `B_MOON_POLAR := 13` —
  `godot/src/world/terrain_config.gd:310-312`, whose comment ("Values start ABOVE every Earth biome so the
  enum spaces never collide", :308-309) was true when written and silently falsified by the sibling commit.

`TerrainConfig.resolve_cell` routes moon biomes **before any Earth machinery**
(`godot/src/world/terrain_config.gd:1309-1310`):

```gdscript
if biome == B_MOON_MARIA or biome == B_MOON_HIGHLANDS or biome == B_MOON_POLAR:
    return _moon_cell(x, y, z, g, biome)
```

With `FP_CLIMATE_BIOMES` ON (live), every Earth **savanna (11) / jungle (12)** column entering the ANALYTIC
path is treated as an **airless Moon column**: `_moon_cell` emits moon strata below ground and **never calls
TreeGen** (moon = "NO trees", :1305-1310 comment) — so above ground the analytic column is pure AIR.

Meanwhile the **C++ mesh generator has no moon branch at all** (`docker/engine/cache/godot/modules/voxel/
generators/cosmos/voxel_generator_cosmos.cpp` — zero `B_MOON` references) and its climate-biome port is
faithful (`tree_species_for` salt-124 acacia thinning at :486-488, `tree_acacia_block` at :585-599), so the
**mesh draws the correct savanna ground + acacia trees**. Result: visible trees the analytic
`WorldManager.block_id_at` (→ `cell_value_at` → `TerrainConfig.generated_cell`,
`godot/src/world/world_manager.gd:1257-1269`) reports as AIR — no aim, no break DDA hit, no player
collision, walk-through. `TreeGen` itself is NOT at fault: `TreeGen.block_at` returns the correct acacia
cells (`godot/src/world/tree_gen.gd:311-329`) — it is simply never reached for biome 11/12 columns.

### Measured evidence

- `probe_acacia` (6 savanna + 2 forest facets, 1,889 tree sites, all four session flags OFF):
  **9,406 mesh-only acacia cells** (1,387 `acacia_log`=56 + 8,019 `acacia_leaves`=57), **2,334 mesh-only
  jungle cells** (ids 54/55), **0 analytic-only cells**, **0 column-profile (g/biome) mismatches** — the
  two sides agree perfectly on WHERE savanna is; only resolve_cell's moon hijack diverges.
- `probe_acacia2` vertical dump at a savanna acacia site (fid 20, base (−12143,−10557), g=3, biome=11
  both sides, `TreeGen.block_at` = [56,56,56,56,56,57]): GD `generated_cell` = **−1 (mat 0xFFFF)** for
  y≤g and **AIR** for y>g; C++ `resolve_cell` = dirt/grass/acacia stack. The −1 is `_moon_cell` emitting
  unregistered moon material ids (`_ID_REGOLITH`… = `id_of` miss = −1 when `MULTI_BODY` is off,
  `terrain_config.gd:536-543`); with `MULTI_BODY` on the ground would be regolith/basalt — differently
  wrong, still tree-free.
- `probe_acacia3`: `_surface_rule` returns grass (1) and `_biome_top(B_SAVANNA)` = grass via the `_:`
  default (`terrain_config.gd:2254-2255`) — confirming the miss is the interception at :1309, not the
  material tables.

Collateral of the same collision (worth fixing in one stroke): **jungle trees are equally uncollidable**
(confirmed by the 2,334-cell delta; live report said "acacia-only" because jungle wasn't visited);
savanna/jungle **underground is analytically moon strata** (wrong `block_id_at` for digging); any Earth-
reachable `== B_MOON_*` comparison is a latent hazard (today only `far_palette.gd:271` compares, on a
moon-only path).

### Why the gates missed it

`verify_cppgen`'s faceted sweep picks slope-firing + cold + stride facets (`verify_cppgen.gd:280-311`) —
savanna facets were never sampled; its tree coverage counter only tallies **legacy** species
(`verify_cppgen.gd:389-391`: WOOD/LEAF/birch/spruce), so a flag-ON run could pass without touching a B1
tree; and byte-equality runs at committed flag defaults (`FP_CLIMATE_BIOMES=false`) never produce biome
11/12 at all. `verify_climate` gated classification + species selection, not `resolve_cell` output on
savanna columns.

### Regression verdict: PRE-EXISTING

Reproduced with all four session flags at committed `false` defaults. The four flags touch
`floor_under/surface_y/blocked/ceiling_scan` (`world_manager.gd:3745,3786`), player facet healing, and
camera roll — none are in the `block_id_at → generated_cell → resolve_cell` chain. Introduced 2026-07-19
by `27ff862` ∥ `318dd2a`.

### Flagged fix design — `FP_BIOME_SPACE_FIX := false`

**Source of truth: the C++ mesh is correct; the analytic side converges to it** by removing the hijack.
(Justification: TreeGen + `_biome_top` defaults already author exactly what the mesher draws — proven by
the 0-profile-mismatch sweep — so no new authoring is needed; only the moon interception is wrong.)

Renumber the moon biome ids out of the Earth space **behind the flag**, via one helper (GDScript `const`
can't be flag-conditional):

```gdscript
## TerrainConfig — single source for the moon biome id block (fix: 21/22/23, clear of every Earth id).
static func moon_biome_id(slot: int) -> int:   # slot 0=maria 1=highlands 2=polar
    return (21 + slot) if CubeSphere.FP_BIOME_SPACE_FIX else (11 + slot)
static func is_moon_biome(b: int) -> bool:
    return b >= moon_biome_id(0) and b <= moon_biome_id(2)
```

Touch-points (all comparisons/emissions route through the helper; flag OFF ⇒ returns 11/12/13 ⇒
byte-identical shipped behaviour):

1. `terrain_config.gd:1309` — `if is_moon_biome(biome): return _moon_cell(...)`.
2. `terrain_config.gd:1049` — `_moon_profile` emits `moon_biome_id(0/1)` (and the polar slot wherever set).
3. `_moon_cell`'s internal maria/highlands comparisons — same helper.
4. `godot/src/world/far/far_palette.gd:271` — compare via `TerrainConfig.is_moon_biome`/`moon_biome_id`.
5. `godot/src/tools/verify_multibody.gd` — read ids through the helper.

Biome ids are **never serialized** (edits store packed material values; biome is derived per column), so
renumbering under the flag has no save/compat surface. The C++ generator needs **no change** (it has no
moon branch; Earth facets never carry moon biomes). NEVER-OOM: zero memory delta.

### Gate spec

`verify_tree_biomes.gd` (new; sed `FACETED`+`FP_CLIMATE_BIOMES`+`FP_BIOME_SPACE_FIX` ON):

- **G-TB-EQUAL** — probe_acacia promoted: ≥5 savanna + ≥2 jungle facets, every tree site's full column
  y∈[g−4, g+`TreeGen.MAX_ABOVE_SURFACE`] over the 5×5 canopy footprint: `TerrainConfig.generated_cell`
  == C++ `resolve_cell` cell-for-cell, **0 mismatches** (was 11,740+ before the fix — the falsifier is
  running the same sweep with the fix flag sed'd OFF and asserting it FAILS).
- **G-TB-SOLID** — at ≥20 acacia + ≥10 jungle sites: analytic trunk cell (base, g+1) has
  `block_id_at == acacia_log/jungle_log` and `cell_solid == true` (the collision/DDA truth the player feels).
- **G-TB-MOON** — `verify_multibody` suite re-run green under the fix (moon columns still emit moon strata
  through the renumbered ids), both `MULTI_BODY` on and off.
- **G-TB-COVER** — extend `verify_cppgen.gd:389-391` `saw_tree` to count acacia/jungle/cactus ids so a
  future flag-ON byte-equality run can never be vacuous on B1 species again.
- **Byte-off** — all fix flags false ⇒ FLAT `verify_feature` 6042/0 unchanged (FLAT never reaches
  Whittaker or moon branches; the helper returns shipped ids).

---

## Bug 2 — cut-tree canopy turns upside down and slowly sinks under the ground

### Root cause: TWO cooperating defects, each isolated headlessly

**B2a (primary — the wrong-gravity "sink"/drift): the per-facet gravity boxes stopped covering their
facets after the R=6371 planet rescale.** `GRAV_BOX_TANGENTIAL := 320` (±160,
`godot/src/world/world_manager.gd:915`) was sized on 2026-07-15 (`0316b21`) for "a facet's ~100-block
half-width" (:911-914). The 2026-07-19 natural-Earth rescale made facets **~500-590 × ~350-400 blocks**
(measured, `probe_gravbox`: fid 0/2/20/100 spans 593×364, 570×353, 543×354, 495×398; offsets from
`centre_cell` up to **298×202**) — so the **outer ~60% of every facet lies outside its gravity Area3D**
(`_build_facet_gravity_area`, world_manager.gd:948-969, centres the ±160 box on `centre_cell`; the
domains are also asymmetric about `centre_cell`, so even the centring is wrong). A `VoxelBody` outside
every box gets the **project-default gravity — global (0,−9.8,0)** (no gravity override in
`godot/project.godot`), which in the planet-ABSOLUTE fixed frame (`FP_FIXED_FRAME` live) is an arbitrary
oblique direction relative to the local surface.

Measured (`probe_treechop2`, real `break_terrain` chop at a tree 273 blocks from facet centre, no
collider): the canopy's `total_gravity` is global from frame 1 (gdot vs facet-down = **−0.605**,
exactly (0,−1,0)·(−facet-up) for that facet) and the body **flies away obliquely** at ~49 b/s terminal.
Control (`probe_treedrop`, synthetic canopy at the facet CENTRE, inside the box): gdot = **1.000**,
clean fall, settle, freeze. Live, in contact with the ground collider, an oblique 9.8 pull produces
exactly the reported phenomenology: sustained torque against the contact (slow roll to inverted under
`angular_damp` 24, `voxel_body.gd:71-73`) plus a slow grind through/along the collider box seams —
"turns upside down and slowly sinks under the ground".

**B2b (the spawn "flip"): the canopy spawns 100% inside its own stale GroundCollider tree boxes.**
The collider emits boxes for TREE cells (`godot/src/physics/ground_collider.gd:517,546,550` via
`tree_block_at`), and `rebuild_now()` after a break is **debounced, non-blocking**
(`ground_collider.gd:223-229`; ~0.25-1.0 s, :88). Its own comment argues staleness is safe because
"VoxelBody settling confirms support analytically, never trusting the collider" — true for settling,
**false for spawn**: `_structural_update` (world_manager.gd:3699) → `VoxelBody.spawn_loose`
(`godot/src/physics/voxel_body.gd:114-134`) places the body at identity in the SAME lattice cells the
tree occupied, i.e. every one of its 20-30 box shapes starts fully overlapping a static collider box.
The solver's depenetration ejects and torques it.

Measured (`probe_treechop3`, chop INSIDE the gravity box, collider prebuilt, gravity CORRECT
gdot=1.000): the canopy tumbles from updot 1.000 → **−0.609** (~127° over-rotation) within 4 s and
settles lying on its side (updot −0.003). With B2a also active (`probe_treechop`, the same chop outside
the box) the combination **blows up to NaN** position/velocity in the very first physics step —
headless severity of the same live flip+sink. (Once NaN, the body exits every area, which is why its
gravity also reads global.)

Interaction with Bug 1: an acacia can't be chopped at all (no DDA hit), so Bug 2 was only ever
observable on non-acacia trees — consistent with the live report.

### Regression verdict: PRE-EXISTING

- **Empirical**: every probe above ran with the four session flags at committed `false` defaults; both
  defects reproduce fully.
- **Code-path**: `VoxelBody._grounded` reads `world.surface_y(x, z)` two-arg (`voxel_body.gd:452` —
  `pos_fid` defaults to −1 ⇒ `FP_QUERY_FRAME_GUARD` no-op, `world_manager.gd:3745-3754`) and
  `world.cell_solid` (:467, untouched). The `FP_FLOOR_SURFACE_WELD` weld lives **only in
  `floor_under`** (`world_manager.gd:3786`+), which neither `VoxelBody` nor `GroundCollider` calls —
  the collider builds from `col_profile`/`tree_block_at`/`overlay_at`
  (`ground_collider.gd:295,357,443-550`). Byte-identical flags-on/off for every Bug-2 path.
- **Introduced**: B2a = `0316b21` (2026-07-15 box sizing) invalidated by the 2026-07-19 R=6371 rescale;
  B2b = latent since the collider gained tree boxes + the debounced rebuild (P2), exposed by the
  faceted/fixed-frame era. The fixed-frame gates never dropped a live body — `verify_fixed_frame.gd:311`
  freezes its debris marker ("no fall between the two reads"), so no gate ever exercised canopy settling.

### Flagged fix design

**`FP_GRAV_BOX_COVER := false`** — size + centre each facet's gravity box from its OWN measured domain
(`_build_facet_gravity_area`, world_manager.gd:948-969):

```gdscript
var lo := FacetAtlas.dom_min(fid); var hi := FacetAtlas.dom_max(fid)
if CubeSphere.FP_GRAV_BOX_COVER:
    var half_x := maxf(float(hi.x - lo.x) * 0.5 + GRAV_BOX_MARGIN, GRAV_BOX_TANGENTIAL * 0.5)
    var half_z := maxf(float(hi.y - lo.y) * 0.5 + GRAV_BOX_MARGIN, GRAV_BOX_TANGENTIAL * 0.5)
    box.size = Vector3(half_x * 2.0, GRAV_BOX_VERTICAL, half_z * 2.0)
    cs.position = Vector3((lo.x + hi.x) * 0.5, 0.0, (lo.y + hi.y) * 0.5)   # domain centre, not centre_cell
else:  # shipped: 320×2048×320 @ centre_cell — byte-identical
```

`GRAV_BOX_MARGIN := 24.0` (covers the ridge band + detach-kick drift). Ridge overlap between neighbours
grows; the existing active-priority stamping (`_stamp_active_gravity`, world_manager.gd:974-981) already
arbitrates it. Same area count, bigger boxes ⇒ zero memory delta (NEVER-OOM safe); direction unchanged
(−T_fid.basis.y), so `verify_fixed_frame` G-P2/P3 gravity lemmas hold as-is.

**`FP_CHOP_COLLIDER_CARVE := false`** — kill the spawn overlap at the source: in `_structural_update`,
after `_write_cell(c, 0)` for the component and **before** `spawn_loose` (world_manager.gd:3693-3699),
synchronously remove the live collider shapes at exactly the carved cells: `GroundCollider.carve_cells
(comp: Array[Vector3i])` — it owns per-column shape bookkeeping, so this is O(component) targeted
`PhysicsServer3D` shape frees (a few dozen), not a rebuild; the debounced full rebuild then proceeds as
today. Off ⇒ shipped debounced path byte-identical. *(Rejected interim: masking the new body off the
terrain layer for N frames — it lets a low chop fall INTO the ground; the carve is the correct minimal.
Rejected large fix: real per-body analytic terrain contact — not needed once gravity + overlap are fixed,
as the clean baseline (`probe_treedrop`) already settles perfectly on the existing collider.)*

### Gate spec

`verify_treechop.gd` (new; sed `FACETED`+`FP_M1_POOL`+`FP_FIXED_FRAME`+both fix flags ON):

- **G-TC-COVER** (numeric lemma, no physics): for a stride of fids, the flag-ON box (position ± half
  extents in area-local frame) contains `[dom_min − 8, dom_max + 8]`; flag OFF ⇒ box byte-equals the
  shipped 320×2048×320 @ `centre_cell` (byte-off proof).
- **G-TC-GRAV** — real `break_terrain` chop of a worldgen tree at a site **>160 blocks from
  `centre_cell`** (the probe_treechop site class): from the first physics frame, canopy
  `total_gravity`·(−facet-up) ≥ 0.999 (was −0.605).
- **G-TC-SETTLE** — for both an inside-ring and an outside-ring chop, within 20 s sim: body state finite
  (no NaN — was NaN in ≤1 frame), settles with canopy centre within its own half-height of
  `surface_y`, **updot ≥ 0.9** (uprightness — was −0.609 tumble), and frozen/sleeping at the end.
- **Falsifier** — the gate re-run with the two fix flags sed'd OFF must go RED on G-TC-GRAV and
  G-TC-SETTLE (this doc's probes prove it measurably does).
- **Byte-off** — flags false ⇒ FLAT `verify_feature` 6042/0 unchanged (flat mode has no gravity areas
  and `rebuild_now` semantics untouched when the carve flag is off).

---

## Summary table

| | Bug 1 (acacia/jungle no-collision) | Bug 2 (canopy flip + sink) |
|---|---|---|
| Root cause | `B_SAVANNA/B_JUNGLE` (11/12, terrain_config.gd:303-304) collide with `B_MOON_MARIA/HIGHLANDS` (11/12, :310-311); resolve_cell:1309 hijacks Earth savanna/jungle into `_moon_cell` (no trees) on the analytic path only | B2a: gravity box ±160 (world_manager.gd:915) vs post-rescale facets ~500-590 wide → outer ~60% gets global (0,−9.8,0); B2b: canopy spawns inside its own stale debounced collider tree boxes (ground_collider.gd:223-229, 517) |
| Verdict | Pre-existing (2026-07-19, `27ff862`∥`318dd2a`); repro with session flags OFF | Pre-existing (`0316b21` 07-15 sizing vs 07-19 R=6371 rescale; collider debounce older); repro with session flags OFF; no Bug-2 path reads the welded/guarded queries |
| Fix flag | `FP_BIOME_SPACE_FIX` — renumber moon biome ids to 21/22/23 via one helper | `FP_GRAV_BOX_COVER` (domain-derived boxes) + `FP_CHOP_COLLIDER_CARVE` (synchronous shape carve at collapse spawn) |
| Headless repro | Yes — probe_acacia/2/3 (9,406 acacia + 2,334 jungle mesh-only cells; 0 profile mismatches) | Yes — probe_treechop/2/3 (gdot −0.605 fly-away; updot → −0.609 tumble; NaN combined) + probe_gravbox geometry |
