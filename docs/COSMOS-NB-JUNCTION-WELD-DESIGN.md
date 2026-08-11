# COSMOS — NB Junction Weld (FP_NB_WELD)

**Status:** DESIGN (research verdict + fix spec; nothing implemented)
**Bug:** at a facet junction with FP_NB_FULLRES live, a neighbour facet renders as a large
terrain slab floating in the air — tilted/rotated and height-offset, detached from the
ground — instead of the ground continuing across the seam; the subtle form is a
height/colour step-band at the seam. Telemetry at the bug: `facet=27`,
`facet_neighbours=2`, `pool_active=0` (settled), 60 fps.
**Verdict up front:** the placement-transform hypothesis is **REFUTED** — every live pool
terrain (active, imminent, and FP_NB_FULLRES widened) is placed by the *same* correct,
static transform path. The floating slab is the neighbour's **far-tier cover tile that is
never released**, because the CORRECTION-2 band-meshed exclusion latch is **dead by
construction**: its `pool_seam_meshed` probe cannot ever return `true` for a neighbour
facet (the probe box always exceeds the neighbour's bounds-clamped domain, and the
engine's `is_area_meshed` does not clip against bounds).

---

## 1. The placement-transform hypothesis, checked and refuted

### 1.1 There is exactly ONE placement path, shared by all live terrains

Every pool slot — the active facet, the imminent neighbour, and the FP_NB_FULLRES widened
neighbours — is built by the same constructor,
`module_world.gd:1835` (`_pool_build_slot`), which sets the slot's transform once:

- `module_world.gd:1875` — `slot.transform = FacetAtlas.facet_transform(fid)`
- `facet_atlas.gd:542-549` — `facet_transform(fid)` is pure frozen data:
  `Basis(ê_u, n̂, ê_w)` + translation `c0 − ox·ê_u − oz·ê_w` (the decorrelated-lattice
  offset folded in). It depends only on the frozen `_frame`/`_off` arrays — never on the
  active facet, never on time.

The active-at-init path (`module_world.gd:2064-2075`, `_pool_init_active`) uses the same
`FacetAtlas.facet_transform(_pool_active)` (line 2073). `pool_spawn`
(`module_world.gd:2096-2130`) differs from the imminent spawn **only in `view_target`**
(`NB_BAND_BLOCKS` = 64 vs the imminent prefill, lines 2115-2124). There is no second
placement path for non-imminent neighbours, and nothing to "keep updated":

- **Fixed frame ON** (`_fixed_frame_on()`, `module_world.gd:2044`): PlanetRoot is pinned
  at `identity − anchor` (`module_world.gd:2049-2050`) and a crossing **deliberately
  skips** the PlanetRoot write (`module_world.gd:2169-2170`). Every slot's global is
  `−anchor ∘ T_fid` forever — correct with zero per-crossing updates. The crossing
  re-places only the ~10 ActiveFrame children (`world_manager.gd:2779-2807`), never
  terrain.
- **Fixed frame OFF**: `redesignate` writes PlanetRoot = `T_to⁻¹` once
  (`module_world.gd:2170`); the engine then re-places every child slot's mesh blocks from
  the live global transform (NOTIFICATION_TRANSFORM_CHANGED,
  `voxel_terrain.cpp:866-880`) — all pool slots at once, not just active+imminent.

### 1.2 The engine cannot mis-place a block against its node transform

godot_voxel stamps every **newly applied** mesh block with the terrain's *current*
`get_global_transform()` (`voxel_terrain.cpp:1988`) and re-stamps **all** blocks on any
transform change (`voxel_terrain.cpp:866-880`). With the slot transforms static-correct
(§1.1) there is no code path that leaves a neighbour VoxelTerrain rotated or offset. The
FP_NB_FULLRES commit (`ab6fa0a`) touches only view targets, the residency selector, the
byte ledger, and the exclusion policy — **zero transform code**.

### 1.3 Why the "imminent renders correctly" asymmetry still holds

Not because of a different placement path — because of the **exclusion policy**:
`_nb_excluded_neighbour` (`world_manager.gd:3143-3144`) excludes the far-ring tile for
the imminent unconditionally (`nb == _nb_imminent_fid`), so over the imminent you see
only real blocks. Every *other* live neighbour is excluded **only via the
`_nb_excl_latch`** — and that latch can never set (§2). The asymmetry the bug report
observed is exactly the asymmetry of this predicate.

---

## 2. Confirmed root cause: the CORRECTION-2 latch is dead by construction

FP_NB_FULLRES CORRECTION 2 (`world_manager.gd:3278-3288`) made the far-ring exclusion
band-conditional: a live widened neighbour keeps its far-tier cover tile until its seam
band has meshed, detected by `pool_seam_meshed` → `_nb_excl_latch`
(`world_manager.gd:3120-3138`). The probe:

- `module_world.gd:1974-1984` (`pool_seam_meshed`) — reframes the **player's own
  position** (standing on active facet A) into neighbour B's lattice and asks
  `is_area_meshed` on a box of half-extents **(32, 40, 32)** around it.
- `module_world.gd:1891-1900` (`_apply_bounds`) — B's terrain is bounds-clamped to its
  domain slab: polygon bbox + `MARGIN_CELLS = 8` (`facet_atlas.gd:29,306-309`) + 2 seam
  cells = **10 cells** beyond B's polygon toward A. The engine clips every view box
  against `bounds` (`voxel_terrain.cpp:1296,1314`), so no block outside the slab is ever
  requested or stored.
- `voxel_terrain.cpp:2072-2079` (`is_area_meshed`) — requires **every** mesh cell of the
  box to hold a loaded block, and does **NOT clip the box against `bounds`**. A cell that
  can never load ⇒ permanently `false`.

While B is a *neighbour*, the player is on A, i.e. at or outside B's ridge. The probe box
extends 32 cells past the player on the A side, but B's domain ends 10 cells past the
ridge: **≥ 22 cells of the probe box lie in space B is forbidden to load**. Therefore
`pool_seam_meshed(B, player_on_A)` is **false for every neighbour, always** — not
starvation, geometry. (A second, independent killer: the probe's ±40 vertical half
exceeds the band terrain's streamed vertical reach — `view 64 ×
view_distance_vertical_ratio ≈ 0.5` ⇒ ~32 — so even a bounds-clipped box would fail.)

The same probe is used by `_lod_promote_pass` (`world_manager.gd:3241-3264`), where its
permanent falseness was **masked by the `PROMOTE_EVICT_MAX_S` timeout** — which is why
this never surfaced before. CORRECTION 2's latch has **no timeout**, only the geometric
release (`NB_EXCL_RELEASE`), so the dead probe became load-bearing for the first time.

### 2.1 The visible consequence

For every non-imminent live neighbour, forever:

1. `_nb_excl_latch` never contains it ⇒ `_facet_ring_sync_exclusion`
   (`world_manager.gd:3268-3295`) keeps its **far-tier tile** (far-ring quad / smooth-V2
   relief / skin per `_skin_candidate_fids`, `world_manager.gd:3300-3310`, which mirrors
   the same predicate).
2. Meanwhile its **live band genuinely meshes** near the seam (the shared viewer reaches
   ~64 blocks past the ridge) — correctly placed (§1).
3. Two representations of the same ground coexist: exact blocky terrain underneath, and
   the **coarse cover tile** above/through it — a big planar-ish slab in B's facet plane
   (3.744° dihedral off A's ground), at coarse DEM/datum height with the far-tier sink,
   smoothed slopes vs blocky terraces. Over a valley it hovers ("large slab floating in
   the air, tilted, offset, detached"); seen edge-on at the seam it is the height/colour
   **step-band**. Nothing is misplaced; a cover layer is never released.

This also explains the settled telemetry (nothing is streaming — the state is stable) and
why the bug arrived with FP_NB_FULLRES: pre-flag, exclusion was binary
(`world_manager.gd:3288`) — the instant a facet went live its tile vanished, so live
blocks and a cover tile never coexisted.

### 2.2 Answering the task's question 3 (tilt vs float)

Both the tilt and the offset are properties of the *retained cover tile*, not of any
missing rotation/translation on the neighbour terrain: the tilt is the facet-plane
dihedral (+ smoothed relief vs blocky terraces), the float is the coarse tile height
(datum/DEM quantization + far-tier sink) vs true block height. The neighbour
VoxelTerrain's own rotation (facet orientation) and translation (lattice offset) are
present and correct on every live slot.

**Live discriminator (cheap, before implementing):** via the remote bridge, at the bug
moment dump each live slot's `global_transform` against
`planet_root_placement ∘ facet_transform(fid)` (must be equal), and toggle the far-ring/
smooth-V2 layer visibility — the slab must vanish with the far tier while
`facet_neighbours` stays 2. If a slot transform ever differs, reopen the placement
theory (the G-NB-PLACE gate below would catch it).

---

## 3. The fix — FP_NB_WELD (byte-off, extends FP_NB_FULLRES)

One flag, `CubeSphere.FP_NB_WELD := false` (live-enable via the export sed alongside
FP_NB_FULLRES). Off ⇒ every branch below is inert ⇒ shipped bytes.

### 3.1 W1 — a seam-anchored, bounds-safe band probe (the core fix)

Replace the interior of `pool_seam_meshed` (flag-gated; old body retained off-flag):

- Compute `lp` = player reframed into B's lattice (as today,
  `FacetAtlas.reframe_position64(_pool_active, fid, …)`).
- Project the probe **inside B**: `p = lp + m̂_B · NB_PROBE_DEPTH` where `m̂_B` is B's
  own-side inward ridge normal for the shared slot (`FacetAtlas.seam_plane(fid, slot)`
  normal in B's lattice; the shared slot is known from `seam_neighbour`), and
  `NB_PROBE_DEPTH := 12.0` cells — comfortably inside B's polygon, comfortably inside the
  streamed band.
- Probe **three single mesh cells** (32³ each, the engine's mesh-block granularity) at
  `p`, `p ± t̂ · 24` (`t̂` = ridge tangent in B's lattice), each as a 1-cell
  `is_area_meshed` box centred at `(p.x, lp.y, p.z)`. All three loaded ⇒ the seam-side
  strip of B nearest the player has meshed. Single cells at depth 12 are inside B's
  bounds by construction (no clipping problem), and the cell containing the player's own
  y at the seam is the first thing the band streams (mesh blocks are stored for meshed
  air too — `voxel_terrain.cpp:2073` comment — so hills/valleys can't wedge it).
- Gate the probe on ridge distance: only attempt when the neighbour's own-side ridge
  distance `want[fid] < NB_BAND_BLOCKS − 16` (48). Farther out, the tile *should* cover —
  that is CORRECTION 2's correct behaviour, unchanged.

`_lod_promote_pass` inherits the working probe for free (its timeout becomes the backstop
it was meant to be, not the only path).

### 3.2 W2 — latch changes trigger the exclusion re-sync

`_nb_update_excl_latch` (`world_manager.gd:3124-3138`) returns `bool changed` (latch set
or cleared); `_manage_pool_z1hybrid` ORs it into its `changed` result so
`_facet_ring_sync_exclusion()` runs the same tick (`world_manager.gd:2923-2929`). Today a
latch flip is only picked up by the 0.5 s throttle at `world_manager.gd:832-836`, which
is gated on raw `FP_M2_LOD` — a live flag set with `FP_M2_LOD` off would never re-sync.
Cost: nil (`set_pool_excluded` no-ops when unchanged).

### 3.3 W3 — crossing-tick latch seeding (two-phase ordering)

On a committed redesignate, the old active becomes a widened band neighbour of `to`
(`module_world.gd:2180-2199`) with its near field *already fully meshed* — but its latch
is empty, so its far tile would pop IN over real ground for the whole (dead-probe:
forever; fixed-probe: until the next successful probe) window. In
`_commit_facet_change`, immediately after a successful redesignate
(`world_manager.gd:2736-2754`), seed `_nb_excl_latch[from] = true` (flag-gated). This
respects the two-phase ordering: it runs after `set_active_facet(to)` +
`redesignate(to)` commit, inside the same crossing bookkeeping that already re-syncs the
ring (`world_manager.gd:2743`), so no phase ever sees a half-placed state. Terrain
transforms are untouched in either phase (§1).

### 3.4 Explicitly NOT in this fix

- **No per-neighbour transform writes, on spawn or reframe** — placement is already
  correct (§1); adding writes would only create the NOTIFICATION_TRANSFORM_CHANGED
  re-place cost the fixed frame exists to avoid. The gate G-NB-PLACE *pins* the law
  instead.
- **No latch timeout that force-drops the tile** — latching without meshed blocks is the
  see-through regression CORRECTION 2 exists to prevent. The 3-cell probe is the
  evidence; the geometric release (`NB_EXCL_RELEASE`) stays the only clear.

### 3.5 NEVER-OOM / perf

Zero new allocations; ≤1 neighbour probed per pool pass (unchanged), now 3 single-cell
`is_area_meshed` map lookups (~27× cheaper than the old 3×3×3-cell box). The ledger, caps
and band radii are untouched.

---

## 4. Gates

- **G-NB-WELD-PROBE** (headless, falsifiable): active A + live band neighbour B; place
  the viewer 8 cells from the ridge on A; pump until the engine has meshed B's seam
  strip; assert the *new* probe flips `true` — and assert the *shipped* probe body, in
  the same state, stays `false` (pins the root-cause mechanism; fails if §2 is wrong).
- **G-NB-WELD-EXCL**: latch set ⇒ B enters the far-ring excluded set within one pool
  pass (W2); walking B's ridge distance past `NB_EXCL_RELEASE` ⇒ latch clears and B
  leaves the set. Crossing A→B ⇒ A is latched the same tick (W3).
- **G-NB-PLACE** (the junction-weld assertion requested): for every live pool fid,
  `slot.global_transform == P ∘ FacetAtlas.facet_transform(fid)` (P = `−anchor` under the
  fixed frame, else `facet_transform(active)⁻¹`), and for a shared-edge column
  `P·T_B·reframe_position64(A,B,p) == P·T_A·p` within 1e-3. Falsifier: an
  identity/stale transform diverges by ~|lattice offset| (10³-10⁴ blocks).
- **Byte-off + regressions**: FP_NB_WELD=false ⇒ shipped placement byte-identical; FLAT
  `verify_feature` 6042/0; `verify_stream_parallel` NB gates (44/0 both flag states);
  `verify_faceted` 84/0.

---

## 5. The three hardest risks + kills

1. **Misdiagnosis — the slab really is the VoxelTerrain.** All code evidence says
   placement is correct, but the verdict rests on reading, not a live measurement.
   *Kill:* run the §2.2 live discriminator first (slot-transform dump + far-tier
   visibility toggle over the remote bridge — minutes, no build); G-NB-PLACE ships
   regardless, so a real placement fault cannot hide again. If a screenshot shows the
   slab with blocky near-mesh texturing rather than skin/smooth shading, reopen §1.
2. **Cover-gap inversion (worse-than-today see-through).** A too-eager latch drops the
   tile while most of the band is unmeshed. *Kill:* 3-cell strip evidence + the
   ridge-distance gate (probe only inside the band's certain reach) + no timeout-latch;
   G-NB-WELD-PROBE's falsifier asserts NOT-latched while the strip is unmeshed.
3. **Corner/diagonal junctions.** At a facet corner the player sees the *diagonal*
   facet, which is never a live target (`z1_live_targets` is edge-only,
   `world_manager.gd:3151`) — its tile correctly stays; but the two *edge* neighbours'
   probes near a corner project `p` close to B's own polygon corner where the band is
   thinnest, and the shared-slot identification must pick the right seam.
   *Kill:* clamp `p` into B's polygon via `FacetAtlas.in_polygon(fid, p, −2)` (retreat
   along t̂ if outside); derive the slot from `seam_neighbour(active, slot) == fid`
   (exact, not nearest-plane); add a corner case to G-NB-WELD-PROBE (A active, B and C
   live, player at the tri-junction).

Adjacent latent finding (out of scope, worth a task): with the widened pool at cap 4, a
surprise pool-miss crossing hits `pool_spawn`'s cap check (`module_world.gd:2101`) and
falls to `pool_reset` teardown (`world_manager.gd:2726-2734`) — the same-tick eviction
exists only in the pool pass, not on the crossing path.
