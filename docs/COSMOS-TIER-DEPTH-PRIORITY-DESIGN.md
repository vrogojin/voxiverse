# COSMOS — Tier Depth-Priority Design (blocks > skin > far ring)

**Status: DESIGN (root-cause + scheme). 2026-07-17. Fable analysis pass — no implementation here.**

The bug (user, verbatim): *"far LOD terrain gets SOMETIMES OVER the blocks and breaks the whole
immersion. So we MUST sort out the rendering priority."*

The invariant this document designs: **wherever a finer tier covers the ground, every coarser
tier must lose — every fragment, every frame, every view angle.** Three tiers:
near voxel blocks (exact, authoritative) > skin heightfield (`FP_SKIN_TIER`, pitch-1, being
built) > far-ring backstop (`FP_FARRING_FULL_COVER`, ~12.6-block cells) > far-ring distant
facets (~50-block cells).

Verdict up front: **this is not one bug; it is two, plus one latent constraint.**

- **RC-A (steady-state, geometric): the constant 6-block radial sink is arithmetically
  insufficient in the tail.** The dominant omitted term is the **radial-vs-normal relief skew**
  (the far ring pushes relief along the sphere radius `d̂`, the near lattice stacks blocks along
  the facet normal `n̂`) — worth up to ~5–8 blocks of effective vertical error on tall steep
  terrain near facet corners, before adding interpolation/aliasing terms. Total worst-case
  overshoot ≈ 10 blocks vs a 6-block sink → steady poke-through of up to ~4 blocks at exactly
  "mountain flank near a facet corner", visible as a coloured sheet cutting through block tops.
- **RC-B (transient, ordering): role-transition staleness.** A facet entering the pool/LOD-cover
  set keeps its **unsunk, CELLS=4 (50-block-pitch)** far quad — whose chord error is **15–25
  blocks above true valleys** by the coverage design's own numbers — for the whole deferred-
  rebuild window (throttle + warm budget + async single-flight, ~0.1–1 s) while near meshes are
  already arriving/applied on it. That is a 15–25-block poke-through flash on every pool
  change/crossing near mountains. This is the dominant *visible event* and matches "SOMETIMES".
- **RC-C (latent, precision): 24-bit depth at `near=0.05, far=9000` is NOT the cause of today's
  block-level poke** (quantum ≤ 0.43 blocks everywhere near blocks exist, vs a 6-block sink) —
  but it **caps the whole tier scheme at range**: the 6-block sink collapses into one depth
  quantum at z ≈ 2 240 blocks, and the skin's 1.5-block sink at z ≈ 1 120. Any tier extension
  past ~1 km inherits z-fighting unless the near plane is raised and/or a depth-domain bias is
  added.

Candidates 3 (material misconfiguration) and the grazing-angle screen-space framing of
candidate 1 are **exculpated with evidence** in §3.5 and §4.3.

