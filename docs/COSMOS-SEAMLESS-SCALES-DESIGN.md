# COSMOS-SEAMLESS-SCALES-DESIGN — one continuum from footstep to orbit

**Status:** design (no implementation in this pass). Branch `deploy/perf-plus-sky`, 2026-07-17.
**Author:** Fable — the same analyst as `COSMOS-WALK-PERF-DESIGN.md`, `COSMOS-STREAM-SCHED-DESIGN.md`
and `COSMOS-ORBITAL-O1O4-DESIGN.md` (the latter lives on `feat/voxiverse-orbital`, commit `9727be9`).
This pass reconciles all three against a new **user-locked requirement** and, where they conflict
with it, **overrules my own prior designs** — explicitly, with the replacement mechanism.

**The requirement (locked, verbatim intent):** *"Walking, flying within the atmosphere, orbiting in
the planet vicinity, all should be natural and smooth. No stitches and jumps when crossing facets
and when crossing the atmosphere-space border as well (we might consider even rendering the surface
blocks from space wherever applicable)."*

It is a **continuum** requirement: walk → fly → orbit → return with no visible pop, tier swap,
veil, or discontinuity anywhere on the path.

---

## 0. Executive summary

1. **My O1 design's H_FARSWAP is rejected by this requirement, and I retract it.**
   `COSMOS-ORBITAL-O1O4-DESIGN.md` §2.1/§2.8 specifies `H_FARSWAP := 20000`: above it, retire the
   live pool AND the far ring and render the home body as a sphere impostor; on descent, rebuild
   the far ring with *"the veil is acceptable v1 — measured"*. That veil is exactly a stitch at
   the atmosphere-space border. It is now **REJECTED**, and — examined honestly — it was never
   necessary: the far ring is ONE merged mesh whose anchor shift is a single transform write
   (`facet_far_ring.gd:105` `shift_anchor`), so the "node churn" rationale in §2.8 bought almost
   nothing. §5 below replaces it with **persistence + screen-space-error-scheduled transitions +
   a continuous scaled-space clamp**, at **zero new memory**.
2. **The unifying law is angular, not radial.** Every tier transition (voxel ↔ skin ↔ far ring ↔
   scaled body ↔ impostor) fires when — and only when — the *screen-space error* of the cheaper
   tier drops below ~1 px on the viewer's actual device (§3). A transition that fires sub-pixel is
   invisible **by construction**; "no stitches" stops being a hope and becomes an assertable gate
   (G-SSE-INV, §10). Radial constants (`OFFSURFACE_Y`, H_FARSWAP, the impostor swap) become
   *derived, device-dependent* altitudes.
3. **The thesis is confirmed, with a precise boundary.** The hard swaps in the orbital design
   existed because tiers were unaffordable at the measured ×25 web multiplier. Post-L5
   (supply ~300+ blocks/s, skin tile ~2–3 ms) tiers can **overlap-with-exact-agreement** instead
   of swapping. What supply does **not** fix (§2.2): (a) content classes absent from cheap tiers —
   trees, carve mouths, **player edits** — which need explicit representation in the skin/ring
   (§4.2, §4.5); (b) the **dihedral camera tilt at facet crossings** (~3.75° instantaneous —
   §6.2, a real stitch nobody has named); (c) depth/precision plumbing for a 15k camera far
   (adaptive near plane, §5.4). All three are cheap; **none is irreducible**. f32 is quantified
   NOT a blocker (§5.3).
4. **"Render the surface blocks from space"** is satisfied in the only sense that has pixels: at
   LEO (h = 500) one block subtends ~3 px on a 2× laptop — a pitch-1 heightfield sample of the
   SAME generator is pixel-identical to a cube there. The rule shipped here is stronger than the
   parenthetical: **the real per-column terrain field stays visible from every altitude** (far
   ring relief IS worldgen output, never a textured ball), and every tier samples the one
   generator (§7) — so "the surface from space" is always the actual surface.
5. **Cross-fades are mostly the wrong tool.** WebGL2/gl_compat alpha blending across large
   overlapping terrain tiers means sorting artifacts + double fill. The shipped, proven mechanism
   is better: **overlap + exact shared sampling + a small sink** (the `FP_FARRING_FULL_COVER`
   contract, `cube_sphere.gd:250-258`) so the finer tier strictly overdraws the coarser one and
   the coarser one is *already correct* where it peeks out. Fades are reserved for the two places
   geometry genuinely appears/disappears super-pixel: tree impostors and skin tiles (dither/alpha
   over ~0.3 s, bounded count, §4.2).

The record of my own measured errors, per the standing instruction: web multiplier ×10 → measured
×25 (`COSMOS-STREAM-SCHED-DESIGN.md` §2.3a); surface class 5–15 ms → measured 560 ms (ibid.);
"acceptable veil" → rejected here (§0.1). This doc's own weakest links are listed in §12.

---

## 1. What the requirement invalidates (named, with file:line)

| Prior decision | Where | Status under the requirement |
|---|---|---|
| H_FARSWAP 20000: retire pool + far ring above; sphere impostor; rebuild-with-veil on descent | O1O4 §2.1 (`H_FARSWAP := 20000.0`), §2.8 | **REJECTED.** Replaced by §5: nothing retires until sub-pixel; the far ring persists to any altitude; the "impostor" is the same far-ring mesh under a continuous distance clamp. |
| O4c SOI swap "imperceptible **because** nothing voxel-scale exists above H_FARSWAP" | O1O4 §3.5 | **Argument dies, conclusion survives re-derivation** (§9): the swap is still imperceptible, but now because every resident tier's screen-space error at SOI range is < 0.2 px — proven by the SSE gate, not by having deleted the geometry. |
| "Loading veil acceptable v1" at the dominant-body/H_FARSWAP descent | COSMOS-ORBITAL-DESIGN.md §5.3(3), O1O4 §3.5 | **REJECTED.** §5.5/§9: rebuilds are SSE-scheduled to complete before their tier's error crosses ~1 px; post-L5 fill rates make the schedule feasible with 3–10× margin. |
| Fixed `OFFSURFACE_Y = 256` pool-freeze as a *visual* boundary | `cube_sphere.gd:284`, `world_manager.gd:2071-2075` | Kept as a **streaming** boundary (spawn freeze), stripped of visual meaning: pool *meshes* persist far above it and retire only sub-pixel (§5.5). |
| Sphere-impostor as the home body's far LOD | O1O4 §2.8, parent §4.4 | **REPLACED** for the home body by the scaled far ring (§5.2). Kept for *other* bodies only while they are genuinely sub-relief-pixel (§9). |

