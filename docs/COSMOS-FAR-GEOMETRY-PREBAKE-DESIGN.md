# COSMOS — Far-GEOMETRY prebake: mountains visible from orbit/distance

Status: DESIGN (analysis only — no production code). Branch `deploy/cheats-eyeball`.
Author: Fable (shell). Follows COSMOS-BACKGROUND-PREBAKE-DESIGN.md (the colour-skin prebake, now live).

User ask: the far terrain GEOMETRY stays flat from orbit — mountains only appear on descent when
the view-local relief kicks in. Prebake far geometry so mountains show from orbit/distance too.

Related: [[COSMOS-BACKGROUND-PREBAKE-DESIGN]], [[COSMOS-FAR-SMOOTH-V2-DESIGN]],
COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN (the shelved S3-S5 ladder), patch 0012 (bake_smooth_tile),
memories `voxiverse-far-smooth-geometry`, `voxiverse-block-lod-design`, `voxiverse-never-oom-web`.

---

## 0. TL;DR

- **Q1 — what is flat from orbit and why**: the planet at orbit is the FacetFarRing SHELL — per-facet
  **CELLS=4 grids (5×5 nodes, ~104-block cells**, `cube_sphere.gd:481`) with radial relief at the
  nodes (`facet_far_ring.gd:5,28` — relief IS emitted) + the flat colour skin. Mountains
  (~92-block amplitude over ~1250-block wavelength) read flat for THREE stacked reasons:
  (a) 104-block node spacing under-samples + attenuates them; (b) the shell shades by the RADIAL
  normal only (`voxi_shade(normalize(wp−centre))`) — **zero slope shading**, so even sampled relief
  has no visual contrast; (c) real relief geometry appears only in the `FP_SMOOTH_V2` annulus,
  **hop 2..4 around the active facet** (`facet_smooth_v2.gd:327-369`) — view-local by design, gone
  beyond ~4 facets. From true orbit, (b) dominates: 92 blocks on a 6371-radius planet is angularly
  tiny — on real Earth too, mountains read from orbit via SHADING, not parallax.
- **The design is therefore TWO layers, one data source**:
  - **G1 (the orbit win, geometry-free): live slope shading from a prebaked global NORMAL/SLOPE
    layer** — mountains become visible from ANY distance the way they actually are from orbit.
  - **G2+G3 (the descent win): a bounded whole-planet coarse HEIGHT layer (~7.5 MB) + a
    view-dependent relief mesh built FROM it** — real geometry to the horizon at mid-altitude,
    with instant (no-worldgen-sampling) tile builds, welding under the V2 annulus.
