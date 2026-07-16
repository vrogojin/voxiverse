# COSMOS — What's Next: Architecture Verdict, SOTA Borrowings, and the Post-Atlas Roadmap

**Status:** analysis + ranked roadmap (no implementation in this pass). Successor to
`docs/COSMOS-PERF-ARCHITECTURE-ANALYSIS.md`, written after PR #19 landed (near-LOD removal,
bulk-underground, crossing pre-gen, far-ring async rebuild, adaptive controller, capture
hygiene, texture atlas) and after the L4 (64³ mesh block) web failure
(`docs/COSMOS-64MESH-DESIGN.md` — patch correct, native fine, web tab-hang during streaming).

**Measured post-PR-#19 state (live web, real GPU):** draws ~204→74–87, fps ~20→30–42,
crossing worst ~300–700 ms→~140 ms, walking worst ~940→140–330 ms. Pixel-identical look.

---

## 0. Executive summary

1. **The architecture is right. Do not replace it.** The faceted cube-sphere +
   fixed-LOD `VoxelTerrain` pool + hand-rolled far layer is not an accident of history —
   it is the only stack that simultaneously satisfies (a) blocky aesthetic with real
   editable voxels, (b) a curved planet with undistorted cubes, (c) WebGL2's per-draw and
   upload constraints. Every credible alternative (VoxelLodTerrain octree LOD, Transvoxel,
   engine-level clipmaps) fails constraint (a) or (b) outright (§3). What needs work is not
   the architecture but **three specific seams in it**, each of which maps 1:1 onto the
   user's three observations (§2).
2. **The single highest-leverage next change is the far-ring underlay** (§2.1): stop
   *excluding* active/pool facets from the FacetFarRing and instead draw a conservative
   (min-filtered, sunken) quad **under everything**, with a small player-bubble discard in
   the shader. One file + one shader. It simultaneously: fixes observation 1 (the mid-far
   see-through gap), removes the pool-churn rebuild class entirely (part of obs 2), and
   converts fast-movement streaming holes from "void with the planet's far inner wall
   behind it" into "plausible low-res ground" (the cosmetic half of obs 3). It can be
   extended to a **build-once, never-rebuild whole-planet ring** (+~7 MB, ledgered) that
   makes the far layer *zero-cost at crossings forever*.
3. **We do not currently know where the remaining 25–33 ms goes, and the next lever
   depends on it.** At 74–87 draws the draw-call slope (~40–60 µs/draw) explains only
   ~4–6 ms; the modeled base was 10–12 ms; yet the tester sits at 30–42 fps (24–33 ms
   true cost). Something in {base cost, fill rate at devicePixelRatio-scaled canvas,
   GDScript per-frame, voxel tick} is bigger than modeled. §1.2 defines two 10-minute
   A/B experiments (3D resolution scale; hidden-near draw floor) that split the frame
   into fill vs draws vs base *before* we spend weeks on the wrong axis.
4. **The L4 web failure is evidence, but not proof, that gl-compat is at its ceiling.**
   The far ring commits a ~4.6 MB mesh in one frame without hanging the tab; a 2–3 MB 64³
   godot_voxel apply hangs it. The difference (many concurrent per-surface buffer
   creations vs one; ANGLE buffer-orphaning; driver validation per `glBufferData`) is
   diagnosable, and if the hang is *pacing*, not *size*, a settled-terrain consolidation
   with explicitly paced sub-uploads remains the last big gl-compat draw cut (§4.6). Spike
   it (time-boxed) before declaring the ceiling reached.
5. **WebGPU remains THE ceiling-breaker and remains unavailable** (verified 2026-07-14,
   `docs/GODOT-MIGRATION-ASSESSMENT.md`): web export is Compatibility/WebGL2-only through
   Godot 4.7; WebGPU is an open proposal with no committed timeline. The plan stands:
   migrate 4.4.1→4.6/4.7 in the post-FP-M2 quiet window (positioning, ~1–2 weeks), watch
   godot-proposals #4806, and treat dual-target (Forward+ native desktop) as the visuals
   route that exists today. Nothing in this doc changes that; several things in this doc
   (underlay, predictive streaming, readiness-gated crossing) carry over to WebGPU intact.

---

## 1. Where the frame actually goes now (and what we don't know)

### 1.1 Post-atlas accounting

