# LOD Research — Distant Terrain Generation & Rendering for VOXIVERSE

**Status: research only — nothing here is implemented.** This report evaluates the vision:

> *"Generate generic coarse terrain and render it within a radius of a few thousand blocks; then
> transition to the standard block-chunk generation/rendering we do now near the player."*

i.e. distant mountains and coastlines visible as coarse silhouettes far beyond today's
256-block fog wall, seamlessly handing off to full voxel detail up close.

All engine/codebase claims below were verified against the working tree (commit `c5f6dec` on
`main`, plus the in-flight `feat/voxiverse-multi-liquid` branch that carries the Mountains
biome) and against the pinned engine (`docker/engine/versions.env`: Godot `4.4.1-stable`,
godot_voxel `v1.4.1`, emsdk `3.1.64`). Web claims are cited inline; a full annotated source
list is in §9.

---

## 0. Executive summary and recommendation

1. **The commonly-repeated claim "godot_voxel LOD is smooth-only" is out of date — but only
   barely.** `VoxelLodTerrain`'s octree LOD was Transvoxel/SDF-only through v1.3. **v1.4
   (March 2025) added *basic* blocky support**: "Can be used with `VoxelLodTerrain`. Basic
   support: meshes scale with LOD and LOD>1 chunks have extra geometry ['LOD skirts'] to
   reduce cracks" ([changelog](https://voxel-tools.readthedocs.io/en/latest/changelog/)).
   Our custom-built **v1.4.1 already contains this**. It remains explicitly second-class:
   the docs still say `VoxelLodTerrain` is "preferably used with smooth meshing such as
   `VoxelMesherTransvoxel` … blocky meshers can be used, although they currently don't have
   as much support for LOD"
   ([VoxelLodTerrain API](https://voxel-tools.readthedocs.io/en/latest/api/VoxelLodTerrain/)).
   There is no blocky seam *stitching* (only skirts), edits work only at LOD0, and skirts
   have known hole cases ([issue #63](https://github.com/Zylann/godot_voxel/issues/63)).
2. **`VoxelTerrain` (our near path) can never do this alone**: it is "voxel volume using
   *constant* level of detail" with an **internal hard cap of 512** on `max_view_distance`
   "because going further can affect performance and memory very badly"
   ([VoxelTerrain API](https://voxel-tools.readthedocs.io/en/latest/api/VoxelTerrain/)).
3. **The decisive VOXIVERSE-specific fact: the world is a pure analytic heightmap.**
   `TerrainConfig.height_at(x,z)` / `column_profile(x,z)` (`godot/src/world/terrain_config.gd`)
   produce surface height *and* biome for any column in ~7 FastNoiseLite evaluations, with no
   voxel data, no chunk generation, and no second copy of the logic that could drift. A
   distant terrain layer can therefore be generated **analytically for pennies** and is
   **consistent with the near voxel surface by construction** (both derive from the same
   function — the seam analysis in §6.4 shows the residual error is ≤ 1 block of smoothing
   quantization).
4. **Recommendation: build a custom analytic far-field mesh layer** (Option C, §5.3): a
   chunked, quadtree-style ring of coarse heightmap meshes sampling `height_at` at 4→32 m
   cells out to ~3,000 blocks, biome-coloured via vertex colours, biased ~1 m below the true
   surface, overlapping the outer voxel band Distant-Horizons-style, with the fog retuned
   from a 243 m wall into a long haze. It is the only option that (a) needs zero engine
   changes, (b) adds zero load on the single web voxel worker, (c) is trivially consistent
   with the near field, and (d) is comfortably inside WebGL2 budgets (~250–400 k triangles,
   ~10–20 MB, ~150 draw calls — §6.6). Prototype effort is small (§7).
5. **Keep `VoxelLodTerrain` (blocky, v1.4.1) as a tracked fallback/mid-field experiment**,
   not the primary plan: it would double generation traffic on the **single** web voxel
   worker thread (`project.godot` caps `voxel/threads/count` for the fixed Emscripten pthread
   pool), its blocky LOD is young, and replacing the near `VoxelTerrain` would force a rework
   of the edit-overlay mirroring (`bulk_inject`, `try_set_block_data`) that `module_world.gd`
   is built around.

---

## 1. Ground truth: the engine today (verified against source)

| Fact | Where verified |
|---|---|
| Renderer **locked** to GL Compatibility (`renderer/rendering_method="gl_compatibility"`), "most reliable backend" comment | `godot/project.godot` (lines 4, 27–28) |
| Web export is **threaded WASM**, COOP/COEP mandatory; voxel worker pool capped (`voxel/threads/count/minimum=2`, `ratio_over_max=0.0`, `margin_below_max=0`) because the Emscripten pthread pool is **fixed-size** — oversubscription deadlocks meshing | `godot/project.godot` (lines 52–65); `module_world.gd` header ("WEB THREADING … We cap it to 1 thread") |
| Near path: `VoxelTerrain` + `VoxelMesherBlocky`, `max_view_distance = RENDER_RADIUS_BLOCKS = 256`, `mesh_block_size = 32` (draw-call motivated), `generate_collisions = false` (physics is analytic) | `module_world.gd` `setup()` (lines 150–172) |
| The runtime `VoxelGeneratorScript` **early-outs on `lod != 0`** (`if lod != 0: return`) — today's generator produces LOD0 only | `module_world.gd` `_make_generator()` (line ~896) |
| Terrain is a pure heightmap: `height_at(x,z)` = continent spline + hills FBM + detail noise (+ beach shelf); `column_profile(x,z)` returns `(height, biome, continentalness, temperature)` as a value-type `Vector4` | `terrain_config.gd` (lines 296–374) |
| `main` branch: `MAX_SURFACE_Y = 24`, `VIEWER_VERTICAL_RATIO = 0.2`, no mountains | `terrain_config.gd` on `main` |
| **Mountains live on `feat/voxiverse-multi-liquid`**: `MOUNTAIN_AMPLITUDE = 92`, mask/continentalness-gated uplift, `B_MOUNTAINS = 9`, peaks ≈ y 103–112, `MAX_SURFACE_Y = 116`, `VIEWER_VERTICAL_RATIO = 0.5` | `git show feat/voxiverse-multi-liquid:godot/src/world/terrain_config.gd` (lines 97–141, 162) |
| Fog: depth fog, `begin = 256*0.45 ≈ 115`, `end = 256*0.95 ≈ 243`, `fog_sky_affect = 0` — the world is **fully occluded ~13 m before the render edge**. This is the wall the far field must replace. | `godot/src/main.gd` `_setup_environment()` (lines 76–84) |
| Per-block colour + name + mass table exists (`BlockCatalog.color_of(id)`), and fallback materials already use `vertex_color_use_as_albedo` — vertex-coloured far meshes fit the existing material style | `godot/src/sim/block_catalog.gd` (line 380+); `godot/src/world/block_materials.gd` (lines 86–96) |
| Both render paths and all gameplay read `TerrainConfig` — a far-field layer reading the same functions cannot disagree with the world | `terrain_config.gd` header; CLAUDE.md rule 2 |

Two facts deserve emphasis because they shape everything below:

* **No caves/overhangs, by locked decision** (`terrain_config.gd` header: "The world is a pure
  heightmap above bedrock — no 3D caves/overhangs"). A heightmap far field is therefore an
  *exact* representation of distant terrain, not an approximation of it. Minecraft mods doing
  this (§4) have to approximate a fully 3D world; we do not.
* **The mountains are the payoff.** On the multi-liquid branch a full-mask inland peak gains
  up to 92 blocks (y ≈ 103–112). A 112 m peak at 3 km subtends ~2.1° — a genuinely visible
  silhouette. The far field must be true 3D geometry, not a flat skirt.

---

## 2. What godot_voxel and Godot 4.4 actually support today

### 2.1 `VoxelTerrain` — the near path — has no LOD and a 512 cap

The class is documented as "Voxel volume using **constant** level of detail", and
`max_view_distance` carries "an internal limit of 512 for constant LOD terrains, because going
further can affect performance and memory very badly at the moment"
([VoxelTerrain API](https://voxel-tools.readthedocs.io/en/latest/api/VoxelTerrain/)).
So even ignoring performance, the *maximum* the current architecture could ever show is 512
blocks — a 2× fog push, not "a few thousand". Any few-thousand-block vision requires a second
mechanism.

### 2.2 `VoxelLodTerrain` — the module's real LOD system

([VoxelLodTerrain API](https://voxel-tools.readthedocs.io/en/latest/api/VoxelLodTerrain/),
[smooth terrain / LOD docs](https://voxel-tools.readthedocs.io/en/latest/smooth_terrain/))

* **Octree of blocks**: "multiple parented grids, each with blocks twice the size of their
  children"; going from LOD `i` to `i+1` doubles voxel/block size at constant block
  resolution — classic voxel octree LOD.
* `lod_distance` (default 48) = how far LOD0 spreads; `lod_count` (default 4) = hierarchy
  depth; each parent LOD extends twice as far. `view_distance` default 512 but configurable
  far beyond (it's the whole point of the node). For a 3,072-block horizon with LOD0 to ~48 m
  you'd need `lod_count ≈ 7`.
* **Transvoxel** (`VoxelMesherTransvoxel`, Eric Lengyel's algorithm) is the flagship mesher:
  "an extension of Marching Cubes … The advantage of this algorithm is to integrate stitching
  of different levels of details without causing cracks." Seams are handled by *transition
  meshes* plus a documented vertex-shader protocol (`CUSTOM0` attribute + `u_transition_mask`
  uniform). LOD fading (cross-fade dither via a `u_lod_fade` shader uniform) is documented but
  opt-in and has a known self-shadowing caveat.
* **Generators run per LOD**: the generator's `lod` parameter "may be used as a power of two,
  telling how big is one voxel … you should sample that noise at steps of `2^lod`, starting
  from `origin_in_voxels`"
  ([generators doc](https://github.com/Zylann/godot_voxel/blob/master/doc/source/generators.md)).
  Our analytic `column_profile` can trivially be sampled at stride `2^lod` — the generation
  side of LOD is *easy* for us.
* **Edits are LOD0-only**: "Only full-resolution voxels can be edited, so that means you can
  only modify terrain in a limited distance around the viewer" (workaround `full_load_mode`
  costs memory — a non-starter on web).
* The **detail normalmap** system (virtual-texture normals for distant flat polygons) exists,
  but its GPU path "is possible … if it supports Vulkan" — i.e. **unavailable under GL
  Compatibility/WebGL2**; the CPU path would compete with meshing on our single worker.

### 2.3 The blocky-LOD verdict, stated plainly

**Historically true, now nuanced.** Until v1.3, `VoxelLodTerrain` was effectively
Transvoxel-only and the blocky path was uniform-resolution — the "known fact" holds for every
version before March 2025. As of **v1.4** (and therefore our pinned **v1.4.1**), the
[changelog](https://voxel-tools.readthedocs.io/en/latest/changelog/) records under
`VoxelMesherBlocky`:

> "Can be used with `VoxelLodTerrain`. Basic support: meshes scale with LOD and LOD>1 chunks
> have extra geometry to reduce cracks" and "Added option to turn off 'LOD skirts' when used
> with `VoxelLodTerrain`, which may be useful with transparent models."

v1.4 also fixed a crash "when invalid model IDs are present at chunk borders with
`VoxelLodTerrain`" — a hint about the maturity level. What this support *is*: the mesher
builds a normal blocky mesh from a `2^lod`-strided ID buffer and **scales it up**, so an LOD3
"block" renders as 8 m cubes; cracks between LOD rings are hidden by **skirts** (extra
downward geometry at block edges), not stitched. Known limitations to plan around:

* Docs still steer users to Transvoxel; blocky "currently do[es]n't have as much support for
  LOD" ([VoxelLodTerrain API](https://voxel-tools.readthedocs.io/en/latest/api/VoxelLodTerrain/)).
* Skirts can leave holes when adjacent octrees subdivide differently
  ([issue #63](https://github.com/Zylann/godot_voxel/issues/63) — filed against smooth skirts,
  but it is the same mechanism blocky LOD reuses).
* Downsampled *ID* fields are lossy in a way SDFs are not: a 2×-strided sample of a 1-block
  ice sheet or a tree canopy simply misses content; there is no "average of IDs". For our
  terrain (heightmap + thin surface layers) this shows up as distant surface-material
  shimmer between LOD levels.
* Waterlogged twins / fluid models / our frozen ARID manifest were designed and tested for
  LOD0 only; the generator would need per-LOD manifest discipline.

**Bottom line:** blocky LOD in 1.4.1 is real but young. It is credible for a *mid-field*
(say 256–1,024 blocks, LOD1–3, where 2–8 m "megablocks" still read as Minecraft-like), and
untested-by-us for a 3 km horizon (32 m cubes read as abstract voxel art — possibly a feature,
possibly not).

### 2.4 Can `VoxelTerrain` (near, blocky) and `VoxelLodTerrain` (far) run simultaneously?

Nothing in the module forbids multiple terrain nodes; `VoxelViewer` attaches per-player and
all terrains observe it. Community evidence:
[issue #287](https://github.com/Zylann/godot_voxel/issues/287) reports that with two terrain
nodes "everything works except the collisions of the second node" — i.e. **rendering multiple
terrains works**; the broken part (module-generated collisions) is one VOXIVERSE explicitly
does not use (`generate_collisions = false`, analytic physics). The real cost is elsewhere:
**both nodes share `VoxelEngine`'s task pool, which our web build caps to a single worker
thread** (`project.godot` `voxel/threads/count/*`; `module_world.gd` header explains the
fixed Emscripten pthread pool). Every far-field block generated or meshed steals time from
near-field meshing — the thing that already gates the "Loading…" prewarm
(`area_meshed`, `module_world.gd` line 787). A second voxel node on web is therefore a
*scheduling* problem before it is a correctness problem.

### 2.5 Godot 4.4 built-ins relevant to a far field

* **No native heightmap terrain node.** Godot 4 ships none ("Godot has no terrain system
  for 3D at the moment" — [Zylann's heightmap plugin README](https://github.com/Zylann/godot_heightmap_plugin));
  `HeightMapShape3D` is collision-only
  ([docs](https://docs.godotengine.org/en/stable/classes/class_heightmapshape3d.html)).
  Whatever we do, the far field is `MeshInstance3D` + runtime `ArrayMesh` (or a third-party
  plugin, §5.4).
* **Visibility ranges** (`GeometryInstance3D.visibility_range_begin/end` + margins +
  `fade_mode`) are the built-in HLOD/band tool
  ([docs](https://docs.godotengine.org/en/4.4/tutorials/3d/visibility_ranges.html)):
  `Disabled` mode gives free hysteresis-based hard switching; `Self`/`Dependencies` fade via
  **alpha blending, which forces the instance into the transparent pass** (a real cost on
  tile-based/weak GPUs and exactly what our overdraw-sensitive Compatibility profile should
  avoid for large terrain sheets). Use hysteresis switching + fog, not alpha fades, for the
  far field.
* **Automatic mesh LOD** is an *import-time* feature; runtime-built `ArrayMesh`es get no
  automatic LODs — our far-field LOD must be explicit (rings/chunk levels).
* **Occlusion culling** is CPU-based (Embree software raster) and platform-agnostic, but
  occluders are baked and "moving `OccluderInstance3D` nodes during gameplay causes expensive
  BVH rebuilds" ([docs](https://docs.godotengine.org/en/4.4/tutorials/3d/occlusion_culling.html)) —
  a poor match for streaming voxel terrain on a WASM CPU budget. Not recommended for v1.
* **Web renderer reality**: "Godot 4.0 and later can only target WebGL 2.0 (using the
  Compatibility rendering method). Forward+/Mobile are not supported on the web platform"
  ([web export docs](https://docs.godotengine.org/en/4.4/tutorials/export/exporting_for_web.html)).
  The Compatibility renderer has **no compute shaders and no RenderingDevice access**
  ([Godot forum](https://forum.godotengine.org/t/compatibility-mode-doesnt-support-compute-shaders-nor-dynamic-buffers/110002));
  WebGL2 additionally brings driver quirks (integer samplers, `fma()`, precision qualifiers —
  see the Terrain3D-on-web writeup in §5.4). **Anything GPU-driven beyond plain
  vertex/fragment shaders is off the table.** Vertex texture fetch *is* core WebGL2/GLES3
  (≥16 vertex texture units guaranteed), so heightmap-in-vertex-shader techniques remain
  possible.

---

## 3. Classic terrain-LOD techniques, scored for a WebGL2 far field

| Technique | Idea | Godot-Compatibility/WebGL2 fit | Verdict for VOXIVERSE |
|---|---|---|---|
| **Geometry clipmaps** ([Losasso & Hoppe 2004](https://hoppe.cs.washington.edu/geomclipmap.pdf); [GPU Gems 2 ch. 2](https://developer.nvidia.com/gpugems/gpugems2/part-i-geometric-complexity/chapter-2-terrain-rendering-using-gpu-based-geometry)) | Nested regular grids centred on the viewer, each ring half the resolution; heightmap sampled in the vertex shader; toroidal texture updates as the viewer moves | Works: vertex texture fetch is core WebGL2. Needs continuous heightmap-texture updates from the CPU (`Image` → `ImageTexture.update`) and a custom vertex shader incl. inter-ring blending | Strong fit *if* we accept shader complexity; constant vertex count (~100–300 k for 7 rings of 255²) and 2 or 3 draw calls. Terrain3D uses exactly this (§5.4) |
| **CDLOD** ([Strugar 2009](https://github.com/fstrugar/CDLOD)) | Quadtree selection + **vertex morphing** between levels in the vertex shader — no cracks, no popping, by construction | Works: selection on CPU, morph is plain VS math + heightmap fetch | Best-in-class transition quality; more implementation effort than clipmaps. The morph trick is worth stealing even for a simpler scheme |
| **Chunked LOD** ([Ulrich 2002](http://tulrich.com/geekstuff/chunklod.html)) | Quadtree of *pre-built static meshes* per chunk per level; **skirts** hide cracks; distance-based selection | Trivially works — it's just `MeshInstance3D`s. No custom shader required | **Best effort-to-value for us**: our heightmap is analytic (chunks are cheap to build at any resolution), chunks are static (terrain never changes at distance), Godot handles culling per chunk. Popping managed by distance + fog + optional morph later |
| **GPU tessellation / mesh shaders** | Hull/domain or mesh-shader amplification | **Unavailable**: not in WebGL2, not in the Compatibility renderer (no compute either) | Excluded by platform |
| **ROAM / per-frame CPU retriangulation** | Continuous triangle-bintree refinement on CPU | "Works" but burns exactly the resource we lack (WASM CPU, main thread) | Legacy; excluded |

**Popping/morphing without geometry shaders:** all three viable schemes solve transitions in
ways WebGL2 supports — clipmap ring blending and CDLOD morphing are pure vertex-shader math;
chunked LOD uses skirts + far switch distances (at ≥1 km, a 2×-resolution swap under haze is
a sub-pixel-scale event for most of the mesh). Godot's `visibility_range` hysteresis handles
the switch scheduling for free (§2.5).

---

## 4. Case study: Minecraft *Distant Horizons* — the canonical voxel near/far hybrid

([CurseForge page](https://www.curseforge.com/minecraft/mc-mods/distant-horizons),
[CurseForge FAQ](https://blog.curseforge.com/distant-horizons-frequently-asked-questions/),
[GitLab](https://gitlab.com/distant-horizons-team/distant-horizons),
[overdraw-prevention explanation](https://www.answeroverflow.com/m/1392143133000728659))

What DH does, distilled from its docs/community material:

* **A second, separate render layer**, not an extension of vanilla chunks: it "renders
  simplified chunks outside of the normal render distance", built by **aggregating voxels**
  into column-oriented LOD data and regenerating meshes per detail level; a **quadtree**
  tracks which detail level each region needs (release notes mention QuadTree node updates
  and buffer-upload optimization). Detail levels halve horizontal resolution (1 m columns →
  2 m → 4 m …). LOD building runs on its own CPU threadpool; LODs persist to a local
  database so revisits are instant.
* **The seam is handled by *overlap*, not by stitching.** DH's `Overdraw Prevention` setting
  makes the LOD layer start rendering *inside* the vanilla render distance: "DH overlaps with
  some part of the vanilla terrain … A value of 1.0 means DH LODs start where vanilla chunks
  end, 0.1 means DH renders very close to the player" — the LOD terrain sits behind/below the
  real chunks so the ragged edge of the full-detail region always has coarse terrain behind
  it, and fog/fading does the rest. **This overlap-plus-fog pattern is the single most
  transferable lesson for VOXIVERSE** (§6.5).
* **Trade-offs it accepts**: distant terrain is colour-only (no block textures), lighting is
  approximate, entities/tile-entities absent, and LOD generation "leans hard on your CPU".
  Players overwhelmingly accept these for the horizon payoff — good evidence that a
  coarse, biome-coloured far field reads as "the world" even in a blocky game.

Difference in our favour: DH must *discover* the world by loading/aggregating real chunks
(the world is edit-heavy, cave-riddled, server-authoritative). VOXIVERSE's far field needs
**no aggregation step at all** — `column_profile(x,z)` *is* the LOD data source, at any
resolution, for free.

---

## 5. The option space

### 5.1 Option A — Native `VoxelLodTerrain` (blocky) replacing or beside `VoxelTerrain`

Use the module's own LOD node with `VoxelMesherBlocky` (possible since v1.4, §2.3), either
(A1) replacing the near `VoxelTerrain` entirely, or (A2) as a far-only node beside it.

* **Pros**: one system; true blocky look at all distances; generator-side LOD is easy for us
  (stride-`2^lod` sampling of `column_profile`); module handles streaming/octree.
* **Cons (A1 — replace)**: edits only at LOD0 (fine), but the whole edit-mirror machinery in
  `module_world.gd` (`bulk_inject` → `try_set_block_data`, `is_area_meshed` prewarm gate,
  frozen ARID manifest) is written and verified against `VoxelTerrain`'s API and would need
  re-validation against `VoxelToolLodTerrain`; blocky-LOD maturity risk lands on the
  *playable* near field — a violation of the "live demo outranks feature depth" gate.
* **Cons (A2 — beside)**: doubles traffic on the **single** web voxel worker (§2.4); double
  memory for overlapping regions (voxel buffers exist in both nodes at LOD0 scale around the
  player unless `lod_distance` is pushed out, which costs more still); the far field would
  render 8–32 m *cubes* (scaled blocky meshes) — a strong aesthetic, but "coarse silhouette"
  was the ask, and megablock skylines are noisier than a smooth ridge under haze; skirt-hole
  risk (§2.3).
* **Memory math (A2, honest rough order)**: with clipbox streaming each LOD keeps a shell of
  blocks; at 32³ mesh blocks / 16³ data blocks with 16-bit TYPE, a 7-LOD stack to ~3 km
  plausibly holds several thousand data blocks ⇒ **tens of MB of voxel buffers plus meshes**,
  against a browser heap that already holds the near field. Not fatal, not free.
* **Feasibility**: Web-compatible in principle (it's the same C++ module we already ship;
  no compute). Genuinely worth a *spike* because we already compiled it — but as mid-field
  enrichment, not as the 3 km horizon.

### 5.2 Option B — `VoxelLodTerrain` + Transvoxel (smooth SDF) as the far field only

Feed the LOD node an SDF generator (`sdf = y − height_at(x,z)`, sampled at `2^lod` stride)
and let Transvoxel produce a smooth distant surface with proper LOD stitching, while
`VoxelTerrain` stays the near world.

* **Pros**: the mature, first-class path of the module (stitching, LOD fading shader hooks);
  a smooth distant silhouette is arguably *closer* to the "coarse generic terrain" vision
  than megablocks; consistent by construction (same `height_at`).
* **Cons**: same single-worker contention and memory profile as A2; marching an SDF is the
  most expensive way imaginable to triangulate a heightmap we can triangulate directly
  (every far block pays 3D SDF sampling + Transvoxel for what is a 2.5D surface);
  biome colouring requires a custom material path (Transvoxel gives positions/normals — we'd
  add colour via a shader sampling our own biome data, i.e. we build half of Option C
  anyway); water needs a separate plane regardless; the detail-normalmap system that makes
  distant Transvoxel pretty is Vulkan-gated (§2.2) — unavailable on web.
* **Verdict**: dominated by Option C on every axis except "uses existing module code".

### 5.3 Option C — Custom analytic far field (chunked heightmap LOD) — **recommended**

A `FarField` node (plain GDScript + `ArrayMesh`) that renders rings of coarse heightmap
chunks from `TerrainConfig.column_profile`, outside and *slightly under* the voxel world.
Design detail in §6.

* **Pros**: zero engine changes, zero voxel-worker load (built on the main thread under a
  per-frame budget, or in a background `Thread` if pool headroom allows — §6.7), exact
  consistency with the near surface (§6.4), full control of the seam (DH-style overlap band),
  biome colours straight from `column_profile` + `BlockCatalog.color_of`, trivially fits
  Compatibility/WebGL2 (opaque vertex-coloured triangles), memory ~10–20 MB (§6.6), and the
  whole thing is testable headlessly in `verify_feature.gd` (assert far-field height ==
  `height_at` at sample points).
* **Cons**: new code to own (streaming, ring rebuild, eviction); distant terrain is smooth
  and untextured (accepted by the DH precedent, §4); no distant trees (mitigate with biome
  tinting; tree impostors are future work); one more thing the main thread does (budgeted).

### 5.4 Option D — Terrain3D or HTerrain as the far field

* **[Terrain3D](https://github.com/TokisanGames/Terrain3D)** (Tokisan): GPU-driven
  **geometry clipmap** renderer; "The OpenGLES 3.0 Compatibility renderer is fully supported
  since Terrain3D 1.0 and Godot 4.4"; web builds exist but "web exports are very
  experimental" ([platforms doc](https://terrain3d.readthedocs.io/en/latest/docs/platforms.html),
  [GPU-driven workflow post](https://tokisan.com/terrain3d-gpu-driven-workflow/),
  [HTML5 issue #502](https://github.com/TokisanGames/Terrain3D/issues/502)). A practitioner
  got it running in-browser only after recompiling Godot, hand-integrating the WASM
  GDExtension, and patching shaders (integer samplers unsupported on the web renderer →
  `floatBitsToUint` workaround; `fma()` removal; precision qualifiers)
  ([Westhoff writeup](https://johnwesthoff.com/projects/godot-web-terrain3d/)).
  For us it is a **GDExtension** — our web template is a custom engine build, so we'd either
  vendor it as a module or ship dlink-enabled templates; its region-based storage would need
  to be *filled at runtime* from `height_at` (supported via its API, but it's an
  editor-centric data model). Verdict: heavyweight integration risk for a far field we can
  mesh ourselves in a few hundred lines; its clipmap shader lessons are more valuable than
  the dependency.
* **[HTerrain](https://github.com/Zylann/godot_heightmap_plugin)** (Zylann, pure GDScript,
  chunked quadtree LOD): explicitly **not in active development** ("no longer works on
  features … only bug fixes"), Godot 4 port exists; data model is editor-authored images with
  bounded size. Runtime-driving it from an analytic function is possible but fights its
  design. Verdict: useful as *reference code* for chunked-LOD GDScript (it is exactly the
  Ulrich pattern in our engine's language), not as a dependency.

### 5.5 Option E — Full Distant-Horizons-style voxel aggregation

Aggregate real voxel columns (including edits and trees) into stored LOD levels, mesh them
per level, quadtree-select. This is what you build when the world is *not* analytically
generable — edit-heavy, cave-riddled, or server-fed. VOXIVERSE's far field is a pure function
of the seed today; buying DH's machinery would be paying for a problem we don't have.
**Revisit only if/when** the engine's long-term vision (persistent large-scale edits, voxel
state machines visibly changing distant terrain) makes the far field genuinely
data-dependent. The piece to adopt *now* is DH's seam strategy (overlap + fog), which §6.5
does.

### Summary matrix

| | A1 replace w/ LodTerrain (blocky) | A2 LodTerrain far (blocky) | B LodTerrain far (Transvoxel) | **C custom analytic (rec.)** | D Terrain3D/HTerrain | E DH-style |
|---|---|---|---|---|---|---|
| Web/Compat feasible | yes (risky) | yes | yes | **yes** | experimental | yes |
| Voxel-worker load added | reshapes all | high | high | **none** | none | mid (own pool) |
| Near/far consistency | native | native | by construction | **by construction** | by construction | native |
| Seam quality | skirts (holes risk) | skirts + overlap | transition meshes | **overlap band + fog (DH pattern)** | overlap | overlap |
| Mountains as silhouettes | megablocks | megablocks | smooth | **smooth** | smooth | blocky-ish |
| Effort | large + risky | medium | medium-large | **small-medium** | large (integration) | large |
| New memory (web) | ~near-field scale | tens of MB | tens of MB | **~10–20 MB** | ~tens of MB | tens of MB |

---

## 6. Recommended architecture: the analytic far field, in detail

### 6.1 Structure

A new `FarField` (Node3D) sibling of the voxel world inside `WorldManager`, owning a set of
**far chunks**: square heightmap tiles, each one `MeshInstance3D` + runtime `ArrayMesh`,
built purely from `TerrainConfig.column_profile` (rule 2 compliant: it reads the sim-layer
functions, never geometry). Ring layout (numbers are a starting point, to be tuned in the
spike):

| Band (blocks from player) | Cell size | Chunk size | ~chunks | ~quads/chunk |
|---|---|---|---|---|
| 192 – 512 (overlap + first ring) | 4 m | 256 m | ~28 | 64² = 4,096 |
| 512 – 1,024 | 8 m | 512 m | ~9 | 64² |
| 1,024 – 2,048 | 16 m | 512 m | ~30 | 32² = 1,024 |
| 2,048 – 3,072 | 32 m | 1,024 m | ~12 | 32² |

Plus one **sea disc**: a flat translucent-ish plane at `SEA_LEVEL + WATER_SURFACE_HEIGHT`
(0.9375, `terrain_config.gd` line 54) spanning the far field, drawn under the terrain tiles
(ocean floor tiles render beneath it exactly as the voxel sea does). Distant water is then a
colour match for near water by construction.

Each vertex: position (`y = height_at`-derived, see 6.4), normal (finite differences of the
same samples), colour (biome → colour via a small far-palette table keyed off
`column_profile.y`/altitude — grass/forest/taiga tints, sand, stone above the badlands line,
snow above the freeze line on the mountains branch). One shared `StandardMaterial3D` with
`vertex_color_use_as_albedo = true` — the same idiom `block_materials.gd` already uses —
so the far field inherits scene lighting and fog automatically.

### 6.2 LOD selection & transitions

Plain chunked LOD (Ulrich, §3): chunk level fixed by band; when the player crosses a
half-chunk hysteresis boundary, re-band affected chunks (rebuild at the other resolution,
swap; `visibility_range` `Disabled`-mode hysteresis for scheduling, no alpha fades — §2.5).
Cracks between adjacent bands: **skirts** (one extra vertex row extruded ~2–4 m downward on
each chunk edge — the DH/Ulrich answer; at ≥500 m under haze this is invisible and it removes
the need for cross-band index stitching). Optional Phase-3 upgrade: CDLOD-style vertex morph
in a custom shader if band swaps ever pop visibly.

### 6.3 The generation split (the user's "coarse world-gen")

The far field **is** coarse world-gen: `column_profile(x,z)` at stride 4–32. No voxels, no
`resolve_cell`, no trees, no ores, no smoothing stencil — per far-vertex cost is one profile
(≈7 FastNoiseLite 2D evals + spline; the mountains branch adds one mask noise). There is no
second generator to keep in sync; the split is purely a *sampling-density* split of one
function. That is the property every other engine has to engineer (DH aggregates real chunks
to get it) and we get for free — the strongest single argument for Option C.

What the far field deliberately drops (and why it's safe): **player edits** (invisible at
≥192 m: a dug pit subtends <0.3°), **trees** (compensated by biome tint; canopy height ≈ +6 m
is sub-cell at 16–32 m cells anyway), **block textures** (DH precedent, §4), **ice sheet
edges/liquid detail** (the sea disc + cold-biome white tint reads correctly at distance).

### 6.4 The seam, analysed

Both layers derive from `height_at`, so the *only* mismatches at the handoff are:

1. **Smoothing offset**: the voxel walk surface is `height_at + 1` reshaped by corner
   modifiers within ±1 block (`_corner_targets`/`_modifier_from_targets`,
   `terrain_config.gd` §8.1 comments). Far vertices should target the *walk surface*
   (`height_at(x,z) + 1` averaged like `_corner_targets` does at coarse stride — i.e. sample
   the same quantity the smoothed voxel surface approximates), leaving a residual of at most
   ~1 block. At the 192–256 m overlap band, 1 m of vertical error subtends ≤0.3° — under fog,
   negligible.
2. **Sampling aliasing**: a 4 m cell can miss a 1-cell noise bump (detail amplitude is only
   ±1 block; hills ±3). Worst-case silhouette error at the seam ≈ 2–3 blocks — same order as
   the fog-washed contrast there.
3. **Trees**: near field has them, far field doesn't. The overlap band (where full-detail
   trees exist in front of the coarse mesh) makes this a gradual density falloff rather than
   a line.

**Z-order at the seam**: bias the entire far field **down by ~1.5 blocks** (DH's
overdraw-prevention role): inside the overlap band the voxel terrain always wins depth
naturally (its surface is ≥1 m above the far mesh), no z-fighting, and the ragged vertical
edge of the last streamed voxel chunks is backed by far-mesh ground immediately behind and
below it instead of sky. Far chunks fully inside `RENDER_RADIUS_BLOCKS − 64` are simply not
built (fill-rate + memory savings; the player can never see them).

### 6.5 Fog retuning (the wall becomes a haze)

Today `fog_depth_end ≈ 243` deliberately occludes the world edge (`main.gd` lines 76–84).
With a far field this inverts: fog must *reveal* 3 km while still softening both the seam
band and the new far edge. Plan: keep `FOG_MODE_DEPTH`, `begin ≈ 120` (unchanged near feel),
`end ≈ 0.9 × R_far ≈ 2,750`, `fog_depth_curve` tuned so the 192–512 m seam band sits at
~35–50% fog opacity (enough to wash the 1-block seam residuals and the tree falloff), fully
opaque before the far-field rim. `fog_sky_affect = 0` stays. Since Godot's depth fog applies
identically to voxel meshes and far meshes, the two layers converge to the same colour with
distance automatically — the luminance-matching problem DH shaders wrestle with is solved by
using the *same* fog in the *same* renderer. Risk to test on real hardware: Compatibility
fog banding at low colour precision over a 3 km gradient
([known Compatibility precision limitation](https://docs.godotengine.org/en/4.4/tutorials/3d/3d_rendering_limitations.html)).

### 6.6 Budget math (web, WebGL2)

From the table in 6.1: ≈ 28·4,096 + 9·4,096 + 30·1,024 + 12·1,024 ≈ **194 k quads ≈ 390 k
triangles** worst case (flat-shared vertices ≈ 200–250 k). At 32 B/vertex (pos + normal +
colour) + 6 B/index ≈ **9–14 MB GPU + a transient CPU copy** — small next to the voxel
meshes already resident. Draw calls: ~**80 far chunks + 1 sea disc**, on top of the current
~200–500 near-field draws that `mesh_block_size=32` was chosen to keep in check
(`module_world.gd` lines 156–166) — comfortably within the ANGLE/D3D11 draw-call envelope
that comment documents. Fill rate: the far field is mostly *behind* near terrain or fog-lit
ground; the down-bias + skip-inner-chunks rule (6.4) prevents systematic double-shading of
the near ground. Frame cost estimate: <1 ms GPU on the Intel-HD-class baseline, dominated by
the existing near field.

Build cost: ~250 k `column_profile` calls for a full field. At ~2–4 µs/call in WASM
(measured order from the smoothing-memo comments in `terrain_config.gd`, which record a
single `height_at` stencil at µs scale), that is **0.5–1 s of CPU total** — amortized over
initial load (build coarse→fine: the 32 m ring is ~12 k profiles ≈ 40 ms, so a full horizon
appears almost immediately and refines inward) and over movement (re-banding touches a few
chunks at a time). Main-thread slices of ≤3 ms/frame keep 60 FPS; the profile pass is
read-only over `TerrainConfig`'s warmed noise singletons (`warm_up()` already guarantees
main-thread-safe access, `terrain_config.gd` line 257).

### 6.7 Threading honesty

The threaded web export *does* allow GDScript `Thread`s, but the Emscripten pthread pool is
fixed at export and already sized for the voxel worker + engine threads
(`project.godot` comments, lines 52–65). Phase 1 should therefore build far chunks on the
**main thread under a time budget** (proven pattern: the mesh-apply budget
`voxel/threads/main/time_budget_ms=4` referenced in `module_world.gd` line 163). If profiling
demands it, Phase 3 can evaluate one dedicated far-field `Thread` **with a pool-size bump in
the export template** — an engine-build change, so it must ride `scripts/build.sh` and be
verified against the deadlock failure mode the header of `module_world.gd` documents.

---

## 7. Phased plan

**Phase 0 — Spike (1–2 days).** Hard-code a static far field around spawn on the
mountains branch (`feat/voxiverse-multi-liquid`): build the 4 rings once at load on the main
thread, flat far-palette colours, down-bias 1.5, retuned fog. Deploy to the live site
behind a query flag. **Exit criteria**: 60 FPS held on a desktop browser (Intel-HD-class),
load-time regression <1.5 s, mountains visible at 2–3 km, seam judged acceptable in
screenshots. This de-risks the two genuine unknowns (fog banding, fill-rate/draw-call
headroom) for almost no code.

**Phase 1 — Streaming far field (3–5 days).** `FarField` manager: chunk keying, banding +
hysteresis, budgeted incremental builds (coarse→fine priority), eviction, skip-inner rule,
sea disc, skirts. `verify_feature.gd` additions: far-vertex height == walk-surface within
1 block at sampled points; band coverage complete for a simulated player path; determinism
(same SEED ⇒ identical far meshes).

**Phase 2 — Visual integration (2–4 days).** Far palette from `BlockCatalog.color_of` +
altitude rules (snow line, stone line) matched against the mountains branch; forest/taiga
canopy tinting; fog curve tuning on real hardware; overlap-band width tuning; screenshot
A/Bs at the seam.

**Phase 3 — Optional upgrades (evaluate, don't commit).** (a) CDLOD-style vertex morph
shader if band swaps pop; (b) a `VoxelLodTerrain`-blocky **mid-field** spike (LOD1–2,
256–768 blocks) to keep megablock aesthetics at middle distance — measure single-worker
contention before adopting (§5.1); (c) background-thread builds with a pthread-pool bump
(§6.7); (d) distant tree impostors (MultiMesh billboards seeded from `TreeGen`'s
deterministic lattice).

**Top risks**: fog/colour banding over 3 km in Compatibility (Phase 0 tests it); draw-call
headroom on ANGLE→D3D11 (Phase 0); seam readability in motion (worst when flying/looking
down the boundary — Phase 2 tuning); main-thread build stutter on slow machines (budgeted
builds + coarse-first ordering); scope creep toward Option E machinery (resist until edits
matter at distance).

---

## 8. Open questions

1. **Walk-surface vs solid-surface targeting** at coarse strides: is averaging
   `height_at + 1` over the cell (mimicking `_corner_targets`) visibly better at the seam
   than point-sampling? (Phase 1 experiment; cheap to A/B.)
2. **How far is "a few thousand"?** 3,072 assumed here; 4–6 k costs only more 32 m ring
   area (linear-ish in chunks) — find the fog-composition sweet spot empirically.
3. **Mountains-branch merge timing**: the far field's wow-factor depends on
   `feat/voxiverse-multi-liquid` landing; on `main` (max surface y=24) the horizon is
   coastlines only. Sequence the work accordingly.
4. **Does the blocky mid-field (Phase 3b) read better than smooth at 256–768 blocks?**
   Aesthetic call needing a real build; also the first real-world test of v1.4.1 blocky LOD
   for us.
5. **Future edits-at-distance** (long-term engine spec: persistent physical objects,
   material state machines): at what point does the far field need a DH-style dirty-region
   overlay (re-mesh far chunks whose columns were edited)? The chunk keying in Phase 1
   should leave a hook for per-chunk invalidation so this stays a bolt-on.
6. **Fallback path parity**: the GDScript fallback (`world/fallback/`) is desktop-only in
   practice; does the far field need to work there too? (It reads only `TerrainConfig`, so
   it should be path-agnostic for free — verify in headless.)

---

## 9. Annotated sources

**godot_voxel (authoritative for module capabilities)**
- [Changelog](https://voxel-tools.readthedocs.io/en/latest/changelog/) — the v1.4 blocky-LOD entry ("meshes scale with LOD … extra geometry to reduce cracks", skirts toggle); confirms v1.4.1 (29/03/2025) contains it; latest release 1.6 (02/2026).
- [VoxelLodTerrain API](https://voxel-tools.readthedocs.io/en/latest/api/VoxelLodTerrain/) — octree LOD, `lod_count`/`lod_distance`/`view_distance`, "preferably used with smooth meshing", blocky second-class statement.
- [VoxelTerrain API](https://voxel-tools.readthedocs.io/en/latest/api/VoxelTerrain/) — "constant level of detail", the internal 512 `max_view_distance` cap.
- [Smooth terrain / LOD docs](https://voxel-tools.readthedocs.io/en/latest/smooth_terrain/) — Transvoxel transition meshes, `CUSTOM0`/`u_transition_mask` shader protocol, LOD fading, detail-normalmap system (GPU path Vulkan-only), octree vs clipbox streaming, edit-at-LOD0 limitation.
- [generators.md](https://github.com/Zylann/godot_voxel/blob/master/doc/source/generators.md) — the `lod` parameter as `2^lod` sampling stride.
- [Issue #63](https://github.com/Zylann/godot_voxel/issues/63) — skirts occasionally leave holes between LOD borders.
- [Issue #287](https://github.com/Zylann/godot_voxel/issues/287) — two terrain nodes: rendering works, module collisions break on the second node (moot for us: `generate_collisions=false`).

**Distant Horizons (the canonical near/far voxel hybrid)**
- [CurseForge page](https://www.curseforge.com/minecraft/mc-mods/distant-horizons) and [CurseForge FAQ](https://blog.curseforge.com/distant-horizons-frequently-asked-questions/) — LOD system overview, client-side generation, persistence, CPU-bound building.
- [Overdraw-prevention explanation](https://www.answeroverflow.com/m/1392143133000728659) — the overlap-with-vanilla-terrain seam strategy adopted in §6.4/§6.5.
- [GitLab repository](https://gitlab.com/distant-horizons-team/distant-horizons) — source of truth for its quadtree/threadpool architecture.

**Godot 4.4 platform constraints**
- [Exporting for the Web](https://docs.godotengine.org/en/4.4/tutorials/export/exporting_for_web.html) — WebGL2/Compatibility only ("Forward+/Mobile are not supported on the web platform"), SharedArrayBuffer + COOP/COEP for threads.
- [Godot forum: Compatibility has no compute shaders / RenderingDevice](https://forum.godotengine.org/t/compatibility-mode-doesnt-support-compute-shaders-nor-dynamic-buffers/110002) and [renderer comparison](https://slicker.me/godot/renderers.html) — no compute, WebGL2 shader restrictions.
- [Visibility ranges](https://docs.godotengine.org/en/4.4/tutorials/3d/visibility_ranges.html) — begin/end/margins, hysteresis vs alpha-fade modes (fades force the transparent pass).
- [Occlusion culling](https://docs.godotengine.org/en/4.4/tutorials/3d/occlusion_culling.html) — Embree CPU raster, baked occluders, BVH-rebuild cost for moving occluders.
- [3D rendering limitations](https://docs.godotengine.org/en/4.4/tutorials/3d/3d_rendering_limitations.html) — Compatibility colour precision (fog-banding risk).
- [HeightMapShape3D](https://docs.godotengine.org/en/stable/classes/class_heightmapshape3d.html) — collision-only; Godot 4 has no terrain node (also stated in Zylann's plugin README below).

**Terrain plugins**
- [Terrain3D](https://github.com/TokisanGames/Terrain3D), [platforms doc](https://terrain3d.readthedocs.io/en/latest/docs/platforms.html) ("Compatibility … fully supported since Terrain3D 1.0 and Godot 4.4"; "web exports are very experimental"), [GPU-driven clipmap post](https://tokisan.com/terrain3d-gpu-driven-workflow/), [HTML5/WebGL issue #502](https://github.com/TokisanGames/Terrain3D/issues/502).
- [Terrain3D in the browser (Westhoff)](https://johnwesthoff.com/projects/godot-web-terrain3d/) — practical WebGL2 shader fixes (integer samplers, `fma`, precision) and GDExtension-on-web pain; required reading before any web terrain shader work.
- [HTerrain / godot_heightmap_plugin](https://github.com/Zylann/godot_heightmap_plugin) — GDScript chunked-quadtree LOD reference implementation; maintenance-mode status; "Godot has no terrain system for 3D at the moment".

**Classic techniques**
- [Losasso & Hoppe, *Geometry Clipmaps* (SIGGRAPH 2004)](https://hoppe.cs.washington.edu/geomclipmap.pdf) and [GPU Gems 2 ch. 2 (GPU clipmaps)](https://developer.nvidia.com/gpugems/gpugems2/part-i-geometric-complexity/chapter-2-terrain-rendering-using-gpu-based-geometry).
- [Strugar, *CDLOD* (2009)](https://github.com/fstrugar/CDLOD) — quadtree + vertex morphing; the popping-free transition technique compatible with WebGL2.
- [Ulrich, *Chunked LOD* (2002)](http://tulrich.com/geekstuff/chunklod.html) — static per-chunk meshes + skirts; the pattern Phase 1 implements.

**VOXIVERSE code references (all paths repo-relative)**
- `godot/src/world/voxel_module/module_world.gd` — near path setup (view distance 256, `mesh_block_size=32` draw-call rationale, `generate_collisions=false`), web thread cap header, generator `lod != 0` early-out, frozen ARID manifest, `area_meshed` prewarm gate.
- `godot/src/world/terrain_config.gd` — `height_at`/`column_profile`/`resolve_cell`, smoothing corner stencil, `RENDER_RADIUS_BLOCKS`, `MAX_SURFACE_Y`, heightmap-only decision; mountains constants on `feat/voxiverse-multi-liquid`.
- `godot/src/main.gd` `_setup_environment()` — the current fog wall (begin ≈115, end ≈243).
- `godot/project.godot` — GL Compatibility lock; `voxel/threads/count/*` web pool sizing.
- `docker/engine/versions.env` — Godot 4.4.1-stable + godot_voxel v1.4.1 + emsdk 3.1.64 pins.
