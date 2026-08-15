# COSMOS FARTREE ORBIT-VISIBILITY — the shell-band far-tree fix (FP_FT_SHELL_BAND)

Status: DESIGN (no code in this doc's session). Flag: `FP_FT_SHELL_BAND`, default `false`, byte-identical off.
Author: Fable far-render architect, 2026-08-15. Companion docs: COSMOS-FAR-TREES-DESIGN.md (the ladder),
COSMOS-FAR-TREES-COLORFIX-DESIGN.md §4.2 (the stale latch), COSMOS-FARTREE-ALIGN-DESIGN.md §5 (NEARCULL),
COSMOS-FARTREE-POLISH-DESIGN.md §1/§4.1 (guard / staleness floor), COSMOS-FOREST-FPS-DESIGN.md §4 (DELTA).
Memory: [[voxiverse-fartree-orbit-dropout]].

---

## 1. Problem (live-confirmed 2026-08-15)

Flying up from a forest, the 3D far trees VANISH abruptly: abundant at alt 41, entirely gone by alt 362.
The player expects the ladder the design promises — trees thinning into fog/speckle — not a hard cut.

### 1.1 Served-pck flag reality (dumped from the DEPLOY-WORKTREE `build/web/index.pck` via
`ProjectSettings.load_resource_pack` + `get_script_constant_map` in the custom headless editor — the #131
lesson: never trust a source-tree run)

| Constant | Live value | | Constant | Live value |
|---|---|---|---|---|
| FP_FAR_TREES / _CARDS / _MESH | **true / true / true** | | OFFSURFACE_Y | **256.0** |
| FP_FAR_TREES_FADE / _SNOW | true / true | | ATMO_TOP / FP_ALT_REGIME | 384.0 / **true** |
| FP_FAR_TREES_COLORFIX / _DELTA | true / true | | FP_ORBIT_RELIEF (+SURFACE_HIDE) | true (true) |
| FP_FAR_TREES_ALIGN / _NEARCULL | true / true | | FP_PLANET_MAP | **true** (rung 3 live) |
| FP_FT_FRAME_WELD / _XFADE_COMPL | true / true | | FP_SHELL_CAMERA_SET / _PREWARM | true / true |
| FP_FT_NEAR_GUARD / _TEXMEAN_COLOR / _STALE_REBUILD | true / true / true | | FP_FAR_TERMINATOR_WELD / FP_SHADE_UNIFIED | true / true |
| FP_FT_MOVE_HYST (FT_DELTA_MOVE_HYST 12) | true | | FP_LOAD_DEFER / FP_CLIMATE_BIOMES | true / true |
| FAR_TREES_MESH_MAX / CARD_MAX | 448.0 / 2400.0 | | FT_SINK_MAX / R0 / R1 | 0.15 / 208 / 288 |
| FAR_TREES_CARD_INST_MAX / MESH_TOTAL_MAX | 8192 / 1024 | | FT_CULL_MIN / FT_CULL_DWELL | 64.0 / 2 |
| FAR_TREES_STEP_MS / BYTES_MAX | 250 / 4 MB | | FOG_BEGIN / CAMERA_FAR (FR:30-31) | 2200 / 9000 |

The **entire far-tree family ships ON**. The dropout is not a flag regression — it is the designed-in
on-surface-only law itself.

## 2. Mechanism (verified in the deploy worktree source == served pck)

- `FacetFarTrees.step()` — `godot/src/world/facet_far_trees.gd:763-770`: reads
  `(_ring as FacetFarRing).shell_offsurface()`; if true, `_apply_visibility(offsurf)` **hides every
  far-tree node** (cards MMI + all 6 mesh MMIs, facet_far_trees.gd:754-761) and `return`s — the instance
  set freezes. Comment :765-766: *"NO far-over-near / orbit suspend (§4.2): trees show ON-surface only …
  mirror of G3's off-surface-only visibility, inverted."*
