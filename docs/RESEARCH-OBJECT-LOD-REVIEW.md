# ADVERSARIAL REVIEW — RESEARCH-OBJECT-LOD.md (Object LOD ladders & auto-cull)

**Reviewer**: Fable adversarial pass, verified against the working tree at
`deploy/perf-plus-sky` (worktree `deploy-cheats`). Every load-bearing claim was checked
against code, not prose. Verdicts: **CONFIRMED** (evidence found, claim holds),
**PLAUSIBLE** (defensible, not fully provable from the repo), **REFUTED** (contradicted
by code — needs redesign before implementation).

**Overall verdict: SOUND CORE, FOUR REAL HOLES.** The angular-size law, the
StructDecimator reuse, the merged-mesh rejection for movers, the MultiMesh buffer law,
and the P0-first staging are all genuinely grounded in shipped code. What the design
gets wrong or omits: (1) `VoxelBody` has **no id/rev and its `_rebuild()` destroys any
mesh-visibility state**, so "zero physics changes" is false; (2) the **frame/space
mapping** between debris transforms (ActiveFrame lattice) and the proposed tier (ring
space) is unaddressed; (3) the fixed 4 MB budget **must become auto-configured**
(user requirement) — a safe bounded ladder is feasible, a grow-until-pressure probe is
not; (4) clamped-distance space dots have **no planet-occlusion story**.

---

## Claim 1 — "Generalize BodyLod's angular law" · **CONFIRMED** (with two driver gaps)

The law exists exactly as quoted:

- `godot/src/cosmos/body_lod.gd:96-100` — `k_px(viewport_h_px, fov_rad) = viewport_h_px / (2·tan(fov/2))`
- `godot/src/cosmos/body_lod.gd:103-106` — `ang_px(r, d, kpx) = 2·r/d · kpx`
- `godot/src/cosmos/body_lod.gd:110-113` — `relief_px(e, d, kpx) = e/d · kpx` (a geometricError SSE)
- `godot/src/cosmos/body_lod.gd:66-68` — `P_POINT := 2.0`, `TAU_POP := 1.0`, `HYST := 0.25`
- `godot/src/cosmos/body_lod.gd:135-144` — `tier_hyst`: one-sided-sticky (promote at nominal,
  demote at `threshold·(1−HYST)`), caller latches. Liftable verbatim.

**Independent math check** (radius r, distance d, vertical FOV θ, viewport height H device px):
half-angle subtended by the bounding sphere ≈ r/d (small-angle); px-per-radian at screen
centre = (H/2)/tan(θ/2); projected disc diameter p = 2·(r/d)·(H/2)/tan(θ/2)·... collapsing:
**p = 2r/d · H/(2·tan(θ/2)) = 2r/d · K_px** ✓. SSE of error e: **e/d·K_px** ✓ — identical to
the 3D-Tiles formula `SSE = e·H/(2·d·tan(θ/2))`. Switch distance from `sse ≤ τ`:
**d = e·K_px/τ** ✓. No factor-of-2, radius/diameter, or radian errors. Worked numbers
verify: K_px(1080 px, 75°) = 1080/(2·0.7673) ≈ 704 ✓; chip r = √3/2 ≈ 0.87, p=2px at
d ≈ 0.87·704 ≈ 612 ✓; pitch-2 switch 2·704 ≈ 1408 ✓; ship card 30·704 ≈ 21 100 ✓.

**Gap 1a — DPR is asserted, not verified.** The shipped driver reads
`get_viewport().get_visible_rect().size.y` with fallback 1080
(`godot/src/cosmos/cosmos_sky.gd:1589-1595`). The project uses
`window/stretch/mode="canvas_items"` over a 1280×720 base (`godot/project.godot:19-21`).
Whether that returns **device** px on the web export (hidpi canvas scaling ×
devicePixelRatio) is not established anywhere in the repo. A DPR=2 mistake shifts every
switch distance 2× (visual-only, but it doubles the mesh-tier population and halves the
dot tier). **P0 must include a one-time runtime check** (compare viewport height against
`JavaScriptBridge`-read `window.innerHeight·devicePixelRatio`) and pick the correct
source, rather than inheriting the sky driver's unverified read.

**Gap 1b — the shipped driver does NOT handle zoom.** Design §4.6 says "plumb through
the same viewport signal BodyLod's driver uses". That driver uses a **constant nominal
FOV**: `LOD_NOMINAL_FOV_DEG := 70.0` (`cosmos_sky.gd:60`, used at `cosmos_sky.gd:1540`) —
the telescope-zoom recompute is M4 future work, not shipped. ObjectLod's driver must read
the **live `Camera3D.fov`** per consult, not copy the nominal-constant shortcut. (Also
cosmetic: the worked example uses 75° / K≈704 while the shipped nominal is 70° / K≈771.)

