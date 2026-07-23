# COSMOS-ORBITAL-SHELL-DESIGN — the whole planet's far LOD from orbit

**Status:** design (no implementation in this pass). Branch `deploy/perf-plus-sky`, 2026-07-18.
**Problem (live pilot, from orbit):** only the facets near the player's ground-track render;
the far hemisphere shows no terrain — the planet reads broken / see-through from space.
**Parent designs this slots into (all honored, none re-litigated):**
`COSMOS-SEAMLESS-SCALES-DESIGN.md` (SSE law §3, overlap-not-fade §0.5, scaled clamp §5.2),
`COSMOS-FARRING-COVERAGE-DESIGN.md` (FULL_COVER sink contract),
`COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md` (sticky backstop roles, depth bias),
`COSMOS-SPACE-NAV-DESIGN.md` SN3 (`CosmosScale`: persistence altitudes, D_ENGAGE clamp, near/far ramp).
**Locked constraints honored:** NEVER-OOM (fixed ceilings, flag-gated, OFF = byte-identical);
seamless-scales (no hard swap anywhere); one-sampler law; ~200-draw web ceiling; multi-body genericity.

---

## 0. Executive summary

1. **The whole-planet orbital shell already structurally exists.** `FacetFarRing`
   (`godot/src/world/facet_far_ring.gd`) is ONE merged, absolute-coordinate, vertex-colored
   coarse mesh of the planet — all 6·K² = **3456 facets** at CELLS=4 (≈50-block cells), one
   `MeshInstance3D`, **one draw call**, colors from `FarPalette` (BlockCatalog-derived), heights
   from `TerrainConfig.profile_at_dir` (the one-sampler funnel). It persists to any altitude
   under SN3 (`CosmosScale.FARRING_RETIRE_H = 1e9`) and scales continuously past D_ENGAGE.
   **We do not need a new representation.** Building a second "globe mesh" would duplicate this
   tier (two representations of one surface = guaranteed drift seam) and double bytes.
