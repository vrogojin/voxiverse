---
name: voxiverse-physics-scale
description: "VOXIVERSE will have MANY persistent physical objects worldwide; physics must be dormant-by-default, activated only on disturbance"
metadata: 
  node_type: memory
  type: project
---

VOXIVERSE is designed to have **a lot of physical objects (loose `VoxelBody` rigid bodies) lying around the world everywhere** — dropped/broken blocks and collapsed clusters persist as world content (they are NOT despawned; deleting one deletes world content, a gameplay change the owner rejected).

Therefore physics MUST be **on-demand / dormant-by-default**, not simulated continuously:
- Idle/settled bodies sleep/freeze (→ STATIC) so they cost ~0.
- The local `GroundCollider` (which exists only so loose bodies rest on terrain; the player is analytic and never uses it) should be active only while a body near the player is **actively simulating** — a settled/frozen body must NOT keep the collider rebuilding (that rebuild churn was a measured stutter source).
- A body wakes + the collider reactivates only on **disturbance**: a block break nearby, or a moving object contacting/pushing it. After re-settling it freezes again.

**Why:** on the live web build (weak Intel HD / WebGL Compatibility), a handful of nearby non-dormant bodies dropped fps to 30–50 with periodic physics spikes; at the intended world scale (thousands of objects) continuous simulation is untenable.

**How to apply:** gate the collider on *awake* bodies (not merely "any body present"); freeze bodies on settle; wake-on-break-nearby + wake-on-contact. See [[voxiverse-project]] and the perf-debugging history on `feat/voxiverse-sim-extensions`. Separate, still-open issue: bodies-absent movement still shows occasional large frame spikes from chunk-streaming/mesh-upload/draw-call growth (draws climbed 13→430, vmem 38→72MB while exploring) — a rendering/streaming cost, not physics.

**2026-08-01 — TREE-CUT PHYSICS STALL SOLVED + live-recovered (deploy/cheats-eyeball → merged main PR #25; FP_TREEPHYS_BOUND; verify_treephys 9/9, FLAT 6042/0).** User cut a tree at a FAR surface spot → game dropped to 5-6 fps and STUCK (never recovered). Telemetry pinpointed it: **phys_ms 300-420/frame, proc_ms 16, draws 58** — PURE physics. Root cause: `WorldManager._structural_update` → `StructuralSolver.solve` (cap MAX_FLOW_CELLS 4096, degrades to connectivity-only above) → 6-connected components → each `VoxelBody.spawn_loose` with **ONE BoxShape3D collider PER CELL** (`voxel_body.gd:542 _rebuild`), body stays fully DYNAMIC until `_grounded()` confirms rest. A large detachment = a rigid body with 150+ box colliders the physics server broadphases/integrates every frame; and the settle-dwell + 10s SETTLE_COARSE force-freeze are BOTH gated on `_grounded()` — which never confirms at a far/faceted spot → perpetual churn, no self-recovery. Fix `FP_TREEPHYS_BOUND` (TREEPHYS_COLLIDER_CAP=64, TREEPHYS_MAX_ACTIVE_SEC=8): (1) component >64 cells collides as ONE BoxShape3D over its AABB (O(1)), render mesh untouched, normal ≤~50-cell canopies unchanged (tree-chop UX preserved); (2) large body spawns frozen STATIC (renders+walkable, zero churn); (3) hard 8s deadline freezes any never-resting dynamic body regardless of _grounded(). RECOVERY: reload dropped the stuck debris → phys_ms 300→0.26. This is the "physics DORMANT-BY-DEFAULT + BOUNDED" principle enforced. Related: [[voxiverse-flight-fallthrough-sun]] (the same far-spot/_grounded facet-frame class), [[voxiverse-never-oom-web]].
