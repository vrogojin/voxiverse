# COSMOS FARTREE-ALIGN — far-tree base weld to the near voxel tree + near-presence handoff cull

Status: DESIGN (task #120). Flags: `FP_FAR_TREES_ALIGN` + `FP_FAR_TREES_NEARCULL`, both default `false`,
byte-identical off. Author: Fable architect session 2026-08-12.
Companion docs: COSMOS-FAR-TREES-DESIGN.md (the tier), COSMOS-FAR-TREES-COLORFIX-DESIGN.md,
COSMOS-FOREST-FPS-DESIGN.md (FP_FAR_TREES_DELTA), COSMOS-FAR-NEAR-GRASSBASE-DESIGN.md (the probe-slab law).
Task #121 (far structures) reuses §5's near-presence predicate — see §5.6.

---

## 1. Symptom + requirements

Live: a FAR tree (rung-1 archetype mesh [128,448) or rung-2 card) renders **a few blocks below** its NEAR
blocky voxel twin, and in the transition band **both render simultaneously** — a sunken ghost tree under the
real one. User requirements, verbatim:

1. **Height weld** — the FAR tree renders at EXACTLY the near tree's position (base height especially).
2. **Handoff cull** — "once we start rendering the NEAR tree, we MUST turn off rendering the FAR one":
   the moment a tree's near voxel column is meshed, its FAR impostor is culled. No overlap, and no gap
   (near present before far removed).

These are two independent bugs with two independent fixes that *compose*: the weld makes the unavoidable
one-rebuild-latency overlap invisible (the far impostor sits inside the near tree's silhouette), and the
cull makes it brief.

---

## 2. Root cause A — the vertical (and lateral) offset, exactly

### 2.1 The near tree's true anchor

- `TreeGen.tree_info` returns `base = (bx, gy, bz)` where `gy = column_top(bx, bz)` = the **topmost solid
  ground CELL index** (tree_gen.gd:239-245; same law as `block_at`, tree_gen.gd:169).
- The trunk occupies cells `y ∈ [gy+1, gy+t]` (tree_gen.gd:331-334) — the tree **stands on top of** cell gy.
- The near render is **corner-anchored**: cell `(x,y,z)` meshes a cube spanning `[x,x+1]×[y,y+1]×[z,z+1]`
  (fallback: shape_mesh.gd:176-177 unit cube at `base = Vector3(cell)`, chunk_mesher.gd:443; godot_voxel's
  blocky mesher uses the same corner convention), placed in world by the fid's `W_fid` frame — the exact map
  `FacetAtlas.lattice_to_world64` evaluates (facet_atlas.gd:400-408; the NB-weld work proved slot transforms
  and this map agree).

⇒ **The near trunk's bottom-face centre = `lattice_to_world64(fid, bx+0.5, gy+1, bz+0.5)`.** That is THE
anchor every far representation must hit.

### 2.2 What the far tier actually does

The enum worker (facet_far_trees.gd:546-596) anchors at:

```
w = FacetAtlas.lattice_to_world64(fid, base.x, base.y, base.z)     # :566  ← raw corner, y = gy
s = w − r̂ · BURY                                                   # :573  ← BURY = 1.0 radial sink (:54)
```

Three stacked constants, all wrong against §2.1:

| # | Error | Where | Blocks |
|---|---|---|---|
| E1 | `base.y = gy` — the ground **cell index**, not the surface the tree stands ON (`gy+1`) | facet_far_trees.gd:566 (`tree_info`'s `base.y`, tree_gen.gd:245) | **−1.0** |
| E2 | `BURY = 1.0` radial sink, the §4.3 "tier-sink" law of the original design — correct for trees standing on the *sunk* V2 far datum, wrong at the near boundary where the visible ground is the near mesh at true height | facet_far_trees.gd:54, :573 | **−1.0** |
| E3 | (rung-1 meshes only) archetype cubes are emitted **centred at integer cells** `p ± 0.5` (facet_far_trees.gd:920-930, `fc = c + dv*0.5`), i.e. the trunk-bottom face sits at local y = +0.5 — but the near convention is corner-anchored, so relative to an origin meant to be "cell gy" the archetype rides **+0.5 high**, partially cancelling E1/E2 | facet_far_trees.gd:908, :926 | **+0.5** (meshes) |
| E4 | no cell centring: `lattice_to_world64` is corner-exact (no `+0.5` — contrast `cell_dir`, facet_atlas.gd:393-394 which adds it), so the impostor is anchored at the cell **corner** while the near trunk column is centred at `(bx+0.5, bz+0.5)` | facet_far_trees.gd:566 | **0.71 lateral** |

Net, against the near trunk-bottom anchor `gy+1`:

- **Cards** (base at local Y=0, facet_far_trees.gd:944-956): base altitude `gy − 1` ⇒ **2.0 blocks sunk**.
- **Rung-1 meshes**: lowest face at `(gy − 1) + 0.5` ⇒ **1.5 blocks sunk**.
- Both: **½-block diagonal lateral offset** (~0.71 blk).

That is the user's "a few blocks below" — a constant 1.5–2-block sink plus the half-block lateral skew,
reading larger on slopes. There is **no** far-ring datum/height involved: the far tree's height comes from
the same `column_top` (same `GenCtx`, tree_gen.gd:239) the near mesher uses, and the MMIs inherit the ring's
placement transform which the NB-weld work aligned with the near slots. The offset is purely the three
constants above. (The sunk-far-*terrain* datum — task #72, [[voxiverse-grassbase-backstop]] — is a separate,
terrain-tier issue; the trees only inherit it via the deliberate E2.)

---

## 3. Root cause B — why both trees render at once

The far band's inner edge is a **fixed camera-distance cut**, not a near-presence test:

- Cards/meshes skip only `dist < r0` with `r0 = TerrainConfig.near_render_radius()` = 128
  (facet_far_trees.gd:697-726, :786-818; `card_inner_radius()` :1079-1080; terrain_config.gd:153, 171-176).
- Under `FP_FAR_TREES_FADE`, rung-1 additionally **dithers IN over `[128, 152]`** (`mesh_fade`,
  facet_far_trees.gd:328-333, FADE_NEAR_W :48) — i.e. it deliberately overlaps the near field's edge.

But the near voxel terrain's ACTUAL meshed extent is **not** a crisp 128-sphere:

1. `max_view_distance` is initialised to `near_render_radius()` (module_world.gd:378-382) but the engine
   meshes whole **32-block mesh blocks** (module_world.gd:393) — the meshed frontier is chunk-quantised, so
   columns out to ~`128 + 32` can be fully meshed. A near tree at base distance 135 renders while its far
   mesh (d ≥ 128, fade-in α > 0.3) also renders. **That is the double-tree band, ~[128, 160].**
2. The view-distance ramp (module_world.gd:431-442, per-slot :475+, RAMP_START :1208-1214) means the live
   extent also goes *below* 128 during load/crossing — then trees in `[actual, 128)` render in **neither**
   representation (a gap; today masked by load chaos, but the same class of bug).
3. Neighbour facets are fully meshed under FP_NB_FULLRES — near trees exist on pool slots, not just the
   active fid, so any fix must probe the owning fid's slot, not the active terrain.

The design doc predicted exactly this (COSMOS-FAR-TREES-DESIGN.md §10.3: "the near voxel view-distance ramp
may move the effective edge — read the live ramp value, don't hardcode 128"). The fix is to key the inner
boundary on **actual near-mesh presence per tree**, not on any distance law.

---

## 4. Fix 1 — `FP_FAR_TREES_ALIGN`: the height weld

### 4.1 The anchor law

Under the flag, the enum worker anchors every tree at the near trunk-bottom-face centre and stores it
**unsunk** (E2 moves to rebuild time, §4.3):

```
# facet_far_trees.gd _enum_worker, replacing :566-573 under FP_FAR_TREES_ALIGN
w = FacetAtlas.lattice_to_world64(fid, base.x + 0.5, base.y + 1.0, base.z + 0.5)
s = w                                    # NO enum-time sink; radial r̂ stored as today (records unchanged)
```

Flag off ⇒ the old expression verbatim (corner, `gy`, `− r̂·BURY`) — the cached record floats are
bit-identical, so byte-off parity holds at the strongest level (the enum output, not just pixels).

**Proof the bases coincide.** Near trunk-bottom-face centre = `W_fid · (bx+0.5, gy+1, bz+0.5)` (§2.1). Far
anchor = `lattice_to_world64(fid, bx+0.5, gy+1, bz+0.5)` = the same `W_fid` map evaluated in f64
(facet_atlas.gd:402-408), with the same `gy` from the same `column_top(bx, bz, ctx)` on the same fid-scoped
`GenCtx` (tree_gen.gd:239 = the near mesher's own height law — CLAUDE.md rule 1: one notion of surface).
Both sides truncate to f32 once (mesh verts + node transform vs. instance-transform floats); at |coord| ≈
6500 one ULP ≈ 0.0005 blk. Equality is **by construction**, not by tuning.

### 4.2 Per-representation geometry fixes

- **Cards**: no mesh change. Local Y=0 is the card's ground (facet_far_trees.gd:949-956) and the side-view
  raster puts the trunk-bottom cell at the tile bottom (facet_far_trees.gd:1016-1020) — anchored at the new
  origin the card base IS the trunk base.
- **Rung-1 archetype meshes** (E3): with the origin at cell `(bx+0.5, gy+1, bz+0.5)`, archetype cell
  `(dx, y, dz)` must span local `[dx−0.5, dx+0.5]×[y−1, y]×[dz−0.5, dz+0.5]`, i.e. a cube **centred at
  `(dx, y−0.5, dz)`**. One-line fix in `_build_archetype_mesh`'s face emission under the flag:
  `_mesh_face(..., Vector3(p.x, p.y - 0.5, p.z), ...)` (facet_far_trees.gd:908). The trunk-stretch shader is
  unaffected (bottom still at local 0; `clamp(v.y/arch, 0, 1)` unchanged, facet_far_trees.gd:249). The mesh
  is built once at setup, so the flag is consulted once — off ⇒ old geometry bytes.

### 4.3 The far sink becomes a distance ramp (keep bury-not-float deep in the band)

E2 existed for a real reason: deep in the band the visible ground is the V2/far tier, which sits at/below
the true surface (near-fill tiles sink 6, [[voxiverse-lod-ladder-midband]]); a buried trunk base reads fine,
a floating tree reads broken. Exact placement must therefore hold **at the near boundary** and relax to the
old buried behaviour with distance:

```
sink(d) = FT_SINK_MAX · smoothstep(FT_SINK_R0, FT_SINK_R1, d)      # FT_SINK_MAX := 1.0 (the old BURY)
FT_SINK_R0 := probe_hi + 16      # just past the maximum possible near-mesh extent (§5.2)
FT_SINK_R1 := probe_hi + 96
```

Applied at **rebuild time** in `_rebuild_cards`/`_rebuild_meshes` (the record already carries r̂ at
o+3..5): `origin = s − r̂·sink(dist)` — three extra mul-subs per emitted instance, main-thread rebuild only
(rate-capped STEP_MS 250 + DELTA-gated). Where far trees are visible near the boundary the base is exact;
at 300+ blocks they carry the same 1-block bury as today (net +2 vs. today's placement — against V2 ground
that is strictly *less* float-corrective than today by 0, since today's deep base was gy−1 and the new deep
base is gy+0: one block higher, still at-or-below the true surface on flat ground; the residual
float-over-sunk-V2-near-fill is **pre-existing** and out of scope, noted in §8-R2).

---

## 5. Fix 2 — `FP_FAR_TREES_NEARCULL`: the near-presence handoff cull

### 5.1 The predicate: actual mesh presence, per tree — SHARED with #121 (`NearPresence`)

The record already carries everything needed: the owning `fid` and the lattice base `(bx, gy, bz)`
(REC floats o+8..10, facet_far_trees.gd:590-592 — stored for the chop filter). Per agreement with the #121
structures design (COSMOS-STRUCTURES-DESIGN.md §7.3), the presence signal is implemented ONCE, in a new
`godot/src/world/near_presence.gd` (`class_name NearPresence`), tri-state:

```
NearPresence.covered(world, fid, box: AABB) -> int    # COVERED | NOT_COVERED | UNKNOWABLE
```

Evaluation order — **COVERED-first** (this ordering is load-bearing, see below):

1. Y-clamp `box` into `TerrainConfig.meshed_slab_y()` (terrain_config.gd:270). If the clamp empties the box
   (fully outside the bounds slab) → **NOT_COVERED**, definitively: the near field can *never* mesh it, so
   the far impostor must show — forever is correct.
2. Probe `module_world.skin_near_meshed(fid, clamped_box)` (module_world.gd:2536-2544 — resolves the owning
   **pool slot**, active OR neighbour, FP_NB_FULLRES covered; godot_voxel `is_area_meshed` in the fid-lattice
   frame). **True → COVERED**, at ANY distance — a positive `is_area_meshed` is trustworthy unconditionally.
3. Only a **negative** needs the live-radius gate: if the box is not fully inside the live near reach
   (`min(viewer_view_distance(), pool_view(active))`, module_world.gd:505-506, :2576+ — never a hardcoded
   128) → **UNKNOWABLE** ("not meshed *yet/here*" can't be told from "will never mesh"); else
   **NOT_COVERED** (a real no — inside reach and not meshed).
4. No module / probe method missing → **UNKNOWABLE** (explicit, never a silent false).

Why COVERED-first: the double-render band lives precisely in the chunk-quantisation shell
`[reach, reach+32]` (mesh blocks are 32³, module_world.gd:393) — columns there CAN be meshed. If the radius
gate ran before the probe, that shell would be permanently UNKNOWABLE and the far impostor would never cull
exactly where the bug is. A positive probe is always safe to act on; only the negative is radius-ambiguous.

- The **probe-slab law** ([[voxiverse-grassbase-backstop]], FP_APPLIED_PROBE_SLAB — facet_far_ring.gd:1639-1655):
  `is_area_meshed` never clips to bounds, so an unclamped box dead-latches false forever. Step 1's clamp
  excludes the dead-latch class by construction; the shared G-NP gate asserts a POSITIVE reachability case
  (an actually-meshed box must return COVERED in the headless module world) so it can never silently recur.
- The predicate is a **pure read** (no streaming/apply cost) — consumers may call it every step for the
  §5.4 fingerprint.
- Trees probe a 1-cell box at the trunk-base cell `(bx, gy+1, bz)`: if the 32³ mesh block holding the trunk
  base is meshed, the near tree's trunk is on screen (canopy may lag one block — a sub-second streaming
  transient). Structures (#121) pass their whole footprint bbox — same function, different box.

### 5.2 Banding: probe only where the answer is in doubt

Probing every cached tree is wasteful; the answer is only uncertain near the frontier. Derive the live reach
instead of hardcoding 128 (the §10.3 note):

```
reach   = min(viewer_view_distance(), pool_view(active))            # live values, module_world.gd:505-506, :2576+
probe_hi = reach + 32 + 8            # mesh-block quantisation + margin — beyond this, near CANNOT be meshed
probe_lo = FT_CULL_MIN := 64.0       # below this, never emit far (a close-up card reads worse than a beat of absence)
```

Per tree at rebuild:

| base distance d | action |
|---|---|
| `d < probe_lo` | never emit far (unchanged: the near field owns it; during load the settle gate already holds the tier, facet_far_trees.gd:481) |
| `probe_lo ≤ d ≤ probe_hi` | **probe**: emit iff `covered() != COVERED` (culls the overlap band AND gap-fills a ramped-down view distance; NOT_COVERED and UNKNOWABLE both emit — never a gap on an unanswerable probe) |
| `d > probe_hi` | emit, no probe (an optimisation only — the predicate would answer UNKNOWABLE/NOT_COVERED there anyway; skipping the call keeps the probe count bounded) |

This **replaces** the hard `dist < r0` skip (facet_far_trees.gd:726, :817) and, under FADE, the near-edge
dither-in term (`mesh_fade`'s `fin`, :331; `card_fade`'s R0 branch, :354) — the probe decides emission, the
handoff is a hard swap made invisible by the §4 weld (the far impostor at swap time is co-located inside the
near tree's silhouette and occluded by it). The 448 mesh↔card cross-dither and the keep(d) thinning are
untouched.

Cost: the probe annulus `[64, ~168]` holds ~`π(168²−64²)/100 × 13.5%` ≈ **100 candidate trees** → ≤ ~100
`is_area_meshed` box tests per rebuild (native C++ hash-map lookups, µs each), on a rebuild that is already
rate-capped (STEP_MS 250) and DELTA-gated. In exchange every probed-true tree is an instance **removed** —
the cull strictly reduces live instance/overdraw in the band (the perf requirement), draw count unchanged (≤7).

### 5.3 No-gap / no-overlap ordering + hysteresis

Hysteresis lives in the CONSUMER (shared-predicate law — policy differs per tier); the tree tier's policy:

- **Near appears** → COVERED → far removed at the next rebuild — **HIDE_STREAK = 1 (immediate)**. Culling
  late is the overlap bug we are fixing (user requirement 2 is verbatim "the moment"), and a spurious
  COVERED cannot occur (a positive `is_area_meshed` is a fact, §5.1). Overlap window ≤ STEP_MS + one frame,
  during which the two are welded co-located (§4) ⇒ invisible. **Near-before-far-removed holds by
  construction** (COVERED requires the mesh to exist).
- **Near unloads** (receding edge / ramp-down) → NOT_COVERED → far restored after
  `FT_CULL_DWELL := 2` consecutive NOT_COVERED probes (SHOW_STREAK — hysteresis against mesh-block churn at
  the frontier); worst-case gap ≈ 750 ms on a tree that is, by definition, at the receding edge behind the
  player's motion. Dwell state: a small dict keyed `(fid, gx, gz)` (bounded by the probe annulus, ~100
  entries, entries dropped when not touched by a rebuild — ~5 KB, added to `total_bytes()`).
- **UNKNOWABLE never changes state** (never latch on an unanswerable probe — the applied-cover dead-latch
  lesson, shared law with #121).

### 5.4 FP_FAR_TREES_DELTA interaction (the rebuild must re-arm on mesh arrival)

`_rebuild_inputs_changed` (facet_far_trees.gd:646-657) knows camera/cache-epoch/edits — a mesh block landing
under a still camera would today never trigger the rebuild that culls the far tree. Under NEARCULL, `step()`
computes the probe pass (the ~100 box tests + dwell update) **before** the DELTA check and folds a
fingerprint (e.g. XOR of `hash(fid,gx,gz)` over probed-true trees) into the changed-inputs predicate:
fingerprint drift ⇒ rebuild. Probe cost at STEP_MS cadence is negligible; with NEARCULL off the fingerprint
is never computed (byte-identical, and DELTA's skip-law comment updated to name the new input).

### 5.5 Wiring

Same Callable plumbing as the chop query: `WorldManager` hands a
`NearPresence.covered`-binding Callable down via a new
`FacetFarRing.set_far_trees_near_query(q)` beside `set_far_trees_chop_query` (facet_far_ring.gd:5150-5152),
wired at world_manager.gd:413-414 under `FP_FAR_TREES`. Unset Callable ⇒ treated as UNKNOWABLE everywhere
⇒ behaviour degrades to today's distance band (never worse than shipped).

### 5.6 Shared with task #121 (far structures): `NearPresence`

The predicate is owned by this task (implements first) as `godot/src/world/near_presence.gd`, per the
agreement with the #121 structures design (COSMOS-STRUCTURES-DESIGN.md §7.3):

- ONE static `NearPresence.covered(world, fid, box) -> COVERED | NOT_COVERED | UNKNOWABLE`, semantics §5.1
  (slab-clamp first with empty-clamp ⇒ NOT_COVERED; **COVERED-first** probe; radius gate downgrades only
  the negative to UNKNOWABLE; missing module ⇒ UNKNOWABLE, explicit).
- Hysteresis is CONSUMER policy: trees use HIDE_STREAK 1 / SHOW_STREAK `FT_CULL_DWELL` (§5.3); structures
  pick their own streaks. The shared law both obey: **UNKNOWABLE never changes state**.
- Consumers reuse the same recipe: (a) probe only inside the live-reach annulus (§5.2 arithmetic — an
  optimisation, not a correctness dependency), (b) fingerprint the answers into their own delta gate (§5.4).
- Shared gate prefix **G-NP-\***, including the positive-reachability assert (a genuinely meshed box returns
  COVERED headlessly) — the applied-cover dead-latch class stays excluded for every future consumer.

---

## 6. Flags, consts, byte-off

Declared in cube_sphere.gd beside the FP_FAR_TREES family (cube_sphere.gd:886-931 pattern):

```
const FP_FAR_TREES_ALIGN := false     # §4: exact near-anchor weld (enum anchor + archetype −0.5 + sink ramp)
const FP_FAR_TREES_NEARCULL := false  # §5: near-mesh-presence handoff cull (probe-keyed inner boundary)
const FT_SINK_MAX := 1.0              # §4.3 deep-band bury (the old BURY)
const FT_SINK_R0 := 208.0             # sink ramp start (≈ probe_hi + 16 at full view; const, gate-derived)
const FT_SINK_R1 := 288.0             # sink ramp full
const FT_CULL_MIN := 64.0             # §5.2 never-emit-far floor
const FT_CULL_DWELL := 2              # §5.3 consecutive absent probes before far restore
```

Byte-off: ALIGN off ⇒ `_enum_worker` emits the shipped floats verbatim and `_build_archetype_mesh` emits the
shipped geometry (both single-site guards); NEARCULL off ⇒ no probe, no fingerprint, the shipped
`dist < r0` skip verbatim. Two flags so weld and cull A/B independently (ALIGN alone still shows the double
tree, welded; NEARCULL alone swaps a 2-block-sunk ghost — full fix = both). gl_compat-safe: zero shader
changes; everything is CPU-side anchor/emission arithmetic.

---

## 7. Perf ledger

| Item | Δ |
|---|---|
| Draws | 0 (same ≤7 MMIs) |
| Live instances in [64, ~168] | **reduced** (every probed-true tree dropped; today they all render) |
| Rebuild CPU | +~100 `is_area_meshed` box tests + ~2 flops/instance sink — µs-scale, under STEP_MS 250 + DELTA |
| Step CPU (NEARCULL, camera still) | the §5.4 fingerprint probe pass, ~100 box tests / 250 ms |
| Memory | +dwell dict ~5 KB (in `total_bytes()`, ≤ FAR_TREES_BYTES_MAX untouched) |

---

## 8. Gate plan (extend verify_far_trees.gd) + live A/B

Headless (per flag state):

- **G-FTA-1 anchor equality**: for N sampled trees, `world_to_lattice64(fid, record anchor)` ==
  `(bx+0.5, gy+1, bz+0.5)` with `(bx, gy, bz)` from `TreeGen.tree_info` (ALIGN on); == the shipped
  `(bx, gy, bz) − BURY·r̂` law (off). Assert `WorldManager.block_id_at((bx, gy+1, bz))`-adjacent invariants:
  ground cell gy solid, trunk cell gy+1 is the species log — pins the +1 convention against the live world.
- **G-FTA-2 archetype base**: min vertex Y of every archetype mesh == 0.0 under ALIGN (−0.5 shift applied),
  == 0.5 off. Card mesh min Y == 0 both states.
- **G-FTA-3 sink ramp**: emitted instance origin == anchor − r̂·sink(d) for sampled d across
  [FT_SINK_R0−ε, FT_SINK_R1+ε]; sink(boundary) == 0.
- **G-FTC-1 cull truth table**: with a stubbed near-query Callable — probed-true tree in [64, probe_hi]
  ⇒ zero instances; probed-false ⇒ emitted, **including d < 128** (gap-fill); d > probe_hi ⇒ emitted with
  zero probe calls (count the stub's invocations — also bounds probes ≤ 256/rebuild).
- **G-FTC-2 dwell**: true→false stub flip restores the instance only after FT_CULL_DWELL debug_steps.
- **G-FTC-3 DELTA re-arm**: camera still, stub flip ⇒ `rebuild_count()` increments (fingerprint input live).
- **G-FTC-4 monotone perf**: instances(cull on) ≤ instances(cull off), same scene.
- **G-OFF byte parity**: both flags off ⇒ `enumerate_facet_sync` record buffers + card/mesh `debug_buffer()`
  bit-identical to shipped; full existing suite (verify_far_trees 40/0, verify_faceted, verify_feature) green.

Live A/B (deployed web build, both flags on): walk + descend through the band —
(a) no ghost tree below any near tree (the §2 offset gone); (b) at the frontier a tree never doubles
(BandShot screenshot strip across [96, 192]: one silhouette per lattice site); (c) receding edge shows no
flicker storm (dwell working); (d) fps ≥ baseline (expect a small win from the removed band instances).

Risks: **R1** — probe cost if forests are extreme at the frontier (cap probes/rebuild at 256, nearest-first,
unprobed default = emit ⇒ degrade to today's behaviour, never a gap). **R2** — pre-existing float of
exact-height trees over sunk V2 near-fill ground just past the frontier (§4.3 bounds it to ≤ today's
behaviour +1; the terrain-side datum is task #72's scope). **R3** — `is_area_meshed` cost on the web build
is unmeasured at this call rate; the P0-style gate records probe-pass ms and the cap is the escape valve.