The fix is a single scheme with two independent invariants — **I1 (geometry): every coarser
tier is a *provable lower envelope* of the next finer tier in the overlap**, and **I2 (depth
domain): per-tier constant window-space depth bias so coincident surfaces resolve in tier order
at every distance** — plus **make-before-break role ordering** so I1 holds *through* transitions,
all behind one swappable sink/policy site (aligned with the skin build's abstraction).

---

## 1. The bug, precisely

### 1.1 What must be true

`FacetFarRing` under `FP_FARRING_FULL_COVER` draws *all* front-hemisphere facets; the ones the
near voxel world overlaps (the active facet + the live-pool/LOD `_excluded` set) are "backstop"
facets, emitted at `BACKSTOP_CELLS = 16` per edge and pushed radially inward by
`BACKSTOP_SINK = 6.0` blocks (`godot/src/cosmos/cube_sphere.gd:287-288`;
`godot/src/world/facet_far_ring.gd:445-452` `_sunk_positions`,
`facet_far_ring.gd:480-506` `_emit_cached`). The intent: the opaque near blocks strictly
overdraw the backstop via the depth buffer — no z-fight, no poke-through
(docs/COSMOS-FARRING-COVERAGE-DESIGN.md §2–§3).

### 1.2 What the user sees

Sometimes the far-ring surface renders **in front of / above** near blocks: a low-res
terrain-coloured sheet slicing through or floating over the exact blocky ground. Because the far
ring is **lit** (`facet_far_ring.gd:552-557`: `StandardMaterial3D`, shaded, roughness 1) while
the near atlas surface is **UNSHADED** (`godot/src/world/voxel_module/block_atlas.gd:243`), the
intruding sheet has visibly different brightness — maximum immersion damage per pixel.

### 1.3 Reproduction conditions (from the analysis below — use these for the probe poses)

1. **Steady poke (RC-A):** stand 150–500 blocks from a tall (relief ≥ 60, worst ≥ 90) steep
   (slope ≥ 0.8) mountain flank that lies near a **facet corner or edge** (radial tilt
   α ≥ 1.9°), view at grazing elevation. Expect a 1–4-block-thick far-ring sheet through the
   block tops of the *inward-facing* flank (the skew pushes the far surface outward from the
   facet centre). ~5–15 px at 1080p.
2. **Transient flash (RC-B):** walk across a facet seam (or trigger a pool spawn) in mountainous
   terrain. For ~0.1–1 s after `set_pool_excluded` fires
   (`godot/src/world/world_manager.gd:1898-1899` → `facet_far_ring.gd:123-130`), the newly
   entered facet's **unsunk CELLS=4** quad coexists with arriving near meshes: up to 15–25-block
   overshoot, ~20–35 px flashes.
3. **Boundary silhouette (RC-D, not a depth bug):** at the near-field horizon, unsunk distant
   facets' 50-block chords overshoot true ridgelines by ±15–25 blocks and read as "far terrain
   sitting on the blocks" even when geometrically behind them.

---

## 2. What exists today (verified inventory)

| Piece | Where | Facts |
|---|---|---|
| Far ring node | `facet_far_ring.gd` | One merged `ArrayMesh` in ABSOLUTE planet coords; node transform = `T_active⁻¹` (or identity−anchor under fixed frame), `facet_far_ring.gd:97-100`. `CELLS = 4` (≈50.3-block pitch), `RELIEF = 1.0` (`:19-20`). |
| Backstop | `facet_far_ring.gd:240-258, 404-506` | Role decided **at emit time** by `_is_backstop(fid)` = active ∪ `_excluded`. Dense cache 17² at `BACKSTOP_CELLS=16` (≈12.57-block pitch). Sink applied per emitted vertex: `v − v̂·6.0` (`:451`). |
| Vertex law (far) | `facet_far_ring.gd:381-397, 425-438` | `pos = b + d̂·relief`, `b` = bilerp of **planarized corners** (in the facet plane), `d̂ = b̂` (radial), `relief = max(0, g − SEA_LEVEL)·1.0`, `g = int(profile_at_dir(d̂))`. |
| Vertex law (near) | `godot/src/cosmos/facet_atlas.gd:282-288` | `lattice_to_world64`: `c0 + fx·ê_u + y·n̂ + fz·ê_w` — block height runs along the **facet normal**. Sampling dir per column: `cell_dir` at column centre (+0.5 offsets, `facet_atlas.gd:271-278`). Solid iff `y ≤ g` (`terrain_config.gd:1046,1088`) ⇒ near top face at `g+1` — the far vertex at `g` already sits 1 block low at coincident footprints (a *helpful* margin). |
| Vertex law (skin) | `godot/src/world/facet_skin_tier.gd:218-228` | `lattice_to_world64(fid, x, g, z) − ŵ·1.5` — **normal-aligned placement** (same law as near), radial sink `SINK = 1.5`, pitch 1, one-sampler (`sample_columns`), `R_OUTER = 256`, 8 MB hard ceiling. |
| Role churn | `world_manager.gd:1786-1787, 1898-1899, 315-319, 2111-2126` | Crossing → `set_active` (O(1)) + sync-exclusion; pool spawn/retire → sync same frame; under `FP_M2_LOD` an additional **0.5 s throttled** resync. All land as `_pending`; the rebuild is **deferred**: warm budget 3 ms/frame (`facet_far_ring.gd:24,218-238`), then sync rebuild or a single-flight async worker build (`:137-173`) — a new pending set **waits for the in-flight build** (`:139`). |
| Far material | `facet_far_ring.gd:552-557` | `StandardMaterial3D`, vertex-colour albedo, `CULL_DISABLED`, lit. Opaque: depth test + depth write ON (defaults). No transparency (FarPalette colours are opaque). |
| Near atlas material | `block_atlas.gd:241-250` | UNSHADED, `CULL_DISABLED`, vertex-colour, NEAREST+mips, opaque. Depth test + write ON. |
| Camera | `godot/src/player/player.gd:101-115` | `far = FacetFarRing.CAMERA_FAR = 9000` under FACETED; **`near` never set ⇒ Godot default 0.05**. `fov = 75`. |
| Geometry | `facet_atlas.gd:12-13` | K = 24, R = 3 072 → facet edge ≈ 201.06 blocks; facet half-edge angle 1.875°, half-diagonal 2.651° (sin = 0.0463). |
| Renderer | web export | gl_compatibility / WebGL2: 24-bit depth (`DEPTH24_STENCIL8`), **no reversed-Z** (RD backends only), no `glPolygonOffset` exposure in materials, no user reads of the main-viewport depth buffer. |

---

## 3. Root causes

### 3.1 RC-A — the sink's error budget is violated in the tail (steady-state)

The 6-block sink must exceed the maximum amount by which the rendered backstop surface can sit
**above** the true near surface anywhere in the overlap. Term by term, at the backstop's
12.57-block cell pitch:

| # | Term | Mechanism | Worst size (blocks) |
|---|---|---|---|
| T1 | **Radial-vs-normal relief skew** | Far vertex extends from footprint `b` along `d̂ = b̂`; the near column at the same footprint extends along `n̂`. Angle α between them: 0 at facet centre → 1.875° mid-edge → 2.651° at corners. The far vertex lands displaced **horizontally** (outward from facet centre) by `relief·sin α`; on local slope `s` that reads as vertical error `relief·sin α·s`. | relief 112 × 0.0463 = **5.2** horizontal; × slope 1.0–1.5 ⇒ **5.2–7.8** vertical (corner); mid-edge (α=1.875°): 3.7 × s ⇒ 3.7–5.5 |
| T2 | **Detail-noise aliasing** | `_detail` freq 0.05 (λ=20; `terrain_config.gd:331`), amplitude 1. Pitch 12.57 > λ/2 = 10 ⇒ under Nyquist; between-vertex surface can sit a full peak-to-peak above the chord. | **2.0** |
| T3 | Hills interp sagitta | `_hills` freq 0.008, 3 octaves, amp 3 (`:323-325`). Σ A·(2πL/λ)²/8 over octaves at L = 12.57. | **~1.0** |
| T4 | Shelf-knee | The water-line flattening window (`SHELF_*`, `terrain_config.gd:109-115`) is a slope discontinuity Δs ≈ 0.5–0.8; chord error ≤ Δs·L/4. | **1.6–2.5** |
| T5 | Sampling-footprint offset | Far samples at grid corners; near at column centres (+0.5, `facet_atlas.gd:273-274`): 0.71·s. | **≤ 1.1** |
| T6 | Mountain-uplift curvature | freq 0.0008 mask through smoothstep; sagitta at L = 12.57. | ~0.2–0.5 |
| M | *Top-face margin (credit)* | far vertex at `g`, near top face at `g+1`. | **−1.0** |

Worst-case stack (T1 corner @ relief ~100, slope ~1.2 + T2 + T3 + T5 − M) ≈ **9.5–11 blocks vs
a 6-block sink → steady poke of ~3.5–5 blocks**. A "merely bad" spot (mid-edge, slope 0.8,
relief 70) stacks to ~7–8 → 1–2-block poke. Flat/hilly interiors stack to ~3–4 → no poke. Hence
**"sometimes": tall + steep + near a facet corner/edge.**

Two corrections to docs/COSMOS-FARRING-COVERAGE-DESIGN.md §3 follow directly:

- Its budget ("chord sagitta ~1.6 + relief quantization + residual flank dip") **omitted T1
  entirely** — the single largest term, and the only one that is *resolution-independent*.
- Its escalation lever ("raise `BACKSTOP_CELLS` to 32 before raising the sink") **cannot fix
  T1**: skew does not shrink with cell pitch. Raising the sink to cover the worst stack (~11)
  would need sink ≈ 12 — doubling the benign dip everywhere the backstop is the only ground.
  Neither lever is the right primitive; §5 replaces the constant sink with a lower envelope.

### 3.2 RC-B — role-transition staleness (transient; the dominant visible event)

The backstop **role** is evaluated at *emit* time, but emission is **deferred**:

1. Pool spawn/retire or LOD-cover change → `_facet_ring_sync_exclusion()`
   (`world_manager.gd:1898-1899`, plus the 0.5 s throttle path `:315-319`) →
   `set_pool_excluded` sets `_pending` (`facet_far_ring.gd:123-130`).
2. `_process` first **warms** every uncached front facet under a 3 ms/frame budget
   (`:137-143, 218-238`) — a newly-backstop facet needs its 17² = 289-sample dense cache.
3. Only then does the rebuild run — and under `FP_FARRING_ASYNC_REBUILD`, a pending set that
   arrives while a build is in flight **waits for the whole in-flight build to land**
   (`:139`, `_async_building` gate) before it can even dispatch.

During that window — frames to ~1 s on the web build under crossing load — the facet that just
**entered** the pool is still drawn as a **non-backstop** facet: **CELLS = 4 (50.3-block pitch),
UNSUNK, at true chord height**. The coverage design itself measured that chord's error: *"the
near surface can dip ~15–25 blocks below the 50-block chord"*
(COSMOS-FARRING-COVERAGE-DESIGN.md §3). Meanwhile the pool/LOD is already applying real meshes
on that facet (streaming begins immediately on spawn). Result: a 15–25-block-high coarse sheet
over freshly-arrived blocks, for up to a second, on every mountainous pool change. At 400 blocks
distance that is a **~26–44 px flash** (§4.2) — unmistakably "far terrain OVER the blocks".

The **departing** direction is benign by asymmetry: a facet leaving the pool keeps its sink until
the rebuild (a 6-block dip where near meshes just vanished — a dip, not a poke). The danger is
one-directional, which makes the fix cheap (§5, D2: sink early, unsink late).

Note `set_active` itself is *not* a mis-placement source: the mesh is absolute and the rigid
re-place is exact (`facet_far_ring.gd:88-100`); under `FP_FIXED_FRAME` it is a no-op. RC-B is
purely the *role* lag, not the transform.

### 3.3 RC-C — depth-buffer precision: exculpated near, binding at range

gl_compatibility/WebGL2, 24-bit depth, conventional (non-reversed) 1/z distribution,
`n = 0.05`, `f = 9000`. Eye-space size of one depth quantum: `Δz(z) ≈ z²·2⁻²⁴ / n`
(window-depth derivative `≈ n/z²`; the f-term is negligible at f/n = 180 000).

| z (blocks) | Δz (blocks) | Context |
|---|---|---|
| 128 | 0.020 | near-field edge |
| 228 | 0.062 | active-facet far corner |
| 400 | 0.191 | pool neighbour mid |
| 600 | 0.429 | pool outer edge — **worst place blocks meet backstop** |
| 1 000 | 1.19 | |
| **1 122** | **1.5** | skin sink = 1 quantum |
| **1 943** | **4.5** | skin-vs-backstop separation = 1 quantum |
| **2 243** | **6.0** | backstop sink = 1 quantum |
| 3 000 | 10.7 | |
| 9 000 | 96.6 | horizon |

Conclusions:

- **Everywhere near blocks exist (≤ ~700 blocks), the quantum is ≤ 0.5 blocks ≪ the 6-block
  sink.** The observed block-level poke-through is **not** a depth-precision failure. Candidate
  2 of the brief is *not* among today's root causes.
- **But the scheme has a precision cliff**: sink-6 stops resolving at ~2.2 km, the skin's
  sink-1.5 at ~1.1 km, and the skin-over-backstop pair at ~1.9 km. Today the skin's
  `R_OUTER = 256` keeps everything far inside the cliff; the moment any tier (skin extension
  rings, pitch-2/4/8 stages, tree impostors) reaches ~1 km, sink-only priority starts
  z-fighting. **The unified scheme must not rely on eye-space separation at range** — that is
  what the window-space bias (I2, §5) is for.
- The near plane is the free lever: precision scales linearly with `n`. `near 0.05 → 0.25`
  shrinks every row 5× (sink-6 then holds to ~5 km) at zero cost — 0.05 is far smaller than an
  FPS with a 0.4-radius capsule ever needs. (Reversed-Z is **not** portable here: WebGL2 lacks
  `glClipControl`, so the [-1,1] NDC mapping squanders the float trick; and the compat renderer
  has no reversed-Z path anyway. Logarithmic depth via the `DEPTH` fragment built-in *is*
  writable in a Godot compat shader but kills early-Z on everything using it — unnecessary,
  since precision is not the binding failure.)

### 3.4 RC-D — coarse-silhouette overshoot beyond the near field (a shape bug, not depth)

The unsunk CELLS=4 facets *beyond* the overlap can raise false ridges ±15–25 blocks at the
near-field horizon. Depth resolves them correctly (they are genuinely behind); they still read
as "far terrain over my blocks" when a chord peak pops above the true skyline. No sink/bias/
precision change touches this — only resolution (or an envelope-from-above cap on chord
overshoot) does. It is listed so the probe can *classify* pokes: a poke that vanishes when the
far ring is hidden but sits **above the near silhouette** is RC-D; one **inside** the near
coverage mask is RC-A/B. The skin tier (exact pitch-1 silhouette to 256+) is the real cure for
the near-boundary instances; distant instances are cosmetic and out of scope here.

### 3.5 Candidate 3 — material/priority audit: no misconfiguration

Verified: both materials are opaque (no transparency ⇒ depth write + test ON;
`render_priority`/`sorting_offset` are irrelevant to opaque depth resolution in Godot — they
order draws, the depth test decides visibility). `CULL_DISABLED` on both affects neither depth
testing nor winding of the depth values. FarPalette emits opaque colours; vertex-colour alpha is
ignored without transparency enabled. The far ring is *lit* vs the atlas *UNSHADED* — a
**visibility amplifier** (pokes contrast hard), not a cause; harmonizing shading is a cosmetic
follow-up. The one genuine material-layer *gap* is the absence of any depth-domain bias — Godot
4.4 `BaseMaterial3D` exposes no polygon offset; the reachable equivalent is a ShaderMaterial
writing `POSITION` (§5, I2).

### 3.6 Candidate 1 as briefed — the grazing-angle framing, corrected

A radial/vertical sink `h` seen at grazing does **not** lose depth separation — along the view
ray the separation is `h / sin θ` (θ = ray-to-surface angle), which *grows* as θ → 0. Nor does
it lose screen separation in the way briefed: the on-screen drop of a sunk point at distance z
is `≈ f_px·h/z` (f_px ≈ 704 px at 75° vertical FOV, 1080p) independent of incidence — 7 px at
z = 600, 33 px at z = 128 for h = 6. What grazing *does* do is stretch any **envelope
violation** (RC-A/B overshoot) into a wide thin sheet across the skyline, maximizing its
visibility. So the correct primitive is not an "angle-aware sink" — a view-dependent sink would
mean per-frame mesh rebuilds *and* still be a lie — it is the view-independent **lower
envelope** (§5, I1). No derived screen-space constant `k` is needed: with I1 the coarse tier
never crosses the fine surface at any angle, and with I2 coincidence resolves in tier order.

---

## 4. Quantities the design is built on

### 4.1 Skew geometry (T1)

At planar footprint `b`, `α = ∠(b̂, n̂)`: 0 (centre), 1.875° (edge mid), 2.651° (corner).
Horizontal displacement of the far vertex = `relief·sin α` → 5.2 blocks at relief 112 in a
corner; effective vertical error `= relief·sin α·slope`. It points **outward** from the facet
centre, so the *inward-facing* flank of a mountain shows the poke.

### 4.2 Poke pixel sizes (75° vfov, 1080p, f_px ≈ 704)

`px ≈ 704 · err / z`: RC-A 4 blocks @ 300 → 9 px; RC-B 20 blocks @ 400 → 35 px; RC-B 15 @ 600 →
18 px. All far above the ~1–2 px visibility threshold; RC-B flashes are the loudest.

### 4.3 Skin-tier interactions (the third tier, so the scheme covers all pairs)

- **skin vs blocks**: pitch-1, one-sampler, normal-aligned placement (`facet_skin_tier.gd:
  218-228` via `lattice_to_world64`) ⇒ **no T1 skew, no aliasing**; at vertices the skin sits
  `1 + 1.5` blocks under the near top face. The residual case: a cliff step Δg between adjacent
  columns puts the skin's connecting wall mid-point `(Δg/2 − 2.5)` above the *lower* column's
  top face when Δg > 5 — but that wall lies ≤ 1 block horizontally inside the near cliff face,
  which occludes it from outside. Gate it (G-TIER-ENVELOPE sweeps cliffs) rather than redesign.
- **skin vs backstop**: separation 4.5 blocks *at vertices* — but the backstop's RC-A overshoot
  (~10) exceeds sink 6 + 4.5 margin at the worst spots, so **the backstop can poke through the
  skin too**. The skin does *not* absolve the backstop; I1 must hold for the
  backstop-under-skin pair as well.

---

## 5. The design — one scheme, two invariants, three tiers

### 5.0 Principles

- **I1 — geometric lower envelope (view-independent, build-time):** in any overlap region,
  tier k+1's rendered surface ≤ tier k's rendered surface, **provably**, not by a tuned
  constant. This is what kills RC-A and (with ordering) RC-B, and it is the only VR-honest
  primitive: a lower-envelope mesh is *real, stereo-consistent geometry* — both eyes see the
  same coarse-but-consistent world; there is no per-eye contradiction. (The user's "the sink is
  a depth-lie that breaks VR" concern actually indicts the *depth-domain* tricks — bias, log
  depth — not the sink: sunk/enveloped geometry is self-consistent; biased depth divorces
  occlusion from parallax. I1 is the VR-correct core; I2 is a sub-quantum safety net.)
- **I2 — depth-domain tier bias (per-fragment, render-time):** where surfaces coincide within a
  depth quantum, tier order must still win. A **constant window-space depth offset** of k
  quanta (the `glPolygonOffset` unit, expressed in-shader) guarantees this at **every**
  distance, because it lives in the same units as the quantization itself — unlike eye-space
  sinks, whose quantum-equivalence degrades as z².
- **One site.** All of it behind one policy class (working name `TierPlace`): the vertex
  placement rule (`place(tier, fid, x, z, g)` returning the enveloped+sunk position) and the
  per-tier bias constant. `facet_far_ring.gd`, `facet_skin_tier.gd` and the gates consume it;
  the skin implementation is already being told to abstract its sink behind one site — this is
  that site. Swapping the mechanism later (composite endgame) touches only this class.
- **NEVER-OOM**: every item is flag-gated OFF, byte-identical when off (FLAT 6035/0), with an
  explicit ledger (§7). No per-frame rebuilds anywhere.

### 5.1 I1 concretely — the min-envelope vertex rule (replaces the constant sink)

For a coarse tier vertex at grid position `i`, define its value not as `h(i)` but as

```
env(i) = min{ h(col) : col ∈ F(i) } − ε          ε = 1 (f32/rounding guard)
```

where `F(i)` is a **covering footprint**: the fine columns of the 2×2 coarse cells around
vertex i, **dilated by the skew reach** `ceil(relief·sin α_max)` (≤ 6 blocks ⇒ at
BACKSTOP_CELLS=16, `F(i)` = the 3×3-cell neighbourhood is sufficient).

**Why this is a proof, not a tuning:** every point p inside a coarse cell lies inside the
footprint of all of that cell's corner vertices, so each corner value ≤ h(p); a triangle's
interpolated surface is a convex combination of its corner values, hence ≤ h(p) everywhere.
Interpolation overshoot (T2/T3/T4/T6), sampling offset (T5) and — via the dilation — skew (T1)
are *all* bounded by construction. This is the terrain analogue of conservative min-Z /
"maximum mipmaps" occlusion structures (§8).

Cost: post-L5 the columns come from `VoxelGeneratorCosmos.sample_columns` (one C++ call per
facet; the dense backstop needs ~(16·3+1)² ≈ 2.4k columns ≈ 1–3 ms at cache-build time, cached
forever exactly like `_ensure_backstop_cached` today). **Zero extra persistent memory** — same
17² grids, different values. Where the backstop is the *only* ground (unstreamed facet
corners), the envelope reads slightly eroded (valley-biased) instead of uniformly 6 low —
comparable magnitude, adaptive shape.

The far ring's **distant CELLS=4 facets** get the same rule with their own footprint (envelope
from the same profile samples, ~13×13 per facet) — this also caps RC-D's upward silhouette
lies (a distant chord can now only *under*-shoot ridges, never raise false ones). The skin
keeps pitch 1 = its own exact envelope; only its `SINK` collapses to the ε guard + I2.

