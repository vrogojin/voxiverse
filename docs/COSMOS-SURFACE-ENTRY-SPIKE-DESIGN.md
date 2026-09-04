# COSMOS — Surface-Entry (Ascent) Regime-Flip Spike: Root Cause + Design

**Symptom (measured):** a set_alt sweep over the 603-house village: `surface(alt 7) → 500` =
worst_ms **1111**; every higher crossing (620→2400) is 75–222 ms; the whole descent is 96–220 ms.
`wf_st_step_us = 0` on the spike frame ⇒ NOT the far-structure card tier (Stage 3 already staged it).

**Verdict in one line:** the spike is the **surface→off-surface REGIME EDGE at OFFSURFACE_Y = 256**
(`cube_sphere.gd:2727`) — one boolean, `FacetFarRing.shell_offsurface()`
(`facet_far_ring.gd:3765`), flips, and every far tier that keys off it does its wake work
**unbudgeted, on the flip frame, in the ascent direction that none of the deployed pacing flags
cover** (they all cover descent, or the floored side of the boundary). The near voxel field is
explicitly NOT the cause (§1.4).

---

## 0. The boundary map (what the 7→500 teleport actually crosses)

A single `set_alt 7→500` step crosses **three** regime edges in one frame — a live climb crosses
them seconds apart, but each is individually spiky and #1 carries nearly all the weight:

| alt | edge | what flips |
|---|---|---|
| **256** | `OFFSURFACE_Y` (`cube_sphere.gd:2727`) | the emit-law **surface floor releases** (`facet_far_ring.gd:1267-1279`), `shell_offsurface()` → true, far-trees zone S→B, far-structures zone S→B, orbit-relief un-hides + un-suspends, FacetTexBaker close-up path opens (`world_manager.gd:1512`), DEM sweep mode opens (`world_manager.gd:1553-1555`), snow skip arms (`world_manager.gd:692`) |
| 384 | `ATMO_TOP` (`cube_sphere.gd:3203`) | sky/atmo **uniform-only** crossover (property writes, `cosmos_sky.gd:379` — no material swap, shaders already warm from the ground view) |
| 448 | `ATMO_TOP + ALT_REGIME_REENTRY_PREP + ALT_REGIME_HYST` = 384+32+32 (`cube_sphere.gd:3387,3399`; `world_manager.gd:762-775`) | `FP_ALT_REGIME` orbital latch — a **suspend** (pool manager gated off at `world_manager.gd:1562`), not a teardown |

Not crossed: the approach-anchor release (`ANCHOR_REL_LO/HI` = 700/900, `cube_sphere.gd:3056-3057`
— the near field stays fully resident through the spike altitude) and the block-LOD orbit engage
(`BLOCK_LOD_ORBIT_ENGAGE_H` = 4000·(1±0.25), `cube_sphere.gd:2606-2607` — never reached by the sweep).

---

## 1. Root cause — who does burst work on the flip frame

### 1.1 FacetFarTrees zone S→B: the only FORCED, UNBUDGETED, main-thread whole-tier rebuild (primary)

- The zone law reads `shell_offsurface()` every step (`facet_far_trees.gd:809-811`); zone
  S→B is decided the same frame the ring's floor-release snapshot commits.
- `_apply_visibility` **hides the whole rung-1 3D-tree mesh set immediately** on entering zone B
  (`facet_far_trees.gd:780-785` — `mmi.visible = false` for every mesh MultiMesh). Cards, still
  holding the stale zone-S buffer, only cover [448, 2400] (`FAR_TREES_MESH_MAX`,
  `cube_sphere.gd:1086`) — so a card gap [R0, 448) opens the instant the meshes hide.
- To close that gap the zone flip **force-arms an immediate full rebuild**:
  `_rebuild_inputs_changed` returns true on `shell_mode != _last_rebuild_shell`
  (`facet_far_trees.gd:1072`, latch at `:137`), bypassing every calm lever (DELTA, MOVE_HYST,
  WALK_CALM). The zone-B rate cap `FT_SHELL_REBUILD_MS = 500` (`cube_sphere.gd:1257`,
  applied at `facet_far_trees.gd:847-850`) caps *frequency*, *not* the cost of the one rebuild.
