# COSMOS-SPACE-NAV-DESIGN — the five-frame navigation continuum, atmosphere/sun, dev-nav, and the walkable Moon

Status: **IMPLEMENTATION-READY DESIGN** (Fable, 2026-07-18). Branch `feat/voxiverse-spacenav`
(off `deploy/perf-plus-sky` @ 27cb9a1). This is the architecture for the user's space-navigation
spec: the frame-mode state machine (planetary → low orbit → high orbit → deep space →
interstellar), seamless velocity/position handoffs, atmosphere+sun rendering under
gl_compatibility, the dev-nav (F) overlay system, and the Moon as a second walkable planet.

Parents (consumed, reconciled, and where stated **amended**):
- docs/COSMOS-ORBITAL-DESIGN.md — the user-signed scale/time/mass model (D2: ÷1000 lengths,
  20-min day, GM_game = GM_real × 5.184e-6). NOT re-litigated.
- docs/COSMOS-ORBITAL-O1O4-DESIGN.md (branch `feat/voxiverse-orbital` @ 9727be9) — O1 orbit
  mechanics + O4 walkable Moon. **Adopted as the mechanics substrate**, with the amendments in §2.
- docs/COSMOS-SEAMLESS-SCALES-DESIGN.md — the SSE law + the scaled-body clamp that REPLACES
  O1O4's H_FARSWAP impostor swap. Its rejections are inherited here as final.
- docs/COSMOS-FIXED-FRAME-DESIGN.md, COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md — keystones, untouched.

Locked requirement (memory `voxiverse-seamless-scales`, verbatim intent): walking → flying →
orbiting → interplanetary is ONE continuum; no stitches or jumps at facet crossings or the
atmosphere↔space border; frame handoffs preserve position+velocity with no visible pop.

---

## 0. Executive summary

1. **One physical truth, five expressions.** The player's physical state is ALWAYS one f64
   `[pos, vel]` pair in the deepest-SOI body's body-centred-inertial (BCI) frame — the O1O4
   `OrbitalState`, integrated symplectically, frozen to Kepler when coasting. The user's five
   navigation modes (**planetary / low orbit / high orbit / deep space / interstellar**) are NOT
   five physics regimes: they are five *re-expressions* of that one state — each mode names the
   reference frame in which controls, HUD velocity, and dev-flight "hold position" are defined.
   Because every re-expression is an exact affine map (`v_frame = A(t)·v_bci + b(p,t)`, pure f64),
   **a mode transition cannot teleport or jerk by construction**: the physical state is untouched;
   only the frame in which it is *read* changes. Seamlessness stops being an implementation goal
   and becomes a theorem with a gate (§5.4).
2. **The classifier is a priority-ordered decision list** over four f64 scalars — altitude `h`,
   orbital-speed ratio `u = |v_bci|/v_circ(r)`, gravity fraction `γ = (R/r)²`, solar-speed ratio
   `s = |v_helio|/v_sol` — with the user's exact thresholds (25 % / 200 % orbital speed, 200 %
   diameter vicinity, 1 % surface gravity, solar / 10× solar speed), two spec ambiguities resolved
   (§4.2), one necessary amendment (geostationary must classify HIGH_ORBIT — §4.4), multiplicative
   hysteresis (±10 % speeds, ±5 % radii, +32 blocks atmosphere) and a 2-s dwell (§4.5).
3. **The pre-resize scale trap is real and is resolved here** (§3): the shipped ephemeris Earth is
   R = 6371 but the voxel Earth is R = 3072, and using the Kepler-locked GM at the voxel radius
   makes datum gravity 219 m/s² and pushes geostationary outside the 1 %-gravity radius. Fix: a
   **dynamics GM** `GM_dyn(body) = GM_game(body)·(R_vox/R_eph)³` — exactly the parent's D1(b)
   ratio-scaling applied only to *local player dynamics*, collapsing to a no-op the moment the D1(a)
   resize (O3) lands. The sky/ephemeris keeps GM_game untouched (calendar locked). The Moon needs
   no interim scaling (its voxel R 1737 IS its ephemeris R).
4. **Rendering is built-in-first** (§6): the sun light, day-night, moon impostor and star dome are
   ALREADY SHIPPED (`cosmos_sky.gd`, flag `ORBITAL_SKY`); this design adds altitude-driven
   Environment ramps (fog/sky→black/stars — all built-in properties), an **analytic sun-occlusion
   dimmer** (pure f64 sphere test driving `light_energy` — no shadow maps), and — the ONE visual
   risk — an optional atmosphere shell, tried as StandardMaterial3D first, bespoke shader only
   behind a live-screenshot gate with the ramp-only look as the shipped fallback. The P3
   depth-bias shader failure is the standing cautionary tale.
5. **Dev-nav (F)** (§7) is a per-mode overlay + control layer: compass + facet borders
   (planetary), 25 %-orbital-speed frame-relative flight + O = circular-orbit release (low orbit),
   + G = geostationary snap and R = frame detach (high orbit), body labels with distance/direction
   everywhere. All overlays are Control-layer drawing or unshaded vertex-colour line meshes — no
   lit spatial shaders anywhere near it.
6. **The Moon rides O1O4 Part B verbatim** (§8) — global fid namespace, equivalence gate, dark
   O4b, SOI swap O4c — with two additions: the Moon's *classification* atmosphere band is 256
   blocks (mode machine only; no drag, no fog — it has no atmosphere), and landing uses the
   airless-body PREWARM 4096 (D-O4-5). Walk parity with Earth is by construction (same locomotion
   machine, feel-g hook s = 0.165) and asserted by gate.
7. Phase order per the orchestrator (§10): **mechanics core first** (SN1 orbital substrate → SN2
   nav-mode machine → SN3 scaled-body/camera continuity), **atmosphere/sun + dev-nav after** (SN4,
   SN5), **walkable Moon last** (SN6, gated on the rest landing solid). Every phase: new flag
   default-false, main byte-identical, NEVER-OOM ledgered, headless gate stated, live-only
   residue stated.

## 1. Ground truth — what is ALREADY shipped on this branch (verified in source)

- **CosmosEphemeris** (`godot/src/cosmos/cosmos_ephemeris.gd`) — the pure-f64 kernel: `BODIES`
  table (sun/earth/moon: gm_real, r, parent, a, m0, spin, tidal), `gm_game()` (× 5.184e-6),
  `omega_orbit/spin`, `body_pos_parent/helio`, `spin_angle` (tidal = orbit + π),
  `dir_to_bodyfixed` (R_z(−spin)·d, spin axis **+Z**), `angular_diameter`, `sub_longitude`,
  `CosmosClock` (the one mutable float). Engine-free, worker-safe, gate-tested.