**Minor — the chip row conflates two laws.** By the design's own selection rule
("coarsest rung with sse ≤ τ", card e = r/2), a 1-block chip switches L0→card at
d = (r/2)·K/τ ≈ **306**, not the tabulated ≈610 (which is the p=2px dot point). The card
band for a chip is [~306, ~612] — one octave, not "card ≡ dot band". Harmless, but the
table should be regenerated from the law before it becomes the gate's expected values.

## Claim 2 — StructDecimator verbatim reuse for movers · **CONFIRMED** (four caveats)

- `godot/src/world/struct_decimator.gd` (note: `world/`, not `cosmos/`) is pure-static,
  sampler-driven: power-of-two `coarse_pitch` targeting `STRUCT_TARGET_RES=16`
  (`struct_decimator.gd:23-28`, `cube_sphere.gd:1093`), **OR-occupancy** + majority-colour
  (`struct_decimator.gd:44-73`, `_majority_id` 77-85), face-culled cube bake with
  per-vertex `BlockCatalog.color_of` colours (`bake_lattice`, 92-127). A `pitch` override
  exists for coarser levels (`decimate(..., pitch)`, line 34). Building a per-object
  `ArrayMesh` from `{verts, colors}` and attaching it as a `MeshInstance3D` is exactly
  what `FacetFarStructures._baked` → merge does today; the per-object variant skips the
  merge. Correct reuse.
- **Merged-mesh rejection for movers: CONFIRMED.** `facet_far_structures.gd:5-11` — one
  merged ArrayMesh per band, verts pre-mapped `lattice_to_world64` into **ring-local**
  coords at bake time. Pre-transformed merged verts cannot follow a per-object live
  transform; re-merging per moved object per frame would be a rebuild storm. The design's
  rejection is right, and the (root, rev) bake-cache precedent is real
  (`facet_far_structures.gd:17-18, 44`).
- **Caveat 2a — the sampler must decode packed cells.** `VoxelBody.cells` stores **PACKED**
  values, not raw block ids (`voxel_body.gd:89`; `CellCodec.mat` decode at
  `voxel_body.gd:209-210, 645`). A naive `cells.get(c, 0)` sampler feeds packed ints into
  `_majority_id`/`color_of` → garbage colours for shaped/stateful cells. Sampler =
  `CellCodec.mat(cells.get(c, 0))`.
- **Caveat 2b — worker-bake race.** The decimator is thread-safe (pure statics, const
  tables), but a sampler closing over the **live** `body.cells` races with
  `break_cell`/`add_cell` mutating it on the main thread
  (`voxel_body.gd:148-190, 199-205`). P2 must snapshot (`cells.duplicate()` on main,
  cheap at ≤ a few hundred entries) and sample the snapshot in the worker.
