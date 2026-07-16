# COSMOS — Walking & Crossing Performance: First-Principles Architecture Analysis

**Status:** analysis + ranked roadmap (no implementation in this pass).
**Scope:** why the live web build walks at ~30 fps with periodic 60–380 ms hitches, what the
frame budget actually consists of, and the ordered set of levers that gets it to "acceptable".
**Data:** `tools/remote-bridge/results/telemetry.jsonl` — 2.5 h + 29 min live real-GPU remote
sessions (32,736 rows, 11 attributed crossings), cross-read against
`docs/COSMOS-MESH-PACING-DESIGN.md` (whose apply-path exoneration this analysis confirms and
extends) and the actual render-path code.

---

## 0. Executive summary

1. **The web frame rate is a vsync ladder, not a dial.** The browser rAF quantizes every frame
   to 16.7 / 33.3 / 50 ms. At 44 draw calls the game sits at 55–60 fps (frames ≈ 1 vsync); at the
   fully-streamed 204-draw load it sits at ~30 fps (every frame ≈ 2 vsyncs). "Acceptable" is a
   threshold problem: get the true frame cost under 16.7 ms and the fps *doubles*; shave 5 ms
   without crossing the threshold and the user sees *nothing*.
2. **Two deterministic hitch sources were hiding inside the "render ceiling" class, and both are
   ours, cheap to fix, and worth more felt smoothness than any pacing knob:**
   - **The far-ring full re-emit** (`facet_far_ring.gd:140 _rebuild_full`) — after *every*
     crossing **and every neighbour-pool change**, ~332k GDScript→C++ `SurfaceTool` calls +
     `generate_normals()` over ~55k tris execute in **one frame**. Estimated 150–500 ms in wasm
     GDScript. This — not generation — is the primary component of the consistent 157–381 ms
     post-crossing worst frames.
   - **The remote-bridge frame capture** (`remote_bridge.gd:508`) — a synchronous
     `viewport.get_texture().get_image()` (WebGL2 `glReadPixels` = full GPU pipeline stall) +
     full-res `resize` + `save_jpg_to_buffer` on the engine thread, **every 500 ms**, during every
     remote session. The telemetry shows a perfect 2-window alternation (worst 32↔65 ms at the
     204-draw state, 18↔53 ms at 44 draws): **the capture adds a ~35 ms hitch twice per second**
     to exactly the sessions in which we (and the user) judge the game's feel.
3. **The steady-state floor is per-draw-call CPU cost on GL-compat→ANGLE, as suspected — but at
   204 draws, not 1000+.** Measured slope ≈ 70–80 µs/draw window-to-window (vsync-inflated; true
   cost likely 40–60 µs/draw). Draw composition: ~90 surface mesh blocks × ~2.1 material surfaces
   each + far ring (1) + misc (~15). **The lever is materials, then block size** — cutting
   surfaces-per-block to 1 via a texture atlas takes 204 → ~110 draws and plausibly crosses the
   16.7 ms threshold on mid clients; a 64³ mesh-block engine patch (or settled-terrain baking)
   takes it to ~40 and makes 60 fps robust.
4. **The streaming controller (`stream_credit`) is pinned at 0 for entire sessions by design
   arithmetic:** its overload setpoint is `CTRL_FRAME_BUDGET_MS = 18` (`cube_sphere.gd:169`)
   while the *healthy* full-radius steady state is 33 ms frames. A client that can never do
   better than 30 fps reads as permanently overloaded, so optional streaming runs at floor pace
   forever. The setpoint must become relative to the client's achievable floor — or the draw-call
   cut must land first, which un-pins it naturally.
5. **Dead ends confirmed** (do not spend effort): greedy meshing *for fps* (prims are 137k — an
   order of magnitude below relevance; draw calls unchanged), `time_budget_ms` pacing (apply
   queue empty; see MESH-PACING doc), per-block visibility gating (godot_voxel owns RIDs),
   radius shrink (user-vetoed), WebGPU *now* (not shipped in 4.4; it is the eventual
   ceiling-breaker per `GODOT-MIGRATION-ASSESSMENT.md`).

---

## 1. Measurement integrity — what the telemetry can and cannot say

