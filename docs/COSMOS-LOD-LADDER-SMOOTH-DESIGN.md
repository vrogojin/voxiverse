# COSMOS LOD-LADDER SMOOTH — root cause + fix design (task #107)

**Symptom (live, user-reported):** a mountain looks smooth from far away; on approach it turns
into a stair-stepped structure of very large blocks before finally becoming full-res near
blocks. Repro: facet 772, NAV `-30970,50,7161` (BCI ≈ `[-5606,1395,-2795]`, |p| = 6417.6 = R+47),
alt 47, hill directly ahead. Screenshots `lod-0.jpg`/`lod-1.jpg`.

**Verdict up front:** the giant blocks in the repro are the **FP_M2_LOD FacetLodMesher megablock
mesh at tier ℓ3/ℓ2 (8/4-block cells) on facet 797 (hop 2, peak at 474 blocks)**, drawn at true
height OVER the resident FacetSmoothV2 smooth tile it protrudes through — there is **no
arbitration between the M2 blocky tier and the smooth tier**. A second, worse rung of the same
bug exists on hop-0/1 facets (active + pool), where **neither** SmoothV2 **nor** M2 covers and
the frontmost tier beyond the 128-block near radius is the blocky far-ring backstop at
**27-block cells**. The deployed ladder is *non-monotone*: fidelity **drops** as you approach.