- Near field: ~50–60 surface mesh blocks × ~1 opaque material (atlas) + water/transparent
  second surfaces on shore blocks. Neighbours bounds-clamped at 96. Far ring: 1 draw
  (`facet_far_ring.gd` single MeshInstance3D, ~55k tris front hemisphere). Misc ~15.
  Total 74–87 measured — matches `mesh_blocks × ~1.1 + far ring + misc`.
- At the previously measured 40–60 µs/draw ANGLE slope, 74–87 draws ≈ **4–6 ms**. The
  old model (base 10–12 ms + draws) predicts ~15–18 ms ⇒ 55–60 fps. Measured: 30–42 fps
  (true frame 24–33 ms). **There is an unexplained 8–15 ms.**

### 1.2 Two cheap experiments before the next big lever (do these first)

1. **Fill-rate split — 3D resolution scale A/B.** The web export uses
   `html/canvas_resize_policy=2` (canvas follows the browser window) and Godot's web
   canvas scales with `devicePixelRatio`. On a 2× laptop panel the 3D target can be
   ~4× the 720p the analysis assumed. Add a `?scale3d=` query param mapped to
   `viewport.scaling_3d_scale` (compat renderer: bilinear upscale) and A/B 1.0 vs 0.75
   vs 0.5 on the tester. If 0.5 jumps a vsync rung, the remaining wall is **fill/bandwidth,
   not draws**, and the cheapest real win is a default resolution cap (e.g. clamp the
   effective 3D pixel count to ~1.2 Mpx, letterboxed by the 2D stretch) — an S-effort,
   flag-gated, fully reversible change that no draw-call work can substitute.
2. **Draw/base split — hidden-near floor.** `DEV_HIDE_NEAR` (module_world) collapses the
   near streaming radius to 8: measure the floor with ~15 draws. The delta from 74–87
   draws re-derives the live per-draw slope post-atlas; the floor itself is the true
   base (GDScript + physics + voxel tick + far ring + compositor). Whichever half is
   bigger names the next lever (§5).

The remaining sections are ordered so their recommendations are valid under *either*
outcome; where the choice depends on the split, it is called out.

---

## 2. The three observations — root cause and fix direction

### 2.1 Observation 1: "far terrain doesn't render under/around the player" — CONFIRMED, structural

**Root cause (code-verified).** The far ring draws every *front-hemisphere* facet EXCEPT
the active facet and the excluded set (`facet_far_ring.gd:214-220 _front_visible`), and
`world_manager.gd:2054-2069 _facet_ring_sync_exclusion` sets the excluded set to the live
pool neighbours (∪ LOD-covered facets when FP_M2_LOD is on). But exclusion is **per-facet
binary** while near coverage is **a viewer-centric disc**: a facet is ~201 blocks on a side
(edge = (π/2·R)/K = (π/2·3072)/24), half-diagonal ~142, and the voxel pool renders only
`near_render_radius()` = 128 around the player on the active facet and 96 on neighbours.
Everything on the active + pool facets *beyond* those radii is covered by **nothing** —
an annular hole ~70–200 blocks wide that tracks the player. Through it (the ring material
is `CULL_DISABLED`, `facet_far_ring.gd:415`) you see the inner surface of the planet's far
side — exactly the user's "only the opposite inner side of the globe shows".

The user's mental model is correct and should become the architecture:
**every facet always renders in far LOD; the near voxel field overdraws it.**

**Fix — the far-ring underlay (S effort, one file + one shader, flag `FP_FARRING_UNDERLAY`):**

1. **Draw all front-hemisphere facets, including active + pool** — delete the exclusion
   logic (`_front_visible` keeps only the hemisphere test; `set_pool_excluded` becomes a
   no-op; `world_manager._facet_ring_sync_exclusion` retires). Cost: +5–8 facets × 32 tris
   ≈ +200 tris. Still one draw call.
2. **Make the quad conservatively UNDER the terrain, never above it.** Today a quad vertex
   sits at the profile height (`_ensure_cached`, `facet_far_ring.gd:318-345`); a 50-block
   bilinear cell can float *above* true terrain in valleys, which was invisible under
   exclusion but would poke through the near field as a floating plane. Change the cache
   to a **min-filter**: sample the profile at the vertex and at 4 half-cell offsets, take
   the min, then sink a fixed margin (~1.5–2 blocks radially). The quad is then a strict
   under-estimate everywhere — visible only through holes (where it reads as slightly
   sunken ground: correct-by-construction as a fallback).
