# COSMOS-FACET-SEAMS-DESIGN — seam-continuous height, a closed shell, one surface law for every tier

**Status:** root-cause + design (no engine code changed in this pass). Branch `deploy/perf-plus-sky`, 2026-07-19.
**Author:** Fable (`design-facet-seams`). Read together with `COSMOS-SEAMLESS-SCALES-DESIGN.md`
(the tier continuum this doc anchors geometrically), `COSMOS-FARRING-COVERAGE-DESIGN.md` (the
backstop/sink machinery this doc lets shrink), `COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md` (the
envelope + bias composition this doc keeps), `COSMOS-FACETED-IMPL.md` §2.5/§3.5 (the welded
ring + junction model), `COSMOS-FIXED-FRAME-DESIGN.md` (placement frames — untouched here).
`COSMOS-SEAM-METRIC.md` is the *pre-pivot curved-mode* seam investigation; it is historical
context only (that geometry no longer ships).

**The live reports (pilot, R = 6371, K = 24, facet edge ≈ 417):**

1. Adjacent facets show **height steps up to 8+ blocks** at every shared border — cliffs along seams.
2. The far-LOD shell has **holes at facet borders** — you can see through it into the planet interior.
3. Request: a **coherent multi-fidelity pipeline** — far shell → skin → blocks — that agrees at
   facet borders and at tier handoffs, with a sensible build queue.

All three have one geometric root plus one architectural gap, both named below with numbers.

---

## 0. Executive summary

- **The height *function* is already seam-continuous; the height *placement* is not.** Every tier
  samples `TerrainConfig.profile_at_dir(d̂)` — a pure function of the world sphere direction
  (terrain_config.gd:967) — so two facets agree on *g* at a shared edge. But the near field (and
  the skin) then **counts g blocks up from each facet's own mean plane along its own normal**
  (`FacetAtlas.lattice_to_world64`, facet_atlas.gd:402: the `y·n̂` term from `c0'` on the plane;
  fill convention: `column_profile → facet_profile` returns g and every consumer treats it as the
  facet-lattice surface y, terrain_config.gd:754-755, 986-991). The two planes of an adjacent
  facet pair sit at **different signed distances from the shared true edge** (the spherical quad
  corners are not coplanar — the equal-angle warp shears each quad differently), so the same g
  lands at different altitudes on the two sides. That difference is the cliff.
- **Measured (f64 replication of `_build_facet`/`_build_seam`, all 6912 Earth seams):** plane-datum
  step at the shared edge **max 5.30 blocks, p90 3.37, p50 1.14** at R = 6371. Add the cross-seam
  sampling offset (the two lattices are incommensurate; boundary columns sample d̂ ~1–2 cells
  apart) × mountain gradient (~1 with SHARP-SLOPE) ≈ 1–3 blocks ⇒ **observed worst ≈ 8+ blocks. ✓**
- **The rescale amplified a latent discontinuity — exactly linearly.** The whole facet geometry is
  R times a fixed angular shape, so every datum/crack term is **∝ R**: at the old R = 3072 the max
  step was 2.56 (p90 1.63) — mostly hiding inside ordinary 1-block terrain steps and the junction
  bevels; at 6371 it is ×2.0739 (probe confirms the ratio to 4 decimals) and reads as cliffs.
- **The far shell holes are the same root wearing a second hat**: `FacetFarRing._ensure_cached`
  (facet_far_ring.gd:781-806) builds each far facet from **its own** planarized corners
  (`facet_planar_corner`) — adjacent facets project the shared true edge onto *different* planes,
  so their edge chords disagree by up to **5.30 blocks** (∝ R), nothing welds them
  (`generate_normals` merges only bit-identical positions), and there is no skirt. From altitude a
  5-block slit along a 417-block edge is a clean view into the interior. The `FULL_COVER` backstop
  adds a second gap class: a sunk backstop facet (sink = `BACKSTOP_SINK_FRAC · cell` ≈ 13 blocks
  at R = 6371) meets an un-sunk horizon neighbour with a 13-block radial cliff at their border.
- **The fix is NOT in the cube-sphere parameterization.** `warp`/`fold_cell`/the atlas frames/the
  welded ring/junction planes are all untouched — low blast radius. The fix is a **datum
  unification**: make the *placed* surface a pure function of d̂ too.

**The two laws this doc establishes (everything else follows):**