The FP_BLOCK_LOD / _RINGS / _GLOBAL pyramid (task #74/#76) is **not deployed** — none of those
flags are in the live export flag list (`deploy_cheats.sh` CS_FLAGS; verified absent) — so the
block-LOD ladder and its level law are *not* the culprit.

---

## 1. The live rendering ladder (as served, flags from deploy_cheats.sh CS_FLAGS)

Live-relevant flags ON: `FP_M2_LOD`, `FP_NB_FULLRES`, `FP_BLOCKY_FARRING`,
`FP_FARRING_FULL_COVER`, `FP_FARRING_UNCOVERED_TRUE`, `FP_FARRING_ACTIVE_NOBLACK`,
`FP_SMOOTH_V2`, `FP_SMOOTH_V2_REACH`, `FP_ORBIT_RELIEF`, `FP_CTRL_ADAPTIVE`.
OFF (relevant): `FP_BLOCK_LOD*`, `FP_FAR_SMOOTH`, `FP_MID_DENSE`, `FP_FARRING_LIMB_DENSE`,
`FP_SMOOTH_V2_EXCL_BLKLOD`, `FP_SMOOTH_V2_LIT`.

On the surface, by facet class (facet edge ≈ 436 lattice cells ≈ 417 blocks):

| Facet class | Geometry tiers present | Frontmost visible | Cell pitch |
|---|---|---|---|
| Active (hop 0), r ≤ 128 | near VoxelTerrain full-res | full-res | 1 |
| Active (hop 0), r > 128 | far-ring blocky backstop only | **backstop megaslabs** | **≈27 blocks** |
| Hop 1 (4 edge neighbours; live pool under FP_NB_FULLRES) | pool blocks near seam (~64–112) + far-ring backstop | full-res near seam, **backstop megaslabs** beyond | 1 / **≈27** |
| Hop 2..4, in frustum | far-ring 109-block blocky (min-sunk) + SmoothV2 smooth tile + **M2 megablock mesh ℓ1..3** | **M2 blocky** (protrudes over smooth) | **2/4/8 blocks** |
| Hop 2..4, out of frustum / beyond | far-ring quad + skin/fine-map textures | textured quad (reads smooth) | 109-block geo, ~1-block texture |
| Orbit | FacetOrbitRelief (on-surface suspended) | — | — |

Proof points:

- **SmoothV2 never covers hop 0/1.** `hop_annulus` appends a facet only `if hop >= hop_b`
  (`godot/src/world/facet_smooth_v2.gd:194`), `hop_b = V2_HOP_B = 2`
  (`godot/src/cosmos/cube_sphere.gd:1445`, instance `_hop_b` never modified —
  `facet_smooth_v2.gd:335,383`). Live reach: hop 2..4 (`FP_SMOOTH_V2_REACH`,
  `V2_HOP_H_REACH := 4`, cube_sphere.gd:1462). Probe: annulus(772) = 36 facets, contains none
  of {772, 796, 748, 773, 771}.
- **M2 never covers hop 0/1 either.** `_recompute_wants` skips
  `if fid == _active_fid or live.has(fid)` (`godot/src/world/facet_lod_mesher.gd:295`); under
  `FP_NB_FULLRES` all 4 edge neighbours are live pool ⇒ skipped. `request()` also hard no-ops
  for active/pool (`facet_lod_mesher.gd:405-407`).
- **The hop-0/1 gap is filled by the far-ring backstop at 27-block pitch.** Backstop facets
  (active ∪ excluded/pool, `FP_FARRING_FULL_COVER`) emit at `BACKSTOP_CELLS := 16`
  (`cube_sphere.gd:335`; emit path `facet_far_ring.gd:3455`) ⇒ 436/16 ≈ **27-block cells**,
  rendered as flat-topped blocks under `FP_BLOCKY_FARRING` (`facet_far_ring.gd:3959-3964`),
  at TRUE (un-sunk) height for cells not covered by the near field
  (`FP_FARRING_UNCOVERED_TRUE`). Non-backstop facets emit at `CELLS := 4`
  (`facet_far_ring.gd:19`) ⇒ ≈109-block cells (those stay min-contained *below* smooth/M2).
- **M2 tier selection (SSE).** `ℓ_c = log2(τ·2·d·tan(fov/2)/vh)`, τ = `LOD_TAU_PX := 3.0`
  (`cube_sphere.gd:1913`), tiers clamped 1..3 = 2/4/8-block cells
  (`facet_lod_mesher.gd:230-238`); hysteresis holds the current tier while
  ℓ_c ∈ [cur−0.25, cur+1.25] (`:244-252`, `LOD_HYST_BAND := 0.25`).
- **Near radius:** 128 blocks faceted (`near_render_radius()`, cube_sphere.gd:2098).

## 2. Repro proven (headless probe, `src/tools/probe_lod_band.gd`)

- Player BCI dir → `facet_of_dir` = **772**; lattice `[-30969.4, 49.3, 7161.9]` (matches NAV).
- Facet 772 dom `(-31084,7124)..(-30649,7551)` = 436×428 cells; seam distances: 27.3 (→773),
  103.4 (→748), 274.5 (→796), 382.5 (→771) — player stands near the 773/796 corner.
- The hill: all cells with g ≥ 60 within 1200 blocks lie on **fid 797** (hop 2; edge-neighbour
  of both 773 and 796, diagonal to 772), peak g = 72 at **dist ≈ 469–483**, biome 9 (stone —
  the grey slabs).
- 797 centre distance 506 ⇒ ℓ_c = 2.11 (vh=540 capture geometry) / 1.11 (vh=1080): desired
  tier ℓ2 or ℓ1, *not* held at ℓ3 by hysteresis — but see §3.2 for why ℓ3 lingers anyway.
- Screenshot silhouette scan (grey-mask column tops, 400..580 px): risers of 2–8 px and
  benches of 6–15 px ⇒ **≈4–11-block steps at 474 blocks** — exactly M2 ℓ2/ℓ3 megablock
  quantization (8-block steps + merged benches); far too fine to be the 27-block backstop or
  109-block far cells, far too coarse to be near blocks. SmoothV2 (continuous chords) cannot
  produce flat-top/vertical-riser silhouettes on a slope.

## 3. Root cause (three interacting laws)

### 3.1 No blocky↔smooth arbitration in the hop-2..4 band
SmoothV2 explicitly "draws OVER the shell — no emit-exclusion" (`facet_smooth_v2.gd:17`) — but
that contract was written against the *far-ring shell*, whose blocky cells are corner-**MIN**
decimated and therefore sit *below* the smooth chords by construction. The M2 mesh is not
min-contained: it is a real decimated voxel mesh at stride 2^ℓ whose megablock tops round the
sampled surface **up as well as down**, so it protrudes through the smooth tile wherever
decimation rounds up (ridges especially). Wherever M2 holds a mesh, the player sees blocky —
the resident smooth tile underneath is wasted. No exclusion law exists in either direction:
`_recompute_wants` (`facet_lod_mesher.gd:276-322`) never consults smooth residency; the only
existing arbitrations are LAW R-E (block-LOD ladder ↔ old smooth tier, `FP_FAR_SMOOTH`-wired
only, `facet_block_lod_ladder.gd:37-46`) and V2-3b `FP_SMOOTH_V2_EXCL_BLKLOD` (smooth ↔ blocky
*far-ring*, OFF live, cube_sphere.gd:1469) — neither touches M2.

### 3.2 The M2 tier law is coarse-biased in exactly the approach band
- τ = 3 px *tolerates* visibly chunky megablocks by design.
- Distance is measured to the **facet centre** (`facet_lod_mesher.gd:297-298,313`): a mountain
  on the near edge of a 436-block facet is judged up to ~300 blocks farther than it is
  (771: centre 608 ⇒ ℓ2, near edge ~380 ⇒ ℓ1).
- Refinement finer than ℓ3 is an "idle-only luxury" (`facet_lod_mesher.gd:368-369`), one tier
  per pass (`:367`), under a native-second cost model `_EST_BUILD_S = {ℓ1:15, ℓ2:4, ℓ3:1}`
  (`:156`) and `LOD_QUEUE_MAX_EST_S := 30` (cube_sphere.gd:1915) — on web (×10–25 measured,
  [[voxiverse-gen-class-costs]]) an ℓ1 rebuild is minutes, so the approach band realistically
  lingers at ℓ3 = 8-block long after the SSE law wants ℓ1/ℓ2. Under controller relief,
  refinement of covered facets is skipped entirely (`:361-362`).

### 3.3 The hop-0/1 hole makes the ladder non-monotone
Active + pool facets are excluded from *both* smooth (§1) and M2 (§1), so beyond the 128-block
near disc / ~64–112-block seam band the frontmost tier is the 27-block blocky backstop — the
**coarsest** relief in the whole mid-field. Approach sequence toward a mountain:
textured-smooth (>frustum/far) → M2 ℓ3 8-block (hop 2, lingering) → **27-block backstop**
(facet joins the pool / becomes active) → full-res (near stream arrives). Fidelity is
non-monotone in distance; the user watches the mountain get *worse* while walking toward it.
This is inherent to the deployed ladder design (each tier shipped correct in isolation), not a
regression: FP_NB_FULLRES widened it (all 4 neighbours became pool ⇒ lost their ℓ1 M2 meshes,
falling to the 27-block backstop beyond the seam band).

## 4. Fix design — `FP_LOD_SMOOTH_LADDER` family (all `const := false`, byte-identical off)

Three independent sub-flags (each alone is byte-off safe; ship C1+C2 first, C3 second):

### C1 `FP_M2_SMOOTH_DEFER` — M2 defers to a resident smooth tile (fixes the repro band)
Where `FacetSmoothV2.is_resident(fid)` (public wrapper already exists:
`FacetFarRing.is_smooth_resident`, `facet_far_ring.gd:1047`), the M2 selector stops wanting
megablocks: in `_recompute_wants` (`facet_lod_mesher.gd:316`), skip stamping `_want[fid]`
**entirely** when the smooth query reports resident (RESOLVED 2026-08-11 with the parallel
#107 investigation, merged doc COSMOS-LOD-LADDER-MIDBAND-DESIGN.md: an earlier "allow ℓ1"
variant is WRONG — the progressive first-cover admits meshless facets at `max(target, 3)`
(`facet_lod_mesher.gd:363-365`) and refines idle-only, so an ℓ1 want re-materializes the ℓ3
steps under load; and no band exists where ℓ1-over-smooth is both visible (>~290 blk ⇒ 2-blk
≈ 1 px) and not already covered finer by the near field / pool band. A floor-bypass ℓ1 grant
stays a documented fallback pending a live A/B only). Skip-ALL also retires the 4.6 MB ℓ1
ledger exposure over the annulus. Un-wanted facets evict via the existing `_idle_sweep`
(`facet_lod_mesher.gd:386-395`) — memory *returns*. EVICTION-LATENCY CAVEAT: the want-skip
alone leaves an already-built ℓ3 mesh protruding through the smooth tile for
`LOD_IDLE_DEMOTE_S` after residency arrives — MEASURED 30.0 s (facet_lod_mesher.gd:35), so
immediate evict (or demote-to-quad) on the resident-set transition is REQUIRED, with
`_idle_sweep` as the race backstop; gate G-LAD-DEFER-EVICT (N1b, sibling branch) asserts the
mesh + bytes are freed on the transition itself. Never a hole: the far ring always backstops (min-contained below
smooth), and smooth residency on approach only ever *grows* under C3. Wiring: mirror the ladder's `set_smooth_query` Callable pattern
(`facet_block_lod_ladder.gd:37-46`) — `world_manager.gd` hands
`Callable(_facet_ring, "is_smooth_resident")` down through module_world to the mesher at setup
(same route the load controller already takes, `world_manager.gd:810,862`); Callable unset ⇒
shipped path verbatim.
**Bytes: ≤ 0** (drops resident ℓ2/ℓ3 meshes over the smooth annulus). Draws/prims: fewer.

### C2 `FP_M2_EDGE_DIST` — nearest-point distance for the SSE law
Feed `sse_lc` the distance to the **nearest point of the facet's planar quad** (clamp the
camera onto the quad spanned by the 4 corners `_facet_render_corners` already computes,
`facet_lod_mesher.gd:307`) instead of the centre (`:313`). Kills the ~300-block coarse bias
for near-edge mountains; hysteresis unchanged (no thrash). **Bytes: 0.** Off ⇒ `:313` verbatim.

