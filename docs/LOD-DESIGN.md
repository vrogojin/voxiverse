# LOD-DESIGN — locked build ADR (analytic far-field terrain: rings, seam, fog, streaming)

Status: **LOCKED, implementation-ready.** This is the build spec for the far-distance terrain
layer. It consolidates `docs/LOD-RESEARCH.md` (the completed research; its Option C —
**custom analytic far-field mesh layer** — is adopted here, not relitigated) into numbered,
implementable decisions. Decisions the research already settled are cited, not re-argued;
where this ADR refines a research number (ring bands, the sea representation), the refinement
and its reason are stated explicitly.

**Engine-patch verdict, stated up front: NO godot_voxel change, NO engine rebuild, NO new
render-path mechanism is required.** The far field is plain GDScript + `MeshInstance3D` +
runtime `ArrayMesh` + one `StandardMaterial3D`, drawn by the GL Compatibility renderer with
ordinary vertex/fragment shading. Nothing in this design needs compute, tessellation,
geometry shaders, or `RenderingDevice` — all unavailable on WebGL2/Compatibility
(LOD-RESEARCH §2.5) and all avoided. **Every part of this design is feasible in the
Compatibility renderer as-is**; the only genuinely hardware-dependent unknowns (fog banding,
ANGLE draw-call headroom, depth precision at 3 km) are quantified in §7 with fallbacks that
stay inside this design.

**The model in one paragraph.** A new `FarTerrain` node (owned by `WorldManager`, render-only,
zero collision, zero voxel-worker load) keeps 4 concentric rings of world-anchored square
heightmap tiles alive around the player, from 192 m out to **R_FAR = 3,072 m**. Each tile is
a static `ArrayMesh` grid whose vertex heights are `TerrainConfig.height_at(x,z) + 1 − 1.5`
(the voxel walk surface, biased 1.5 blocks down — the Distant-Horizons overlap pattern,
LOD-RESEARCH §4/§6.4), clamped up to a slightly-sunk sea surface over open water, with
per-vertex biome/climate colours from `BlockCatalog.color_of` and Ulrich-style skirts hiding
ring cracks. Both the near voxel world and the far field derive from the same
`height_at`/`column_profile` (`terrain_config.gd:392-396`, `:443-459`), so they agree by
construction; the residual seam error is ≤ 1 block of smoothing quantization at lattice
points. The fog wall at 243 m (`main.gd:94-95`) is retuned into a 2,750 m haze. Tiles are
built on the **main thread** under a 3 ms/frame budget, coarse ring first, so there is no
load spike and the single web voxel worker is never touched. Removing the node (or flipping
one const) restores today's behaviour exactly.

Headline numbers (derived in §1/§3, verify-pinned in §6):

