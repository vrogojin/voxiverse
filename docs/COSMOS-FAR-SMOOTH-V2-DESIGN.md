# COSMOS FAR SMOOTH V2 — uniform-pitch smooth annulus, block-exact per-cell colour

**Status: DESIGN (clean-slate reset). Author: Fable, 2026-08-05.**
Supersedes the residency/ladder machinery of `COSMOS-FAR-SMOOTH-GEOMETRY-DESIGN.md` (P1–P4 +
REV 2/3/5-driver/7-VISUAL rim); REUSES its proven substrate (P0 canon weld, `FP_CPP_SMOOTH_BAKE`
patch 0012, REV-7 slot-mesh commit model, the quiescence and gate lessons). Read that doc for the
full failure history; this one is the design that cannot repeat it.

User directive (verbatim): *"figure out how to re-introduce SMOOTH far terrain geometry, WITHOUT
misaligning the far rendered facets, and WITHOUT the ugly heightmap texture."*
Accepted baseline (user: "looks very good", must not regress): blocky far —
`FP_BLOCKY_FARRING` shell megablocks + block-LOD rings (`FP_BLOCK_LOD*`) + baked skin maps
(`FP_PLANET_MAP`/`FP_SKIN_BLOCK_EXACT`/`FP_FACET_TEX`).

---

## 0. Verdict up front

**Recommended architecture — three decisions:**

1. **Geometry: ONE uniform pitch, no ladder.** A smooth radial-heightfield shell at a single
   8-block pitch (C := 52 cells over the 417-block facet), covering a **sticky hop-annulus**
   `hop(fid, active_fid) ∈ [B..H]` (defaults B=2, H=4) around the active facet. No S2 collar, no
   S3/S4/S5 tiers, no snap plans, no exclusion handshake. Welds are bit-identical **by pure
   function** (P0 canon corners + one global pitch), so the entire misalignment/race class is
   structurally unrepresentable, not merely fixed.
2. **Colour: per-cell block-exact flat shading, zero textures.** Each 8×8-block cell is painted
   one crisp colour — `FarPalette.color_for(g, biome, temp)` of its own baked node (the same
   block-exact law the near terrain and the approved blocky far use) — carried on the cell's
   provoking vertex through a `flat` varying. No baked skin map ever touches smooth geometry;
   the "low-res image draped over smooth relief" look is impossible because there is no image.