### C3 `FP_SMOOTH_V2_NEARFILL` — close the hop-0/1 hole with the smooth tier
`setup_instance` sets `_hop_b = 0` (flag-gated; off ⇒ `V2_HOP_B` verbatim,
`facet_smooth_v2.gd:335`), so the active facet + 4 edge neighbours carry smooth relief tiles
too. Their tiles are emitted **uniformly sunk by `V2_NEARFILL_SINK := 6.0`** (=`BACKSTOP_SINK`)
blocks radially (a new `sink` arg to `build_tile`, default 0.0 ⇒ byte-identical): constant
sink ⇒ no per-walk re-commit, never pokes through the near mesh (same clearance law the
backstop already proves, cube_sphere.gd:327-334), ≈1.6 px error at the 130-block hand-off.
Where terrain slopes, the sunk smooth chords still sit *above* the 27-cell min-decimated
backstop tops ⇒ mountains in the 128→seam band read as relief, not megaslabs; on flats the
un-sunk backstop wins by ≤ 6 blocks and both are flat ⇒ no visible change, stable depth
ordering (no shimmer). Crossing safety: residency with `hop_b=0` is a *superset* of today's —
a facet approaching through hop 2→1→0 **never loses** its smooth tile (this also deletes the
current unload-on-approach cliff at the annulus edge).
**Bytes: +5 tiles.** Tile ≈ (53² + skirt) verts × 40 B + 52²·6·4 B idx ≈ 190 KB
(`tile_bytes`, `facet_smooth_v2.gd:231-236`) ⇒ **+ ~0.95 MB resident**, annulus ledger
36→41 tiles ≈ 6.9→7.9 MB — bounded constant, NEVER-OOM safe. Commit: +14 % tiles on the
already-paced whole-annulus rebuild (live 14.5 ms avg after FP_SMOOTH_V2_PACE/_ASYNC_MERGE
⇒ ~16.5 ms, cadence unchanged). Draws: unchanged (one merged smooth mesh). Prims: +~27 K tris
(vs 1.2 M live).