- That rebuild is `_rebuild_cards` (`facet_far_trees.gd:1125-1214`): a **main-thread GDScript
  loop** over every cached tree record in ~100+ wanted facets out to `FAR_TREES_CARD_MAX = 2400`,
  up to `FAR_TREES_CARD_INST_MAX = 8192` emitted instances (`cube_sphere.gd:1090`) **plus** all the
  skipped/thinned records, with a `_is_chopped` **Callable into WorldManager per surviving record**
  (`facet_far_trees.gd:1189`) — Callable dispatch is the expensive op in web GDScript (×25).
  This tier's full rebuild was independently measured at ~250 ms live (#119,
  [[voxiverse-forest-fps-root]]); over a village+forest with the chop filter it is plausibly
  350–600 ms. It is the **only** tier whose flip work is synchronous, unstaged and unbudgeted.

Note the asymmetry that fits the data: on **descent** (B→S) the COLORFIX `_stale` latch hides the
tier until a rebuild lands (`facet_far_trees.gd:766-769, 794-796`), and the post-teleport descent
is exactly when `credit_ok` is low (near field streaming), so the credit gate at
`facet_far_trees.gd:842` **defers** the B→S rebuild off the crossing frame. On **ascent** the near
field is resident and idle → credit flows → the forced rebuild lands **on** the crossing frame.

### 1.2 Far-ring floor release: a full-cap dirty set + main-thread dispatch prelude (secondary)

- The upward crossing always re-emits: `shell_fall_should_reemit` returns true unconditionally on
  `floor_changed` (`facet_far_ring.gd:1323-1325`, fed from `:1289`), and the snapshot arms
  `_pending` as **SAFETY** (`_shell_snapshot` → `_arm_pending(src)`, `facet_far_ring.gd:1344-1351`
  — the luxury rail at `:1462-1488` is never used for this arm).
- The new emitted set differs from the resident one *everywhere*: the cap shrinks from the floored
  90° hemisphere to θ_h+23° ≈ 45–57°, so nearly **every populated sector fails the
  `rec.size() != c.size()` test** (`facet_far_ring.gd:2306-2308`) or a member sig flips
  (limb-dense bit 64, `facet_far_ring.gd:2257-2258`, off-surface-only per
  `cube_sphere.gd:472-479`). The whole cap goes dirty in one dispatch.
- The good news (and why descent bounds this class at ≤ 220 ms): those sectors are **class-1
  deferrable** (built in the current epoch, no new members — the 57° cap ⊂ the resident 90° set),
  so `FP_SHELL_STAGE_REEMIT` budgets them (`_stage_filter_dirty`, `facet_far_ring.gd:2329-2418`;
  budgets `cube_sphere.gd:415-417, 451-453`) and the swaps are per-sector
  (`_swap_in_sectors`, `facet_far_ring.gd:2481-2507`).
- The residual cost is the **main-thread dispatch prelude** that runs before any staging:
  `_dispatch_async_rebuild` (`facet_far_ring.gd:2520-2607`) does `visible_fids`, the per-fid
  signature loop of `_sectors_compute_dirty` (`:2292-2321`, ~10 dict ops × ~1700 fids),
  `_refresh_limb_set` (`:2569`), the slot snapshot (`:2525`) — tens of ms on web — **plus** the
  first `_orbit_warm_async` cycle: `want = _pending or not _orbit_emitted_once` (`:2090`) fires the
  emit on the first off-surface frame *regardless* of any calm gate, and `_count_uncached_visible`
  (`:2108-2140`) is a fresh 3456-fid scan.

### 1.3 Why NONE of the deployed shell flags cover the ascent edge

- **FP_SHELL_PREWARM_DESCENT** — the latch `_pwd_tick` requires `_pwd_descending` AND
  `_shell_orbit()` (i.e. already un-floored) AND h ∈ [`SHELL_PWD_ALT_LO`=650, `SHELL_PWD_ALT_HI`=1300]
  (`facet_far_ring.gd:1396-1412`; `cube_sphere.gd:433-434`). Triple-dead at an ascent through 256:
  wrong direction, wrong regime (still floored), wrong altitude band. It pre-warms the *descent
  knee at ~590*, a different boundary entirely.
