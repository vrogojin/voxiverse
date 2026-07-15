# COSMOS FIXED-FRAME — the fixed absolute render frame (crossing hitch keystone)

Status: **DESIGN** (investigate + design; no implementation).
Flag: `CubeSphere.FP_FIXED_FRAME` (new, default **false**; requires `FACETED && FP_M1_POOL`).
Off ⇒ byte-identical to the shipped build, following the established sed-at-export deploy pattern
(`FACETED`/`FP_M1_POOL`/`FP_M2_LOD` are all `false` in source — cube_sphere.gd:47,63,105 — and
flipped on only at export; this feature lives entirely behind them).

Related: docs/COSMOS-FP-M1-DESIGN.md (the pool + redesignation crossing this replaces the transform
write of), docs/COSMOS-FP-M2-DESIGN.md (LOD neighbours), docs/COSMOS-MULTIFACET-STREAMING-REVIEW.md.

---

## 0. Problem

Crossing a dihedral ridge costs a measured **200–772 ms physics-tick stall** live. Root cause
(confirmed at engine level, memory `voxiverse-crossing-phys-spike`):

- `WorldManager.maybe_cross_facet` (world_manager.gd:1410) commits the crossing:
  `TerrainConfig.set_active_facet(to)` (:1444), then `module_world.redesignate(to)` (:1455).
- `redesignate` (module_world.gd:1608) performs **one** write:
  `_planet_root.transform = FacetAtlas.facet_transform(to).affine_inverse()` (module_world.gd:1617)
  — re-framing the whole live planet so the new active facet is axis-aligned +Y-up at the lattice
  frame's origin.
- That write is **not O(1)**: godot_voxel calls `set_notify_transform(true)` (voxel_terrain.cpp:48),
  and `NOTIFICATION_TRANSFORM_CHANGED` (voxel_terrain.cpp:867-879) re-places **every loaded mesh
  block** via `RenderingServer.instance_set_transform` (voxel_mesh_block.cpp:131) — across all live
  pooled terrains **and** every FP-M2 LOD tile under PlanetRoot — synchronously, in the physics tick.
- GroundCollider and the far ring are confirmed **not** contributing (collider early-returns with no
  awake debris; `FacetFarRing.set_active` is O(1) — one node transform + a deferred re-emit,
  facet_far_ring.gd:54-56).

So the crossing cost scales with the number of loaded mesh blocks — i.e. with live-terrain count and
LOD coverage — which also blocks the full-res-neighbours ambition.

## 1. Investigation findings (what the code actually does today)

### 1.1 The frame model today: scene frame ≡ active facet lattice frame

- `_pool_init_active` (module_world.gd:1541-1560): `PlanetRoot @ T_active⁻¹`; each terrain lives in
  a `FacetSlot_<fid> @ T_fid = FacetAtlas.facet_transform(fid)` (module_world.gd:1545,1550).
  Composite for the active facet = `T_active⁻¹·T_active = identity` → active terrain content
  (fid-lattice coords) lands axis-aligned at the scene origin. **The scene/world frame IS the
  active facet's lattice frame.**
- Everything gameplay is written in that frame: player position/velocity/yaw (player.gd throughout),
  the analytic floor/wall/ceiling (player.gd:245-368; gravity is a raw `velocity.y -= g·δ`,
  player.gd:311; walls are per-axis x/z probes :282-293; floors are `floor_under` y-scans :333),
  the DDA (`world.aimed_voxel`), the edit overlay indices, the GroundCollider shapes, debris.
- A crossing therefore re-frames BOTH sides today: the world (`_planet_root.transform`, the
  expensive half) and the player (`apply_reframe`, player.gd:136-139 — f64-exact position via
  `FacetAtlas.reframe_position64`, yaw twist about `Vector3.UP` only; the player stays upright,
  gravity stays −Y).

### 1.2 The floating-origin re-anchor does NOT run under FACETED