- **Q4 — the make-or-break numbers**: height data **7.5 MB** (i16, 33²/facet ≈ 13-block cells);
  slope layer **+13.5 MB** (RG8 packed normal at the skin's 64²/facet) or 0 if derived from G2 in
  the bake; relief mesh **transient ≤ 16 MB** (bounded tile budget, same class as the shipped
  smooth ladders). Worst-case total **~37 MB** — vs the infeasible ~158 MB full-res globe.
  **FITS NEVER-OOM easily** (live heap 412-495 MB of 2048).
- Bake rides the SAME `FP_BG_PREBAKE` governed pacer; builds go through `bake_smooth_tile`
  (patch 0012), which ALREADY returns per-node relief for arbitrary corner_dirs+cells — the C++
  fast path exists, flag currently OFF but engine-resident.

---

## 1. Q1 — the orbit render path and why it is flat (file:line)

At orbit the visible planet = FacetFarRing shell (whole visible hemisphere; block-LOD megablock
tiers are deploy-retired, skin-far config). Per facet the shell emits a **CELLS=4 grid** — 5×5
nodes, cell ≈ 417/4 ≈ 104 blocks (`cube_sphere.gd:481`: "the coarse 5×5 (CELLS=4)"); the near/active
set gets BACKSTOP_CELLS=16 dense grids (~26-block cells, `cube_sphere.gd:300`), still sunk-backstop
semantics. Node positions DO carry radial relief (`facet_far_ring.gd:28` `RELIEF := 1.0` blocks per
g−SEA_LEVEL; the FS1 FP_SHELL_WELD radial emission) — **the shell is a heightfield, not literally
flat** — but:

1. **Sampling**: 104-block cells across ~92-block-amplitude, ~1250-block-wavelength mountains →
   peaks land between nodes, amplitude attenuates; what survives is a gentle bump.
2. **No slope shading**: every shell fragment shades with the planet-RADIAL normal
   (`_SHELL_ABS_TEX_LIGHT`, `facet_far_ring.gd:4221`), so a mountain flank and flat plain at the
   same latitude are the SAME brightness. Relief without shading contrast is invisible at distance —
   this is the dominant term from orbit (92 blocks is sub-pixel-scale geometry at alt ≥2000 anyway).
3. **Real relief is view-local**: `FP_SMOOTH_V2` (V2_CELLS=52, 8-block cells) builds only the
   hop-[2..4] annulus (~35-40 tiles) around the active facet (`facet_smooth_v2.gd:327-369`) —
   by design (the whole-planet mesh was the infeasible 158 MB). Beyond hop 4: shell only.

So "mountains appear on approach" = the V2 annulus arriving. To make them show from orbit/distance
we need (i) shading contrast at all distances (cheap, data-only) and (ii) more relief-mesh reach at
mid-altitude (bounded, view-dependent).

## 2. Q3 — latent machinery audit (what already exists)

- **`bake_smooth_tile` (patch 0012, `FP_CPP_SMOOTH_BAKE`, engine-resident, flag OFF)**: takes
  `(corner_dirs, r_datum, cells)` → per-node `dir/g/biome/temp/relief/pos/planar/bnrm` PackedArrays,
  byte-equal to the GDScript FarDensity law (gate G-CSB-EQ 407/0 historically). **It is
  resolution-agnostic — pass any facet's canon corner dirs + any `cells` and it returns exactly the
  coarse global height tile we need.** This IS the bake kernel for G2; no new C++.
- **FarDensity + FacetSmoothTier (task #78/#80, shelved ladder)**: the S3/S4/S5 view-dependent tier
  machinery exists and its budgets were proven (289 tiles = 13.4 MB < 96 MB cap); its FAILURE mode
  was warmup cost (per-tile worldgen sampling convoy) — which G2's prebaked data eliminates (tile
  build becomes a pure array→mesh transform, no `profile_at_dir` calls at build time).
- **FP_SMOOTH_V2**: the shipped, user-validated near-relief annulus; stays the fine layer on top
  (draw-over, no exclusion — the V2 no-seam lesson).
- **FP_SMOOTH_V2_LIT**: stripped for wrong slope shadows — that was per-cell FACE-normal shading of
  the V2 mesh. G1 is different: a smooth per-texel normal from the height DATA (central differences
  on a 13-block grid), far less noisy than per-cell mesh normals; still the same risk class, so G1
  ships in two steps (§3.1) with the safe variant first.

## 3. The design — three flags, one data source

### 3.1 G1 `FP_SKIN_RELIEF_SHADE` — mountains from ORBIT (shading, zero geometry)

Bake a whole-planet slope layer next to the colour skin and let the shell shader modulate the skin
colour by slope — mountains gain light/dark flanks at every distance, exactly how orbit imagery
reads relief.

- **G1a (safe first step): slope-magnitude shade** — one L8 layer at the skin's 64²/facet:
  `shade = f(|∇h|, curvature)` (hillshade/AO-style, sun-agnostic — valleys and steep flanks darken).
  No directional term ⇒ CANNOT produce wrong-sun shadows (the V2_LIT failure class is structurally
  excluded). Cost: **+13.5 MB** (24 sub-pages × 768² L8, CPU+GPU same as fine tier halves).
- **G1b (optional upgrade, gated separately): packed coarse normal (RG8, +27 MB)** — shader
  reconstructs the surface normal and runs the EXISTING `voxi_shade(n_relief, sun_dir)` with it →
  correct live sun-tracking relief lighting at all distances. Ship only after G1a eyeballs clean;
  carries the V2_LIT risk (wrong-looking directional shadows) so it must be independently
  rollback-able.
- Both bake in the SAME pass as the colour skin (the pacer already walks every facet; the height
  samples come from the same `bake_smooth_tile`/`sample_columns` grid — near-zero extra bake cost).

### 3.2 G2 `FP_GLOBAL_RELIEF_DATA` — the bounded whole-planet coarse DEM

One always-resident height layer: **i16 relief (blocks, 1-block vertical quantum) at 32 cells/facet
edge (33² nodes ≈ 13-block horizontal pitch)**:

```
3456 facets × 33² nodes × 2 B = 7.5 MB   (CPU PackedInt32/16 pages; no GPU copy needed — consumed by mesh builds)
```

13-block pitch resolves the 1250-block mountain wavelength ~96× — recognizable massifs, ridges,
valleys; 92-block peaks fully captured. (64 cells/facet = 29 MB would be sharper but is beyond what
mid-altitude viewing distinguishes; 32 is the knee.) Baked facet-by-facet by the `FP_BG_PREBAKE`
pacer via `bake_smooth_tile(corner_dirs(fid), r_datum, 32)` — C++-fast (~ms/facet), governed,
view-first, imperceptible (§5). Edit-invariant (relief is terrain-law only, like the skin's terrain
path) — no edit cascade needed at this resolution (a player dig is sub-texel).

### 3.3 G3 `FP_ORBIT_RELIEF` — the view-dependent coarse relief mesh (the descent win)

A whole-planet MESH is impossible (33² nodes × 3456 ≈ 3.8 M verts resident; the 158 MB lesson). The
mesh stays VIEW-DEPENDENT, the DATA global:

- Resurrect the S-ladder discipline with V2's proven policies: residency a pure function of
  `active_fid` (hop-BFS annulus, sticky, never camera-turn-coupled), draw-over the shell (NO
  exclusion — the V2 no-seam law), whole-surface ArrayMesh commits (no RS region writes — the
  ANGLE-crash lesson).
- Rings: hop ≤ 4 → owned by FP_SMOOTH_V2 (unchanged, 8-block cells); hop 5..~12 → G3 tiles at
  32-cell pitch (13-block) built STRAIGHT from the G2 arrays (zero worldgen sampling at build time —
  the ladder's warmup convoy is structurally gone); beyond → shell + G1 shading carries it (at that
  angular size shading IS the relief).
- Budget: ~150-250 tiles × 33² verts ≈ 8-16 MB mesh bytes, tile-count-capped (ledgered, LRU on the
  annulus frontier). ≤3 draws (per-ring merged ArrayMesh, the shipped pattern).
- From ORBIT (off-surface): a nadir-cap set at the same pitch, capped to the same tile budget —
  visible limb relief + shaded nadir; the scaled-body clamp already handles placement.

### 3.4 Q6 — the descent continuum (no pop)

All three layers derive from the SAME `profile_at_dir` law through the SAME canon corner dirs
(`facet_corner_dirs`, the P0 weld canon), so heights agree BY CONSTRUCTION wherever layers meet:

```
orbit:    shell (radial-lit skin) + G1 slope shade            [mountains read via shading]
mid-alt:  + G3 coarse relief mesh (hop 5..12, 13-block)       [real geometry to the horizon]
near:     + FP_SMOOTH_V2 annulus (hop 2..4, 8-block) OVER G3  [fine relief, draw-over]
surface:  + near voxels OVER everything                       [full res]
```

Draw-over ordering (near > V2 > G3 > shell) means every transition is a REFINEMENT on top of an
already-agreeing coarser surface — no exclusion holes, no boundary steps (the exact mechanism the
user validated for V2-over-shell). G3→V2 handoff: V2 tiles simply cover hop ≤4; the G3 tile
beneath is 13-block vs V2's 8-block of the same law — sub-cell discrepancy ≤ one relief quantum,
hidden by draw-over. No geomorph needed.

## 4. Q4 — the memory budget (make-or-break, QUANTIFIED)

| Layer | Bytes | Resident? |
|---|---|---|
| G2 global height data (i16, 33²/facet) | **7.5 MB** | always (CPU only) |
| G1a slope-shade layer (L8, 64²/facet, CPU+GPU) | **13.5 MB** | always |
| G3 relief mesh (view-dependent, capped) | **≤16 MB** | transient, ledgered |
| G1b optional normal layer (RG8) | +27 MB | only if G1b ships |
| **Total (G1a+G2+G3)** | **~37 MB** | |

Context: colour-skin prebake = 27 MB; live peak heap 412-495 MB; ceiling 2048 MB. **~37 MB ≈ 1.8% of
ceiling — FITS NEVER-OOM with no compromise.** The 158 MB infeasibility was a fully-meshed
full-res globe; this design keeps the GLOBAL part as cheap DATA (7.5 MB) and meshes only the view.

## 5. Q5 — pacing: the same governed pacer

G2 (and G1's bake pass) ride `FP_BG_PREBAKE` unchanged: dispatch only on healthy frames
(proc_ms < ~22 ms), ≤1 background slot on-surface, view-cone-first then planet sweep. Per-facet cost
via `bake_smooth_tile` is milliseconds (C++), so the global DEM completes well inside the skin
sweep's own timescale; G3 tile builds are array→mesh transforms on the worker (no worldgen), commits
paced ≤K tiles/frame (the rate-cap lesson from REV7). No new pacer machinery.

## 6. Gates

- **G-GP-OFF**: all flags false ⇒ byte-identical; FLAT verify_feature 6042/0.
- **G-GP-DATA-EQ**: G2 node heights == `FarDensity.node_at` heights at the same canon dirs (≤1
  quantum) — the weld guarantee (reuses the G-CSB-EQ harness).
- **G-GP-BYTES**: G2+G1a+G3 ledger ≤ 40 MB cap; G3 tile count ≤ cap under a residency storm.
- **G-GP-WELD**: G3↔V2 and G3↔G3 shared-edge verts bit-equal (canon corner dirs), G3 under V2
  never protrudes (draw-over containment).
- **G-GP-PACE**: injected hot frame ⇒ zero G2 dispatches + zero G3 commits that frame.
- **Live A/B (arbiter)**: orbit nadir — mountains READ (shaded massifs, not flat colour);
  mid-alt descent — relief to the horizon, no pop at the V2 frontier; fps floor + heap flat;
  G1b (if tried) — no wrong-sun shadow complaints, else instant rollback of that flag alone.

## 7. Bottom line

- **Flat-from-orbit = the CELLS=4 shell**: relief is emitted but under-sampled (104-block cells),
  UNSHADED by slope (radial normal only), and real relief mesh is hop-2..4 view-local.
- **Representation**: global coarse DEM as DATA (i16, 13-block pitch, **7.5 MB**) + slope-shade
  layer (**13.5 MB**) + view-dependent relief mesh from the data (**≤16 MB** transient) —
  **~37 MB total, NEVER-OOM verdict: FITS** (1.8% of ceiling; no bounded compromise needed).
- **Flags**: `FP_SKIN_RELIEF_SHADE` (G1a safe / G1b normal-map upgrade separately gated),
  `FP_GLOBAL_RELIEF_DATA` (G2), `FP_ORBIT_RELIEF` (G3); all bake via the existing `FP_BG_PREBAKE`
  pacer and the already-shipped `bake_smooth_tile` C++ kernel (patch 0012 — flip `FP_CPP_SMOOTH_BAKE`
  on for the bake path).
- **The honest physics note**: from TRUE orbit, shading (G1) is what makes mountains visible —
  geometry there is sub-pixel; G3's geometry pays off from mid-altitude down, welding into V2.
  Ship order: G2 (data) → G1a (orbit look, safe) → G3 (descent reach) → G1b (optional).