> **One-Height Law (already true — pin it):** terrain height is `g = H(d̂) =
> profile_at_dir(d̂, R).x`, a pure function of the world sphere direction. No tier, no facet, no
> LOD may sample height any other way. (Locked by SEAMLESS-SCALES §7's one-sampler law; this doc
> adds the gate.)
>
> **One-Surface Law (new — the fix):** every tier renders the ground surface at the **same world
> point** `P(d̂) = (R + relief(g(d̂)))·d̂`, minus its tier's declared sink. For the voxel/skin
> lattice tiers this is achieved by the per-column **datum shift** `S(fid, x, z)` (§3); for the
> far shell by **radial emission from shared corner directions** (§4). Residual disagreement
> budget: ≤ 1 block quantization + ≤ 0.15 blocks of normal-vs-radial cosine — the same ±1-voxel
> texture the terrain already has mid-facet.

Cost of the whole program: **zero new persistent memory** (the datum shift is per-column
arithmetic on frozen atlas data; the shell rebuild changes cached *values*, not cache sizes), one
C++ generator patch (the L5 mirror — the only heavy item), and the backstop sink shrinking from
~13 to ~2–3 blocks once the sagitta no longer needs covering.

---

## 1. Root cause 1 — the near-field seam step (problem 1), file:line

### 1.1 The mechanism

The chain, verified in code:

1. `FacetAtlas._build_facet` (facet_atlas.gd:271-309): a facet's frame is its **mean plane** —
   normal `n̂ = normalize((c2−c0)×(c3−c1))` through the centroid of the 4 true corners
   `c_i = R·vertex_dir(...)`, corners projected onto it (`cp`). The 4 corners of a cube-sphere
   quad are **not coplanar** (the equal-angle warp `tan(a·π/4)` shears each quad differently by
   grid position — the same shear that made per-facet bevels non-reusable, the proven ~53°
   seam-orientation spread). Measured max corner deviation from own mean plane: **2.77 blocks**
   at R = 6371.
2. `FacetAtlas._build_seam` (facet_atlas.gd:342-385): the shared true edge `e0,e1` is projected
   onto **both** facets' planes; the **welded ring** is the average. The junction/clip planes hang
   off the ring — the *clip geometry* is consistent. But the ring is only the hinge; nothing makes
   the two *terrain surfaces* meet there.
3. `TerrainConfig.column_profile` faceted branch (terrain_config.gd:754-755) →
   `facet_profile(fid,x,z)` (:986-991) → `profile_at_dir(cell_dir(fid,x,z))` — height g is
   correctly a function of d̂ (seam-continuous **as a function**).
4. Placement: the surface cell is written at **facet-lattice y = g**, and
   `lattice_to_world64(fid, x, g, z)` (facet_atlas.gd:402-408) maps that to
   `plane_point + g·n̂_fid`. The skin does the identical thing explicitly
   (facet_skin_tier.gd:482-493, 539-541). So the physical altitude of the surface is
   `plane_altitude(fid at that point) + g`, and **plane_altitude differs between the two sides of
   a seam** by the quad-non-planarity mismatch.

At a point q on the shared edge, side A's surface sits at altitude `g − h_A(q)` above q (along
n̂_A) and side B's at `g − h_B(q)`, where `h_X(q)` is q's signed distance to X's plane. The step
is `|h_A − h_B|` — the plane-datum mismatch.

### 1.2 The numbers (f64 probe, exact `_build_facet` replication, all 6912 seams)

| quantity | R = 6371 (current) | R = 3072 (old) | ratio |
|---|---|---|---|
| seam datum step `max |h_A − h_B|` along shared edges | **5.30** | 2.56 | 2.0739 |
| step p90 / p50 | 3.37 / 1.14 | 1.63 / 0.55 | 2.0739 |
| quad non-planarity (corner dev from own plane), max | 2.77 | 1.34 | 2.0739 |
| sagitta: facet plane below sphere datum, centre / mid-edge | 6.81 / 3.66 | 3.28 / 1.77 | 2.0739 |
| far-ring shared-edge chord crack, max | 5.30 | 2.55 | 2.0739 |

(The ratio is 6371/3072 exactly — every term is R × a fixed angular shape. The probe recipe is
§8.1 so Opus can regenerate it as a verify gate.)

On top of the datum step, two smaller terms complete the observed picture:

