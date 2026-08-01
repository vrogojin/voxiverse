# COSMOS-BLOCK-LOD-DESIGN — Decimated-block terrain LOD pyramid

*Design: FableLOD (research + architecture). Implementation: Opus, flag-gated phases P0–P5.*
*Companion to COSMOS-LOD-TEXTURE-DESIGN.md + COSMOS-NO-PROTRUSION-FIDELITY-DESIGN.md.*

## 0. The idea (engine law)

Far terrain = the SAME blocky surface at power-of-2 block sizes: 1-block voxels near → 2 → 4 → 8 → 16 → 32-block "megablocks" far. ONE continuous blocky aesthetic, **no representation swap** (today's near-blocks → smooth chord/skin swap is the seam the user rejects, and its min-envelope sits visibly *below* the near blocks = task #72). Distant Horizons' proven formula transplanted onto the faceted planet; slots into our composition law (overlap + shared sampling + sink) and *strengthens* no-protrusion.

## 1. Architecture: custom `FacetBlockLod` (NOT VoxelLodTerrain)

Rejecting VoxelLodTerrain-per-facet: (1) blocky LOD is explicitly second-class in godot_voxel (Transvoxel transition cells are a smooth-surface crack-stitch, meaningless for axis-aligned quads); (2) it's a per-terrain scene-node streaming machine — 3456 rotated lattices don't fit its single-frame octree, which is exactly what FacetAtlas/FacetFarRing already solve; (3) physics is analytic (never reads meshes — CLAUDE.md); (4) NEVER-OOM needs OUR ledger. So: a new `FacetBlockLod` sibling of FacetFarRing/FacetSkinTier — absolute coords, per-facet merged surfaces, the same placement/weld/async-rebuild discipline.

## 2. Data model — per-facet COLUMN pyramid (DH-style, not a 3D octree)

Level `Ln` has pitch `2^n` blocks. Column stores `{top_h: i16, id: u8 (BlockCatalog id ≤255), flags: u8 (water/tree/edited)}` = **4 B**. v1 single-span (top surface only; overhang/cave second-spans = v2, sub-4px at LOD range).

**Bake sources (hybrid):**
- **L0/L1 near (streamed)**: decimated from REAL voxel content — `WorldManager.block_id_at` (generated + `_edits` + trees + carves; the ONE cell query). Player towers/quarries/trees appear as coarse lumps.
- **L2+ and global**: `sample_columns`/`column_top`+`column_profile` (analytic, one-sampler law) + fid-keyed edit overlay + TreeGen column-hash (v2).

## 3. The 2× downscale rule (no-protrusion by containment)

- `top_h(coarse) = MIN(top_h of the 2×2 children)` → coarse solid volume ⊆ space below fine surface everywhere in footprint ⇒ **rendered coarse ≤ true terrain, zero interpolation caveats** (stronger than chord/envelope; block tops are flat). *Majority-on-height would protrude — rejected.* The min under-estimate is bounded by ONE coarse cell's relief (2–32 blocks) ≪ today's envelope footprint (26–52) ⇒ directly fixes #72.
- `id(coarse) = MAJORITY` of children whose top is within 1 coarse pitch of the coarse top (a deep pit doesn't recolor a hilltop); ties by fixed id order (determinism).
- `water flag = OR` of children water (shore reads as water — DH; coherent oceans).
- **Pyramid invariant (G-BLD-PYR): `Ln+1 == decimate(Ln)` exactly**, both sources ⇒ edit-invalidation is a pure upward cascade; store is deterministic/headless-provable.

## 4. Meshing + ring ladder + cross-fade

**Meshing**: per (facet × level) tile, greedy-merged extruded columns — top quads merged across equal-height/equal-id runs (ocean/plains → a few quads), side quads where a same-level neighbour is lower, + a boundary SKIRT dropped one coarse pitch on tile/ring edges (closes silhouette gaps). Absolute coords; corner heights from the shared integer (fid,x,z) lattice ⇒ adjacent tiles weld bit-identically (G-SKIN-EDGE law); cross-facet edges ride EDGE-CANON. ONE merged ArrayMesh per tile, per-facet merge (draws ≈ live tiles). Vertex colors from FarPalette/BlockCatalog, unshaded, composing with the shell `shade·tint` law. (Atlas block-texture on mega-blocks = v2.)

**Ring ladder** (level by on-screen block size, ~4–10 px; `d_max(Ln) ≈ 2^n·K_px/4`, K_px≈1407):

| Level | pitch | band (blocks) | source |
|---|---|---|---|
| voxels | 1 | 0..128 | live near field (unchanged) |
| L1 | 2 | 128..~700 | streamed, real-content |
| L2 | 4 | ~700..1400 | streamed |
| L3 | 8 | 1400..2800 | streamed |
| L4 | 16 | 2800..5600 | streamed (orbit nadir) |
| L5 | 32 | 5600..~15k | GLOBAL always-resident (all 3456 facets) |
| beyond | — | blocks <1-2 px | FP_FACET_TEX smooth satellite (fade blocky out under it) |

**Cross-fade** (NOT Transvoxel/geomorph — morphing blocks = "melting"):
- **Spatial** (ring boundaries): containment composition — Ln+1 (min-rule) always at-or-below Ln, strictly overdraws it; skirts close the ≤ one-coarse-pitch (≤4–8 px) step. No stitching geometry to crack.
- **Temporal** (tile arrival/LRU): 0.3 s screen-door DITHER fade (discard-pattern in the one opaque material — no transparency/sorting). Evict only tiles whose band has a resident coarser cover (L5 never evicts) ⇒ never a hole.

## 5. NEVER-OOM budget

Facet edge ≈417. DATA: L5 global = 13²cols×4B×3456 ≈ **2.3 MB** (always resident floor); streamed L1–L4 ≈ ≤2 MB. MESH (dominant): L5 hemisphere greedy ≈ 40–80 quads/facet ≈ **8–12 MB**; streamed L1–L4 under an explicit **LRU cap**. **Total ceiling `BLOCK_LOD_BYTES_MAX`**: v1 target **16 MB** (start ladder at L2, drop L1), expand toward 28 MB (re-add L1) ONLY if live heap+fps A/B is green with headroom. Hard ledger, wholesale-clear on breach. Knobs if A/B fails: L5→L6 global (÷4), shrink LRU, drop L1.

## 6. Migration map

- **FacetSkinTier: SUPERSEDED** (never re-enable — L1/L2 blocky tiles are its job done right). Closes #60 by obsolescence.
- **FacetFarRing: KEPT** as the sunk always-there backstop *underneath* everything (DH inversion: the smooth ring is what the blocky pyramid overdraws). Its no-protrusion envelope stays the safety floor during streaming gaps; FP_FACET_TEX stays the beyond-pixel tier. Optionally suppress its emission in fully-covered bands (later, flagged).
- **#72**: structurally improved (min over 2–4 blocks vs envelope footprint 26–52).

## 7. Edit cascade

fid-keyed choke points (`_write_cell`/`sim_revert_cell` → `FacetAtlas.edit_key_fid`): mark L0-footprint column dirty → re-derive L1 from real content → cascade upward (≤6 column updates/edit) → re-greedy only the touched tile, debounced (≥1 s/tile), budgeted. G-BLD-EDIT keeps it honest (post-cascade == from-scratch decimate).

## 8. Flags + gates

Flags (each requires predecessor; default-false, byte-identical off — gated construction like `_skin`/`_facet_tex`): `FP_BLOCK_LOD` (master: node+data+L2 ring), `FP_BLOCK_LOD_RINGS` (ladder+LRU+fade), `FP_BLOCK_LOD_GLOBAL` (L5 resident), `FP_BLOCK_LOD_REALBAKE` (L0/L1 from live voxels), `FP_BLOCK_LOD_EDITS` (cascade).

Gates (`verify_block_lod.gd`): **G-BLD-MIN** (coarse ≤ true fine; falsify min→majority-height), **G-BLD-PYR** (Ln+1==decimate(Ln)), **G-BLD-SEAM** (shared-edge/tile columns bit-identical; skirt closes boundary), **G-BLD-BYTES** (ledger==arithmetic; LRU never evicts global), **G-BLD-EDIT** (tower/pit→cascade→lump; revert→bit-exact), **G-BLD-DRAWS** (draws ≈ tiles ≪ columns).

## 9. Phased plan (each shippable + headless-gated + FLAT 6042/0)

- **P0** — decimator + pyramid store (no rendering). CPU decimate from column samples + edits; G-BLD-PYR/MIN. *Lowest risk; proves the data model.*
- **P1** `FP_BLOCK_LOD` — one visible ring: L2 (4-blk) tiles in the 700–1400 band, greedy + skirts + per-facet merge, over the far ring. Kills #72 step + smooth→blocky swap. G-BLD-MIN/SEAM/BYTES/DRAWS.
- **P2** `FP_BLOCK_LOD_RINGS` — the ladder L2–L4 + LRU + dither + hysteresis; live fps/heap A/B (16 MB ceiling proven or knobs pulled).
- **P3** `FP_BLOCK_LOD_GLOBAL` — L5 all-facet resident + orbit blend into FACET_TEX; the "blocky planet from space" moment.
- **P4** `FP_BLOCK_LOD_REALBAKE` + `_EDITS` — L0/L1 from live voxels + edit cascade.
- **P5** — suppress redundant far-ring bands (flagged), retire skin, perf soak, sed-ON.

## 10. Decisions (locked by lead, user AFK)
- Memory: **16 MB first** (L2 start), expand only on green heap A/B.
- **v1 single-span** columns (overhangs v2).
- **v1 vertex-colored** (FarPalette); atlas mega-block texture v2.

## Boot-screen hooks (task #75)
The bake exposes `facets_baked / facets_total` (per level) + an **"essential near set ready"** milestone so the branded splash shows real % and gates "start playing" while the rest bakes in background.
