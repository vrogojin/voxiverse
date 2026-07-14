# COSMOS-MULTIFACET-STREAMING-REVIEW — multi-facet voxel streaming: verdict, root causes, and the target architecture

Status: **architecture review, decision-ready.** Commissioned after the user's live-play report
on the FP3b faceted build: (1) no real voxels on neighbouring facets, (2) terrifically slow
facet crossings, (3) chunks stop rendering after a crossing, plus the requirement that chunk
streaming be **generic across scales** — surface walk, atmospheric flight, near orbit, and a
telescope view of a distant planet, all resolving real blocks whenever the view is close or
magnified enough. Every claim below is grounded in file:line of this branch
(`feat/voxiverse-cosmos-m5`) or in the vendored engine source
(`docker/engine/cache/godot/modules/voxel`, godot_voxel v1.4.1 + patches 0001–0004).

Requirements as distilled from the user report:

- **R1** — real voxels visible on neighbouring facets, and on multiple facets simultaneously.
- **R2** — seamless facet crossing: no multi-second (or multi-minute) hole.
- **R3** — no state where chunks stop rendering after a crossing.
- **R4** — ONE generic multi-scale streamer: LOD driven by screen-space error / angular size,
  not a fixed distance hole; real voxels available at any range if the view is close/zoomed
  enough (walk → low flight → near orbit → telescope).

---

## 0. Executive verdict

**The shipped single-active-facet architecture is directionally WRONG for R1 and R4, and its
central justification — "a live godot_voxel VoxelTerrain cannot be rotated" — is a
misdiagnosis.** It cannot be incrementally tuned into compliance:

