# COSMOS FARTREE-FRAME — far-tree impostors mis-rotated + mis-lifted vs the near voxel trees (task #131)

Status: DESIGN. Proposed flag: `FP_FT_FRAME_WELD` (new, default `false`, byte-identical off).
Author: Fable architect session 2026-08-13.
Parent docs: COSMOS-FARTREE-ALIGN-DESIGN.md (#120 weld+cull), COSMOS-FARTREE-SHIFT-RESIDUAL-DESIGN.md
(#120-residual/#130), COSMOS-FAR-TREES-DESIGN.md (the tier), COSMOS-FACET-SEAMS-V2.md (FS2′ datum bake),
COSMOS-NB-JUNCTION-WELD-DESIGN.md (#104 — read for what it does NOT change: placement).

---

## 1. Symptom + what was measured (all against the SERVED build, not the repo)

Live (after the #120 align + FT_SINK_MAX 1.0→0.15 retune): FAR tree impostors in the archetype-mesh band
[128,448) render **offset in altitude AND yaw-rotated** vs the NEAR blocky trees. Observed at facet 1133,
`facet_neighbours=2`, alt 14, pos (22274, 15, 23346), cam_yaw −71°
(frame-1786624963274-042.jpg: near trees axis-aligned face-on; several mid-band canopies corner-on/diamond,
sitting flush on the grass with trunks swallowed). The earlier warm-forest A/B (facet 1754, alt 59) had
been read as "aligned".

Measured for this design (fresh, this session):

1. **Live flag dump** — the served `build/web/index.pck` (this deploy worktree, Aug 13 14:20) loaded
   headlessly, constant map dumped: `FP_DATUM_BAKE = true`, `FP_RADIAL_DATUM = false`,
   `FP_NB_FULLRES = true`, `FP_NB_WELD = true`, FAR_TREES family all true, `FT_SINK_MAX = 0.15`,
   `FP_FIXED_FRAME = true`. (The main checkout's `build/web/` is a STALE export — 243 constants, no tree
   flags; always dump the worktree pck.)
2. **Facet geometry, computed exactly** (replicating `CosmosFacet.vertex_dir` + `FacetAtlas._build_facet`
   in f64, R=6371, K=24):

   | fid | face,i,j | yaw(t1_far, ê_u) | **visible rot (mod 90°)** | datum s at centre / edge-mid / corner |
   |---|---|---|---|---|
   | 1133 (player) | 1, 23, 5 | 91.2° | **1.2°** | +5.48 / +3.32 / −1.51 |
   | 1132 / 1134 / 1109 | face 1 | 91.1–91.2° | **1.1–1.2°** | +5.4…+5.6 centre |
   | **1733 / 1732 / 1734** | **face 3** (across the fold) | 48.8–59.0° | **31–41°** | +5.4…+5.6 centre |
   | 1754 (the "aligned" A/B) | 3, 1, 2 | 36.7° | **36.7°** | +5.75 centre |

   Facet 1133 is at i=23 — the LAST row of face 1: its boundary is a **cube-face fold** (neighbours
   1732-1734 on face 3; lattice ê_u across the fold turns 36.5°, dihedral 3.6°).
   Tilt of the true radial vs the facet normal: 0.03° at centre (≤ ~2.6° at corners) — negligible.

---

## 2. Root cause — two independent frame defects, both in facet_far_trees.gd, NEITHER is the anchor's fid

### 2.1 What the near tree's world pose actually is (the law to match)

- Every near voxel slot — active AND neighbour (FP_NB_FULLRES) — is placed at
  `FacetAtlas.facet_transform(fid)` (module_world.gd:1926; one construction path for all slots),
  whose basis is the facet lattice `(ê_u, n̂, ê_w)` and whose f32 map equals `lattice_to_world64`
  by construction (facet_atlas.gd:542-549 vs :402-408).
- Each slot's mesher additionally carries the **FS2′ datum bake** for ITS fid
  (module_world.gd:1908-1911; active path :402, :1872-1875; C++ patch 0010): every near-mesh vertex is
  lifted `y += s(fid, x, z)` with `s = FacetAtlas.datum_lift` (facet_atlas.gd:471-486) — the continuous
  solve that puts the facet-PLANE lattice onto the true SPHERE. **Live `FP_DATUM_BAKE = true`** ⇒ the
  near tree's trunk-bottom-face centre is
  `W_fid · (bx+0.5, gy+1+s(fid, bx+0.5, bz+0.5), bz+0.5)`, cubes axis-aligned to `(ê_u, n̂, ê_w)`.
- The far *terrain* tiers agree with that: V2 and the far ring emit **radially** from
  `facet_corner_dirs` (facet_smooth_v2.gd:72-75; facet_far_ring.gd:2575 etc.) — on the sphere — and the
  skin tier, which does use the plane map, **adds the lift explicitly**:
  `lattice_to_world64(fid, x, y + FacetAtlas.datum_lift(fid, x, z), z)` (facet_skin_tier.gd:554-560).

### 2.2 Defect A (ALTITUDE): the far-tree anchor omits the datum lift — it is the ONLY placement left on the facet plane

The #120 enum anchor is `lattice_to_world64(fid, bx+0.5, gy+1, bz+0.5)` (facet_far_trees.gd:739-742) —
**no `datum_lift` term**. The #120 anchor law (COSMOS-FARTREE-ALIGN-DESIGN.md §2.1/§4.1) equated the near
trunk base with the plane map, and gate G-FTA-1 pinned exactly that — but the lift lives in the C++
mesher, invisible to the headless GDScript gate, so the pinned law is right only where s ≈ 0.

Error = `s(fid, bx, bz)` ∈ **[−1.5, +5.5]** blocks (sign included: near facet corners the planarized
plane pokes ABOVE the sphere, so the far tree *floats* ~1.5; mid-facet it is *buried* ~5.5; ~3.3 at edge
midpoints). Position-dependent — which is why the #120-residual census (a band that evidently crossed
low-s terrain) measured "bases on the grass" while frame-042's mid-facet trees show canopies swallowed to
the ground. This also answers the FT_SINK question: the far tree IS above the near ground in places —
by up to ~1.5 blk near corners — and that is the datum sign, not the 0.15 sink (which is noise at this
scale).

### 2.3 Defect B (ROTATION): the instance basis is a world-axis tangent frame, not the facet lattice

`_write_card` (facet_far_trees.gd:962-980) and `_write_mesh_inst` (facet_far_trees.gd:1075-1085) build
the per-instance basis as

```
t1 = normalize(r × ŷ_world)   # ŷ = Vector3(0,1,0) — NOT the planet axis (poles are ±Z)
t2 = normalize(r × t1)         # basis = (t1, r, t2)
```

The near tree's cubes are axis-aligned to the owner facet's `(ê_u, n̂, ê_w)`. Since near cubes are
90°-symmetric, the visible error is `yaw(t1, ê_u) mod 90°` — **0-45°, a function of where the facet sits
on the sphere**: ≈1.2° for the face-1 facets around 1133 (invisible), **31-41° for the face-3 facets
across 1133's fold**, 36.7° at 1754. Standing on 1133 at the fold, the player sees their own facet's far
trees straight and the cross-fold facets' far trees turned ~36° — the observed "rotated at the boundary".
The 1754 A/B did not falsify this: it verified *height* (the #120 census counts trunk pixels, not
orientation), in a dense forest where a uniform 37° yaw of every canopy has no straight-edge reference.

### 2.4 Why the "neighbour-frame anchor" hypothesis is DEAD (the lead to test first)

The near neighbour tree does **not** render in the active facet's frame. Its slot is placed at
`facet_transform(neighbour_fid)` (module_world.gd:1926 — the one shared construction path;
the FP-R0 spike comment :2687-2691 documents the same law), and FP_NB_WELD changed only the
`pool_seam_meshed` PROBE (module_world.gd:2032-2035), never placement. The far anchor evaluates the SAME
`W_fid` map for the SAME owner fid (facet_atlas.gd:402-408 == :542-549 in f32). So for a cross-facet
tree, far and near agree on the frame *for position* by construction — there is no inter-facet
rotation/offset term in the anchor. What made the bug read as "boundary-specific" is that the
**boundary is where facets with different B-defect yaw errors are visible side by side** (and, at a
cube-face fold, the yaw error jumps 35°+ across the seam).

Also ruled out, with cites:
- **Residual E4 lateral skew**: none — the anchor centring `(bx+0.5, bz+0.5)` is exact
  (facet_far_trees.gd:740-741), `lattice_to_world64` is the slot map, and the datum lift is along n̂
  (no lateral component). No lateral offset was measurable in frame-042 foreground/midground pairs.
- **Card billboard/orientation**: cards are NOT camera-billboards — they get the same static
  `(t1, r, t2)` basis (facet_far_trees.gd:964-975), so they share defect B (harmlessly at card
  distances; the visible rotation is the rung-1 MESH band, whose corner-on cubes frame-042 shows).
- **Warm-up/settle transient**: both defects are pure static functions of (fid, position) baked into
  the enum records / instance buffers — persistent, not settle-dependent. (The #130 dwell-stall was the
  transient class and is already fixed.)
- **FT_SINK_MAX over-correction**: 0.15 uniform vs a ±5.5 signed position-dependent error — wrong shape,
  wrong magnitude; not implicated.

---

## 3. Fix — `FP_FT_FRAME_WELD`: place AND orient the far tree in the owner facet's near law

One new flag, two one-site changes, both in facet_far_trees.gd. Both are per-owner-fid — this fixes
active-facet and neighbour/cross-fold trees identically (there is no special "boundary" code path,
because §2.4 shows none is needed).

### 3.1 Part A — anchor datum lift (altitude)

In `_enum_worker`, after the ALIGN centring (facet_far_trees.gd:740-741), before `lattice_to_world64`
(:742):

```gdscript
if CubeSphere.FP_FAR_TREES_ALIGN and CubeSphere.FP_FT_FRAME_WELD:
    ay += FacetAtlas.datum_lift(fid, ax, az)     # FS2′: onto the sphere, matching the near-mesh +s bake
```

- `datum_lift` is pure frozen-frame f64 arithmetic (facet_atlas.gd:471-486) — worker-safe (the
  skin-tier precedent, facet_skin_tier.gd:560, and the enum worker already reads frozen FacetAtlas).
- It returns 0.0 unless `FP_DATUM_BAKE` — the anchor **tracks the live near-mesh law by construction**
  (datum off ⇒ identical bytes even with the weld flag on; no second source of truth).
- The signed solve is kept as-is: negative s near corners LOWERS the anchor exactly as the near mesh
  sits lower there.
- The NEARCULL probe box stays in lattice coords (facet_far_trees.gd:517) — `is_area_meshed` is voxel
  content, datum-agnostic; no change.

### 3.2 Part B — orientation weld (rotation)

In `_rebuild_cards` / `_rebuild_meshes`, hoist once per wanted facet:
`var fb := FacetAtlas.frame_basis(int(fid))` (facet_atlas.gd:828-832), and pass it to the writers.
In `_write_card` (facet_far_trees.gd:964-975) and `_write_mesh_inst` (:1077-1085), under the flag,
replace the `(t1, r, t2)` construction with the owner lattice basis:

```gdscript
t1 = fb.x        # ê_u — the near cube X axis
uy = fb.y        # n̂  — the near column axis (replaces r as the instance up/scale axis)
t2 = fb.z        # ê_w
```

Scales unchanged (`hs`/`vs`); the stored r̂ keeps serving the ALIGN sink ramp (:942-944, :1052-1054)
untouched. Handedness is safe: `ê_w = ê_u × n̂` (facet_atlas.gd:288) ⇒ `Basis(ê_u, n̂, ê_w)` is
right-handed det=+1 (asserted by verify_frame — module_world.gd:2687 comment) — no negative-scale
MultiMesh trap. Shaders untouched: the radial shading normal comes from the `planet_centre` uniform,
not the instance basis; the trunk-stretch acts on local Y, which is now n̂ (matches the near column
axis better than r did, by the ≤2.6° tilt). Flag off ⇒ the shipped basis floats verbatim.

With A+B, a cross-facet far tree's anchor and basis are **the same numbers** the neighbour slot's
transform + datum bake give the near tree — position AND rotation weld by construction, not by tuning.

### 3.3 Explicitly rejected

- Orienting to the ACTIVE facet's frame (the task-prompt phrasing): would rotate a neighbour tree
  ~3.7° (or 36° across a fold) AWAY from its own near twin. The near law is per-OWNER-fid; so is the fix.
- A camera-yaw/billboard basis for meshes: breaks the blocky-voxel identity with the near tree entirely.
- Fixing only the fold facets: defect B is global (1754 = 36.7° on a non-boundary facet); the weld is
  uniform.

---

## 4. Flags / consts / byte-off

```gdscript
cube_sphere.gd (beside the FP_FAR_TREES family, :886+ pattern):
  const FP_FT_FRAME_WELD := false   # §3: owner-facet frame weld — anchor +datum_lift (A) + lattice-basis orientation (B)
```

Byte-off: part A is a single guarded add in the enum (off ⇒ shipped record floats verbatim); part B a
single guarded basis selection in each writer (off ⇒ shipped buffer floats verbatim). No shader, draw,
instance-count or memory change anywhere. gl_compat-safe. Part A composes with (requires) the shipped
`FP_FAR_TREES_ALIGN`; with `FP_DATUM_BAKE` off it is inert by construction.

## 5. Perf ledger

| Item | Δ |
|---|---|
| Enum worker | +1 `datum_lift` (~20 flops) per tree, off-thread, per-facet enumeration — noise |
| Rebuild | +1 `frame_basis` per wanted fid (≤ FAR_TREES_CACHE_FACETS lookups) per rate-capped rebuild |
| Draws / instances / memory / shaders | 0 |

## 6. Gates (extend verify_far_trees.gd) + live A/B

Headless:

- **G-FTF-1 anchor+datum**: sampled trees on ≥2 facets: `world_to_lattice64(fid, anchor)` ==
  `(bx+0.5, gy+1+datum_lift(fid, bx+0.5, bz+0.5), bz+0.5)` (flag+ALIGN on) / the #120 law (off).
  Run with `FP_DATUM_BAKE` both states — off, the two laws must coincide (pins the tracking property);
  on, assert ≥1 sampled tree has |datum_lift| > 2 (the gate must exercise a mid-facet column, or it
  proves nothing — the G-FTA-1 lesson).
- **G-FTF-2 orientation**: emitted basis columns (buffer floats 0-2/4-6/8-10) == `(ê_u·hs, n̂·vs, ê_w·hs)`
  (cards) / unit `(ê_u, n̂, ê_w)` (meshes) of the record's OWNER fid under the flag; == the shipped
  `(t1, r, t2)` floats off (bit-compare).
- **G-FTF-3 cross-fold weld** (the task gate): a face-fold pair (1133/1733 class — derive one from the
  atlas, don't hardcode): for a tree OWNED by the cross-fold fid, assert far anchor == the near law
  point AND far basis == `frame_basis(owner)` — position AND rotation equality; also assert the
  SHIPPED basis' yaw error vs ê_u exceeds 30° for that fid (pins that this gate catches the live bug).
- **G-OFF**: flag off ⇒ enum records + card/mesh `debug_buffer()` bit-identical; standing suite green
  (verify_far_trees 40/0, verify_faceted, verify_feature).

Live A/B (redeploy, cheat set + `FP_FT_FRAME_WELD`; the viewpoint is pinned: facet 1133,
pos 22274, 15, 23346, yaw −71°):

1. Mid-band canopy silhouettes axis-aligned with the near trees (no corner-on diamonds) — including
   across the fold; one silhouette per lattice site.
2. Trunk bases meet the ground across the band; no sunken canopy-on-grass mid-facet, no floating bases
   near facet corners.
3. Walk the seam: no rotation jump at the fold line.
4. fps/draws/vmem unchanged.

## 7. Risks / follow-ups

- **R1**: `datum_lift` uses the OWNER facet's plane; a tree exactly on the seam ridge sits where two
  facets' s differ by the residual seam step — bounded by the FS2′ weld tolerance (sub-block), same as
  the near terrain itself. Accept.
- **R2 (follow-up, #121)**: `FacetFarStructures` has the identical omission —
  `lattice_to_world64` with no datum term (facet_far_structures.gd:266, :325 ring-local verts) — plus
  whatever basis its decimated models use. Apply the same weld there when #121 lands its far models.
- **R3**: the #120-residual doc's "weld holds live" census (COSMOS-FARTREE-SHIFT-RESIDUAL-DESIGN.md §1)
  is position-conditional — re-run the blob census at a HIGH-s viewpoint (mid-facet) post-fix; the old
  measurement must not be cited as proof the altitude weld was ever globally correct.

## 8. Honest verdict

This is **both** a frame-transform fix (altitude: the missing FS2′ datum term — the far tree is the
only placement in the stack still on the facet plane; ±5.5 blk, sign flips corner→centre) **and** an
orientation fix (rotation: the world-axis `r × ŷ` basis vs the owner lattice — 0-45° visible,
~36° across 1133's cube-face fold, coincidentally ~1° on 1133 itself). It is **not** a
neighbour-placement/anchor-frame bug: near neighbour slots render in their own facet frame, which is
exactly the frame the far anchor already evaluates (module_world.gd:1926 == facet_atlas.gd:402/542).
The boundary-specificity in the report is real but is *visibility*, not mechanism: a cube-face fold is
where the two yaw-error families meet on screen. Both defects are global, deterministic, and closed by
one flag with byte-off parity and a gate (G-FTF-3) that would have caught each of them.