`maybe_reanchor` (world_manager.gd:1374-1394) is **chart-gated**: `if _chart == null … return ZERO`,
and `_chart` is only constructed when `not CubeSphere.FLAT_WORLD` (world_manager.gd:158-159).
`FACETED` **requires** `FLAT_WORLD = true` (cube_sphere.gd:44). So on the faceted path
`maybe_reanchor` is a byte-identical no-op — the task brief's premise that "the existing
floating-origin re-anchor already fires" does **not** hold under FACETED. Today the faceted world
needs no floating origin because the crossing reframe itself re-centres the active facet at the
origin. Section 3 shows a re-anchor is (surprisingly) **not needed** by this design either at the
current planet size; §9 Phase 4 designs one anyway for future large planets.

### 1.3 Coordinate magnitudes — the precision picture is better than assumed

- `R_BLOCKS = 3072`, facet edge ≈ (π/2·R)/K ≈ **200 blocks** (facet_atlas.gd:13). Dihedral between
  adjacent facets ≈ edge/R ≈ 0.065 rad ≈ **3.7°**.
- Facet **lattice** coords carry per-facet decorrelation offsets `O ∈ [−32768, 32768]`
  (facet_atlas.gd:371-372, `_off`), so lattice coords — and therefore today's **scene/render
  coordinates of every active-facet mesh block, the player, and the collider** — already run at up
  to ~33 k blocks (f32 ulp ≈ 4 mm). This is the shipped, live-validated regime.
- **Absolute** (planet-frame) coords are bounded by R + terrain height ≈ **3.3 k blocks**
  (f32 ulp ≈ 0.25 mm) — an order of magnitude *smaller* than today's render coordinates.
- The neighbour/LOD composites today are `T_active⁻¹·T_fid` — two ~33 k-translation f32 transforms
  composed. In the fixed frame each slot is the single `T_fid` — strictly less f32 composition error
  at the seams.

### 1.4 Pieces that are ALREADY planet-absolute (become free)

- **FP-M2 LOD tiles**: each `LodFacet_<fid>` node sits `@ facet_transform(fid)` under the mesher `@
  identity` under PlanetRoot (facet_lod_mesher.gd:5-7,445,558,712). The W8 cache comment
  (facet_lod_mesher.gd:67-70) states only `global_transform` (PlanetRoot) changes, and only on a
  crossing. Under a fixed frame the entire LOD layer is static.
- **Far ring**: its merged mesh is built in ABSOLUTE coords; the node transform is `T_active⁻¹`
  (facet_far_ring.gd:5,54-56,120,176). Under a fixed frame the node pins at identity and
  `set_active`'s transform write disappears (the deferred exclusion re-emit stays).

### 1.5 Edits are already (fid,cell)-global

The `_edits`/`_meta` overlay keys are (fid,cell)-GLOBAL under FACETED (world_manager.gd:868-911,
FP-M1a); a crossing migrates nothing (world_manager.gd:1445-1449) — only the window-keyed PERF
indices are re-derived (`_rebuild_window_indices`, :1449). The active terrain's voxel edits
(`set_cell`, module_world.gd:460) are addressed in fid-lattice coords == terrain-local coords, and a
slot's local frame is fid-lattice **in both designs** (composite identity today, `T_fid` fixed-frame)
— the edit path needs **no change**.

### 1.6 VoxelViewer / streaming / culling

Exactly one global `VoxelViewer`, a **child of the player** (module_world.gd:2181-2193;
world_manager.gd:305). godot_voxel maps the viewer's global position into each terrain's local frame,
so streaming per slot is correct under any rigid slot transform — the rotated-neighbour slots already
prove rotated streaming/culling works (FP-M1c shipped; per-slab `bounds` are set in terrain-local
voxel space, frame-independent). The fixed frame only changes the viewer's *global* coords (absolute,
≤3.3 k instead of lattice ~33 k). One audit item: shortcuts of the form `viewer.global −
node.global` that assume no relative rotation (e.g. module_world.gd:2214) must become proper
`to_local()` calls.

### 1.7 Debris (VoxelBody) — a latent bug the fixed frame fixes

