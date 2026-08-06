# COSMOS — Pale Backstop on Steep Peaks / Near-Nadir: Root Cause + Minimal Fix Design

Status: DESIGN (no code). Author: Fable (architecture). 2026-08-05.
Scope: the live-observed, A/B-proven pre-existing defect — standing on a steep ~100-block
mountain peak (or hovering and looking straight down), the immediate down-slope foreground /
near-nadir renders as a flat PALE region (snow-white in a −3 °C region) with a gray
"alpha-hash-looking" band at its inner edge, instead of real surface. Proven independent of
FP_SMOOTH_V2 (identical with v2res=0): the region is hop 0–1, where V2 has no geometry.
Related standing task: #72 "far-terrain rendered too low below near blocks" / #86.

All file:line references are against this worktree
(`/home/vrogojin/voxiverse/.claude/worktrees/deploy-cheats`, branch `deploy/cheats-eyeball`).
"Live flags" = the CS_FLAGS list in the current `deploy_cheats.sh` (scratchpad), the set the
observed build was exported with. Load-bearing ON: `FP_FARRING_FULL_COVER`, `FP_ENV_ALL`,
`FP_SHELL_WELD` (⇒ `TierPlace.env_all_on()` true), `FP_TIER_ENVELOPE`,
`FP_TIER_STICKY_BACKSTOP`, `FP_BLOCKY_FARRING`, `FP_FARRING_ACTIVE_NOBLACK`,
`FP_ENV_FLOORED_ASYNC`, `FP_BAND_BLOCK_MAP` + `FP_SKIN_FLATCOLOR`/`FP_SKIN_BLOCK_EXACT`,
`FP_NO_NEAR_LOD`. Load-bearing OFF: `FP_FARRING_CULL_COVERED`, `FP_FARRING_LEVEL` (the U2/U3
cull-not-sink pair), `FP_SMOOTH_RIM`/`FP_FAR_SMOOTH` (old ladder), `FP_BAND_SHOT`,
`FP_BLOCK_LOD` (P0 rings not in this deploy), `FP_TIER_DEPTH_BIAS`.

---

## 1. ROOT CAUSE, precisely

**The pale foreground is the far ring's DENSE BACKSTOP of the ACTIVE facet (and, across a
facet border, of the live-pool ring-1 neighbours), drawn SUNK below the true surface, at
26-block cell resolution, in the flat freeze-line palette colour — visible because the near
voxel field does not reach the down-slope: the near-stream ellipsoid is cut 40 blocks below
the player's feet.** Two independent laws collide on steep relief:

### 1.1 The near field is vertically guillotined, not just horizontally bounded

- `TerrainConfig.near_render_radius()` returns **128** on the faceted planet
  (`godot/src/world/terrain_config.gd:171-176`, `CURVED_RENDER_RADIUS_BLOCKS := 128` at :153).
- The one global `VoxelViewer` streams a *vertically clamped* ellipsoid
  (`module_world.gd:2882-2905` `attach_viewer`): `VIEWER_VERTICAL_RATIO := 0.5`
  (`terrain_config.gd:190`) gives U = 128·0.5 = **64 blocks up**, and the A2 downward-reach
  clamp (`DOWNWARD_REACH_CLAMP_ENABLED := true`, `VIEWER_DOWNWARD_REACH_BLOCKS := 40`,
  `terrain_config.gd:203-236`) trims the DOWN side to **40 blocks below the player** (viewer
  offset O = (U−D)/2 = +12, half-height H = (U+D)/2 = 52, ratio 52/128 ≈ 0.406).
- On a ~100-block peak with mountain-grade slope (MOUNTAIN_AMPLITUDE 92; local slope commonly
  0.4–1.0 block/block), the down-slope surface falls out of the streamed band **~40–100
  blocks of horizontal distance from the player** — far inside the 128-block horizontal
  radius. Columns whose surface is >40 blocks below the feet are never streamed, never
  meshed. The A2 comment itself says why this is *analytically* safe (collision reads
  TerrainConfig, `terrain_config.gd:192-203`) — but *visually* nothing near draws there.
  godot_voxel emits no faces against unloaded blocks, so from the peak you look straight
  past the meshed rim into whatever draws behind it.

### 1.2 What draws behind it is the sunk dense backstop of the active facet