| Quantity | Locked value |
|---|---|
| Horizon | R_FAR = 3,072 m; inner hole 192 m (= `RENDER_RADIUS_BLOCKS` 256 − 64) |
| Rings | 4 (cells 4/8/16/32 m; each ring's cell ≈ 2% of its inner radius) |
| Triangles | ≈ 478 k at the mountain spawn; ≈ 554 k geometric worst; **hard cap 600 k** (asserted) |
| Draw calls | ≈ 60–75 far tiles typical; **hard cap 96** (+1 material, opaque pass only) |
| GPU memory | ≈ 11–14 MB (≈ 210 k verts × 40 B + 16-bit indices) |
| Build cost | ≈ 210 k `column_profile` calls ≈ 0.4–0.9 s WASM CPU, amortized ≤ 3 ms/frame |
| Fog | depth fog, begin 115 / end 2,750 / curve 0.38 (derivation §3.4) |
| Camera | `Camera3D.far` 563 → **3,840** (`player.gd:66`) |

---

## Decision 1 — Far-field representation: 4 fixed-resolution rings of world-anchored heightmap tiles with skirts

**1.1 Structure (locked).** Chunked LOD in the Ulrich pattern (LOD-RESEARCH §3, §6.1):
per ring, a world-aligned square tile grid (tile coordinates `Vector2i(floor(x / T),
floor(z / T))` — tiles are anchored in **world space**, never player-relative, so a tile's
mesh is a pure function of `(ring, tile_coord, SEED)` and re-centering never regenerates
geometry that is still in-set). Each live tile is one `MeshInstance3D` + `ArrayMesh` child of
`FarTerrain`. No quadtree: ring membership is a fixed function of distance (§4), which is
simpler, bounded, and sufficient at these scales.

**1.2 The ring table (locked).** This refines LOD-RESEARCH §6.1's "starting point" table: the
research's strict octave-doubling bands, priced honestly with partial-tile counts, land at
≈ 490 k triangles — over its own ~390 k envelope. The bands below keep the same structure
(cell size doubles ring to ring) but tighten the two inner bands so **every ring's cell size
is ≈ 2% of its inner radius** (constant screen-space error target), which brings the total
back inside the envelope:

Tris/tile below include the **double-sided** skirt (2× the skirt tris of the original design,
§1.4): a grid-64 tile is 8,192 surface + 1,024 skirt, a grid-32 tile 2,048 + 512.

| Ring | Band (m, from player XZ) | Cell | Tile | Grid | Tris/tile (incl. 2-sided skirt) | Typical tiles | Typical tris |
|---|---|---|---|---|---|---|---|
| 0 | 192 – 320 | 4 m | 256 m | 64×64 | 8,192 + 1,024 = 9,216 | ~10 | ~92 k |
| 1 | 320 – 768 | 8 m | 512 m | 64×64 | 9,216 | ~12 | ~111 k |
| 2 | 768 – 1,792 | 16 m | 1,024 m | 64×64 | 9,216 | ~16 | ~147 k |
| 3 | 1,792 – 3,072 | 32 m | 1,024 m | 32×32 | 2,048 + 512 = 2,560 | ~33 | ~85 k |

Total ≈ 71 tiles ≈ **435 k triangles** typical, ≈ 478 k at the mountain-foothill spawn, and a
**≈ 554 k geometric worst** (every tile full-mesh, worst boundary alignment, no ocean
collapse — measured by a position sweep). Typical counts assume the area-of-annulus /
tile-area estimate plus perimeter partials; exact counts vary ±20% with player position, hence
the **hard caps** (§4.4): if a computed desired set would exceed `FAR_MAX_TRIS = 600_000` or
`FAR_MAX_TILES = 120` or draw calls > 96, outermost tiles are trimmed first (never inner/seam
tiles) and a warning is pushed — the caps are a safety net, not the sizing mechanism. The cap
clears the 554 k worst with headroom so no inland mountain position ever trims the horizon.
The skirt-doubling adds only **indices** (16-bit; the ≤ 4,485 verts/tile is unchanged), so GPU
memory is unaffected and stays in the 10–20 MB envelope below. Well within WebGL2 limits: each tile has ≤ 4,485 vertices
(65² grid + 4×65 skirt row), so indices are 16-bit; a single vertex format (position +
normal + COLOR) ≈ 40 B/vertex → ≈ 11–14 MB GPU total (LOD-RESEARCH §6.6 envelope 10–20 MB).
Draw-call context: the near field already runs ~200–500 draws by design
(`module_world.gd:178-188`, the `mesh_block_size=32` rationale); +75 opaque draws is inside
the ANGLE→D3D11 headroom that comment documents.

**1.3 Vertex data (locked).**
* **Position**: lattice point `(wx, r(wx,wz), wz)` where `r` is the render height of §2.2.
* **Normal**: central differences of the same height lattice (the sampling grid carries one
  padding row per edge, so a 64-grid tile samples 67² columns). Skirt vertices copy the edge
  vertex's normal (no dark walls).
* **COLOR**: the far palette of §2.3.
* No UVs, no textures — flat vertex colour, the Distant-Horizons trade the research validated
  (LOD-RESEARCH §4), rendered through the engine's existing idiom
  `vertex_color_use_as_albedo = true` (`block_materials.gd:111`, `:121`).

**1.4 Skirts (locked).** Every tile edge is extruded straight down by `SKIRT_DEPTH = 4 ×
cell` (16/32/64/128 m per ring). This over-covers the worst inter-ring crack: at a ring
boundary the two resolutions disagree by at most ≈ slope × coarser-cell; even a 45° mountain
flank at the ring-2/3 boundary (≤ 32 m discrepancy) is hidden by ring 2's 64 m skirt. Skirt
quads reuse the edge vertex colour. This is the whole crack story — **no cross-ring index
stitching, no T-junction repair** (Ulrich's answer; LOD-RESEARCH §6.2), and no
`visibility_range` alpha fades (they force the transparent pass — LOD-RESEARCH §2.5; locked
OUT for v1).

**Skirts are DOUBLE-SIDED (locked — corrects the original single-winding assumption).** The
player sits at the ring centre, so at a ring boundary the covering skirt hangs from the
*higher* tile's edge. When distant terrain **rises** away from the player (every distant
ridge/mountain) that skirt's outward face points away from the player; when terrain falls it
points toward the player. No single triangle winding is visible in both cases — a one-sided
skirt would leak fog/sky through the crack on exactly the objectionable rising boundaries.
The fix: `FarMeshBuilder._wall_quad` emits **both** windings for each skirt quad (4 tris/quad
instead of 2). This doubles only the thin skirt walls (~6% of a tile's triangles) rather than
paying for a `CULL_DISABLED` material — the top surface stays single-sided `CULL_BACK`, so it
is neither whole-surface-overdrawn nor split into a second draw call. (Contrast §2.4: the top
surface's own winding is separately fixed to face +Y; that part genuinely needs only
`CULL_BACK`.)

**1.5 World anchoring and the skip-inner rule (locked).** A tile is *live* iff its 2D AABB
intersects the Euclidean annulus `[max(192, ring.inner), ring.outer]` around the player's XZ,
and is **skipped** iff its AABB lies entirely inside radius 192 (`RENDER_RADIUS_BLOCKS − 64`,
`terrain_config.gd:115`) — those cells are always covered by the near voxel field
(`max_view_distance = 256`, `module_world.gd:177`), so building them wastes memory and fill
rate (LOD-RESEARCH §6.4). The 192–256 band is the deliberate **overlap band**: far mesh
present *behind and below* the streamed voxel chunks, so the ragged edge of the voxel world
is backed by coarse ground instead of sky (the DH overdraw-prevention pattern,
LOD-RESEARCH §4).

**1.6 What the far field is NOT.** No collision shape, no `StaticBody3D` — physics is
analytic through `WorldManager` (`world_manager.gd:786-1030`) and never sees render geometry
(CLAUDE.md rule 2 / rule "physics is analytic"). Not consulted by the DDA raycast, the
ground collider, or the sim layer. Not affected by `VIEWER_VERTICAL_RATIO`
(`terrain_config.gd:129`) — that governs voxel streaming only. It ignores the `_edits`
overlay entirely: a dug pit subtends < 0.3° at 192 m (LOD-RESEARCH §6.3). A per-tile
`invalidate_tiles(region: Rect2i)` hook (recompute + re-commit affected tiles through the
normal queue) is **specified as the extension point** for future distant-edit visibility
(LOD-RESEARCH §8.5) but NOT implemented now.

---

## Decision 2 — Generation: point-sampled `height_at`, composite land/sea surface, palette from the catalog, main-thread amortized

**2.1 The sampling contract (locked).** Per lattice point, ONE
`TerrainConfig.column_profile(x, z)` call (`terrain_config.gd:443-459`) yields height `g`,
biome, continentalness and temperature — ~7 warmed FastNoiseLite evaluations, no voxel data,
no `resolve_cell`, no trees, no smoothing stencil (LOD-RESEARCH §6.3). **Point-sampling at
the lattice, no cell averaging**: research open question §8.1 is resolved in favour of
point-sampling for v1 (it makes the lattice-point height *exactly* the near field's walk
surface, giving verify an exact invariant; a `_corner_targets`-style average is a Phase 2
A/B, §6.4). The builder must never touch `TerrainConfig._shape_memo` paths — it reads only
`column_profile`/`height_at`, which are memo-free.

**2.2 The render height `r(x,z)` (locked) — one composite surface, no separate sea disc.**

```
walk(x,z)  = height_at(x,z) + 1                      # the voxel walk surface (SVS §8.1)
land(x,z)  = walk(x,z) − BIAS_LAND                   # BIAS_LAND = 1.5 (research §6.4)
sea_y      = SEA_LEVEL + WATER_SURFACE_HEIGHT − BIAS_SEA
           = 0 + 0.9375 − 0.25 = 0.6875              # terrain_config.gd:46, :78
r(x,z)     = land(x,z)                if g >= SEA_LEVEL   (dry column)
           = max(land(x,z), sea_y)    if g <  SEA_LEVEL   (sea-covered column)
```

This **deliberately replaces** LOD-RESEARCH §6.1's separate translucent "sea disc" with a
single opaque composite surface, for a hard technical reason quantified in §7.2: at 2,750 m
with the player camera's 0.05 near plane, 24-bit depth resolution is ≈ 9 m — a disc floating
0.5–1.5 m above coplanar ocean-floor tiles **would z-fight at distance**. One surface has
nothing to fight. It also deletes the disc/floor overdraw, handles frozen and molten seas
for free (colour, §2.3), and enables the open-ocean collapse (§2.5). Costs accepted: distant
water is opaque (DH precedent, LOD-RESEARCH §4) and a dry beach column at g = 0 renders at
−0.5 next to sea vertices at 0.6875 — a ≤ 1.2 m waterline lip, sub-0.4° at 192 m, washed by
the 26–33% fog of §3.4. `BIAS_SEA = 0.25` (not 1.5) keeps the far sea visually flush with
the near water plane at the seam; 0.25 m is safely above depth-resolution at ≤ 256 m
(≈ 0.08 m) so near water always wins depth in the overlap band.

**2.3 The far palette (locked; new `far_palette.gd`).** Colours are looked up from
`BlockCatalog.color_of(id)` (`block_catalog.gd:428`) at palette init — **no hard-coded RGB**;
if the catalog recolours a block, the far field follows. Per vertex:

1. **Clamped sea vertex** (`r == sea_y`): the sea regime colour from temperature `t`
   (profile `.w`), mirroring `_sea_liquid_kind` (`terrain_config.gd:991`, thresholds
   `:48-51`): `t < −0.55` → `color_of(ice)`; `t >= 0.60` (`LAVA_SEA_T`) → `color_of(lava)`;
   else `color_of(water)`. Frozen seas read white, molten seas orange — matching the near
   world's ice caps and lava seas by construction. Normal forced to +Y.
2. **Snow-cap override** (any land vertex): iff
   `ClimateModel.surface_temperature(g, t) < 0` (`climate_model.gd:47`, `ALT_ZERO_Y = 96`
   `:25`) → `color_of(snow_block)`. This reproduces the altitude snow line — the same
   predicate worldgen stamps caps with (`terrain_config.gd:556-566`) — so mountain peaks
   (y ≈ 103–112, `MOUNTAIN_AMPLITUDE = 92` `:97`) whiten above y≈96 at every distance.
3. **Biome base** (keyed on the public `B_*` consts, `terrain_config.gd:153-162`, mirroring
   `_biome_top` `:1018-1035` / `_underwater_floor` `:1037-1048`):
   OCEAN floor (unclamped shallow) → sand if `t > 0` else gravel; BEACH/DESERT → sand;
   BADLANDS → red_sand; SWAMP → mud; SNOWY → snow_block; TAIGA →
   `lerp(color_of(grass), color_of(podzol), 0.20)` (the deterministic mean of the 20% podzol
   hash at `:1029`); FOREST → `lerp(color_of(grass), color_of(leaf), 0.35)` (canopy tint —
   the locked compensation for no distant trees, LOD-RESEARCH §6.3); PLAINS → grass;
   MOUNTAINS → stone.

**2.4 One material (locked).** A single shared `StandardMaterial3D`:
`vertex_color_use_as_albedo = true`, `roughness = 1.0`, `metallic/specular = 0`, opaque,
`CULL_BACK`. The top surface is wound to face +Y so `CULL_BACK` draws it correctly from above
(the original winding faced down and was wrongly culled). **`CULL_BACK` alone does NOT suffice
for the skirts** — a centre viewer must see the covering skirt on both rising and falling
boundaries, which no single winding gives (§1.4). Skirts are therefore made double-sided in
*geometry* (both windings), keeping ONE material and ONE draw call per tile while the top
stays cheap and single-sided. The scene is flat-ambient with no sun (`main.gd:77-82`), so
vertex colour IS the final surface colour (back-face skirt tris show the same colour — no dark
walls), and Godot's depth fog applies to near and far layers identically — the
luminance-matching problem solved by using the same fog in the same renderer (LOD-RESEARCH
§6.5).

**2.5 Open-ocean collapse (locked).** If every sample in a tile is a clamped sea vertex, the
tile is emitted as a **single flat quad** (4 vertices, 2 triangles, no skirt — its neighbours
at sea are coplanar by construction, and any land neighbour's skirt covers the edge). Ocean
horizons then cost ~2 tris/tile instead of 8,704 — this is what keeps coastal/at-sea views
far below the tri cap.

**2.6 Where it runs (locked): main thread, budgeted, coarse-first.** Per LOD-RESEARCH §6.7:
GDScript `Thread`s on web share the **fixed** Emscripten pthread pool already sized for the
voxel worker (`project.godot:63-65` and the deadlock warning in `module_world.gd`'s header) —
so Phases 0–2 build **only on the main thread**, mirroring the engine's own proven pattern
of a main-thread time budget (`voxel/threads/main/time_budget_ms=4`, `project.godot:72`):

* `FAR_BUILD_BUDGET_MS = 3.0` per frame of sampling work, measured with
  `Time.get_ticks_usec()`; a tile's sampling pass is sliced into ≤ 1,024-column steps so a
  64-grid tile (67² = 4,489 profiles ≈ 9–18 ms at the measured 2–4 µs/profile,
  LOD-RESEARCH §6.6) spans frames without ever exceeding the budget.
* **≤ 1 mesh commit per frame** (ArrayMesh creation + `add_child` — the upload spike).
* Queue priority: ring 3 outward-in first (a 32-grid tile ≈ 1.2 k profiles ≈ 2–4 ms, so the
  full horizon silhouette appears within the first ~30 frames), then ring 2, 1, 0, each
  nearest-first. The full field (~210 k profiles ≈ 0.4–0.9 s CPU) finishes amortized during
  the existing load prewarm + first seconds of play; **no load-time spike** by construction.
* `FarTerrain._ready()` calls `TerrainConfig.warm_up()` (idempotent,
  `terrain_config.gd:317-320`) before any sampling — same main-thread warm-up discipline as
  `module_world.setup()` (`module_world.gd:120`) — so this holds even on the fallback render
  path where the module never ran.
* The voxel worker is untouched: `FarTerrain` never instantiates a voxel node, never calls
  the generator, never enqueues module tasks. (The generator's own `lod != 0` early-out,
  `module_world.gd:1059-1060`, stays exactly as-is.)
* Phase 3 (optional, §6.5) may move sampling to one dedicated `Thread` **only** together
  with a pthread-pool bump in the export template via `scripts/build.sh` — an engine-build
  change gated on profiling evidence, per LOD-RESEARCH §6.7.

**2.7 Determinism (locked).** A tile mesh is a pure function of `(ring, tile_coord,
TerrainConfig.SEED)` — no `randi()`, no `Time`, no player state. Two builds of the same tile
are byte-identical (verify-pinned, §6.2), the same discipline as worldgen
(`terrain_config.gd:25-28`).

---

## Decision 3 — The near/far seam: overlap + down-bias + retuned fog

**3.1 Consistency by construction.** Both layers derive from `height_at`; at every far
lattice point the far surface is *exactly* `walk − 1.5` (dry land). The voxel walk surface
is `walk` reshaped within ±1 block by the corner-target smoothing
(`_corner_targets`/`_modifier_from_targets`, `terrain_config.gd:620-650`), so the vertical
mismatch at lattice points is **exactly 1.5 ± 1.0 blocks — the far mesh sits 0.5–2.5 blocks
under the voxel surface, never above it** at lattice points. Between lattice points the far
mesh interpolates linearly; a sub-cell terrain dip can locally reduce the clearance and in
rare 1-block pits a far edge can graze the voxel surface — at ≥ 192 m that is a sub-0.2°,
26%-fogged event, and from above it is hidden by the opaque voxel ground. Accepted
(LOD-RESEARCH §6.4 error budget); the down-bias is the systematic guarantee.

**3.2 Z-order (locked).** Inside the 192–256 overlap band the voxel terrain always wins
depth naturally (its surface is ≥ 0.5 m above the far mesh at lattice points; depth
resolution at 256 m is ≈ 0.08 m — resolvable). No z-fighting, no stencil tricks, no draw
order dependence. Where near chunks have not streamed yet, the far mesh shows coarse ground
behind them instead of sky. Far tiles fully inside 192 m don't exist (§1.5), so the far
field never double-shades the ground under the player.

**3.3 Trees at the seam.** Near field has full trees to 256 m; far field has none, tinted
instead (§2.3.3). The 64 m overlap band makes this a density falloff, not a line
(LOD-RESEARCH §6.4.3). No tree impostors in v1 (Phase 3 option, §6.5).

**3.4 Fog retune (locked numbers).** Today (`main.gd:89-98`): depth fog `begin = r·0.45 ≈
115`, `end = r·0.95 ≈ 243`, `curve 0.9`, `fog_sky_affect 0` — a deliberate wall fully
occluding the world edge ~13 m before 256. With a far field this inverts to a haze
(LOD-RESEARCH §6.5). Godot's depth-fog factor is
`pow(clamp((d − begin)/(end − begin), 0, 1), curve)`. Locked:

```
env.fog_depth_begin = 115.0      # unchanged near feel
env.fog_depth_end   = 2750.0     # ≈ 0.9 × R_FAR: fully opaque before the 3,072 rim
env.fog_depth_curve = 0.38       # front-loaded so the seam band sits at ~26–49%
env.fog_sky_affect  = 0.0        # unchanged
```

Resulting opacity (the derivation the numbers were solved from):

| Distance | 192 (seam start) | 256 (voxel edge) | 352 (mid-seam) | 512 | 1,024 | 2,048 | 2,750 |
|---|---|---|---|---|---|---|---|
| Fog | 0.26 | 0.33 | 0.40 | 0.49 | 0.67 | 0.89 | 1.00 |
| (today) | 0.63 | 1.00 | — | — | — | — | — |

The seam band (192–512) sits at 26–49% — enough to wash the ≤ 1-block seam residuals, the
waterline lip (§2.2) and the tree falloff, while the 115–192 near band is actually *crisper*
than today (0.26 vs 0.63 at 192). A y≈103 peak at 3,072 m subtends ≈ 1.9° and reads through
0.89–1.0 fog as a silhouette against `SKY_COLOR` — the fog light colour IS the sky colour
(`main.gd:8`, `:92-93`), so the far rim dissolves into the horizon exactly as the 256 wall
does today, just 11× further out. Exact curve value is Phase 2 tunable on real hardware
(banding risk, §7.1) — `begin/end` are locked, `curve` is locked ±0.1.

**3.5 Camera far plane (locked).** `player.gd:66` sets `camera.far = RENDER_RADIUS_BLOCKS ×
2.2 ≈ 563` — the far field would be frustum-clipped. Change to `FAR_CAMERA_FAR = 3,840`
(1.25 × R_FAR) when the far field is enabled; keep today's value when disabled. Camera
`near` stays at Godot's default 0.05 in v1 (see §7.2 for the precision analysis and the
0.1 fallback lever).

---

## Decision 4 — Streaming and LOD update: re-evaluate on 64 m steps, no-hole swaps, no morphing in v1

**4.1 Re-evaluation rule (locked).** The desired tile set is a **pure function of one
evaluation point** `E` (player XZ). `FarTerrain.update_center(pos)` — called from
`WorldManager.update_streaming` (`world_manager.gd:112-116`), which the player already
drives every physics tick (`player.gd:160-164`) — recomputes the desired set only when
`pos.xz` has moved ≥ `FAR_RECENTER_STEP = 64.0` m from the last evaluation point. Because
evaluation points are ≥ 64 m apart and ring bands are ≥ 128 m wide, a tile's ring assignment
can change by at most one ring per re-evaluation and cannot oscillate frame-to-frame — the
64 m step IS the hysteresis (no additional `visibility_range` machinery; `Disabled`-mode
ranges are unnecessary since we own the set).

**4.2 Set reconciliation (locked, the no-hole rule).** Diff desired vs live keys
`(ring, tile_coord)`:
* Keys in both: untouched (world anchoring means the mesh is still valid — zero rebuild for
  pure translation within a band).
* New keys: enqueued (priority: coarser ring first, then nearest).
* Stale keys: freed **only after** every desired tile overlapping their footprint has
  committed (e.g. a ring-1 512 m tile is freed only once the 2×2 ring-0 256 m tiles covering
  it are live, and vice versa outward). Until then the stale tile keeps rendering — a
  one-band-late resolution is invisible under 26–49% fog; a hole is not.
* Eviction frees the `MeshInstance3D` + `ArrayMesh` immediately (no cache — rebuilds
  re-sample, profiles are cheap; **no persistent height cache**, keeping steady-state CPU
  memory at ~zero beyond live meshes).

**4.3 Per-frame cost (locked).** All work happens inside the §2.6 budget: ≤ 3 ms sampling +
≤ 1 mesh commit per frame, on the Compatibility renderer's main thread. A worst-case
re-center while walking (crossing one 64 m step) dirties ~4–8 tiles ≈ 20–70 k profiles ≈
0.05–0.3 s CPU spread over a few dozen frames — no hitch. Sprinting/flying continuously
re-centers; the queue is coalescing (a key superseded before it builds is dropped), so the
system degrades to "horizon refines when you slow down", never to a stall.

**4.4 Bounds (locked, verify-pinned).** `FAR_MAX_TILES = 120`, `FAR_MAX_TRIS = 600_000`
(raised from 450 k for the double-sided skirts, §1.4/§1.2), far draw calls ≤ 96 (tiles +
nothing else; one material, opaque pass). The desired-set
computation enforces them by trimming outermost-first (§1.2). Memory bound follows:
≤ 120 tiles × ≤ 230 KB ≈ 27 MB absolute worst, ≈ 11–14 MB typical.

**4.5 Transitions (locked): hard swaps, no morph.** Ring boundary swaps replace a tile with
2×2 (or 1/4) tiles of 2× different cell size at ≥ 320 m under ≥ 33% fog — a sub-pixel-scale
pop for most of the mesh (LOD-RESEARCH §3, "popping/morphing" note). v1 ships **no** CDLOD
vertex morph, **no** `visibility_range` fades (transparent-pass cost, LOD-RESEARCH §2.5),
**no** CPU re-tessellation. If Phase 2 screenshots/motion tests show objectionable popping,
Phase 3(a) adds a CDLOD-style morph as a custom **vertex shader** (plain VS math — WebGL2
legal; the mesh gains a per-vertex morph-target height in `CUSTOM0`), which slots in without
changing tiling. This is the one pre-planned escape hatch, deliberately deferred.

---

## Decision 5 — Integration: the `FarTerrain` node, wiring, prewarm, graceful degrade

**5.1 New files (all new code lives in `godot/src/world/far/`):**

| File | Contents |
|---|---|
| `far_terrain.gd` | `class_name FarTerrain extends Node3D`. The manager: ring table const, desired-set computation, build queue + budget, commit/evict + no-hole rule, `update_center()`, `invalidate_tiles()` stub, the locked consts (`ENABLED`, `R_FAR`, `INNER_HOLE`, `BIAS_LAND`, `BIAS_SEA`, `SKIRT_*`, `FAR_BUILD_BUDGET_MS`, caps, `FAR_CAMERA_FAR`). |
| `far_mesh_builder.gd` | `class_name FarMeshBuilder` — **pure static** tile builder: `sample_tile(ring, tc) -> Dictionary` (height/colour lattices; sliceable) and `build_mesh(sampled) -> ArrayMesh` (+ the raw-arrays variant verify uses). No scene access, fully headless-testable. |
| `far_palette.gd` | `class_name FarPalette` — the §2.3 table, built once from `BlockCatalog.color_of` + `ClimateModel.surface_temperature`. |

**5.2 Edits to existing files (complete list — nothing else changes):**

| File | Change |
|---|---|
| `godot/src/world/world_manager.gd` | `_ready()` (`:63-82`): after path selection, `if FarTerrain.ENABLED:` instantiate + `add_child` a `FarTerrain` (it is part of "the world" `WorldManager` owns — CLAUDE.md architecture graph). `update_streaming()` (`:112-116`): `_far.update_center(player_pos)`. |
| `godot/src/main.gd` | `_setup_environment()` (`:89-98`): fog params switch on `FarTerrain.ENABLED` — enabled → §3.4 values; disabled → today's `r*0.45 / r*0.95 / 0.9` untouched. |
| `godot/src/player/player.gd` | `:66`: `camera.far = FarTerrain.FAR_CAMERA_FAR if FarTerrain.ENABLED else r * 2.2`. |
| `godot/src/tools/shader_prewarm.gd` | `spawn_warmups()` (`:143+`): add ONE warm instance drawing the far material on the far vertex format (position+normal+COLOR, no UV) — a new material × format pair that would otherwise compile (~800–950 ms via ANGLE, `main.gd:61-67`) on the first far-tile draw. Additionally the coarse-first queue (§2.6) commits ring-3 tiles during the prewarm hold, so the pipeline is exercised behind the "Loading…" overlay by construction; the grid instance is the belt-and-braces guarantee. |
| `godot/src/tools/verify_feature.gd` | Add `_test_lod_far_field()` to the runner (`:26-62`). Spec in §6.2. |

**5.3 Enable/disable (locked).** `FarTerrain.ENABLED: bool` — a single const, the exact
`SMOOTHING_ENABLED` diagnostic-toggle pattern (`terrain_config.gd:39`). `false` restores
today's behaviour bit-for-bit: no node, today's fog wall, today's camera far. Phase 0 ships
`ENABLED = false` plus a web query-string override (`?far=1` read via
`JavaScriptBridge.eval("location.search")`, ignored on non-web) so the spike deploys to the
live site dark (LOD-RESEARCH §7 Phase 0); Phase 1 flips the default to `true` and the
override inverts to `?far=0`. **No change to the near voxel path's gameplay in any state**:
`FarTerrain` never writes `_edits`, never touches the module node, and no gameplay code
reads it.

**5.4 Both render paths.** `FarTerrain` reads only `TerrainConfig` + `BlockCatalog` +
`ClimateModel` — path-agnostic by construction (LOD-RESEARCH §8.6). It runs identically over
the module world and the GDScript fallback, and headless with neither.

---

## Decision 6 — Correctness, verification, and the phased build order

**6.1 The invariants (what "correct" means).**
1. **Lattice identity**: every dry-land far vertex equals `height_at(x,z) + 1 − 1.5`
   exactly; every clamped sea vertex equals `0.6875` exactly.
2. **Under-bias**: at lattice points, far height ≤ voxel walk surface − 0.4 (i.e. below even
   a maximally-down-smoothed surface cell: 1.5 − 1.0 corner quantization − margin).
3. **Coverage**: for any evaluation point, the union of live-tile AABBs covers the annulus
   `[192, 3,072]` with no gap, and no tile AABB lies inside 192.
4. **Budgets**: Σ tris ≤ 600 k, tiles ≤ 120, per-tile verts ≤ 4,485 (16-bit indices).
5. **Determinism**: same `(ring, tile_coord, SEED)` → byte-identical arrays.
6. **Palette**: peaks above the freeze line are snow-coloured; sea regimes colour by `t`.

**6.2 `_test_lod_far_field()` (headless, added to the `:26-62` runner).**
* Build one tile per ring via `FarMeshBuilder` raw arrays; assert invariant 1 exactly
  (float eq ≤ 1e-4) over all lattice points, and invariant 2 against
  `TerrainConfig.height_at + 1` (+ the corner-target walk surface via
  `surface_modifier`-style sampling) over ≥ 500 columns in the 192–320 band.
* Build the same tile twice; assert hash-identical arrays (invariant 5).
* Compute desired sets for the spawn point and for a simulated 500 m path in 64 m steps;
  after each step drain the queue synchronously (test hook `drain_for_test()`), assert
  invariants 3 + 4, assert the no-hole ordering (stale tiles present until replacements
  commit), and assert eviction keeps the live count bounded.
* Palette pins: a `find_mountains()`-located peak column above y=96 → `color_of(snow_block)`;
  a deep-ocean column → water colour; a `t ≥ 0.60` sea column → lava colour; a `t < −0.55`
  sea column → ice colour.
* Open-ocean collapse pin: an all-sea tile emits exactly 2 triangles.
* Soft perf pin (the `_test_collider_amortized` style): one 64-grid tile build guarded against
  pathological slowdown (≤ 75 ms headless — a generous ~2× ceiling over the observed 25–35 ms
  on the shared CI binary, so it never machine-flaps; the measured value is always printed, and
  the real per-frame control is `FAR_BUILD_BUDGET_MS` on device).

**6.3 Residual seam error, quantified (the number a reviewer should check on screenshots).**
Lattice points: exact (invariant 1). Between lattice points at ring 0 (4 m cells): linear
interpolation vs the true surface differs by ≤ detail amplitude (±1 block,
`terrain_config.gd:83`) + hills curvature (≪ 1 block over 4 m) ≈ **≤ 2–3 blocks worst-case
silhouette error at the seam** — the same order as the 26–40% fog contrast there
(LOD-RESEARCH §6.4.2). Anything worse than that on hardware is a bug, not a tuning problem.

**6.4 Phased build order (each phase = one PR-able branch off the feature branch;
gate = verify green on both paths + `/steelman` + the live-web check, per the
non-negotiable "live demo outranks feature depth").**

| Phase | Scope | Effort | Exit gate |
|---|---|---|---|
| **0 — Spike** | Static one-shot build of all 4 rings around spawn (no streaming, no verify), §3.4 fog, §3.5 camera, `?far=1` gate. Deploy live. | 1–2 d | 60 FPS on an Intel-HD-class desktop browser; load regression < 1.5 s; mountains visible at 2–3 km; fog banding + draw-call headroom judged acceptable in screenshots (the two real unknowns, §7.1). |
| **1 — Streaming** | `FarTerrain`/`FarMeshBuilder`/`FarPalette` as specified: desired-set + queue + budget + no-hole + eviction + open-ocean collapse + prewarm hook + `_test_lod_far_field`. Default ON. | 3–5 d | verify green (module + fallback + headless); soak a 2 km walk/fly path with the PerfHUD (`main.gd:57-59`) showing no frame > 33 ms attributable to far builds. |
| **2 — Visual polish** | Fog-curve tuning on real hardware; palette A/B at the seam (incl. the §2.1 point-vs-averaged sampling A/B and the §2.2 waterline lip); banding assessment; screenshot set for DESIGN.md. | 2–4 d | Seam judged acceptable in motion (worst case: flying along the boundary looking down); no palette mismatch calls against near-field screenshots. |
| **3 — Optional (evaluate, don't commit)** | (a) CDLOD vertex-shader morph iff Phase 2 shows popping; (b) `VoxelLodTerrain` blocky **mid-field** spike (research §5.1/§7 — measure single-worker contention first); (c) background-`Thread` builds + pthread-pool bump via `scripts/build.sh` iff profiling demands; (d) tree impostors (MultiMesh billboards off `TreeGen`'s deterministic lattice). | per item | Each item needs its own measured justification; none blocks shipping Phases 0–2. |

Note (supersedes LOD-RESEARCH §8.3): the Mountains biome has **landed on `main`**
(`terrain_config.gd:97` `MOUNTAIN_AMPLITUDE = 92`, `:141` `MAX_SURFACE_Y = 116`, `:129`
`VIEWER_VERTICAL_RATIO = 0.5`) — the far field's payoff is available now; no branch
sequencing constraint remains.

---

## Decision 7 — Risks, hard limits, and fallbacks

**7.1 Fog/colour banding (the #1 unknown — Phase 0 tests it).** The Compatibility renderer's
lower colour precision over a 2,635 m gradient can band (Godot's documented 3D rendering
limitation; LOD-RESEARCH §6.5). Fallbacks, in order, all inside this design: steepen
`fog_depth_curve` (compresses the gradient), pull `fog_depth_end` in to ~2,000 (costs
horizon contrast, not architecture), or reduce `R_FAR` to 2,048 (drop ring 3; every budget
shrinks). No fallback requires touching the tiling, palette, or seam machinery.

**7.2 Depth-buffer precision at 3 km (quantified).** With camera `near = 0.05` and 24-bit
depth, resolution at distance d is ≈ d²/(near · 2²⁴): **≈ 0.08 m at 256 m, ≈ 9 m at
2,750 m**. Consequences, already designed for: (a) the seam bias (1.5/0.25 m) is resolvable
where it matters (≤ 256 m); (b) NO two far surfaces may rely on sub-9 m separation at
distance — this is why the sea is a composite surface, not a disc over floor tiles (§2.2);
(c) far-vs-far tile joins are coplanar or skirted, never near-coplanar overlaps. If Phase 0
still shows far-field shimmer, the lever is camera `near` 0.05 → 0.1 (halves far-plane
error; verify first-person block reach still renders — the aimed-block outline sits at
≥ 0.4 m). No reversed-Z or depth tricks exist in Compatibility; do not attempt them.

**7.3 Draw-call headroom (ANGLE→D3D11).** +60–75 opaque draws on top of the near field's
~200–500 (`module_world.gd:178-188`). Phase 0 measures on the PerfHUD. Fallback: raise
ring-2/3 tile size to 2,048 m (halves outer-ring draw count at identical tri count) —
a table edit, not a redesign.

**7.4 Web memory.** ≈ 11–14 MB GPU + transient per-tile CPU arrays (~200 KB), bounded by
§4.4 caps against a browser heap already holding the near field (research A2 alternatives
cost *tens* of MB of voxel buffers — the analytic layer is the cheap option). Eviction is
immediate; there is no cache to leak.

**7.5 Main-thread stutter on weak machines.** The §2.6 budget is the control; the failure
mode is a slower-refining horizon, never a hitch (§4.3). If 3 ms proves too greedy on the
Intel-HD baseline, drop `FAR_BUILD_BUDGET_MS` to 2 — the queue absorbs it.

**7.6 Scope creep (named so it can be refused).** No DH-style aggregation/persistence
(LOD-RESEARCH §5.5 — we have no data-dependent far field yet); no Terrain3D/HTerrain
dependency (§5.4); no `VoxelLodTerrain` in the critical path (§5.1 — Phase 3b spike only);
no distant edits (the `invalidate_tiles` stub is the designed seam for that future). The
far field renders `height_at`; anything that isn't a pure function of `height_at` +
`column_profile` is out of scope for this ADR.

**7.7 Feasibility statement.** Every mechanism above is plain vertex/fragment-shader-era
rendering: static opaque indexed triangle meshes, one standard material, depth fog. Nothing
is gated on compute, tessellation, geometry shaders, mesh LOD imports, or occlusion baking —
**there is no part of this design that is infeasible in the GL Compatibility / WebGL2
renderer.** The Phase 0 spike exists to measure quality (banding, headroom), not
possibility.

---

## Appendix A — Locked constants (single source: `far_terrain.gd`)

```
ENABLED              := false (Phase 0) → true (Phase 1)
R_FAR                := 3072.0
INNER_HOLE           := 192.0            # RENDER_RADIUS_BLOCKS − 64
RING_TABLE           := [                # {outer_m, cell_m, tile_m, grid}
                          {320.0,  4.0,  256.0, 64},
                          {768.0,  8.0,  512.0, 64},
                          {1792.0, 16.0, 1024.0, 64},
                          {3072.0, 32.0, 1024.0, 32} ]
BIAS_LAND            := 1.5              # blocks below the walk surface (height_at + 1)
BIAS_SEA             := 0.25             # far sea at SEA_LEVEL + 0.9375 − this = 0.6875
SKIRT_CELLS          := 4                # skirt depth = 4 × ring cell
FAR_RECENTER_STEP    := 64.0             # m of XZ movement before re-evaluating the set
FAR_BUILD_BUDGET_MS  := 3.0              # main-thread sampling budget per frame
MAX_COMMITS_PER_FRAME:= 1
FAR_MAX_TILES        := 120              # hard caps — trim outermost-first, warn
FAR_MAX_TRIS         := 600_000          # raised from 450k for double-sided skirts (§1.4)
FAR_MAX_DRAWS        := 96
FAR_CAMERA_FAR       := 3840.0           # player.gd:66 override when ENABLED
FOG_BEGIN / END / CURVE := 115.0 / 2750.0 / 0.38   # applied in main.gd when ENABLED
```

## Appendix B — Code references relied on above

`terrain_config.gd`: SEED `:30`, SEA_LEVEL `:46`, LAVA_SEA_T `:51`, WATER_SURFACE_HEIGHT
`:78`, DETAIL_AMPLITUDE `:83`, MOUNTAIN_AMPLITUDE `:97`, RENDER_RADIUS_BLOCKS `:115`,
VIEWER_VERTICAL_RATIO `:129`, MAX_SURFACE_Y `:141`, B_* `:153-162`, warm_up `:317-320`,
height_at `:392-396`, column_profile `:443-459`, _with_snow_state `:556-566`,
_corner_targets `:620-634`, _biome_top `:1018-1035`, _underwater_floor `:1037-1048`,
_sea_liquid_kind `:991`.
`main.gd`: SKY_COLOR `:8`, prewarm wiring `:61-72`, fog `:89-98`.
`module_world.gd`: setup/warm_up `:109-120`, max_view_distance `:177`, mesh_block_size
draw-call rationale `:178-188`, generate_collisions `:191`, attach_viewer `:930-939`,
area_meshed `:948-951`, generator `lod != 0` early-out `:1059-1060`.
`world_manager.gd`: _ready `:63-82`, on_player_ready `:106-108`, update_streaming
`:112-116`, initial_view_meshed `:123-126`, analytic queries `:786-1030`.
`player.gd`: camera.far `:66`, update_streaming call `:160-164`.
`project.godot`: gl_compatibility `:27-28`, voxel thread caps `:63-65`, main mesh-apply
budget `:72`.
`block_catalog.gd`: color_of `:428`. `block_materials.gd`: vertex_color_use_as_albedo
`:111`, `:121`. `climate_model.gd`: ALT_ZERO_Y `:25`, surface_temperature `:47`.
`shader_prewarm.gd` (`godot/src/tools/`): begin `:131`, spawn_warmups `:143+`.
`verify_feature.gd`: test runner `:26-62`.