### 5.2 I2 concretely — the per-tier window-space bias

One small spatial shader (vertex-colour albedo, replicating the current two materials; the
compat backend supports writing `POSITION`):

```
POSITION = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
POSITION.z += TIER_BIAS * POSITION.w;      // constant *window-space* offset
```

`TIER_BIAS = 2·k·2⁻²⁴` pushes the fragment exactly k depth quanta behind, at every distance
(window depth = 0.5 + 0.5·z/w). Assign k = 8 to the far ring, k = 4 to the skin, near blocks
unbiased (keep their stock `StandardMaterial3D`). Screen position (x, y, w) is untouched — no
parallax shift, no silhouette change; the only lie is sub-quantum occlusion order, which is the
point. This is the GPU-native decal technique the brief asked about, reachable in Godot 4.4
gl_compat **only** via ShaderMaterial (`BaseMaterial3D` has no polygon-offset property; verified
against the 4.4 material API). Eye-space equivalent of 8 quanta at z = 600 is 3.4 *milli*blocks
— cosmetically nil — and at z = 3 000 it is ~86 blocks *of depth only*, safe because no finer
tier exists beyond ~1.1 km to be wrongly occluded (assert this reach ordering in the gate).

Risk to manage: converting the two far/skin materials to ShaderMaterial must preserve the compat
pipeline look (fog, tonemap, vertex colour). Keep the near atlas material untouched — the
authoritative tier needs no bias and stays on the fully-tested path.