- Under `FP_FARRING_FULL_COVER`, hop-0/1 facets (active ∪ live-pool `_excluded` ∪ sticky) are
  "backstop" facets — `_is_backstop`, `facet_far_ring.gd:2018-2025` — emitted from the DENSE
  `_bpos_cache` at `BACKSTOP_CELLS := 16` (`cube_sphere.gd:300`) and pushed radially inward at
  emit: `_emit_cached` sunk branch `facet_far_ring.gd:3584-3604`, `_sunk_positions`
  :3375-3384, sink value from `TierPlace.backstop_sink()` (`tier_place.gd:108-115`).
- Numbers at R = 6371, K = 24: facet edge = (π/2·6371)/24 ≈ **417 blocks**, dense cell =
  417/16 ≈ **26.1 blocks**. Live (`env_all_on()`) the sink is the global-envelope ε guard
  `max(1.5, 0.45·26.1) ≈ 11.7 blocks`; a not-yet-enveloped chord uses the full
  `0.5·26.1 ≈ 13.0` (`backstop_sink_chord`, `tier_place.gd:178-180`;
  `_emit_cached`'s `_benv_done` branch :3597-3598).
- The sink is only half the depression. Under `FP_ENV_ALL` the dense vertex HEIGHTS are the
  **min-envelope**: each vertex = MINIMUM terrain g over its dilated footprint sampled at
  ENV_FINE_MULT×dense resolution (`_ensure_backstop_cached_env`, `facet_far_ring.gd:3071-3135`;
  weld twin `_ensure_backstop_cached_env_weld` :3140+). Footprint half-width = (mult + dil)
  fine samples ≈ ±33 blocks ⇒ each vertex is the min over a ~65-block window. And
  `FP_BLOCKY_FARRING` then draws each cell as a flat top at the MIN of its 4 corners
  (`_emit_blocky`, :3467+; doc comment :3456-3460) ⇒ the visible top = **min of true surface
  over a ~90-block window, minus ~11.7**. On a mountainside that is **30–90 blocks below the
  local surface** — the "pale rectangle hiding the surface / being inside a mountain" read is
  the correct perception of a plane genuinely that far down.
- Why doesn't the never-black un-sink save the peak case? `FP_FARRING_ACTIVE_NOBLACK` un-sinks
  the active facet **whole-facet, keyed on ONE probe under the camera**
  (`_noblack_guarantee` :1414-1450 → `_noblack_near_meshed` :1458-1471, probe half-extents
  `NOBLACK_PROBE_HALF := 10`, `cube_sphere.gd:1303`). **Grounded on the peak the near field IS
  meshed under the camera**, so `_noblack_unsink_fid = -1` and the active facet's own
  down-slope backstop stays sunk. The granularity of the un-sink decision (per-facet,
  camera-column probe) is the design gap; the need is per-cell/per-vertex.
- The per-cell cull that WOULD remove covered cells and collapse the sink
  (U2 `FP_FARRING_CULL_COVERED` + U3 `FP_FARRING_LEVEL`, `is_cell_culled` :2253,
  `_level_on` :2217, `backstop_sink_level` `tier_place.gd:131-133`) is **OFF in this deploy**,
  so the full dense grid emits, sunk, everywhere — including right at the near-mesh frontier.

### 1.3 The two viewing cases

- **Grounded on a peak**: near mesh covers a ~40-block-deep collar around the summit; beyond
  it (still well inside 128 horizontal) the visible ground is the active facet's own dense
  backstop: SUNK (ε ≈ 11.7 + envelope-min), coarse (26-block flat blocky cells), pale. If the
  down-slope crosses a facet border, the neighbour is a pool/sticky backstop — same law, same
  look (sunk; `FP_FARRING_ACTIVE_NOBLACK` is single-facet by construction,
  `_noblack_unsink_fid` :51).
- **Hovering, looking straight down (below the shell-orbit regime)**: the streamed ellipsoid
  rides the player at altitude, so no near mesh exists at the ground at all. The under-camera
  probe then usually reads uncovered ⇒ the ACTIVE facet un-sinks (true surface — the shipped
  noblack behaviour, `_emit_cached` :3592-3593) but stays 26-block-coarse and pale, while
  every neighbouring backstop facet in view stays SUNK ⇒ a pale plate with visible height
  steps at facet borders. (High enough, `_shell_orbit()` :1491-1492 turns backstop roles off
  entirely — the orbit view is a different, already-fixed regime.)

### 1.4 Why the colour is pale

- Dense backstop vertex colour is the vertex's own direct biome sample:
  `FarPalette.color_for(g, biome, t, …)` (`_ensure_backstop_cached*`,
  `facet_far_ring.gd:3057, :3131-3133`), and `color_for` **whitens above the freeze line**
  (`far_palette.gd:288-296` — "a dry-land vertex above the freeze line whitens (the altitude
  snow line)"). At −3 °C on a peak the entire backstop is `_snow` — flat white.
- The texture path does not rescue it: `FP_BAND_SHOT` (the RG8 shot with the baked
  hillshade/AO byte `_rg.g`, :4129-4153) is OFF in this deploy; the live
  `FP_SKIN_FLATCOLOR`/`FP_BAND_BLOCK_MAP` band branch renders per-block FLAT palette colours
  (`_FLAT_UNIFORMS`/far_lut, :4182-4190) — on a frozen peak, mostly snow-white texels.
  Lighting is the shell-absolute law with the **planet-radial** normal
  (`_SHELL_ABS_TEX_LIGHT` vertex(), :3977-3989) — no slope/hillshade term — so the whole
  region shades uniformly: a featureless pale wash, in hard contrast with the relief-lit,
  block-textured near voxels ending in a raw mesh rim right in front of it.

### 1.5 What the gray "alpha-hash dither" band actually is

**Confirmed negative** (the brief's prime suspect): it is NOT a near-terrain LOD/transition
fade. The near path is a plain `VoxelTerrain` + `VoxelMesherBlocky` (`module_world.gd:365,
:324-325`) — not `VoxelLodTerrain`, no lod fade property; `FP_NO_NEAR_LOD` additionally keeps
the GDScript LOD mesher from ever being created (`module_world.gd:1871-1882`). No material in
`godot/src` uses `distance_fade`, `ALPHA_HASH`, or a screen-door discard on any live path
(the only screen-door shader in the tree is `facet_block_lod_ring.gd:688-734`, and
`FP_BLOCK_LOD` is not in this deploy's flags).

**Positive identification (medium-high confidence)**: the band is the **per-block flat-colour
band map faithfully rendering the worldgen's own per-block snow/stone alternation at the
freeze line, at 1 texel = 1 block, NEAREST-sampled** (`band_map : filter_nearest`,
:4108/:4186; texelFetch per block, :4113-4127). Around the snow line / on steep faces the top
block alternates snow-white vs stone-gray block-by-block, so the innermost band of the far
field renders a white/gray per-block checker — at close range this reads exactly like an
alpha-hash dither. The band is at the *inner edge* because that is where the band texels are
magnified largest and where the frontier against baked-vs-unbaked page coverage
(premultiplied-alpha gate, :3991-4002) also mixes flat `col` fallbacks in. One-probe live
confirm: hold the same peak vantage and flip `FP_SKIN_FLATCOLOR`/`FP_BAND_BLOCK_MAP` off for
one A/B — the checker collapses to the uniform vertex colour if this identification is right.
The fix below does not depend on which way this confirm lands (it is a colour-domain
sub-symptom of the same "far field visible at near range" defect).

---

## 2. Why this is a real defect, not cosmetics

The tier contract (TIER-DEPTH, `tier_place.gd:3-10`) is: *near voxels are the authoritative
visible surface; the far ring is a horizon/backstop tier that must never protrude and is
expected to be **hidden** by near geometry wherever the player can look closely.* Steep
relief breaks the "hidden" assumption structurally: the near tier's coverage boundary is a
**vertical** cut (−40 blocks) while the defect driver is **vertical** relief — so on every
mountainside the coarse/sunk/pale tier becomes the *foreground* at 40–130 blocks from the
camera, a range at which its 26-block cells, its ~12-block sink + envelope-minima (deliberate
*anti*-protrusion displacements, sized to be invisible when the tier is distant or occluded)
and its flat unlit palette are all individually visible. The player reads it as a hole in the
world ("pale rectangle hiding the surface", "inside a mountain"), and it fires on every
peak/cliff — the terrain type mountains exist to showcase. It also violates the seamless-
scales law (LOCKED: walk→fly→orbit is ONE continuum, no stitches): the near→far stitch is
nakedly visible at walking range.

---

## 3. Fix options, ranked

All options are a NEW `const FP_* := false` in `cube_sphere.gd` (byte-identical off; FLAT
`verify_feature` 6042/0), NEVER-OOM bounded, independently deployable/rollback-able.

### 3.1 RECOMMENDED — (A′) `FP_FARRING_UNCOVERED_TRUE`: per-VERTEX analytic un-sink of the dense backstop where the near field is provably unreachable

Generalize the shipped-and-proven `FP_FARRING_ACTIVE_NOBLACK` law from "1 facet ×
whole-facet × camera-column probe" to "every backstop facet × per-vertex × **analytic**
coverage": a dense backstop vertex whose surface point lies **outside the near-stream
ellipsoid (inflated by a safety margin)** emits at the TRUE welded chord height, un-sunk,
because near mesh **cannot exist there** — z-fighting is impossible *by construction*, not by
probe-and-hope. Vertices inside the (inflated) ellipsoid keep today's envelope+sink law
byte-identically — the proven no-protrusion regime keeps governing exactly the region where
near/far can actually coexist.

- **Coverage law** (pure function, no `is_area_meshed` probes, worker-safe): the streamed
  region is the `attach_viewer` ellipsoid — centre = player + radial·O (O = 12), horizontal
  semi-axis 128, vertical semi-axis H = 52 (`module_world.gd:2895-2905`,
  `terrain_config.gd:213-236`) — inflated by `UNSINK_MARGIN_BLOCKS := 24` (one 16-block mesh
  block + slack) on every axis. Vertex test in the active facet frame: radial delta vs
  tangential distance to the player column. A vertex is `uncovered` iff outside the inflated
  ellipsoid. Frontier continuity: a vertex un-sinks only in full (its 17×17 grid slot either
  takes the true-chord height or the envelope height); a cell mixing covered/uncovered
  corners simply spans the two — a continuous skirt, no crack (single shared vertex array).
  Under `FP_BLOCKY_FARRING` the cell top is the corner MIN, so a mixed frontier cell
  automatically takes the *conservative* (enveloped) height — the frontier can never
  protrude.
- **Height source**: a second small dense cache `_btrue_cache[fid]` holding the plain welded
  TRUE chord (exactly `_ensure_backstop_chord_cached`'s construction,
  `facet_far_ring.gd:2995-3008`, kept separate because under env_all `_bpos_cache` holds
  envelope heights). Built lazily for backstop fids only, on the same warm paths, reaped with
  the backstop role. Colour reuses `_bcol_cache` unchanged.
- **Why per-vertex-true beats re-enabling U2+U3 here**: U3 (`FP_FARRING_LEVEL`) only
  collapses the *sink* to ε; the vertex heights stay envelope-minima, so a ridge still reads
  tens of blocks low, and U2's `is_area_meshed` probe machinery brings the churn/hysteresis
  cost that kept it out of this deploy. The analytic law needs no probe, no hysteresis, no
  streaming race: "outside the ellipsoid" is stable under everything except player movement.
- **Re-emit trigger**: the un-sink pattern depends only on the player column ⇒ mark
  `_pending` when the column drifts ≥ `UNSINK_DRIFT_BLOCKS := 16` since the last emit
  (freeze the column per dispatch into `_async_unsink_col`, the `_async_backstop` freeze
  pattern, :294-300). ≤ 1 extra async rebuild per 16 blocks walked — same order as the
  existing coverage/crossing cadence, riding the existing async rebuild pipeline (no new
  RenderingServer usage; the swap path is untouched).
- **Both viewing cases fixed**: peak — every down-slope vertex below the −(40+24) cut
  un-sinks to true height (the "sunk well" and the inner cliff-lip step disappear; what
  remains is coarse-but-correctly-placed terrain). Hover — the ellipsoid contains no ground ⇒
  ALL backstop vertices of ALL hop-0/1 facets un-sink ⇒ no per-facet steps (fixes the
  neighbour-facet half of the defect that single-facet noblack cannot).
- **Interaction with `FP_FARRING_ACTIVE_NOBLACK`**: when both are on, the new per-vertex law
  supersedes the whole-facet `_bpos_cache` pick in `_emit_cached`'s noblack branch
  (:3592-3593) — one un-sink law, no double standard; noblack's other two jobs (immediate
  chord cache, re-emit arming, :1434-1449) are kept verbatim.
- **Risk (low)**: (i) un-sunk chord can overshoot the true surface between samples on concave
  terrain (the ~13-block sagitta bound that motivated the sink) — harmless here because
  nothing else draws in the uncovered region (V2 owns hop 2–4 only; skin/block-LOD off; near
  mesh provably absent), and the blocky corner-MIN halves it in practice; (ii) the margin
  must genuinely cover godot_voxel's mesh reach past the viewer ellipsoid — G-PB-COVERED
  (§4) pins it; (iii) +1 rebuild per 16 blocks — measured by the existing rebuild-count
  gate discipline.
- **Expected residual (honest)**: the foreground far field will still be 26-block coarse and
  band-flat-coloured — it will read as "distant-style terrain at the right height", not
  full-detail voxels. Removing that residual is (B)/(D)/block-LOD territory, out of scope.

### 3.2 (D) `FP_VIEWER_RELIEF_REACH` — relief-aware downward stream reach (rank 2, good companion later)

The defect driver is the fixed −40 cut, so let D adapt: D = clamp(local relief drop within
the near disc, 40, U=64) using the existing `clamped_viewer_offset_y/ratio` helpers
(`terrain_config.gd:220-236` — today consts, would become functions of a cached local-relief
sample), updating the viewer offset/ratio with hysteresis. Pros: real coverage — actual
voxels down the slope; attacks the cause, not the symptom. Cons/risk: pays real streaming
(−40 → −64 ≈ +23 % vertical slab volume; covering 100-block drops needs a ratio raise
0.5 → ~0.69 ≈ +37 % — minutes-scale restream cost territory on 2-core web), and every D
change triggers viewer churn/restream. Quantify via the heap/soak harness before enabling.
Caps: `RELIEF_REACH_MAX := 64` initially (no ratio change — offset-only, zero new data class),
which alone pushes the pale frontier from −40 to −64. Not the minimal first fix, but the
right second lever if A′'s residual still bothers at close range.

### 3.3 (C) `FP_BACKSTOP_SLOPE_SHADE` — colour/shade-match the backstop (cosmetic companion, rank 3)

Kill the flat pale wash: multiply a static slope hillshade into the dense backstop vertex
colour (normal from the dense grid's own neighbours — the `_rg.g` shade-byte precedent from
FP_BAND_SHOT, single-owner rule respected: v_st keeps dynamic light), and/or stop the
freeze-line whitening from painting *foreground* cells (blend `FarPalette.color_for`'s snow
override toward the per-block band colours near the camera). Cheap, zero geometry risk, but
does NOT fix the sunk-well geometry — never sufficient alone. Pairs well with A′.

### 3.4 (B) `FP_FULLRES_256` — widen the near radius 128→256 (rank 4, rejected as the fix)

The lever already exists (`terrain_config.gd:155-176`). Rejected: ~8× streamed data blocks,
the exact cost `CURVED_RENDER_RADIUS_BLOCKS` was introduced to avoid ("minutes" on the web's
2 voxel workers, :145-153), and it still doesn't fix the vertical cut (the −40 clamp
guillotines the slope regardless of horizontal radius) nor the hover case.

### 3.5 (A-as-stated) probe-based per-cell un-sink via `is_area_meshed` (rejected variant)

The brief's option A at ring-1 granularity, driven by the U2 coverage probe. Rejected in
favour of A′: whole-facet granularity doesn't fix the peak case at all (the active facet is
already the noblack facet and stays sunk); per-cell probing needs throttles + 2-read
hysteresis + reap (the U2 machinery) and still races streaming arrivals (transient
protrusion window). The analytic ellipsoid gives the same answer with zero probes and zero
races.