- **FP_SHELL_CLIMB_NO_CHURN** — suppresses only re-emits where `floored AND
  floored == _emit_floored_last` (`facet_far_ring.gd:1296-1298`; doc `cube_sphere.gd:3305-3316`):
  it calms the climb *below* the boundary and is **explicitly inert at the crossing** (a floor
  change is its carve-out).
- **FP_SHELL_FALL_HOLD** — its own trigger law returns true first thing on `floor_changed`
  (`facet_far_ring.gd:1324-1325`).
- **FP_SHELL_STAGE_REEMIT / SECTOR_FINE** — do engage (that is why descent ≤ 220 ms), but they
  stage only the ring's *worker/swap* side, not the tree tier and not the dispatch prelude.

### 1.4 Ruled out

- **Near-field teardown**: nothing unloads at 256. The approach anchor keeps the viewer's near
  field until 700–900 (`cube_sphere.gd:3056-3057`); the ALT_REGIME latch at 448 *freezes* pool
  management (`world_manager.gd:1559-1562`) — a suspend, with targets held, no shed; the off-surface
  spawn freeze (`world_manager.gd:3662-3666`) is a cheap early-return. On ascent there is nothing
  to re-grow, and `vox_gen` was 0 through this band in prior flights.
- **Far structures**: `wf_st_step_us = 0` on the spike frame; the zone flip at
  `facet_far_structures.gd:543-560` is visibility + the (now-staged) Stage-3 pipeline.
- **Block-LOD orbit tier**: engages at 3000+ (`cube_sphere.gd:2606-2607`) — never in this sweep.
- **Sky**: continuous in-shader altitude crossover; no material swap at 256/384.

### 1.5 One-time first-exposure costs (a possible co-payer — must be discriminated, §3.1)

Two things are drawn/compiled for the **first time in a session** at the first ascent:
`FacetOrbitRelief._mi.visible = true` (`facet_orbit_relief.gd:661-662`) — first draw of its own
ShaderMaterial (WebGL2/ANGLE program link + buffer residency happen at first draw), and the WS1a
un-suspend (`facet_orbit_relief.gd:663-665`) releases any `_commit_dirty` accumulated while frozen.
A GL program link on ANGLE can alone cost hundreds of ms. If the spike is dominated by this class
it recurs **once per session**, not per crossing — a free experiment distinguishes it (§3.1).

---

## 2. Design — make the ascent edge a *visibility flip over resident content*, never a rebuild

Mirror-image of the descent principle that already ships ([[voxiverse-deorbit-shell-reemit]]):
*pre-warm / keep-resident so the regime edge opens nothing in one frame.* Ascent has an extra gift
the descent never had: **the floored 90° hemisphere set is a strict superset of the un-floored
cap for every altitude below ~9900 blocks** (the CLIMB_NO_CHURN bound, `cube_sphere.gd:3306-3308`)
— so on ascent the resident meshes already cover every pixel and the entire conversion is a
*quality* upgrade, deferrable by construction. All flags default **false**, GDScript only, no
engine rebuild; byte-off contract = FLAT `verify_feature` 6042/0.

### S1 — Tier attribution markers (`FP_WF_TIER_ATTR`) — build first