### 5.3 Ordering — make-before-break roles (kills RC-B)

Asymmetric rule, exploiting that "sunk/enveloped with no cover" is benign (a dip) while "unsunk
under cover" is the bug:

- **Sink early:** a facet's role flips to backstop **synchronously** at the moment it enters
  the pool/LOD set. Two implementation options, choose at build time:
  (a) *sticky ring:* the backstop set = active ∪ all 8 ring-1 neighbours ∪ recently-active,
  **statically per crossing** — role churn disappears entirely except at crossings, where the
  entering set is known *before* streaming starts (the pool spawns after redesignation). Dense
  cache ledger grows from ≤5 to ≤12 facets ≈ 8 kB each ≈ 96 kB — nothing (raise G-FRC-BOUND
  accordingly).
  (b) *gated apply:* `module_world` holds the first mesh-apply on a facet until
  `_facet_ring.is_emitted(fid)` reports the backstop-role mesh committed. More coupling; only
  if (a)'s ring is somehow insufficient.
- **Unsink late:** a facet leaving the set keeps its backstop role until the pool confirms its
  near meshes are freed (or for a fixed hysteresis ≥ the worst rebuild latency). Cost: a
  transient 6-block dip — invisible under the skin tier anyway.
- Additionally, cap the staleness ceiling: when a pending role change waits on an in-flight
  async build (`facet_far_ring.gd:139`), the *entering* facets' quads are the only dangerous
  stale content — with (a) they are already sunk, so the wait becomes harmless by construction.

