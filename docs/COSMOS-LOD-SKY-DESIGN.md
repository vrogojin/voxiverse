# COSMOS-LOD-SKY-DESIGN — multi-body distance LOD + celestial lighting, phases, terminator

**Status:** design (no implementation in this pass). Branch `deploy/perf-plus-sky`, 2026-07-19.
**Scope:** overnight tasks 1+2 — (1) distance-driven surface LOD generic over bodies (Moon in the
sky → walkable-Moon feed, telescope-ready), (2) celestial lighting: sun terminator from surface AND
space, moon shine + real phases, the Rayleigh sunrise/sunset/terminator colour ramp.
**Parent designs honored, none re-litigated:** `COSMOS-SEAMLESS-SCALES-DESIGN.md` (SSE law §3,
overlap-not-fade, G-SSE-INV), `COSMOS-ORBITAL-SHELL-DESIGN.md` (camera-capped shell S1–S4),
`COSMOS-SPACE-NAV-DESIGN.md` (SN4a/b/c, BodySpec), `COSMOS-ORBITAL-O1O4-DESIGN.md` Part B (Moon
worldgen O4b, BODY_TABLE/O4c), the fixed frame, the one-sampler law.
**Locked constraints:** NEVER-OOM outranks visuals (fixed ceilings, every flag default-false,
OFF ⇒ byte-identical); seamless-scales (no pop anywhere on walk→fly→orbit); ~200-draw gl_compat
ceiling; no heavy volumetrics; multi-body genericity (no per-body hardcoding in the law).
**Numbers in this doc are for the CURRENT build:** R_BLOCKS = 6371, K = 24 ⇒ 3456 facets, facet
edge ≈ 417 blocks, CELLS=4 cell ≈ 104 blocks, BACKSTOP_CELLS=16 cell ≈ 26 blocks; natural ÷√1000
clock (DAY_GAME ≈ 2732.6 s ≈ 45.5 min); px thresholds at DPR2-1080p (K_px ≈ 1407), computed live
from the viewport in implementation (SEAMLESS-SCALES §3.1).

---

## 0. Executive summary