3. **Player-bubble discard for edit safety.** A dug pit deeper than the sink margin would
   expose the quad plane crossing the pit. Convert the ring material to a trivial
   ShaderMaterial (vertex-color albedo, `cull_disabled`) with a `player_pos` uniform and
   `if (distance(world_pos, player_pos) < mask_r) discard;` — mask_r ≈ 32 (edits happen
   within interaction reach ≪ 32). One uniform write per frame. This replaces per-facet
   exclusion with a per-pixel exclusion that is *exactly* the shape of the real coverage.
4. **Optional extension — the build-once whole-planet ring.** With exclusion gone, the only
   remaining rebuild trigger is the hemisphere terminator on crossing. Emit **all 3456
   facets once** (~110k tris, ~331k verts ≈ +7 MB over the current caches — ledgered,
   NEVER-OOM flag-gated): the ring becomes a static mesh built at setup (budget-warmed),
   and **crossings do zero far-ring work forever** — `set_active` keeps only its transform
   write; `_rebuild_full`, the async worker, the warm scheduler all become setup-only.
   110k tris is well inside the measured triviality band (137k prims at ~30 fps was
   draw-bound, not prim-bound). This also deletes the last far-ring term from the
   crossing spike (§2.2).

**Planet self-occlusion / back-face question (user asked):** mostly moot. The far ring is
ONE draw call, so culling its back half saves triangles, not draws — and triangles are not
the wall. The whole-planet option deliberately *stops* culling the back hemisphere and buys
zero-rebuild with the freed complexity. Near-field self-occlusion is negligible: over a
128-block view radius on R=3072 the surface drops ~2.7 blocks — nothing is hidden. Godot's
OccluderInstance3D CPU culling would cost wasm cycles to cull draws we don't have. **Do not
spend on occlusion culling.**

### 2.2 Observation 2: residual ~140 ms crossing hitch

The crossing frame itself is clean (fixed-frame keystone: `module_world.gd:1864-1870` skips
the PlanetRoot write; redesignate is O(bookkeeping)). The residual ~140 ms lands in the
~1 s after, and decomposes into:

1. **Mesh-upload burst of the 96→128 annulus** on the new active facet. The ramp
   (`view_target`/`_pool_ramp_kick`, `module_world.gd:1875-1886`) spreads *requests* over
   RAMP_SECONDS, and crossing pre-gen (`POOL_CROSSING_PREGEN`, prefill to 128 when the
   ridge is committed at <64 blocks) moves most volume before the border — but a fast or
   diagonal approach crosses with the prefill incomplete, and the remaining applies are
   atomic per-mesh-block `RenderingServer` uploads that WebGL2/ANGLE serializes on the
   main thread. This is the component the mesh-upload-pacing work targets.
2. **The far-ring deferred re-emit** still runs once per crossing (async behind
   `FP_FARRING_ASYNC_REBUILD`, whose main-thread residue is the `add_surface_from_arrays`
   swap of a ~4.6 MB mesh — tens of ms on a weak client). The §2.1(4) whole-planet ring
   **removes this term entirely**.
3. **ActiveFrame re-framing + GroundCollider re-centre + carve push** — small (~10 node
   transforms + bounded box updates) but same-frame.

**Fix direction — make the crossing a fully-prepared event (M effort):**
the redesignation is a *designation*, not a gameplay necessity — the player can walk onto
the neighbour's live, meshed, collidable terrain while `_pool_active` still names the old
facet (POOL_SWITCH_MARGIN hysteresis already exists). Gate the actual `redesignate()` on a
**readiness predicate**: imminent slot prefilled to ≥ the ridge-band radius AND the apply
queue drained AND controller credit above floor — then fire it on the first frame with
headroom. Combined with §2.1(4) and upload pacing, the crossing budget becomes: bookkeeping
(sub-ms) + at most one paced upload window. Expected: 140 ms → under ~50 ms worst.

### 2.3 Observation 3: "blocks don't generate fast enough when moving fast"

Three distinct sub-problems; don't conflate them:

1. **Visual holes while sprinting** — with §2.1 the fallback under every unstreamed cell is
   plausible low-LOD ground instead of void. This converts the failure from jarring to
   soft. Ship first; it may already reduce the *felt* severity below action threshold.