### 5.4 The options from the brief, judged

| Option | Verdict |
|---|---|
| (a) angle/distance-aware sink | **Reject.** View-dependent ⇒ per-frame rebuild of a cached-forever mesh; still a lie; the failure it targets (screen separation at grazing) is not the actual failure mode (§3.6). |
| (b) per-tier depth bias / polygon offset | **Adopt as I2.** Reachable in gl_compat via ShaderMaterial `POSITION.z`; window-space constant beats the quantum at all ranges; zero memory. Insufficient alone — cannot rescue fragments that project *outside* the near silhouette (geometric overshoot), so it pairs with I1, never replaces it. |
| (c) explicit render order + split depth ranges (`glDepthRange`) | **Reject for v1, absorb into endgame.** Our tiers *overlap in distance* (backstop lives at 100–600 blocks under the blocks), so a global depth-range partition cannot express "far ring behind blocks" — the classic planet-renderer split (KSP) works only when tiers partition *distance*. It returns as the composite endgame **after** the skin guarantees coverage to a split distance D (§6). |
| (d) larger near plane (+ tuned far) | **Adopt as hygiene.** `near 0.05 → 0.25` = 5× precision for free; not a fix for today's bug (precision isn't the cause) but removes the ~1–2 km cliff hanging over every tier extension. Keep `far = 9000` (the planet needs it). Verify no near-clip artifacts against walls (capsule keeps geometry ≥ ~0.3). |
| (e) layered composite (per-tier RT, nested coverage) | **Endgame, corrected feasibility.** The brief's "needs Forward+/WebGPU" applies to *depth-aware* merging (compat exposes no main-viewport depth to user shaders). A **range-partition** composite — near SubViewport (blocks+skin, near/far 0.25/650, transparent clear) painter-composited over a far viewport (far ring + sky, 600/9000) — needs **no depth read** and works in gl_compat/WebGL2 today. Precondition: the skin must guarantee coverage to the split distance so nothing < D lives in the far pass. Ledger: one extra full-res RGBA8+D24 target ≈ 12–16 MB at 1080p + a full-screen blit ⇒ NEVER-OOM flag-gated, A/B on `worst_ms` + heap. VR-correct: fully (each layer is honest geometry in an honest depth range). |