`worst_frame_markers()` (`world_manager.gd:4108-4119` → `facet_far_ring.gd:6245-6270`) has
structure-tier self-time (`st_step_us`) but **no far-tree or ring-prelude self-time** — which is
why the 1111 ms is currently unattributable. Add leaf µs timers (cheap ints, measured

- `wf_ftr_us` — last `_far_trees.step()` wall µs, timed around `facet_far_ring.gd:1526`;
- `wf_or_us` — last `_orbit_relief.step()` µs (`facet_far_ring.gd:1520-1521`);
- `wf_ring_disp_us` — `_dispatch_async_rebuild` prelude µs (`facet_far_ring.gd:2520-2607`);
- `wf_ring_swap_us` — last `_swap_in_sectors`/`_swap_in_arrays` µs (the `_push_event` timing at
  `facet_far_ring.gd:2507` already measures this — surface it in the dict);

into the same `out` dict at `facet_far_ring.gd:6262`. ~½ day, and every later A/B stops guessing.

### S2 — `FP_FT_SHELL_FLIP_CALM` — the tree-tier fix (expected primary win)

Turn the zone S→B flip into a correct-or-nothing **handoff** instead of a forced rebuild:

1. **De-force the flip re-arm.** In `_rebuild_inputs_changed`, under the flag, remove
   `shell_mode != _last_rebuild_shell` (`facet_far_trees.gd:1072`) from the immediate-change set;
   instead latch `_flip_pending = true`. The flip rebuild is then served by the existing paced
   path (`step_cap` at `facet_far_trees.gd:847-850`) on the first step where `credit_ok` (the
   `facet_far_trees.gd:842` gate) — with an `FT_FLIP_MAX_MS` failsafe (≈ 2000) that forces it
   through regardless (a stale band must not persist).
2. **No gap while pending.** In `_apply_visibility` zone B (`facet_far_trees.gd:780-785`), keep the
   rung-1 mesh MultiMeshes **visible while `_flip_pending`** — hide them only after the first
   zone-B card buffer commits (`_rebuild_cards(..., shell_mode=true)` completion clears
   `_flip_pending`). At h ∈ (256, ~600) the 3D trees are still valid geometry (they were being
   drawn one frame earlier); this is exactly the `FT_SHELL_SWAP_DWELL` idea
   (`cube_sphere.gd:1258`) promoted from "2 blind steps" to "until the replacement is resident".
   Mirror the same latch on descent B→S (meshes stay hidden, cards stay up, until the S rebuild
   lands — the COLORFIX `_stale` latch at `facet_far_trees.gd:766-769` already does this half).
3. **(P2, optional, biggest structural win)** Budget-slice `_rebuild_cards`: cursor over (facet,
   record) with an ~2 ms/frame budget, write into a scratch buffer, one `set_buffer`
   (`facet_far_trees.gd:1208`) on completion (double-buffer — the old buffer keeps drawing).
   This bounds *every* card rebuild (walk churn near villages too — composes with
   [[voxiverse-ground-walk-perf]]), not just the flip. Do it only after S1 confirms `wf_ftr_us`
   dominates.

### S3 — `FP_SHELL_ASCENT_LAZY` — the ring-side fix (mirror of the descent pre-warm, ascent-shaped)

Because the resident floored set is a superset (§2 preamble), the upward floor release does not
need a SAFETY re-emit at all:

1. In `shell_set_camera_abs`, when the re-emit trigger fired **solely** because of
   `floor_changed` with the new `floored == false` (the ascent release — `facet_far_ring.gd:1289`,
   `:1323-1325`): still commit the snapshot (`_shell_snapshot`, `:1344-1351` — the axis/cap/regime
   must advance so `_shell_orbit()`/`shell_offsurface()` read correctly), but arm via the existing
   **luxury rail** instead of SAFETY — add a `luxury := false` param to `_shell_snapshot` threaded
   into `_arm_pending(src, luxury)` (`facet_far_ring.gd:1462-1488`). The deployed
   `FP_APPLIED_PROBE_CALM` coalescer then promotes it when the stream is healthy + settled; add a
   `SHELL_ASCENT_LAZY_MAX_MS` (≈ 4000) forced promote so the conversion (limb-dense, orbit env,
   cap trim) always lands.
2. Set `_orbit_emitted_once = true` at that same latch, so `_orbit_warm_async`'s
   `want = _pending or not _orbit_emitted_once` (`facet_far_ring.gd:2090`) does not force the
   emit on the first off-surface frame; its `remaining > 0` env-warm dispatches stay as-is
   (bounded worker batches — the deployed descent behavior).
3. The **descent** floor edge (new `floored == true`) is untouched: that direction is a genuine
   growth (90° ⊅ resident 57°) and must stay SAFETY, exactly as shipped.

Composition: disjoint by predicate from `FP_SHELL_PREWARM_DESCENT` (descending + un-floored +
[650,1300] vs. the ascent floored→un-floored edge at 256); the eventual promote flows through the
same `FP_SHELL_STAGE_REEMIT`/`SECTOR_FINE` staged pipeline; `FP_SHELL_CLIMB_NO_CHURN` still owns
the below-floor climb. Requires `FP_APPLIED_PROBE_CALM` (deployed ON) — with it off, fall back to
the shipped SAFETY arm (byte-identical).

NEVER-OOM: S3 temporarily keeps the *larger* already-resident mesh — zero growth; the promote
shrinks it.

### S4 — `FP_OFFSURF_MAT_PREWARM` — prepay first-exposure GL cost (only if §3.1 says one-time class)

During the existing boot-splash prewarm stage (the branded splash already reports real
bake/prewarm progress — the integration point exists), render one frame of each
off-surface-only material — `FacetOrbitRelief`'s ShaderMaterial (`facet_orbit_relief.gd:661`)
foremost — on a 1-triangle mesh parented behind the camera (or a 2×2 SubViewport), forcing ANGLE
program link before gameplay. ~½–1 day.

### S5 — (hygiene, optional) regime-edge spreading

`set_alt` teleports cross 256/384/448 in one frame; the sweep therefore stacks three edges the
live climb spreads out. Either process at most one regime edge per frame in
`WorldManager.update_streaming` (tiny edge queue), or simply record it as a measurement caveat:
A/B flights should include a *slow* climb arm, not only teleports.

---

## 3. Verification + live A/B

### 3.1 The free discriminator (run before building anything past S1)

Same session, run the crossing **twice**: `set_alt 7→500 → 7 → (settle 10 s) → 500`.
- 2nd ascent ≈ as cheap as descent (≤ ~250 ms) ⇒ a large first-exposure component (§1.5) → S4
  moves up the order.
- 2nd ascent still ≈ 1 s ⇒ pure recurrent rebuild class → S2+S3 carry the whole fix.

### 3.2 Headless gates (byte-off contract)

- FLAT `verify_feature` **6042/0** with all new flags off (they gate every new branch).
- `verify_shell.gd` + **G-SHELL-ASCENT-LAZY**: drive `shell_set_camera_abs` floored true→false
  (the gate-forcing param convention, e.g. `facet_far_ring.gd:1257`); assert flag-on: no SAFETY
  `_pending` on the edge, snapshot committed (`_emit_floored_last` false), luxury promoted under
  the failsafe clock; flag-off: `_pending` set immediately (shipped law verbatim).
- `verify_fartree_*` + **G-FT-FLIP-CALM**: drive `step()` through a synthetic S→B flip; assert
  flag-on: no `_dbg_rebuild_count` bump on the flip step, mesh rung still visible, first zone-B
  rebuild lands ≤ failsafe and then hides the rung; flag-off: rebuild on the flip step (shipped).

### 3.3 Live markers at the crossing (bare-URL + counters, per [[voxiverse-near-radius-diet]])

Watch across the 256 crossing, both arms: `worst_ms` for the 7→500 step (target: into the
descent's 96–220 band); `wf_ftr_us` / `wf_ring_disp_us` / `wf_ring_swap_us` (S1) on the worst
frame; `ftr_rb` delta on the crossing frame (S2 on: 0 at the flip, +1 within the failsafe);
`sh_reemit`/`sh_emit` delta (S3 on: no re-emit burst at the flip; staged conversion within
`SHELL_ASCENT_LAZY_MAX_MS`); `sh_off`/`sh_dwell` (`facet_far_ring.gd:3852-3853`) to timestamp the
regime edge; `vox_gen` (must stay 0 — proves the near field is untouched, §1.4).

---

## 4. Build order + effort

| stage | what | effort | risk |
|---|---|---|---|
| S1 | tier attribution markers | ~½ d | none (leaf ints) |
| §3.1 | repeat-crossing discriminator flight | ~0 | none |
| S3 | `FP_SHELL_ASCENT_LAZY` (ring, luxury-arm the ascent release) | ~1 d | low — superset argument + failsafe |
| S2 (1+2) | `FP_FT_SHELL_FLIP_CALM` (de-force flip rebuild + handoff visibility) | ~1–1.5 d | low-med — handoff latch on both directions |
| S4 | off-surface material prewarm at splash | ~½–1 d | low — only if discriminator says so |
| S2 (3) | budget-sliced card rebuild | ~2 d | med — do after S1 confirms `wf_ftr_us` dominates |

Deploy path: byte-off source, flags ON via the `deploy_cheats.sh` sed / `CLITE_FLAGS` per arm
([[voxiverse-deploy-cheats-pipeline]]); A/B arms = {baseline}, {S3}, {S3+S2}, each swept
7→500→7→500 plus one slow-climb arm (S5 caveat).