- **Caveat 2c** — the decimator carries **no cache**; the (id, rev, pitch) LRU is new code
  the design owns (§4.3 says so — fine, but the teammate framing "is the output keyed by
  (id,rev,pitch)" is answered *no, the caller keys it*, per the far-structures precedent).
- **Caveat 2d** — shaped cells (modifier ≠ 0) OR-decimate to full cubes; error ≤ one
  coarse cell, inside e = c. Acceptable; document it.

## Claim 3 — VoxelBody lifecycle · **PARTIALLY REFUTED — the biggest must-fix cluster**

What exists:
- **Live transform**: yes — `RigidBody3D` (`voxel_body.gd:2`).
- **Dormancy**: yes — `is_awake()` = not frozen and not sleeping (`voxel_body.gd:407-408`);
  freeze/sleep machinery 228-419. The snapshot-dormant-rows idea is well-founded.
- **A mesh L0 can hide**: yes, but see the refutation below.
- **Spawn/parent topology**: both spawn paths land under `_frame_host()` (ActiveFrame
  when FP-FIXED-FRAME is on, else WorldManager itself — `world_manager.gd:1015-1016`):
  collapse spawns via `VoxelBody.spawn_loose(_frame_host(), …)` (`world_manager.gd:4388`)
  and splits via `_spawn_detached` → `get_parent().add_child` (`voxel_body.gd:518-523`).
  The scan-a-children-set registry pattern already exists (`active_body_count` et al.,
  `world_manager.gd:1763-1782`) — registration needs **no** signals. Good.

What is **missing** (refuting §4.4's "Diverges: none — zero physics changes"):
- **No `id`**: acceptable — `Object.get_instance_id()` is a stable unique key for the
  cache; no code change needed. Fine.
- **No `rev`**: there is **no revision counter anywhere in `voxel_body.gd`**, and
  `_rebuild()` (633-702) has no hook/signal. The design's cache law "(id, rev, pitch)…
  `_rebuild()` bumps rev" requires **adding a flag-gated `_rev += 1` to `_rebuild()`** (or
  an emitted signal). That is a physics-file edit; the design must own it explicitly in
  P1's diff budget instead of claiming zero changes.
- **L0-hide does not survive `_rebuild()`**: `_rebuild()` **queue_frees every
  `MeshInstance3D` child and creates a fresh one** with default `visible = true`
  (`voxel_body.gd:634-636, 661-663`). Consequences: (a) a latched `mi.visible = false` is
  silently undone by any `break_cell`/`add_cell` — a far, decimated-tier body pops its
  full mesh back on for one+ frames; (b) any stand-in mesh parented **under** the body is
  deleted outright. The tier must re-apply the hide on every rev bump (same hook as the
  cache invalidation — one mechanism serves both), and stand-ins must live outside the
  body's children (or be excluded from the `_rebuild` sweep by a flag-gated filter).
- **Frame/space mapping is unaddressed (new finding).** Debris transforms are
  **ActiveFrame-local lattice** poses (`voxel_body.gd:130-137`; lattice-vs-global
  discipline throughout, e.g. 152-156, 564-583). The proposed `ObjectLodTier` is a child
  of `FacetFarRing`, whose children inherit the ring's **placement transform / anchor
  shifts / SN3 scaled placement** (`facet_far_trees.gd:14-16`). Copying `body.transform`
  straight into a MultiMesh row under the ring **misplaces the card** whenever the ring
  transform ≠ ActiveFrame transform — which is precisely the orbit/far regime this tier
  exists for. The far-tree analogue of this bug was #131 (frame weld, `datum_lift` +
  world-axis basis). P1 must state the mapping explicitly:
  `row_xform = ring_placement⁻¹ · T_frame · body.transform` (and its SN3 scaled-placement
  form), and the gate must assert card == L0 position to sub-cell on a synthetic body at
  a facet fold.

## Claim 4 — MultiMesh moving-transform mechanics on gl_compat · **CONFIRMED**