Not re-litigated (keystones): fixed frame @ identity, faceted pool 1+≤4 (Z1 ≤2 live), analytic
physics (no terrain collision meshes — `module_world.gd` `generate_collisions=false`), 128-block
near disc (`terrain_config.gd:129`), gl_compatibility/WebGL2, NEVER-OOM over visuals, no
intermediate near-LOD (user-removed), no 64³ mesh blocks, no extra workers, no 256-full-res.

---

## 2. The economics test — what L5 supply buys, and what it cannot

### 2.1 The measured base (2026-07-17, T1 per-class, SW-1, user's laptop)

Supply 23–35 blocks/s vs walking demand ~90–100 gross; per-class: surface-crossing **559.8 ms**
(46 % of gen time), underground gate-failed **337.7 ms** (51 %), web multiplier **~×25**
(`COSMOS-STREAM-SCHED-DESIGN.md` §2.3a). L5(a) — the whole `_generate_block` inner path as a C++
generator in the module patch set — is **underway now** per §2.6 of that doc; expected surface
560 → ~5–20 ms, underground 338 → ~2–10 ms ⇒ **supply ~300+ blocks/s ⇒ supply ≥ demand at every
walking speed**, and a skin tile ~60 ms → ~2–3 ms.

### 2.2 The thesis, tested

**Thesis:** the hard swaps existed because tiers were unaffordable; post-L5 they can overlap and
cross-fade, which is what satisfies "no stitches."

**Verdict: right in structure, and the honest boundary is this list.** Supply ≥ demand fixes:
the walking backlog (the obs-2/3 see-through class), the crossing prefill, time-to-cover-256
(~45 s → ~4–5 s voxel, ~1 s skin), re-entry pre-warm feasibility, and — critically — it makes
**overlap affordable**: tiers no longer fight for the same starved workers, so the skin can be
built *and kept current* underneath the voxel field instead of replacing it. What supply does
NOT fix, with the fix that does:

| Irreducible-by-supply item | Why supply can't fix it | Actual fix | § |
|---|---|---|---|
| Trees / carve mouths / SHARP-SLOPE shaping absent from skin + far ring | representation gap, not throughput | tree impostors in the skin (bounded multimesh); shaping is sub-pixel where skin shows (≥96–128 blocks — a 1-block shaping delta is < 2 px beyond ~350–700, and partially masked by fog) | §4.2 |
| **Player edits** invisible to skin/far ring — a dug quarry or built tower pops in/out at the voxel edge and at re-entry | the cheap tiers sample worldgen, not the overlay | tiers sample a per-column **edit surface delta** aggregated from `_edits` (already resident, fid-keyed) | §4.5 |
| Dihedral camera tilt at crossings (~3.75° instant at K=24) | geometry, not streaming | visual-only tilt easing ~0.3 s (§6.2) + the corner-flip rotation bug fix | §6 |
| f32/depth plumbing above 9k camera far | precision, not throughput | adaptive near plane + scaled-space clamp; f32 quantified harmless | §5.3–5.4 |
| Fly-speed demand at 32 m/s (~400–800 blocks/s gross > 300 supply) | demand scales with speed × radius | continuous speed-aware voxel annulus, skin carries the rest (unoutrunnable at ~2–3 ms/tile) | §8 |

None of these is a *discontinuity* that must remain; each has a bounded, flag-gated mechanism.
**Answer to the commissioning question: there is no irreducible stitch.** The closest to one is
the tree-pop at the voxel edge (a 7-block tree at 128 blocks subtends ~77 px — very visible),
which is why tree impostors are promoted from R3's "v2 option" to a first-class item (§4.2).

---

## 3. The law: screen-space error drives every tier

### 3.1 The metric (device-correct, per N4)

The web export renders 3D at **window × devicePixelRatio** (`export_presets.cfg:31`
`html/canvas_resize_policy=2`; `project.godot:21` `stretch/mode="canvas_items"` — see
`COSMOS-PERF-NEXT-ARCHITECTURE.md` §1.2). So "one pixel" is device-dependent and must be computed
at runtime, never hardcoded:

```
K_px = viewport_height_device_px / (2 · tan(fov/2))        # fov = 75° vertical (player.gd:115)
px(e, d) = e / d · K_px                                     # screen size of a feature/error of e blocks at distance d
```