Loose `VoxelBody` debris are direct children of WorldManager (world_manager.gd:590-592).
`FacetAtlas.crossing_transform` (facet_atlas.gd:298-301) documents "used to re-place static nodes
(debris) at a crossing" — but it is **called nowhere** (only `crossing_basis` is used, for the player
yaw twist, world_manager.gd:1442). Today a crossing rotates the world frame under existing debris and
leaves them in stale coordinates — a latent misplacement bug that has simply never been prominent
(debris near a ridge at crossing time is rare). In the fixed frame, debris keep their true absolute
pose by construction (§5).

### 1.8 GroundCollider

Node3D child of WorldManager (world_manager.gd:170-171), two double-buffered `StaticBody3D` children
with PhysicsServer-pooled box shapes at lattice cell coords, rebuilt incrementally around the player
(ground_collider.gd:20-44). It performs zero work on a crossing today (gated when no awake debris);
its shape set after a crossing is stale in exactly the same way as debris (rebuilt when the player
column drifts). Frame-independent internally — all its terrain queries are lattice-pure via
WorldManager.

## 2. The design

### 2.1 Frame model

Two frames, one bridge:

- **Absolute frame** (= the scene/world frame, fixed forever): the planet's true frame.
  `PlanetRoot @ identity` — written **once at setup and never again** (until an optional Phase-4
  anchor shift). Every `FacetSlot_<fid>` keeps its existing `T_fid = FacetAtlas.facet_transform(fid)`
  — which IS the facet's true place on the cube-sphere. LOD tiles and the far ring are already
  absolute (§1.4) and pin at identity.
- **Gameplay (lattice) frame**: the active facet's lattice frame, in which ALL existing gameplay
  math continues to run unchanged — analytic floor/walls/ceiling, DDA, edits, worldgen, streaming
  decisions, pool policy (`own_dist` takes active-lattice points, facet_atlas.gd:365).