1. R1 is impossible by construction: exactly one facet is ever a voxel field
   (`module_world.gd:2087` freezes one `gen_facet` per generator epoch;
   `facet_atlas.gd:477-499` masks every cell beyond that facet's ridges to AIR), and every
   other facet is a 4×4 vertex-coloured quad (`facet_far_ring.gd:13` `CELLS := 4`). No
   parameter of this design produces voxels on two facets at once.
2. R4 is impossible by construction twice over: `VoxelTerrain` has **no LOD and a hard
   512-voxel view-distance cap** (LOD-RESEARCH §2.1), and the faceted far layer has exactly
   two LOD states — full voxels (active facet) or a 32-triangle quad (everything else). There
   is no mechanism, present or latent, that can raise a distant facet's resolution when the
   player zooms.
3. R2/R3 are not fundamental — they are artifacts of the teardown-based crossing
   (`module_world.gd:1274-1322`) compounded by four concrete defects (§4), at least two of
   which are one-line-class fixes.

**The constraint on record is falsified by the vendored engine source** (§3): `VoxelTerrain`
handles an arbitrary (invertible) global transform in both streaming and rendering. The
det==0 spam that spawned the "cannot be rotated" rule came from a **singular per-frame bend
basis in our own R2.2 curved-mode code** (`cosmos_true_place.gd:99-114`), not from a rigid
facet rotation (orthonormal, det = +1). This must be re-proven by a live spike (gate FP-R0,
§8), but the code evidence is unambiguous.

**Recommended architecture (§6): the Planet Assembly.** One `PlanetRoot` node carrying
`T_active⁻¹` (exactly the transform `FacetFarRing` already uses, `facet_far_ring.gd:39`);
under it, a small pooled set of live, statically-rotated `VoxelTerrain`s (active facet + the
ridge-adjacent neighbours, each with its own frozen per-facet generator and its own
carve-mesher), and a **facet LOD-mesh layer** — per-facet blocky meshes at
screen-space-error-selected LOD, built through the script-exposed
`VoxelGenerator.generate_block` + `VoxelMesher.build_mesh` (no terrain node, no voxel-worker
load) — replacing `FacetFarRing`'s quads. A crossing becomes a **re-designation**: one root
transform update + player reframe + view-distance rebalancing between already-streamed
terrains. No teardown, no restream, no regeneration. Break/place remains active-facet-only
(reach-limited, acceptable; generalization is a bounded follow-up).

---

## 1. Ground truth (verified, file:line)

### 1.1 The near-voxel path

- One engine-enumerated `VoxelTerrain` (`module_world.gd:267,1284`) + one global `VoxelViewer`
  on the player (`module_world.gd:1569-1580`). The engine streams an axis-aligned box of
  half-extent `TerrainConfig.near_render_radius()` around the viewer
  (`module_world.gd:275-276`), vertical ratio 0.5.
- **`near_render_radius()` returns 256 in faceted mode, not 128.** `terrain_config.gd:133-134`
  branches on `CubeSphere.FLAT_WORLD` only — and FACETED *requires* `FLAT_WORLD = true`
  (`cube_sphere.gd:44-47`), so the faceted build streams the full flat-world 256 radius while
  paying the ~8× curved per-column cost (`terrain_config.gd:120-127` documents exactly this
  cost class for curved mode and why 128 was introduced there). The faceted branch simply
  never takes it. This single mis-branch multiplies every crossing restream ~4×.
- Facet scoping is generator-side masking, not box clamping: the worker calls
  `FacetAtlas.junction_modify(gen_facet, cell, v)` at the buffer-write exit
  (`module_world.gd:1908-1909`); beyond-ridge cells become AIR (`facet_atlas.gd:487-489`).
  `gen_facet` is frozen per generator epoch (`module_world.gd:1749, 2087`). The analytic twin
  is `WorldManager.cell_value_at` (`world_manager.gd:292-299`).
- Per-facet lattice coordinates carry a decorrelation offset `O ∈ [−32768, 32768]`
  (`facet_atlas.gd:107-108`) — facet-local world coordinates routinely reach |x|,|z| ~ 3·10⁴.
  (Engine bounds are ±0x1FFFFFFF, `constants/voxel_constants.h:24` — not a hazard; f32
  precision at 3·10⁴ is ~2 mm — not a hazard.)
- Web: the voxel task pool is pinned to 4 workers, main-thread mesh-apply budget 6 ms/frame
  (`project.godot:48-80`).

### 1.2 The crossing (FP3b as shipped)

`world_manager.gd:1245-1273` (`maybe_cross_facet`, called per physics tick from
`player.gd:229`): fires one-sided at `own_dist < −0.1` (`world_manager.gd:42`), computes the
f64-exact reframe + dihedral yaw (`facet_atlas.gd:250-257`), sets the active facet
(`:1258`), then `module_world.set_facet(to, old_mod_pos)` (`:1263-1265`) →
`_push_facet_carve()` + `restream()` (`module_world.gd:1246-1248`), then
`_facet_ring.set_active(to)` (`:1266-1267`), `_flip_settling = true`, `_restream()`
(`:1268-1269`). The player teleports only after the call returns (`player.gd:229-231`).
`restream()` **frees the old `VoxelTerrain` and creates a fresh one** with a new generator,
ramping `max_view_distance` 48 → 256 over 1.5 s (`module_world.gd:1283-1322, :54-55`).

### 1.3 The far layer

`FacetFarRing` (`facet_far_ring.gd`): every non-active, front-hemisphere facet as one 4×4
heightmap quad (25 `profile_at_dir` samples cached per facet, `:61-86`), all emitted into ONE
SurfaceTool mesh; node transform = `T_active⁻¹` (`:39`). `set_active` triggers a synchronous
full rebuild — a 3456-facet scan + re-emit + `generate_normals` + commit on the main thread
(`:34-58`), plus first-time caching (25 sphere-profile noise evaluations each) for every facet
newly entering the front hemisphere.

### 1.4 Edits

`_edit_key` in faceted mode is the raw active-lattice `Vector3i` (`world_manager.gd:343-346`
— the chart is null, so the FLAT branch is taken). The FP3 spec's `(fid, cell)` key migration
(COSMOS-FACETED-IMPL §6.2) is **not implemented** (deferred as FP3b-3, commit 78ea80a). An
edit made on facet A is therefore silently re-interpreted in facet B's lattice after a
crossing — a latent corruption, masked today only because B's generator masks most stray
A-keys to territory it never renders.

---

## 2. Verdict detail: can the shipped spec ever satisfy R1 + R4?

**No.** The three load-bearing locked decisions that must be superseded:

| Locked decision | Where locked | Why it blocks | Supersede with |
|---|---|---|---|
| "godot_voxel must never be rotated" → exactly ONE live VoxelTerrain | COSMOS-FACETED-IMPL §4.2, §5.2; COSMOS-PLANET-TOPOLOGY §"Module path"; `module_world.gd:345-349` | Forbids voxel fields on ≥2 facets simultaneously (R1) and forces crossing = teardown (R2/R3) | §3: the constraint is falsified; pooled rotated terrains (gate FP-R0) |
| Non-active facets are flat quads (`FacetFarRing`, CELLS=4) | FP2 as shipped (commit fcc4b96) — note the IMPL spec §5.2 itself asked for MORE (full-res junction bands + 4-block-pitch neighbour heightmaps); the shipped ring is thinner than its own spec | No block detail anywhere off the active facet at any zoom (R1, R4) | §6.3: per-facet blocky LOD meshes, screen-space-error selected |
| Crossing = `set_facet` teardown + restream (M4 pattern) | COSMOS-FACETED-IMPL §6.1; FP3b commit 78ea80a | The multi-second/minute hole (R2), the blank world (R3) | §6.4: crossing = re-designation (transform update + view-distance rebalance) |

Notably, the FP3 spec **already named its own escape hatch**: "the honest fallback if
godot_voxel restream cost is unfixable: keep **two** VoxelTerrain instances (active +
crossing-target pre-warmed), swap on cross — flagged, only if the gate fails"
(COSMOS-FACETED-IMPL §6.4). The user's report is that gate ("PerfHUD max frame ≤ 100 ms,
near cover visible throughout") failing in the strongest possible way. This review's
recommendation is that fallback, generalized and made primary — with the added finding that
even the two-instance swap is unnecessary ceremony once rotation is admitted, because the
neighbour terrains can simply *stay alive*.

`LOD-DESIGN.md` (the flat-world far field) is **not** superseded — it remains the flat-mode
contract. Its faceted analogue (`FacetFarRing`) is what gets replaced.

---

## 3. The constraint, re-characterized: "VoxelTerrain cannot be rotated" is false as stated

### 3.1 What the vendored engine actually does

- **Streaming**: `VoxelTerrain::process_viewers()` converts every viewer's world position into
  terrain-local space via `get_global_transform().affine_inverse()` and even scales view
  distances by the basis (`terrain/fixed_lod/voxel_terrain.cpp:1213-1218,1253`). The streamed
  box is axis-aligned **in terrain-local space** — which for a facet terrain is exactly the
  facet lattice. This is precisely the semantics multi-facet streaming needs.
- **Rendering**: every mesh block's world transform is parent-composed; a transform change
  re-applies `set_parent_transform(transform)` to all mesh blocks
  (`voxel_terrain.cpp:867-882` NOTIFICATION_TRANSFORM_CHANGED handler; `:1988`, `:2178`).
  Rotation is carried like any Transform3D.
- Nothing in the module inverts a bare `Basis` on the streaming path; there is no det
  assertion to trip for an orthonormal basis (grep over the module finds basis inversion only
  in editor code and `VoxelBlockyType` rotation resolution).

### 3.2 Where the det==0 spam actually came from

The R2.2 experiment rotated the terrain by the **per-frame bend transform F** built from
`CosmosTruePlace` — and that basis is *genuinely singular* in identified regions:
`cosmos_true_place.gd:99` ("dir_of_window has no true direction → d_cam = ZERO → a singular
mt (Basis.invert det==0)") and `:114` ("a singular F… Basis.invert det==0 spam the moment
anything inverts it"). The engine faithfully spammed `affine_inverse()` errors because it was
handed a **singular matrix**, and the failure was recorded as "godot_voxel cannot be rotated"
(`module_world.gd:345-349`, `main.gd:118`, `world_manager.gd:946`) — an overgeneralization
from a degenerate input to all rotations. A facet placement transform
(`facet_atlas.gd:270-277`) is orthonormal with det = +1 (machine-checked per facet by
verify_faceted: "every basis right-handed det=+1", `verify_faceted.gd:477`), and inverts
exactly.

### 3.3 Answers to the three boundary questions

**(a) Own basis vs rotated parent:** the engine code paths use `get_global_transform()`
exclusively — own-basis rotation and rotated-parent composition are the same case. Both are
handled. The practical caveats are API-level, not engine-level: `is_area_meshed` takes a
**local-space** AABB (callers must convert — `module_world.gd:1592-1603` already learned this
lesson for translation), and `VoxelToolTerrain` raycasts in local space (irrelevant: VOXIVERSE
raycasts analytically). Module-generated collisions are known-broken with multiple terrains
(LOD-RESEARCH §2.4, upstream issue #287) — irrelevant: `generate_collisions = false`
(`module_world.gd:290`).

**(b) The GDScript fallback:** never had any such constraint. `ChunkStreamer`/`ChunkMesher`
emit plain `ArrayMesh`es; a rotated parent Node3D is trivially supported. The fallback's
limitation is merely that `chunk_streamer.gd:33-53` has no facet awareness (plain XZ ring) —
a bounded follow-up, not a blocker (the live web path is the module,
`module_in_web=yes`).

**(c) VoxelLodTerrain / VoxelMesherBlocky:** `VoxelMesherBlocky.supports_lod()` returns true
in the vendored 1.4.1 (`meshers/blocky/voxel_mesher_blocky.h:82-84`; scaled meshes + skirts,
LOD-RESEARCH §2.3), but our runtime generator refuses `lod != 0` (`module_world.gd:1772-1774`)
— generator-side LOD (stride-2^lod column sampling) is a small, contained change.
`VoxelLodTerrain` itself is compiled into the build, but it is the wrong tool off the active
facet: it doubles traffic on the shared 4-worker web pool for regions we can mesh statically,
and its LOD selection is distance-from-viewer, not screen-space error — useless for the
telescope case. The decisive alternative: **both `VoxelGenerator.generate_block(buffer,
origin, lod)` and `VoxelMesher.build_mesh(voxel_buffer, materials)` are script-exposed**
(`generators/voxel_generator.cpp:60-65`, `meshers/voxel_mesher.cpp:176-191`), so a decoupled
layer can produce true blocky meshes at any stride, at C++ speed, on a background thread,
with zero voxel-worker-pool load and zero engine patches.

**Conclusion:** the constraint's true boundary is "never hand godot_voxel a singular
transform, and keep the *editable* terrain's local frame = the frame your analytic physics
lives in." Statically-rotated additional terrains are inside the boundary. Gate FP-R0 (§8)
re-proves this live before anything is built on it.

---

## 4. Root causes, ranked by confidence

### R1 — no voxels on neighbouring facets: **CONFIRMED, by design (not a bug)**

Single `gen_facet` per epoch + ridge masking to AIR (`module_world.gd:1908-1909`,
`facet_atlas.gd:487-489`) + 4×4 quads for everything else (`facet_far_ring.gd:13,49-50`).
Working exactly as FP2/FP3 specified; the spec is what's wrong (§2). Note the shipped ring is
*thinner* than its own spec — COSMOS-FACETED-IMPL §5.2 called for full-resolution junction
bands and 4-block-pitch neighbour heightmaps that were never built.

### R2 — terrifically slow crossing: **CONFIRMED, an artifact — four compounding defects**

1. **Teardown instead of reuse** (`module_world.gd:1283-1310`): the old facet's ~fully
   streamed near field — data blocks AND meshes — is destroyed and rebuilt from scratch,
   though the new facet's field was never resident. Fundamental cost of a crossing should be
   ≈ *streaming the new facet's near disk once, ideally before it's needed*; the shipped cost
   is that PLUS losing everything already paid for.
2. **The 256-radius / 8×-cost mis-branch** (`terrain_config.gd:133-134`, §1.1): the restream
   regenerates a 512×256×512 box of sphere-profiled columns — order 5–8k non-trivial
   generation tasks × 256 column profiles each ≈ 1.5–2M `profile_at_dir` evaluations on 4
   pinned WASM workers, with a 6 ms/frame main-thread apply choke. Tens of seconds to minutes
   of visible refill. The curved mode learned this exact lesson and dropped to 128
   (`terrain_config.gd:120-127`); faceted never inherited it.
3. **The M4 cover is structurally inoperative for facet crossings.** Even if
   `NEAR_COVER_ENABLED` were flipped on, the guard `old_wrapper_pos != position`
   (`module_world.gd:1302`) can never pass: a facet crossing never repositions the module
   wrapper (`world_manager.gd:1263-1265` captures `old_mod_pos = _module_world.position` and
   the node is never moved — contrast the curved flip, `:1322-1325`), so `old_wrapper_pos ==
   position` and the old terrain is freed immediately. And even if pinned, a world-position
   pin is the wrong bridge for faceted: the render frame *rotates* by the dihedral at a
   crossing, so a correct cover needs `crossing_transform(A,B)` applied — which is §3's
   rotation, again.
4. **Synchronous far-ring rebuild** (`facet_far_ring.gd:34-58`): a full 3456-facet scan,
   re-emission of ~1.7k cached facets through SurfaceTool + `generate_normals` + commit, plus
   25 noise profiles per newly-front-hemisphere facet, all in one main-thread frame, in the
   same frame as the restream kickoff. (Minor: `_make_generator` also recompiles its GDScript
   source per restream, `module_world.gd:2057-2059`.)

### R3 — chunks stop rendering after crossing: **CONFIRMED mechanism + one PLAUSIBLE aggravator**

- **CONFIRMED (structural blank-out):** at the crossing instant, three things remove all
  geometry at once — (i) the old facet's entire voxel field is freed (defect 3 above: no
  cover possible), (ii) `FacetFarRing.set_active(B)` removes B's quad from the ring (the
  active facet is always excluded, `facet_far_ring.gd:49-50`) while (iii) B's voxel field
  starts from `max_view_distance = 48` and refills at defect-2's minutes timescale. Net: the
  player stands on invisible analytic ground, inside a far-ring hole, watching a 48-block
  puddle grow at WASM-worker speed. At spawn the identical fill is masked by the ShaderPrewarm
  overlay hold; at a crossing nothing masks it. This *is* "all chunks stop being rendered" as
  experienced.
- **PLAUSIBLE (corner ping-pong storm):** `maybe_cross_facet` checks only distance to the
  *crossed* ridge; the reframed position is guaranteed ~HYST inside B along that plane
  (mid-edge crossings are safe — B's welded plane is A's with flipped orientation), but near a
  facet corner it can land beyond one of B's *other* ridges, re-firing a full
  teardown+restream every physics tick (B→C→…), each print-logged
  (`world_manager.gd:1270`). There is no crossing cooldown and no interior-containment check.
  Diagnosis: repeated `[WorldManager] facet cross` lines in the live console.
- **REFUTED:** the suspected "module node not repositioned" cause. In faceted mode the render
  frame is the active lattice at identity — `node_origin()` is chart machinery
  (curved-only); the wrapper correctly stays at ZERO for both A and B. Also REFUTED as a
  general cause: "reframed pos outside B's ridges" (true only in the corner sub-case above).
- **REFUTED:** epoch staleness — `TerrainConfig.set_active_facet(to)` at
  `world_manager.gd:1258` precedes generator creation, so `gen_facet` freezes to B correctly
  (`module_world.gd:2087`).

---

## 5. Option space, scored

Scoring axes: web gate (threaded WebGL2/Compatibility, COOP/COEP, 4-worker pool, 6 ms apply
budget), NEVER-OOM memory, engine-patch cost, seam correctness, and reach toward R1–R4.

### (a) Multiple VoxelTerrains under rotated parents — **adopt for the near ring**

- Feasibility: engine-supported per §3.1 (gate FP-R0 must confirm live on web). Each facet
  terrain streams an axis-aligned box **in its own lattice** — exactly the right semantics.
  One global `VoxelViewer` serves all terrains (viewers are engine-global; each terrain
  localizes the position — `voxel_terrain.cpp:1253`). Each terrain gets its own generator
  (frozen `gen_facet`) and its own `VoxelMesherBlocky` instance with its own FP-CARVE plane
  blob (`set_facet_carve` is per-mesher, patch 0004 :461,:577) sharing the ONE baked
  `VoxelBlockyLibrary` — so seams clip correctly per facet with zero new C++.
- Memory: the dominant cost is the surface shell of data blocks + meshes. Active terrain at
  128-view ≈ handful of MB-scale shell (uniform air/solid blocks collapse in godot_voxel);
  neighbours at 64–96-view proportionally less. Pool of 1 active + ≤4 neighbours fits a
  measured ceiling; enforce with explicit caps (§7).
- Cost drivers: shared 4-worker pool — neighbour streaming competes with the active facet
  (engine priority is distance-to-viewer, which is the right order anyway). Wasted generation
  in masked-air regions (each neighbour's box overlaps foreign territory) — mitigate with a
  block-level facet-domain early-out in the generator (cheap, `FacetAtlas.dom_min/dom_max` +
  seam planes vs block AABB, before the column-profile pass).
- Limit: does **not** scale to R4's far/telescope range (no LOD, 512 cap). Near-ring only.

### (b) Decoupled multi-LOD blocky-mesh layer for all visible facets — **adopt for mid/far**

- Generalize `FacetFarRing` from coloured quads to true voxel meshes: per facet, fill a
  `VoxelBuffer` via the script-exposed `generate_block(buffer, origin, lod)` (generator
  extended to stride-2^lod sampling) and mesh it with a dedicated
  `VoxelMesherBlocky.build_mesh()` call — **C++ generation + C++ meshing with no terrain
  node**, runnable on a plain background `Thread` (the web export is threaded) or under a
  FarTerrain-style main-thread ms-budget. Place the `MeshInstance3D`es under the facet's
  rigid transform. Resolution per facet chosen by **screen-space error** (§6.3) — this is the
  single mechanism that serves walk, flight, orbit AND telescope.
- Web gate: plain opaque vertex-lit meshes, zero shaders beyond the existing material path,
  zero voxel-pool load, bounded main-thread apply. Memory: meshes only (no persistent
  VoxelBuffers — buffers are transient per build), LRU-capped.
- Seam correctness: at LOD0 the junction cells resolve through the same
  `junction_modify`/carve sentinels; at LOD>0 a coarse polygon clip (facet domain mask)
  suffices — seams sit under the near ring or beyond visual acuity by selection.
- This is LOD-RESEARCH Option-C machinery upgraded from heightmap-quads to blocky meshes,
  reusing the C++ mesher instead of hand-rolled GDScript meshing.

### (c) Unified world-space voxel clipmap spanning facets — **reject**

A single world-axis-aligned clipmap cannot represent per-facet lattices: facet voxels are
axis-aligned only in their own frames (that undistortedness IS the faceted pivot's product).
A world-space grid would resample rotated lattices → aliasing at every seam, a second notion
of "what's solid here" (violates engine rule 1), and it forfeits `junction_modify`'s
exactness. Also the only option requiring genuinely new engine machinery. Dominated by (a)+(b)
on every axis.

### (d) Crossing as cheap re-designation (pre-warmed pool / double-buffer) — **subsumed by (a)**

The FP3 spec's own fallback. With rotation admitted, the double-buffer degenerates into
something better: the neighbour terrains are *already live* under the assembly; a crossing
re-designates which one is "active" (editable, full view distance) and updates ONE root
transform. No swap-blink, no pre-warm choreography, no teardown ever. View-distance changes
stream only the delta annulus (grow B 96→128, shrink A 128→96) — the engine diffs the boxes
(`process_viewers` prev/new state) rather than reloading.

**Recommendation: (a) for the near ring + (b) for everything else + (d)'s re-designation as
the crossing model.** All three share one selection principle (screen-space error → pick
representation: editable terrain / static LOD mesh / nothing-yet) — that is the "one generic
streamer" R4 asks for.

---

## 6. The target architecture: the Planet Assembly

### 6.1 Scene shape

```
WorldManager
 └─ PlanetRoot (Node3D, transform = T_active⁻¹  — the FacetFarRing placement, generalized)
     ├─ FacetTerrain[active]   VoxelTerrain @ T_fid  (composite = identity: axis-aligned, editable)
     ├─ FacetTerrain[n1..n4]   VoxelTerrain @ T_fid  (rotated composites; render-only, no edits)
     └─ FacetLodMesher         per-facet MeshInstance3D sets @ T_fid, LOD ℓ ∈ {1..5} + horizon quads
```

- **World frame invariant:** world coords = active facet lattice (unchanged — analytic
  physics, DDA, GroundCollider, collapse all keep their contracts). The active terrain's
  composite transform is identity BY CONSTRUCTION (`T_active⁻¹ · T_active`), so the editable
  field stays axis-aligned exactly as today; rule 1 (`block_id_at` is THE query) is untouched.
- **One global VoxelViewer** (unchanged). Every live terrain streams around the player's
  position as expressed in its own lattice — dihedral tilt at k=24 is 3.75°/seam, so a player
  at a ridge sits well inside every neighbour's vertical stream slab.
- **Masking already prevents double-render:** each terrain's generator masks beyond its own
  ridges (`junction_modify` on its frozen `gen_facet`); carve sentinels clip the junction
  cells to the shared welded planes from each side. The two cut faces at a ridge are coplanar
  with opposite windings — each visible only from its own side (no z-fight; gate asserts it).

### 6.2 Lifecycle & pool policy (NEVER-OOM discipline)

- `FacetTerrain[active]`: view distance 128 (fix the §1.1 mis-branch; faceted ⇒ 128).
- Neighbour terrains: spawned when the player is within `D_warm ≈ 96` blocks of the shared
  ridge, view distance 64–96, retired (freed) beyond `D_warm + 32` (hysteresis). Hard pool
  cap: **1 active + 4 neighbours** (near a corner: the 2 edge-neighbours flanking it +
  their shared diagonal — still ≤ 4). Each spawn/retire is one terrain, amortized, never in
  the crossing frame.
- Ceilings: a measured per-terrain byte budget asserted in verify (data blocks + mesh count);
  the pool cap is a const; the LOD-mesh cache (§6.3) is LRU with a hard mesh-count and
  triangle cap (the FacetFarRing/FarTerrain cap discipline). All new memory is flag-gated OFF
  by default behind the A/B gate per the never-OOM rule.

### 6.3 FacetLodMesher — the generic multi-scale layer (replaces FacetFarRing)

- Per facet, LOD ℓ meshes are built from `generator.generate_block(buffer, origin, ℓ)`
  (generator gains stride-2^ℓ column sampling; LOD0 semantics byte-identical) +
  `mesher.build_mesh(buffer, materials)` on a background Thread, applied under a main-thread
  ms budget. A facet at ℓ renders 2^ℓ-block "megablocks" — the honest Minecraft-like distant
  look; the coarsest tier degrades to the current coloured quad (kept as ℓ=∞).
- **Selection = screen-space error:** projected block size in pixels
  `p ≈ (2^ℓ · viewport_h) / (2 · dist · tan(fov/2))`; choose the largest ℓ with `p ≤ τ`
  (τ ≈ 2–4 px), with hysteresis. This ONE rule covers every regime:
  - walking: adjacent facets resolve ℓ=0–1 near the seam (R1 at distance);
  - low flight: facets below resolve ℓ=1–2, horizon coarsens;
  - near orbit: whole hemisphere at ℓ=3–5, nadir facets finer (R4);
  - telescope: zoom shrinks `fov` → `p` rises → the selector requests fine ℓ for exactly the
    facets in the magnified frustum, budget-capped (R4). A distant planet is the same math
    with `dist` large and `fov` tiny.
- Never-OOM at the telescope extreme: the selector requests, a budgeter grants — hard caps on
  live fine-ℓ facets (e.g. ≤ 9 at ℓ≤1 beyond the near ring) + LRU eviction + lifetime caps.
  Degradation is graceful (one ℓ coarser), never unbounded.
- Trees/edits at LOD: worldgen trees appear from ℓ where their stride survives (accepted
  shimmer, LOD-RESEARCH §2.3); player edits are invisible beyond the live terrains
  (accepted — same acceptance the flat FarTerrain ADR already made).

### 6.4 Crossing = re-designation

On `own_dist < −HYST` (unchanged detection):

1. `TerrainConfig.set_active_facet(B)` (unchanged).
2. `PlanetRoot.transform = facet_transform(B).affine_inverse()` — ONE assignment; every child
   terrain and LOD mesh moves rigidly (engine re-transforms mesh blocks, §3.1). B's terrain
   composite becomes identity (axis-aligned, editable); A's becomes rotated (render-only).
3. Player reframe (unchanged f64 math, `player.gd:136-139`).
4. View-distance rebalance: B 96→128, A 128→96 — delta-annulus streaming, no teardown.
5. Swap the carve/edit designation; edit keys are `(fid, cell)`-global (§6.5) so nothing
   migrates.
6. LOD selector notices the new distances; no rebuild storm (meshes are facet-anchored;
   only placement changed — the FacetFarRing "rigid re-parent" insight, now applied to
   everything).

No generator is created, no terrain freed, no far-layer rebuilt, no cover needed. The
remaining transient is a sub-frame transform update. R2 and R3's confirmed mechanisms are
removed *categorically*, not mitigated. Add a **containment check + cooldown**: after
reframe, verify the position is interior to all four of B's ridges (else resolve the corner
case explicitly via the diagonal neighbour) — kills the ping-pong storm (§4-R3).

### 6.5 Edits and interaction scope

- Edit keys become facet-global `(fid, cell)` ints (the FP3b-3 debt, COSMOS-FACETED-IMPL
  §6.2) — mandatory before any multi-facet work, since active-lattice Vector3i keys corrupt
  across re-designations today (§1.4).
- Break/place remains **active-facet-only**: reach is 8 blocks and the seam strip is no-build
  by design (FP4 spec), so the un-editable window is a ≤ ~4-block sliver beyond a ridge the
  player can close by stepping over it (which is now cheap). Acceptable; generalizing later
  means routing `set_cell` to the neighbour terrain's `VoxelTool` + a neighbour-lattice DDA
  segment — bounded, deferred to FP4 as already specced (§6.3 of the IMPL doc).

---

## 7. Adversarial review of the recommendation (where it breaks at 3 a.m.)

1. **The rotation constraint might be real on some path we haven't exercised** (e.g. an
   Emscripten-specific transform notification order, or a patch-0003 bake interaction that
   assumes identity). Mitigation: FP-R0 is a *live web* gate, not just headless, and runs
   with patches 0003/0004 active. If it fails: the architecture degrades to option (d)
   two-terrain double-buffering in the ACTIVE frame only (unrotated pre-warm at B's lattice,
   swap on cross) + LOD-mesh neighbours from (b) — R1 loses live-voxel neighbours but keeps
   block-true LOD meshes; R2/R3 fixes survive intact.
2. **Worker-pool starvation:** 5 terrains × streaming deltas + LOD builds could starve the
   active facet's meshing on 4 WASM workers. Mitigations: LOD builds NEVER touch the voxel
   pool (script Thread); neighbour view distances are small; engine priority is
   viewer-distance; gate asserts active-facet `is_area_meshed` latency during a
   walk-the-planet soak. Watch: `try_schedule`/apply-budget contention at the 6 ms choke —
   raise apply budget only behind the existing smoothness gate.
3. **Seam double-geometry / z-fight when two facets both render voxels:** cut faces are
   coplanar-opposite-winding (§6.1) — but *unclipped fallback lips* (unpatched binary, or a
   −1 carve slot) would interpenetrate visibly from both sides. Gate: seam soak renders both
   sides at LOD0 and asserts carve sentinels resolved (non-negative slots) on BOTH meshers +
   no OOB (`oob_seen`).
4. **Memory at the corner case** (4 neighbours + active + LOD cache + telescope burst): the
   ceilings are only as good as their enforcement. Every cap is a const asserted headless;
   the A/B gate measures real browser heap before default-ON (the never-OOM rule). The
   telescope budgeter is the riskiest cap — it must be *request-grant*, never
   selector-driven-unbounded.
5. **The 8 twist singularities (FP5)**: corner facets where the lattice can't align — a
   neighbour terrain across a twist seam has a lattice 90°-incompatible with the strip.
   The pool policy must treat twist seams as LOD-mesh-only (no live neighbour terrain) until
   FP5 defines the junction there. Explicitly out of scope; asserted by skipping those 8×.
6. **Orbit + gravity/physics:** this review fixes *streaming*; flight/orbit locomotion
   (gravity toward planet centre off-facet, camera far plane 9000 already set in
   `facet_far_ring.gd:16`) is separate work. The streamer must merely not *assume* the viewer
   is on the active facet — it doesn't: selection is pure camera math, terrains stream around
   the viewer wherever it is. But the ACTIVE-facet designation needs an off-surface rule
   (nearest-facet-by-direction) — small, must be in FP-M2's gate.
7. **`_flip_settling`/M4 machinery left half-dead:** re-designation obsoletes the cover/ramp
   for crossings but curved-mode flips still use them. Do NOT delete; gate flat + curved
   byte-identity every stage.

---

## 8. The plan (FPn idiom, each stage independently shippable, live demo never regresses)

Every stage exits through: `verify_faceted` all-green (extended per stage), the FLAT
byte-identity gate (6027/0 on `verify_feature.gd` — all changes flag-gated on
FACETED/new consts), and the live-web playability gate (deployed build loads, plays, and the
stage's specific soak passes on desktop browser).

- **FP-R0 — the constraint kill-shot (spike, ~days).** Headless + live web: one extra
  VoxelTerrain under an orthonormal-rotated parent (a real `facet_transform`), own generator
  (frozen neighbour `gen_facet`), own carve mesher, shared library, shared global viewer.
  Assert: blocks mesh; zero `det==0`/basis errors in the console; `is_area_meshed`
  (local-AABB-converted) true over the streamed core; memory delta per terrain measured and
  recorded. **Exit gate:** the spike facet visibly renders rotated real voxels in the live
  web build with the active facet unchanged. If FAIL → record the true boundary in this doc
  and pivot to the two-terrain double-buffer variant (§7.1).
- **FP-S1 — stop the bleeding (no architecture change, ships alone).**
  (a) `near_render_radius()` returns 128 when `CubeSphere.FACETED` (keep flat 256 —
  byte-identity); (b) block-level facet-domain early-out in the generator before the
  column-profile pass; (c) crossing containment check + cooldown (kills the corner ping-pong
  storm); (d) FacetFarRing: make `set_active` incremental (keep the mesh; re-emit only the
  exclusion delta next frame; cache-warm new hemisphere facets under a ms budget); (e) drop
  the per-restream GDScript generator recompile (compile once, instantiate per epoch).
  **Exit gate:** live crossing max frame ≤ 100 ms (the original FP3 gate) and near-field
  refill under the player ≤ ~10 s; no `facet cross` log storms.
- **FP-M1 — the Planet Assembly + re-designation crossing.** PlanetRoot; active terrain
  reparented; neighbour pool (spawn/retire, caps); crossing per §6.4; `(fid, cell)` edit
  keys (FP3b-3 debt) with a save-format migration note; M4 cover/ramp left curved-only.
  **Exit gate:** cross-and-return byte-identity re-run; live crossing with **no visible near
  hole** (old facet's voxels persist rotated); PerfHUD max frame ≤ 50 ms at a sprint
  crossing; memory ceiling assert (pool × per-terrain budget from FP-R0); `verify_faceted`
  extended with a two-facet seam render soak (carve resolved both sides, no OOB).
- **FP-M2 — FacetLodMesher core (replaces FacetFarRing).** Generator stride-2^ℓ support
  (LOD0 byte-identical — asserted); background-thread `generate_block`+`build_mesh`
  pipeline; screen-space-error selector with hysteresis + request-grant budgeter; tiers
  ℓ∈{1,2,3} + quad fallback; off-surface active-facet rule. **Exit gate:** walking a seam
  shows real megablock detail on ≥3 facets at once; headless selector unit gate (given
  camera params → expected ℓ per facet); triangle/mesh caps asserted; live web soak at
  altitude (fly-hack) holds frame rate.
- **FP-M3 — orbit & telescope.** Extend tiers to ℓ∈{4,5}; zoom-FOV input to the selector;
  fine-ℓ burst budget + LRU; horizon-hemisphere handling (back-face facet culling already in
  the ring, generalized). **Exit gate:** scripted orbit camera sees the whole planet with
  nadir facets at block resolution within the budget; telescope zoom onto an antipodal facet
  resolves ℓ≤1 within N seconds and within the mesh cap; browser heap delta within the
  measured ceiling (the A/B gate before default-ON).
- **FP-M4 — polish & debt.** Fallback-path facet awareness (rotated ChunkStreamer parents);
  neighbour-facet interaction window (route edits/DDA across the seam, FP4 scope); twist-seam
  (FP5) exclusion made explicit; docs: supersede-markers into COSMOS-FACETED-IMPL §4.2/§5.2/§6.1
  and the det==0 comments in `module_world.gd:345-349` / `main.gd:118` / `world_manager.gd:946`
  corrected to the true boundary (§3.3).

Sequencing rationale: FP-S1 ships user-visible relief immediately and de-risks nothing else;
FP-R0 is pure knowledge and can run in parallel; FP-M1 removes R2/R3 categorically and
delivers R1-adjacent; FP-M2/M3 deliver R1-at-distance and R4. Each stage leaves the deployed
demo strictly better.

---

## 9. Superseded-decisions ledger

| # | Decision | Status after this review |
|---|---|---|
| 1 | "godot_voxel must never be rotated" (module_world.gd:345-349 et al.) | **Superseded** (pending FP-R0 live confirmation): true boundary = "never a singular transform; editable terrain stays in the physics frame" |
| 2 | Single-active-facet voxel field (FACETED-IMPL §4.2/§5.2) | **Superseded** by the Planet Assembly pool (§6) |
| 3 | Crossing = set_facet teardown + M4 restream (FACETED-IMPL §6.1) | **Superseded** by re-designation (§6.4); M4 cover/ramp remain curved-mode-only |
| 4 | FacetFarRing quads as the only off-facet representation | **Superseded** by FacetLodMesher (§6.3); quads remain the coarsest tier |
| 5 | `near_render_radius()` keyed on FLAT_WORLD only | **Corrected**: FACETED takes the 128 branch (FP-S1) |
| 6 | Active-lattice Vector3i edit keys under FACETED | **Corrected**: `(fid, cell)` global keys (FP-M1; was already spec'd in FACETED-IMPL §6.2, never implemented) |
| 7 | LOD-DESIGN.md (flat far field) | **Unchanged** — flat-mode contract stands |
