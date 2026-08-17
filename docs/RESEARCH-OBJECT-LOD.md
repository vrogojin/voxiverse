# RESEARCH — Object LOD Ladders & Auto-Cull for Discrete Physical Objects

**Scope**: how VOXIVERSE should render discrete physical objects — loose `VoxelBody` debris
(1–30 blocks), and future space objects (ships, stations, asteroids, 10s–1000s of blocks) — at
any distance, with an automatic LOD ladder, an automatic cull decision, and support for LIVE
(moving) transforms, on Godot 4.4.1 gl_compatibility / WebGL2 threaded WASM.

**Status**: research report + recommended design (pre-implementation). Adversarial review expected.

---

## 0. Executive summary

1. **The industry-standard LOD/cull metric is angular size in device pixels**, not distance.
   Every serious system (Unity LODGroup, UE screen-size, CesiumJS/3D-Tiles SSE, and VOXIVERSE's
   own shipped `BodyLod`) reduces to the same projected-sphere formula:

   ```
   K_px      = viewport_height_device_px / (2 · tan(fov_vertical / 2))    # px per radian
   p(r, d)   = 2·r / d · K_px                                             # object disc in px
   sse(e, d) = e / d · K_px                                               # error of a coarser rep, in px
   ```

   VOXIVERSE **already ships this law** for planetary bodies in
   `godot/src/cosmos/body_lod.gd:96-113` (`k_px` / `ang_px` / `relief_px`, thresholds
   `P_POINT = 2 px`, `TAU_POP = 1 px`, one-sided-sticky ±25 % hysteresis). The recommendation is
   to **generalize that exact law to discrete objects**, not to invent a second metric.