2. **Streaming can't keep up directionally.** godot_voxel streams in distance order around
   the `VoxelViewer` — it has no notion of velocity. Borrow the standard
   **movement-predictive streaming** trick (every streamed open-worlder since Cell/SPU-era
   GTA; in Minecraft-land, chunk-loading "look-ahead" mods): offset the viewer node by
   `min(speed, v_cap) · τ · v̂` (τ ≈ 1.5–2.5 s lookahead, offset clamped to ~48 blocks so
   the trailing edge never unloads under the player's feet). The engine then prioritizes
   the terrain the player is *about* to need. S effort (one node position expression in
   the viewer-follow code, `module_world.gd:~2507`), flag-gated, zero memory.
3. **Generation throughput is finite** (2–3 web workers on weak clients; bulk-underground
   already cut per-column cost). When demand exceeds supply, the honest options are
   (a) generate less (radius — vetoed), (b) generate earlier (predictive, above), or
   (c) **move slower — the soft speed clamp**: scale max ground speed by a streaming-health
   factor (e.g. `clamp(1 − k·(vox_gen_backlog − B0)/B1, 0.6, 1.0)`, smoothed over ~1 s, or
   analytically: the fraction of *meshed* mesh blocks in a cone ahead of the velocity).
   This is the physically-correct coupling — the same one Distant Horizons users know as
   "elytra outruns LOD generation" and Minecraft itself ships as slower elytra chunk
   loading. **It changes game feel → needs the user's sign-off on the curve**, but the
   mechanism is S effort and trivially flag-gated.
4. **Fall-through is a separate bug if it is real.** Physics is analytic
   (`WorldManager.block_id_at` → `TerrainConfig.generated_block`), so collision does NOT
   require generated voxel data — the floor exists before the mesh does. If the player
   genuinely falls through while sprinting, that is a GroundCollider re-centre latency or
   a facet-frame query bug, not a streaming-throughput problem. Add a telemetry counter
   (player_y < analytic floor_under − ε) before designing any fix.

---

## 3. Is the architecture right? — alternatives, honestly costed

| Alternative | What it would buy | Why it fails here | Verdict |
|---|---|---|---|
| **`VoxelLodTerrain` (octree/clipbox LOD)** as the one terrain, subsuming the far ring | Engine-maintained continuous LOD, would "fix" obs 1 for free | **Smooth/Transvoxel-only — there is no blocky LOD in godot_voxel through 1.6** (verified in `GODOT-MIGRATION-ASSESSMENT.md` §2 against the 1.5/1.6 changelogs). Adopting it means abandoning the blocky aesthetic — a design-lock violation, not a perf trade. Also single-lattice: no faceted-planet frames. | **No.** |
| Transvoxel/marching-cubes **far shell only** (smooth LOD for distance, blocky near) | Nice silhouettes far out | A second full meshing pipeline + memory class for scenery the 1-draw far ring already renders at ~zero cost; distant blockiness is invisible at 4-cell/facet resolution anyway. | **No.** |
| **Whole-planet single volume** (generator samples the sphere in one unbounded lattice) | No facets, no crossings at all | Gravity-aligned blocky play on a sphere in one lattice = distorted cubes — the exact thing FACETED was chosen to avoid (locked decision, user taste-tested k=24). | **No** (locked). |
| **Distant-Horizons-style dedicated far renderer** | Proven MC far-LOD pattern | **We already have one** — FacetFarRing (+ the retired FP-M2 LOD tier). The gap is coverage policy, not the pattern. Borrow its details (§4.1), don't rebuild. | **Already ours; refine.** |
| **GPU-driven / multidraw** | Collapse draw CPU | WebGL2 has `WEBGL_multi_draw`, but Godot's gl-compat renderer doesn't use it and threading it through is an engine-renderer patch far bigger than L4 was. Native WebGPU makes it moot. | **Defer to L7.** |
| **Impostor/billboard far terrain** | Cheapest possible far | The far ring *is* an impostor layer (flat colored relief quads, 1 draw). | **Done.** |

**Verdict: keep the stack.** The faceted planet + pooled fixed-LOD terrains + a far
underlay is structurally the same three-tier solution Distant Horizons converged on for
the same problem (blocky near + cheap far), adapted to a sphere. The remaining defects are
policy seams (exclusion→underlay, crossing readiness, viewer prediction) — all S/M fixes
*inside* the architecture. The one genuinely structural bet left on gl-compat is §4.6.

## 4. SOTA techniques and projects — what to borrow, concretely

1. **Distant Horizons (Minecraft mod)** — the closest prior art. Borrowables: (a) LODs
   are column-quantized (height + color per column) — our `_pos_cache`/`_col_cache` is
   already that; (b) far geometry lives in **few, huge, rarely-rebuilt GPU buffers**,
   rebuilt regionally and asynchronously, never globally per event — the §2.1(4)
   build-once ring is exactly this discipline; (c) **its known failure mode is ours**:
   flight outruns LOD generation → the accepted mitigations are prediction + generation
   throttling of *speed* (§2.3).
2. **Veloren (Rust)** — renders far terrain from a downsampled world **heightmap
   ("lod_terrain")** in a handful of draws, entirely decoupled from chunk meshing, with
   chunk meshes fading in over it — the same "far layer always covers, near overdraws"
   contract as the underlay. Validates: never let near-coverage state *subtract* from far
   coverage.
3. **Outer Wilds / floating-origin planet rendering** — their keystone (keep the physics
   frame fixed, move only cheap render placements) is our shipped FP-FIXED-FRAME. Done.
4. **Greedy meshing — re-confirmed dead for fps.** It merges coplanar faces *within* a
   surface: fewer triangles (~137k → maybe 40k), **zero fewer draw calls**, and the frame
   is draw/fill-bound, not vertex-bound. Only revisit as a memory optimization (if §1.2
   shows fill-bound, note greedy meshing does not reduce fill either — same covered area).
5. **Texture atlas caveat (already shipped, keep an eye):** atlas + mipmaps bleed at tile
   edges under minification. The standard fix when it shows is a **texture2DArray** (one
   layer per block texture, same single material, native in WebGL2) — equal draw count,
   no bleed. Only act on visual evidence.
6. **Settled-terrain consolidation with paced uploads — the last gl-compat draw cut.**
   The L4 lesson was that a single multi-MB godot_voxel apply hangs the tab; but the far
   ring's ~4.6 MB `commit()` does not. **Time-boxed spike (½ day): reproduce the 64³ hang
   and attribute it** — candidate causes: many per-surface `glBufferData` creations in one
   frame vs one; ANGLE re-validation; shader/material re-bind storms during apply. If the
   hang is *pacing-shaped*, then a GDScript-side baker — merge quiescent surface mesh
   blocks (outside the player's edit bubble) into ~1–4 consolidated ArrayMeshes per facet,
   built on a WorkerThreadPool task, uploaded in ≤512 KB sub-mesh slices across frames,
   with the source blocks hidden via a shrunk view box — buys the ~74→~30 draw end-state
   L4 promised **without an engine patch and without an atomic upload**. L effort, the
   worst NEVER-OOM surface of anything here (transient double-geometry) → explicit ledger
   + ceiling + flag, and only worth it if §1.2 says the wall is draws (need-the-user).
7. **Occlusion culling** — bounded and rejected for this scene (§2.1): 1-draw far ring,
   ~2.7-block horizon drop over the near radius, frustum culling already handled per mesh
   block by godot_voxel's `RenderingServer` instances.
8. **MultiMesh/instancing** — right tool for repeated *props* (trees as instanced
   canopy/trunk meshes, debris) when prop count grows; irrelevant to unique terrain
   surfaces. Note for the content roadmap, not this perf pass.
9. **Chunk-mesh caching across crossings** — the pool already IS the cache (live slots
   persist; retired slots restream). The marginal win of caching *meshes* for retired
   facets is small against its memory class. Skip.

## 5. The WebGPU / Forward+ question (L7) — quantified verdict

- **Status (verified 2026-07-14):** web export is Compatibility/WebGL2-only through Godot
  4.7; WebGPU-on-web is an open proposal (godot-proposals #4806) with no assignee, no
  timeline. Browser-side WebGPU is universal since Safari 26 (2025-09). A community
  4.6.2-based WebGPU fork exists (beta) — not a production path for a threaded
  custom-module build. Nothing has changed since the migration assessment.
- **What it buys when it lands:** the per-draw CPU cost drops an order of magnitude
  (pre-validated pipelines + bind groups vs ANGLE's per-draw GLES3→D3D11 translation and
  state re-validation); render-graph submission moves off the main JS thread; and the
  RenderingDevice renderers (Forward+/Mobile) become possible in-browser — i.e. **both**
  our walls (draw CPU, upload stalls) are the exact things WebGPU's API shape removes.
  At 74–87 draws we would be nowhere near any WebGPU limit; L4/§4.6-class work becomes
  unnecessary; the visuals ceiling (§3.2 of the migration doc) lifts too.
- **Is it THE answer?** For the *ceiling*, yes. For *now*, no — it is unschedulable. The
  correct posture is unchanged: (1) do the S/M policy fixes in this doc (they are
  renderer-agnostic and survive the migration); (2) migrate to 4.6/4.7 in the post-FP-M2
  quiet window so the eventual WebGPU hop is one minor, not four; (3) re-open the renderer
  strategy the day a WebGPU web export reaches an official dev snapshot; (4) treat
  **dual-target** (Forward+ desktop export for visuals, gl-compat web for reach) as the
  deliverable that exists today if the user wants "great visuals" before WebGPU ships.
- **Dual-target worth it?** Yes, later, as its own milestone (per the migration doc §3.3):
  our two-render-path discipline already proves gameplay parity, and the Docker pipeline
  already builds native binaries. It is a *visuals* play, not a web-perf play — it does
  nothing for the three observations.

## 6. Ranked, sequenced plan

**Tonight-safe (flag-gated, low risk, no user decision needed):**

| # | change | fixes | impact | effort | risk |
|---|---|---|---|---|---|
| N1 | **Far-ring underlay + player-bubble discard** (§2.1 items 1–3, `FP_FARRING_UNDERLAY`) | Obs 1 root cause; pool-churn rebuilds; obs 3 cosmetics | The mid-far gap disappears; planet reads solid from every altitude | S (1 file + 1 shader) | low — min-filter + sink margin is conservative by construction; visual A/B live |
| N2 | **Whole-planet static ring** (§2.1 item 4, same file, `FP_FARRING_STATIC`) | The far-ring term of obs 2; deletes rebuild machinery | Crossings do zero far-ring work, forever | S–M | low; +~7 MB ledgered (NEVER-OOM: cap + flag) |
| N3 | **Predictive viewer offset** (§2.3.2, `FP_VIEWER_LOOKAHEAD`) | Obs 3 streaming direction | Terrain ahead streams before arrival; trailing edge clamped | S | low; tune τ live via query param |
| N4 | **§1.2 experiments**: `?scale3d=` A/B + hidden-near floor re-measure | names the next wall | Decides fill vs draws vs base with data | S | none (measurement) |
| N5 | **Crossing readiness gate + upload pacing** (§2.2) | Obs 2 residual | 140 ms → target ≤50 ms worst | M | medium — interacts with pool policy; gate suite must pass (coordinate with the in-flight mesh-upload-pacing work) |

**Need-the-user (bigger bets / feel changes):**

| # | change | when |
|---|---|---|
| U1 | **Soft speed clamp** coupled to streaming health (§2.3.3) | after N1+N3 land and obs 3 is re-felt; the curve is a game-feel decision |
| U2 | **64³-hang attribution spike → settled-terrain consolidation** (§4.6) | only if §1.2 says the wall is draw count AND 60 fps on mid clients is required pre-WebGPU |
| U3 | **3D resolution cap default** (if §1.2 says fill-bound) | visual tradeoff — user judges 0.75/0.5 look on the live tester |
| U4 | **Godot 4.6/4.7 migration** (positioning) | post-FP-M2 quiet window, per `GODOT-MIGRATION-ASSESSMENT.md` |
| U5 | **Dual-target Forward+ desktop tier** (visuals) | its own milestone, after U4 |

**Success criteria:** (a) no see-through to the planet interior from any position/altitude
on a 10-minute walk (obs 1); (b) crossing worst ≤ 50 ms attributed (obs 2); (c) sprinting
shows sunken-LOD ground, never void, and fall-through counter = 0 (obs 3); (d) steady p90
frame unchanged or better with N1+N2 on (the underlay must not cost a rung — it adds ~200
tris and removes rebuilds, so any regression means a bug, not a tradeoff).