`K_px ≈ 0.65 · H`: **704** at 1080p·DPR1, **1407** at 1080p·DPR2, ~2800 at 4K·DPR2. This is
chunked-LOD's ρ (Ulrich 2002) applied to fixed-resolution shells instead of a quadtree. All
thresholds below are written for DPR2-1080p (K_px = 1407, the user's laptop class) and are
**computed live from the actual viewport** in implementation (one function,
`CubeSphere.px_of(e, d)`; re-evaluated on resize).

### 3.2 The per-tier error budget and the derived distances

Geometric error of each tier vs ground truth (the voxel surface):

| tier | resolution | error e (blocks) | sub-1px beyond d = e·K_px | sub-2px beyond |
|---|---|---|---|---|
| voxel field | exact | 0 (+ trees exact) | — | — |
| skin pitch 1 | 1-block samples, min-bias | ~0.5–1 | 0.7–1.4 k | 350–700 |
| skin pitch 2 | 2-block | ~1–2 | 1.4–2.8 k | 0.7–1.4 k |
| skin pitch 4/8 (§4.3 extension) | 4/8-block | ~2–4 / 4–8 | 2.8–5.6 k / 5.6–11 k | half that |
| far-ring backstop | `BACKSTOP_CELLS=16` ⇒ ~12.5-block cells (`cube_sphere.gd:258`) | ~4–7 (FARRING-COVERAGE §3) | 5.6–9.8 k | 2.8–4.9 k |
| far ring horizon | `CELLS=4` ⇒ ~50-block cells (`facet_far_ring.gd:19`) | ~15–25 | 21–35 k | 10.5–17.5 k |
| sphere impostor (other bodies) | no relief | ~relief ≈ 64 (moon craters) | 90 k | 45 k |
| **content classes** | tree ~7 blocks | 7 | 9.8 k | 4.9 k |

Read-offs that anchor the whole design:

- **H_FARSWAP = 20000 was accidentally almost right** — it is where the CELLS=4 far ring's error
  goes sub-1–2 px. The number survives; its *meaning* flips from "retire everything here" to
  "above here, the coarse ring alone is pixel-exact — nothing else is even needed."
- The user's "surface blocks from space": at LEO (h = 500) a block is 1/500 rad ≈ **2.8 px** —
  super-pixel, so *some* tier finer than the backstop is owed; skin pitch-1 (error < 1 block
  < 2.8 px) delivers it exactly. Actual cube meshes are only distinguishable from heightfield
  samples below ~350–700 blocks — comfortably inside the streaming disc.
- Trees are the widest content error: sub-pixel only above ~5–10 k. Pool mesh retire must wait
  for that (or the skin must carry impostors) — §5.5.

### 3.3 The invariant this buys (the anti-stitch gate)

> **G-SSE-INV — no tier transition may fire while its screen-space delta ≥ τ_pop (default 1 px,
> computed for the live viewport).** Every retire, rebuild, scale-engage, impostor swap, and
> eviction logs `(event, e_blocks, d, px)` at fire time; the gate (headless: synthetic camera
> sweeps; live: telemetry assert) fails on any event with px ≥ τ_pop.

This converts "no stitches and jumps" from a review adjective into a regression test.

---

## 4. The tier continuum, end to end

```
T0 voxel field   0..R_v      exact; R_v = 128 shipped (terrain_config.gd:129), speed-adaptive §8,
                             ramped neighbours 96; FP_FULLRES_256 held as a later A/B (cube_sphere.gd:193)
T1 skin          ~96..256+   R3 heightfield tiles, pitch 1→2, sunk 1.5, + tree impostors + edit deltas
T1x skin ext     256..~800   pitch 4/8 rings (§4.3) — closes the skin→backstop resolution step
T2 far ring      whole body  CELLS=4 horizon + BACKSTOP_CELLS=16 sunk under T0/T1 (FP_FARRING_FULL_COVER)
T3 scaled body   d > D_eng   the SAME T2 mesh under a continuous distance clamp (§5.2) — the "impostor"
T4 other bodies  sphere impostor until their relief > ~1px, then their own T2 ring (§9)
```

The composition mechanism everywhere is **overlap + shared sampling + sink** (finer tier strictly
overdraws coarser; coarser is already correct where exposed) — the proven FULL_COVER contract
extended down-scale and up-scale. Per boundary:

### 4.1 T0 ↔ T1 (voxel edge, ~96–128 blocks): what pops today, what fixes it

Today: beyond the near disc there is only the 12.5-block backstop — arriving voxel meshes
change the ground *shape* visibly (obs-2/3 class), and outrunning supply exposes it. Post-L5 +
R3: the skin already carries **exact-silhouette 1-block relief** there, sunk 1.5 blocks
(STREAM-SCHED §5.1), so a voxel block's arrival changes the surface by ≤ the min-bias error
(< 1 block = < 8 px at 128 — visible only as a subtle sharpening) plus the **content classes**:

- **Trees** (the real pop: ~77 px at the edge): `FP_SKIN_TREES` — instanced impostor trunks +
  canopy billboards from the TreeGen column hash (deterministic, same hash the voxel path uses),
  per skin tile, MultiMesh, capped per tile and globally (ledger §10). When voxel meshes arrive,
  the tile's impostors for covered columns fade out over ~0.3 s (dither or alpha on the impostor
  material only — small quads, no terrain sorting hazard). This is the one place a *fade* is the
  right tool: the two representations genuinely differ super-pixel.
- **Carve mouths / SHARP-SLOPE cells**: ≤ 1–2-block deltas ⇒ ≤ 8–16 px worst at 128 but strongly
  foreshortened on terrain seen at grazing angles; accepted v1 (judged by the M3 screenshot
  protocol), with the §4.3 pitch ramp keeping them near-threshold. NOT worth per-cell geometry in
  the skin.
- **New-tile appearance**: a skin tile popping into an *empty* spot is a pop; but post-L5 the
  skin builds the full 256-disc in ~1 s from spawn and repaints incrementally thereafter —
  steady-state, tiles only ever *replace* backstop, a sub-2px event beyond 2.8 k… which at 256
  blocks is NOT sub-pixel (backstop error 4–7 blocks ≈ 22–38 px at 256). Hence tile arrival
  inside ~1–3 k must fade in (~0.3 s dither), and the M3 target is "covered before the player can
  look" (≤ 1 s), making it a spawn/teleport-only event in practice.

### 4.2 T1 internal (pitch 1 → 2) and T1 ↔ T1x ↔ T2 (the resolution ladder)

Pitch boundaries inside the skin are classic LOD-ring cracks. Mechanism: **CDLOD-style vertex
morph** (Strugar) *within the skin only* — each tile vertex carries its own height and its
parent-pitch height as two attributes; a per-vertex morph factor derived from camera distance
blends them across the outer 30 % of each ring. Pure vertex-shader arithmetic (no textures, no
extensions — works in gl_compat/WebGL2); tiles stay independently buildable. Cracks at tile
edges: the shared-edge rule (§7 — both tiles sample identical columns at shared vertices) plus
the sink means any residual T-junction pinhole shows sunk backstop of the same color — invisible.
The skin extension rings (pitch 4 @ 256–512, pitch 8 @ 512–800) exist because the backstop's
4–7-block error is 10–40 px in the 256–800 band a mountain vantage or low flight actually sees
(horizon from height H ≈ √(2·R·H): 250 blocks at eye level, ~780 from a 100-block peak, ~1600
at ATMO_TOP=384). Cost post-L5: a pitch-8 64-block tile is 9² samples ≈ trivial; the whole
256–800 annulus ≈ 150 tiles ≈ sub-second. Memory: coarse tiles are tiny (~2–8 KB); annulus adds
≈ 1 MB inside the existing 8 MB skin ceiling.