### 5.5 The unified tier table (the contract the gates assert)

| Tier | Placement | Envelope (I1) | Bias (I2) | Reach | Owner |
|---|---|---|---|---|---|
| Near blocks | lattice, exact | — (authoritative) | 0 | 0–~600 (pool) | module_world |
| Skin | normal-aligned, pitch 1 | exact heights − ε(1) [today: −1.5 const, fine] | 4 quanta | 0–256 (→650 later) | FacetSkinTier |
| Backstop (far ring) | radial, 12.57-pitch | **min-envelope, 3×3 dilated** − ε | 8 quanta | overlapped facets | FacetFarRing |
| Distant (far ring) | radial, 50.3-pitch | min-envelope (own footprint) | 8 quanta | horizon | FacetFarRing |

Invariant chain, everywhere and every frame including transitions:
`distant ≤ backstop ≤ skin ≤ blocks` in geometry, and `bias(distant)=bias(backstop) >
bias(skin) > 0` in depth.

---

## 6. Recommendation

**v1 (now, WebGL2):** D2 sticky/make-before-break roles → kills RC-B (the loud flashes);
D1 min-envelope vertices → kills RC-A (the steady mountain-corner pokes) with a proof instead
of a tuned constant; D3 per-tier window bias + D4 `near = 0.25` → makes the scheme
range-robust and future-proofs the skin's extension stages. All view-independent, cache-time,
zero-to-negligible memory, no per-frame cost, no new draw calls.