Fields, from `godot/src/net/remote_bridge.gd:376-405`:

| field | source | validity |
|---|---|---|
| `worst_ms` | max true wall `ticks_usec` frame delta per ~0.27 s window | **The only reliable timing.** Includes GDScript + physics + render submit + GPU sync + rAF wait. |
| `fps` | frames per window | Reliable. |
| `proc_ms` | `Performance.TIME_PROCESS` | **Invalid on threaded web** — includes rAF/compositor wait (memory `voxiverse-web-time-process-invalid`). Never use for attribution. |
| `vox_gen/mesh/main/gpu` | `VoxelEngine.get_stats()` task counts | **Queue depths, not milliseconds.** `vox_main = 0` means *no pending apply tasks at the sample instant* — it does **not** measure how long applies took. Any claim of the form "vox_main ≈ 0 ⇒ mesh apply is free" over-reads this field. |
| `draws`/`prims` | `RENDER_TOTAL_DRAW_CALLS_IN_FRAME` / primitives | Reliable. |

### 1.1 The observer effect (new finding)

`_capture_frame_async()` (`remote_bridge.gd:508-540`) runs every `FRAME_INTERVAL_MS = 500` in
every authed remote session: `get_image()` on the viewport texture is a synchronous WebGL2
readback (pipeline flush + 1280×720 RGBA transfer), followed by a bilinear resize and a JPEG
encode, all on the engine thread. The telemetry windows are ~270 ms, so **every other window
contains one capture** — and the data shows exactly that:

```
steady state, 204 draws:  worst_ms = 32.6, 66.5, 32.5, 65.0, 32.1, ...   (2-window period)
steady state,  44 draws:  worst_ms = 18.7, 53.4, 18.7, 55.1, ...
```

The capture-window excess is ~33–35 ms **regardless of scene load** — the signature of a fixed
readback+encode cost, not of scene rendering. Consequences:

- **The true no-bridge steady state is: 204 draws → stable ~30 fps with worst ≈ 32 ms (clean
  2-vsync frames, no hitch); 44 draws → 55–60 fps, worst ≈ 18 ms.** The twice-per-second 65 ms
  stutter that makes walking feel bad *in remote sessions* is partly self-inflicted.
- Every dataset used to judge "feel" and to drive the load controller during a remote session is
  polluted by a 2 Hz artificial hitch. The controller's p90-over-30-frames can absorb ≤3 outliers,
  so the capture alone doesn't pin it (§1.2 does), but it biases every worst-frame statistic.
- The 79%-"pure render/rAF" deep-spike class in `COSMOS-MESH-PACING-DESIGN.md` §1.3 is real, but
  its magnitude and its "evenly spread" texture include this 2 Hz component.

### 1.2 The controller is pinned at credit 0 by its own setpoint

`stream_load_controller.gd:79-95`: overload ⇔ EMA(window p90 frame ms) > `CTRL_FRAME_BUDGET_MS`
(= 18, `cube_sphere.gd:169`). At the fully-streamed 204-draw state the *healthy* frame is 33 ms
(2 vsyncs). p90 = 33 > 18 → sustained overload → AIMD drives credit to 0 and it can never
recover while the near field is streamed in. Telemetry: `stream_credit = 0` on **every row** of
the last 29-minute session. The in-tree comment (line 82) even states this reading is intended.

Effect: all *optional* streaming (neighbour fill, second-neighbour promotes) runs at
`CTRL_RELIEF_FLOOR = 0.25` or holds entirely, for the whole session, on any client whose
full-radius floor is ≥ 30 fps-locked — i.e. on exactly the Intel-class clients we target. Only
the committed-imminent slot (`CTRL_IMMINENT_COMMIT_PACE`) streams at full pace. The controller
was built to detect *transient* overload, but with a 60-fps-derived setpoint on a 30-fps-floor
client it degenerates into a constant. Fix options in §4 (L5).

---

## 2. Frame-budget accounting

### 2.1 The vsync ladder

Godot's threaded web export is driven by browser rAF at the display rate (60 Hz here). A frame
whose true cost exceeds 16.7 ms slips to the next rAF tick: observable frame times are ~16.7,
33.3, 50, 66.7 ms. The telemetry confirms: worst_ms clusters at 18, 32, 53, 65; fps medians are
mixtures of the 60/30/20 rungs. **All "fps" reasoning must be done in true-cost ms against the
16.7 threshold.**