3. **Coexistence: smooth is a mid-far band inside the approved blocky world.** Near voxels and
   the L1 blocky ring (`BLOCK_LOD_L1_OUTER_BLOCKS = 700` ≈ hop <2) stay untouched; the smooth
   annulus carries real relief from hop 2 to hop H (≈ 800–1900 blocks — the band where the
   shell's 104-block cells currently flatten every mountain); beyond H and at orbit the
   user-approved blocky shell + skin remain the picture. The blocky baseline is the frame;
   smooth fills its one relief gap.

Feasibility **GREEN** (every mechanism is already gate-proven or shipped); the single riskiest
unknown is aesthetic, not mechanical — §8.

---

## 1. Decoding the two constraints (the anti-failure contract)

### 1.1 "Without misaligning the far rendered facets"
The session produced facet-to-facet height steps from three roots: (a) the S2..S5 tier ladder —
different pitches meeting at facet borders, coarse chords dipping under fine relief; (b) the
stale-snap-plan race — a resident edge chord-snapped to a neighbour pitch that no longer existed
(async ordering; `FP_SMOOTH_SNAP_SELFHEAL` closed the eternal case, a transient heal window
remained); (c) reach extension multiplying tier frontiers.

**The structural cure is a theorem, not a patch.** A shared-edge weld is race-free iff every
boundary vertex is a pure function of data that is (i) immutable and (ii) independent of any
neighbour's *current state*. Under the ladder, a boundary vertex depended on the neighbour's
committed TIER — mutable, asynchronous ⇒ the race class existed by construction. Under ONE
global pitch, a boundary node is
`f(shared canon corner dirs [static FacetAtlas data], i/C [global const])` — nothing mutable,
nothing neighbour-dependent. Two facets compute the same edge node bit-identically (gate-proven:
G-FS-CANON/G-FS-WELD-EDGE, cross-face agreement to f64 rounding, both sides f32-narrow the same
f64 → still bit-equal). Therefore: **no snap plans, no weld refresh, no self-heal, no
transaction between neighbouring tiles — the machinery that raced is deleted, and with it every
state the race needed.** Build order, worker count, commit timing cannot matter because no tile
reads another tile.

### 1.2 "Without the ugly heightmap texture"
The shipped smooth tiles were painted by the baked skin (~6 blocks/texel base/band pages) — a
low-res *image*, bilinearly filtered, draped over smooth geometry: mis-registered, smeared,
reads as "terrain wearing its own satellite photo". The near terrain by contrast is coloured
per-BLOCK — crisp, quantized, registered to geometry.

**The cure: colour IS geometry.** Every smooth cell gets exactly one colour, computed from the
same `TerrainConfig` chain (`g`/`biome`/`temp` → `FarPalette.color_for`, the
`FP_SKIN_BLOCK_EXACT`-aligned block-colour law) at bake time, carried as a **flat varying** so
the fragment sees a hard-edged 8-block quantized paint — the far reads as *distant voxel
terrain* (8-block megacells with real relief), the same visual family as the approved blocky
ladder, only with continuous mountain silhouettes. There is no texture fetch, no filtering, no
registration error, no mip, no bake-convergence repaint — the failure mode has no substrate.
(The baked skin keeps its job on the blocky shell beyond H, where the user already approved it.)

---

## 2. Geometry decision — why uniform-res beats the alternatives

| Option | Verdict | Reason |
|---|---|---|
| **Uniform-pitch shell (CHOSEN)** | ✅ | Kills tier frontiers and the whole snap/race class by construction (§1.1); one slot topology ⇒ trivial REV-7 commit model; one draw; residency a pure function of `active_fid`. |
| Continuous geomorph LOD | ❌ | Morph state is a NEW async surface (per-vertex morph factors must agree across edges → the same neighbour-coupling we just deleted); per-frame vertex work on gl_compat; buys bytes we don't need at H=4 scale. Geomorph was already rejected once (node-superset argument) — this reset removes even the supersets it would morph between. |
| One distance-continuous global heightfield (non-facet) | ❌ | Abandons the facet-atlas canon that IS our proven weld; any crossing becomes a whole-mesh re-emit (the known 300–700 ms re-emit bomb class); per-facet tiles + slot mesh already render as ONE draw, so the "one continuum" goal is met visually without a new mesh topology. |

### 2.1 The numbers (R=6371, K=24, facet edge ≈ 417 blocks)
- **Pitch 8 blocks** (C=52): chord sagitta 8²/8R ≈ 0.0013 blocks — curvature invisible; relief
  is sampled at the same order as the near-field's visual grain at 800+ blocks distance
  (an 8-block feature subtends ≤ ~0.6° at the annulus's inner edge).
- **Heights are block-exact for free**: `node_at`'s `relief = (g − SEA_LEVEL)·1.0` with integer
  `g` — every smooth vertex sits exactly on a block-top height of the shared one-chain law. The
  equal-height law at every exposed boundary (the arc's LAW R-D, the user's #1 last time) holds
  **by construction**, not by an envelope/feather mechanism.
- **Tile** (indexed, shared verts): 53² = 2809 nodes + 4·53 skirt ≈ 3021 verts × 56 B ≈ 169 KB;
  16 224 + 1248 skirt idx × 4 B ≈ 70 KB ⇒ **≈ 0.24 MB/tile, 5.4k tris/tile**.
- **Annulus** hop ∈ [2..4]: 9² − 3² = 72 facets ⇒ **17.3 MB, ~390k tris, ONE draw**.
  (H=5: 112 facets, 27 MB, 605k tris — a live A/B stretch goal, one const.)
- Reach: outer edge ≈ 4.5 facets ≈ **1 880 blocks** — beyond the ground-level terrain horizon
  (√(2R·h_relief) ≈ 1 130 blocks for 100-high mountains, +√(2R·h_eye)), so from the surface the
  frontier is hidden by curvature; it becomes visible only at flight altitudes where the blocky
  far is the approved look and one facet is few pixels wide.

### 2.2 Rendering & residency (all reused mechanisms)
- **Slot mesh (REV 7 `FP_SMOOTH_SLOT_MESH` mechanism, now trivial):** ONE tier ⇒ ONE
  fixed-capacity surface (cap = 128 slots ≈ 31 MB GPU, fixed at creation, `custom_aabb` set,
  flags=0 uncompressed). A tile commit = engine-packed bytes
  (`mesh_create_surface_data_from_arrays`) + two `glBufferSubData` region writes (~1 ms);
  evict = blit the precomputed degenerate blob. Commit budget ~2 MB/frame, whole-event
  queueing. O(N) upload over a fill, no O(N²) re-pack, no tier-pair transactions (there are no
  tiers to move between — a facet is IN the annulus or not).
- **Residency = pure function of `active_fid`.** The annulus set changes ONLY at a facet
  crossing: ~2H+1 ≈ 9 tiles bake in (nearest-first, worker-paced), the trailing edge evicts
  after a dwell (blit-out). No camera coupling, no per-frame ranking, no SSE, no caps-vs-rank
  band: `_want` is literally `hops(active) ∈ [B..H]`. The Q1 idle-signature machinery reduces
  the driver to an O(1) check at rest — quiescence is trivial because nothing else exists.
- **No emit-exclusion, ever — smooth draws OVER the shell.** The shell keeps emitting all
  facets exactly as in the approved baseline (its own R4/R5 quiescence fixes stand untouched);
  the smooth surface draws above it. Safe by height law: the blocky shell megablock top is
  `min(cell) ≤ true` and the smooth surface is `true − ε_blk (1 block)` ≥ shell − its sink ⇒
  smooth strictly covers the shell inside the annulus with no z-fight (`FP_TIER_DEPTH_BIAS`
  arbitration inherited for ties). This deletes the `_shell_gen` handshake race, the
  stale-shell hole window, the noblack-vs-exclusion fixpoint conflict — the entire R3.2/R4.2
  bug family loses its substrate. Cost: overdraw of ≤72 foreshortened distant facets — far
  cheaper than the machinery it replaces.
- **Frontiers (both stateless):**
  - *Inner (hop B):* smooth edge at true block-top; the adjacent L1/L2 blocky tops are
    min-decimated ≤ true. The step equals blocky's own decimation error — the identical step
    class the approved baseline already shows at its L1→L2 ring boundary. A skirt drops the
    inner edge to the local min. No coupling to near-streamer state (the annulus starts at
    ~800 blocks; near voxels end ≤ 128+margin — they can never meet).
  - *Outer (hop H):* the outer boundary row snaps to the shipped shell CELLS=4 weld chord — a
    pure static function of the fid (NOT of any neighbour tile), computed at bake; plus the
    4-block skirt. Beyond ground horizon at surface alts; sub-pixel where visible.
- **Block-LOD arbitration in CODE (LAW R-E, honoured this time):** flag
  `FP_SMOOTH_V2_EXCL_BLKLOD` suppresses L2..L4 ring emission for facets with
  `hop ∈ [B..H]` — a pure-geometric predicate, changes only at crossing. Shipped as a separate
  flag so the live A/B can compare smooth-over-blocky vs smooth-instead-of-blocky; never a
  deploy-sed convention.
- **Lighting:** phase-2 flat per-cell normal (cross of the cell's pos-grid diagonals, on the
  provoking vertex) through the two-normal law already designed and orbit-proofed in REV 4 C-2
  (`voxi_shade_rel`: day/night/terminator gate stays RADIAL ≡ near law; relief only as a
  day-gated bounded modulation ⇒ night far ≡ near exactly, terminator untouched).

### 2.3 Per-cell flat colour on a shared grid — the provoking-vertex law
GLSL ES 3.0 (WebGL2/ANGLE — our floor) mandates `flat` interpolation with **last-vertex
provoking convention**, and our engine's shader language supports it (`INTERPOLATION_FLAT`,
`shader_language.h`). On a regular grid, rotate each cell's two triangles (rotation preserves
winding) so BOTH end at node (i+1, j+1): `(i,j)(i+1,j)(i+1,j+1)` and `(i,j+1)(i,j)(i+1,j+1)`.
Node (i+1,j+1) is then the provoking vertex of exactly cell (i,j) and no other ⇒ its COLOR (and
phase-2 normal) attribute carries **cell (i,j)'s** values on a fully shared, indexed grid —
per-cell flat shading at zero extra vertices. Cell colour = the provoking node's own baked
`(g, biome, temp)` → `FarPalette.color_for` (zero extra samples; a half-cell colour registration
offset, invisible at ≥800 blocks — a cell-centre sample is the recorded alternative if the live
eyeball ever flags it). Row-0/col-0 nodes are never provoking; their colour slot is unused.
**Fallback if flat varyings misbehave on any real driver** (probe first, §6): duplicated-vertex
flat shading at C=26 (≈ 2 704·4 verts/tile ≈ same byte order at half density) — one const, same
laws.

---

## 3. Reuse vs discard (from the shelved arc)

**REUSED verbatim**
- `FarDensity.node_at` P0 canon-dir weld (+ its gates G-FS-CANON/WELD-EDGE/NRM-CONT).
- `FP_CPP_SMOOTH_BAKE` (patch 0012 `bake_smooth_tile`): dir/g/biome/temp per node, native,
  byte-equal, one call per tile — at C=52 it is exactly the tile this design needs. (`bnrm`
  boundary normals: unused in V2 — flat cell normals come from the pos grid; ignore the array.)
- REV-7 slot-mesh commit mechanics (engine packer, region updates, degenerate-blob evict,
  format-guard refusal latch, commit budget) + its gates G-SLOT-FORMAT/EQ/BUDGET.
- Sticky, crossing-triggered residency *concept* (REV-2 LAW R-A) — now degenerate-simple.
- Quiescence discipline + counters (Q1 idle signature; R4/R5 ring fixes stay as shipped).
- `voxi_shade_rel` two-normal lighting design (REV-4 C-2) for phase 2.
- The gate meta-lessons: shader LEGALITY on a real parser (G-FS-VARY-STAGE + Tier-A compile),
  committed-mesh (not set-level) assertions, falsify-both-ways, fixpoint-existence.

**DISCARDED (with the reason each cannot be "fixed back in")**
- S2..S5 tier ladder + caps + SSE/hop-band tier assignment — the misalignment root (§1.1).
- ALL mixed-pitch machinery: `_snap_plan`, `snap_edge_to_pitch`, chord-snap-to-neighbour,
  `FP_SMOOTH_WELD_REFRESH`, `FP_SMOOTH_SNAP_SELFHEAL` — nothing left to snap between.
- Emit-exclusion + `_shell_gen`/snap-gen handshake + smooth-leaving windows — no exclusion.
- The S2 rim collar entirely: envelope-inside-disc, feather, `RIM_*` cadence, `FP_RIM_CHEAP`,
  `FP_RIM_NEAR_WELD`, the 174k-sample `_env_weld_grid` bake — the annulus never meets the near
  field, so there is nothing to envelope, weld or rebake on walk. (The near↔far seam remains
  the approved baseline's: voxels → L1 blocky ring, untouched.)
- Baked-skin colouring of smooth geometry (UV2 slot plumbing, `FP_SMOOTH_SKIN_SLOT`,
  slot-indirect on smooth) — no textures on smooth, §1.2.
- Tier-pair transactional commits (`FP_SMOOTH_TXN` cross-tier atomicity) — one tier, no pairs.

---

## 4. Phased plan (each flag-gated `const := false`, byte-off, FLAT-verified, live-A/B-able)

### V2-1 `FP_SMOOTH_V2` — the minimal proof (ship first)
Uniform C=52 annulus at **hop [2..3] only** (16² − 9 = 40 tiles ≈ 9.6 MB, 216k tris), native
bake, single-tier slot mesh, per-cell flat colour (provoking-vertex law), over-shell
double-draw, radial shade only (the shipped `voxi_shade` — near-parity by construction).
Sticky residency, dwell evict, worker-paced fill nearest-first.
- **Gates:** G-V2-WELD (adjacent pairs incl. cross-face + cube-corner: boundary verts
  bit-equal); **G-V2-PURE** (build the full annulus twice under different worker
  orders/thread counts ⇒ committed slot bytes byte-equal — race-freedom asserted, not argued;
  falsify by perturbing one corner dir); G-V2-FLAT-LEGAL (varying-stage scan + Tier-A
  llvmpipe compile of every splice combination + live-console check — the R4.1 lesson);
  G-V2-COLOUR (readback: each cell's provoking vertex COLOR == `FarPalette.color_for` of that
  node; falsify with a rotated index order); G-V2-QUIESCE (fixed active facet: post-fill,
  zero dispatches/uploads/rebuilds over 600 frames; perturb by one crossing, re-settle;
  counters must move during warm-up — non-vacuous); G-SLOT-* re-run; FLAT 6042/0 off.
- **Live A/B (the user's eyeball is the acceptance):** relief readable at 800–1200 blocks; NO
  facet border visible anywhere in the band; the colour reads as distant voxel terrain, not a
  map; heap delta ≈ ledger; `smooth_commit_ms ≤ 8` during fill; rest telemetry Δ=0.

### V2-2 `FP_SMOOTH_V2_LIT` — relief lighting
Flat cell normals on provoking vertices + `voxi_shade_rel` splice (day-gated relief
modulation, radial night gate). Gates: G-FS-NIGHT-PARITY (numeric twin sweep), golden-string
+ Tier-A compile, FLAT.

### V2-3 `FP_SMOOTH_V2_REACH` — full band + arbitration
H 3→4 (72 tiles, 17.3 MB; stretch 5 behind the same const), crossing-shift pacing
(≤ 2 bakes in flight, leading edge first), outer-row static shell-chord snap,
`FP_SMOOTH_V2_EXCL_BLKLOD` (suppress L2..L4 inside the annulus — code arbitration, separately
A/B-able). Gates: G-FS-STABLE-pattern crossing script (no facet transitions twice, zero
camera-coupled evictions — assert the eviction cause log), G-V2-COVER (committed-mesh: shell
emit set unchanged by smooth residency — asserts NO exclusion path exists), ledger re-assert.

### V2-4 (optional, only on live evidence) polish
Cell-centre colour sample (if the half-cell offset ever reads wrong); H=5; a shader-only
detail-noise band near the inner frontier (`FP_RIM_DETAIL_BAND` contingency from R7.4). None
scheduled — each needs a named live observation first.

---

## 5. NEVER-OOM + gl_compat + warmup budgets

| Item | Bytes | Notes |
|---|---|---|
| GPU slot surface (fixed at creation) | cap 128 × 0.24 MB ≈ **31 MB** | one-time; `SMOOTH_BYTES_MAX` 96 MB ledger, asserted at setup |
| CPU resident | ≈ 0 | packed tile bytes freed after blit; re-derivable from the native bake |
| Transient | ≤ 8 in-flight × 0.24 MB ≈ 2 MB | native return arrays freed at commit |
| Draws | **+1** | one surface, one material (vs the ladder's +4) |
| Tris | 216k (V2-1) / 390k (V2-3) | draw COUNT is the proven ceiling, not tris; still a live A/B item on weak GPUs — fallback H−1, one const |
| Warmup | 40 tiles × 2 809 nodes ≈ 112k native samples ≈ few s worker (8-core), ~10–20 s (2-core) | one-time progressive fill, ring-ordered, region-write commits ⇒ no hitch; strictly LIGHTER than the ladder's warmup (fewer tiles than 289, no 174k-sample S2 collar, no O(N²) re-pack) |
| Crossing | ~9 bakes + 9 blits ≈ 2.2 MB | paced; trailing-edge dwell evict |

Warmup tradeoff stated honestly (design question 4): uniform pitch spends MORE bytes per
distant facet than the ladder's S5 did (0.24 MB vs 19 KB), which is why the band is bounded at
H=4 rather than hemisphere-wide — the ladder bought hemisphere reach at the price of the
frontier/race machinery that broke it. Beyond H the approved blocky+skin already looks good;
we are not paying bytes to replace something the user likes.

---

## 6. Probe-first items (before building V2-1)
1. **Flat varying through the splice chain on a REAL parser** — Tier-A (Xvfb+llvmpipe)
   compile + one live web frame with a 2-triangle flat-varying test patch; the R4.1 meta-lesson
   made mandatory. (Spec basis is solid: GLSL ES 3.0 flat + last-vertex provoking are
   mandatory; ANGLE conforms; engine parser supports it.)
2. **`glBufferSubData` on an in-use buffer** — already the REV-7 named unknown; same probe
   (native + one live frame with `smooth_commit_ms`), same fallback ladder (budget 1/frame →
   ping-pong slots → refusal latch to a whole-surface rebuild path).

---

## 7. Why the two failures cannot recur (the contract, restated as invariants)
1. **Misalignment:** every boundary vertex is a pure function of static shared data (canon
   corners × global pitch); no tile reads any other tile; residency is a pure function of
   `active_fid`; commits are per-tile region writes with no cross-tile transaction; the shell
   emit set never depends on smooth residency. There is no mutable shared state on which an
   ordering race could act — G-V2-PURE asserts it as byte-equality under permuted build order.
2. **Heightmap-texture look:** the smooth material contains no texture sampler for terrain
   colour; colour is a per-cell quantized block-palette attribute registered to the geometry
   that carries it. Smearing requires filtering an image; there is no image.

## 8. Verdict
**GREEN.** Every load-bearing mechanism is either gate-proven (canon weld, native bake,
block-exact palette) or shipped-and-measured (slot-mesh region updates, sticky residency,
quiescence counters); the design deletes machinery rather than adding it (no ladder, no snap,
no exclusion, no rim), and the budgets close with ~3× headroom.
**Single riskiest unknown — aesthetic, by design:** whether 8-block per-cell flat colour on
continuous relief reads to the user as "natural distant voxel terrain" or as "low-poly".
Everything mechanical is probed or gated; this one is answerable only by the V2-1 live eyeball
— which is exactly why V2-1 is scoped to 40 tiles behind one flag: a full look-judgment for
~9.6 MB and one deploy, with rollback = flag off (byte-identical baseline, the look the user
already approved).