**Endgame (VR-correct, post-skin):** range-partition composite (§5.4e) once the skin reliably
covers 0→D: blocks+skin own the near pass, the far ring exits the overlap business entirely,
and I1/I2 shrink to the blocks-vs-skin pair inside one honest viewport. The `TierPlace` site is
the swap point; nothing else changes. Forward+/WebGPU (unschedulable through 4.7) is *not* a
prerequisite — it would only upgrade the composite from painter's-order to depth-aware merging.

---

## 7. Ranked plan

Ordered by (impact on the reported bug) × (risk). Each lands separately, flag-gated, default
OFF, FLAT export byte-identical (6035/0).

| # | Item | Mechanism | Flag | NEVER-OOM ledger | Kill metric |
|---|---|---|---|---|---|
| P0 | **Probe + gate first** | (i) G-TIER-ENVELOPE (headless): sweep worst spots — mountain flank at facet corner, shelf knee, cliffs — assert `far_render_h ≤ skin_render_h ≤ near_surface − ε` per fine column, all tier pairs; plus a scripted pool-enter/retire sequence asserting **no frame** pairs a visible near mesh with an unsunk far quad. (ii) V-POKE (Tier-A Xvfb/llvmpipe + live bridge): debug flag recolours the far ring magenta; three captures per fixed pose (full / far-hidden / near-only-for-mask); `poke_px` = magenta inside the near-coverage mask. Poses from §1.3; crossing script samples every frame for 3 s. | none (tooling + debug recolour flag) | 0 | The metric itself: reproduces RC-A ≥ ~9 px steady and RC-B flashes before any fix; **0 required after**. Camera-quiet frame pairs + screendiff at the boundary catch pops without streaming-conditioned stats. |
| P1 | **Sticky roles / make-before-break** (§5.3a) | Backstop set = active ∪ ring-1 ∪ recently-active, fixed per crossing; unsink deferred behind mesh-free confirm/hysteresis. | `FP_TIER_STICKY_BACKSTOP` | dense caches ≤5→≤12 facets ≈ +96 kB (raise G-FRC-BOUND) | V-POKE crossing script: max `poke_px` over the 3 s window = 0. |
| P2 | **Min-envelope vertices** (§5.1) | `TierPlace.place()` computes 3×3-dilated per-footprint minima from `sample_columns` at cache build; constant sink shrinks to ε = 1–2. Applies to backstop; distant facets in the same change or a follow-up. | `FP_TIER_ENVELOPE` | 0 persistent (same grids); +~2.4k transient C++ samples per facet cache build | G-TIER-ENVELOPE passes on the analytic worst-spot sweep (currently fails by ~4 blocks); steady V-POKE = 0 at §1.3 pose 1. |
| P3 | **Depth bias + near plane** (§5.2, §3.3) | Far/skin ShaderMaterials with `POSITION.z += 2k·2⁻²⁴·w` (k = 8/4); `player.gd` camera `near = 0.25`. | `FP_TIER_DEPTH_BIAS` | 0 (+2 small shaders) | Z-fight probe: camera-quiet frame pairs at a forced-coincidence pose (envelope flag off, sink 0) show shimmer without, byte-stable frames with; visual parity screendiff far-material swap ≤ noise. |
| P4 | **Skin integration under the same law** | Skin consumes `TierPlace` (one site, per its build brief); gate extends to skin pairs incl. the Δg>5 cliff case (§4.3); assert the reach-ordering table §5.5. | rides `FP_SKIN_TIER` | within skin's existing 8 MB ceiling | G-TIER-ENVELOPE all-pairs green; V-POKE with skin ON at §1.3 poses = 0. |
| P5 | **Steady-state partition (bubble mask)** | Far ring stops emitting backstop cells under *confirmed fully-applied* near coverage (per-facet coverage bitmap → cell skip at rebuild) — removes the overlap (and its overdraw) except in the moving boundary band. The perf-next "underlay + bubble-mask" idea, landed as an optimization *after* correctness, not as the correctness mechanism. | `FP_TIER_PARTITION` | +1 small bitmap per live facet (≤ kB) | V-POKE stays 0; far-ring overdraw (RenderingServer info) drops under covered facets; `worst_ms` A/B non-regressing. |
| P6 | **Range-partition composite** (§5.4e) | Two-viewport nested composite once skin coverage → D is gated-reliable. | `FP_TIER_COMPOSITE` | **+12–16 MB RT @1080p** — flag OFF by default, measured heap + `worst_ms` A/B gate before any default flip | V-POKE = 0 with sinks/biases *removed* in the near pass (the honesty check); stereo-consistency review for the VR target. |