1. **The tier ladder already 80 % exists; this design completes it into a per-body LADDER with a
   single angular-size LAW.** Point → impostor sphere (shipped: CosmosSky's Moon) → per-body
   coarse far ring (shipped for Earth: FacetFarRing + FP_SHELL_CAMERA_SET) → dense cap
   (FP_SHELL_DENSE_CAP, designed) → skin (FP_SKIN_TIER, shipped) → voxel pool (shipped). What is
   NEW: the generic `BodyLod` selection law (§2), the Moon's ring instance riding O4c's
   BodyDescriptor (§3), and hard multi-body byte ceilings (§5). No new representation is invented
   anywhere — the law only decides WHICH existing tier a body presents.
2. **The Moon is already a lit, phased disc** — `cosmos_sky.gd` places a SHADED SphereMesh at the
   exact ephemeris angular size, lit by THE sun DirectionalLight, so phase + terminator
   orientation are automatic and already real-geometry-derived. At K_px = 1407 the Moon disc is
   ~13 px — phases are visible today with ORBITAL_SKY on. Task 2's "phases" therefore ships as a
   GATE (G-MOON-PHASE, §7.2) proving the shipped geometry equals (1+cos ψ)/2, not as new code.
3. **One scattering model, two vantage points.** A pure-static Rayleigh transmittance ramp
   T(μ) — three constants (τ_B, τ_G, τ_R), one air-mass formula — recolors (a) ground
   sunrise/sunset via Environment property writes and (b) the space-side terminator band via a
   per-vertex tint on the shell material, and (c) the SN4c limb shell when it lands. Deep blue →
   cyan → gold → orange → crimson emerges from exp(−τ·m(μ)) with real sea-level optical depths —
   no scripted gradient (§6). Zero bytes; the shell tint is the one VISUAL-RISK shader (P3
   precedent) with the StandardMaterial fallback retained permanently.
4. **Moon shine defaults to ambient modulation, NOT a second DirectionalLight.** In gl_compat,
   each additional per-pixel light renders lit geometry in an extra additive pass — a real second
   light could approach DOUBLING the ~200-draw budget. v0 (default): night ambient energy/tint
   scales with the ephemeris-derived illuminated fraction — zero draws, zero bytes. v1 (flagged,
   measured A/B): a real second light for actual moon-shadows-on-terrain (§7.3).
5. **NEVER-OOM ceiling (all of this doc + the shell doc, Earth + Moon resident, worst case):
   far-tier GPU+CPU total ≤ ~26 MB, held under a stated 32 MB global ceiling** with
   `N_RING_MAX = 2` resident rings, impostors O(bodies-in-table) ≤ 0.4 MB, dense/skin/pool
   dominant-body-exclusive. Nothing scales with planet area, session length, or body count
   beyond the table (§5).

## 1. Ground truth (verified in source, this branch)

| item | where | state |
|---|---|---|
| Sun impostor + THE DirectionalLight, ephemeris-driven | `cosmos_sky.gd:174-203, 263-292` | shipped under ORBITAL_SKY |
| Moon impostor: shaded sphere, exact angular size, lit ⇒ phase automatic | `cosmos_sky.gd:205-219, 279-284` | shipped under ORBITAL_SKY |
| Day/night env ramp + star dome + altitude ramp + occlusion dimmer | `cosmos_sky.gd:294-343` (SN4a/b flags) | shipped |
| Whole-Earth camera-capped shell, 1 draw, ≤ 61 k tris | `facet_far_ring.gd` + FP_SHELL_CAMERA_SET/PREWARM | shipped (S1/S2) |
| Scaled clamp s = min(1, D_ENGAGE/d), retire altitudes | `cosmos_scale.gd` (FP_SCALED_BODY) | shipped |
| Shell lit vertex-colour material ⇒ Earth terminator from orbit | shell doc §7 | free once lit |
| Moon worldgen kernel (craters/maria), BodyDescriptor, per-body ring | O4b/O4c plan | NOT built — this doc's M2 rides it |
| Ephemeris: real Sun/Earth/Moon positions, tidal lock, angular_diameter | `cosmos_ephemeris.gd` | shipped, f64, pure |

Known rescale caveat carried forward (not this doc's to fix): `CosmosSky.D_SKY = 8000` was sized
for R = 3072; at R = 6371 the impostors sit at only 1.26 R and inside the 9000 far plane's fog
band edge cases — the O3 revisit noted in `cosmos_sky.gd:26` should land with M1 (one constant).

## 2. The multi-body LOD law (`FP_BODY_LOD`) — angular size drives everything

Pure statics (`BodyLod`), no engine deps, evaluated per body per frame (≤ 8 bodies, trivial):

```
K_px            = viewport_height_device_px / (2·tan(fov/2))      # recomputed on resize AND zoom
ang_px(b, d)    = 2·R_b / d · K_px                                # the body's disc in device px
relief_px(b, d) = e_relief(b) / d · K_px                          # the impostor's max error in px

tier(b) =  POINT      if ang_px < P_POINT (2 px)                  # unshaded bright dot, phase moot
           IMPOSTOR   if relief_px < τ_pop (1 px)                 # shaded sphere, exact angular size
           RING       if relief_px ≥ τ_pop                        # the body's own FacetFarRing
plus, for the DOMINANT body only (the O4c pool-exclusive invariant):
           DENSE_CAP / SKIN / VOXEL per the existing SSE ladder (shell §6, seamless §4)
```

- `e_relief(b)` is a per-body constant in the BodyDescriptor: Earth ≈ 112 (max mountain), Moon ≈
  64 (crater kernel amplitude, O4b), Sun = 0 ⇒ the Sun is IMPOSTOR forever by the law itself —
  genericity, not special-casing.
- Every boundary carries ±25 % hysteresis + a min-dwell (anti-thrash, same discipline as the pool).
- Every transition logs `(body, from, to, d, relief_px)` under **G-SSE-INV**: a tier may only
  swap when its screen-space delta < τ_pop — the impostor⇄ring handover is sub-pixel **by the law
  that triggers it**, so no cross-fade is needed (seamless-scales §0.5: overlap/agreement, not
  fades).
- Derived Moon numbers (DPR2): disc 13 px at its 384.4 k orbit; relief_px = 1 at d ≈ 90 k ⇒ ring
  BUILD starts at `d < 120 k` (async, minutes of slack at any gear), handover fires at ~90 k
  sub-pixel, ring EVICTED (freed) at `d > 150 k` (25 % hysteresis). Earth from the Moon: disc
  ~47 px, relief_px < 1 beyond 158 k ⇒ Earth demotes to impostor during most of the transfer and
  re-promotes on return — the same law both directions.

**The telescope falls out of the law.** A telescope is an fov narrow (zoom) ⇒ K_px scales by the
zoom factor ⇒ `relief_px` of a distant body crosses τ_pop and the SAME machinery promotes it —
no telescope-specific LOD code. Byte-safety under zoom: `N_RING_MAX = 2` resident rings
(dominant + the largest-relief_px non-dominant); a third body stays IMPOSTOR even zoomed
(accepted v1 limit, stated on the HUD if ever hit). `FP_TELESCOPE` itself is only the input/fov
handling + K_px recompute; the LOD response is `FP_BODY_LOD` unchanged.

## 3. The per-body tier ladder + budgets (Earth numbers at R = 6371; Moon at R = 1737)

```
T-point   POINT     any body, ang < 2 px      ~0 B (reused quad/dot, ≤ 8 bodies)
T-imp     IMPOSTOR  CosmosSky shaded sphere    ~50 KB/body (32×16 SphereMesh + mat), exact angular size, lit
T-ring    RING      per-body FacetFarRing      camera-capped emit ≤ N(96°) tris, 1 draw, clamp via FP_SCALED_BODY
T-dense   DENSE_CAP ≤ 64 nearest facets @16c   shell §6 (S3) — dominant body only
T-skin    SKIN      FP_SKIN_TIER heightfield   ≤ 8 MB ceiling — dominant body only
T-vox     VOXEL     pool + near field          ≤ 128 MB pool — dominant body only (O4c invariant)
```

| tier item | Earth (K=24, 3456 f) | Moon (K=14, 1176 f — O4c) | growth law |
|---|---|---|---|
| ring emitted mesh (96° cap, tri-soup 40 B/vert) | ≤ 7.3 MB GPU (shell §2) | ≤ 2.5 MB GPU | capped by N(θ_cap); flat vs time/altitude |
| ring CPU caches (700 B/facet + centres) | 2.42 + 0.35 MB | 0.82 + 0.12 MB | hard cap 6·K² fids; never evicted while ring resident; FREED whole on ring evict |
| dense cap (≤ 64 facets @ 16 cells) | +3.7 MB mesh, +0.5 MB cache | same cap if dominant | N_DENSE = 64; dominant-exclusive |
| skin | ≤ 8 MB (existing ledger) | same ceiling if dominant | dominant-exclusive |
| impostor/point | ~50 KB | ~50 KB | O(body table), ≤ 8 bodies ⇒ ≤ 0.4 MB |

Resolution note at R = 6371: Earth CELLS=4 cell ≈ 104 blocks ⇒ ring error ≈ 30–50 blocks,
sub-1px beyond ~42–70 k — comfortably inside the regime where only the ring is resident
(POOL_RETIRE_H = 10 k, SKIN_RETIRE_H = 4 k). The dense cap (26-block cells, error 8–14) covers
the 1–12 k band under the ground track exactly as the shell doc designed; the ladder has no gap.
Moon K = 14 keeps its facet edge ≈ 195 blocks (same class as Earth's pre-rescale 201) so the O4b
sampler cost/facet and the warm budget carry over unchanged.

**Approach continuity (fly toward the Moon):** IMPOSTOR (exact silhouette) → ring lands async
sub-pixel at 90 k → the clamp reparameterizes it continuously (s = 1 at engage) → on SOI/dominant
swap the dense cap, skin, and pool run the SAME descent ladder as Earth re-entry (seamless §5.1,
"one re-entry path" — O1O4 §3.5's good half). Detail therefore increases GRADUALLY the whole way
by construction: each step is either sub-pixel at fire time or a continuous reparameterization.

**Depth order with multiple clamped bodies (eclipse geometry):** clamp distances are assigned
preserving true distance order (seamless §9 rule); the sky impostors at D_SKY always render
BEHIND any resident ring (impostor tier and ring tier for the same body never draw together —
make-before-break swap on the async build landing, logged).

## 4. What is genuinely NEW vs reused (the implementation surface)

1. **`BodyLod` statics** (new file, pure math): the §2 law + hysteresis + transition log. ~150
   lines, fully headless-gateable.
2. **BodyDescriptor** (O4c's object, shell doc §8): `{K, R, e_relief, sampler funnel, palette,
   has_atmo, h_nav_band}`. This doc adds `e_relief` and the impostor material params. The Moon
   ring is `FacetFarRing` instantiated with a descriptor — the shell policy (camera-set law,
   prewarm, progressive emit) is already pure math on `(R_body, d, ĉ)` and ports verbatim.
3. **Moon sampler**: `moon_profile_at_dir` (O4b kernel) behind the SAME one-sampler funnel —
   the ring's 25-sample warm and the future skin/pool all read it; the C++ `sample_dirs` batch
   twin covers it when L5's batch API lands (shell §4).
4. **The scattering ramp statics** (§6) + the shell tint uniform + the moonshine ambient term —
   all in/beside `cosmos_sky.gd`'s existing pure-static section (SN4 pattern).
5. NOT new: no new mesh representation, no new streaming system, no per-body render path.

## 5. NEVER-OOM ledger + the global ceiling

All deltas worst-case, all flags on, Earth dominant + Moon ring resident (the worst legal state):

| item | bytes | draws | growth law |
|---|---|---|---|
| Earth shell stack (already ledgered, shell §10) | 7.3 GPU + 2.77 CPU + 4.2 dense | 1 | shell doc caps |
| skin (existing) | ≤ 8 MB | ≤ ~6 merged | existing ceiling |
| Moon ring + caches (M2) | 2.5 GPU + 0.94 CPU | +1 | freed whole at evict (150 k); N_RING_MAX = 2 |
| impostors/points, all table bodies | ≤ 0.4 MB | ≤ 3 existing + ≤ 5 dots | O(table), table ≤ 8 |
| atmo shell (SN4c, when it lands) | ≤ 0.1 MB | +1 | one sphere |
| scattering ramp + phase gate + moonshine v0 | **0** (uniforms/property writes) | 0 | — |
| moonshine v1 second light | 0 bytes | **+1 additive pass over lit geometry** (§7.3 — the A/B) | — |
| telescope | 0 (fov + K_px recompute) | 0 | — |

**Global far-tier ceiling: 32 MB** (measured resident ≈ 26.2 MB worst above), asserted by
G-LOD-BYTES; the 128 MB pool is separate and dominant-body-exclusive as shipped. Rules that make
the ceiling structural, not aspirational: (a) rings are the ONLY per-body structure that scales
with facet count, capped by `N_RING_MAX = 2` + LRU-by-relief_px eviction with hysteresis;
(b) dense cap / skin / pool exist only for the dominant body; (c) impostor/point tiers are O(1)
reused nodes per table body; (d) no cache outlives its ring. Nothing scales with planet AREA:
facet counts are 6·K² constants chosen per body (K such that facet edge ∈ ~100–450 blocks).

## 6. The scattering model — real-data basis, one ramp, three consumers

**Physics (checked against real data):** the terminator band seen from orbit and the
sunrise/sunset seen from the ground are the same phenomenon — sunlight traversing air mass
m(μ) that grows from ~1 (overhead) to ~38 (horizon, Kasten–Young / Chapman), with Rayleigh
extinction σ ∝ λ⁻⁴ removing blue first. Sea-level vertical Rayleigh optical depths (real):
**τ ≈ (0.245, 0.098, 0.042) for B/G/R (440/550/680 nm)**. Per-channel direct-light transmittance
`T_c(μ) = exp(−τ_c · m(μ))` reproduces the observed progression with no hand-painted gradient:

| air mass m | μ ≈ sun elevation | T (R,G,B) | reads as |
|---|---|---|---|
| 2 | 30° | (0.92, 0.82, 0.61) | pale warm white |
| 5 | 11° | (0.81, 0.61, 0.29) | gold |
| 10 | 5° | (0.66, 0.37, 0.086) | orange |
| 20 | 2° | (0.43, 0.14, 0.007) | red |
| 38 | 0° (horizon/terminator line) | (0.20, 0.024, ~1e-4) | deep crimson |

The complementary SCATTERED component `S_c = 1 − exp(−τ_c · m_view)` (blue-dominant) is the blue
day sky and the blue limb from space; the deep blue of the twilight arch above the crimson band
gets one optional ozone (Chappuis) constant `τ_oz ≈ (0.016, 0.045, 0.006)` added to τ for the
twilight band only. Across the terminator into night the direct term fades through the SN4b
penumbra to the night floor. Band width on the globe: μ ∈ [−0.05, +0.25] ≈ 17° of arc ≈ 1900
blocks at R = 6371 — a soft band ~18 shell vertices wide (104-block cells), so PER-VERTEX
evaluation is smooth; no per-fragment work and no textures needed.

**Implementation, one pure-static ramp (`CosmosSky.scatter_tint(μ) -> Color`, C¹, gate-pinned)
consumed at three sites:**

- **(a) Ground sunrise/sunset (`SKY_SCATTER_RAMP`):** `_ramp_environment` upgrades its linear
  NIGHT→DAY twilight lerp: `fog_light_color`/horizon end of the background ramps through
  `scatter_tint(elev)`, ambient tint warms in the gold band. Environment property writes ONLY
  (the SN4a pattern) — zero bytes, zero shaders, safe class. Flag off ⇒ the shipped two-colour
  lerp byte-identical.
- **(b) Space-side terminator on the planet (`SHELL_TERMINATOR_TINT`):** the shell material gains
  a `sun_dir` uniform; per VERTEX μ = normalize(v_world)·sun_dir, `ALBEDO *= mix(1, scatter_tint(μ),
  band(μ))`. This is the ONE shader change — same class as the FP_TIER_DEPTH_BIAS lit
  vertex-colour shader (P3), which FAILED live once: **VISUAL RISK, screenshot-gated, default
  false, StandardMaterial fallback retained permanently** (fallback look = hard-lit terminator,
  still geometrically correct via the lit material — today's baseline). If P3's bias shader
  ships, ONE shader carries bias + tint (no second material variant).
- **(c) The SN4c limb shell** (when that stage lands): the same `scatter_tint` on the shell
  fragment's normal-vs-sun angle gives the blue limb + sunset band — SN4c's v2 "bespoke shader"
  inherits this ramp instead of inventing its own (one-model rule).

Because the ground ramp (a) and the space tint (b) are the SAME T(μ) evaluated at the same μ,
descending through the atmosphere the sky you see and the band you saw from orbit agree —
seamless-scales' "one model, two vantage points" holds by construction, and the altitude
composition is SN4a's existing space_mix authority blend (no new seam).

## 7. Celestial lighting — sun, moon shine, phases

### 7.1 Sun terminator, both vantages (already structural — assert, don't build)

THE DirectionalLight aims along −sun_dir from the ephemeris; every lit tier (voxels, skin, shell)
shades from the same light ⇒ the day/night hemisphere on the globe from orbit and day/night on
the ground ARE the same shading. No new mechanism; gate G-TERMINATOR asserts the terminator
great-circle on emitted shell vertices ⊥ sun_dir to ≤ 1° (shell §7 promised it; this doc ships
the gate), composed with SN4b so the night side reaches the umbra ambient floor.

### 7.2 Moon phases (`G-MOON-PHASE` — a gate, not a feature)

The shipped Moon impostor is a real sphere lit by the real sun light at the real ephemeris
geometry, so lit fraction AND terminator orientation are already exact. The gate derives, per
sampled t across ≥ 1 synodic month (game ≈ 29.5·DAY_GAME ≈ 22.4 h real; sample analytically, no
wall clock): ψ = angle between (sun−moon) and (earth−moon) from the f64 ephemeris, asserts
illuminated fraction `f = (1+cos ψ)/2` sweeps 0→1→0 with the synodic period, and asserts the
bright-limb position angle equals the projected sun direction. New/full moon EMERGE from the
orbit — nothing is scripted; the month is DAY_GAME-derived already. When close, the Moon ring is
lit by the same light ⇒ the surface terminator on approach is the impostor's terminator
continued — same model, third vantage point, asserted at the handover distance.

### 7.3 Moon shine (`SKY_MOONSHINE`, + `SKY_MOONSHINE_LIGHT` v1)

- **v0 (default when flag on): ambient moonlight, zero draws.** At night authority
  (1 − twilight), ambient energy gains `MOONSHINE_GAIN(≈ 0.5) · f · moon_up` over the night
  floor, tinted cool (0.75, 0.80, 1.00); `moon_up = clamp(moon_dir·up, 0, 1)`. Full moon ⇒
  meaningfully brighter night; new moon ⇒ the shipped floor exactly. Composes under SN4a/b
  authorities. **Lunar eclipse for free:** reuse `occlusion_factor` with the MOON as observer vs
  Earth's sphere — one scalar dims f and visibly reddens the disc (multiply the impostor albedo
  by the §6 ramp's deep-red — the real umbra colour, same physics).
- **v1 (separate flag, measured A/B): a real second DirectionalLight** along −moon_dir, energy
  `MOON_LIGHT_MAX(0.08) · f · night_authority`. **The cost is draws, not bytes:** gl_compat
  renders extra per-pixel lights as an additive pass over lit geometry — worst case approaches
  doubling the lit-surface share of the ~200-draw budget. Default OFF even at export until the
  live draw-count/worst-frame A/B passes; v0 is the permanent fallback.

## 8. No-pop composition with the existing flags

| boundary | mechanism | why no pop |
|---|---|---|
| impostor ⇄ ring (any body) | law fires at relief_px < τ_pop; async build, make-before-break swap | sub-pixel at fire time, G-SSE-INV logged |
| ring under clamp | FP_SCALED_BODY s = min(1, D_ENGAGE/d) | C0 reparameterization, no switch (shipped) |
| ring ⇄ dense cap ⇄ skin ⇄ voxel | existing shell/seamless ladder | already designed/gated there |
| lighting across altitude | SN4a space_mix authority blends every new term (moonshine, scatter) | all terms C¹ in h and μ |
| tint across terminator | scatter_tint C¹, band() smoothstep, penumbra SN4b | no hard line anywhere |
| day↔night, stars, sky | shipped elevation ramp unchanged; new terms multiply/compose | flag-off byte-identical |

## 9. Staged, flag-gated plan (every flag default false, OFF ⇒ byte-identical, FLAT 6035/0)

| stage | flag | content | headless gates | live-only |
|---|---|---|---|---|
| L0 | (none) | G-MOON-PHASE + G-TERMINATOR gates on SHIPPED geometry | phase fraction + limb angle vs ephemeris across a synodic month; terminator ⊥ sun_dir ≤ 1° | — |
| L1 | `SKY_MOONSHINE` (+`SKY_MOONSHINE_LIGHT` v1) | §7.3 ambient moonlight + lunar-eclipse dim/redden; v1 light separate | G-MOONSHINE: energy = gain·f·night·moon_up, 0 at new moon/day, monotone, C¹; eclipse factor 0/1/monotone | night look; v1 draw-count A/B |
| L2 | `SKY_SCATTER_RAMP` | §6a ground sunrise/sunset via Environment writes | G-SCATTER: T(μ) endpoints, monotone red-ward hue as μ↓, C¹, band-off identity to shipped colours | sunset screenshot pass |
| L3 | `SHELL_TERMINATOR_TINT` | §6b shell vertex tint (VISUAL RISK) | G-TINT: tint == scatter_tint at sampled μ; flag-off shader absent byte-identical | **mandatory screenshot gate** (P3 precedent); fallback StandardMaterial |
| M1 | `FP_BODY_LOD` | §2 BodyLod law + hysteresis + logging (drives the EXISTING impostor only, v1) | G-LOD-LAW: tier table over synthetic (R, e_relief, d, K_px); hysteresis no-thrash; G-SSE-INV zero super-τ transitions on synthetic approach | — |
| M2 | `FP_MOON_RING` (rides O4c `MULTI_BODY`) | Moon FacetFarRing via BodyDescriptor (K=14) + O4b sampler + clamp depth order + build/evict triggers | G-LOD-BYTES (global 32 MB, Earth+Moon resident); ring parity gates (shell COVER/BOUND parameterized by body); evict frees caches (lifetime cap) | Moon approach visual; handover screenshot |
| M3 | (shell S3 `FP_SHELL_DENSE_CAP`) | per-body dense cap — already designed; M2 makes it body-parameterized | shell doc gates re-run with body param | mid-altitude look |
| M4 | `FP_TELESCOPE` | fov zoom + live K_px recompute; law does the rest | G-SCOPE: synthetic zoom promotes per law; N_RING_MAX binds; budgets hold under max zoom | zoom feel; distant-body look |

Order: **L0 immediately** (pure gates, zero risk, certifies task 2's core claims on shipped
code); L1+L2 next (zero-byte, safe class); M1 parallel (pure math); L3 after L2's ramp is
gate-pinned; M2 blocks on O4b/O4c (the walkable-Moon effort) — its LOD-side spec is complete
here; M4 anytime after M1. Dependencies stated per stage; nothing here blocks the shell or nav
streams.

## 10. Headless-provable vs live-only (the split)

**Headless:** every law, curve, budget, and geometry claim — the LOD tier function + hysteresis;
byte ceilings incl. Earth+Moon residency + eviction; phase fraction/limb angle vs ephemeris;
terminator great-circle; scatter ramp values/monotonicity/C¹; moonshine/eclipse scalars;
flag-off byte-identity for every flag; no-pop transition logs on synthetic approaches; K_px
recompute under synthetic zoom.
**Live-only:** every LOOK — sunset/terminator/limb colours (screenshot protocol), the shell tint
rendering correctly under gl_compat (the P3 failure class), moonshine feel, v1 second-light
draw-count/worst-frame A/B, Moon-approach visual continuity, telescope feel.

## 11. Risks and open decisions

| risk | exposure | mitigation |
|---|---|---|
| Shell tint shader wrong/flat on compat (P3 precedent) | space terminator band | L3 default-false, screenshot-gated, StandardMaterial fallback permanent; geometry terminator correct either way |
| v1 moon light doubles lit-geometry draws | worst-frame on weak GPUs | v0 ambient default; v1 behind its own flag + measured A/B, may never ship |
| Moon ring rides O4b/O4c which haven't landed | M2 timing | M1/L-stages are independent; M2's LOD spec is complete here so O4c implements once |
| D_SKY = 8000 vs R = 6371 (impostor placement margin) | sky look post-rescale | one-constant O3 revisit bundled into M1 |
| Ramp constants read wrong on unusual displays | tint too strong/weak | constants named, gate-pinned, judged by the screenshot pass; K_px live-computed |
| Telescope promotes rings beyond budget | byte ceiling | N_RING_MAX structural; third body stays impostor (stated v1 limit) |

Open decisions for the user: **D-LS1** moonshine v0 gain (0.5 of night floor — taste);
**D-LS2** ozone term in the twilight band on/off (slightly deeper blue arch, one constant);
**D-LS3** whether the POINT tier renders mag-faded dots for sub-2px bodies or nothing (cosmetic).

What this doc deliberately does not do: implement anything; invent a second terrain or sky
representation; change any flag-off byte; re-litigate shell/seamless/nav keystones; design the
Moon's worldgen (O4b owns it) or the dominant-body swap (O4c owns it).