- **set_buffer-only law**: real and load-bearing — `facet_far_trees.gd:704-706` ("We do
  NOT use set_instance_transform: on a set_buffer-[fed MM it is a no-op]"), uploads at
  `facet_far_trees.gd:1202, 1328` and the near-guard flush `738-741`; memory
  [[voxiverse-fartree-polish132]] (the `set_instance_transform` no-op gotcha, PR #62/#63).
- **Per-row lazy rewrite is coherent with set_buffer**: keep the CPU-side
  `PackedFloat32Array` retained (far-trees keeps `_last_buf`/`_last_mesh_bufs`), skip
  recomputing rows whose accumulated screen motion `Δx·K_px/d < 0.5 px`, and upload the
  **whole** buffer once iff ≥ 1 row changed. The 0.5 px skip saves row *recompute*, not
  upload bytes — the design says exactly this; correct. 2048×20×4 B = 160 KB/upload is
  fine at a low duty cycle; the gate must assert settled-scene rewrite count == 0 (the
  FT_DELTA lesson — count rebuilds, not fps).
- **colors+custom stride 20**: `mesh_stride()` (`facet_far_trees.gd:375-378`) —
  `use_colors=true, use_custom_data=true` → 12 xform + 4 COLOR + 4 CUSTOM = 20, COLOR
  written white; the colour-slot-aliasing trap is real ([[voxiverse-far-trees-colorfix]],
  PR #55). Design repeats the law correctly.
- **INSTANCE_CUSTOM f16 on web**: project law (same memory); the design stores only
  atlas_col / hue / fade / luma there — all f16-safe. Positions never ride CUSTOM. OK.
- **Budget arithmetic hole (SHOULD-FIX)**: "atlas CPU-rasterised **per object-rev**
  (LRU)" at `OBJ_CARD_INST_MAX = 2048` is 2048 unique 32×32 RGBA8 tiles = **8 MB of atlas
  alone** — 2× the whole proposed ledger. Far-trees affords its atlas because it is
  **8 archetypes** (256×64 total, `facet_far_trees.gd:41-44`). Cap unique card tiles
  (e.g. 256 ⇒ 1 MB) and fall back to shared archetype shapes tinted by majority colour
  (COLOR slot) past the cap; account tiles in the ledger.

## Claim 5 — Sub-pixel beacon, no hard cull · **CONFIRMED** (one omission: occlusion)

- **No log-depth / reversed-Z on this path**: CONFIRMED. Godot's `gl_compatibility`
  (GLES3/WebGL2) backend has neither reversed-Z (RenderingDevice-only since 4.3) nor a
  writable float depth; nothing in the repo patches depth handling. The shipped far scene
  already lives inside `CAMERA_FAR = 9000` (`facet_far_ring.gd:30`) with clamped-distance
  angular-size-preserving sky placement (the Moon ring is placed at
  `cam + dir·D_SKY` scaled to the impostor's angular radius — `cosmos_sky.gd:1551-1558`).
  Extending that technique to objects is the right call; depth precision never enters.
- **Brightness ∝ p²**: photometrically correct. A fixed-2px rendered dot standing in for
  a true disc of angular size p must carry the true flux, which scales with solid angle
  ∝ (r/d)² ∝ p² — i.e. luma_dot = L_surface·(p/2px)², floored at `DOT_MIN_LUMA` as a
  deliberate gameplay (beacon) deviation. Same law as stellar magnitude ∝ 1/d². OK.
- **OMISSION (MUST-FIX for P3): planet occlusion.** A CLASS_SPACE object physically
  behind the planet (or below the horizon) whose position is **clamped** to
  `OBJ_FAR_CLAMP_D` will depth-win against terrain and shine through the planet. The sky
  already solves the analogous problem analytically for sunlight
  (`CosmosSky.occlusion_factor`, ray-vs-body geometry — `cosmos_sky.gd:415-433`); the
  dot/card emit pass needs the same ray-sphere visibility test per body-in-the-way (Earth
  + Moon) before writing the row. Debris (true-distance placement, fog-bounded ≤ 2200 <
  FOG_BEGIN) does not need it; clamped placement does.
- Depth **within** the far tiers: coarse painter's order by tier (render_priority), as
  the sky does — the design says "depth-sorted coarsely by tier"; adequate.
- `gl_PointSize`: the design's justification ("unsupported through Godot's spatial
  shaders") is loosely stated — `POINT_SIZE` exists for point-primitive meshes — but
  point-size range on WebGL2 is implementation-dependent (only 1 px guaranteed), so the
  camera-facing-quad choice is right regardless. PLAUSIBLE→OK.

## Claim 6 — Never-OOM budget · **REFUTED as specified — fixed 4 MB must become auto-configured**

The ledger/caps/priority *mechanism* is sound and precedented
(`FAR_TREES_BYTES_MAX = 4<<20`, `cube_sphere.gd:906`; `STRUCT_BYTES_MAX = 8<<20`,
`cube_sphere.gd:1097`; `BodyLod.far_tier_bytes` + 32 MB ceiling, `body_lod.gd:190-239`;
capped-with-telemetry `_capped` convention, `facet_far_trees.gd:1202-1208`). But the user
requires the budget to **auto-configure small→large from available VRAM**. Feasibility on
WebGL2, honestly assessed:

| Proxy | Verdict |
|---|---|
| Direct VRAM query | **Impossible** on WebGL2 — no API. |
| `navigator.deviceMemory` | Chrome/Edge only, quantized, capped at 8, reports **system RAM** not VRAM. Weak but usable tier hint via `JavaScriptBridge`. |
| `WEBGL_debug_renderer_info` GPU string | Available (unmasked renderer). Classify {software/llvmpipe, Intel/Adreno/Mali, Apple, NVIDIA/AMD} → tier. String-matching is fragile but is the industry-standard practice; must fail-safe to the low tier. |
| `RenderingServer.get_rendering_info(TEXTURE_MEM_USED / BUFFER_MEM_USED)` | Engine-side **own-usage** estimates — right tool for the ledger's actuals, useless for *capacity*. |
| `performance.memory` / WASM heap | JS/WASM heap only — governs the CPU-side never-OOM ([[voxiverse-never-oom-web]]), not VRAM. |
| Adaptive probe (grow until frame-time/alloc pressure) | **Rejected upward.** On WebGL2 an over-allocation frequently manifests as **context loss** — the whole game dies, unrecoverable without reload. Probing toward failure violates never-OOM structurally. Downward adaptation (demote on sustained pressure) is safe. |

**Required reconciliation** (replaces the fixed constant):
1. `OBJ_LOD_BYTES_MAX` becomes a **boot-time-selected tier** from a closed ladder, e.g.
   {2, 4, 8, 16 MB}, chosen once from (GPU-string class, `deviceMemory`,
   `navigator.hardwareConcurrency` — never `OS.get_processor_count()`
   [[voxiverse-web-core-count]] — and device-px viewport area). Unknown/blocked signals ⇒
   the 2 MB floor. Instance caps (`OBJ_MESH_MAX` / `OBJ_CARD_INST_MAX` /
   `OBJ_DOT_INST_MAX`) derive from the chosen tier, not independent constants.
2. The **compile-time hard max (16 MB) stays a constant**, and the P0 gate proves the
   worst legal state at the **max** tier — so never-OOM remains structural and provable
   regardless of what the selector picks.
3. Mid-session adaptation is **demote-only** (sustained frame-time pressure drops one
   tier, frees pools); promotion only at boot. No grow-to-failure probing, ever.
4. Selected tier + reason string goes to telemetry (the `_capped` log convention) so live
   A/Bs can see what the selector did.

## Claim 7 — Byte-off + staging · **CONFIRMED** (with three OFF-purity watch-points)

- The default-OFF discipline is the established pattern: `FP_BODY_LOD := false`
  (`cube_sphere.gd:2965`), `FP_FAR_TREES_CARDS := false` (`cube_sphere.gd:895`); `BodyLod`
  is documented DEAD off-flag (`body_lod.gd:7`). No `FP_OBJ_LOD*` exists yet — namespace
  clean.
- **P0 as pure statics + gate is the right first step** — it is byte-for-byte the
  `BodyLod`/M1 precedent (pure law file + `verify_body_lod`-style gate, no renderer
  change), and it forces the corrected math (Claims 1/6) to be pinned before any node
  exists.
- OFF-purity watch-points for P1+: (a) the registry scan of `_frame_host()` children and
  every `ObjectLodTier` construction must sit behind the flag (never-constructed off,
  like `FacetFarStructures` — `facet_far_structures.gd:27`); (b) the `voxel_body.gd`
  edits (rev bump, rebuild hook, `_rebuild` sweep filter) must be flag-gated to
  byte-identical off; (c) FLAT `verify_feature.gd` must stay 6042/0 with all `FP_OBJ_LOD*`
  off — the P1 gate run must include it, and P1's L0-hide must be provably inert off-flag.

---

## Priorities

**MUST-FIX before implementation**
1. **VoxelBody rev + rebuild hook + rebuild-surviving L0-hide** (Claim 3). Add flag-gated
   `_rev` bump in `_rebuild()` (voxel_body.gd:633) + a tier re-apply of visibility on rev
   change; never parent stand-ins under the body (the `_rebuild` sweep deletes them,
   voxel_body.gd:634-636). Retract "zero physics changes" — own the diff.
2. **Frame/space mapping** for card/mesh rows: ActiveFrame-lattice body pose → ring-space
   row transform (incl. SN3 scaled placement); gate a synthetic facet-fold body for
   card==L0 alignment (the #131 far-tree frame-weld class).
3. **Auto-VRAM budget ladder** replacing the fixed 4 MB (Claim 6): boot-time proxy-selected
   tier {2..16 MB}, hard max constant, gate proves worst-state at max, demote-only
   adaptation, no probe-to-failure.
4. **Planet-occlusion test for clamped CLASS_SPACE placement** (Claim 5): analytic
   ray-sphere versus Earth/Moon before emitting a clamped dot/card row.
5. **Worker-bake data race + packed-cell decode** (Claim 2): main-thread `cells`
   snapshot for the P2 worker; sampler decodes `CellCodec.mat`.

**SHOULD-FIX**
6. K_px sourcing: verify device-vs-CSS px on the web export once at boot (DPR check);
   read live `Camera3D.fov` — do **not** inherit `LOD_NOMINAL_FOV_DEG` (cosmos_sky.gd:60).
7. Card-atlas unique-tile cap + ledger line (per-object-rev tiles at cap = 8 MB > ledger);
   archetype-tinted fallback past the cap.
8. Regenerate the §4.1 worked table from the law (chip card-onset ≈ 306 not 610; align
   the example FOV with the driver's) before it seeds gate expectations.

**OK as designed**
- The law itself, thresholds (τ=1 px, P_POINT=2 px, ±25% one-sided hysteresis), SSE-driven
  selection, closed-form switch distances.
- StructDecimator reuse (with the caveats above), merged-mesh rejection for movers,
  card/dot tier split, dormant-snapshot rows, delta gate, set_buffer-only writes,
  stride-20 colors+custom law, f16-safe CUSTOM payloads, dither-discard fades,
  brightness ∝ p² with a luma floor, P0→P4 staging order.