Dependencies: P0 first (measurement before mechanism). P1 and P2 are independent; land P1 first
(smaller, kills the loudest symptom). P3 independent. P4 tracks the skin build. P5/P6 later.

---

## 8. SOTA — how planet/large-world renderers solve ground-over-far priority

- **Distance partition + composite (KSP, Star Citizen's zone system, many space games):** two+
  cameras with split near/far ranges, composited back-to-front. Solves *precision*, and by
  construction gives the near scene absolute priority — but only because tiers are partitioned
  by distance. Ports to WebGL2 as our P6 (SubViewport composite); the overlap band must first
  be eliminated (skin coverage), which is why it is the endgame, not the v1.
- **Logarithmic depth (Outerra; Cesium optionally):** fragment-depth rewrite to equalize
  precision over huge ranges. Portable to gl_compat via the `DEPTH` built-in but costs early-Z;
  our quantum analysis (§3.3) shows precision is not the binding failure ≤ 700 blocks, so we
  take the cheaper `near`-plane lever instead.
- **Reversed float depth (Space Engineers, No Man's Sky, modern engines):** needs
  `glClipControl`/[0,1] clip — absent in WebGL2; not portable. Noted to prevent re-derivation.
- **CDLOD / chunked LOD (Strugar; Ulrich):** LOD levels **partition** the terrain (quadtree) and
  geomorph at boundaries — there is *no* coarse-under-fine overlap to prioritize. The deep
  lesson: overlapping tiers are the anomaly; partition is the steady state (our P5/P6). Our
  overlay+sink is the web-budget shortcut for the *moving boundary* where partition is
  impossible mid-stream.
- **Conservative-Z / min-mipmap heightfield structures (Hi-Z occlusion culling, "maximum
  mipmaps" for heightfield ray-casting, Tevs et al.):** coarse representations built as
  per-footprint **extrema** so the coarse level provably bounds the fine one. Directly the P2
  min-envelope — the only place in the literature where a coarse mesh carries a *guarantee*
  rather than a tolerance.
- **Decal/coplanar rendering (polygon offset; D3D depth-bias):** constant + slope-scaled
  *window-space* bias as the canonical coincident-surface resolver — our P3, hand-rolled in the
  vertex shader because Godot's material API doesn't expose it.
- **Minecraft ecosystem (Distant Horizons):** far LOD starts *beyond* the vanilla render
  distance (partition again) with a small overlap band handled by draw order + acceptable
  artifacts — evidence that a boundary band with weaker guarantees is tolerable *if* the band is
  thin and transient, which is what P1's make-before-break enforces.

---

## 9. Corrections to earlier docs (where this analysis contradicts them)

1. **COSMOS-FARRING-COVERAGE-DESIGN.md §3** — the sink budget omitted the radial-vs-normal skew
   (T1, up to ~5–8 blocks, the largest term), and its escalation lever (`BACKSTOP_CELLS` 32) is
   resolution-based and cannot address it. §5.1 replaces the constant-sink primitive.
2. **Same doc §4/§8** — "only a thin terminator band is transiently stale for ≤1–2 frames"
   understates RC-B: the *entering-facet* staleness window is throttle+warm+async-flight
   (~0.1–1 s) and the stale content is a 15–25-block-overshooting unsunk quad under live
   streaming. The make-before-break ordering (P1) is the miss.
3. **This brief's candidate 1** (grazing shrinks the sink's screen separation) — inverted; see
   §3.6. The grazing problem is visibility amplification of envelope violations, not projection
   loss.
4. **This brief's option (e) framing** ("layered composite unschedulable in gl_compat through
   4.7") — over-broad: only *depth-aware* merging is blocked; range-partition painter
   compositing is available in gl_compat/WebGL2 today (§5.4e), gated on skin coverage, at a
   12–16 MB RT ledger cost.
5. **voxiverse-perf-next-architecture (underlay + bubble-mask)** — confirmed as the right
   *steady-state* structure, but re-ranked: it is an overdraw/priority *optimization* (P5) that
   presupposes the correctness invariants (P1–P3); a mask alone cannot protect the moving
   boundary band where the bug actually lives.

---

*Analysis pass: facet_far_ring.gd, facet_skin_tier.gd, facet_atlas.gd, cube_sphere.gd
(:270-298), block_atlas.gd, world_manager.gd (:300-319, :1786-1799, :1890-1899, :2109-2126),
player.gd (:101-115), terrain_config.gd (:85-115, :323-331, :860-877, :1037-1088),
COSMOS-FARRING-COVERAGE-DESIGN.md. Numbers assume K=24, R=3072, n=0.05→0.25, f=9000, 24-bit
depth, 75° vfov @1080p.*
