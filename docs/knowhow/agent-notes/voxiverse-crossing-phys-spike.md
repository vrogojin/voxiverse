---
name: voxiverse-crossing-phys-spike
description: "Facet-crossing 200-772ms phys_ms spike is the redesignate PlanetRoot transform write, NOT the GroundCollider"
metadata: 
  node_type: memory
  type: project
---

The live-web facet-crossing spike (`phys_ms` 200-772ms every `RE-DESIGNATION`) is the FP-M1c
`module_world.redesignate` writing `_planet_root.transform` — which rotates the whole live planet by the
inter-facet dihedral and fires `NOTIFICATION_TRANSFORM_CHANGED` → `for_each_block(set_parent_transform)` on
every loaded VoxelTerrain block + a `_propagate_transform_changed` walk over all FP_M2_LOD tile nodes,
SYNCHRONOUSLY inside `Player._physics_process` (so it lands in `TIME_PHYSICS_PROCESS`, not proc).

**Why:** It is NOT the GroundCollider (the natural first suspect). Proven: the collider early-returns
(`ground_collider.gd:165-167`) whenever no AWAKE VoxelBody debris is near — a plain walk-across does zero
collider work; no crossing path triggers a synchronous full rebuild (that only comes from `_notification`
ENTER_TREE, i.e. a reparent, which crossings don't do). VoxelTerrain has `generate_collisions=false`, so the
PlanetRoot move touches no physics shapes — the solver step is near-empty on a debris-free walk. Headless
`redesignate` GDScript body measures 0.02-0.38ms; the real cost is the engine re-place/re-cull of loaded
mesh blocks, which the headless dummy renderer (0 blocks streamed) can't reproduce.

**CONFIRMED at engine level (2026-07-15, agent crossing114):** the single `_planet_root.transform =` write
(`module_world.gd:1617`) is NOT O(1). godot_voxel `voxel_terrain.cpp:48` calls `set_notify_transform(true)`,
so `NOTIFICATION_TRANSFORM_CHANGED` (`voxel_terrain.cpp:867-879`) runs `_mesh_map.for_each_block(set_parent_transform)`
→ `voxel_mesh_block.cpp:131` `_mesh_instance.set_transform()` = one `RenderingServer.instance_set_transform`
per loaded mesh block, ×(1 active + up to POOL_MAX_NEIGHBOURS=4) live terrains + all FP_M2_LOD tile nodes =
~600–low-thousands of RS writes on ONE physics tick. Crossing call path: `player.gd:229` → `world_manager.gd:1410`
maybe_cross_facet → :1455 redesignate. HONEST HEDGE: a few hundred–thousand pure instance_set_transform at
200–772ms is high for a queued RS buffer — bracket ONLY the transform write before assuming 100% is re-place
(the phys_ms window may fold same-tick LOD re-tier).

**LIVE A/B RESULT (2026-07-15, real GPU via remote bridge — CORRECTS the hypothesis):** The fixed-frame
keystone (FP_FIXED_FRAME) SHIPPED + was measured live. Findings: (1) the transform WRITE is 0.02ms and the
synchronous redesignate GDScript dropped 43ms→4ms with FP_FIXED_FRAME on — a real but SMALL win; (2) crossings
STILL hitch 464-1132ms and the dominant cost is GENERATION, not the transform re-place: every post-crossing
window shows vox_gen 440-1595 (huge backlog), the spike tracks vox_gen. crossing114's transform-re-place
hypothesis was LARGELY WRONG — vindicated only in the small vox_gen=0 structural component (~300ms seen when
generation was drained). **The #114 crossing hitch is fundamentally a GENERATION-THROUGHPUT problem** (new facet
activates → surroundings stream in → vox_gen bursts ~1500 → frame stalls). The fixed frame is the ENABLER not the
fix: it makes crossings O(1) in live-terrain count, which unblocks the real solution — keep the crossing-target
facet fully PRE-GENERATED/pre-warmed (now affordable) so crossing needs no gen burst (+ A2 underground clamp
reduces gen, + the FP-M2 pre-warm controller). Deferred-spike A/B was CONFOUNDED (baseline had vox_gen=0
crossings, keystone walk had all-high-gen). Instrumentation: A1 per-crossing {transform_ms, redesignate_ms,
blocks_replaced} + A1-refine {ev:crossing_after, post_worst_ms} over the remote bridge; note the crossing_after
window can UNDERCOUNT (starts slightly late, misses the initial giant frame — the telemetry worst_ms 464-1132 is truer).

**How to apply:** Don't "fix" this by amortizing the collider broadphase — that passes gates but doesn't
move phys_ms. And do NOT expect the fixed frame alone to smooth crossings — attack GENERATION (pre-warm the
target facet). The fixed frame is still worth shipping (removes ~39ms/crossing + the transform cost, fixes the
stranded-debris bug, enables full-res neighbours + aggressive pre-warm). The fix is the **fixed absolute render frame — DESIGNED 2026-07-15** in
`docs/COSMOS-FIXED-FRAME-DESIGN.md` (branch `fix/voxiverse-crossing-hitches`, task #114): PlanetRoot pinned
@ identity forever, slots keep their T_fid absolute transforms, a new `ActiveFrame` Node3D @ T_active carries
player/GroundCollider/debris/aim-highlight (gameplay math stays facet-lattice as LOCAL transforms), crossing =
bookkeeping + one ActiveFrame write + debris local compensation + gravity-vector rotate, zero mesh-block
re-place. Five phases (P0 instrument → P1 frame-neutral refactor → P2 keystone flip → P3 soak → P4 optional),
flag `FP_FIXED_FRAME`. Corrections to earlier assumptions, verified in source: (a) `maybe_reanchor`
(`world_manager.gd:1374`) is a chart-gated NO-OP under FACETED — it can NOT carry precision; (b) none is
needed: shipped lattice coords already run at ~33k (±32768 decorrelation offsets, `facet_atlas.gd:371-372`)
while absolute coords are ≤~3.3k — 10× smaller, so no floating origin in v1 (the "~19k" figure was the offset
scale); (c) LOD tiles + far ring are ALREADY planet-absolute — static for free; (d) `crossing_transform`
(`facet_atlas.gd:300`) is documented as the debris re-placer but called nowhere — today's crossings strand
debris in the stale frame, fixed by construction; (e) the [[voxiverse-corner-seam]] 90° turn is a chart-FLIP
bug (non-faceted M3/M5) and is NOT fixed by this. Live validation still needs flags ON on real GPU via the
remote bridge (headless streams 0 blocks).