### 2.2 Where the walking frame goes (measured)

Binned over the last 29-min session (capture-window rows excluded implication noted):

| state | draws | prims | frame (median) | worst (non-capture) |
|---|---|---|---|---|
| partially streamed | 44 | 82k | ~17–19 ms (51–60 fps) | 18.7 ms |
| fully streamed | 204 | 137k | ~30 ms (28–35 fps) | 32 ms |

- **Slope:** (30 − 18) ms / (204 − 44) draws ≈ **75 µs/draw** as observed; vsync quantization
  inflates this, so the true CPU+driver cost is plausibly **40–60 µs/draw**. That magnitude is
  consistent with Godot's GL-compat per-surface bind/uniform work translated through
  ANGLE→D3D11 on a slow client CPU — per-draw overhead, not triangle count (137k prims is
  trivial; fill at 720p is trivial; there are no shadows and one directional-free environment).
- **Base (44-draw) cost ≈ 16–18 ms**, i.e. the game already rides the 60 fps rung when the draw
  load is low. The base is composed of GDScript per-frame (player + WorldManager analytic
  physics + HUDs, small), physics ~3 ms, godot_voxel per-frame viewer/terrain processing across
  ≤5 pooled `VoxelTerrain`s, render submission, and browser compositing of a COOP/COEP 720p
  canvas.

### 2.3 Draw-call composition at radius 128 (verified against code)

- Active facet: view 128 blocks = radius 4 mesh blocks (32³, `module_world.gd:333`) → ~50
  surface columns, 1–2 blocks deep vertically (bulk-underground keeps interiors solid ⇒ fully
  enclosed blocks emit nothing) → **~60–90 mesh blocks**.