2. **What is broken is the emitted-set *policy*, not the representation.** The ring emits only
   the hemisphere around the **player's active facet** (`_front_visible`,
   `facet_far_ring.gd:291-302`: cull vs `facet_normal64(_active_fid)`), and refreshes that set
   only on **surface crossing events** (`set_active` / `set_pool_excluded`, fired from
   `world_manager.gd:1825/2154`). Off-surface the radial direction drifts away from the active
   fid without a crossing (exactly the drift `_pool_off_surface`, `world_manager.gd:2114-2122`,
   exists to detect), so from orbit the emitted hemisphere stays pinned near the departure
   region — the rest of the planet is simply **absent from the mesh**. A co-factor above
   h ≈ 6.3 k: the fixed 9000 camera far clips the limb (owned by SN3's far ramp, not this doc).
3. **The fix is one flag: `FP_SHELL_CAMERA_SET`** — drive the emitted set from the **camera's
   radial direction** with an altitude-derived cap angle and an angular-drift re-emit trigger,
   reusing the existing deferred-warm + async-rebuild + single-swap machinery **verbatim**.
   Worst emitted mesh ≤ **~61 k tris / ~183 k verts / ~7.3 MB** (96° cap) vs the shipped
   surface hemisphere's ~55 k tris / ~6.6 MB — **delta ≤ +0.7 MB, still one draw call**. In low
   orbit the cap is *smaller* than today's hemisphere (~23 k tris at h = 500).
4. **No cross-fade is needed — and per seamless-scales none is wanted.** Emitted-set changes are
   invisible **by geometry**: facets enter/leave only beyond the visible cap (behind the limb or
   as sub-pixel silhouette slivers), asserted by the G-SSE-INV logging discipline. Near tiers
   (pool/skin) compose with the shell exactly as today: overlap + shared sampling + sunk
   backstop (FULL_COVER + sticky roles), retiring per SSE on ascent. There is no activation
   event at all — the shell is the same always-on far ring that draws the horizon while walking.
5. **Fixed memory ceiling, NEVER-OOM clean:** full-planet CPU caches (lazily or pre-warmed)
   cap at 3456 × ~700 B ≈ **2.4 MB** — a ceiling already reachable today by circumnavigating on
   foot; the shell only reaches it sooner. No per-orbit growth: every structure is keyed by
   fid ≤ 3456. Optional density step (`FP_SHELL_DENSE_CAP`, ≤ 64 facets @ 16 cells) adds a
   capped +3.7 MB mesh / +0.5 MB cache, flag-gated OFF.

---

## 1. Root cause, named (file:line)

| # | mechanism | where | effect in orbit |
|---|---|---|---|
| R1 | Emitted set = hemisphere around `_active_fid`'s normal | `facet_far_ring.gd:291-302` (`_front_visible`: `cd·nrm ≥ BACK_CULL`, `nrm = facet_normal64(_active_fid)`) | the drawn set is centred on the player's *surface* facet, not on what the camera can see |
| R2 | Set refresh only on surface crossing events | `set_active :109`, `set_pool_excluded :164`; callers `world_manager.gd:1825,1837,2169` | off-surface, the radial point drifts across facets with **no crossing fired** (`_pool_off_surface`, `world_manager.gd:2114-2122`, documents this exact drift; pool targets freeze off-surface at `:1978-1981`) → `_active_fid` goes stale → the hemisphere never recentres |
| R3 | Warm budget 3 ms/frame per newly-front facet set | `_warm_front :269` | even when crossings do fire (low fast orbit), a freshly needed ~500-facet cap takes seconds to warm → the set trails the ground track |
| R4 | Fixed camera far 9000 | `facet_far_ring.gd:22`, ramp exists in `CosmosScale.far_plane` (SN3, flag-gated) | above h ≈ 6.3 k the horizon tangent √(d²−R²) exceeds 9000 → the limb clips even where emitted |

R1+R2 are this design's target. R3 is fixed by S2 (prewarm). R4 is already owned by SN3
(`FP_SCALED_BODY` near/far ramp) — a stated dependency, not new work.

## 2. Representation — decision and budgets

Facet geometry: K = 24 ⇒ 3456 facets, edge ≈ 201 blocks, R = 3072. At CELLS = 4 a facet is
32 tris (tri-soup 96 verts); committed vertex ≈ 40 B (pos 12 + normal 12 + color 16).
The task's "16×16 or 32×32 per facet for the 24 facets" premise is corrected here: there are
3456 facets; the equivalent per-cube-FACE view is 6 sheets of 96×96 cells — which is **exactly
the existing far ring's resolution**. The object the task asks for already exists.

| option | draws | tris (worst) | verts | GPU bytes | new code/repr | verdict |
|---|---|---|---|---|---|---|
| **A. Camera-capped merged far ring** (chosen) | **1** | ≤ 61 k @96° cap (69.6 k @105°) | ≤ 183 k | ≤ **7.3 MB** (8.3 @105°) | policy change only | **CHOSEN** — reuses everything; ≤ +0.7 MB over shipped hemisphere (55.3 k tris / 6.6 MB) |
| B. Full-sphere static mesh (zero rebuilds ever) | 1 | 110.6 k always | 331.8 k soup | 13.3 MB (soup) / ~4.8 MB indexed | mesh-path change (indexing) | rejected v1: 2× bytes soup; indexed variant kept as the **measured fallback** if S1's re-emit churn fails its gate (§9) |
| C. Per-facet nodes/skins | 3456 | — | — | — | new streaming system | dead on arrival vs the ~200-draw ceiling |
| D. New unified "globe mesh" beside the far ring | 1 | ~110 k | — | +duplicate | second representation of the same tier | rejected: violates the one-representation economy — two meshes of one surface WILL drift (seam class); also double memory for zero pixels |

Chosen budget summary (the exec numbers): **1 draw; ≤ 61 k tris / 183 k verts / 7.3 MB GPU
worst (96° cap); CPU caches fixed 2.4 MB (+0.35 MB centre cache); zero allocations that grow
with time or orbits.**

## 3. The emitted-set law (`FP_SHELL_CAMERA_SET`)

All in absolute planet coordinates (the mesh's native space; camera position obtained f64 from
the nav state / `render_centre()` inverse — both placement paths, fixed-frame and legacy, fold
through `_placement_xform`).

```
ĉ        = normalize(camera − body_centre)              # sub-camera radial direction
d        = |camera − body_centre|                       # true (unclamped) distance, f64
θ_h(d)   = arccos(R/d)                                  # visible-cap angular radius (< 90° always)
θ_emit   = min(θ_h + SHELL_RELIEF_DEG + SHELL_SLACK_DEG, SHELL_CAP_MAX_DEG)
emit fid ⇔ centre_dir(fid) · ĉ ≥ cos(θ_emit)            # replaces the active-fid hemisphere test
```

Defaults (all tunable constants, gate-tuned):
- `SHELL_RELIEF_DEG := 8°` — terrain of height h pokes past the limb by ≈ √(2h/R): 8° covers
  ≥ 30-block relief; the 92-block mountain worst case is 15.5° but subtends ≤ ~4 px only at
  d ≥ 21 k where CELLS=4 is near sub-pixel anyway. The limb gate (§9 G-SHELL-LIMB) is the
  oracle; the lever costs bytes only via θ_emit.
- `SHELL_SLACK_DEG := 15°` — drift margin so re-emits are scheduled, not reactive.
- `SHELL_CAP_MAX_DEG := 96°` — ceiling (facet-centre test grants ~half-facet slop like the
  shipped `BACK_CULL = 0.0`); 105° is the pre-approved fallback if the limb gate demands it.
- **Re-emit trigger:** angular drift of ĉ since the last emit > `SHELL_SLACK_DEG − 2°`, or θ_h
  changed by > 5° (fast radial ascent/descent). Deferred (`_pending`), warmed under the
  existing budget, built by the existing async worker, swapped in one main-thread call —
  byte-for-byte the crossing-rebuild pipeline, just a different trigger.

Properties:
- **At the surface** (camera ~2 blocks up, d ≈ R+2): θ_h ≈ 2°, so the raw law would emit a
  ~25° cap — far less than the shipped 90° hemisphere. That is defensible by the horizon
  argument, but it changes the shipped surface look/perf baseline, which this flag must not do. **v1 therefore floors the cap at the shipped hemisphere while
  true-scale near tiers are live:** `θ_emit := max(θ_emit, 90°)` when `h < OFFSURFACE_Y`. Above
  OFFSURFACE_Y the altitude law takes over smoothly (θ_h ≥ 21° at h = 256 and the near tiers
  are frozen). This keeps flag-ON surface behaviour visually identical to shipped and confines
  the new policy to exactly the regime that is broken today.
- **Low orbit is cheaper than the surface:** h = 500 ⇒ θ_h = 30.7°, θ_emit = 53.7° ⇒
  N = 3456·(1−cos θ)/2 ≈ 705 facets ≈ **22.6 k tris** (vs 55.3 k shipped hemisphere).
- **High orbit saturates** at the 96° cap: 1909 facets ≈ 61 k tris — the worst case, +10 %
  over the shipped hemisphere, then held flat to any distance (the SN3 clamp keeps depth sane).
- Re-emit cadence at LEO: one per ~13° of ground-track arc ≈ one per ~3.5 facet-widths —
  comparable to today's per-crossing rebuild cadence, but with **no pool/skin churn attached**
  (those tiers are frozen/retired off-surface) and fully async (measured swap class ≈ +0.23 ms).
- `_active_fid` keeps its other jobs (placement in the legacy path, backstop roles); the flag
  only replaces the **cull axis** (`nrm` → ĉ) and the **refresh trigger**. Flag OFF ⇒
  `_front_visible` and triggers byte-identical to shipped.

## 4. Source: sampling, C++ bulk fill, precompute vs stream

- **One-sampler law holds by construction:** the shell's heights/colors come from
  `TerrainConfig.profile_at_dir` (`facet_far_ring.gd:519,569`) — the same funnel as the near
  mesher, skin, physics oracle. No new sampling site is introduced, so **seam agreement with
  near facets is inherited, not engineered**. When the FP_CPPGEN batch API lands
  (SEAMLESS-SCALES §7.2 `sample_columns` — already forwarded to the port), add a
  `sample_dirs(dirs) → profiles` twin so a facet's 25-sample warm is one C++ call; until then
  the GDScript warm stands (25 calls/facet, ~0.5–1 ms/facet web).
- **Cache ceiling:** `_pos_cache`+`_col_cache` = 700 B/facet → full planet **2.42 MB** fixed
  (+ `_centre_cache` ≈ 0.35 MB). This ceiling is *already reachable today* (walk around the
  planet); the shell reaches it in one orbit instead. No eviction needed — NEVER-OOM prefers a
  small never-freed constant over a churn policy, and 2.4 MB is that constant.
- **Precompute vs stream — `FP_SHELL_PREWARM` (S2):** on first sustained off-surface
  (h > OFFSURFACE_Y for > 5 s), kick a one-shot background warm of all uncached facets
  (WorkerThreadPool task or budgeted main-thread slices at the existing 3 ms — decided by a
  measured A/B; the profile funnel is pure/thread-safe per the L5 purity contract, but v1 can
  stay main-thread-budgeted to avoid re-auditing thread-safety of the GDScript funnel). After
  prewarm, an orbital re-emit is pure cached emit + async build — **no warm lag anywhere on
  the orbit**. Idempotent, bounded, one-shot per session.

## 5. Activation and no-pop composition (the seamless-scales answer)

**There is no activation event.** The shell is the far ring — always resident, always drawn,
from footstep to any altitude (SN3 persistence). The questions "what triggers the shell" and
"how does it cross-fade with near facets" dissolve into three already-locked mechanisms plus
one new invariant:

1. **Near-tier composition (unchanged):** pool voxel meshes and skin tiles strictly overdraw
   the shell; shell facets under them are emitted **sunk** (`FP_FARRING_FULL_COVER` +
   TIER-DEPTH sticky roles + depth bias) so no z-fight and no poke-through. On ascent the pool
   freezes (`OFFSURFACE_Y`) and persists to its SSE retire altitude (`CosmosScale.POOL_RETIRE_H`
   = 10 k, skin 4 k, ±25 % hysteresis) — each retire fires sub-pixel by SSE. **Role precedence
   under this design: backstop(sunk) > dense-cap(§6, unsunk) > coarse.** A facet keeps its sunk
   backstop role as long as near meshes overlap it (the sticky machinery already encodes
   make-before-break); it may take a dense or coarse role only after the near tier is gone.
2. **The border (unchanged):** above D_ENGAGE (≈ R+12.5 k) the SN3 clamp reparameterizes the
   same mesh continuously (s = 1 at engage — no switch). The shell design adds nothing here.
3. **Emitted-set changes are invisible by geometry (new invariant):** a facet ENTERS the set
   only near the emit cap — i.e. at/beyond the limb, where it is occluded by the planet body or
   subtends a sliver of silhouette; it LEAVES only after drifting `> θ_emit` from ĉ — strictly
   beyond the visible cap (the slack margin guarantees it left the visible region *before* the
   re-emit that drops it). So no fade is needed — exactly the seamless-scales position that
   fades on large terrain tiers are the wrong tool (WebGL2 sorting + double fill). The
   discipline is enforced, not assumed: every enter/leave logs `(fid, event, px_extent, θ_from_ĉ)`
   at fire time under the G-SSE-INV telemetry contract; the gate fails on any super-τ event.

The one place a *pop* could still occur is a **stale set during the async build** (≤ 1 build
latency at the trigger): the slack margin (15° fired at 13°) is sized so the old set still
contains the visible cap until the new set lands. The gate asserts containment at swap time.

## 6. LOD by distance

- **Far/high:** CELLS=4 (error 15–25 blocks) is sub-1px beyond ~21–35 k (DPR2) and the SN3
  clamp bounds depth; no coarser step is needed — the 61 k-tri cap is affordable at every
  distance (vertex cost, not fill, and it is one draw).
- **Near/low (the coarse band the seamless doc left open, ~1 k–10 k):** optional
  **`FP_SHELL_DENSE_CAP`** (S3): promote the ≤ `N_DENSE := 64` facets nearest the sub-camera
  point to the existing dense 16-cell grid (`_bpos_cache`, ≈12.5-block cells, error 4–7 blocks
  — the FULL_COVER backstop resolution, emitted **unsunk** when no near tier overlaps).
  Coverage ≈ 8×8 facets ≈ 1600-block square under the ground track. Budget: +64×480 =
  **+30.7 k tris / +92 k verts / +3.7 MB** worst, dense caches ≤ 64×8.1 KB ≈ **0.5 MB** —
  capped by count, hysteresis on membership, evict-to-coarse is a sub-2px event beyond ~2.8 k
  (logged like every set change). This reuses the dense cache + emit path FULL_COVER already
  ships; it is a role, not a new mesh.
- The near-field proper (0–~800 blocks) stays owned by pool + skin (+ pitch rings, C3) per
  seamless-scales; the shell never tries to be a near tier.

## 7. Color and light continuity

- **Colors:** `FarPalette` resolves every vertex color from `BlockCatalog.color_of` once
  (`far_palette.gd:36-56` — "NO hard-coded RGB") and mirrors worldgen's sea/ice/lava/snow
  predicates. A catalog recolor propagates to the shell by construction. Same palette at every
  altitude ⇒ the planet from orbit is the same planet as the horizon on foot.
- **Sun/terminator:** the shell material is a **lit** vertex-color material
  (`_make_material :757`; depth-biased variant under TIER-DEPTH P3). The ORBITAL_SKY
  DirectionalLight (−sun_dir from `CosmosEphemeris`) therefore paints the **day/night
  terminator across the globe automatically** — no new mechanism. Night side falls to the
  ambient floor; SN4a/b already ramp ambient/occlusion with altitude and eclipse. Headless
  assertable: terminator great-circle position on emitted vertices vs ephemeris sun dir ≤ 1°.
- Known accepted delta (unchanged from today's horizon): vertex-color albedo vs the textured
  near look; judged by the screenshot protocol, not re-litigated here.

## 8. Multi-body genericity

The shell *policy* (§3 law, §5 invariant, §6 dense cap) is pure math on `(R_body, d, ĉ)` —
already generic. The *implementation* hardcodes the home body (`FacetAtlas.K/R_BLOCKS`,
`TerrainConfig.profile_at_dir`). Rule for this design: **new constants and queries go through
per-body accessors** (`r_body` is already a parameter of `CosmosScale.scale_for`). The actual
extraction — a `BodyDescriptor {atlas params, sampler funnel, palette}` with one `FacetFarRing`
instance per body — lands with the MULTI_BODY/O4c milestone (the Moon's ring is already planned
there, built via `sample_columns` when d < ~120 k, impostor→ring handover sub-pixel per
SEAMLESS-SCALES §9). This doc adds S4 as that milestone's shell-side checklist, not new scope.

## 9. Staged, flag-gated plan + gates

Every flag default **false**; OFF ⇒ byte-identical (asserted); FLAT verify 6035/0 throughout;
flip-at-export only after its measured A/B (the standing rule).

| stage | flag | content | headless gates | live-only |
|---|---|---|---|---|
| S0 probe | (none — telemetry only) | log `emitted_count`, `_active_fid` vs camera radial fid, re-emit cadence via the existing farring event drain | — | 10-min orbit remote-drive: confirm R1/R2 signature (emitted set pinned while radial fid sweeps) |
| **S1 camera set** | `FP_SHELL_CAMERA_SET` | §3 law: ĉ-cull + θ_emit + drift trigger + surface floor; reuse warm/async/swap verbatim | **G-SHELL-COVER** (synthetic sweeps h ∈ {500, 2 k, 8 k, 30 k, 200 k} × longitudes incl. the spawn **antipode**: every facet containing a random dir within θ_h of ĉ is emitted — zero misses); **G-SHELL-ANTIPODE** (the pilot's repro headless: camera over the antipode at LEO ⇒ visible cap fully emitted); **G-SHELL-BOUND** (tris ≤ N(96°) ≈ 61 k; caches ≤ 3456·700 B); **G-SHELL-NOPOP** (every set change logged, enter/leave px < τ_pop, containment holds at swap); **G-SHELL-BYTEOFF** (flag off ⇒ `visible_fids()` byte-identical) | orbit soak: worst_ms flat through re-emits; limb screenshots |
| S2 prewarm | `FP_SHELL_PREWARM` | §4 one-shot background full-planet cache warm above OFFSURFACE_Y | warm completes ≤ N s headless; no frame over budget; byte ceiling 2.4 MB asserted; idempotence | ascent-to-orbit with zero warm-lag re-emits |
| S3 dense cap | `FP_SHELL_DENSE_CAP` | §6: ≤ 64 nearest facets at 16 cells, role precedence backstop>dense>coarse, hysteresis | bound gates (count/tris/bytes); role-precedence gate on a synthetic ascent (sunk while pool alive); set-change logging | mid-altitude (1–8 k) look A/B screenshots |
| S4 multi-body | (rides `MULTI_BODY`/O4c) | §8 BodyDescriptor extraction; Moon shell instance | per-body gate parity (COVER/BOUND parameterized by body) | Moon approach visual |
| fallback | (decision, not a flag) | if S1's re-emit churn fails its soak gate: switch the ring to the **indexed full-sphere** build (option B, ~4.8 MB, zero re-emits ever) | same COVER/BOUND gates, trivially satisfied | — |

**Limb tuning gate (S1, G-SHELL-LIMB):** analytic — for sample dirs at angular distance up to
90° + √(2·112/R) from ĉ, any terrain column whose relief rises above the camera's tangent
plane must lie in an emitted facet; oracle for `SHELL_RELIEF_DEG` / `SHELL_CAP_MAX_DEG` (96°
default, 105° pre-approved fallback at +1.0 MB).

**Dependencies:** S1 is standalone-correct below h ≈ 6.3 k; the full altitude range needs SN3's
`FP_SCALED_BODY` near/far ramp (R4) — already designed/landed behind its own flag. S2/S3 depend
on S1 only.

## 10. NEVER-OOM ledger (all deltas, worst case)

| item | bytes | draws | growth law |
|---|---|---|---|
| S1 emitted mesh @96° cap | ≤ 7.3 MB GPU (vs 6.6 shipped hemisphere ⇒ **Δ ≤ +0.7 MB**) | 1 (unchanged) | capped by N(θ_cap), flat vs time/altitude |
| S1/S2 full-planet CPU caches | 2.42 MB + 0.35 MB centre | 0 | hard cap 3456 fids; never evicted, never re-allocated |
| S3 dense cap | +3.7 MB mesh, +0.5 MB caches | 0 | hard cap N_DENSE = 64 |
| 105° limb fallback | +1.0 MB over 96° | 0 | constant |
| indexed full-sphere fallback (B) | ~4.8 MB total (replaces, not adds) | 1 | constant, zero rebuilds |
| telemetry (S0) | inside the existing bounded farring FIFO (16) | 0 | bounded FIFO |

No structure grows with orbit count, session length, or walk distance. All flags OFF ⇒ zero
bytes, byte-identical behaviour.

## 11. Risks and open decisions

| risk | exposure | mitigation |
|---|---|---|
| Re-emit churn at low orbit (≈ per-13°-arc async builds) contends with mesh workers / jank | worst_ms spikes during orbit | measured soak gate (S1); single-flight gate already exists; **pre-approved fallback: indexed full-sphere (zero re-emits, ~4.8 MB)** |
| Warm lag on first orbit pass over uncached longitudes (R3) | set trails ĉ for seconds | S2 prewarm (one-shot, bounded); until S2, the slack margin hides ≤ 1 build of staleness |
| Limb peaks culled at high distance (facet-centre test) | ≤ ~4 px silhouette nicks at d ≥ 21 k | G-SHELL-LIMB oracle; SHELL_RELIEF_DEG / 105° cap levers |
| Surface-regime behaviour change with flag ON | perf/look baseline shift while walking | §3 floor: θ_emit ≥ 90° below OFFSURFACE_Y ⇒ flag-ON surface set == shipped hemisphere |
| Sunk-role loss during ascent (near meshes persist above OFFSURFACE) | poke-through over the frozen pool | role precedence rule §5.1 + existing sticky/make-before-break gates re-run on a synthetic ascent |
| Thread-safety of a worker-thread prewarm through the GDScript funnel | data race class | v1 prewarm stays main-thread-budgeted; worker variant only after the L5 C++ funnel (purity contract) carries it |
| Two scale/placement writers (`apply_scaled_placement` per-frame vs re-emit transform writes) | transform fight above D_ENGAGE | re-emit writes go through `_placement_xform` exactly as shipped; the SN3 driver re-applies the clamp the same frame (ordering already exercised by SN3 gates) |

Open decisions for the user: **D-SH1** ship S1 alone first (fixes the reported hole) vs S1+S2
together (no warm lag) — recommendation: S1+S2, S2 is small; **D-SH2** dense cap (S3) now or
after the L5 batch sampler lands (cheaper warms) — recommendation: after; **D-SH3** τ_pop for
the set-change gate (share D-S1 of SEAMLESS-SCALES: 1 px default).

What this doc deliberately does not do: implement anything; add a second terrain
representation; change flag-off behaviour by one byte; re-litigate SN3's altitudes, the
FULL_COVER sink contract, or any locked keystone.