- **Cross-seam sampling offset**: the two lattices are incommensurate (decorrelation offsets,
  different orientations); the nearest columns across a seam sample d̂ up to ~1.5 cells apart, so
  on SHARP-SLOPE mountain flanks (gradient ~1) the *sampled* g itself differs by 1–3 blocks. This
  term existed at R = 3072 too and is bounded by terrain roughness — it is NOT the fix target
  (post-fix it reads as ordinary terrain stepping, bevelled by the junction band).
- **Dihedral lever lean**: a column's solid leans `y·sin(δ/2)` (δ = 3.75°) toward its own facet —
  ≤ 3.8 blocks lateral at g = 116, but the junction clip planes are shared between the sides, so
  this produces no gap and no vertical step; it is why the seam *walls* look sheared, not why they
  step.

**Why it "worked" before the rescale:** at R = 3072 the p90 step was 1.6 blocks — inside the
±1-block quantization + bevel texture the terrain has everywhere. The rescale doubled the datum
terms while leaving the quantization at 1 block, pushing the p90 past the visibility threshold
and the tail to cliff scale. The discontinuity was always there; R made it legible.

### 1.3 Answering the commissioned question precisely

> *Is the height a pure function of the WORLD sphere-direction, or of facet-local UV?*

Both, and that is the trap: **g is a pure function of d̂ (seam-continuous); the altitude at which
g is rendered is a function of the facet id** (which plane, which normal). The discontinuity
enters at exactly one place: the `y·n̂` term of `lattice_to_world64` composed with the "surface
at lattice y = g" fill convention. The parameterization (`cell_dir`, the warp, the edge tables)
is *not* discontinuous and needs no change.

---

## 2. Root cause 2 — the far shell does not close (problem 2), file:line

Three independent defects, all in `facet_far_ring.gd`:

- **RC2a — per-facet edge chords (the cracks).** `_ensure_cached` (:781-806) and
  `_ensure_backstop_cached` (:821-853) bilerp each facet's own `facet_planar_corner` values. The
  shared edge's endpoints on side A are projections onto A's plane; on side B onto B's plane —
  they differ by up to 2.77 per corner, and matched points along the two chords by up to **5.30
  blocks** (table above). Adjacent far quads therefore neither share vertices nor touch;
  `generate_normals`' cross-seam smoothing (the G-L1-FARRING observation) only merges vertices
  that are *bit-identical* — these never are. No skirt exists at facet borders. Result: a ∝R slit
  along every seam, visible against the dark interior at any grazing altitude.
- **RC2b — the backstop/horizon sink cliff.** Under `FP_FARRING_FULL_COVER`, backstop facets are
  sunk `TierPlace.backstop_sink()` ≈ 13 blocks (rescale-safe `BACKSTOP_SINK_FRAC=0.5` × cell
  ≈ 26, cube_sphere.gd:299-304) while their horizon neighbours are not sunk at all
  (`_sunk_positions` applies per-role at emit, :928-935, :963-989). At every
  backstop↔horizon border the shell itself steps ~13 blocks radially — a second gap class that
  sweeps as roles change across crossings (mitigated but not closed by TIER-DEPTH P1 sticky).
- **RC2c — mixed tessellation T-junctions.** Backstop facets emit at `BACKSTOP_CELLS=16`,
  horizon facets at `CELLS=4`. Even with welded corners, a 16-cell edge against a 4-cell edge
  leaves T-junction pinholes unless the fine side's edge vertices are constrained to the coarse
  side's polyline.

Why the ridge apron (M2b) does not save this: it was designed for the `FP_M2_LOD` mesher's
LOD↔LOD ridges (facet_lod_builder.gd:134-137) — a different tier, default-off, and its strips are
sized to megablock erosion, not to the ∝R chord crack. It is the right *pattern* (lower-fid owns
the seam strip) applied at the wrong layer to fix the shell.

And the deep reason the shell *cannot* be closed robustly while RC1 stands: if far vertices were
moved to the true radial surface `(R+g)·d̂` (which trivially welds — see §4), they would poke
**through** the plane-anchored near field by the sagitta (6.8 blocks mid-facet). The current
plane-anchored far ring + 13-block sink is a workaround for the near field's bowl. **Shell
closure and datum unification are one program.**

---

## 3. The fix, part 1 — `FP_RADIAL_DATUM`: the per-column datum shift (kills problem 1)

### 3.1 The construction

For each facet column define the **datum shift**: the lattice height at which the sphere datum
crosses the column,

