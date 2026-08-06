# COSMOS — Near↔Far Height Step at the Near-Stream Bubble Edge: Root Cause + Arbitration Design

Status: DESIGN (no code). Author: Fable (architecture). 2026-08-06.
Scope: the live-observed defect at the far-render-v1 milestone — a visible HEIGHT STEP where
the near blocky VoxelTerrain ends and the far tier begins (~at the near-stream bubble edge):
the far tier renders the same facet's surface at a different (lower) altitude than the near
blocks, so the ground drops a ledge right where near hands off to far.

All file:line references are against this worktree
(`/home/vrogojin/voxiverse/.claude/worktrees/deploy-cheats`, branch `deploy/cheats-eyeball`).
Live flag context = the CS_FLAGS set documented in `docs/COSMOS-PALE-BACKSTOP-FIX-DESIGN.md`
(§ preamble, :13-20) **plus** the far-render-v1 additions now deployed:
`FP_SMOOTH_V2`/`FP_SMOOTH_V2_REACH`, `FP_FARRING_UNCOVERED_TRUE`, `FP_VIEWER_RELIEF_REACH`,
`FP_FAR_COLOR_UNIFIED`. Load-bearing OFF (unchanged from that list): `FP_FARRING_CULL_COVERED`
+ `FP_FARRING_LEVEL` (the U2/U3 cull-not-sink pair), `FP_SMOOTH_RIM`/`FP_FAR_SMOOTH` (the old
ladder — **therefore `FP_RIM_NEAR_WELD` is code-present but INERT live**: the S2 collar that
would weld far to the near block-top is never built), `FP_BLOCK_LOD`, `FP_TIER_DEPTH_BIAS`.

---

## 1. ROOT CAUSE, precisely

**The step is the far ring's dense backstop of the ACTIVE facet drawn in its "covered"
regime — envelope-minimum heights minus the ε sink — inside an annulus where no near mesh
actually exists. The deployed per-vertex un-sink (`FP_FARRING_UNCOVERED_TRUE`) restores TRUE
height only OUTSIDE the *streamed-target* ellipsoid inflated by a safety margin; but the
*rendered* near mesh never reaches that boundary. The gap between "what the coverage law
claims the near field covers" and "what the near field actually meshes" renders as a
permanently depressed ring around the near bubble — a down-step at the near-mesh edge and an
up-step at the un-sink boundary.**

### 1.1 The three radii (the geometry of the defect)

At R = 6371, K = 24: facet edge ≈ 417 blocks, dense backstop cell = 417/16 ≈ 26.1 blocks
(`BACKSTOP_CELLS := 16`, `cube_sphere.gd:300`).

| radius (blocks from player column) | what it is | where decided |
|---|---|---|
| **~112** | outer edge of the *actually meshed* near surface. Data streams to 128, but godot_voxel emits no faces against unloaded neighbours, so the meshed surface stops ~1 mesh block short; the codebase itself treats ≥96–112 as the honest meshed bound (`NEAR_COVER_MESHED_HALF = 96` "one laggard outer mesh block", `INNER_HOLE_CURVED = 112` note, `module_world.gd:116-131`; prefill targets 112). | godot_voxel mesher |
| **128** | the streamed-DATA target: `TerrainConfig.near_render_radius()` (`terrain_config.gd:171-176`, `CURVED_RENDER_RADIUS_BLOCKS := 128` :153) — the horizontal semi-axis of the viewer ellipsoid `streamed_ellipsoid_params()` returns (`terrain_config.gd:258-263`). | streaming target |
| **152** | the un-sink boundary: the same ellipsoid inflated by `UNSINK_MARGIN_BLOCKS := 24` (`cube_sphere.gd:1358`) inside the deployed coverage test `_uncovered()` (`facet_far_ring.gd:3091-3105`). | `FP_FARRING_UNCOVERED_TRUE` |