### Rejected alternatives
- **(b) finer M2 levels / τ 3→1.5:** doubles linear resolution of every M2 mesh planet-wide —
  ×4 bytes and ×4 build seconds per tier at the same distance, on a web build where ℓ1 is
  already ~minutes; and blocky-4 at 400 blocks still reads blocky. Doesn't restore smooth.
- **(c) radii retune only:** cannot fix 3.1 (M2 protrudes over smooth at *any* radius split)
  nor 3.3 (no tier exists to retune into the hop-0/1 hole).
- **(d) smooth-over-blocky blend:** gl_compatibility, no depth-prepass / no HDR; a dither or
  alpha blend across two full terrain tiers is a new shader family + overdraw on the weakest
  target. The exclusion (C1) achieves the same look for free.

## 5. Gate plan (`src/tools/verify_lod_ladder.gd`, headless; pattern of verify_far_smooth.gd)

- **G-LSL-OFF (byte-identity):** all three flags false ⇒ FLAT `verify_feature.gd` unchanged
  (6042/0) + `G-V2-*` unchanged; no node/wiring constructed (Callable unset, `_hop_b`
  untouched, `build_tile(sink=0)` byte-equal to today's output on a sample facet).
- **G-LSL-DEFER (ON discriminates):** with a stubbed smooth-resident set {797} and the repro
  camera geometry, the want-classifier (factored pure) yields NO `_want[797] ≥ 2`; clearing
  the stub restores today's `_want[797]` (2 at vh 540). Asserts the frontmost tier in the
  repro band is the smooth tile, not an ℓ2/ℓ3 megablock mesh.
- **G-LSL-EDGE:** for the repro pose, `d_edge(771) ≈ 380 < d_centre(771) = 608` and
  `desired_tier` drops 2→1; monotonicity: `d_edge ≤ d_centre` for all facets; hysteresis
  transition count ≤ 1 per direction (existing G-M2-SEL sweep re-run under the flag).
- **G-LSL-NEARFILL:** `hop_annulus(772, 0, 4) ⊇ hop_annulus(772, 2, 4) ∪ {772,796,748,773,771}`
  (superset law — crossing never sheds a near tile); sunk-tile containment: every vertex of a
  `build_tile(fid, cells, gen, sink=6)` tile sits exactly 6 blocks radially under the
  `sink=0` twin.
- **G-LSL-LEDGER (NEVER-OOM):** 41-tile annulus total `tile_bytes` ≤ 12 MB hard assert
  (+5 tiles ≤ 1.3 MB over the 36-tile baseline); M2 ledger under C1 is monotonically
  non-increasing across a simulated want→defer→idle-sweep cycle (asserts the eviction path
  actually returns the bytes).
- **LIVE-EYEBALL-REQUIRED:** the protrusion claim (M2 over smooth) and the C3 flat-land
  no-change claim are z-buffer facts a headless gate can't see — one approach capture at
  ~800/470/250/130 blocks toward the same peak, flags A/B.

## 6. Injection points (exact)

| File | Change |
|---|---|
| `godot/src/cosmos/cube_sphere.gd` | `+ const FP_M2_SMOOTH_DEFER := false`, `FP_M2_EDGE_DIST := false`, `FP_SMOOTH_V2_NEARFILL := false`, `V2_NEARFILL_SINK := 6.0` (beside the V2 block, :1443-1469) |
| `godot/src/world/facet_lod_mesher.gd` | `+ var _smooth_query: Callable` + `set_smooth_query()` (mirror facet_block_lod_ladder.gd:40); C1 skip in `_recompute_wants` (:316); C2 nearest-point d (:313, reuse `_facet_render_corners`) |
| `godot/src/world/facet_smooth_v2.gd` | `setup_instance` `_hop_b = 0` under C3 (:383 pattern); `build_tile(..., sink := 0.0)` radial sink; instance hop map (annulus BFS already computes hop, :183-196) to pick sink for hop ≤ 1 tiles |
| `godot/src/world/world_manager.gd` / `module_world.gd` | wire `Callable(_facet_ring, "is_smooth_resident")` (far_ring:1047) into the mesher at setup, via the existing controller-forwarding route (:810,862) |

Perf risk summary: C1 strictly reduces work; C2 is arithmetic; C3 = +1 MB resident, +14 %
paced smooth-commit, +27 K prims, 0 draws — all bounded constants, no new shader, no HDR,
depth priority unchanged (near overdraws sunk smooth; smooth overdraws min-contained blocky;
never far-over-near).