```
p0 = lattice_to_world64(fid, x+0.5, 0, z+0.5)        # column base point on the facet plane (f64)
b  = p0·n̂                                            # (≈ |p0|, both from frozen atlas data)
s  = −b + sqrt(b² + R² − |p0|²)                       # solve |p0 + s·n̂| = R for s ≥ 0
S(fid,x,z) = round(s)                                 # integer, per column
```

Properties (all provable in the gate):

- `s ∈ [0, ~6.9]` at R = 6371 (0 near corners, sagitta at centre) — **the shift only ever raises
  a column**, never cuts it.
- s is pure arithmetic over the frozen atlas frame + R — worker-safe, C++-mirrorable **with zero
  new frozen data** (the C++ generator already receives `facet_frame`, `facet_off`,
  `facet_r_blocks` — facet_skin_tier.gd:573-577).
- With the shift, the placed surface sits at `plane + (g+s)·n̂`, i.e. altitude `R + g·(n̂·d̂)` =
  `R + g` to within `g·(1−cos 2.65°) ≤ 0.15` blocks. **That is a pure function of d̂** — both
  sides of every seam agree to ≤ 0.15 + rounding. The measured 5.30-block tail collapses to the
  universal ±1 quantization.

### 3.2 Where it enters: a per-column re-index at the existing choke points — `resolve_cell` untouched

The shift is **not** a worldgen change. All height-dependent logic (strata, sea fill `g < y ≤
SEA_LEVEL`, snow line, biome, trees) keeps running in **true-height space**, unchanged and
byte-identical; the shift is a re-indexing applied at the *lattice boundary*, exactly the
`junction_modify` pattern (one authority, applied at the window exits):

```
cell_value(fid, x, y, z) = resolve(x, y − S(fid,x,z), z)      # solid content shifted up by S
surface_lattice_y(fid, x, z) = g + S                          # what floor scans / spawn / skin see
sea_surface_lattice_y(fid, x, z) = SEA_LEVEL + S              # the ocean rides the sphere too
```

Touch points (the full list — everything else follows through them):

1. **Module worker buffer write** (the same exit where `junction_modify` runs,
   module_world.gd worker loop): query the column's S once (it is per-column, like the profile
   memo) and write cell y from resolved y−S. The C++ emit loop mirrors identically (it already
   iterates per column after `sample_columns`).
2. **`WM.cell_value_at` faceted exit** (the analytic twin) — same one-line re-index.
3. **`height_at` / `analytic_column_profile` faceted consumers** — return g+S (one addition at
   the faceted branch, terrain_config.gd:638-642). Floor scans, DDA, GroundCollider, find_spawn,
   TreeGen anchoring, PerVoxelEnvironment all read through these and follow automatically.
4. **Skin sampler** — `sample_columns` heights become g+S (C++ and the GD oracle twin,
   facet_skin_tier.gd:584-605), so the skin lands on the shifted surface with no further change.
5. **Far ring** — needs nothing: §4 moves it to radial placement, which IS the shifted surface.

Explicitly NOT touched: `resolve_cell`, the noise stack, biome/climate, `profile_at_dir`,
`junction_modify`'s planes/mask (own_dist is horizontal — a vertical shift does not change which
cells straddle a *near-vertical* ridge plane by more than the ±1 rounding the model already
quantizes), crossing/HYST logic, the atlas, the warp. `FLAT_WORLD` and curved mode never reach
the faceted branch ⇒ byte-identical by construction.

### 3.3 Consequences to disclose (honest list)

- **The planet's content re-registers vertically by 0–7 blocks per column** (flag-on vs flag-off).
  Same terrain at the same d̂, same shapes; features spanning columns shear by ≤1 block at
  S-contour lines — the same class as existing terrain steps. Session edits are in-memory only
  (no persistence), so no migration; if persistence lands later, the flag state must be part of
  the world key.
- **The vertical envelope grows by ≤ 7**: `MAX_SURFACE_Y=116` consumers and the worldgen y-bounds
  get +7 headroom (edit-key y range ±512/1535 is untouched).
- **Sea level becomes per-column in lattice space** (`SEA_LEVEL + S`) — in true space it is still
  exactly `SEA_LEVEL=0`, so all worldgen logic is unchanged; only the two window exits and the
  height funnels see it, via the same re-index (a "sea surface" query helper for the ~2 physics
  callers that compare against SEA_LEVEL directly in lattice space — enumerate by grep at impl).