So the **annulus [~112 .. 152]** — 40 blocks wide, immediately abutting the visible near-mesh
edge — is classified "covered" by the un-sink law and therefore keeps the covered-branch
height, while nothing near ever draws there. (Vertically the same applies below/above the
±128 relief-reach band, `VIEWER_RELIEF_REACH_BLOCKS := 128`, `cube_sphere.gd:1222`,
`terrain_config.gd:239-243` — but with FP_VIEWER_RELIEF_REACH live the vertical cut is mostly
solved; the user's residual observation is the *horizontal* frontier.)

### 1.2 What the covered branch renders there (the height law that loses)

The emit's sunk branch (`_emit_cached`, `facet_far_ring.gd:3711-3744`; fast path
`_append_backstop_tris` :3523-3538) draws `_bpos_cache` positions through
`_sunk_positions` (:3491-3500):

- Under live `FP_ENV_ALL` the vertex heights are the **min-envelope**: minimum terrain g over
  a ~65-block dilated footprint (per `COSMOS-PALE-BACKSTOP-FIX-DESIGN.md` §1.2) — 0 loss on
  flat ground, tens of blocks low on relief.
- Minus the ε sink `TierPlace.backstop_sink()` (`tier_place.gd:108-115`):
  `max(1.5, 0.45·26.1) ≈ 11.7` blocks under env_all; a not-yet-enveloped chord takes the full
  `0.5·26.1 ≈ 13.0` (`backstop_sink_chord`, :178-180).
- `FP_BLOCKY_FARRING` then draws each 26-block cell flat at the MIN of its 4 corners —
  another downward quantization on any slope.

**Net: even on flat grassland the ground beyond the near-mesh edge sits ≈ 12 blocks below
the near block tops; on relief, 12–40+.** That ledge, running along the bubble edge and
tracking the player, is the observed step. At r > 152 the surface *pops back up* to the TRUE
welded chord (`_blend_uncovered` :3107-3124 taking `_btrue_cache` heights :3067-3079) — the
second, outward step.

### 1.3 Verdict on the brief's four candidates

- **(a) far = min-envelope + sink, not true block-top — CONFIRMED PRIMARY**, but only in the
  covered branch; the deployed un-sink already fixed the far field (zone beyond 152). The
  defect is that the covered branch's *territory* is wrong, not its law.
- **(b) coarse quantization (26-block cells, corner-MIN)** — real but secondary: it shapes the
  step (blocky terraces) and adds a few blocks on slopes; it does not create the ~12-block
  offset.
- **(c) FP_RIM_NEAR_WELD covers only the S2 collar** — moot in this deploy: the whole old
  ladder (`FP_SMOOTH_RIM`/`FP_FAR_SMOOTH`) is OFF, so NO weld exists anywhere on the boundary.
  The boundary is naked backstop.
- **(d) smooth-profile vs blocky g** — negligible: far chord nodes place at
  `_weld_place(d, g)` with integer `g = int(prof.x)` (`facet_far_ring.gd:4014-4024`), the
  same One-Surface altitude law the datum-shifted near field uses; residual ≤ ~1 block at
  nodes (chord interpolation between 26-block nodes adds the sagitta class, bounded ~13 on
  mountain concavities — that is the accepted-protrusion class, §2.3).

FP_SMOOTH_V2 is NOT involved: its annulus is hops 2..4 (`V2_HOP_B := 2`,
`cube_sphere.gd:1184-1185`) — ≥ ~400 blocks out; its tiles are block-top-exact with no sink
(`facet_smooth_v2.gd:59-125`) and never touch the bubble edge.

---

## 2. The user's proposal, evaluated

> "Render NEAR and FAR at the same altitude. When we've baked ALL the near blocky terrain for
> a facet, turn OFF its far rendering; once we start removing chunks, re-enable it. Interim
> far protrusion through near terrain is acceptable (far texel colours ≈ block textures)."

### 2.1 "Same altitude" — ADOPT as the core principle

This is the correct height contract for everywhere the far tier is *visible*: the deployed
un-sink already implements it beyond 152. The fix is to extend it inward to the true
near-mesh edge (§3). The sink/envelope machinery remains correct — but only *under* real
near mesh, where it is invisible by design.

### 2.2 Per-FACET granularity — REJECT (it never fires)

The near bubble covers π·128²/417² ≈ **30 % of the active facet's area at full settle** (and
0 % of every other facet). "ALL the near terrain of a facet is baked" is unsatisfiable —
a strict per-facet far-off would never trigger, and the step would remain untouched. The
per-facet residency arbitration precedent (`FP_SMOOTH_V2_EXCL_BLKLOD`) works for
facet-sized tiers (V2 vs block-LOD rings); it cannot express a player-centred 128-block disc.