### 4.3 T2 (far ring) — already continuous, keep it

The far ring + FULL_COVER backstop is the *unoutrunnable* base: one merged mesh, one draw
(`facet_far_ring.gd`), whole-planet, static. Nothing changes at this tier except §4.5 edit
deltas and §5's persistence. Its known transition (a facet toggling backstop⇄horizon role across
a crossing, sink 0⇄6 on the next deferred rebuild) moves the surface 6 blocks at ≥128 distance
≈ ≤ 0.05° ≈ sub-2px — logged under G-SSE-INV but passes as shipped.

### 4.4 Edits in the cheap tiers (`FP_TIER_EDITS`) — the unnamed pop

`_edits` is fid-keyed and permanent (`world_manager.gd` FP-M1a); skin and ring ignore it, so any
surface-visible edit (tower, quarry, glass dome) appears only within the voxel disc — it will
pop at the disc edge and vanish from orbit. Mechanism: WorldManager maintains a per-column
**surface-delta aggregate** `(fid, col) → (top_y_override, dominant_color)` updated on edit
commit (O(1) per edit; derived data, rebuildable, bounded by edit count — already ledgered
memory). Skin tiles and backstop cells sample it after the worldgen profile: `h = max(gen_h,
override)` (and `min` for pure digs below gen surface). Fidelity: a 1-block hut is sub-pixel
beyond ~1.4 k — fine coarse; a 60-block tower stays visible from LEO exactly as the requirement
implies. v1 covers height + color only (no shape); the SSE table says that is sub-pixel wherever
the skin/ring is the presenting tier.

---

## 5. The atmosphere-space border (replaces O1O4 §2.8 wholesale)

### 5.1 What replaces H_FARSWAP: four mechanisms, no cliff

1. **Persistence**: pool meshes (frozen above `OFFSURFACE_Y=256` as shipped), skin, and far ring
   simply remain resident during ascent. Zero new cost — they were resident on the surface;
   NEVER-OOM position is unchanged by altitude.
2. **SSE-scheduled retire** (memory reclaim, not a visual event): each tier is *evicted* only
   when its **presence delta** (what the scene loses, = the error of the next-coarser tier plus
   its content classes) is sub-τ_pop on the live device. Derived altitudes at DPR2-1080p: skin
   evict ≈ h 3–6 k (pitch-2 error 1–2 blocks sub-1px beyond 2.8 k); pool-mesh evict ≈ h ~10 k if
   trees have no skin impostors, ≈ h 3–4 k with `FP_SKIN_TREES` on (the tree delta is then
   carried by the skin). Hysteresis ±25 % against bounce.
3. **Continuous scaled-space clamp** for the far ring (§5.2) above the last true-scale tier.
4. **Atmosphere as a visual ramp, not a border** (§5.6).

Descent runs the same ladder in reverse, **pre-scheduled by SSE**: each tier's rebuild is
launched when predicted `px(e_tier, d)` will cross τ_pop within its measured build time × 3
(margin). Post-L5 budgets: skin full disc ~1 s, voxel 128-disc ≈ 1300 blocks ≈ 4–5 s @300/s;
drag-capped descent from the rebuild altitudes gives 30 s + — margin ≥ 6×. The O1 re-entry
prepare_landing path (O1O4 §2.7) becomes the *last rung* of this ladder rather than a special
event. **No veil exists anywhere on the path.**

### 5.2 The home-body "impostor" is the far ring itself (`FP_SCALED_BODY`)

Above an engage distance the far ring is placed **camera-relative at a clamped distance with
angular-size-preserving scale**:

```
d      = |camera − body_centre|                (f64, from the orbital state)
s      = min(1, D_ENGAGE / d)                  # C0-continuous; == 1 exactly at engage
node:    position = cam + dir_to_body · d·s    # camera-relative placement (no anchor dependency)
         scale    = s
```

Because `s = 1` exactly at the engage point, geometry, parallax and angular size are **equal on
both sides of the switch** — there is no switch, only a reparameterization (KSP's scaled-space
made continuous; Elite's supercruise rendering uses the same identity). The far ring's per-vertex
relief remains the real worldgen field, so "surface from space" holds at every distance at the
fidelity the pixels can carry (§3.2). The sphere-impostor code path (O1O4 §2.8 v1) survives only
for *other* bodies below their relief-pixel threshold (§9). Engage: `D_ENGAGE = R + h_engage`
with `h_engage := max(all true-scale tier evict altitudes) + hysteresis` ≈ **10–12 k** at DPR2
(runtime-derived) — below it everything is true-scale; above it only ring + sky remain, so the
two scale frames never coexist on interleaved geometry (the parallax-shear failure mode is
structurally excluded). Cost: **zero bytes** (same mesh, same one draw call).

### 5.3 f32, quantified (the stated concern)

The far ring's vertex data is body-local (|v| ≤ ~2R = 6.1 k; offsets live in the node transform —
`facet_far_ring.gd:97-109`). Under anchor-follow (true-scale regime) the camera stays within
8192 of origin (`REANCHOR_TRIGGER_BLOCKS`, `cube_sphere.gd:345`), and under the clamp (scaled
regime) all magnitudes are ≤ D_ENGAGE + 2R·s ≤ ~18 k. Worst f32 pathway is the MVP subtraction of
two large translations: absolute error ≈ ulp(d) = 1.19e-7·d, i.e. **relative error ~1.2e-7 at
every distance** ⇒ angular error ~1.2e-7 rad ≈ **1.7e-4 px** at K_px = 1407. At the old worry
point (anchor 384 k, pre-clamp): ulp = 0.03 blocks at 384 k distance = 8e-8 rad. **f32 is never
within four orders of magnitude of visibility on this path**; the clamp additionally caps it.
f32 is therefore *not* a residual discontinuity — striking the last physical candidate for an
"irreducible stitch."