---

## 4. Flags, touch points, gates

### Flags (all `:= false` in `godot/src/cosmos/cube_sphere.gd`)

| Const | Role |
|---|---|
| `FP_FARRING_UNCOVERED_TRUE := false` | the recommended per-vertex analytic un-sink |
| `UNSINK_MARGIN_BLOCKS := 24` | ellipsoid inflation (mesh-block reach + slack) |
| `UNSINK_DRIFT_BLOCKS := 16` | player-column drift that re-arms `_pending` |
| (later, separate deploys) `FP_VIEWER_RELIEF_REACH`, `FP_BACKSTOP_SLOPE_SHADE` | §3.2 / §3.3 |

### Files / functions to touch (A′ only)

- `godot/src/world/facet_far_ring.gd`
  - new `_btrue_cache: Dictionary` + `_ensure_backstop_true_cached(fid)` (mirror of
    `_ensure_backstop_chord_cached`, :2995-3008, into the separate cache); reap alongside
    the existing dense-cache reap of departing backstops.
  - `_unsink_col` (live) + `_async_unsink_col` (frozen at `_dispatch_async_rebuild` /
    `_rebuild_full` — the `_async_backstop` freeze contract, :294-300). Column source:
    reuse the `set_player_column` push (`_player_col_abs`, :78-81) — WorldManager must push
    it under the new flag too, not only under FP_SMOOTH_RIM.
  - per-vertex law helper (pure; reads only frozen state) + blended position assembly in
    `_emit_cached`'s sunk branch (:3588-3604) and `_append_backstop_tris` (:3407-3448);
    supersede the noblack pos pick (:3592-3593) when the flag is on.
  - drift re-arm next to `_noblack_guarantee`'s call site in `_process` (:1249).