- `shell_offsurface()` = `_cam_set and not _emit_floored_last` (facet_far_ring.gd:3255). `floored` is
  `h < OFFSURFACE_Y` fed per frame by `apply_camera_set` (facet_far_ring.gd:1198, 1208), latched into
  `_emit_floored_last` at each shell re-emit snapshot (facet_far_ring.gd:1288 — a floor crossing always
  re-emits, `shell_fall_should_reemit` :1272-1273, so the latch tracks the crossing within one snapshot).
- **`OFFSURFACE_Y = 256.0`** (cube_sphere.gd:2240). So the whole tier hard-suspends at alt ≈ 256.

### 2.1 The contradiction (the actual defect)

The ladder (COSMOS-FAR-TREES-DESIGN.md §4) builds rung-2 cards out to **FAR_TREES_CARD_MAX = 2400**
camera-distance blocks (≥ FOG_BEGIN 2200, so fog performs the final dissolve), yet the tier dies at
**altitude 256** — a *different variable* an order of magnitude tighter. Angular arithmetic (≈688 px/rad,
1080p/90° — the ladder's own yardstick):

| Camera altitude | nearest tree (directly below) | 6-blk tree on screen | fine-map texel (6.5 blk) on screen |
|---|---|---|---|
| 256 (today's cut) | 256 blk | **~16 px** | ~17 px |
| 448 | 448 blk | ~9 px | ~10 px |
| **600** | 600 blk | **~6.9 px** | **~7.5 px** |
| orbit 650-700 | 650+ | ≤6 px | ≤7 px |

At the 256 cut a tree is still a **16-px object** — visibly popping out. At ~600 the card's footprint
**converges with the rung-3 fine-map texel footprint** (one tree ≈ 1-2 texels ≈ its own card size): 3D
geometry adds nothing over the canopy speckle beyond that point. The live orbit screenshots confirm rung 3
works (forest green vs desert tan, FP_PLANET_MAP live). So:

- **256 → ~600 is a hole**: 3D trees are meaningful and the ladder owns the range, but the tier is hidden.
- **≥ ~600 is fine-by-design**: rung-3 speckle is the correct representation. We do NOT add 3D at true
  orbit (sub-texel, physically meaningless, and the orbit regimes want the tier quiescent).

### 2.2 Why the suspend exists (must be preserved, not deleted)

The on-surface-only law was hardened by FP_FAR_TREES_COLORFIX §4.2 (#115) + NEARCULL (#130) for
**de-orbit correctness**: a frozen instance set re-shown instantly on the offsurf→onsurf flip carries
PRE-ORBIT band membership (stale near/far bands, far-over-near) until the first rebuild — so the `_stale`
latch (facet_far_trees.gd:100, 754-761) hides the tier "correct-or-nothing" until one rebuild completes.
G3 `FacetOrbitRelief` is the opposite tier (off-surface-only; on-surface hidden + frozen,
facet_orbit_relief.gd:645-653) — the two were split at the OFFSURFACE_Y boundary. Any fix must carry the
§4.2 latch and the §5.5 far-over-near filters into the shell regime, not delete the gate.

---

## 3. The fix: a three-zone visibility law (cards own the shell band)

Replace the binary `offsurf ⇒ hide` with an **altitude-banded law**, flag-gated `FP_FT_SHELL_BAND`:

```
h := ring.shell_cam_alt()                      # camera radial altitude (new read-only accessor = FR _dbg_h,
                                               # fed per frame by apply_camera_set, FR:1200 — no new math)
offsurf := ring.shell_offsurface()             # unchanged predicate

ZONE S (surface,   not offsurf):        today's behaviour VERBATIM — mesh rung [R0,448) + card rung
                                        [448,2400], live rebuilds, guard, NEARCULL, DELTA. Untouched.
ZONE B (shell band, offsurf, h < FT_SHELL_HIDE_ALT=600):
                                        CARDS VISIBLE + LIVE (calmed rebuilds, §5); mesh rung HIDDEN;
                                        a global dither fade dissolves the tier over
                                        [FT_SHELL_FADE_ALT=520, 600] (§3.3).
ZONE O (orbit,     offsurf, h ≥ 600):   tier HIDDEN + FROZEN (today's economics), `_stale` latched —
                                        rung-3 canopy speckle owns the view (ships, confirmed live).
```

Flag off ⇒ `_apply_visibility(offsurf)` + early-return exactly as shipped (zone B collapses into zone O
at the 256 boundary) — byte-identical.

### 3.1 Rung ownership off-surface: the whole band goes to CARDS

In zone B the **mesh rung suspends** (its MMIs hidden, `_rebuild_meshes` skipped) and the card rung
owns `[R0, 2400]` — the machinery already exists: it is exactly the "cards own the frontier" code path
that runs when `FP_FAR_TREES_MESH` is off (facet_far_trees.gd:1052-1056 `card_inner_radius()`, :1086-1102
the NEARCULL/fade branches). The rebuild takes a `shell_mode` bool and forces those branches. Why:

- **Geometry**: in zone B every tree is ≥ h > 256 blocks away (the camera is airborne; base camera
  distance ≥ altitude). The mesh band [128, 448) survives only as the sliver [h, 448) directly below,
  shrinking to nothing by h = 448 — not worth 6 draws + trunk-stretch + guard bookkeeping.
- **View direction**: aerial views are dominated by the cap quad (the horizontal canopy disc,
  facet_far_trees.gd:1377-1379) — precisely the top-down-correct piece of the cross+cap design (§3.1d).
- **Perf**: halves the rebuild (no 6 species buffers, no mesh writes) and keeps zone B one-draw.

The mesh→card swap at the 256 crossing happens at ≤16 px on silhouette-matched representations
(same archetype cells rasterised into the atlas) mid-flight; a `FT_SHELL_SWAP_DWELL := 2` step dwell
(≈0.5 s) on zone entry/exit absorbs boundary flapping when hovering at h ≈ 256. Accepted as an A/B
checkpoint (§9); the fallback lever if it reads as a pop is to keep the mesh rung live in zone B too
(a one-line widening — staged, not default, because of the guard/draw cost).

### 3.2 The card band in zone B, exactly

- Membership: base camera distance ∈ [R0(=128, moot — nothing is closer than h), 2400], nearest-first
  under the unchanged `FAR_TREES_CARD_INST_MAX = 8192` cap. Worst case (all-forest disc below at h≈500)
  is the same annulus area as the surface horizon case the cap was sized for — no new cap.
- Fades: the NEARCULL "cards own frontier" alpha (`thin_alpha` only, facet_far_trees.gd:1101-1102) —
  keep(d) thinning toward the fog line, no near dither-in. FT_SINK ramp saturated at 0.15 (all trees are
  past FT_SINK_R1=288) — the deep-band bury, unchanged.
- Orientation/lighting: unchanged — FRAME_WELD facet-basis cards, radial `voxi_shade`, per-frame
  `sun_dir` (world_manager hub → FR:5333, called unconditionally) + `planet_centre` refresh already in
  `step()` (:793-797). Off-surface trees therefore shade the terminator correctly for free.

### 3.3 The 520→600 handoff to rung 3 (no rebuild-driven fade)

A per-instance alpha would need rebuilds to animate a climb fade. Instead: one **`tier_fade` uniform**
(default 1.0) multiplied into the existing FADE dither test, set per step (and per frame at trivial cost
if the step cadence visibly stair-steps — it is one `set_shader_parameter`):

```
tier_fade = 1.0 − smoothstep(FT_SHELL_FADE_ALT, FT_SHELL_HIDE_ALT, h)     # 1 below 520, 0 at 600
shader:   if (_ft_dither(FRAGCOORD.xy) > v_fade * tier_fade) discard;      # (compl-inverted variant idem)
```

Spliced into `_CARD_TAIL_FADE` under the flag by the same string-splice pattern as SNOW/XFADE_COMPL
(facet_far_trees.gd:242-259) — flag off ⇒ shipped shader string verbatim. The dissolve is screen-space
dither (gl_compat-safe, no sorting), symmetric on descent (trees dither IN through 600→520). Requires
`FP_FAR_TREES_FADE` (live ON); without it the flag documents a hard cut at 600 — still strictly better
than today's cut at 256, but FADE is a declared prerequisite.

Below the fade band nothing fades by altitude: fog (2200) + keep(d) thinning + the 2400 band edge do the
distance work exactly as on the surface.

---

## 4. Correctness in the shell regime

### 4.1 Far-over-near (§5.5 filter #1) — geometrically vacuous off-surface, asserted not probed

On the surface, R0/NEARCULL exists because near voxel trees render inside `near_render_radius()` = 128
and the probe annulus tops out at 128+40 = 168 (`probe_hi`, facet_far_trees.gd:543, 575, 660). In zone B
**every tree's base camera distance ≥ h > 256 > 168**: `_nearcull_emit` already short-circuits to
"emit, no probe" (:544-546) and the guard's `dist >= r_hi ⇒ skip` (:675-676) never fires. There is no
near mesh to double-render over — the near field cannot reach the ground from alt > 128+ (and above
ATMO_TOP+PREP ≈ 416 it is FP_ALT_REGIME-frozen besides). So in the shell regime the correct R0 is
"no inner cull at all", which the existing code produces by construction. Design decision: in zone B
**skip the guard pass and fingerprint entirely** (they are dead weight; the fingerprint would issue 0
probes anyway) and let the gate assert the invariant `min instance dist ≥ h` instead of probing it.
Descending back through 256 re-enters zone S where guard + NEARCULL resume — and they resume against a
**fresh rebuild** (§4.2), never against a frozen set.

### 4.2 The §4.2 stale latch, carried to the new boundary

The latch trigger moves from "any offsurf frame" to "**any zone-O frame**" (`offsurf and h ≥ FT_SHELL_HIDE_ALT`):

- **Climb S→B**: no latch — the set stays live (calmed rebuilds), bands stay correct, no pop at 256
  (the node simply stays visible; the mesh rung dwell-swaps to cards).
- **Climb B→O**: `_stale` latches on the first zone-O frame; the tier hides (dither-faded to nothing
  already by 600, so the hide is invisible). Frozen exactly as today — orbit economics unchanged.
- **De-orbit O→B**: correct-or-nothing preserved: the tier **stays hidden** (`_stale` true) until the
  first completed rebuild re-bands the instance set for the current camera, then appears — dithering in
  through the 600→520 fade. The #115 stale-band garbage frame remains impossible.
- **De-orbit B→S**: the set is live (rebuilt in-band), so crossing 256 needs no latch; the swap-dwell
  brings the mesh rung back after `FT_SHELL_SWAP_DWELL` steps; NEARCULL/guard own the frontier again.
- The rebuild that clears `_stale` in zone B must be reachable at credit 0 (a de-orbit is exactly when
  FP_LOAD_DEFER starves credit): the FP_FT_STALE_REBUILD ≤0.5 Hz floor (:782-786, 829-835) applies in
  zone B with the same wall/move thresholds, so "hidden forever at credit 0" cannot happen — mirrored by
  the existing #132 §4.1 reasoning.

### 4.3 Filters that ride along unchanged

Chop filter (`_is_chopped`, at rebuild), body gate (Earth-only enumeration), FP_CLIMATE_BIOMES species
gate, ALIGN/FRAME_WELD anchoring, COLORFIX buffer layout, SNOW selection: all are enumeration/rebuild-
time laws independent of altitude — zone B rebuilds run them verbatim. `_cam_to_absolute` (:1463-1466)
already maps the render camera through the ring's live transform (SN3 scaled placement is a parent
transform of the instances, so band distances stay frame-consistent by construction — same argument as
the tier's class doc).

---

## 5. Perf: rebuilding while flying, without re-lighting #119/#129

The band currently freezes off-surface, so zone B introduces new work. Quantified + gated:

### 5.1 Cost per rebuild (zone B is card-only)

Rebuild = walk cached records (≤64 facets × ~235 recs ≈ 15 k distance+fade evaluations, no probes in
zone B) + write ≤8192×16 floats + one 512 KB `set_buffer` upload. The #119/#129 measured full rebuild
(meshes + cards + probes, web) was ~50-60 ms (cube_sphere.gd:933 comment); card-only, probe-free is
roughly half — budget **≈20-30 ms web worst-case**. This is exactly the class of cost that PWM'd fps in
#119 when re-armed at 2-4 Hz — so the cadence, not the cost, is the design surface.

### 5.2 The zone-B cadence law (altitude-scaled DELTA)

The buffer is a pure function of (camera, cache epoch, edits) — and in zone B its *visual* sensitivity
to camera motion scales with 1/h (band membership + thinning alphas shift ~proportionally to move/h). So
widen the DELTA move threshold with altitude:

```
zone-B move_thr = max(FT_DELTA_MOVE_HYST (12), FT_SHELL_MOVE_FRAC (0.25) × h)
zone-B rate cap = FT_SHELL_REBUILD_MS := 500        # ≥ the surface 250 — a hard ≤2 Hz ceiling
```

- Climb (mostly radial, 100-200 blk/s dev-fly): the 256→600 band is ~2-4 s → **~4-6 rebuilds total**.
- Low-alt cruise (h ≈ 300, 60 blk/s lateral): rebuild every 75 blk ≈ 1.25 s → ~25 ms / 1250 ms ≈
  **2% main thread** — an order below the #119 regime (2-4 Hz × 50-60 ms ≈ 10-25%).
- Fast lateral flight (200 blk/s at h 400): threshold 100 blk → 2 Hz ceiling binds → ≤ 25 ms × 2/s = 5%.
- Orbit proper: zone O — **zero rebuilds** (today's freeze economics exactly).

The wanted-facet rescan reuses the same widened threshold (`max(FT_DELTA_WANTED_MOVE, 0.25 h)`).
Zone transitions (S↔B↔O, and the swap-dwell expiry) are folded into `_rebuild_inputs_changed` as a
latched `_last_rebuild_zone` — entering a zone re-arms exactly one rebuild. The credit/settle gates,
FP_FT_MOVE_HYST interaction, and the STALE_REBUILD floor compose unchanged; enumeration stays one
facet/job under the settle gate (the LRU is distance-driven and works at any altitude, :951-970).

### 5.3 NEVER-OOM

**Zero new allocations**: same card buffer (already `instance_count = 8192` at setup), same LRU (64
facets), same atlas/mesh; zone B skips guard metadata growth. `total_bytes()` (:1480-1501) is unchanged
and stays asserted ≤ `FAR_TREES_BYTES_MAX` (4 MB). The only new state is a handful of scalars (zone
latch, dwell counter, fade uniform value).

---

## 6. Scope isolation — nothing else moves

`FP_FT_SHELL_BAND` is consumed **only** in `facet_far_trees.gd` (+ one read-only `shell_cam_alt()`
accessor on the ring exposing the already-computed `_dbg_h`). Explicitly untouched:

- **FP_ALT_REGIME** near-field freeze (cube_sphere.gd:2790, enter > ATMO_TOP+PREP+HYST ≈ 448): trees
  are a far tier stepped from the ring's `_process` (FR:1437-1438), which runs off-surface (G3 proves
  it) — no near-field machinery is woken. The zone-B band [256, 600] overlaps the freeze band by design;
  the tier never queries the near field there (§4.1).
- **G3 FacetOrbitRelief** off-surface-only law + SURFACE_HIDE (facet_orbit_relief.gd:645-653): untouched.
- **Shell emit law** (camera-set, floored cap, FALL_HOLD, SURF_CAP, CLIMB_NO_CHURN): untouched — we only
  *read* `shell_offsurface()`/`_dbg_h`.
- **FacetFarStructures** (shares the trees' pattern, FR:1440-1442): stays on-surface-only. If the same
  dropout is later confirmed for far structures, it gets its own flag mirroring this design — not a
  free rider on this one.
- OFFSURFACE_Y itself: **not** re-tuned. The #72/#73 lesson class ("never tighten a shared constant to
  fix one tier") applies — the fix is tier-local zoning, not moving the shared boundary.

---

## 7. Flag + consts (byte-off discipline)

Declared in `godot/src/cosmos/cube_sphere.gd` beside the FP_FT_* family (CS:886-1022 pattern):

```
const FP_FT_SHELL_BAND := false      # far trees render in the off-surface shell band [OFFSURFACE_Y, FT_SHELL_HIDE_ALT)
const FT_SHELL_HIDE_ALT := 600.0     # zone-O boundary: card footprint ≈ fine-map texel footprint (§2.1) — rung 3 owns above
const FT_SHELL_FADE_ALT := 520.0     # tier_fade dissolve start (80-blk band into the hide)
const FT_SHELL_MOVE_FRAC := 0.25     # zone-B DELTA move threshold = max(FT_DELTA_MOVE_HYST, frac·h)
const FT_SHELL_REBUILD_MS := 500     # zone-B rebuild rate cap (≤2 Hz hard ceiling)
const FT_SHELL_SWAP_DWELL := 2       # steps of zone dwell before the mesh↔card rung swap (256-boundary flap absorber)
```

Off-path byte identity: every new read sits behind `CubeSphere.FP_FT_SHELL_BAND`; `_apply_visibility`
keeps its shipped body when off (the new `h` argument defaults so existing call sites/gates compile
unchanged); the shader splice returns the shipped string verbatim when off; no node, buffer, or const
is touched off. Prerequisites (all live ON): FP_FAR_TREES + _CARDS (the rung), FP_SHELL_CAMERA_SET
(offsurf/h exist), FP_FAR_TREES_FADE (the dither dissolve), FP_FAR_TREES_DELTA (the cadence law),
FP_FT_STALE_REBUILD (credit-0 de-orbit recovery). The implementation asserts/documents these; with any
absent the flag degrades to shipped behaviour, never worse.

---

## 8. Gates (verify_far_trees.gd additions — headless; shader is live-only)

Headless drives use the existing hooks (`debug_set_cache` / `debug_step` / `debug_apply_visibility` —
extended with the `h` argument — `debug_stale_*`, `debug_buffer`), synthetic records, no threads:

1. **G-FTSB-OFF (byte identity)**: flag false ⇒ `step` at (offsurf=true, h=300) hides the node, runs
   zero rebuilds, buffers untouched — bit-identical to shipped; the full existing FT gate suite passes
   unchanged in both flag states.
2. **G-FTSB-VIS (the predicate, sampled)**: flag true ⇒ (h=41, floored) show cards+meshes; (h=300,
   offsurf) show cards, meshes hidden; (h=560) cards shown, `tier_fade` uniform ∈ (0,1) per the §3.3
   law (pure-function assert on the computed value + `get_shader_parameter` read-back); (h=650) all
   hidden + `_stale` latched. Monotone: no h where a higher altitude shows more.
3. **G-FTSB-BAND (zone-B rebuild)**: seed cache, camera at surface-point + 300·r̂, `debug_step` ⇒ card
   instances all with dist ∈ [300, 2400], **zero** mesh instances, **zero** cull probes, **zero** guard
   metadata rows (the §4.1 assertion), thinning survivors deterministic across runs.
4. **G-FTSB-LATCH (climb + de-orbit script)**: h sequence 41→300→650→300→41: assert visible/hidden per
   §4.2 at each step, `_stale` latches exactly at 650 and clears only on the first completed rebuild at
   descending 300 (before it: hidden; after: visible) — no frame where a pre-orbit-banded buffer is
   visible. Re-assert NEARCULL/guard re-engage after the B→S crossing + swap dwell.
5. **G-FTSB-CADENCE (pure)**: the zone-B `move_thr(h)`/rate law: at h=300 a 30-blk move ⇒ no rebuild,
   80-blk ⇒ rebuild; zone flips re-arm exactly one; `rebuild_count()` over a simulated 10-step hover
   is ≤1 (the #119 shape: no PWM at rest).
6. **G-FTSB-LEDGER**: after zone-B rebuilds `total_bytes() ≤ FAR_TREES_BYTES_MAX`; instance count ≤ cap;
   draws in zone B ≤ 1 (cards only).

**Live-probe-only** (headless dummy RS never parses GLSL — the shader splice compiles only in a real
GL context): the `tier_fade` dither dissolve rendering, the visual quality of the 256 mesh→card swap,
top-down card readability, and real fps. These are the A/B protocol's job:

## 9. Live A/B protocol (deployed web build, flag baked on)

1. **Climb**: spawn in forest, note tree field at alt ~41. Dev-fly straight up; screenshot at 150, 250,
   270 (the old cut — trees must persist; watch the mesh→card swap for popping), 350, 500 (thinned but
   present), 560 (visible dissolve), 650 (gone; fine-map canopy speckle reads beneath). FAIL today's
   build: gone by ~300. PASS: continuous ladder to speckle.
2. **Orbit**: one pass at 650+; confirm zero 3D trees, speckle forests, fps == pre-fix orbit baseline
   (zone O is byte-frozen).
3. **De-orbit**: drop from orbit into the same forest; confirm no stale-band flash at ~600 (trees dither
   in only after the first rebuild) and no far-over-near at touchdown (guard resumed).
4. **Low-alt cruise**: fly laterally ~2000 blk at h ≈ 300; trees populate ahead (the cadence law feeds
   the band), no #119-style fps sawtooth (telemetry `rebuild_count` slope ≈ distance/max(12, 0.25 h)).
5. **Surface regression**: forest-floor walk A/B fps + the #130/#132 scenarios unchanged (zone S is the
   shipped path plus one branch).

## 10. Risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | Zone-B rebuild churn re-lights the #119/#129 PWM (25 ms × Hz) | altitude-scaled move threshold (0.25 h) + 500 ms hard cap + card-only rebuild + zone O = zero work; gate 5 pins the at-rest cadence |
| 2 | Frozen/stale set during fast lateral shell flight (trees missing ahead) | the threshold is distance-based (lateral moves count); STALE_REBUILD ≤0.5 Hz floor covers credit-0; worst case is late fill-in, never wrong geometry |
| 3 | The 256 mesh→card swap pops when hovering at the boundary | ≤16 px, silhouette-matched atlas, swap dwell; A/B checkpoint 1 with the "meshes live in zone B" fallback lever |
| 4 | De-orbit stale-band garbage returns (the #115 regression the suspend prevented) | latch moved to the 600 boundary, not removed: hidden-until-first-rebuild is preserved verbatim; gate 4 scripts the exact descent |

## 11. Staging

**P0**: flag + consts; zone law in `step`/`_apply_visibility`; card-only zone-B rebuild path (reuse the
mesh-off branches); cadence law; ring `shell_cam_alt()`; gates 1-6. **P1**: `tier_fade` shader splice +
per-step uniform; live A/B 1-5. **P2 (only if A/B 1 fails)**: mesh rung in zone B. Each stage ships or
pulls alone behind the one flag.