The right granularity is **neither per-facet nor per-cell: it is ONE SCALAR per player** —
the radius to which the near mesh is actually applied. Coverage here is a player-centred
disc *by construction* (the viewer ellipsoid is the only thing that streams near data), so a
single probed radius captures it exactly; per-cell probing (U2's 256 cells × ~16 fids) buys
no extra expressiveness for this boundary and re-imports the churn cost that shelved it.

### 2.3 The protrusion tolerance is the load-bearing simplification

U2's per-cell cull was shelved (pale-backstop §1.2/§3.5) because `is_area_meshed` probing
races streaming arrivals: a stale "not meshed" answer leaves far geometry at/above the near
surface — a *transient protrusion window* — so it needed confirm-streaks, dilation, reap
cadence and a flush safety path (`is_cell_culled` streak law `facet_far_ring.gd:2282-2296`,
`_cull_committed_unsafe` :2311-2318, `CULL_CONFIRM/CULL_DILATE/CULL_REAP_MS`
`cube_sphere.gd:1284-1287`). The user's directive **dissolves that objection**: if far
geometry at true height transiently coexisting with near blocks is acceptable, then *both*
states of any coverage flip are valid ground — a wrong "covered" shows today's look for one
probe cadence, a wrong "uncovered" shows equal-altitude far under near for one cadence. No
hole, no black, no unbounded error. Hysteresis shrinks from a correctness requirement to a
cosmetic anti-flicker dwell.

Corollary: we do **not** need the U2 cull (not emitting covered cells) to fix the step at
all. Culling removes *hidden* geometry (an overdraw optimization); the visible trench is
*un-hidden* geometry at the wrong height. The minimal fix is a **height-law territory fix**,
not a cull. U2/U3 stay OFF and orthogonal.

---

## 3. RECOMMENDED FIX — `FP_FARRING_APPLIED_COVER`: the covered branch tracks the APPLIED near extent

New `const FP_FARRING_APPLIED_COVER := false` in `godot/src/cosmos/cube_sphere.gd`
(byte-identical off; FLAT `verify_feature` 6042/0). Effective only with
`FP_FARRING_UNCOVERED_TRUE` (gate: `applied_cover_on() := FP_FARRING_APPLIED_COVER and
FP_FARRING_UNCOVERED_TRUE` — it *refines* the deployed law, never replaces it).

### 3.1 The three-zone height law (replaces the deployed two-zone blend)

Per dense-backstop vertex, in `_blend_uncovered` (`facet_far_ring.gd:3107-3124`), using its
TRUE chord point `t`:

| zone | test | emitted height | change vs deploy |
|---|---|---|---|
| **A — provably unreachable** | outside the *streamed* ellipsoid + 24 (the deployed `_uncovered` test, :3091-3105) | TRUE chord (`_btrue_cache`) | **unchanged** (byte-preserved; pale-backstop gates stay green) |
| **C — actually meshed** | inside the *applied* ellipsoid: same centre/axes law, horizontal semi-axis = probed `r_applied` (§3.2), vertical = the streamed H | covered law verbatim (`_sunk_positions(_bpos_cache…)` envelope + ε) | **unchanged law, shrunk territory** — now always hidden under real mesh |
| **B — claimed-but-unmeshed gap** (the trench annulus) | inside A's boundary, outside C's | TRUE chord − `ENV_EPS_G` (1.5 blocks, `tier_place.gd:17`) | **NEW**: equal-altitude far, with a sub-2-block z-guard so a mesh block that lands during the probe-staleness window never coplanar-fights it |

Zone B is where the step lived; at true−1.5 the ledge collapses from ~12 blocks to ≲2 (plus
the honest chord/coarseness residual, §3.6). The ε here deliberately reuses the smallest
existing guard, NOT `backstop_sink_level()` (≈5.2 at R=6371) — 5 blocks is still a visible
curb, and the z-fight risk it guards is transient-only under the tolerance (§2.3).
`FP_BLOCKY_FARRING`'s corner-MIN keeps mixed frontier cells conservative for free.

### 3.2 The coverage signal: a probed scalar `r_applied` (main-thread live + frozen-for-worker)

- **Probe**: on MAIN, on the existing paced cadence next to `_noblack_guarantee`'s call site
  (`_process`, `facet_far_ring.gd:1271-1278`), walk a quantized ladder
  `r ∈ {112, 96, 80, 64, 48}` (16-block steps = mesh-block size): `r_applied` = largest r
  whose square box (half-extent r, centred on the player column, vertical half-extent = the
  streamed H) passes the existing cover query — `_cull_cover_query` →
  `module_world.skin_near_meshed` → `VoxelTerrain.is_area_meshed`
  (`module_world.gd:2362-2370`), mapped into the active facet's lattice exactly as
  `_noblack_near_meshed` already does (`facet_far_ring.gd:1487-1500`). A box that passes
  proves every mesh block inside is applied ⇒ zone C ⊆ real mesh ⇒ the sunk region is
  genuinely hidden. Invalid query (GDScript/no-module path) ⇒ `r_applied = 0` ⇒ zone B
  everywhere inside the ellipsoid — degraded but correct (equal-altitude far; strictly
  better than today's trench).
- **Cost**: ≤ 2 `is_area_meshed` calls per cadence tick (test current step ± one). Compare
  U2: up to 256 probes/facet. This is the churn-avoidance in one line: *scalar, quantized,
  ladder-stepped*.
- **Hysteresis/dwell**: `r_applied` moves at most ONE 16-block step per cadence tick
  (natural dwell), grows only on a passing probe, and **shrinks instantly** on a failing one
  (mirror of U2's asymmetric instant-un-cull, :2282-2296) — a retreating near mesh converts
  its cells to zone B (equal-altitude, acceptable) within one cadence + one rebuild.
- **Freeze contract**: snapshot `_async_applied_r` in `_dispatch_async_rebuild` alongside
  `_async_unsink_col` (:1692-1697); the worker's `_emit_cached(from_worker=true)` reads only
  the frozen pair. The synchronous fast path (`_append_backstop_tris`, main-thread only per
  its own doc :3530-3534) reads the live scalar — same live/frozen split the deployed
  un-sink already uses.

### 3.3 Re-emit triggers (bounded churn)

- Existing: player-column drift ≥ `UNSINK_DRIFT_BLOCKS = 16` re-arms `_pending`
  (`_unsink_drift_check` :1507-1513) — unchanged, already paid for.
- New: `_pending = true` when the quantized `r_applied` step CHANGES. Bounded: a full cold
  stream-in crosses ≤ 5 steps (≤ 5 extra rebuilds, one-time); at settle it is constant; a
  crossing/teleport re-walks the ladder (≤ 5 again). All re-emits ride the existing
  single-flight async rebuild pipeline — no new RenderingServer usage, swap path untouched.

### 3.4 Files / functions to touch

- `godot/src/cosmos/cube_sphere.gd` — `FP_FARRING_APPLIED_COVER := false`,
  `APPLIED_PROBE_STEP := 16`, `APPLIED_PROBE_MAX := 112`.
- `godot/src/world/facet_far_ring.gd`
  - `_applied_r` (live) + `_async_applied_r` (frozen at :1692-1697); ladder probe helper
    beside `_noblack_near_meshed` (:1487-1500 pattern); cadence call beside :1278.
  - `_blend_uncovered` (:3107-3124): add the zone-B branch (second params: applied semi-axes
    + the frozen/live scalar selected by the caller, mirroring `pcol/have_pcol` at
    :3738-3740); `_uncovered` (:3091-3105) gains a params-only twin for the applied
    ellipsoid — both stay pure/worker-safe.
  - re-arm on step change beside `_unsink_drift_check` (:1507-1513).
- `godot/src/world/tier_place.gd` — nothing (ε reuses `ENV_EPS_G`); optionally a
  `applied_cover_on()` accessor for gate symmetry.
- `godot/src/world/world_manager.gd` — nothing new: cover query (:1117-1129) and player
  column (:1134-1137) are already wired under the deployed flags.

### 3.5 Composition with deployed machinery (explicit)

- **FP_FARRING_UNCOVERED_TRUE**: prerequisite; zone A is its law byte-preserved (G-PB-TRUE /
  G-PB-COVERED / G-PB-HOVER remain green — the hover case has `r_applied = 0`, all-B/A, true
  height everywhere, same visual as today).
- **FP_RIM_NEAR_WELD / FP_SMOOTH_RIM** (code present, OFF live): if the ladder is ever
  re-enabled, an S2-committed facet leaves the backstop emit entirely (law-6 exclusion via
  `_rim_interim_sink_eligible`, :3505-3508) so this law simply stops applying there; in the
  pre-commit window `_sunk_positions`' R-D ε-sink (:3498-3499) and zone B agree within
  ~3.7 blocks. Composes, no conflict.
- **U2/U3 (`FP_FARRING_CULL_COVERED`/`FP_FARRING_LEVEL`)**: stay OFF; no shared state. If U2
  is ever revived (overdraw), it would cull zone-C cells — hidden anyway; U3's level-sink
  applies to zone C only. Composes.
- **FP_BLOCKY_FARRING / FP_ENV_ALL / envelope caches**: untouched — zone C reads them
  verbatim; zones A/B read `_btrue_cache`, which the deployed flag already builds and reaps
  with the backstop role (:3067-3079, :2537).
- **FP_SMOOTH_V2(_REACH)**: disjoint by construction (hops 2..4).

### 3.6 Honest residual (what this does NOT fix)

The frontier far field stays 26-block-coarse, band-flat-coloured, chord-interpolated
(local error up to the ~13-block sagitta on mountain concavities — visible as far ground
clipping *into* near blocks occasionally: the accepted-protrusion class, per directive).
It will read as "distant-style terrain at the correct altitude", not as more voxels.
Follow-ups if the residual matters: (i) densify the ACTIVE facet's backstop
(`BACKSTOP_CELLS` 16→32 for hop-0 only, 4× verts of one facet, ~13 KB); (ii) extend V2 to
hops 0–1 with this same three-zone law applied per-tile-vertex (8-block cells at the
frontier — the best-fidelity endgame, but V2 tiles are static per-facet and would need
drift-rebuilds; a separate design).

---

## 4. Gates — `godot/src/tools/verify_near_far_height.gd` (flags forced via function params, no sed)

- **G-NFH-STEP** (the defect pin, falsifiable): relief fixture + pinned column; drive
  `_blend_uncovered` with forced (streamed, applied) params, `r_applied = 96`. Assert every
  vertex in the annulus (96 .. 152] sits within [true − ENV_EPS_G − 1.0, true]. **Falsify**:
  flag off ⇒ the same vertices sit ≥ 0.8·ε_env (≈9+) blocks low (more on relief — envelope
  minima).
- **G-NFH-COVERED**: vertices inside the applied ellipsoid byte-identical (array compare) to
  the flag-off covered branch.
- **G-NFH-OUTER**: vertices outside the inflated streamed ellipsoid byte-identical to the
  deployed FP_FARRING_UNCOVERED_TRUE emit (zone A preservation).
- **G-NFH-PROBE**: ladder law — grows ≤ 1 step/tick, shrinks instantly on a failing probe;
  invalid query ⇒ r_applied = 0 (zone B inside, never a sunk trench).
- **G-NFH-CHURN**: scripted stream-in (probe ladder 48→112) + 256-block walk ⇒ rebuild count
  ≤ ladder_steps + walk/16 + role events (the bounded-re-emit proof, `_cull_reemit_count`
  discipline).
- **G-NFH-OFF**: flag off ⇒ emitted arrays byte-identical to shipped golden; full FLAT
  `verify_feature` 6042/0.

## 5. NEVER-OOM ledger

| Item | Bound | Bytes |
|---|---|---|
| `_applied_r` + frozen copy + ladder state | scalars | ~24 B |
| height caches | reuses `_btrue_cache`/`_bpos_cache`/`_bcol_cache` — zero new arrays | 0 |
| probes | read-only `is_area_meshed` queries, ≤ 2/cadence tick | 0 resident |
| re-emits | ladder-step + drift bounded, single-flight pipeline | 0 resident |

Total: **~24 B resident, zero per-frame allocation, no growth with walk distance.**