- `godot/src/world/world_manager.gd` — unconditional player-column push (vicinity of the
  cover-query wiring, :1117-1129 / `update_streaming`).
- `godot/src/world/terrain_config.gd` — read-only: expose one helper returning the streamed
  ellipsoid params (O, H, r) so the ring and `attach_viewer` share ONE derivation site
  (single-source rule; `module_world.gd:2895-2905` refactors to call it, value-identical).

### Gates (new `godot/src/tools/verify_pale_backstop.gd`, pattern of verify_far_smooth.gd; flag forced via function params per codebase convention, no sed)

- **G-PB-TRUE** (the defect gate): fixture = a mountain facet + a pinned player column on a
  peak (scan for relief range ≥ 30 within 128 blocks). Build the backstop emit; assert every
  emitted vertex whose surface point is outside the inflated ellipsoid sits at radius
  `R_datum + relief_true` within ±1.0 block (welded-chord/quantization tolerance) — i.e. the
  visible surface within N blocks of the camera on a steep column is at TRUE height, not
  sunk. **Falsify**: same fixture, flag off ⇒ those vertices sit ≥ ε·0.8 (~9+) blocks low.
- **G-PB-COVERED** (no-protrusion preserved): every vertex inside the inflated ellipsoid is
  byte-identical to the flag-off emit (array compare) — the near/far coexistence region is
  untouched; plus the margin audit: no un-sunk vertex lies within `UNSINK_MARGIN_BLOCKS/2`
  of the *un-inflated* ellipsoid surface.