### 5.4 Depth and camera planes (the real plumbing cost)

True-scale visibility to h ≈ 10–12 k needs camera far ≈ tangent distance √(d² − R²) ≈ 11–14 k >
the shipped 9000 (`facet_far_ring.gd:22`). With near = 0.05 that is a 280 k far/near ratio —
24-bit depth resolution at z = 12 k is O(100) blocks, unusable *if* distant surfaces interleaved
(they don't: tiers overlap only ≤ ~800 blocks where δz < 0.1; beyond that a single ring). Still,
ship the standard virtual-globe fix (Cozzi): **altitude-continuous near/far**:
`near = clamp(h/256, 0.05, 8)`, `far = max(9000, 1.2·√(d²−R²))` — both C0 ramps (no visible
event; frustum changes don't pop when nothing visible is clipped, gate-asserted). In the scaled
regime far relaxes back to ~1.2·D_ENGAGE. One place: the camera rig (`player.gd:105-115`).

### 5.5 NEVER-OOM ledger for the border (all deltas)

| item | bytes | draws | note |
|---|---|---|---|
| far-ring persistence to any altitude | **0** (already resident) | 0 | the §0.1 point |
| `FP_SCALED_BODY` clamp | 0 | 0 | same mesh/node |
| skin persistence to its evict altitude | 0 beyond R3's ≤ 8 MB ceiling | ≤ ~50 (existing R3 ledger; merge-per-facet fallback if draws bind — standing was 58–60 fps at 62–195 draws, WALK-PERF §3) | evicted sub-pixel |
| skin extension rings §4.3 | ~+1 MB inside the 8 MB ceiling | ≤ ~20 coarse tiles | |
| tree impostors | MultiMesh ≤ ~64 B/instance, cap 4 k instances ≈ ≤ 0.5 MB (+ 2 small quad meshes/materials) | ≤ 2 | hard cap, evict with tile |
| edit surface-delta aggregate | O(edited columns) ≤ existing `_edits` order | 0 | derived, rebuildable |
| pool meshes kept to evict altitude | 0 (already resident; retire = reclaim) | 0 | retire IS the reclaim |

Everything defaults OFF (`FP_SCALED_BODY`, `FP_TIER_SSE`, `FP_SKIN_TREES`, `FP_TIER_EDITS`),
OFF == byte-identical, flipped at export after the measured A/B — the standing rule.

### 5.6 The atmosphere itself: a C¹ visual ramp (`ATMO_VISUAL_RAMP`, extends `ORBITAL_SKY`)

The border must also not *look* like a border: fog density, sky energy/color, and star visibility
become smooth functions of altitude sharing the drag model's scale height (O1O4 §2.6,
`H_SCALE = 128`): `fog_density(h) = fog₀·exp(−h/H_SCALE)`, sky→black and stars→full over
h ∈ [ATMO_TOP·0.5, ATMO_TOP·2.5], composed with the existing sun-elevation ramp (O0). All O(1)
environment uniforms per frame; zero geometry. This also *diegetically* thins the fog that today
helps mask pop-in — which is fine, because by the altitudes fog has thinned, SSE says the
resident tiers are pixel-exact.

---

## 6. Facet crossings — confirm/refute "nothing else pops"

Status confirmed from shipped instrumentation: the fixed frame made the crossing frame itself
cheap (`maybe_cross_facet` is O(1) bookkeeping + deferred far-ring rebuild —
`world_manager.gd:1708-1830`), FULL_COVER closed the see-through. The claim to test: *the
residual "slight jerk" is purely streaming (supply < demand ⇒ L5's problem).* Verdict:
**streaming is the dominant term, but not the only one. Two real residuals and one candidate:**

1. **The dihedral camera tilt — a real, unnamed stitch.** `apply_reframe` (player.gd:166-177)
   keeps the crossing *positionally* continuous to f64 and compensates yaw in-lattice, but the
   dihedral tilt "is carried by ActiveFrame" (player.gd:171): the player's up snaps from facet
   A's normal to B's in one tick — an **instantaneous camera roll/pitch of up to 90°/K = 3.75°**
   (1.8° post-O3 K=50) about the ridge axis. 3.75° in one frame is far above rotation-detection
   thresholds (~0.2–0.5°/frame); it reads as exactly the "slight jerk" reported. Fix
   (`FP_CROSS_TILT_EASE`): at commit, record `ΔR = T_to.basis⁻¹·T_from.basis` and apply a
   decaying visual-only counter-rotation to the **camera** (not physics, not velocity —
   locomotion stays exact) easing to identity over ~0.3 s (slerp, critically damped). Ten lines
   in the camera rig; flag-off byte-identical.
2. **The corner first-flip 90° turn** (memory `voxiverse-corner-seam`): a frame-rotation bug on
   the first flip at a cube corner — a genuine jump, must be root-caused and fixed regardless of
   this design (no flag; it is a defect, not a policy).
3. **Far-ring role staleness** (≤ 1–2 frames of old exclusion set before the deferred rebuild,
   `facet_far_ring.gd:124` region): the old merged mesh still covers the region during them
   (FARRING-COVERAGE §4) and the sink delta is sub-2px (§4.4) — **acquitted**.
4. LOD/skin tile boundaries across the ridge: tiles are per-facet; the atlas welds seam heights
   and §7's shared-edge rule makes adjacent facets' tiles sample identical columns at the shared
   ridge (including `junction_modify` — the sampler contract, §7.2 item 4). Backstop continuity
   across a ridge is already shipped geometry. **No mechanism to pop** — asserted by the tile
   shared-edge gate (§10 C3).

**The discriminating A/B (cheap, do first):** remote-drive a crossing with the destination facet
fully pre-generated and backlog ≈ 0 (stand at the ridge until `vox_gen ≤ 5`, then cross). If a
jerk persists with an idle pipeline, it is item 1 (the tilt), not streaming — 10 minutes on the
live loop, and it decides whether `FP_CROSS_TILT_EASE` ships in the first wave.

---

## 7. The one-sampler law (design law + the L5 interface contract)

### 7.1 The law

> **Every tier — voxel, skin, far ring, scaled body, other-body ring, edit deltas aside — must
> sample the SAME worldgen implementation, parameterized by stride/LOD; a second implementation
> of any terrain quantity is a guaranteed seam.** Corollary: when L5 lands, the C++ generator
> **is** that implementation, and every GDScript sampling site must be able to route to it.

Today the law almost holds: everything funnels through `TerrainConfig.profile_at_dir` /
`facet_profile` / `resolve_cell` (one choke point — O1O4 §1), which is *why* the tiers agree.
L5 creates the first real risk of bifurcation: a C++ path for the voxel workers while analytic
physics (`WorldManager.block_id_at` → `resolve_cell`), the skin, the far ring
(`facet_far_ring.gd:390,434`), and the LOD builder keep calling GDScript. Two implementations of
`resolve_cell`/`column_profile` maintained in parallel WILL drift — and a drift between the
physics oracle and the rendered mesh is worse than a seam (float-through/fall-through class).

### 7.2 The interface L5's C++ generator MUST expose (forward to the implementer)

1. **`generate_block(buffer, origin, size, fid)`** — the worker path (already the port's shape,
   STREAM-SCHED §2.6: whole inner path, frozen tables in once at setup, no per-cell script calls).
2. **Batch heightfield sampling for the cheap tiers** — the new requirement this design adds:
   `sample_columns(fid: int, cells: PackedInt64Array /*packed (x,z)*/) →
   {heights: PackedFloat32Array, biomes: PackedInt32Array, water: PackedByteArray,
   colors: PackedColorArray /*or palette ids*/}` — ONE call per skin tile / backstop grid
   (33²–65² columns), amortizing the boundary cost that would otherwise eat the win
   (per-call GDScript→C++ round trips are exactly what §2.6 forbids per-cell). Target: a 64×64
   pitch-2 tile ≤ ~1 ms. Must include the ridge/junction treatment (`junction_modify`) so
   adjacent facets' tiles agree bit-exactly at shared seam columns.
3. **Scalar parity queries callable from GDScript** — `column_profile(fid, x, z)` and
   `resolve_cell(...)` equivalents exposed via ClassDB, so `block_id_at`/`height_at` (the physics
   truth) can route to the SAME core under the port flag. The GDScript twin is retained
   permanently ONLY as the byte-equality oracle, never as a live second path.
4. **Purity contract**: pure function of (frozen tables handed over once, fid, cell) — no
   callbacks into script, no engine singletons, thread-safe const after setup (the frozen-epoch
   discipline, made structural).
5. **The gate**: the planned N ≥ 256-block byte-equality gate (STREAM-SCHED §2.6.3) **plus** a
   column gate — ≥ 10⁴ random `sample_columns` outputs == GDScript `column_profile`, spanning
   biomes, ridges, seam columns, and tree stencils; and a physics-parity gate (`block_id_at`
   through C++ == through GDScript on random edited+unedited cells). FLAT verify 6035/0
   throughout.

Item 2 is the load-bearing addition: it is what makes the skin, the extension rings, the
backstop refresh, and future Moon tiles all cost milliseconds *and* agree with the voxel surface
exactly — the mechanical embodiment of "no stitches."

---

## 8. Flying — what the scheduler owes a fast mover

Demand law (matches the measured §1.3 decomposition of WALK-PERF): swept-volume demand for a
voxel disc of radius R_v at ground speed v is `blocks/s ≈ k_gross · 2·R_v·v/256 · N_y`, with
N_y ≈ 6.5 block-layers and k_gross ≈ 2–4 (ramps, lead, probes — measured 90–100 gross vs 15–20
ellipsoid at v = 3.4). So demand is **linear in v and in R_v** (the prompt's "speed³ cone" is
pessimistic — no cubic term exists; the cone is R9's lead volume, linear too):

| v (m/s) | mode | gross demand @R_v=128 | vs post-L5 supply ~300/s |
|---|---|---|---|
| 3.4 | walk | ~90–100 | fine (margin 3×) |
| 9.5 | run | ~250 | marginal |
| 16 | fly g1 | ~420 | deficit |
| 32 | fly g1 sprint | ~840 | deficit 3× |
| 100–550 | g2 ascent/orbital | n/a — climbing leaves the terrain volume; demand → 0 above OFFSURFACE | cheap by construction |

So R2 (lazy neighbours) + R9 (idle lead) suffice post-L5 **for walking and running only**; fast
atmospheric flight needs a **speed-aware tier policy** — but per the continuum requirement it
must be a continuous law, not R5's discrete SPRINT mode. `FP_SPEED_ANNULUS`:

```
R_v(target) = clamp( 0.8·S_meas·256 / (k̂·2·v̂·N_y), 48, near_render_radius() )
```

with `S_meas` = the controller's measured supply (blocks/s, EMA), `v̂` smoothed speed, `k̂` the
measured gross factor — i.e. the StreamLoadController closes the loop so **voxel demand never
exceeds 80 % of measured supply**; the skin (unoutrunnable: tile demand at v=32 ≈ 4 tiles/s ×
2–3 ms ≈ 1 % of the builder thread) carries R_v..256+ with exact silhouette + tree impostors.
Slew-rate-limit R_v (grow ≤ 8 blocks/s, shrink ≤ 32/s) + hysteresis so the annulus breathes
instead of snapping; the transition at the annulus edge is the §4.1 boundary, already fade-
hardened. At fly-32 the equilibrium is R_v ≈ 64–80 — visually: crisp trees to ~70 blocks, exact
terrain shape to 256+, which is what a player moving at 32 m/s can actually inspect. This
**supersedes R5** (its discrete shed) and re-scopes R6 (gaze viewer) to a post-L5 luxury,
re-evaluated per STREAM-SCHED's operative ranking. Descent (the re-entry case) is owned by the
SSE schedule (§5.1) with drag capping v at 55 (O1O4 §2.6) — margin 6×.

---

## 9. The Moon and the SOI swap, re-derived (amends O1O4 §3.5)

The old argument — "the swap is imperceptible because nothing voxel-scale exists above
H_FARSWAP" — is void (§1). The re-derivation under SSE:

- At the Earth↔Moon SOI crossing (≥ 64 k from the Moon, ~318 k from Earth), Earth's persisted
  scaled ring subtends 2R/d ≈ 1.1° ≈ 27 px; its CELLS=4 error (15–25 blocks) is **0.07–0.11 px**
  — sub-pixel by an order. The swap's only render-side effect (scene spin-frame re-expression;
  rendered sun/star directions continuous — the existing G-O4-SWAP assert) touches nothing with
  super-pixel error. **The swap stays imperceptible — now proven by G-SSE-INV, not by geometry
  deletion.**
- **Moon approach**: the sphere impostor's error is the lunar relief (~64 blocks: craters,
  O4b kernel), super-1px inside d ≈ 90 k (DPR2). So the Moon's far ring (1176 facets, ~1.5 MB,
  seconds to build from `sample_columns`) is built async when d < ~120 k (hysteresis 25 %) —
  at gear-3 speeds that is minutes before it matters; the impostor→ring handover fires sub-pixel.
  Then the §5.1 descent ladder runs on Moon fids through the one re-entry path (O1O4 §3.5's
  "one path" property is kept — it was the good half of that section), with `PREWARM` at the
  airless-body 4096 (D-O4-5 unchanged).