- **PerVoxelEnvironment lapse-rate temperature** reads lattice y where true altitude is y−S: error
  ≤ 7 blocks of altitude ⇒ ≪ 0.1° — accepted, documented.
- The dihedral lever lean (§1.2) remains — walls at seams stay slightly sheared. That is the
  locked faceted-geometry aesthetic (curvature lives at seams), not a defect.

### 3.4 Why not the alternatives

- **Skirts/aprons on the near field** (hide the cliff): leaves "adjacent facets agree" false;
  collision and gameplay still step 5 blocks; rejected as primary (skirts remain a far-shell tool).
- **Tangent planes at facet centres instead of mean planes**: moves the mismatch to the corners
  (where seams meet — worse), max |s| grows; rejected.
- **Curved columns / radial voxel y**: breaks the flat-lattice engine contract (godot_voxel,
  physics, the whole FP program); rejected — the datum shift buys radial-exact *surfaces* while
  keeping perfect-cube voxels, which is the locked FP invariant I3.
- **Re-planarize the atlas so planes agree at edges**: impossible — a single plane through 4
  non-coplanar points does not exist; the non-planarity IS the curvature budget. Any per-facet
  plane choice leaves an ∝R mismatch somewhere; only making the *surface* d̂-anchored removes it.

---

## 4. The fix, part 2 — `FP_SHELL_WELD`: the far shell closes at every altitude (kills problem 2)

### 4.1 Radial emission from shared corner directions

Replace the far vertex rule (both `_ensure_cached` and `_ensure_backstop_cached`; the envelope
variant §4.3):

```
today:  v = bilerp(planar corners) + d̂·relief(g)          # plane-anchored, per-facet chords
new:    d̂(s,t) = normalize(bilerp(R·vertex_dir(corner_ij)))   # from the TRUE shared corners
        v = d̂ · (R + relief(g(d̂)) − sink_tier)               # pure function of d̂ (+ tier sink)
```

Closure becomes structural:

- A shared edge's endpoint directions are the **same** `vertex_dir` values for both facets
  (shared grid corners), and edge samples at matched t are computed from the same two endpoints
  ⇒ **bit-identical edge vertices** ⇒ the shell welds; `generate_normals`' global smoothing then
  actually merges them (today's comment finally becomes true).
- Facet-grid corners (4 facets; 3 at the 8 cube corners) share one direction ⇒ closed fans.
- The surface now sits at `R + relief` — the **same** altitude law as the datum-shifted near
  field and skin (One-Surface Law): near↔far agreement to ≤ 1.15 blocks everywhere, not just at
  seams. The sagitta bowl disappears from every tier simultaneously.

### 4.2 The two gap classes that remain, closed explicitly

- **RC2c (mixed tessellation)**: rule — **every shared far edge is owned by the coarser side**.
  The finer side (backstop 16 vs horizon 4; 16 = 4×4 so parameters nest) emits its edge-row
  vertices ON the coarse side's edge polyline (evaluate the coarse chord at the fine t, in
  direction space). T-junctions on a shared straight polyline are crack-free. One helper +
  one gate (G-SHELL-T below).
- **RC2b (sink cliffs)**: the sink ladder becomes **continuous at role borders** — a backstop
  facet's sink ramps to the neighbour's sink over its outer cell ring (per-vertex sink =
  lerp(sink_backstop, sink_neighbour, edge proximity), computed at emit exactly where
  `_sunk_positions` already runs per-vertex). Combined with §5's sink shrink (13 → ~2–3), the
  worst residual role step is ~2 blocks *and* covered by make-before-break stickiness.

### 4.3 Interlock with the datum fix (staging constraint)

`FP_SHELL_WELD` at the **current** sink (≈13 > sagitta 6.8 + relief quantization) is safe to ship
**before** `FP_RADIAL_DATUM`: radial far vertices sunk 13 stay under the plane-anchored near
field everywhere (13 > 6.8 + backstop chord error ~4–7). So the shell can close first (small,
self-contained, immediately kills the see-through), and the sink shrinks only in stage FS3 after
the datum fix lands. The envelope builder (`_ensure_backstop_cached_env`, TIER-DEPTH P2) keeps
its min-footprint rule verbatim — only its vertex *placement* moves to the radial law; its
dilation constant derivation (`ENV_DILATE_BLOCKS`, the radial-vs-normal skew ≤ 5.4 blocks at
facet corners) actually *shrinks* post-datum-fix since near and far then share the radial law.

---