- **G-PB-HOVER**: player column held 200 blocks above the surface ⇒ ALL backstop vertices of
  active + ring-1 emit at true height (no per-facet step: max |Δr| across a shared facet
  edge ≤ 1.0).
- **G-PB-OFF**: flag off ⇒ emitted arrays byte-identical to shipped golden; full FLAT
  `verify_feature` 6042/0.
- **G-PB-LEDGER**: `_btrue_cache.size()` ≤ the sticky cap (`STICKY_RING1_MAX = 12`) + pool
  bound; measured bytes ≤ 64 KB; rebuild count over a scripted 256-block walk ≤ walk/16 + role
  events (the bounded-re-emit proof, `_cull_reemit_count` discipline :284).

## 5. NEVER-OOM ledger (A′)

| Item | Bound | Bytes |
|---|---|---|
| `_btrue_cache` pos grids | ≤ ~12-16 backstop fids × 17²·12 B | ≤ ~56 KB peak |
| colour | reuses `_bcol_cache` | 0 |
| per-emit uncovered mask | transient 17² bytes/facet inside the emit loop | ~0.3 KB transient |
| frozen dispatch state | 1 Vector3 + params | negligible |
| re-emits | rate-bounded by drift const + existing single-flight async pipeline | 0 resident |

Total: **≤ 64 KB resident, zero per-frame allocation, no growth with walk distance** —
reaped with the backstop role exactly like `_bpos_cache`. Heap A/B: the standard live
telemetry heap counter before/after a 10-minute peak walk, budget +0.1 MB.