- **CosmosSky** (`cosmos_sky.gd`, flag `ORBITAL_SKY` — cube_sphere.gd:516) — Sun impostor + THE
  DirectionalLight3D (shadows off, D11), shaded Moon impostor (phase for free), additive
  procedural star dome (`star_fade` uniform, live-validated), day-night Environment ramp
  (`_ramp_environment`: background/fog colour + ambient energy from sun elevation). Impostors at
  `D_SKY = 8000`, camera-relative, fog-disabled.
- **The faceted planet + fixed frame**: `FacetAtlas` K = 24, R_BLOCKS = 3072 (facet_atlas.gd:12-13);
  `facet_of_dir` (facet_atlas.gd:664, comment reserves "full off-facet gravity/locomotion is
  FP-M3"), `lattice_to_world64/world_to_lattice64` (282/291), `facet_normal64` (329),
  `frame_basis` (620), `edit_key` fid-multiplicative packing (66). ActiveFrame + FrameAdapter
  (world_manager.gd:218-236, player.gd:60,88), anchor `_anchor_offset` +
  `REANCHOR_TRIGGER_BLOCKS = 8192` (cube_sphere.gd:424), `OFFSURFACE_Y = 256` pool freeze
  (cube_sphere.gd:363), far ring `CAMERA_FAR = 9000` (facet_far_ring.gd:22).
- **Player** (`player/player.gd`): SURFACE analytic walk + FLY lattice noclip (F key, line 240),
  feel gravity 22 + the per-body feel hook (lines 90-99), FrameAdapter-routed physics boundaries,
  remote-drive intent seam (the live-loop test harness).
- **Worldgen choke point**: `TerrainConfig.profile_at_dir/facet_profile/resolve_cell` — the
  one-sampler law holds; `FP_CPPGEN` (VoxelGeneratorCosmos) is the compiled twin (cube_sphere.gd:190).
- **NOT implemented anywhere**: `FP_M3_ORBIT` (CosmosGravity, OrbitalState, ORBITAL mode),
  `MULTI_BODY`, `FP_SCALED_BODY`, any nav-mode machinery. Those are this design's scope, with
  O1O4 as the blueprint for the first and last.

## 2. Reconciliation ledger — every conflict with the parent designs, named

| # | Parent decision | Status here |
|---|---|---|
| R1 | O1O4 §2.1/§2.8 `H_FARSWAP := 20000` — above it retire pool + far ring, render the home body as a sphere impostor, rebuild-with-veil on descent | **REJECTED** (was already retracted by SEAMLESS-SCALES §0.1/§5). Replaced by SN3: far-ring persistence + the continuous scaled clamp `s = min(1, D_ENGAGE/d)` + SSE-scheduled retire/rebuild. The `H_FARSWAP` const is never created. |
| R2 | O1O4 §2.8 anchor-follow (integer steps, ActiveFrame pinned to −anchor in orbit) | **ADOPTED** unchanged — it is orthogonal to the impostor question and G-O1-ANCHOR still gates it. |
| R3 | O1O4 §3.5 "SOI swap imperceptible *because* nothing voxel-scale exists above H_FARSWAP" | Argument dead with R1; conclusion re-derived per SEAMLESS-SCALES §9: imperceptible because every resident tier is sub-pixel at SOI range (G-SSE-INV). Moon far ring is built by **angular-size trigger** (d < ~120 k, hysteresis 25 %), not by an H_FARSWAP descent event. |
| R4 | O1O4 §2.5 player modes {SURFACE, FLY, ORBITAL}, FLY→ORBITAL latch at H_BLEND_HI ± 32 | **ADOPTED** as the LOCOMOTION machine. The user's five modes are NOT new locomotion modes — they are the NAV-FRAME machine layered above it (§4.1). No conflict once the two machines are named. |
| R5 | O1O4 §2.2 gravity blend band 22 → GM/(R+h)², §2.6 drag D10, §2.7 re-entry prewarm, §2.3 OrbitalState, §2.4 frame algebra | **ADOPTED** verbatim as SN1, with GM read through `GM_dyn` (§3) — at the shipped R = 3072 the blend lands 22 → ~18 (gentle), post-O3 22 → 43.6 (the parent's number). |
| R6 | O1O4 §3 (Part B Moon: fid namespace, G-O4-EQ, worldgen, SOI swap, staging O4a→O4c) | **ADOPTED** verbatim as SN6, plus the 256-block classification band (§8.2) and the D-O4-5 PREWARM 4096 recommendation confirmed. |
| R7 | Parent ORBITAL-DESIGN D1 (resize R = 6371, K = 50) staged as O3 | **UNCHANGED and now load-bearing**: §3's GM_dyn makes every SN phase correct-shaped at 3072, but O3 must land **before O4c** (Moon travel) exactly as the parent staged — the interim GM_dyn is inconsistent with the on-rails Moon's period at lunar distance, which is harmless only while the Moon is unreachable. |
| R8 | SEAMLESS-SCALES C2/C4/C5 (scaled clamp, SSE scheduler, atmosphere visual ramp) | **ADOPTED**: C2+adaptive near/far = SN3; C5 = SN4a. C4 (full SSE scheduler) is NOT a dependency of the nav mechanics — SN3 ships the clamp + persistence with fixed conservative retire altitudes; the SSE scheduler upgrades it later without interface change. |
| R9 | O1O4 §2.5 "Gear 3 ships with O4c" + parent D5 (a_C 0.2–0.5 m/s²) | **ADOPTED** unchanged (gear-3 in SN6c). |

## 3. The scale bridge — GM_dyn (the one new scale decision, D-SN-2)

**The trap.** `CosmosEphemeris.BODIES` carries the REAL Earth (R 6371, GM_game 2.066e9); the voxel
Earth is R_BLOCKS = 3072. Using GM_game raw at the voxel radius: datum gravity GM/R² = **219 m/s²**
(10× the feel-22), datum orbital speed 820 m/s, and geostationary
`r_geo = (GM/ω²)^{1/3} = 42,240` sits OUTSIDE the 1 %-gravity radius `10R = 30,720` — the user's
own thresholds then classify a geostationary orbit as *deep space*, which breaks the G-key spec.

**The fix.** All *local dynamics* (gravity field, orbital integration, the mode classifier's
v_circ/γ, SOI radii, r_geo) read:

```
GM_dyn(body) = CosmosEphemeris.gm_game(body) × (R_vox(body) / R_eph(body))³
```

where `R_vox` is the walkable body's voxel radius (FacetAtlas: Earth 3072 today, Moon 1737) and
`R_eph` the ephemeris radius (6371 / 1737). Properties, all load-bearing:

- **Kepler-shape-exact at the voxel surface**: lengths scale by k = R_vox/R_eph, GM by k³ ⇒ all
  periods preserved, all speeds scale by k, all dimensionless ratios (γ at n·R, u, orbits/day)
  exactly real. Datum gravity = 50.9·k = **24.6 m/s²** at 3072 — a *gentle* blend from feel-22.
- **r_geo_dyn = 42,240·k = 20,370 < 10R = 30,720** ⇒ geostationary classifies HIGH_ORBIT at the
  shipped radius too (the §4.4 amendment then only guards the corner cases).
- **Collapses to identity post-O3**: R_vox = R_eph = 6371 ⇒ GM_dyn ≡ GM_game. No flag day, no
  code change at the resize — the formula is the migration.
- **The Moon is already exact**: R_vox = R_eph = 1737 ⇒ GM_dyn ≡ GM_game from day one.
- **The sky is untouched**: CosmosEphemeris keeps GM_game + real÷1000 distances — the 20-min day,
  9.11-h month, angular sizes, eclipse geometry all stay locked. The one inconsistency: a *player*
  at lunar-distance r under GM_dyn does not orbit with the on-rails Moon's period. Confined to
  r ≫ 10R where the nav frame is heliocentric anyway, and eliminated by O3 before the Moon is
  reachable (R7). Disclosed, gated (G-SN-SCALE asserts GM_dyn == GM_game when R_vox == R_eph).

Derived numbers used throughout (Earth: interim R = 3072 / post-O3 R = 6371):

| Quantity | Formula | Interim (3072) | Post-O3 (6371) |
|---|---|---|---|
| GM_dyn | GM_game·k³ | 2.317e8 | 2.066e9 |
| Datum circular speed | √(GM_dyn/R) | 274.6 m/s | 570 m/s |
| Datum escape | √2 × above | 388 m/s | 805 m/s |
| Datum gravity | GM_dyn/R² | 24.6 m/s² | 50.9 m/s² |
| Equatorial spin speed | ω·R, ω = 2π/1200 | 16.1 m/s | 33.4 m/s |
| Geostationary r_geo | (GM_dyn/ω²)^{1/3} | 20,370 | 42,240 |
| Vicinity 4R (§4) | 4·R_vox | 12,288 | 25,484 |
| 1 %-gravity radius 10R | 10·R_vox | 30,720 | 63,710 |
| Earth SOI (dyn) | a·(GM_dyn/GM_sun)^{2/5} | ~385 k | ~925 k |
| Moon: datum circ / escape / feel g | — | 121 / 171 m/s, g 3.6 | same |
| Moon selenostationary | (GM_moon/ω_moon²)^{1/3} ≈ 88.5 k | **> Moon SOI 66.1 k ⇒ does not exist** | same |
| Solar orbital speed at Earth | √(GM_sun_game/a_E) | 2,145 m/s | same |

## 4. The nav-frame state machine (the user's five modes)

### 4.1 Two machines, cleanly separated (the architecture keystone)

- **Locomotion machine** (O1O4 §2.5, adopted): `PMode { SURFACE, FLY, ORBITAL }` — *how the player
  integrates*. SURFACE/FLY below the blend band are byte-identical shipped code; ORBITAL carries
  the f64 OrbitalState (symplectic + thrust + drag, freeze-to-Kepler).
- **Nav-frame machine** (NEW, this design): `NavMode { PLANETARY, LOW_ORBIT, HIGH_ORBIT,
  DEEP_SPACE, INTERSTELLAR }` — *which reference frame controls/HUD/dev-flight are expressed in*.
  A pure classifier over the f64 state + hysteresis wrapper. It **never touches the scene graph,
  never moves geometry, never mutates the physical state** — its outputs are: (a) the control
  carrier frame for dev-flight (§7.2), (b) the HUD velocity frame, (c) the dev-nav overlay set +
  available toggles, (d) telemetry fields.

The scene/render frame is a THIRD, independent thing (per the fixed-frame keystone): the deepest-
SOI *walkable* body's body-fixed frame (planet pinned at identity, sky moves), or heliocentric
anchor-follow when the dominant body has no voxel presence (the Sun). Scene-frame changes happen
ONLY at SOI swaps (SN6c/O4c machinery) — **never at nav-mode changes**. This is what makes nav
transitions structurally popless: they are HUD/controller re-expressions of an untouched state.

### 4.2 The classifier inputs (all f64, per physics tick, body = deepest dynamic SOI)

```
r        = |p_bci|                         # distance to dominant body centre
h        = r − R_vox(body)                 # radial altitude (the O1O4 §2.1 definition)
v_circ(r)= sqrt(GM_dyn(body)/r)            # local circular orbital speed AT CURRENT r
u        = |v_bci| / v_circ(r)             # orbital-speed ratio
γ        = (R_vox/r)²                      # gravity fraction of surface gravity (GM cancels)
r_helio  = |p_helio|;  s = |v_helio| / sqrt(GM_sun_game/r_helio)   # solar-speed ratio
H_ATMO(body)                                # Earth 384 (ATMO_TOP); Moon 256 (§8.2); else 0
```

Two spec ambiguities, resolved (called out for the user, D-SN-1):
1. *"suborbital < 25 % orbital speed"* taken literally misfires far away (a coasting observer at
   100R has tiny v_circ-relative… no — v_circ is small there, but a *stationary* observer has
   u ≈ 0 < 0.25 ⇒ "planetary" at any distance). The speed clause is therefore **gated by the
   vicinity radius**: it can only fire at r ≤ 4R. Intent preserved: a slow craft *near* the planet
   is suborbital (it will fall back); a slow craft far away is not "planetary" in any sense.
2. *"vicinity = ≤ 200 % planet diameter"* is measured **from the body centre**: r ≤ 2·(2R) = 4R.
   (The alternative — altitude ≤ 4R ⇒ r ≤ 5R — changes nothing structurally; one const.)

### 4.3 The decision list (first match wins; raw classification, pre-hysteresis)

```
1. PLANETARY      h < H_ATMO(body)                    # inside the atmosphere band
                  or (r ≤ 4R and u < 0.25)            # suborbital in the vicinity
2. LOW_ORBIT      r ≤ 4R                              # in the vicinity, super-suborbital
                  or (γ > 0.01 and u < 2.0)           # bound-ish flight inside the gravity well
3. HIGH_ORBIT     γ > 0.01                            # gravity > 1 % of surface
                  or r ≤ 1.2·r_geo_dyn                # the geostationary guard (§4.4)
                  or (u ≥ 2.0 and s < 1.0)            # hyperbolic escape, still sub-solar-speed
4. DEEP_SPACE     r_helio ≤ R_SYSTEM (≈ 6e9 ≈ 40 AU)  # within the solar system
                  or s < 10.0                         # < 10× solar orbital speed
5. INTERSTELLAR   (else)
```

Frames assigned: PLANETARY → body-fixed rotating (surface) frame; LOW_ORBIT and HIGH_ORBIT →
body-centred inertial (planet centre, non-rotating — the SAME frame; the two modes differ only in
dev-nav feature set, exactly per the user's spec); DEEP_SPACE → heliocentric inertial;
INTERSTELLAR → the observer itself (attitude retained; HUD speed reads 0 or last-frame-relative).

Sanity table (Earth, interim radii; each row asserted by G-SN-CLASS):

| Situation | h | u | γ | → mode |
|---|---|---|---|---|
| Standing on the surface (equator) | 0 | 0.06 | 1.0 | PLANETARY (atmo) |
| Hovering at h = 500 (above atmo) | 500 | 0.07 | 0.74 | PLANETARY (vicinity + slow) |
| LEO circular at h = 500 | 500 | 1.0 | 0.74 | LOW_ORBIT |
| Circular at r = 5R | — | 1.0 | 0.04 | LOW_ORBIT (γ-gated speed clause) |
| Geostationary (r_geo = 6.6R interim) | — | 1.0 | 0.023 | HIGH_ORBIT (γ; guard redundant here) |
| Circular at r = 12R | — | 1.0 | 0.007 | DEEP_SPACE (per the user's own thresholds) |
| Hyperbolic escape at r = 20R, v = 2.5·v_circ, s < 1 | — | 2.5 | 0.0025 | HIGH_ORBIT (speed clause) |
| Coasting at Earth's solar orbit, far from Earth | — | — | ~0 | DEEP_SPACE |
| s ≥ 10 beyond 40 AU | — | — | 0 | INTERSTELLAR |

Note the r = 12R row: dynamically still Earth-bound (inside the SOI), but the user's locked
thresholds put it in DEEP_SPACE — and that is FINE, because the nav mode only changes what the
HUD/controls express; the *integrator* keeps the patched-conic dominant body (§4.1), so physics
stays exact. This is precisely why the two machines must not be conflated.

### 4.4 The geostationary amendment (the one deliberate spec deviation)

The G key (§7.4) requires geostationary to be reachable *in the planetary frame* — i.e. classify
HIGH_ORBIT. Post-O3 that is automatic (r_geo = 42,240 < 10R = 63,710); with GM_dyn it also holds
interim (20,370 < 30,720). But it is fragile at the boundary (a body with a slower spin has a
larger r_geo; the Moon's exceeds its SOI). The added clause `r ≤ 1.2·r_geo_dyn` in rule 3 makes
"the radius at which the body's own spin defines a stationary orbit" always planet-frame territory,
independent of the 1 % coincidence. For bodies where r_geo > SOI (the Moon), the clause is capped:
`min(1.2·r_geo_dyn, 0.9·R_SOI)` — and the G key reports "no stationary orbit exists" (§7.4).

### 4.5 Hysteresis + dwell (no flip-flop at boundaries)

A transition OUT of the current mode fires only when the raw classifier has produced a *different*
mode continuously for `NAV_DWELL_S = 2.0` s, AND every threshold separating the two modes is
crossed by its margin: speed ratios ×(1 ± 0.10) (u: leave PLANETARY above 0.275, re-enter below
0.225; the 2.0 boundary at 2.2/1.8; s at 1.05/0.95, 10.5/9.5), radii ×(1 ± 0.05) (4R, 10R,
1.2·r_geo, R_SYSTEM), atmosphere ± 32 blocks absolute (the O1O4 band). Implementation: the
classifier takes the incumbent mode and applies the margins in the incumbent's favour — one pure
function `NavKernel.classify(state, incumbent) → mode`, trivially table-gated. Because transitions
are lossless (§5), flapping would only ever be a cosmetic HUD flicker — the dwell exists for UX,
not correctness, so 2 s is safe.

An explicit **R-detach latch** (§7.4) can force DEEP_SPACE expression from HIGH_ORBIT; it is a
manual override bit the classifier respects until cleared (R again, or a natural transition).

## 5. The seamless handoff math (per transition — the crux)

### 5.1 The frame maps (all pure f64; θ = spin_angle(body,t), ω⃗ = ω ẑ; O1O4 §2.4 algebra)

```
SURFACE(rotating, body-fixed axes):  p_fix = R_z(−θ)·p_bci
                                     v_fix = R_z(−θ)·(v_bci − ω⃗ × p_bci)
BCI  (planet-centred inertial):      identity (the storage frame)
HELIO(sun-centred inertial):         p_hel = p_bci + body_pos_helio(body,t)
                                     v_hel = v_bci + body_vel_helio(body,t)     # circular: a·n·t̂, closed form
SELF (interstellar):                 no positional frame; HUD v := 0 (attitude kept)
```

`body_vel_helio` is one NEW ephemeris accessor (closed-form derivative of `body_pos_helio` —
circular v1: `a·n·(−sin θ_o, cos θ_o, 0)` chained through parents). Everything else exists.

### 5.2 The transitions, exhaustively

| Transition | Velocity re-expression | New machinery |
|---|---|---|
| PLANETARY ↔ LOW_ORBIT | v_fix ↔ v_bci: the ω⃗×p term (16.1 m/s interim / 33.4 post-O3 at the equator — the eastward-launch bonus, O1O4 G-O1-HANDOFF's pinned number) | none (O1O4 §2.4) |
| LOW_ORBIT ↔ HIGH_ORBIT | **identity** (same BCI frame; only the dev-nav feature set changes) | none |
| HIGH_ORBIT ↔ DEEP_SPACE | v_bci ↔ v_hel: add/subtract the body's heliocentric velocity (Earth: 2,145 m/s) | `body_vel_helio` |
| DEEP_SPACE ↔ INTERSTELLAR | HUD/control expression only; physical state untouched | none |
| SOI swap (Earth ↔ Moon, SN6c) | `p' = p − moon_pos(t)`, `v' = v − moon_vel(t)` (O1O4 §3.5) — a *scene+physics* event, ± 2 % hysteresis, its own gates | O4c |

### 5.3 The controller rule that preserves the theorem (SN-R1)

The only way a mode flip can jerk is if a *controller* injects an impulse when its reference
changes (e.g. dev-flight damping toward "rest in the new frame" — rest differs by ω⃗×p or 2.1 km/s
across a boundary). Rule SN-R1, load-bearing and gated: **on any nav-mode change, every
controller's commanded/reference velocity is re-initialized to the player's CURRENT velocity
re-expressed in the new frame — never to frame-rest — and any assist/damping ramps in over
≥ 1 s.** Dev-flight velocity-command (§7.2) satisfies this by construction: the commanded BCI
velocity is continuous across the flip; only subsequent *input* moves it.

### 5.4 The continuity theorem + gate

Since (a) the physical state lives in one BCI f64 store, (b) every frame map in §5.1 is affine and
continuous in t, (c) SN-R1 forbids reference resets, and (d) the scene frame is untouched by nav
transitions: for any trajectory, `v_bci(t+dt) − v_bci(t) = (g + a_thrust + a_drag)·dt` at EVERY
tick including mode-flip ticks — no impulse terms exist. **G-SN-CONT** (headless): script a
trajectory that crosses every boundary both directions (spiral ascent surface → LEO → r = 15R →
heliocentric coast → return → re-entry), step the full stack (integrator + classifier + machine +
controllers), assert per-tick: the identity above to 1e-9 relative; every frame round-trip
(fix→bci→fix etc.) < 1e-9 blocks; zero Δv at each flip tick; the mode sequence matches the
expected list with hysteresis honoured.

### 5.5 Position/render continuity at the borders

Inherited, not re-derived: anchor steps are integer + relative-invariant (G-O1-ANCHOR); the
atmosphere↔space border has NO render event under SN3 (persistence + `s = min(1, D_ENGAGE/d)`
clamp, C0 at engage — SEAMLESS-SCALES §5.2); facet crossings are the shipped O(1) reframe (+
`FP_CROSS_TILT_EASE` as a separate seamless-scales item, not this design's scope); the SOI swap
touches only sky-scale nodes and is gated for continuity of rendered sun/star directions (G-O4-SWAP).

## 6. Atmosphere + sun rendering (gl_compatibility, built-in-first)

Standing constraint honoured: the tier depth-bias P3 hand-written spatial shader just failed live
(flat/wrong vs the StandardMaterial3D it replaced). Everything below is Environment/lighting
properties and built-in nodes, except the ONE flagged shell.

### 6.1 What is already done (do not rebuild)

Sun as THE real DirectionalLight, day/night from spin, dawn/dusk sky+fog+ambient ramp, star dome
with fade, moon impostor with automatic phase — all shipped in `cosmos_sky.gd` under
`ORBITAL_SKY`. The surface **terminator line** is automatic: it is the day-night boundary the
DirectionalLight paints on the lit sphere/facets (visible from orbit for free once you can get
there).

### 6.2 SN4a — the altitude ramp (`ATMO_VISUAL_RAMP`, adopts SEAMLESS-SCALES §5.6)

All C¹ functions of radial altitude h, composed with the existing sun-elevation ramp; O(1)
Environment property writes per frame, zero geometry, zero memory:

```
fog_density(h)   = fog₀ · exp(−h / H_SCALE)         # H_SCALE = 128 (shared with the drag model)
space_mix(h)     = smoothstep(0.5·H_ATMO, 2.5·H_ATMO, h)     # 192 .. 960 on Earth
background       = lerp(ramped_sky_colour, BLACK, space_mix)  # sky → black even with the Sun visible
star_fade        = max(night_fade, space_mix)                 # stars come out as the sky blackens
ambient_energy  *= lerp(1.0, AMBIENT_SPACE (≈ 0.15), space_mix)
```

"Light dispersion decreasing with altitude" IS this ramp; "sky fully dark above the border while
the Sun is visible" is `space_mix = 1` with the Sun impostor + light untouched. On the Moon
(has_atmo = false): fog₀ = 0, space_mix ≡ 1 — black sky at the surface, stars at noon (O1O4 §3.2).

### 6.3 SN4b — the sun-occlusion dimmer (`SN_SUN_OCCLUSION`) — day-night for the orbital observer

Without shadow maps the DirectionalLight lights a player behind the planet. Analytic fix (pure
f64, one scalar per frame): with p = player BCI position, ŝ = sun direction, the body occludes the
sun when the angle α between ŝ and −p̂ satisfies `α < asin(R_vox/|p|)`. Soft penumbra: ramp
`light_energy` over `α ∈ asin(R/|p|) ± 0.005 rad` (~ the solar angular radius). Below the blend
band the existing elevation ramp already encodes this (horizon ≈ occlusion) — blend the two
drivers by altitude so exactly one owns any regime. Also drives `ambient` floor and (SN6c) works
unchanged over the Moon. Solar eclipses BY the Moon fall out later by running the same test
against the Moon's sphere (O5 polish, slot noted). Gate G-SN-OCCLUDE: shadow factor 0 in the
umbra, 1 sunlit, monotone in between, continuous at the blend-band boundary.

### 6.4 SN4c — the atmosphere shell (`SN_ATMO_SHELL`) — **THE VISUAL RISK**

The one item that genuinely wants geometry: the blue limb/halo wrapping the planet seen from
space, with sunset colours near the terminator. Three-step escalation, each gated on a LIVE
screenshot pass before default-on, with the previous step as fallback:

1. **v0 (ships with SN4a): no shell.** The altitude ramp + terminator + horizon fog already read
   as an atmosphere from inside and low orbit. Zero risk.
2. **v1 built-in attempt**: one SphereMesh at R + H_ATMO, StandardMaterial3D: additive blend,
   albedo sky-blue at low alpha, `shading_mode = PER_PIXEL` (lit ⇒ dark on the night side gives a
   crude terminator on the shell), rim + rim_tint for limb emphasis, `disable_fog`, cull front
   (render the far side as backdrop) — **flagged uncertainty: BaseMaterial3D rim under the
   compatibility renderer must be verified live**; if rim is unsupported it degrades to a flat
   translucent shell, judged by screenshot.
3. **v2 bespoke shader** (only if v1 fails the look): a small unshaded fragment shader on the
   shell computing the closed-form view-ray path length through the spherical shell (analytic
   single-scatter approximation), sunset tint from `dot(view, sun)`. Additive, depth-draw-off,
   fog-off — the same "safe class" as the shipped star-dome shader (which DID pass live), NOT the
   lit-terrain-replacement class that failed in P3. Still: **VISUAL RISK — live screenshot gate
   mandatory, default-false until passed, v1/v0 fallback permanently retained.**

Memory: one sphere mesh + material ≤ ~100 KB. All variants NEVER-OOM-trivial.

### 6.5 Beautiful sunrises/sunsets from space

Composition of the above, no extra machinery: the elevation ramp's dawn/dusk colours (shipped) ×
the shell's terminator band (v1/v2) × the occlusion penumbra (SN4b) — as the player orbits into
the terminator they cross the penumbra ramp while the shell shows the tinted band. Judged live;
listed in §11 as morning-test items.

## 7. Dev-nav mode (F) — controls + overlays per nav mode

### 7.1 Structure

Flag `SN_DEVNAV`. F toggles dev-nav (replacing the bare fly toggle *under the flag only* —
flag-off, F is the shipped fly toggle byte-identically). Dev-nav = (a) the mode-appropriate
flight controller, (b) an overlay set. Overlays are: a Control-layer HUD (compass strip, body
labels — `draw_line`/`draw_string`, no materials) + unshaded vertex-colour line meshes
(`ImmediateMesh` or pre-built `ArrayMesh` line strips) for 3-D guides. **No lit spatial shaders
anywhere in dev-nav** (the P3 lesson); line meshes are the same safe class as the far ring's
unshaded rebuild path. All nodes created lazily on first F, reused, hard-capped (§9).

### 7.2 The dev-flight controller (all modes above PLANETARY)

**Velocity-command flight in the NAV frame** — the mechanism that makes "flying follows the
surface's rotation" (planetary) and "follows the planet, not its surface" (orbital) true
automatically: input (camera-frame WASD/Space/Ctrl) sets a commanded velocity `v_cmd` IN THE
CURRENT NAV FRAME, converted each tick to BCI (`v_bci = A⁻¹·v_cmd + carrier(p,t)`) and applied
kinematically (gravity off while dev-flying — it is a dev/creative verb, like shipped fly).
Zero input ⇒ rest in the frame ⇒ planetary hover tracks the spinning surface; orbital hover
station-keeps relative to the planet centre. Per SN-R1, `v_cmd` is re-expressed (not reset) on
mode flips. Speed authority per mode:

| Mode | Dev-fly speed cap | Note |
|---|---|---|
| PLANETARY | shipped fly 16/32 m/s, lattice path **unchanged** | only overlays added |
| LOW_ORBIT | `0.25 · v_circ(r)` (interim ~63–69 m/s; post-O3 ~137–142 at LEO) | the user's "fly at 25 % orbital speed" |
| HIGH_ORBIT | `0.25 · v_circ(r)` (falls with r), floored at 50 m/s | same rule, floored |
| DEEP_SPACE | `0.25 · v_sol(r_helio)` (~536 m/s at Earth distance) | same rule vs the Sun |
| INTERSTELLAR | const `SN_DEV_V_MAX = 10,000 m/s` | data |

Real (non-dev) propulsion is O1's gear-2 thrust and SN6c's gear-3 — dev-flight never replaces
them; F off returns to the locomotion machine's normal ORBITAL/FLY behaviour.

### 7.3 Overlays per mode

- **PLANETARY**: (1) *compass strip* top-centre (Rust-style): heading ticks every 15°, cardinal
  letters, computed from local north/east — `north = normalize(ẑ − (ẑ·r̂)r̂)`, `east = ẑ × r̂`
  normalized, `heading = atan2(f·east, f·north)` with f = camera forward projected to the tangent
  plane (pure function, gate-pinned: looking east at the equator = 90°). (2) *facet borders*: line
  loops along the active facet's ridge polygon + its ring-1 neighbours (FacetAtlas seam/poly rows;
  ≤ 9 facets × 4 edges, rebuilt only on crossing — bounded, trivial).
- **LOW_ORBIT adds**: spin-axis line (±1.5R along ẑ through the body centre), equator ring
  (r = 1.02R, 128 segments, in the body-fixed XY plane — static in-scene since the planet is
  pinned), spin-direction arrowheads on the ring (east-pointing), the body's heliocentric orbit
  line (256 samples from the ephemeris, each vertex placed camera-relative with the D_SKY
  distance-clamp — direction-exact, dev-grade), and **per visible body** (table bodies whose
  unprojected position is on-screen): a label with name, distance-to-centre, distance-to-surface,
  and a small arrow for its velocity relative to the current nav frame.
- **HIGH_ORBIT adds**: G and R toggles (§7.4).
- **DEEP_SPACE / INTERSTELLAR**: same overlay set minus orbit/G toggles; body labels persist
  (the Sun included).

### 7.4 The toggles

- **O — circular-orbit release** (LOW/HIGH): sets `v_bci = v_circ(r) · t̂`, `t̂ = normalize(look −
  (look·r̂)r̂)` (degenerate look ⇒ keep current tangential direction, else east), then hands the
  state to the ORBITAL integrator (dev-flight off ⇒ free coast, freeze-to-Kepler applies). O
  again: back to velocity-command, `v_cmd` initialized from the current velocity (SN-R1 — no
  jerk). The initial impulse is an explicit user command, not a seam.
- **G — geostationary snap** (HIGH only): if `r_geo_dyn < 0.9·R_SOI` — move to the equatorial
  point at r_geo preserving current longitude, set `v_bci = ω⃗ × p` (exactly circular there, and
  scene-stationary by construction since the scene frame is body-fixed). An explicit dev teleport
  (allowed: user-invoked). Over the Moon: HUD notice "no stationary orbit (r_geo > SOI)".
- **R — frame detach** (HIGH+): latches nav expression to DEEP_SPACE (heliocentric HUD/controls)
  until R again or a natural reclassification; a pure classifier override bit (§4.5).

### 7.5 HUD

Extends O1O4 §2.9: frame-explicit speed labelled with the CURRENT nav frame ("surface / orbital /
solar / self"), radial altitude, Ap/Pe + time-to (closed-form), prograde/retrograde markers, the
current NavMode name, and (dev) the active toggles. RemoteBridge telemetry gains
`nav_mode/frame_v/|v_bci|/ap/pe` — the live loop reads these in the morning run.

## 8. The Moon (SN6) — adopted O1O4 Part B + two additions

### 8.1 Adopted verbatim (see O1O4 §3 for full detail; not restated)

Global fid namespace (append-only BODY_TABLE, zero call-site churn, worker safety structural),
G-O4-EQ equivalence gate FIRST (atlas hash + worldgen pins + full suites both flag states),
per-body worldgen dispatch at `facet_profile` (moon_profile_at_dir: regolith/maria/craters, no
sea/trees/snow), BlockCatalog data adds (regolith/basalt/anorthosite), pool dominant-body-
exclusive invariant, SOI swap as pure re-expression + sky swap, feel gravity s = 0.165
(hang-time ×2.5), tidal lock already in the kernel, Earth-in-the-lunar-sky at 1.9°.

### 8.2 Addition 1 — the classification atmosphere band

`H_ATMO(moon) = 256` blocks, **classification-only** (the user's locked spec: treat the Moon's
"atmosphere" band as ~256 blocks): within it the nav machine reads PLANETARY (surface-frame
controls near the ground — necessary for sane low flying over a rotating-with-tidal-lock body).
`has_atmo` stays false ⇒ NO drag, NO fog, `space_mix ≡ 1` (black starry sky at noon), no shell.
BodySpec grows the field `h_nav_band` distinct from `has_atmo` — one const per body.

### 8.3 Addition 2 — landing pacing (confirms D-O4-5)

No drag ⇒ no terminal-velocity cap ⇒ a ballistic lunar descent arrives at 120–170 m/s. Adopted
recommendation: `ORBIT_PREWARM_H = 4096` for airless bodies (≥ 24 s of pool pre-warm) + accept
brief low-LOD ground under a non-braking lander. A retro-burn landing is the intended gameplay;
the morning test flies it deliberately.

### 8.4 Walk parity (the test scenario's "same kind of walkable planet")

By construction: the locomotion machine, analytic physics, edit overlay, collapse, pool and
crossing algebra are all fid-driven and body-blind (O1O4 §3.1/§3.3). Gate G-SN-MOONWALK: run the
existing FLAT-style invariant suite's movement/edit subset with the active facet forced to a Moon
fid — walk, jump (hang ×2.5 at preserved height), break/place, collapse must pass identically.

## 9. NEVER-OOM ledger (all additions; every flag default-false, OFF ⇒ byte-identical)

| Item | Bytes | Cap / lifetime |
|---|---|---|
| NavKernel + frame maps + classifier state | O(bytes), zero per-frame alloc (DVecF64 temps) | static |
| OrbitalState + CosmosGravity (SN1, from O1O4) | ~100 B/entity, `ORBIT_ACTIVE_MAX = 8` (player = 1) | pinned |
| Scaled-body clamp + adaptive near/far (SN3) | **0** (same far-ring mesh/node; camera params) | — |
| Altitude ramp + occlusion dimmer (SN4a/b) | 0 (Environment/light property writes) | — |
| Atmosphere shell (SN4c, if it passes live) | ≤ ~100 KB (1 sphere + 1 material) | 1 node, reused |
| Dev-nav overlays (SN5) | ≤ 64 KB hard cap: compass Control, ≤ 10 facet-border loops, axis+equator+orbit lines ≤ 3 strips × 256 verts, ≤ 8 body labels | lazy-built, reused, freed on flag |
| HUD | 1 Control | static |
| Moon atlas rows (SN6b) | +0.72 MB static (616 B × 1176 fids) | one-shot warm_up; MULTI_BODY=false ⇒ 0 |
| Moon far ring | ~1.5 MB | built by angular trigger, freed when sub-relief-pixel again |
| **Pool (the doubling risk, addressed)** | **unchanged budget — strictly exclusive to the dominant body** (O1O4 §3.3): entered only via prepare_landing/crossings, which are dominant-body ops; peak = max-over-bodies, never sum. Asserted: G-SN-POOLX (every pool fid ∈ dominant body's range, every tick of the SOI-swap gate script). | POOL_MEM_BUDGET_MB = 128 |
| Both bodies' far rings during transfer | Earth ring (already resident today) + Moon ring 1.5 MB — the only genuine "two bodies at once" cost; both needed for seamlessness (both visible) | bounded, stated |

## 10. §PLAN — phased implementation (ordered for the orchestrator)

Rules for every phase: new flag default **false**; `main`/flag-off **byte-identical** (FLAT
6035/0 + full faceted suite); flip-at-export only after its gate + (where stated) live A/B;
NEVER-OOM per §9. "Live-only" lists what a headless gate CANNOT prove (visuals/feel) — deferred
to the morning session, never to overnight.

### SN1 — ORBITAL substrate (flag `FP_M3_ORBIT`) — *mechanics core, first*
O1O4 Part A verbatim MINUS H_FARSWAP (R1), PLUS GM_dyn (§3): `cosmos_gravity.gd` (blend field),
`orbital_state.gd` (f64 state, symplectic, freeze-to-Kepler, frame algebra statics incl.
`body_vel_helio`), PMode ORBITAL + gear-2 thrust + drag + re-entry designation/prewarm +
anchor-follow, orbit HUD basics.
- Memory: §9 rows 1-2. 
- Headless gates: the full O1O4 §2.10 suite (G-O1-FIELD/ENERGY/KEPLER/HANDOFF/REENTRY/DRAG/
  ANCHOR/OFF) + **G-SN-SCALE** (GM_dyn law: ×k³; identity when R_vox = R_eph; blend-band
  continuity at the interim numbers 22→24.6-datum).
- Live-only: worst-frame envelope during ascent; the feel of gear-2.
- Size: ~2 agent-nights (O1a+O1b).

### SN2 — the nav-frame machine (flag `SN_NAV_MODES`)
`cosmos_nav.gd` (pure static kernel: classify + hysteresis + frame maps + carrier velocities) +
the machine state in player.gd/WorldManager + frame-explicit HUD velocity + telemetry fields.
- Memory: O(bytes).
- Headless gates: **G-SN-CLASS** (the §4.3 table + boundary/hysteresis/dwell sequences + the
  R-latch), **G-SN-CONT** (§5.4 — the continuity theorem over the full scripted trajectory),
  **G-SN-GEO** (`|ω⃗×p| == v_circ` at r_geo; Moon ⇒ none), G-SN-OFF (byte-identity).
- Live-only: nothing visual — this phase is pure math + HUD text. The cheapest big win.
- Size: ~1 agent-night.

### SN3 — border continuity (flag `FP_SCALED_BODY`)
SEAMLESS-SCALES C2: far-ring persistence (no retire below sub-pixel), the `s = min(1, D_ENGAGE/d)`
camera-relative clamp, altitude-continuous camera near/far (`near = clamp(h/256, 0.05, 8)`,
`far = max(9000, 1.2·√(d²−R²))`). Fixed conservative retire altitudes v1 (skin ≈ 4 k, pool-mesh
≈ 10 k, hysteresis ± 25 %); the full SSE scheduler (`FP_TIER_SSE`) is a later drop-in (R8).
- Memory: **0 bytes** (the §9 row).
- Headless gates: **G-SN-CLAMP** (synthetic camera sweep 0 → 300 k altitude: rendered angular
  size of the body continuous to < 1e-4 at engage; s == 1 below D_ENGAGE exactly), **G-SN-NEARFAR**
  (near/far ramps C0, ground values exactly shipped 0.05/9000), flag-off byte-identity.
- Live-only: the actual absence of pops on the climb (P1 screendiff on the remote bridge).
- Size: ~1 agent-night.

### SN4 — atmosphere + sun (flags `ATMO_VISUAL_RAMP`, `SN_SUN_OCCLUSION`, `SN_ATMO_SHELL`)
§6.2 altitude ramps; §6.3 occlusion dimmer; §6.4 shell v0→v1(→v2 only if needed).
- Memory: 0 / 0 / ≤ 100 KB.
- Headless gates: **G-SN-RAMP** (space_mix/fog/star curves: C¹, endpoints exact — h = 0 equals
  the shipped shipped-day values, h ≥ 2.5·H_ATMO equals black/stars-full), **G-SN-OCCLUDE**
  (§6.3), instantiation-only for the shell.
- Live-only (**explicitly cannot be headless**): the entire LOOK — limb, sunset band, night-side
  darkness, shell v1 rim support under gl_compat. Morning screenshot protocol; `SN_ATMO_SHELL`
  stays false until it passes. **VISUAL RISK is confined to this flag.**
- Size: ~1 agent-night (v0/v1) + taste passes.

### SN5 — dev-nav (flag `SN_DEVNAV`)
§7: F-toggle rework (flag-gated), velocity-command controller with SN-R1, compass, facet borders,
axis/equator/orbit lines, body labels, O/G/R.
- Memory: ≤ 64 KB capped (§9).
- Headless gates: **G-SN-DEVNAV** (overlay nodes instantiate + free on toggle; caps asserted;
  compass pure-function pins — east-at-equator = 90°, pole degeneracy handled; O sets
  |v_bci| == v_circ(r) ⊥ r̂; G lands exactly circular: |v − ω⃗×p| < 1e-9; R latch respected by the
  classifier), G-SN-CONT re-run WITH dev-flight active across flips (SN-R1 proof).
- Live-only: legibility/aesthetics of every overlay; compass feel.
- Size: ~1-1.5 agent-nights.

### SN6 — the walkable Moon (flags per O1O4: `MULTI_BODY`; stages a/b/c) — *last, gated on SN1-SN5 solid*
- **SN6a** = O4a fid-namespace refactor, Earth-only, **G-O4-EQ green before anything else**.
- **(external gate)** O3 D1-resize (parent plan) SHOULD land here — before SN6c makes the Moon
  reachable (R7). If O3 slips, SN6c may still proceed on GM_dyn with the §3 disclosure.
- **SN6b** = O4b Moon body dark (atlas append, worldgen, materials) + `h_nav_band = 256` (§8.2).
- **SN6c** = O4c SOI swap + gear-3 + lunar landing (PREWARM 4096) + Earth-in-moon-sky + the
  Moon far ring by angular trigger (R3).
- Headless gates: the O1O4 §3.6 suite (G-O4-EQ/KEY/MOONGEN/ATLAS2/SOI/SWAP/LOCK/OFF) +
  **G-SN-MOONWALK** (§8.4) + **G-SN-POOLX** (§9) + G-SN-CLASS re-run with body = moon
  (256-band, no-geo case).
- Live-only: the full round trip (§11), Moon terrain taste (D-O4-1).
- Size: ~3-4 agent-nights across a/b/c.

Dependency graph: SN1 → SN2 → {SN3, SN4, SN5 in any order} → SN6 (SN6a can start after SN1).
The morning-validation-ready increment is **SN1+SN2+SN3** (fly to space, mode machine live,
no border pops) — SN4/SN5 enrich it, SN6 completes the user's scenario list.

## 11. The morning live-test map (the user's scenarios → phases)

| Scenario | Needs |
|---|---|
| Fly in atmosphere; leave it and fly around; fly freely | SN1+SN2+SN3 (+SN4 for the look) |
| Toggle orbiting (O), observe modes/HUD | SN2+SN5 |
| Geostationary (G), detach (R) | SN5 |
| Sunset/sunrise from orbit; dark night side; black sky above atmosphere | SN4 (screenshot pass) |
| Go land on the Moon; walk it identically; no atmosphere but 256 nav band | SN6 (after O3 ideally) |
| Take off from the Moon, land back on Earth | SN6c (the full loop, remote-bridge telemetry) |

## 12. Risks + open decisions

| # | Risk | Sev | Mitigation |
|---|---|---|---|
| 1 | Shell look fails on gl_compat (rim unsupported / flat) | M | the §6.4 ladder: v0 ships regardless; v1/v2 behind live screenshot; risk confined to one flag |
| 2 | Mode thresholds feel wrong in play (too eager/lazy) | L | all consts data (`cosmos_nav.gd` header); classifier pure ⇒ retune + re-gate in minutes |
| 3 | GM_dyn interim confuses HUD numbers vs the parent doc's tables | L | HUD shows live-derived values only; §3 table is the reference; O3 erases the difference |
| 4 | Dev velocity-command flight interacts badly with drag/atmo re-entry | M | dev-flight disables drag (kinematic); re-entering PLANETARY at speed hands to the shipped fly/fall paths through the §5 maps — G-SN-CONT covers the path |
| 5 | Controller-reference bug reintroduces flip jerks (SN-R1 violation) | M | G-SN-CONT runs WITH dev-flight + assists active; SN-R1 is a named, gated rule not a convention |
| 6 | Overlay draw cost on weak GPUs | L | ≤ ~6 line meshes + 1 Control; remote-bridge frame-delta A/B before export flip |
| 7 | SN6 pool exclusivity broken by a landing race | H | G-SN-POOLX asserts per-tick during the scripted SOI+landing gate; the invariant is structural (prepare_landing is dominant-body-only) |
| 8 | O3 resize slips; Moon ships on GM_dyn | M | allowed with disclosure (§10 SN6); the inconsistency is unobservable except station-keeping beside the on-rails Moon |

Open decisions for the user: **D-SN-1** vicinity measured from centre (4R) vs surface (5R) —
§4.2(2), recommend centre; **D-SN-2** GM_dyn interim (§3) — recommend yes (it is also the O3
migration path); **D-SN-3** shell fidelity ladder stop-point (v0/v1/v2) — recommend judge v1
live before ever writing v2; **D-SN-4** dev-teleport style for G (instant vs eased) — recommend
instant (explicit dev verb).

## 13. What this design deliberately does not do

No SpaceGrids/RCS/match-velocity (O2 owns them; OrbitalState is built to be shared), no portal
implementation (PortalAnchor compatibility inherited — parent §7.4), no full SSE scheduler
(drop-in later, R8), no shadow maps, no n-body, no axial tilt/seasons, no interstellar content
(the mode exists, its space is empty), no Godot precision=double, no WebGPU/Forward+ (renderer
locked through 4.7), no changes to walking-scale look or feel with flags off.