## 5. The fix, part 3 — the multi-fidelity pipeline (answers problem 3)

SEAMLESS-SCALES §3–§5 already defines the tier *continuum* (T0 voxels → T1/T1x skin → T2 far
ring/backstop → T3 scaled body → T4 other bodies), the screen-space-error law, and the
composition mechanism ("overlap + shared sampling + sink"). What it lacked — and what the pilot
felt — is the **geometric contract that makes composition honest**. This doc supplies it; the
queue below unifies scheduling.

### 5.1 The contract (three invariants, per tier)

Every surface tier declares `(pitch, sink, bias)` and must satisfy:

- **I-H (one height):** samples `H(d̂)` through the one-sampler funnel (C++ `sample_columns` /
  `profile_at_dir`) — never a second implementation. (Existing law; gate pins it.)
- **I-P (one surface):** renders at `P(d̂) − sink·d̂` with `P(d̂) = (R + relief(g))·d̂` — via the
  datum-shifted lattice (T0, T1) or radial emission (T2, T3). Cross-tier altitude disagreement at
  matched d̂ ≤ 1.6 blocks (1 quantization + 0.15 cosine + 0.5 pitch rounding) **before** sinks.
- **I-C (composition):** finer tier strictly overdraws coarser: sinks strictly increase with
  coarseness, biases follow TIER-DEPTH §5.2 (blocks 0 > skin 4q > far 8q), and every role
  transition is make-before-break (TIER-DEPTH §5.3 sticky pattern).

Post-fix sink ladder (re-derived, replaces sagitta-driven values):

| tier | places via | pitch | sink (blocks) | bound it must cover |
|---|---|---|---|---|
| T0 voxels | lattice + S | exact | 0 | — (ground truth) |
| T1/T1x skin | lattice + S | 1–8 | 1.5 (keep) | ≤1 quantization vs T0 |
| T2 backstop | radial, envelope | ~26/16 | ε ≈ 2–3 (was 13) | envelope residual + f32 (P2 rule) |
| T2 horizon | radial | ~104/4 | ramp to backstop sink at role borders | chord error vs P(d̂), covered by envelope-min at emit |
| T3 scaled body | same mesh as T2 | — | inherits T2 | SN3 clamp is screen-invariant |

### 5.2 Band ownership (unchanged, now safe)

Ownership stays **apparent-size-driven** (SEAMLESS-SCALES §3.2), not altitude-driven: T0 to
~128, T1 96–256, T1x 256–800, T2 the body, T3 beyond D_ENGAGE, T4 other bodies. The seam fixes
make the overlap zones *geometrically coincident* (≤1.6 blocks), which is what lets overlap +
sink work as a composition mechanism instead of a masking trick. "Surface blocks from space"
(the locked requirement) is delivered by T1 pitch-1 remaining super-pixel to LEO (≈2.8 px/block
at h=500) over the sub-camera cap, per the existing SSE table.

### 5.3 The build queue (one queue, four job classes)

Today each tier self-schedules (voxel pool; skin `_process` budget; far ring warm/async; LOD
builder thread). Unify the *admission policy* — not the executors — under one priority law:

- **Job classes:** `near-block` (godot_voxel pool), `skin-tile` (builder), `shell-facet-warm`
  (cache fill), `shell-reemit` (async rebuild), plus `apron/weld` strips where mixed density.
- **Priority:** `px_error_reduction / est_cost_ms`, where px error comes from the live SSE
  function (`px_of(e,d)`) with the tier error table — so "what to build next" is literally
  "what removes the most visible wrongness per millisecond". Near blocks inside the interaction
  radius (≤48) are exempt (always first — gameplay).
- **Admission:** the existing `StreamLoadController` credit scales ALL classes (the FP-M2 §6.5
  closed loop), with `vox_gen` backlog feed-forward as shipped. No new controller.
- **Make-before-break** is a queue invariant, not a per-tier hack: a job that would *remove*
  coverage (retire, unsink, evict) may only run when its replacement is committed (sticky
  backstop generalized).
- **NEVER-OOM:** per-class hard caps are the existing ones (§7); the queue holds references,
  never buffers — bounded by job count caps (≤ 64 entries/class, drop-lowest-priority).

This is deliberately an *organizing law over existing machinery* (controller, pools, budgets all
ship today) — the implementation is a priority function + an admission gate, not a new subsystem.

### 5.4 Tier handoffs (the specific pilot-visible ones)