2. **LOD selection should be SSE-driven, not band-driven**: a representation whose geometric
   error is `e` blocks (e.g. a decimation coarse-pitch, or an impostor's silhouette error) is
   acceptable exactly while `e/d · K_px ≤ τ` (τ ≈ 1 px). This single rule automatically gives
   per-object switch distances proportional to object size — a 1-block chip drops to a card at
   ~30 blocks, a 100-block station holds full mesh to kilometres — with **no per-object tuning**.

3. **The ladder** (by object size class): full exposed-face voxel mesh → OR-occupancy decimated
   mesh (`StructDecimator`, already shipped) → batched card impostor (the far-tree cross-card
   pattern, already shipped) → **unlit dot** (point tier). Small debris skips the middle rungs
   (its first coarse pitch is already sub-τ at trivial distance); big space objects get the full
   ladder. Space objects are **never hard-culled** — they clamp into the dot tier and dither-fade
   only below ~0.5 px, exactly how stars/beacons are handled in space games.

4. **Moving objects are batched by tier**: awake bodies write their MultiMesh transform each
   frame (cheap: tens of floats); dormant/sleeping bodies are **snapshotted** into a static
   buffer and cost zero per frame — this piggybacks on the dormancy machinery `VoxelBody`
   already has (`is_awake()`, freeze/sleep, `godot/src/physics/voxel_body.gd:407`).

5. **Never-OOM** stays structural: a byte ledger + hard instance caps + a priority queue keyed
   by projected pixels (largest first), mirroring `FAR_TREES_BYTES_MAX` / `STRUCT_BYTES_MAX` /
   `BodyLod.far_tier_bytes` discipline. Proposed master flag: **`FP_OBJ_LOD`**, staged P0–P4,
   default-off, byte-identical off, FLAT gate stays 6042/0.

---

## 1. What VOXIVERSE already has (read before theorizing)

The engine already contains four of the five building blocks; the missing piece is the glue for
*discrete, moving* objects.

| Asset | File | What it gives us |
|---|---|---|
| **Angular-size selection law** | `godot/src/cosmos/body_lod.gd` | `k_px/ang_px/relief_px`, tier ladder POINT→IMPOSTOR→RING, `P_POINT=2px`, `TAU_POP=1px`, one-sided ±25 % hysteresis (`tier_hyst`), sub-pixel no-pop bookkeeping (G-SSE-INV), byte-ledger accounting. Pure statics, engine-free, gate-tested. |
| **Voxel→coarse decimation** | `godot/src/world/struct_decimator.gd` | Power-of-two coarse pitch from max extent (`coarse_pitch`, target res `STRUCT_TARGET_RES=16`), **OR-occupancy** (preserves 1-block walls; MIN would delete silhouettes), **majority-colour** per coarse cell, face-culled cube mesh with per-vertex `BlockCatalog` colours. Deterministic, sampler-driven. |
| **Card-impostor tier** | `godot/src/world/facet_far_trees.gd` | The proven 3-rung ladder (near voxel 0–128 → archetype MultiMesh 128–448 → cross+cap cards 448–2400 → fine-map texel), CPU-rasterised card atlas, ONE MultiMesh draw, dither-discard fades (no alpha sort — gl_compat safe), hash-survival thinning, rebuild-on-change delta gate, near-presence handoff cull, 4 MB ledger + 8192-instance cap. |
| **Unique-geometry far models** | `godot/src/world/facet_far_structures.gd` + `structure_tracker.gd` | Merged ArrayMesh per band for *unique static* geometry, per-structure bake cache keyed (root, rev), tri cap 80 k, 8 MB ceiling, union-find registry with revision counters. |
| **The object itself** | `godot/src/physics/voxel_body.gd` | `cells: Vector3i→id`, exposed-face mesh (one surface per material), per-cell box colliders (single AABB above `TREEPHYS_COLLIDER_CAP=64` cells), full dormancy model (frozen ground bodies, sleeping wood, `is_awake()`), connected-component splitting on break. Spawned by `WorldManager._collapse_unsupported()` and tree chops. |

What is *missing*: `VoxelBody` renders its full mesh at **every** distance and is only ever
removed by `queue_free()`; nothing decimates it, nothing culls it by angular size, and there is
no far representation that can follow a live `RigidBody3D` transform. Future ships/stations have
no rendering story at all beyond `CAMERA_FAR = 9000` (`godot/src/world/facet_far_ring.gd:30`).

Also relevant, hard-won project law (memory + docs):

- gl_compat MultiMesh needs **both** `use_colors` and `use_custom_data` or the colour slot
  aliases custom data ([[voxiverse-far-trees-colorfix]], PR #55) — stride 20, COLOR written white.
- `INSTANCE_CUSTOM` is **f16 on web** — never pack precision-critical data there.
- `set_instance_transform` is a **NO-OP after `set_buffer`** on a MultiMesh
  ([[voxiverse-fartree-polish132]]) — pick ONE write API per buffer and stay with it.
- `discard` kills early-Z *write* only — count draws before believing a fill theory
  ([[voxiverse-near-leaf-cutout]]).
- Never size anything off `OS.get_processor_count()` on web; memory safety outranks visuals
  ([[voxiverse-never-oom-web]]).

---

## 2. State of the art

### 2.1 Screen-space / angular-size LOD selection and culling (Q1)

**The projected-pixel formula.** For a bounding sphere of radius `r` at eye distance `d`, with
vertical FOV `θ` and viewport height `H` device pixels, the projected disc diameter is

```
p = 2·r / d · H / (2·tan(θ/2))        (small-angle; exact form uses atan, irrelevant beyond ~20°)
```

- **Unity LODGroup** exposes exactly this as `screenRelativeTransitionHeight` — "the ratio of
  the GameObject's screen space height to the total screen height", computed from the LODGroup's
  bounding volume ([Unity manual](https://docs.unity3d.com/560/Documentation/Manual/class-LODGroup.html),
  [scripting API](https://docs.unity3d.com/ScriptReference/LOD-screenRelativeTransitionHeight.html)).
  Typical authored thresholds: LOD0 down to ~50–60 % screen height, LOD1 to ~25–30 %, LOD2 to
  ~10 %, cull below ~1–2 % (small props) — i.e. roughly a **halving of screen size per step**.
- **Unreal Engine** LOD/HLOD "screen size" is "based around the projected diameter of the
  bounding sphere of the model" — the same `r·H/(2·d·tan(θ/2))` projected-sphere radius —
  which is why "a skyscraper and a teacup can both transition at 5 % of screen height"
  ([UE per-platform LOD screen size](https://dev.epicgames.com/documentation/unreal-engine/optimizing-lod-screen-size-per-platform-in-unreal-engine),
  [ibbles' UE LOD notes](https://github.com/ibbles/LearningUnreal/blob/main/Mesh%20LOD.md),
  [Moonjump LOD mechanics](https://moonjump.com/game-dev-mechanics-level-of-detail-lod-how-it-works/)).
  Nanite generalizes the same idea to per-cluster screen-space error with sub-pixel targets.
- **CesiumJS / 3D-Tiles** make the *error* the first-class quantity: every tile carries a
  `geometricError` `e` (metres of error if this tile renders instead of its children), and the
  runtime computes **SSE = e·H / (d·2·tan(θ/2))** — "roughly the number of pixels wide a sphere
  of radius `e` would be drawn at the tile's position" — refining while SSE >
  `maximumScreenSpaceError` (CesiumJS default **16 px**; quality-first clients use 1–8)
  ([3D-Tiles spec](https://github.com/CesiumGS/3d-tiles/blob/main/specification/README.adoc),
  [Cesium3DTileset docs](https://cesium.com/downloads/cesiumjs/releases/1.38/Build/Documentation/Cesium3DTileset.html),
  [cesium-native selection algorithm](https://cesium.com/learn/cesium-native/ref-doc/selection-algorithm-details.html),
  [community explanation](https://community.cesium.com/t/understanding-geometric-error/8480/2)).
- The academic grounding is Luebke et al., *Level of Detail for 3D Graphics* (2002): LOD
  selection should minimize perceptible screen-space error under a budget; distance-based bands
  are just the fixed-FOV special case.

**Key insight**: `ang_px` (object size) drives *culling*; `sse` (representation error) drives
*selection*. VOXIVERSE's `BodyLod` already implements both: `ang_px` vs `P_POINT` and
`relief_px` vs `TAU_POP` — `e_relief` *is* a `geometricError`. 3D-Tiles' 16 px default is far
looser than `BodyLod`'s 1 px because terrain tiles stream over a network; for locally-generated
representations 1 px (sub-pixel pops "by the law that triggers them") is affordable and is
already this project's proven convention.

**Sub-pixel objects / no-pop.** Industry practice for the "smaller than a pixel" regime:
- **Dither/cross-fade at transitions** — screen-door dissolve via `discard` against a Bayer/hash
  pattern; needs no alpha sorting, works on gl_compat
  ([Cesium for Unreal dithered LOD transitions](https://cesium.com/blog/2022/10/20/smoother-lod-transitions-in-cesium-for-unreal/)).
  VOXIVERSE's far-tree fade (`_CARD_TAIL_FADE`, `FADE_EPS=0.004`, `THIN_FADE`) is exactly this.
- **Point/dot tier** — below ~2 px a shaded model is indistinguishable from a bright dot;
  flight sims and space games render a constant-size (1–3 px) unlit quad whose *brightness*,
  not size, encodes distance (stars: magnitude ∝ 1/d²; clamped to avoid invisibility). KSP
  ships this as the "Distant Object Enhancement" pattern — sub-pixel vessels/planets drawn as
  brightness-attenuated flares ([DOE/L mod](https://www.curseforge.com/kerbal/ksp-mods/distant-object-enhancement-l)).
- **Fade-out cull** — never binary-remove a visible object: ramp the dot's opacity/brightness
  over the last octave of distance so the disappearance is below perceptual threshold.

### 2.2 Impostors / billboards for discrete objects (Q2)

- **Octahedral impostors** (Ryan Brucks/Fortnite-popularized; UE "Impostor Baker", Amplify
  Impostors, Godot port [wojtekpil/Godot-Octahedral-Impostors](https://github.com/wojtekpil/Godot-Octahedral-Impostors)):
  bake a grid of views (recommended 16×16 = 256 angles) into atlases (albedo + depth + normal,
  typically 2048², ~16–48 MB VRAM at full maps), blend the 3 nearest views at runtime.
  Excellent silhouette fidelity from *any* angle; costs a bake pass (viewport captures — on
  threaded-web Godot a real constraint), significant VRAM per unique object, and breaks down
  close-up (parallax) ([Amplify manual](https://wiki.amplify.pt/index.php?title=Unity_Products%3AAmplify_Impostors%2FManual),
  [Zucconi overview](https://www.alanzucconi.com/2018/08/25/shader-showcase-saturday-7/)).
- **Billboard clouds** (Décoret, Durand, Sillion, Dorsey, SIGGRAPH 2003): simplify a model onto
  a small set of textured, transparency-mapped planes chosen by an error-threshold optimization
  ([paper](https://dl.acm.org/doi/10.1145/1201775.882326), [INRIA page](https://inria.hal.science/inria-00510175)).
  The far-tree **cross+cap card** (2 vertical crossed quads + 1 horizontal cap) is the fixed
  3-plane billboard-cloud special case — ideal for roughly-isotropic objects.
- **When impostors beat decimated meshes**: below ~10–20 px projected size, a textured quad
  (2–6 tris) carries more perceived detail than any mesh you could afford, and unifies into one
  instanced draw. Above ~50 px, mesh LODs win (parallax, silhouette, lighting). The crossover
  is why every ladder ends mesh → impostor → dot rather than mesh → smaller mesh → nothing.
- **Cost model**: cross-cards à la far-trees: 32×32 texels × a few atlas tiles ≈ KBs, CPU-bakeable
  from voxel cells (no viewport). Octahedral: viewport bake, MBs per unique object. For *voxel*
  objects, CPU-rasterising cells into a tiny atlas (the shipped `FacetFarTrees` technique) gets
  90 % of the benefit at ~0.1 % of the VRAM, and works headless.

### 2.3 Automatic LOD count & thresholds from object size (Q3)

- **Simplygon's default pipeline is 50 %-50 %-50 %** triangle reduction per LOD level, with
  switch distance derived from the reduction's *max surface deviation* — i.e. from a measured
  geometric error, closing the loop with §2.1
  ([Simplygon reduction docs](https://documentation.simplygon.com/SimplygonSDK_10.0.1400.0/concepts/reduction.html),
  [LOD transitions from triangle ratio](https://www.simplygon.com/posts/fd30ea69-957c-4897-a7f4-821037deb81f),
  [switch distances in UE plugin](https://simplygon.com/posts/dd10914d-b7a4-4a78-9b3c-35eec441495d)).
- For voxel objects the deviation is *known analytically*: a decimation at coarse pitch `c`
  has max deviation `e ≈ c·√3/2` blocks (half a coarse cell diagonal); conservatively `e = c`.
  So the LOD count needs **no heuristic**: pitches are `c = 1, 2, 4, … ≤ extent/2` — an object
  of max extent `E` supports `floor(log2(E))` useful mesh steps, and each step's switch
  distance falls out of the SSE law (`d_i = c_i·K_px/τ`). A 2-block chip has zero useful mesh
  steps (c=2 is already the whole object → its "LOD1" is the card); a 512-block station has ~8.
- Doubling the screen-size band per step (halving detail when projected size halves) is the
  standard result of that law — it's what Unity's default LOD bars and SpeedTree's
  billboard-last ladders encode empirically.

### 2.4 Decimating a VOXEL object specifically (Q4)

Approaches, in increasing sophistication:

| Approach | What it is | Verdict for VOXIVERSE |
|---|---|---|
| **2× occupancy downsample + face-cull** | Coarse cell solid if any/most children solid; majority colour; greedy/face-culled cube mesh. The Minecraft-community "Distant Horizons" style, and `StructDecimator` verbatim ([voxel LOD threads](https://www.gamedev.net/forums/topic/679604-voxel-lod/), [cubical voxel LOD](https://www.gamedev.net/forums/topic/677008-lod-on-a-cubical-voxel-engine/5280976/)). | **Use it — already shipped & gate-tested.** OR-occupancy is the right polarity for thin walls/masts (proven in §6.1 of the structures design). |
| Greedy meshing at each pitch | Merge coplanar same-colour faces. | Marginal here: decimated objects are small grids (≤16³ coarse cells); the face-culled mesh is already tiny. Skip. |
| Surface nets / dual contouring at low res | Smooth iso-surface from coarse density. | Wrong aesthetic for blocky objects; loses the voxel silhouette (ships *should* look blocky). Skip. |
| Vertex clustering / QEM on the fine mesh | Classic mesh decimation (Garland-Heckbert). | Strictly worse than re-decimating the voxel grid, which is the ground-truth representation. Skip. |
| Per-cell colour → texture bake | Bake cell colours into a tiny per-object texture instead of vertex colours. | Only wins when coarse cells ≫ vertices; vertex colours (the `StructDecimator` output) are simpler and match far-structure rendering. Skip for meshes; cards already do this via the atlas. |

**"Few-block" objects decimate to nothing** — a 1–8 cell body's first coarse level is a single
cube. Their ladder is therefore just: full mesh → card (tinted majority colour) → dot. This is
the formal justification for giving debris a shorter ladder than ships (§3.2).

### 2.5 Space games: huge dynamic range, distant ships/stations (Q5)

Documented / widely-known practice:

- **KSP**: two coordinate worlds — near "local space" (metres, floating origin re-centred on the
  active vessel; Krakensbane subtracts orbital velocity) and **"ScaledSpace"** — a 1/6000-scale
  mirror of all celestial bodies rendered around a camera at scaled position, composited behind
  the near scene. Sub-pixel vessels/bodies become brightness-scaled flares (the DOE pattern,
  [mod page](https://www.curseforge.com/kerbal/ksp-mods/distant-object-enhancement-l)).
  VOXIVERSE's `FacetFarRing`+shell+`BodyLod` IMPOSTOR tier is precisely a scaled-space: the
  impostor is drawn at *exact angular size* at a renderable distance — "SEAMLESS-SCALES" law.
- **Elite Dangerous / Star Citizen**: 64-bit (or segmented-zone) world positions, camera-relative
  rendering for stability ("translate everything by −camera before transforms";
  [Unity HDRP camera-relative doc](https://github.com/shenzhou05/SRP-Chinese-Translation/blob/master/Pages/HDRP/Camera-Relative-Rendering-in-HDRP.md),
  [gamedev.net huge-distance thread](https://gamedev.net/forums/topic/660567-rendering-huge-space-distance-technique/)).
  Distant ships hold as glowing dots/hologram markers essentially forever — the *gameplay*
  requirement (target visibility) overrides pure perceptual culling; cull is replaced by
  "clamp to beacon". A community survey of scale handling across space games:
  [ResetEra thread](https://www.resetera.com/threads/the-ways-different-space-games-have-handled-traversal-and-scale.932520/).
- **Outer Wilds**: small real-scale system + aggressive floating origin; everything simulated,
  no scaled space — viable only because the system is ~50 km across.
- **Depth precision**: the classic fixes are logarithmic depth
  ([Ulrich's note](https://tulrich.com/geekstuff/log_depth_buffer.txt),
  [Outerra](https://outerra.blogspot.com/2009/08/logarithmic-z-buffer.html),
  [gamedeveloper.com](https://www.gamedeveloper.com/programming/logarithmic-depth-buffer)) or —
  strictly better where available — **reversed-Z with a float depth buffer**
  ([NVIDIA depth-precision article](https://developer.nvidia.com/blog/visualizing-depth-precision/),
  [Reed, Depth Precision Visualized](https://www.reedbeta.com/blog/depth-precision-visualized/)).
  **Godot gl_compatibility/WebGL2 offers neither** (no reversed-Z on the GL backend, no
  writable float depth): the far scene must instead avoid needing depth range — draw far
  objects at *clamped distance with angular-size-preserving scale* (the shipped impostor/shell
  approach), depth-sorted coarsely by tier, exactly as the sky and `FacetFarRing` already do.

### 2.6 Many MOVING far objects (Q6)

- **GPU instancing / MultiMesh** is the only draw-count-safe way to render hundreds of far
  objects on WebGL2; per-instance data rides in the instance buffer
  ([Godot MultiMesh optimization doc](https://docs.godotengine.org/en/stable/tutorials/performance/using_multimesh.html)).
  Caveats: one AABB for the whole MultiMesh (spatial coherence matters — fine for a
  camera-centred far tier with a pinned custom AABB, the far-tree convention), and the 4-float
  `INSTANCE_CUSTOM` cap ([proposal #8666](https://github.com/godotengine/godot-proposals/issues/8666)).
- **Transform update cost**: rewriting a MultiMesh buffer is O(instances) floats/frame on CPU +
  one upload. The standard mitigations: (a) **split static from dynamic** — sleeping bodies go
  in a rarely-rewritten buffer, awake ones in a small hot buffer; (b) **tier the update rate** —
  far/small objects update transforms at 5–10 Hz (their projected motion is sub-pixel between
  updates: a body moving `v` blocks/s at distance `d` moves `v·K_px/d` px/s on screen — update
  when accumulated screen motion ≥ ~0.5 px); (c) whole-buffer `set_buffer` writes, never
  per-instance calls mixed in (the project's own set_buffer/set_instance_transform trap).
- **Budgeting**: hard instance caps with **priority = projected pixels** (angular size), which
  is simultaneously the perceptual importance metric and the LOD driver — one sort serves both.
  Pool instances; degrade by demoting the smallest-`p` objects a tier, never by unbounded alloc.
  (This is the discrete-object analogue of `BodyLod.select_ring_bodies`' dominant-then-largest
  arbitration and the far-trees nearest-first cap.)

### 2.7 WebGL2 / gl_compatibility feasibility (Q7)

Feasible and proven **in this project**: MultiMesh instancing with colors+custom data (stride 20
pattern), alpha-scissor/dither discard (no sorted transparency), CPU-side atlas rasterisation,
per-frame uniform pushes (`sun_dir`, `planet_centre`), pinned custom AABBs, worker-thread bakes
via WorkerThreadPool.
Not available / to avoid: compute shaders and GPU-driven culling (no compute on WebGL2),
Nanite-style per-cluster streams, geometry shaders, reversed-Z / float depth (GL backend),
viewport-heavy octahedral bakes at runtime (viewport round-trips on threaded web are expensive
and the fine-grained readback stalls the pipeline), true point-sprite size control
(`gl_PointSize` unsupported through Godot's spatial shaders — use a camera-facing quad).

---

## 3. Comparison table (approaches for the far representation of a discrete object)

| Approach | Draw cost | Memory | Bake cost | Moving transform | Fidelity band | gl_compat/web | Verdict |
|---|---|---|---|---|---|---|---|
| Full voxel mesh always (status quo) | 1 draw/object, unbounded verts | mesh per object | none | free (RigidBody) | perfect | OK | fails at scale; no cull |
| Decimated pitch-2ᵏ mesh (`StructDecimator`) | 1 draw/object (unique geometry) | ~KB/object/level | ms-scale, CPU, worker-safe | free (MeshInstance under body) | 10–100 px | OK | **use for E ≥ 16 blocks** |
| Merged band ArrayMesh (far-structures style) | 1 draw/band | shared | rebuild on any change | **no** — merged verts can't follow per-object transforms | static only | OK | reject for movers; keep for static builds |
| Cross+cap card MultiMesh (far-trees style) | **1 draw/tier** | 16–32 B/inst + tiny atlas | CPU rasterise once/archetype or /object-rev | per-instance transform write | 2–20 px | **proven** | **use as impostor rung** |
| Octahedral impostor | 1 draw/object (or batched) | MBs/object | viewport bake | per-instance | 5–100 px | risky on web (bake) | defer; only for hero ships, offline-baked |
| Unlit dot quad MultiMesh | 1 draw for ALL dots | 16 B/inst | none | per-instance | < 2 px | trivial | **use as terminal rung** |
| Hard distance cull | 0 | 0 | none | n/a | n/a | n/a | reject for space objects (must stay visible); OK for debris with fade |

---

## 4. RECOMMENDED DESIGN — `FP_OBJ_LOD`

### 4.1 The law (P0): generalize `BodyLod` to `ObjectLod`

One new pure-static class `godot/src/cosmos/object_lod.gd` (engine-free, gate-tested like
`BodyLod` — same file discipline), sharing the primitives:

```
K_px        = H_device_px / (2·tan(fov/2))          # reuse BodyLod.k_px verbatim
p           = 2·r_obj / d · K_px                    # object disc in device px (r_obj = bounding-sphere radius, blocks)
sse(level)  = e_level / d · K_px                    # error of a candidate representation, px
```

with per-representation geometric errors (all in blocks, all derivable, no tuning):

| Rung | Representation | `e_level` |
|---|---|---|
| L0 | full exposed-face voxel mesh (today's `VoxelBody` mesh) | 0 |
| L1..Lk | `StructDecimator` mesh at pitch `c = 2, 4, …` | `c` |
| C | cross+cap card (majority-colour rasterised cells) | `r_obj / 2` (silhouette half-error of a 3-plane billboard cloud) |
| D | unlit dot quad (2–3 px, brightness ∝ clamp(p², …)) | `r_obj` (all shape gone) |

**Selection rule** (the Cesium/Simplygon law, matching `TAU_POP`):
pick the *coarsest* rung with `sse ≤ TAU_OBJ` where **`TAU_OBJ = 1.0 px`**; additionally force
D when `p < P_POINT = 2.0 px` (shape is invisible regardless of error — `BodyLod` reuse).
Equivalent switch distances, closed-form: `d_switch(level) = e_level · K_px / TAU_OBJ`.

Worked example (1080 px viewport, 75° FOV → `K_px ≈ 704 px/rad`):

| Object | r (blk) | mesh→pitch-2 at | →card at (p=2px ⇒ d=r·K_px) | →dot at | fades out at (p=0.5px) |
|---|---|---|---|---|---|
| 1-block chip | 0.87 | — (no useful pitch) | d ≈ 610 | d ≈ 610 (card ≡ dot band) | d ≈ 2 400 |
| 25-block canopy | 3 | d ≈ 1 400 (c=2) | d ≈ 2 100 | d ≈ 2 100 | d ≈ 8 400 → fog kills it first (FOG_BEGIN 2200) |
| 100-blk ship | 30 | 1 400 / 2 800 / 5 600 (c=2/4/8) | d ≈ 21 000 | d ≈ 21 000 | **never** (space object: clamp to dot) |
| 1000-blk station | 300 | c up to 64 → d ≈ 45 000 | d ≈ 211 000 | d ≈ 211 000 | **never** |

(Card and dot bands merge for blocky objects because a card's `e ≈ r/2` crosses τ at ~the same
distance `p` crosses `P_POINT·2` — the card rung earns its keep in the 2–20 px window where it
replaces a *decimated mesh draw per object* with *one instanced draw per scene*.)

**Hysteresis**: reuse the `tier_hyst` one-sided-sticky pattern verbatim — promote (toward
detail) at nominal threshold, demote only past ±25 % (`HYST = 0.25`), caller latches. No
cross-fades needed at mesh↔mesh swaps (sub-pixel by the law); card↔dot and the final fade use
the far-tree dither-discard (`FADE` custom float), never alpha blending.

**Cull law** — two object classes, declared at spawn:
- `CLASS_DEBRIS` (VoxelBody chips/canopies): dither-fade over `p ∈ [0.5, 1.0] px`, release the
  far instance at `p < P_CULL_DEBRIS = 0.5 px` (`d_cull = 2·r·K_px/0.5 = 4·r·K_px`). In practice
  fog (2200) and the despawn/dormancy story bound debris first; the formula is the backstop.
- `CLASS_SPACE` (ships, stations, asteroids, beacon-tagged anything): **no cull**. Below
  `P_POINT` the dot clamps to 2 px and brightness attenuates `∝ p²` down to a floor
  (`DOT_MIN_LUMA`), exactly the KSP-DOE/Elite beacon pattern; an optional per-object
  `beacon=false` allows asteroids-field-noise to use the debris fade instead. Far placement
  uses **clamped-distance, angular-size-preserving** positioning (unit direction ×
  `OBJ_FAR_CLAMP_D`, scale × `d_true/OBJ_FAR_CLAMP_D`) — the shipped sky-impostor technique —
  so gl_compat depth precision never enters (no log-depth on WebGL2, §2.5/§2.7).

### 4.2 The render stack (what draws what)

```
ObjectLodTier (Node3D child of FacetFarRing, sibling of FacetFarTrees — same step/sun/centre plumbing)
 ├─ per-object MeshInstance3D            L1..Lk decimated meshes — only objects with p ≥ ~20 px
 │    (swapped under the body's OWN transform: rigid-body motion is free; expected count ≤ 16)
 ├─ MultiMeshInstance3D "cards"          rung C, ONE draw: stride-20 buffer (12 xform + 4 COLOR(white) + 4 CUSTOM),
 │    CUSTOM = [atlas_col, hue_jitter, fade, spare]; atlas CPU-rasterised per object-rev (LRU) or per archetype
 └─ MultiMeshInstance3D "dots"           rung D, ONE draw: camera-facing unit quad, CUSTOM = [luma, fade, class, spare]
```

- **L0** stays what it is today — `VoxelBody`'s own mesh; the tier merely *hides* it
  (`mi.visible = false`) past the L0→L1 switch and shows the decimated stand-in. Physics is
  untouched (colliders/dormancy unchanged — physics already has its own LOD via
  `TREEPHYS_COLLIDER_CAP` and dormancy).
- **Registry**: a lightweight `ObjectRegistry` on WorldManager — `{id → {node_ref, r_obj, class,
  rev, latched_tier}}`. VoxelBody registers on spawn (`spawn_loose`/`_spawn_detached`),
  deregisters on `queue_free`; `rev` bumps on `_rebuild()` (break/add_cell) so bake caches
  invalidate exactly like far-structures' `(root, rev)` law. Ships/stations later register
  through the same interface — **one registry, one law** (mirror of "block_id_at is THE query").
- **Transforms**: each step, awake bodies (`is_awake()`) in card/dot rungs get their row of the
  MultiMesh buffer rewritten from `body.transform`; **dormant bodies are snapshotted** — their
  row is written once at freeze/sleep and skipped thereafter (the dormancy flag is already
  authoritative). Update pacing: rows whose accumulated screen-space motion `Δx·K_px/d < 0.5 px`
  since last write are skipped (per-row lazy write); full `set_buffer` upload only when ≥ 1 row
  changed (never mix in `set_instance_transform` — the known trap).
- **Delta discipline**: rebuild-on-change gate à la `FP_FAR_TREES_DELTA` — inputs are (camera
  moved > τ·d for the nearest tracked object, registry rev-sum, latched-tier set); a still
  scene with sleeping debris costs zero.

### 4.3 Never-OOM budget

```
OBJ_LOD_BYTES_MAX   := 4 << 20     # hard ledger: decimation bakes + card atlas + both MultiMesh buffers
OBJ_MESH_MAX        := 16          # simultaneous decimated-mesh objects (p ≥ ~20 px is self-limiting; cap is the guarantee)
OBJ_CARD_INST_MAX   := 2048        # card rows
OBJ_DOT_INST_MAX    := 4096        # dot rows
```

Arbitration: sort registered objects by `p` descending; grant mesh slots first, then cards,
then dots; anything past `OBJ_DOT_INST_MAX` is dropped smallest-first (log-once, telemetry
count — the far-trees `_capped` convention). Decimation bakes live in an LRU keyed
`(id, rev, pitch)` inside the ledger; `total_bytes()` asserted by the gate. Nothing scales with
session length or world size — only with the cap table (the `BodyLod.far_tier_bytes` pattern).

### 4.4 Reuse vs divergence from existing machinery

| Existing | Reused | Diverges because |
|---|---|---|
| `BodyLod` | `k_px`, hysteresis pattern, ledger pattern, G-SSE-INV transition logging | objects are many + moving → per-object registry & instance buffers instead of a 3-body table |
| `StructDecimator` | `decimate`/`bake_lattice` **verbatim** (sampler = `body.cells` lookup; fid moot — body-local) | output feeds a per-object MeshInstance, not the merged band mesh |
| `FacetFarTrees` | card mesh shape, atlas rasterisation, stride-20 buffer law, dither fade, delta gate, caps discipline | cards are per-object-rev (unique), not per-species archetype; transforms are live |
| `FacetFarStructures` | bake-cache-by-rev law, near-handoff idea | merged-mesh approach rejected for movers (transforms can't merge) |
| `VoxelBody` dormancy | `is_awake()` gates transform rewrites; `_rebuild()` bumps rev | none — zero physics changes |

**Near-handoff**: unnecessary for objects (unlike trees/structures there is no second renderer
of the same thing — the tier itself hides L0 when it shows L1+, one owner at a time,
make-before-break within a frame).

### 4.5 Staging & flags (all default-OFF, byte-identical off, FLAT 6042/0)

- **P0 — `FP_OBJ_LOD` (law + gate)**: `object_lod.gd` pure statics (selection, hysteresis,
  switch/cull distances, budget arithmetic) + `verify_object_lod.gd` (tier tables over synthetic
  approaches, sub-pixel-swap assertion, worst-legal-state ≤ `OBJ_LOD_BYTES_MAX`, byte-off).
  No renderer change. ~1 day.
- **P1 — `FP_OBJ_LOD_DEBRIS`**: registry + tier node + card/dot MultiMeshes + L0 hide for
  `VoxelBody`; dormant snapshotting; delta gate; fog-band fade. Live A/B: chop a forest edge,
  walk 500 blocks — debris still visible as cards where today it pops invisible into fog.
- **P2 — `FP_OBJ_LOD_MESH`**: decimated-mesh rung via `StructDecimator` for E ≥ 16 objects
  (today: giant `TREEPHYS_COLLIDER_CAP` detachments; tomorrow: ships). Worker-baked, LRU.
- **P3 — `FP_OBJ_LOD_SPACE`**: `CLASS_SPACE` + clamped-distance placement + beacon dot floor +
  no-cull; registry API for non-VoxelBody objects (ships/stations/asteroids when they exist).
  Gate: synthetic 10⁵-block approach with monotone `p`, no gap, no double-render.
- **P4 (optional, deferred)** — offline octahedral atlas for hero objects; only if P2 meshes
  prove insufficient in the 20–100 px band on real ships. Not needed for debris.

### 4.6 Risks / adversarial notes

- **Two cameras' worth of px**: `K_px` must be recomputed on resize AND zoom (the `BodyLod`
  telescope note) — plumb through the same viewport signal `BodyLod`'s driver uses.
- **f16 `INSTANCE_CUSTOM` on web**: fade/luma/atlas-col all fit f16 comfortably; never put
  positions there.
- **Buffer rewrite cost** is the real perf risk at `OBJ_CARD_INST_MAX`: 2048 × 20 floats =
  160 KB/upload. The lazy-row + dormant-snapshot rules make the steady state ~zero; the gate
  must assert rewrite count under a settled scene == 0 (the `FT_DELTA` lesson: measure the
  rebuild counter, not fps).
- **Card for a tumbling body**: a cross-card under a live rotation shows its planes edge-on
  periodically. Mitigation: card transform uses the body's *position* but a camera-facing (or
  gravity-up) basis, not the body's rotation — at ≤ 20 px the rotation is unreadable anyway
  (billboard-cloud logic). The gate cannot see this; flag for the live A/B checklist.
- **Never restart the relay mid-session** during live A/Bs (project law).

---

## 5. Sources

- Unity LODGroup: https://docs.unity3d.com/560/Documentation/Manual/class-LODGroup.html ; https://docs.unity3d.com/ScriptReference/LOD-screenRelativeTransitionHeight.html ; editor internals https://github.com/Unity-Technologies/UnityCsReference/blob/master/Editor/Mono/Inspector/LODGroupGUI.cs
- Unreal LOD/HLOD screen size: https://dev.epicgames.com/documentation/unreal-engine/optimizing-lod-screen-size-per-platform-in-unreal-engine ; https://github.com/ibbles/LearningUnreal/blob/main/Mesh%20LOD.md ; https://moonjump.com/game-dev-mechanics-level-of-detail-lod-how-it-works/
- 3D-Tiles / Cesium SSE: https://github.com/CesiumGS/3d-tiles/blob/main/specification/README.adoc ; https://cesium.com/downloads/cesiumjs/releases/1.38/Build/Documentation/Cesium3DTileset.html ; https://cesium.com/learn/cesium-native/ref-doc/selection-algorithm-details.html ; https://community.cesium.com/t/understanding-geometric-error/8480/2
- Dithered LOD transitions: https://cesium.com/blog/2022/10/20/smoother-lod-transitions-in-cesium-for-unreal/
- Décoret, Durand, Sillion, Dorsey, *Billboard Clouds for Extreme Model Simplification*, SIGGRAPH 2003: https://dl.acm.org/doi/10.1145/1201775.882326 ; https://inria.hal.science/inria-00510175
- Octahedral impostors: https://github.com/wojtekpil/Godot-Octahedral-Impostors ; https://wiki.amplify.pt/index.php?title=Unity_Products%3AAmplify_Impostors%2FManual ; https://www.alanzucconi.com/2018/08/25/shader-showcase-saturday-7/
- Simplygon LOD chains: https://documentation.simplygon.com/SimplygonSDK_10.0.1400.0/concepts/reduction.html ; https://www.simplygon.com/posts/fd30ea69-957c-4897-a7f4-821037deb81f ; https://simplygon.com/posts/dd10914d-b7a4-4a78-9b3c-35eec441495d
- Depth precision: https://developer.nvidia.com/blog/visualizing-depth-precision/ ; https://www.reedbeta.com/blog/depth-precision-visualized/ ; https://tulrich.com/geekstuff/log_depth_buffer.txt ; https://outerra.blogspot.com/2009/08/logarithmic-z-buffer.html ; https://www.gamedeveloper.com/programming/logarithmic-depth-buffer
- Camera-relative / huge distances: https://github.com/shenzhou05/SRP-Chinese-Translation/blob/master/Pages/HDRP/Camera-Relative-Rendering-in-HDRP.md ; https://gamedev.net/forums/topic/660567-rendering-huge-space-distance-technique/ ; https://www.resetera.com/threads/the-ways-different-space-games-have-handled-traversal-and-scale.932520/
- KSP distant objects: https://www.curseforge.com/kerbal/ksp-mods/distant-object-enhancement-l
- Voxel LOD practice: https://www.gamedev.net/forums/topic/679604-voxel-lod/ ; https://www.gamedev.net/forums/topic/677008-lod-on-a-cubical-voxel-engine/5280976/
- Godot MultiMesh: https://docs.godotengine.org/en/stable/tutorials/performance/using_multimesh.html ; https://github.com/godotengine/godot-proposals/issues/8666
- Luebke, Reddy, Cohen, Varshney, Watson, Huebner, *Level of Detail for 3D Graphics*, Morgan Kaufmann, 2002.
- In-repo: `godot/src/cosmos/body_lod.gd`, `godot/src/world/struct_decimator.gd`, `godot/src/world/facet_far_trees.gd`, `godot/src/world/facet_far_structures.gd`, `godot/src/world/structure_tracker.gd`, `godot/src/physics/voxel_body.gd`, `docs/COSMOS-STRUCTURES-DESIGN.md`, `docs/COSMOS-FAR-TREES-DESIGN.md`, `docs/COSMOS-LOD-SKY-DESIGN.md`.