- Depth-order polish: when multiple clamped bodies can overlap along a ray (eclipse geometry),
  assign clamp distances preserving true distance order — one comparison, noted for O4c.

Net: O4c loses its veil clause and gains two SSE triggers; everything else in Part B stands.

---

## 10. Ranked plan

Route for all kill metrics — **SW-ORB-1** (extends SW-1; remote-drive, fixed seed/spawn):
fresh reload → stand 10 s → walk 90 s (one crossing) → stop 30 s → fly g1 32 m/s 60 s (≥ 2
crossings) → climb through ATMO_TOP to h = 8 k → (post-O1) g2 to LEO, 1 orbit → deorbit → land →
walk 30 s. Integrated, unconditioned metrics (the L4b lesson — never condition on streaming
state): **P1** pop events = camera-quiet frame pairs (|Δcam| < ε) with downsampled screendiff >
threshold, target **0**; **P2** G-SSE-INV violations (logged transitions with px ≥ 1), target
**0**; **M1** % 250 ms windows worst_ms > 100; **M2** unconditional fps p10; **M3**
time-to-cover-256 (target ≤ 1.5 s post-L5); **M4** ∫vox_gen dt; **M5** hole/see-through probe.
Ship rule per item: its named metric improves, no other regresses > 10 %.

| # | item | mechanism | expected effect (number to beat) | flag | NEVER-OOM | kill metric |
|---|---|---|---|---|---|---|
| C1 | **L5 sampler contract** (§7.2 — shape the port NOW) | batch `sample_columns` + ClassDB parity + purity + gates | skin tile 60 → ≤ 1–3 ms; physics/render single-source | (port's flag) | zero | byte-equality gates 100 %; FLAT 6035/0 |
| C2 | **Far-ring persistence + scaled clamp** (kills H_FARSWAP retire/veil) | §5.1–5.4: no retire, `s = min(1, D_ENGAGE/d)`, adaptive near/far | border pop events → **0**; ascent/descent veil count → 0 | `FP_SCALED_BODY` | **0 bytes** | P1=P2=0 on the climb leg |
| C3 | **R3 skin** + shared-edge gate + §4.3 pitch rings + CDLOD morph | post-L5 economics (STREAM-SCHED §2.6 re-ranked it #2) | M3 45 s → ≤ 1.5 s; edge sharpening ≤ 1 block | `FP_SKIN_TIER` | ≤ 8 MB ceiling (+1 MB rings) | M3 + t=5 s screenshot; P1 on walk leg |
| C4 | **SSE transition scheduler** (§3.3, §5.1) | runtime K_px; retire/rebuild/evict only sub-1px; logs every event | converts "no stitches" into a failing test | `FP_TIER_SSE` | 0 (scheduler only) | **P2 = 0** whole route |
| C5 | **Atmosphere visual ramp** | §5.6 fog/sky/star C¹ ramps on h | border *look* continuous; screenshots | `ATMO_VISUAL_RAMP` | 0 | P1 on climb; user screenshot pass |
| C6 | **Crossing tilt ease + corner-flip bug** | §6.1 camera slerp 0.3 s; §6.2 root-cause | crossing jerk with idle pipeline → imperceptible; A/B §6 discriminates first | `FP_CROSS_TILT_EASE` (bug: none) | 0 | P1 at crossings with vox_gen ≤ 5 |
| C7 | **Speed-aware annulus** | §8 closed-loop R_v, slew-limited | fly-32: M5 = 0 AND M4 bounded (backlog flat) | `FP_SPEED_ANNULUS` | 0 (shrinks live volume) | fly-leg M5=0, M4 flat, P1=0 |
| C8 | **Tree impostors** | §4.1 MultiMesh from TreeGen hash + 0.3 s fade | edge tree-pop (77 px class) → fade; enables lower pool-evict | `FP_SKIN_TREES` | ≤ 0.5 MB cap | P1 on walk/fly legs; screenshot |
| C9 | **Edit deltas in cheap tiers** | §4.5 per-column aggregate | built structures visible from orbit; no edge pop | `FP_TIER_EDITS` | O(edits), derived | scripted build-tower probe: visible at h=8 k |
| C10 | **Moon ring by angular trigger** (O4c amendment) | §9 build at d<120 k; ordered clamps | O4c veil clause deleted | inside `MULTI_BODY` | +1.5 MB while relevant | P2=0 across SOI leg (O4c gate) |

Order: C1 immediately (the port is being written NOW); C6's A/B + bug next (cheap, walking UX
today); C2+C4+C5 as the border wave (needs O1a's altitude plumbing to matter, but C2's clamp +
C4's scheduler are testable headless with a synthetic camera); C3+C8 post-L5-merge; C7 after C3;
C9 anytime; C10 rides O4c. Every flag OFF ⇒ byte-identical; FLAT 6035/0 (6056/0 orbital) holds
throughout.

---

## 11. SOTA — what actually ports

| source | their ground↔orbit mechanism | verdict for godot_voxel 1.4.1 + WebGL2 + 16-slot pthread + faceted cube-sphere |
|---|---|---|
| **Chunked LOD** (Ulrich '02) | screen-space error ρ = e/d·K drives selection | **The core of §3** — ported as fixed shells instead of a quadtree (our tiers are shells; no tree needed at one planet's scale). |
| **CDLOD** (Strugar) | per-vertex morph between LOD levels, no cracks | Ports **within the skin** (§4.3): vertex-attribute morph, gl_compat-safe. Not across representation changes (cubes↔heightfield) — there we use overlap+sink instead. |
| **Geometry clipmaps** (Losasso/Hoppe) | nested regular grids around the viewer | The skin's pitch rings ARE a poor-man's clipmap; full GPU clipmap needs vertex-texture streaming — possible in WebGL2 but not worth it at our tile counts. |
| **KSP** | scaled-space replica + PQS; the swap is a known visible seam modders patch | Adopt the scaled-space *identity* but make it continuous (s=1 at engage, §5.2) — removing exactly the seam KSP shipped with. |
| **Outerra** | true ground-to-space, log-depth, fractal refinement | Log-depth needs shader control of gl_FragDepth everywhere (kills early-z, not viable across Godot's material set). Substitute: adaptive near/far (§5.4) + clamp — same effect at our scales. |
| **Elite Dangerous** | 64-bit + dual-float GPU math, quadtree planets, supercruise scaled rendering | 64-bit engine rejected (unchanged); the *rendering* trick (clamped-distance scaled bodies) is C2. |
| **Star Citizen** | 64-bit zones, camera-relative render | Camera-relative IS our anchor discipline (`REANCHOR`); zones = ActiveFrame (already shipped). Nothing new to take. |
| **Space Engineers** | static voxel planets, LOD swaps with visible pops, billboard impostors | Cautionary: hard LOD swaps on voxel terrain read badly — their pops are the class G-SSE-INV forbids. Their billboard impostors validate C8. |
| **No Man's Sky** | streaming LOD rings; atmosphere haze masks transitions; planets don't truly orbit | Haze-as-mask ports diegetically (C5 makes it altitude-honest); the frozen-sky half is what this project explicitly surpasses. |
| **Distant Horizons / Veloren** | heightmap-only far LODs, cancel-on-out-of-range | Already the R3/R4 validation (STREAM-SCHED §10). DH's colored-quad far tier = our far ring. |
| **Virtual globes** (Cozzi & Ring) | RTC rendering, adaptive near/far, depth partitioning | RTC = our anchor; **adaptive near/far adopted verbatim** (§5.4); multi-frustum depth partitioning kept in pocket if one frustum's 24-bit budget ever fails a gate. |

Honest non-ports: GPU-driven refinement/compute LOD (no compute in WebGL2), log-depth (above),
persistent-mapped buffers (absent), hardware tessellation (absent), any WebGPU-era path
(renderer-gated through 4.7, unschedulable — unchanged verdict).

---

## 12. Risks, open decisions, and this doc's weakest links

| risk | exposure | mitigation |
|---|---|---|
| L5 lands without the batch/parity API (C1 arrives late to shape it) | skin economics stay ×25; physics/render bifurcation risk | **forward §7.2 to the implementer now** (this doc's most time-critical output); the parity gate blocks the port flag regardless |
| SSE thresholds mis-derived on unusual DPR/resolutions | pops on devices we don't test | K_px computed from the live viewport (§3.1) + P2 telemetry logs every transition's px on real clients |
| Skin draw-call count binds on weak GPUs | fps regression with `FP_SKIN_TIER` on | measured A/B (standing 62–195 draws @60 fps is the headroom datum); merge-per-facet fallback pre-designed |
| Tilt ease feels floaty / motion-sick to some | taste | 0.3 s critically-damped default, constant exposed, screenshot/feel pass; flag-off = shipped behavior |
| Adaptive near plane breaks a near-field effect (aim highlight, held-block view) | visual glitch in flight | near ramps only with altitude (h/256) — at ground it is exactly 0.05; gate sweeps the ramp |
| Edit-delta aggregate drifts from `_edits` | ghost/missing structures far out | derived-data rebuild on load + a consistency assert in the verify pass |
| Scaled-space clamp vs future O2 grids at high altitude | a grid near the player while the body is scaled | grids are true-scale near-field by construction (≤ km from player); the body is the only scaled node; ordering rule §9; O2 gate to assert no interleaving |
| This doc's weakest links (stated openly) | — | (a) k_gross ≈ 2–4 in §8 is inferred from one decomposition (WALK-PERF §1.3, "unverified decomposition") — E8/L4's instrumented walk should pin it before C7 is tuned; (b) the tree-impostor look at 96–256 blocks is a taste call — screenshot A/B is the decision artifact; (c) §6's claim that the dihedral tilt is perceptible is argued from thresholds, not yet measured — the §6 idle-pipeline crossing A/B settles it in 10 minutes; (d) post-L5 supply ≈ 300/s is the port's *expectation*, not a measurement — every C-item that depends on it re-runs its numbers when L5's SW-1 lands |

Open decisions for the user: D-S1 τ_pop (1 px default vs 2 px lenient — trades earlier evictions
for theoretical visibility); D-S2 tree-impostor style (billboard vs low-poly trunk+blob); D-S3
whether `FP_SPEED_ANNULUS`'s minimum R_v (48) is acceptable at sprint-fly (screenshot pass).

What this doc deliberately does not do: implement anything; re-litigate D1/D2/D5 or any locked
keystone; design portals, grids (O2), or multiplayer; change the near-field look at walking
scale in any way with flags off.