- **T0↔T1** (voxel edge): unchanged from SEAMLESS-SCALES §4.1 (skin already lattice-exact); the
  datum shift applies to both simultaneously through the shared sampler ⇒ no relative motion.
- **T1↔T2** (skin edge → backstop): post-fix both sit within ≤1.6 of P(d̂); the backstop's ε sink
  + bias resolves overdraw; the 256→800 pitch ramp (T1x) keeps the resolution step sub-pixel.
- **T2 role borders** (backstop⇄horizon): sink ramp (§4.2) + sticky roles.
- **Facet borders within any tier:** T0/T1 — datum shift (≤1 step, bevelled by the junction
  band, which finally meets at matched heights — the FP2 "matching triangular junction blocks"
  vision now actually holds); T2 — bit-welded edges.
- **Altitude:** no hard swap anywhere (H_FARSWAP retired per SEAMLESS-SCALES §5); the shell's
  camera-set law + prewarm already handle the emit set from orbit; welded closure makes the cap
  visually solid at any θ.

---

## 6. Staged, flag-gated plan (each stage default-off, measured, independently shippable)

**FS0 — pin the bug (no behavior change).** New gate `verify_facet_seams.gd`:
(a) replicate the §1.2 probe in-engine over all seams — assert current max step ≈ 5.30 ± 0.1 at
R=6371 (regression-pins the diagnosis; FALSIFIABLE: perturb a plane → number moves);
(b) assert step ∝ R by evaluating the atlas math at a sanity R (constructed frames at R=3072 —
pure math, no world boot);
(c) live-surface probe: boot headless faceted, sample `WM` surface heights on both sides of 3
seams at matched d̂, assert the measured step equals the geometric prediction (proves mechanism,
not just geometry). *Headless-provable.*

**FS1 — `FP_SHELL_WELD` (shell closes; ships alone).** Radial emission from shared corner dirs
(§4.1) + coarse-owns-edge T-junction rule (§4.2) + sink ramp at role borders; **current sink
value kept** (safe under plane-anchored near, §4.3). Gates: G-SHELL-WELD (shared-edge vertices
bit-identical across every adjacent cached pair); G-SHELL-CLOSED (mesh topology: no boundary
edge interior to the emitted cap — every interior edge has 2 faces); G-SHELL-T (fine edge verts
colinear with coarse chord ≤1e-6); G-SHELL-UNDER (welded shell + sink stays ≤ near surface over
backstop footprints — the P2 envelope gate rerun); flag-off byte-identity; FLAT 6035/0.
*Headless-provable; the "no see-through from altitude" look is live-only.*

**FS2 — `FP_RADIAL_DATUM` (the seam-step kill; the big one).**
(a) GDScript: S(fid,x,z) helper in FacetAtlas (frozen-data arithmetic, worker-safe) + the §3.2
re-index at the two window exits + the height funnels + skin oracle;
(b) C++ mirror in `VoxelGeneratorCosmos` (same arithmetic from the already-frozen
`facet_frame`/`facet_off`/`facet_r_blocks`; per-column, after `sample_columns`) — patch series
sibling of patch-0007, full build.sh + `module_in_web=yes` check;
(c) skin/`sample_columns` heights become g+S in both paths.
Gates: G-DATUM-SEAM (both-sides surface altitude at matched d̂ agree ≤ 1.0 + 0.15 over every
seam × 5 samples, near path AND skin path); G-DATUM-RADIAL (surface altitude −(R+g) ≤ 0.65
everywhere sampled); G-CG-COLUMNS rerun (C++ == GDScript byte parity, the L5 mirror gate);
G-DATUM-OFF (flag off ⇒ byte-identical world, the FS0 step number returns); FLAT byte-identity;
full faceted/orbital suites green. *Headless-provable; the "cliffs gone" look is live-only.*

**FS3 — sink re-derivation + cross-tier gate.** Shrink `BACKSTOP_SINK_FRAC` to the ε ladder
(§5.1 table) now that sagitta is gone; retire the sagitta clause from the sink derivation
comment (cube_sphere.gd:293-299). Gate: G-TIER-ALT (matched-d̂ altitude across T0/T1/T2 within
the §5.1 budget, pre-sink); G-SHELL-UNDER rerun at the new sink. *Headless-provable; z-artifact
absence (shimmer at ε sink on gl_compat) is live-only — screenshot-gated like P3.*

