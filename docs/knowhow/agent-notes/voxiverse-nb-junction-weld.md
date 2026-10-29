---
name: voxiverse-nb-junction-weld
description: "2026-08-11 NB junction \"tilted floating slab\" root cause = dead CORRECTION-2 exclusion latch (pool_seam_meshed geometrically unsatisfiable), NOT placement transforms; fix FP_NB_WELD SHIPPED+MERGED PR #44 (1c5112b)"
metadata: 
  node_type: memory
  type: project
---

2026-08-11: FP_NB_FULLRES junction "misaligned neighbour terrain" (tilted/offset floating
slab; subtle = seam step-band) ROOT-CAUSED — the placement-transform hypothesis was
REFUTED: one shared placement path (module_world.gd:1875 `slot.transform =
facet_transform(fid)`, frozen per-fid; fixed frame pins PlanetRoot so no updates ever
needed; engine re-places all blocks on any transform change). The slab is the neighbour's
FAR-TIER COVER TILE never released: `pool_seam_meshed` probes ±(32,40,32) around the
player reframed into B's lattice, but B's bounds end 10 cells (MARGIN_CELLS 8 + 2) past
the ridge and engine `is_area_meshed` does NOT clip against bounds ⇒ probe is false for
every neighbour ALWAYS ⇒ `_nb_excl_latch` never sets ⇒ non-imminent live neighbours keep
their far tile forever over their genuinely-meshed band (double cover; tile = 3.744°
dihedral tilt + coarse datum height = "floating slab"). "Imminent renders correctly"
because it is excluded by fid, not by a different placement path. Probe bug is
PRE-EXISTING, masked in _lod_promote_pass by the PROMOTE_EVICT_MAX_S timeout.

**Why:** three lessons — (a) an eyeball "misaligned terrain" at a junction can be a
lingering cover layer, not a transform; check which LAYER the geometry belongs to before
hunting transforms; (b) `is_area_meshed` + bounds-clamped terrains is a trap: any probe
box that can exceed the domain slab is permanently false; (c) a latch whose only setter
is an unsatisfiable probe fails silent-forever unless it has a timeout backstop (the
promote-evict timeout is what hid this for months).

**SHIPPED+MERGED PR #44 (main 1c5112b, 2026-08-11):** FP_NB_WELD (byte-off). W1 module_world.gd:1970-2044 pool_seam_meshed dispatches shipped(old box) vs weld (project NB_PROBE_DEPTH=12 cells inside B from ridge via own_dist, 3 single 32³ cells ±NB_PROBE_SPAN=24 along ridge tangent, corner-safe in_polygon(fid,-2)); W2 world_manager.gd:3124 _nb_update_excl_latch returns changed + ridge-gate cand_d<NB_PROBE_RIDGE_MAX=48 → same-tick _facet_ring_sync_exclusion; W3 :2736 seeds _nb_excl_latch[from]=true on crossing. NO transform code touched (grep-verified). Gate verify_nb_weld 15/0 (G-NB-WELD-PROBE discriminator: weld TRUE while old box provably FALSE same state). NOTE: floating-slab repro needs a LIVE-but-unexcluded neighbour (pool_active>0) — at the surface junction I A/B'd, pool_active=0 so the slab didn't reproduce (fix is byte-off-safe + gate-proven regardless).

**How to apply:** fix design = FP_NB_WELD in docs/COSMOS-NB-JUNCTION-WELD-DESIGN.md.
Live discriminator before implementing: dump live slot global_transforms + toggle far tier
(slab must vanish with the far tier). Related: [[voxiverse-bg-prebake-design]]
[[voxiverse-perf-next-architecture]] [[voxiverse-facet-seams]]. Adjacent latent bug: at
cap-4 a pool-miss crossing falls to pool_reset teardown (module_world.gd:2101 cap check;
same-tick eviction only exists in the pool pass).