- **The bridge — `ActiveFrame`**: one new `Node3D @ T_active` (the active facet's true transform).
  The **player, GroundCollider, debris VoxelBodies, and the aim highlight** are its children. Their
  LOCAL transforms are lattice coordinates (today's numbers verbatim); their GLOBAL transforms —
  what the physics server and the renderer consume — come out planet-absolute automatically.
  The camera stays a child of the player (player.gd:72-86) → renders from the absolute frame with
  zero extra machinery (no `set_render_camera` split needed; that M5_REAL pattern, player.gd:87-92,
  remains non-faceted-only).

Physics space is therefore the **absolute frame** — one consistent frame for capsule↔debris
collision, rays, and rendering. Gravity for rigid bodies becomes a rotated global vector (§2.3).

### 2.2 The crossing algorithm (pure bookkeeping — no geometry moves)

On commit in `maybe_cross_facet` (same detection, hysteresis, containment check, cooldown —
world_manager.gd:1416-1441 unchanged):

1. `TerrainConfig.set_active_facet(to)` — worldgen/lattice bookkeeping (unchanged).
2. `_rebuild_window_indices()` — PERF indices re-derived for `to` (unchanged).
3. `module_world.redesignate(to)` — **minus module_world.gd:1617**. Keeps: view-distance rebalance,
   `editable` flip, `_pool_active/_terrain/_mesher/_generator` swap, `_lod_mesher.set_active_facet`
   (module_world.gd:1622-1643). The PlanetRoot transform write is skipped under the flag.
4. **`ActiveFrame.transform = FacetAtlas.facet_transform(to)`** — one node with O(10) children
   (player, collider bodies, debris), none of which is a VoxelTerrain: no mesh-block re-place.
5. **Debris compensation** (§5): for each `VoxelBody` child, `local ← Δ·local` with
   `Δ = FacetAtlas.crossing_transform(from, to)` (facet_atlas.gd:300) — global pose preserved
   exactly; velocities are physics-server-global and need no touch.
6. **Gravity rotate** (§2.3): one `PhysicsServer3D.area_set_param(default_area,
   AREA_PARAM_GRAVITY_VECTOR, −T_to.basis.y)` call.
7. Player reframe — `apply_reframe(new_pos, yaw_delta)` exactly as today (player.gd:136-139), only
   now `new_pos` is assigned to `position` (local = lattice) instead of `global_position`. The f64
   `reframe_position64` guarantees `T_from·p_from == T_to·p_to`, so the player's **absolute** pose is
   continuous to f64; steps 4+7 in the same tick keep it continuous end-to-end.
8. GroundCollider: force a re-center (`_target` = new player column; existing incremental machinery
   rebuilds at its normal budget). Far ring: `set_active(to)` keeps the exclusion re-emit, drops the
   transform write (facet_far_ring.gd:56 flag-gated to identity).

Total synchronous cost: a handful of node-transform writes + O(#debris) local fixups + one
PhysicsServer param — **microseconds**, independent of live-terrain count and LOD coverage.

### 2.3 Gravity / up / forward — decision: (a) facet-local play frame

We keep the player's canonical state in the active facet's lattice frame (option (a) of the brief).
The alternative (b) — generalising the analytic math to a tilted frame — is rejected: the analytic
core is pervasively axis-aligned (integer cell scans per axis, `floor_under`/`ceiling_scan` walk y
columns, walls probe x/z independently, `_cell_intersects_player` is an axis-aligned AABB), and the
worldgen/edit lattice itself is axis-aligned per facet; generalising it buys nothing and risks
everything.

Concretely, in player.gd (and voxel_body.gd):

- **Positional math**: mechanical `global_position → position`, `global_transform → transform`
  (local = lattice under ActiveFrame). Mouse-look `rotate_y`/pitch operate on local rotation —
  unchanged semantics. `set_initial_look`, `_cell_intersects_player`, `head_position`,
  `ground_probe_position`, `update_streaming(position)`, `maybe_cross_facet(position)` — all lattice.
- **Physics-server-facing calls** (global space) get direction/point mapping through
  `ActiveFrame.basis` / `ActiveFrame.transform` (call it `B`/`T`):
  - `move_and_collide(T.basis * motion)` (player.gd:386,389); the slide stays in global space; the
    rubber-band dot-check compares the global displacement against `T.basis * wish`.
  - stand-on-piece ray (player.gd:342-343): cast from `T*(p+0.05ŷ)` to `T*(p−0.6ŷ)`; the
    `piece_top >= terrain_floor` comparison (:349-355) converts the hit point back to lattice
    (`T⁻¹·hit`) and compares y there.
  - `_push_bodies` (player.gd:574-591): shape-query transform `T*(p+0.9ŷ)`, push dir `T.basis*dir`.
  - weight force (player.gd:367): direction `−T.basis.y`.
  - wood-vs-terrain aim contest (`_current_target`, player.gd:437-479): camera origin/dir are
    absolute; convert to lattice for `world.aimed_voxel`; distances are rigid-invariant so the
    contest compares directly; terrain highlight xform maps back through `T` (AimHighlight is
    `top_level` and writes `global_transform`, aim_highlight.gd:35,50 — give it the `T`-mapped
    xform, or re-parent under ActiveFrame and write `transform`).
- **Rigid-body gravity**: the world gravity vector rotates to `−T.basis.y` per crossing (§2.2.6).
  All debris shares the active facet's up — the same approximation as today (gravity is scene −Y for
  everything), and the error to a neighbouring facet's true up is ≤ one dihedral ≈ 3.7°. Sleeping
  (frozen) debris doesn't integrate gravity at all; per-body true-up gravity via Area3D is an
  explicit non-goal (dormant-by-default physics, memory `voxiverse-physics-scale`).
- **VoxelBody lattice queries** (voxel_body.gd:139,431,444 — `wake_bodies_near`, `surface_y`,
  `cell_solid` fed from `global_transform`/global positions): switch to `transform`/local positions —
  local IS lattice under ActiveFrame, so these become *more* direct than today.

`velocity` remains our own lattice-frame bookkeeping (we never call `move_and_slide`), so gravity
integration `velocity.y -= g·δ` (player.gd:311) is untouched.

### 2.4 What explicitly does NOT change

Worldgen (`TerrainConfig.generated_block`, active-facet lattice), the edit overlay and its keys
(§1.5), `block_id_at` and every analytic query, the DDA, the pool policy + Z1-hybrid + load
controller (all lattice math on `own_dist`), the LOD mesher's selector/budgeter (its render-space
probes use `global_transform`, which simply becomes constant), the carve/junction machinery
(seam planes are per-facet lattice data), `_collapse_unsupported` (lattice flood-fill; only the
spawn transform of the detached body maps through `T` — as a child of ActiveFrame that means
assigning the same lattice-local transform as today).

## 3. Precision — why no floating origin is needed at R = 3072 (and the plan if R grows)

| quantity | today (shipped) | fixed frame |
|---|---|---|
| render/scene coords of mesh blocks | lattice, up to ~33 k (ulp ≈ 4 mm) | absolute, ≤ ~3.3 k (ulp ≈ 0.25 mm) |
| camera global | lattice ~33 k | absolute ≤ ~3.3 k |
| player physics coords | lattice ~33 k global | lattice ~33 k **local**; global absolute ≤ 3.3 k |
| slot composite | `T_act⁻¹·T_fid` (two ~33 k f32 translations composed) | single `T_fid` |

The shipped game already renders and runs physics at ~33 k-block coordinates (the decorrelation
offsets, §1.3) with no visible artefacts — the fixed frame moves every *global* quantity an order of
magnitude closer to the origin. The one new error term: the engine composes `T_active (f32, ~33 k
translation) · local (~33 k)` to produce the player/camera absolute pose, a catastrophic cancellation
leaving ~a-few-ulps-of-33 k ≈ **≤ ~1 cm** absolute placement error — smooth in the local position
(no per-frame jitter; `T_active` is constant between crossings), shared in kind with the terrain
slots' own `T_fid` f32 placement, and far below block scale. Accepted.

**Therefore: no re-anchor in v1.** The existing `maybe_reanchor` is chart-gated OFF under FACETED
(§1.2) and stays that way. Phase 4 (optional, for R ≫ 3072) designs the absolute-frame analog: an
integer **anchor shift** `A` — `PlanetRoot.position −= A`, `ActiveFrame` re-derived as
`translate(−A)·T_active`, debris/player untouched (they ride ActiveFrame) — one mesh-block re-place
per shift, fired on `|player_abs| > threshold`, i.e. rarely and never on a crossing. A cheap
telemetry guard (log `|player_abs|` max) ships in Phase 0 to keep this evidence-based.

## 4. GroundCollider + VoxelViewer in the fixed frame

- **GroundCollider**: parent it under ActiveFrame; zero internal changes (all its terrain reads are
  lattice via WorldManager; shapes at lattice coords acquire correct absolute globals through the
  parent; PhysicsServer handles rotated static boxes natively). On a crossing its existing shape set
  is momentarily stale — exactly as today (§1.8) — and the forced re-center (§2.2.8) plus
  VoxelBody's analytic settling (never trusts an in-progress set, ground_collider.gd contract) cover
  the window. The active-body gate and all budgets unchanged.
- **VoxelViewer**: stays a child of the player → absolute global → correct local streaming positions
  for every slot (§1.6). Streaming distances/culling under static rotated far-from-origin slot
  transforms are exactly the already-shipped rotated-neighbour regime; the only delta is translation
  magnitude, ≤ 3.3 k (smaller than today's 33 k lattice). Audit item: replace `global − global`
  translation-only shortcuts with `to_local()` (module_world.gd:2214 and any siblings).

## 5. Debris correctness (and the latent-bug fix)

VoxelBodies live under ActiveFrame. At a crossing their **absolute** pose must be preserved (the
physical object doesn't move); since the parent transform flips `T_from → T_to`, each body's local
transform is compensated `local ← crossing_transform(from,to)·local` — the exact documented-but-never
-wired intent (§1.7). Linear/angular velocities live in physics-server global space and are already
correct. Sleeping bodies stay asleep (no global pose change ⇒ no wake). This *fixes* today's latent
stale-frame misplacement. Spawn paths (`spawn_loose`, `_spawn_detached`) parent under ActiveFrame
with lattice-local transforms (same numbers as today).

## 6. Bonus assessment: yaw-snap and the corner-seam 90° artifact

- The **net camera-relative change** at a crossing is the dihedral tilt (~3.7°) in both designs —
  that is physical (gravity genuinely turns) and remains for the camera ease to smooth. What the
  fixed frame removes *structurally* is the class of one-frame glitches where the PlanetRoot write
  and the player reframe could be observed out of step (any mid-tick render between :1617 and
  `apply_reframe` shows the world rotated ~90°+twist for a frame). With no geometry write there is
  nothing to be out of step with; a follow-up can also ease the dihedral in absolute space cleanly.
- The **corner-seam 90°-turn artifact** (memory `voxiverse-corner-seam`) is a frame-rotation bug in
  the M3/M5 **chart flip** path — non-faceted machinery this design does not touch. Not fixed here;
  the faceted corner-deferral logic (world_manager.gd:1427-1441) is unchanged.

## 7. Risk register

| # | risk | mitigation |
|---|---|---|
| 1 | **Up/gravity**: some player/debris math still assumes global −Y after conversion (missed call site) | Phase 1 lands the conversion at frame = identity (numerically byte-identical, diffable); Phase 2's headless gates assert movement invariants with a tilted `T_active`; grep-audit of `Vector3.UP/DOWN/global_position` in gameplay files is a Phase-1 exit criterion |
| 2 | **Analytic floor/walls**: accidental mixing of absolute and lattice points in the wood-interaction block | the only mixing sites are enumerated (§2.3); each converts at the boundary with a named helper (`ActiveFrame` accessors on WorldManager); headless gate walks/jumps/breaks across a live crossing and asserts positions |
| 3 | **GroundCollider**: stale shapes at crossing / rotated static shapes misbehaving | staleness ≤ today's (§4); rotated static boxes are standard Godot physics; forced re-center on crossing; debris settling is analytic by design |
| 4 | **float32**: absolute-frame placement error | bounded ≤ ~1 cm and smooth (§3); strictly smaller render coords than shipped; Phase-0 telemetry guard on `|player_abs|`; Phase-4 anchor shift designed for future R |
| 5 | **Viewer/culling**: godot_voxel streaming against static rotated far-from-origin terrains | already the shipped regime for rotated neighbours (§1.6); `to_local()` audit; soak gate (verify_fp_m2_soak) re-run with flag on |
| 6 | **Debris compensation drift** (repeated crossings accumulate f32 error in `local`) | compensation uses `crossing_transform` (f64-backed atlas frames, one f32 rounding per crossing on O(1) bodies); debris is short-lived; acceptable, asserted ≤ epsilon per crossing in the gate |
| 7 | **Unaudited scene consumers** of the "scene = lattice" assumption (ShaderPrewarm pile, snowfall, border overlay, crosshair-adjacent UI) | Phase 3 audit list; each is either camera-relative (prewarm), non-faceted (border overlay), or trivially parented under ActiveFrame |

**Rollback story**: every change is branch-gated on `FP_FIXED_FRAME`; off ⇒ byte-identical (the
Phase-1 refactor is additionally identity-frame-neutral even when FACETED is on). Live rollback =
re-export with the flag off (the established sed-at-export pattern). No persistence format changes
(edit keys untouched), so rollback is safe on existing worlds.

## 8. Phased implementation plan

Headless gates prove correctness/invariants; the ms win itself can only be measured **live on real
GPU with flags on** via the remote bridge (memory `voxiverse-remote-bridge`; use real frame deltas,
never TIME_PROCESS — memory `voxiverse-web-time-process-invalid`).

### Phase 0 — Instrumentation + baseline (ships alone, no behavior change)
- **Files**: `net/remote_bridge.gd` (telemetry fields `crossing_ms`, `crossing_from/to`, and a
  re-place proxy: loaded-mesh-block/LOD-node counts at crossing time; `phys_ms` already exists at
  remote_bridge.gd:326), `world/world_manager.gd` (time `maybe_cross_facet` commit path),
  `tools/verify_fp_m2_soak.gd` (log crossings), plus the `|player_abs|` precision guard.
- **Contract**: measure today's 200–772 ms live with attribution; establish the A/B baseline.
- **Acceptance**: telemetry visible in a live remote-bridge session across ≥5 crossings; flag-off
  export byte-identical apart from telemetry.
- **Risk**: none (read-only instrumentation).

### Phase 1 — Gameplay-frame refactor, frame-neutral (`ActiveFrame @ identity`)
- **Files**: `cosmos/cube_sphere.gd` (add `FP_FIXED_FRAME := false`), `world/world_manager.gd`
  (create ActiveFrame; parent player/GroundCollider/debris/AimHighlight; frame accessors
  `active_T()/active_basis()`; spawn-path parenting), `player/player.gd` (global→local conversion +
  the §2.3 physics-boundary mappings through the accessors), `physics/voxel_body.gd` (local-frame
  queries), `player/aim_highlight.gd`, `main.gd` (spawn assignment).
- **Contract**: with ActiveFrame pinned at identity, every mapping is the identity — numerically
  byte-identical behavior in all modes, flag on or off. Pure structure.
- **Acceptance (headless)**: `verify_feature.gd` all-pass; `verify_faceted.gd` + FP gate suite
  all-pass; a new `verify_fixed_frame.gd` asserting the identity-frame equivalence of
  blocked/floor_under/DDA/aim over randomized samples vs direct calls.
- **Risks**: #1, #2 (this phase is where missed call sites surface — at identity they are silent,
  which is why Phase 2's tilted-frame gates exist; the grep-audit exit criterion applies here).

### Phase 2 — Flip the frame + the O(1) crossing (the keystone; flag-on behavior)
- **Files**: `world/voxel_module/module_world.gd` (`_pool_init_active`/`pool_reset`: PlanetRoot @
  identity under the flag; `redesignate`: skip :1617 under the flag; `to_local()` audit incl. :2214),
  `world/world_manager.gd` (crossing steps 4–8 of §2.2: ActiveFrame write, debris compensation,
  gravity vector, collider re-center), `world/facet_far_ring.gd` (identity transform under the flag),
  `player/player.gd` (`apply_reframe` writes local).
- **Contract**: flag on ⇒ PlanetRoot written once at setup, never on a crossing; crossing = §2.2;
  flag off ⇒ byte-identical shipped behavior.
- **Acceptance (headless)**: extend `verify_fixed_frame.gd` — (a) PlanetRoot.transform constant
  across N scripted crossings while slot transforms == `T_fid`; (b) FP3a cross-and-return
  byte-identity of the player lattice pose still passes; (c) player **absolute** pose continuous at
  each crossing to f64 epsilon; (d) debris `global_transform` invariant across a crossing to f32
  epsilon, sleepers stay asleep; (e) gravity vector == `−T_active.basis.y`; (f) place-edit on A,
  cross, break on B, cross back — overlay intact (existing FP-M1a gate re-run flag-on); (g) analytic
  query equivalence at a tilted frame. **Live**: remote-bridge A/B on real GPU — `crossing_ms` from
  200–772 ms to sub-frame; worst-frame p90 across crossings within budget.
- **Risks**: #1–#6 all concentrate here; the phase is small in lines precisely because Phases 0–1
  moved the bulk ahead of it.

### Phase 3 — Hardening, audit, soak
- **Files**: audit list of §7-risk-7 consumers; `pool_reset` pathological path under the flag;
  ShaderPrewarm/snowfall/overlay checks; `tools/verify_fp_m2_soak.gd` run flag-on (LOD + controller
  interaction: confirm the mesher's now-constant `global_transform` didn't regress the W8 cache
  assumptions); corner-deferral crossing storm re-test.
- **Acceptance**: soak gates green flag-on; a long live remote-bridge walk crossing ≥20 ridges incl.
  a corner approach with no visual/physics anomalies and flat `crossing_ms`.
- **Risks**: #5, #7.

### Phase 4 — Optional / deferred (not needed at R = 3072)
- Absolute-frame integer **anchor shift** for future large planets (§3) — flag-gated, fires on
  telemetry evidence only; one re-place per shift, rare by construction.
- Camera dihedral **easing in absolute space** (replaces/simplifies FP3b-style smoothing).
- **Full-res neighbour ring exploration** (§9): now that crossing cost is O(1) in live-terrain
  count, revisit `FP2_LIVE_CAP` and the Z1-hybrid promote policy.

## 9. Interaction notes

- **Unblocks full-res neighbours**: today every additional live terrain and LOD tile adds mesh
  blocks to the crossing re-place — the crossing cost is the argument *against* more live facets.
  Fixed-frame crossings cost the same at 2 live terrains or 6, so the live cap becomes purely a
  memory/throughput question (NEVER-OOM ledger + generation ceiling), not a hitch question.
- **Neighbour-seam + underground-clamp work** (parallel streams): orthogonal — both operate on
  facet-lattice worldgen/mesh content, which this design leaves byte-identical; only node framing
  changes. The seam work benefits indirectly: slot placement drops the composed `T_act⁻¹·T_fid` f32
  error (§1.3), tightening rendered seam alignment.
- **Godot 4.6 migration** (memory `voxiverse-godot-migration`): this design reduces coupling to
  godot_voxel's transform-notification behavior (we stop exercising it entirely on the hot path) —
  strictly migration-friendlier.

## 10. Decisions — RESOLVED by the user 2026-07-15

The user chose the more robust/future-proof option on 3 of 4 — this is a LARGER build than the
recommended-minimal path; scope the phases accordingly.

1. **Floating-origin / anchor: INCLUDE IN v1** (not deferred). Even though the f32 analysis (§3)
   shows none is needed at R = 3072, the user wants the re-anchor built now for headroom on larger
   planets. IMPLICATION: `maybe_reanchor` is a chart-gated no-op under FACETED (§1.2), so this needs
   a NEW faceted/fixed-frame re-anchor implementation (integer world shift of the ActiveFrame + all
   absolute slots + the viewer), not a reuse of the existing one. Add it as a core phase (fold the
   former P4 anchor work into P2/P3), with the Phase-0 |player_abs| telemetry guard as its trigger.
2. **Debris gravity: PER-BODY ACCURATE (Area3D)**. Each detached VoxelBody gets gravity along its
   own facet's up via per-facet Area3D gravity volumes — physically exact on neighbour facets (no
   ≤3.7° error). More nodes/complexity; bound the Area3D set to live facets (NEVER-OOM).
3. **player.gd / voxel_body.gd conversion: FULL FRAME-ADAPTER ABSTRACTION** (not the mechanical
   minimal). Introduce a proper coordinate-frame adapter layer through which all global↔ActiveFrame-
   local conversions route, rather than scattered enumerated renames. Bigger refactor, cleaner
   long-term (and readies the multi-body cosmos); the Phase-1 equivalence gate must prove it
   byte-identical numerically.
4. **Camera dihedral easing: KEEP CURRENT FEEL in v1** (recommended default). No crossing-camera
   re-tuning in this work; absolute-space easing stays a later (P4) option.
5. **Flag coupling: `FP_FIXED_FRAME` requires `FP_M1_POOL`** (recommended default). The FP-S1
   teardown crossing path stays untouched as the fallback; the pool-off path is not retrofitted.

Sequencing note: Track B implementation starts AFTER the parallel A1 (crossing instrumentation =
this design's P0) and A2 (underground reach-clamp) land and merge — all three touch module_world.gd,
and A1 provides P0's baseline. Track B is now a multi-phase, higher-scope build (anchor + per-body
gravity + frame-adapter); dispatch it phase-by-phase with the equivalence gate on P1.