**FS4 — queue unification.** The §5.3 priority function + admission gate over the existing
executors; telemetry field per job (class, px, cost, credit at admit). Gates: G-QUEUE-ORDER
(synthetic scene: queue drains strictly by px/ms within a class mix); G-SSE-INV (the
seamless-scales anti-stitch gate, now implementable: every transition logs px at fire).
*Headless-provable with synthetic cameras; feel is live-only.*

Dependency graph: FS0 → FS1 and FS0 → FS2 are independent; FS3 requires FS1+FS2; FS4 is
orthogonal (any time). Recommended order: FS0, FS1 (quick win, kills see-through), FS2, FS3,
FS4. Each stage: default-off flag, byte-identity gate, sed-flip at export per deploy pattern.

### Live-only checklist (cannot be proven headless — schedule pilot passes)

1. FS1: no see-through at any altitude/heading (orbit sweep + the climb path).
2. FS2: seam cliffs gone on foot + from flight; junction bevels read as smooth bevels; ocean
   surface continuous across seams (the sea rides S).
3. FS3: no shimmer/z-fight at ε sinks on gl_compat (the P3 shader-failure class — screenshot).
4. FS4: no starvation regressions (walk-perf telemetry M1/fps p10 unchanged).

---

## 7. NEVER-OOM ledger (all deltas, worst case)

| item | bytes | why bounded |
|---|---|---|
| S(fid,x,z) | **0** persistent | pure per-column arithmetic; rides the existing column memo (same key, same lifetime) |
| C++ mirror | 0 | same frozen params already passed |
| shell weld | 0 | same caches, same sizes — values change, not counts (`_pos_cache` 6·K² cap unchanged) |
| T-junction edge rows | 0 | computed at emit from existing corner data |
| sink ramp | 0 | per-vertex lerp at emit (where `_sunk_positions` already iterates) |
| queue | ≤ ~64 entries × 4 classes × ~64 B ≈ **16 KB** | hard cap, drop-lowest |
| gates | transient only | probe arrays freed per run |

Degrade ladder unchanged (memory-safety first): under pressure the queue sheds coarse-tier
*builds* first (T2 re-emits), never coverage (make-before-break holds even in degrade).

---

## 8. Appendices

### 8.1 Probe recipe (regenerate as `verify_facet_seams.gd` FS0)

Replicate `_build_facet` exactly (corners `R·vertex_dir`, mean-plane normal from the diagonals,
outward-oriented, corners projected). For every seam (adjacency by shared corner-direction pair):
sample the true edge arc at t ∈ {0,¼,½,¾,1}, compute signed distances to both planes, report
`max|h_A−h_B|`; also corner deviation from own plane, sagitta at centre/mid-edge (plane centroid
radius vs R), and the far chord crack (edge projected onto each plane, matched-t distance).
Expected at K=24: **R=6371 → 5.30 / 2.77 / 6.81 / 5.30; R=3072 → ÷2.0739 exactly.** The
2026-07-19 numbers in §1.2 came from an f64 out-of-engine replication verified against
cube_sphere.gd axis tables; the in-engine gate supersedes it.

### 8.2 Blast-radius statement (the commissioned flag)

**The cube-sphere parameterization is NOT touched**: `warp`, `fold_cell`, `vertex_dir`, the
atlas frames, seam planes, welded rings, junction encoding, crossing algebra — all byte-stable.
The byte-identity strategy is therefore ordinary: every stage behind a default-off flag with a
byte-identity gate; the single high-cost item is the C++ generator patch (FS2b), which follows
the proven patch-0003/0007 discipline (GDScript twin first, mirror gate, full rebuild,
`module_in_web=yes` check). The riskiest *visual* item is the FS3 ε-sink on gl_compat depth
precision — held behind its own flag with the 13-block sink as permanent fallback.

### 8.3 What this supersedes / amends

- Amends `COSMOS-FARRING-COVERAGE-DESIGN.md` §3: the sink's "clears facet chord sagitta" clause
  retires at FS3 (the sagitta itself retires at FS2).
- Amends `COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md` §4.1: the radial-vs-normal skew bound shrinks
  post-FS2 (both laws radial); envelope dilation may tighten.
- Completes `COSMOS-SEAMLESS-SCALES-DESIGN.md`: supplies the One-Surface Law its tier continuum
  silently assumed, and the §5.3 queue its §8 scheduler section deferred.
- `COSMOS-SEAM-METRIC.md` remains historical (curved mode, pre-pivot).