- Neighbours: ≤2 live at view 96, bounds-clamped to their slab → **~20–40 mesh blocks**.
- `VoxelMesherBlocky` emits **one surface per distinct material per mesh block**
  (`block_materials.gd`: every block id is its own textured/swatch `StandardMaterial3D`; a
  typical surface chunk holds grass+dirt+stone±sand±snow ⇒ **~2.1 surfaces/block** from
  204 ≈ 90×2.1 + far ring (1 draw, `facet_far_ring.gd:45` single `MeshInstance3D`) + ~15 misc
  (player, HUD, debris).
- **So the 204 draws are `mesh_blocks × materials_per_block`, and materials are the cheaper
  axis to attack** (no engine patch), block size the stronger one (engine patch).

### 2.4 What 60 fps requires

True frame cost < 16.7 ms. Non-draw base is ~10–12 ms of which ~3 physics + several GDScript +
voxel tick + submit/compose. At ~50 µs/draw that leaves headroom for **~100–130 draws**. Hence:

- **Atlas alone (204 → ~110 draws)** puts mid clients at/near the 60 fps rung and weak clients
  at a *clean* 30 (worst ≈ 33, no spikes) — a plausible "acceptable".
- **64³ mesh blocks or settled-terrain baking (→ ~40 draws)** makes 60 fps robust on Intel-class
  clients; this is the structural end-state for gl_compatibility.
- Getting under 16.7 ms *also* un-pins the load controller (§1.2) without touching its setpoint.

---

## 3. The post-crossing spike, decomposed

The honest post-crossing figure (per-crossing attribution windows, `remote_bridge.gd:130`):
**157–381 ms worst frame, once, within ~1.2 s of the crossing** — the crossing frame itself is
≤ 17 ms (`transform_ms = 0`, fixed-frame keystone working as designed).

### 3.1 Primary: the far-ring synchronous re-emit (new attribution)

`facet_far_ring.gd`: a crossing (`set_active`, line 57) and **any pool composition change**
(`set_pool_excluded`, line 92 — i.e. every neighbour spawn/retire while walking) set `_pending`.
`_process` then budget-warms new facets (3 ms/frame) and, on the final frame, calls
`_rebuild_full()` (line 140) **synchronously**:

- scans all 3456 facets, emits ~1728 front-hemisphere facets × 32 tris via per-vertex
  `SurfaceTool` calls → **~166k `add_vertex` + ~166k `set_color` GDScript→C++ round-trips**,
- then `generate_normals()` over ~55k tris and `commit()` (~4.6 MB vertex upload).

At ~1–2 µs per wasm GDScript call this is **300–700 ms of main-thread work in one frame** —
the right order, cadence (once, shortly after the crossing), and constancy (independent of
`blocks_replaced`, which varies 19→460 while post_worst stays 157–381) to be the dominant
component of the post-crossing spike. The generation burst (`vox_gen` 280–400 pending) the
MESH-PACING doc identified is real but secondary — worker threads contending with the browser
main thread degrade rAF, they don't produce a single ~300 ms frame with empty queues.

**Fix (cheap, high confidence):** the per-facet positions/colors are *already cached* as packed
arrays (`_pos_cache`/`_col_cache`, lines 31-32). Replace the per-vertex SurfaceTool emission
with direct packed-array assembly: pre-triangulate each facet once into cached
`PackedVector3Array`(verts) + `PackedVector3Array`(normals — flat, computable per cell at cache
time) + `PackedColorArray`, then `_rebuild_full` becomes ~1728 `append_array` copies (~5 MB
memcpy ≈ few ms) + one `ArrayMesh.add_surface_from_arrays`. Alternatively/additionally, spread
emission across frames under the existing 3 ms warm budget with a double-buffered mesh swap.
Memory: +1 normals array per cached facet ≈ +2–3 MB bounded by the existing cache — NEVER-OOM
compatible, flag-gateable (`FP_FARRING_FAST_REBUILD`).

### 3.2 Secondary: generation-burst rAF contention

During the ramp after a crossing, up to 10 voxel workers (web pthread pool 16,
`project.godot:63`) compete with the browser main thread on a client with maybe 4–8 logical
cores. Telemetry class: spikes with `vox_gen > 0` (~21% of ≥250 ms frames). Levers: the
committed-imminent pre-gen already moves most of this *before* the crossing; a lower web worker
cap on low-core clients (`threads/count/ratio_over_max` 0.7 → 0.5, or margin 1 → 2) trades fill
speed for rAF stability — cheap A/B, export-baked.

### 3.3 Tertiary: the capture (§1.1) landing inside the window

One in ~2 post-crossing windows contains a capture hitch, inflating `post_worst_ms` by up to
~35 ms.

---

## 4. Ranked levers (impact × effort, NEVER-OOM annotated)

| # | lever | expected effect | effort | risk | memory |
|---|---|---|---|---|---|
| **L1** | **Far-ring packed-array rebuild** (§3.1) | post-crossing worst 157–381 ms → **≤ ~30 ms**; also removes the same spike on every neighbour spawn/retire while walking | **S** (1 file) | low; verify seam colors/normals match | +2–3 MB bounded cache |
| **L2** | **Bridge capture hygiene**: interval 500 → 2000 ms, capture only when last-window worst < threshold, and/or capture at reduced viewport scale; add a `?frames=0` A/B | removes a 2 Hz ~35 ms hitch from every remote session; unpollutes all future measurement | **S** | none (dev tool) | none |
| **L3** | **Texture atlas + single opaque material** (one `StandardMaterial3D` with a block atlas; per-model UVs in the `VoxelBlockyLibrary` models instead of per-model materials) | draws 204 → ~110 and cheaper state changes per draw; expected steady frame 30 → ~20–24 ms: mid clients snap to 45–60 fps, weak clients get clean 30; controller credit can recover | **M** (library build in `module_world.gd:_configure_library` + manifest bakes; water/transparents keep a 2nd material) | medium: UV plumbing across the many baked model families (snow caps, slopes, composites); needs the byte-identity gates re-run | neutral-to-positive (1 atlas replaces N textures) |
| **L4** | **64³ mesh-block engine patch** (godot_voxel caps at 32; check the 16-bit index / worst-case vertex-count reason before committing) **or** settled-terrain consolidation (bake quiescent regions into 1 mesh/facet, keep a small edit bubble live) | draws ~110 → ~40 (with L3): 60 fps robust on Intel-class web GL | **L** (engine patch + rebuild, or a new baking subsystem) | high: remesh-per-edit cost ×8, larger upload transients; bake path risks memory duplication → must be ledgered + flag-gated | patch ≈ neutral bytes, larger transients; bake needs an explicit ceiling |
| **L5** | **Controller setpoint fix**: make `CTRL_FRAME_BUDGET_MS` adaptive (e.g. setpoint = clamp(p10-of-best-minute × 1.3, 18, 45) — overload means *worse than this client's own floor*), or gate on hitch-rate rather than absolute ms | optional streaming resumes on 30-fps-floor clients; neighbours pre-fill; crossings meet fuller pools | **S–M** | medium: re-run the G-M2-CTRL square-wave gates | none |
| **L6** | **Web worker-count A/B** (ratio 0.7 → 0.5) | shaves the `vox_gen`-burst rAF class (~21% of deep spikes) on low-core clients | **S** (export-baked) | slower fill | none |
| **L7** | **Forward+/WebGPU migration** (Godot 4.6+, per `GODOT-MIGRATION-ASSESSMENT.md` renderer-gated) | order-of-magnitude per-draw cost cut; the true ceiling-breaker; obviates L4 | **XL, blocked** on upstream WebGPU export shipping | — | — |

### Dead ends (do not spend effort)

- **Greedy meshing for fps** — prims are 137k at 720p with unshaded materials; neither vertex
  count nor fill is within an order of magnitude of mattering. It does not reduce draw calls
  (still 1 surface per material per block). Worth revisiting only as a *memory* optimization.
- **`time_budget_ms` / apply pacing** — the apply queue is empty (MESH-PACING §1.3); confirmed.
- **Hiding/merging godot_voxel mesh blocks from GDScript** — the module owns RIDs; node
  visibility doesn't propagate (`module_world.gd:32`); no per-block gate exists.
- **Radius shrink** — vetoed; and unnecessary: the same draw count can be bought with L3/L4.
- **Chasing the 1188 ms figure** — naive `sort -worst_ms` mixes the far-ring re-emit, capture
  hitches, gen-contention and background-tab gaps; the attributed post-crossing worst is
  157–381 ms and L1 removes most of it.

---

## 5. Sequenced recommendation

**Step 1 — kill the deterministic hitches (L1 + L2 + L5; ~days).**
Far-ring packed-array rebuild, capture hygiene, controller setpoint. This is almost all of the
*felt* jank for a fraction of the effort: crossings become genuinely smooth (the keystone
already made the crossing frame free; L1 removes the deferred bomb), walking loses the 2 Hz
stutter in remote sessions, and streaming stops being starved on the very clients we tune for.
After this the game should read as "stable 30 fps, no spikes" on the tester — re-measure before
Step 2, because all prior worst-frame data is capture-polluted.

**Step 2 — the draw-call cut that needs no engine rebuild (L3; ~1–2 weeks).**
Texture-atlas + single opaque material in the blocky library. 204 → ~110 draws puts the true
frame cost at the 16.7 ms boundary: mid-tier clients jump a vsync rung to 45–60 fps and the
weakest stay at a clean 30. Flag-gate (`FP_ATLAS_MATERIAL`), A/B live via the bridge, keep the
per-model-material path as fallback. This is the highest engineering-value single change on the
gl_compatibility path.

**Step 3 — choose the structural end-game (L4 now vs L7 later).**
If after L3 the tester still sits at 30 fps, take the 64³ mesh-block investigation first (verify
godot_voxel's index format / vertex-count cap — that is likely *why* 32 is the max); if it's
sound, it stacks with L3 for ~40 draws and robust 60 fps. If the patch is structurally blocked,
the honest answer is that gl_compatibility is within ~2× of its ceiling here and the remaining
headroom lives in the Godot 4.6/WebGPU migration — which memory already marks as the planned,
renderer-gated route. Do not build the settled-terrain baker unless both L4 routes fail: it
duplicates the mesher and carries the worst NEVER-OOM surface of any option.

**Success criteria** (measure with L2 landed, frames off): steady walking p90 frame ≤ 33 ms with
zero >100 ms frames over a 10-minute walk; post-crossing worst ≤ 50 ms; median fps ≥ 30 on the
Intel-HD tester, ≥ 45 after Step 2 on a mid client.
