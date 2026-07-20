# COSMOS ATMO2 — path-length sun physics, moderated atmosphere, absolute near-field night, real dynamic range

**Status: DESIGN (root-cause + staged plan). 2026-07-20. Owner: design-atmo2 (Fable).**
Audited build: the LIVE deploy at `deploy/perf-plus-sky` **5b1d276** (the build the pilot
flew 2026-07-20 ~20:30–20:46Z). Flag values dumped from the deployed `build/web/index.pck`
(headless `get_script_constant_map`); behaviour confirmed against the pilot session's
remote-bridge frames + telemetry (`tools/remote-bridge/results/`, frames 000–059 +
frame-latest, telemetry.jsonl `_rx` 20:32–20:46Z).

This supersedes nothing structurally: A0–A6 (docs/COSMOS-ATMO-SKY-DESIGN.md) landed and
mostly WORK — the ephemeris sun, the analytic occlusion geometry, the absolute far-shell
day/night (A5) and the space-black sky (A3) are all correct in the live frames. What is
wrong is (a) the **sun's colour/brightness law** (altitude/elevation-keyed instead of
atmospheric-path-keyed), (b) the **atmosphere shell's brightness integral** (single-sample
overestimate, 6–80× hot), (c) the **near-field materials never read light at all**
(unshaded — A4 dims lights nothing listens to), and (d) the **impostor presentation**
(half-size discs, glare-only blob, no space-white). Each is root-caused below with
file:line, then ONE coherent model fixes all of them with shared curves.

---

## 1. Flag fingerprint of the audited build (from the pck, not source)

ON: FACETED, FLAT_WORLD, ORBITAL_SKY, FP_FIXED_FRAME, FP_M1_POOL, FP_SCALED_BODY,
FP_SN3_MAIN_LIVE, FP_SKY_PLANET_OCCLUDE, FP_SUN_PRESENCE, FP_ATMO_SPACE_ZERO,
FP_LIGHT_ABSOLUTE, FP_SHELL_ABSOLUTE, FP_ATMO_SHELL, SKY_SCATTER_RAMP,
SHELL_TERMINATOR_TINT, SKY_MOONSHINE(+LIGHT), FP_SKY_DSKY_R, ATMO_VISUAL_RAMP,
SN_SUN_OCCLUSION, FP_SHELL_WELD, FP_RADIAL_DATUM, FP_CLOUDS, FP_PRECIP, FP_STORMS,
FP_CLIMATE_GRID, FP_SEASONS, SN_HUD_NAV, ORBIT_*, SN_ATMO_BRAKING, SN_DEVNAV.
OFF: FP_BODY_LOD, FP_MOON_RING, MULTI_BODY, FP_SKIN_TIER.
Consts: SUN_MIN_ANG_DEG=2.0, MOON_MIN_ANG_DEG=1.5, SUN_GLARE_RADII=5.0, ATMO_TOP=384.

**Frame verification** (this matters — a wrong frame assumption would sink everything):
Phase 2 fixed-frame is LIVE — `world_manager.gd:234-241` sets ActiveFrame to
`T_active = facet_transform(active)`, so the player/camera GLOBAL position is
planet-ABSOLUTE with the planet centre at the scene origin. Telemetry proves it:
`pos [4063.75, −4082.85, −2730.22]`, |pos| = 6374.8 = `orbit_r`, `alt 3.8`
(R_BLOCKS = 6371). CosmosSky's `cam_origin`-as-planet-relative assumption is **correct**;
none of the bugs below are frame bugs.

---

## 2. Root causes, with the pilot's numbering (file:line at 5b1d276)

### 2.1 Bug (3): the glowing night-sky "artifact" IS THE SUN — rendered unrecognizably

Captured live: `tools/remote-bridge/results/frames/frame-1784579719109-040.jpg`
(LOW_ORBIT, alt 988): a soft ~4–5° warm-yellow radial blob among stars, no crisp disc.
It moves opposite the spinning surface because it is a celestial object (body-fixed
`sun_dir`, `cosmos_sky.gd:678` — correct). Three defects make the Sun read as an artifact:

1. **Yellow in space.** The disc emission and glare colour are multiplied by
   `scatter_tint(mu_cam)` where `mu_cam = sun_dir·up` — a camera-ELEVATION key through
   the Kasten–Young SURFACE air-mass curve (`cosmos_sky.gd:722-733`, curve at
   `cosmos_sky.gd:434-443`) — applied at EVERY altitude. In vacuum the sun is painted
   sunset-gold. The DirectionalLight colour has the same defect
   (`cosmos_sky.gd:847`: `scatter_tint(max(elev,0))`).
2. **No crisp disc — the blob is glare only.** `_place_impostor`
   (`cosmos_sky.gd:923-927`) scales assuming "SphereMesh default radius = 1"; Godot's
   `SphereMesh` default radius is **0.5** (height 1.0), and `_build_nodes` never sets it
   (`cosmos_sky.gd:506-509`, `:565-568`). Every sun/moon disc renders at **half** its
   intended angular size: sun 1.0° (not the 2.0° floor), moon 0.75° (not 1.5°). The 1°
   disc drowns inside the 10°-wide glare quad (half-extent = `sun_r·SUN_GLARE_RADII`,
   `cosmos_sky.gd:731`) → a fuzzy ball, not a sun.
3. **The blue halo around it** is the A6 shell's overbright limb wash (§2.4) wherever
   the sun sits near the limb from orbit.

A1's planet-occlusion of the disc/glare (`cosmos_sky.gd:693, 739-741`) is geometrically
correct (verified against the telemetry positions) — the sun/glare do die in the umbra.

### 2.2 Bug (9): the Moon is invisible — four stacked causes

1. **Half angular size** — same SphereMesh-0.5 defect (§2.1.2): 0.75° rendered.
2. **Night: the self-phase shader makes non-gibbous phases near-black.**
   `_MOON_PHASE_SHADER` (`cosmos_sky.gd:146-158`) is unshaded with `ambient = 0.02`;
   a crescent/new moon's visible hemisphere gets `ALBEDO ≈ 0.72·0.02 ≈ 0.014` — a black
   disc on a black sky. There is no earthshine floor.
3. **Day/low-sky: buried by the A6 wash.** The overbright shell (§2.4) paints the whole
   low sky 0.5–1.0-luminance blue-white (frames 000/007) — a 0.75° dim lit disc is
   invisible inside it; near the sun a crescent also sits inside the 10° glare quad.
4. **Every full moon is a lunar eclipse.** The ephemeris moon orbit is coplanar
   (`incl = 0.0`, `cosmos_ephemeris.gd:84-87`), so at every opposition the moon enters
   the umbra cone (angular radius asin(6371/384400) ≈ 0.95°) and
   `moon_eclipse_factor` (`cosmos_sky.gd:483-486`) crimson-dims it — ~8–9 real minutes
   per 20.7-real-hour lunar month (small duty, but it hits exactly the brightest phase).
   A1's horizon hide (correct) removes another ~50% of availability.

Primary: (1)+(2) at night, (1)+(3) by day. The moon is never *hidden by a bug*; it is
rendered too small, too dark, or on too bright a background to ever be seen.

### 2.3 Bug (6): surface bright at night while orbit view is dark — near blocks are UNSHADED

Captured live: `frame-latest.jpg` / `frame-…-026.jpg` (alt 4, 20:46Z): black starry sky,
far ring correctly near-black (A5 night floor), **near grass/trees/clouds at full day
brightness, zero Lambert gradient**.

Root cause: **every near-field material is `SHADING_MODE_UNSHADED`** —
`block_atlas.gd:243` (the ONE shared atlas material for cubes), `block_materials.gd:165,
178, 192` (shaped/solid/textured families); lighting is baked as face-shade/AO into
vertex COLOR by the meshers. Clouds are unshaded quads too (bright white at night in the
frames). So:

* A4's absolute light dimmer (`cosmos_sky.gd:845-847`) dims a DirectionalLight **no near
  geometry reads**; the ambient writes (`cosmos_sky.gd:894`) are equally ignored.
* The far ring (A5 shell v2, `facet_far_ring.gd:1190-1210`) self-shades per-vertex with
  the absolute `day(n̂·ŝ)` factor — hence "from orbit the surface correctly goes dark".

The pilot's split observation is exactly the shaded/unshaded boundary. A4's curves are
right; they are wired to a renderer input that the near field does not consume. The fix
is to compose the SAME absolute day factor into the unshaded materials (§3 C-NEAR).

### 2.4 Bugs (8)+(part of 3): the atmosphere shell is 6–80× too bright

The A6 strength (`cosmos_sky.gd:221` and the GLSL twin `:199-224`):
`strength = chord · exp(−max(h_min,0)/H) / H` — one density sample at the ray's
closest-approach altitude times the full geometric chord. That single-sample estimate is
only valid for exterior limb-grazing rays; everywhere else it wildly overestimates:

* Vertical from the surface: chord = 768, h_min < 0 ⇒ ρ = 1 ⇒ strength = 6. The true
  normalized optical path is ∫₀^768 e^(−h/128) dh / 128 ≈ **1** → **6× hot**.
* Horizontal from the surface (h = 60): forward chord ≈ 3100, ρ(60) = 0.63 ⇒
  strength ≈ 15 (×gain 1.6 ⇒ 24) → **clipped white**.
* Exterior graze from orbit (h_min ≈ 0): chord ≈ 6200 ⇒ strength ≈ 48 (×1.6 ⇒ 77).

Live evidence: frame 000 (alt 360) — the whole sky a blown cyan-white wash with stars
showing through it; frame 050 (alt 1019) — the limb a thick clipped-white band with blue
fringes; frame 007 (surface day) — the sky a yellow-white haze (the terminator band tint
`mix(1, T(μ), band(μ))` at μ ∈ band multiplied over the blown strength swings the whole
sky's hue). This is simultaneously the "atmosphere too bright" (8), the daytime
sun-invisibility half of (4) (an additive ≤1 glare vanishes on an already-clipped sky),
and the "blue halo" of (3).

### 2.5 Bugs (5)+(7): the sun attenuation law itself — altitude/elevation instead of path

Everything that colours sunlight today keys on **camera elevation μ through the
Kasten–Young surface air-mass fit** (`air_mass`, `cosmos_sky.gd:434-443`): the disc/glare
(`:722-733`), the light colour (`:847`), the A5 tint (`facet_far_ring.gd:1195-1197` GLSL
twin), the A6 tint (`cosmos_sky.gd:199-200` GLSL). K–Y is a curve fit of *real-Earth
surface* optical path vs elevation; it is meaningless off the surface. Hence: the sun
reddens/dims in SPACE by the viewer's pseudo-elevation, and nothing reddens through the
limb when it physically should. The corrected law (§3) makes attenuation a function of
the **optical path through the atmosphere along the viewer→sun ray** — which *reduces to*
a K–Y-shaped curve at the surface and to zero in space, by geometry, with no regime
switch.

### 2.6 Secondary conflicts found during the audit (must ride the plan)

* **WeatherFX stomps the altitude fog.** CosmosSky writes `fog_density = ρ(h)`
  (`cosmos_sky.gd:860`); WeatherFX, which `_process`es later in the tree, overwrites
  `fog_density = _base_fog · mult` every frame (`weather_fx.gd:173`, base captured at
  setup `:38`). With FP_PRECIP baked ON the altitude fog thinning is dead.
* **Fog will paint the planet black from deep space.** `fog_depth_end` is pinned at
  `CAMERA_FAR·0.98 = 8820` (`main.gd:275`) while A0 ramps the real camera far with
  altitude. From d ≳ 9 k every planet fragment is beyond fog-end ⇒ painted the fog
  colour, which the night/space ramp drives toward black. Untested live only because the
  pilot stayed below alt ~1000 this session. Physically, depth fog IS the atmosphere:
  it must fade out with `atmo_vis(h)` (and/or track camera far).
* **Penumbra split-brain:** the glare/disc visibility uses `OCC_PENUMBRA = 0.005`
  (`cosmos_sky.gd:693`) while the light uses `pen(h)` — unify on `pen(h)`.

---

## 3. The corrected model — one optical-path law, six consumers

### 3.1 The real solar numbers this is built on (cited)

* Sun effective temperature **5772 K** (IAU 2015 nominal). Extraterrestrial (AM0)
  spectrum per **ASTM E490**; total solar irradiance ≈ **1361 W/m²**. In space the sun
  is **white** (CCT ≈ 5800–5900 K, spectral peak ~450–500 nm — slightly blue-green-rich);
  it is NOT yellow.
* Terrestrial direct-beam spectrum per **ASTM G173** (AM1.5): after one-to-few air
  masses of Rayleigh (+aerosol) extinction the direct sun is **yellowish-white**,
  CCT ≈ 4900–5600 K at mid elevations; at the horizon (relative air mass ≈ **38**,
  Kasten & Young 1989) blue AND green are scattered out: CCT ≈ **1800–2500 K**, deep
  orange-red.
* Sea-level **vertical Rayleigh optical depths** at (680, 550, 440) nm:
  **τ⃗ = (0.042, 0.098, 0.245)** — exactly the shipped `TAU_R/G/B`
  (`cosmos_sky.gd:429-431`). These are real; KEEP them.
* True luminances (why "sun ≫ everything" matters): sun disc ~1.6×10⁹ cd/m² (space and
  near-noon surface), clear day sky ~10⁴, full moon ~2.5×10³, moonlit ground ≲10⁻¹ —
  a 10-decade scene the renderer must fake in LDR (§3.5).

Sources: IAU Resolution B3 (2015); ASTM E490-00a; ASTM G173-03; Kasten, F. & Young, A.T.
(1989) "Revised optical air mass tables and approximation formula", Applied Optics 28.

### 3.2 The optical-path kernel (new pure statics; the heart of ATMO2)

Density `ρ(h) = exp(−h/H)`. Two scale heights, deliberately split:

* `H = H_SCALE = 128` stays the **amplitude/gameplay** scale height (fog, drag, halo
  thickness — unchanged, shared with SN1).
* **`H_OPT := 30.0`** (new const) is the **extinction-colour** scale height. Rationale:
  the 1:1000 world's atmosphere is geometrically thick (H/R = 1/50 vs Earth's ≈ 1/750),
  so its self-consistent horizon air mass would be only ~9 — too small a dynamic range
  for the real τ⃗ to produce both a near-white noon and a red horizon. H_OPT = 30 gives
  m_horizon(ground) = √(πR/2H_OPT) ≈ 18 and m_limb(full chord from space) ≈ 36 —
  matching the real-Earth m-range the real τ⃗ values were measured against. One declared
  constant buys physical colour behaviour end to end.

For a ray from camera altitude `h` with local-vertical direction cosine `μ_v`
(= `dir·up` at the camera), closest-approach altitude `h_min`:

```
X_horiz(h)  = ρ_opt(h) · sqrt(π·(R+h)·H_OPT/2)          # tangent half-path
X_up(h,μ_v) = H_OPT · ρ_opt(h) / sqrt(μ_v² + 2H_OPT/(π(R+h)))   # ascending ray
              # μ_v=1 ⇒ ≈ H·ρ (plane-parallel); μ_v=0 ⇒ ≡ X_horiz — C¹, 4 ops, no erf
X_down      = 2·X_horiz(h_min) − X_up(h, |μ_v|)          # descending ray that clears
                                                          # the planet (fold at tangent)
X_space     = 2·X_horiz(max(h_min,0)) if the LOS grazes the shell, else 0
m(ray)      = X(ray) / (H_OPT·(1−e^(−ATMO_TOP/H_OPT)))   # normalized: vertical-from-
                                                          # ground = 1, space-clear = 0
T⃗(m)        = exp(−τ⃗·m)                                  # per-channel transmittance
L(m)        = exp(−τ_lum·m), τ_lum ≈ 0.10                # broadband brightness factor
```

Checkpoints (these become gate assertions): m = 0 in space with a clear LOS ⇒ T = white,
L = 1 (**full-brightness white sun in space**); m = 1 at surface noon ⇒
T ≈ (0.96, 0.91, 0.78) (pale warm, ~5400 K look); m ≈ 18 at the surface horizon ⇒
T ≈ (0.46, 0.17, 0.011) (deep orange-red sunset); m ≈ 36 through the full limb from
orbit ⇒ T ≈ (0.22, 0.03, 10⁻⁴) (the ISS-sunrise crimson graze). One formula, every
vantage point, C¹ across the atmosphere border — SEAMLESS-SCALES by construction.
Kasten–Young is retired from the live path (it is the same physics as `X_up` fit to real
Earth); it stays in the gate as the surface-regime cross-check curve.

### 3.3 The six consumers

* **C-SUN (disc + glare + DirectionalLight).** Disc core = white × T⃗(m(cam→sun));
  emission/energy × L(m)·occ(cam, pen(h)). Light colour = the same T⃗; light energy =
  occ × L. Space: blinding white; noon: pale warm; sunset: dim red you can look at;
  through the limb from orbit: reddens exactly as the ground sunset does.
* **C-GLARE** (the LDR "bloom", §3.5): intensity ∝ L(m)·occ, colour = disc colour,
  tight core (≈1.5 disc radii at ~0.9 luminance) + wide soft skirt (5 radii). Dies at
  sunset/eclipse/umbra via the same occ.
* **C-SHELL (A6 v2 shader body).** Replace `chord·ρ(h_min)/H` with the §3.2 path
  evaluated for the VIEW ray (amplitude on H=128 for a generously thick halo, colour on
  H_OPT), normalized so the **peak limb luminance ≈ 0.35** and the surface horizon band
  ≈ 0.2–0.3. Keep the existing day(μ_ca) × mix(1, T, band) factors — but T now from
  §3.2. From space: a thin moderate blue ring, reddening across the terminator, black on
  the night side, always dimmer than the sun.
* **C-NEAR (the bug-6 fix).** Shader twins of the unshaded near-field materials
  (atlas cubes `block_atlas.gd:243`; shaped/solid families `block_materials.gd`;
  cloud materials) that keep vertex-colour×texture EXACTLY and multiply
  `shade(μ) = max(night_floor + (1−night_floor)·day(μ)·lum(T⃗(μ)), moonshine_term)`
  with `μ = normalize(MODEL_MATRIX·v)·ŝ` — the planet centre is the scene origin
  (verified §1), so per-vertex absolute day/night falls out with ONE `sun_dir` uniform,
  and it EQUALS the far shell's factor at the same surface point — near and far agree by
  construction, killing the pilot's near/far split. `night_floor ≈ 0.10`;
  MOONSHINE_GAIN retuned ~0.5 → ~0.15 to compose with it. StandardMaterial fallback
  retained permanently (P3 gl_compat class).
* **C-MOON.** Size fix (§2.1.2) restores the true 1.5° floor; the self-phase shader's
  `ambient` becomes an **earthshine floor 0.10–0.12**; full-moon disc luminance target
  0.55–0.7; eclipse redden kept but gated by real alignment — give the ephemeris moon
  its **5.1° inclination** (`incl` slot exists, `cosmos_ephemeris.gd:66-87`) so eclipses
  become the rare event they should be (verify SN1/O1 gates still pass — incl feeds only
  the ephemeris kernel; if any gate pins coplanarity, keep incl behind the same flag).
* **C-SKY (Environment ramp).** Unchanged (A3 is correct); the SKY_SCATTER_RAMP
  recolour swaps its K–Y tint for T⃗(m) of the camera→sun ray (same visual at the
  surface, correct in space).

### 3.4 HDR on the web renderer — the honest verdict

**There is no HDR on the current web build, and none is reachable by configuration.**
Godot 4.4's Compatibility renderer (the only 3D method on WebGL2; Forward+/Mobile need
Vulkan/D3D12/Metal, and WebGPU is not shipped) renders 3D into an **R10G10B10A2 UNORM**
buffer with colours "**tonemapped and stored in sRGB format so there is no HDR
support**" (Godot 4.4 internal-rendering-architecture docs). Tonemapping is applied
inline per fragment; additive blends then sum in sRGB and clamp at 1.0. Environment
**glow IS available** in Compatibility since 4.2 as a simplified implementation
(Levels/Mix/Map properties unavailable; docs: environment_and_post_processing, 4.4).
Auto-exposure and the screen-space effects are Forward+-only.

Consequences accepted by this design:
* Brightness ordering must be **authored as an LDR luminance budget** (§3.5), not
  achieved by exposure.
* The **glare quad IS the bloom** (kept, retuned); optionally compose the real
  Compatibility glow with `glow_hdr_threshold ≈ 0.92` so ONLY the sun disc/glare (the
  budget's sole ≥0.9 residents) bloom — flag-gated, P3 class (if it misbehaves on
  device, off = glare alone still delivers).
* **Do NOT switch the tonemap curve.** With an LDR-budgeted, largely-unshaded scene,
  ACES/Filmic just darkens midtones globally and forces a full-look retune for zero
  dynamic-range gain (tonemap curves pay off on >1 inputs, which cannot exist here).
  Keep LINEAR; revisit only with a Forward+/desktop target (see
  voxiverse-godot-migration).

### 3.5 The LDR luminance budget (the gate-pinned ordering: sun ≫ atmosphere > moon > stars > night ground)

| Layer | Post-everything luminance target |
|---|---|
| Sun disc core (space/day) | **1.00** — the only thing allowed to clip |
| Sun glare peak / skirt | 0.90 / additive ≤ 0.4 |
| Clouds (day, lit faces) | ≤ 0.85 (below the glow threshold) |
| Day zenith sky (C-SKY) | ≈ 0.45 |
| Atmosphere limb halo peak / horizon band (C-SHELL) | **≤ 0.35** |
| Full-moon disc | 0.55–0.70 |
| Stars (points) | 0.5–0.9 |
| Night ground, near AND far (shared night_floor) | 0.03–0.10 |
| Sun disc at the horizon (m ≈ 18) | ≈ 0.17 — dimmer than the day sky, gazeable |

Small ground light sources (torches etc., future) then read against a 0.03–0.10 night —
the ordering leaves them ~a decade of headroom.

---

## 4. A0–A6 verdicts (task requirement)

| Existing piece | Verdict |
|---|---|
| A0 `FP_SN3_MAIN_LIVE` (far-plane ramp) | **KEEP** — but requires the B5 fog companion (§2.6) before any deep-space session |
| A1 `FP_SKY_PLANET_OCCLUDE` | **KEEP** (geometry verified correct) — unify penumbra on `pen(h)` |
| A2 `FP_SUN_PRESENCE` | **FIX** (B0/B1): keep floors+glare+quad, replace the μ-keyed colour with path-T⃗, fix the SphereMesh-0.5 size bug, retune glare into core+skirt |
| A3 `FP_ATMO_SPACE_ZERO` (`atmo_vis`) | **KEEP** (correct; frames confirm star-black space) |
| A4 `FP_LIGHT_ABSOLUTE` | **KEEP** the curves + moon self-phase; its *intent* on near blocks is delivered by B3 (the light itself reaches nothing unshaded); light colour re-keyed by B0; moon ambient floor raised in B4 |
| A5 `FP_SHELL_ABSOLUTE` (shell v2) | **KEEP** (proven live: far night dark) — harmonize its tint to path-T⃗ in B2 (GLSL twin swap, same shape at the surface) |
| A6 `FP_ATMO_SHELL` | **SUPERSEDE the shader body** (B2: path integral + normalization); keep the node, mesh, additive/depth discipline, uniforms |
| SKY_SCATTER_RAMP | **KEEP**, tint source swaps to path-T⃗ (identical at the surface) |
| SHELL_TERMINATOR_TINT (v1) | dead code path while A5 is on — leave as the A5-off fallback |
| SKY_MOONSHINE(+LIGHT) | **KEEP**, gain retuned under B3 (0.5 → ~0.15 vs the new night floor) |

---

## 5. Staged plan (all new flags default OFF ⇒ byte-identical; P3 shader class throughout: any gl_compat compile failure ⇒ flag off, shipped fallback)

| Stage | Flag | Content | Fixes | Depends |
|---|---|---|---|---|
| **B0** | `FP_SUN_PATHLIGHT` | §3.2 kernel as pure statics + rewire light colour/energy (`cosmos_sky.gd:845-847`) and disc/glare colour (`:722-733`) to T⃗(m)·L(m)·occ; retire K–Y from live paths; unify penumbra on pen(h) | (5)(7), space-yellow of (3) | — |
| **B1** | `FP_SUN_APPARENT` | SphereMesh radius fix (true 2.0°/1.5° floors); crisp white disc core; glare core+skirt retune; optional Compatibility glow (threshold 0.92) as a sub-flag `FP_SUN_GLOW` | (4), blob of (3) | B0 |
| **B2** | `FP_ATMO_PATH_SHELL` | A6 shader body v2: §3.2 path (amplitude H=128, colour H_OPT), peak-limb 0.35 normalization; A5 tint GLSL harmonized to the same m-form | (8), blue-wash of (3), day-sun washout of (4) | B0 |
| **B3** | `FP_NEAR_DAYLIGHT` | C-NEAR shader twins (atlas cube material, shaped/solid families, clouds): per-vertex absolute `shade(μ)` with shared night_floor; moonshine retune | (6) | B0 (curves) |
| **B4** | `FP_MOON_PRESENCE` | earthshine floor 0.10–0.12; luminance target; ephemeris moon `incl = 5.1°` (eclipses become rare); optional faint cool rim | (9) (with B1's size fix) | B1, B2 |
| **B5** | `FP_FOG_ARBITER` | WeatherFX MULTIPLIES onto CosmosSky's altitude fog density (composition, not overwrite); fog fades with `atmo_vis(h)`; fog_depth_end tracks the ramped camera far | §2.6, protects A0 | — |

Recommended bake order: **B0+B1 → B2 → B3 → B4 → B5.** B0+B1 make the Sun read as THE
SUN (white in space, crisp disc, correct sunset); B2 calms the sky so day reads right and
the sun is findable by day; B3 delivers real night on the ground; B4 gives the pilot the
Moon; B5 is the deep-space protective hygiene.

NEVER-OOM ledger: every stage is shader-body swaps, uniforms, consts, and ≤2 KB of new
ShaderMaterials replacing StandardMaterials 1:1 (B3 is the largest: ~4–6 material twins,
built once). Zero per-frame allocation, zero per-voxel data, no new nodes, no textures.
Upper bound ≈ 30 KB total, constant.

---

## 6. Gates

**HEADLESS-PROVABLE** (extend `src/tools/verify_atmo_sky.gd`; GDScript/GLSL twins pinned
by construction — the established G-AS discipline):

* `G-B0-PATH`: m = 0 exactly for space-clear LOS; vertical-from-ground m = 1 ± 2%;
  monotone in zenith angle; C¹ across the tangent fold and the ATMO_TOP crossing
  (numeric derivative); horizon m ∈ [15, 22], full-limb m ∈ [30, 40]; T⃗(0) = white
  exactly; surface m(μ) within 15% of Kasten–Young shape over elevations 5°–90°
  (the physics cross-check); light colour/energy a function of (position, t) only —
  orientation-sweep invariant.
* `G-B1-SUN`: rendered disc angular radius == floored angular radius (assert via mesh
  AABB × transform against `2·tan(ang/2)·D` — pins the SphereMesh-0.5 fix); glare peak
  ≤ disc luminance; sun luminance in space == 1.0; at the horizon ≤ 0.2.
* `G-B2-LIMB`: path twins vs numeric ρ-integration on a ray grid (camera in/out of the
  shell × 16 directions, relative error < 10%); peak limb luminance ≤ 0.35 + horizon
  band ≤ 0.30 (budget assertions); night side → 0; inside/outside continuity at
  ATMO_TOP (value + derivative); C-SHELL and A5 tint equality on a shared μ grid.
* `G-B3-NEARNIGHT`: near-material shade(μ) == shell day-factor at the same surface point
  ± ε (near/far consistency BY ASSERTION — the pilot's bug 6 becomes a pinned
  invariant); sun below dip+pen ⇒ shade ≤ 0.12; noon ⇒ 1; vertex-colour/texture path
  byte-equal at shade = 1 (day look preserved).
* `G-B4-MOON`: full-moon-clear-of-umbra disc mean luminance ≥ 0.4; new-moon night disc
  ≥ earthshine floor; with incl = 5.1° the eclipse duty cycle < 1% of oppositions
  (print + assert); ephemeris/O1/SN1 suites unchanged.
* `G-B5-FOG`: with FP_PRECIP + sky both on, applied fog_density == sky-ρ(h) × weather
  multiplier (composition asserted); density → 0 above ATMO_TOP; under the A0 far ramp,
  fog_depth_end ≥ 0.98·camera_far at every altitude step.
* Byte-off identity for EVERY stage: all-new-flags-off run of the full existing suite
  (FLAT 6035/0 class + verify_atmo_sky + verify_orbital_sky + facet-seam gates).

**LIVE-ONLY** (remote-bridge screenshots/video, the established loop):
space-white sun with crisp disc + glare among stars (the §2.1 frame re-shot); the same
sun yellow at surface noon and red at the horizon (same-session triptych); sunset from
the ground vs terminator from orbit — same hues (shared-curve check); limb halo a thin
moderate blue ring, stars visible beside it, sun clearly brighter than it; genuinely dark
night ground near AND far in one frame (the §2.3 frame re-shot); phased Moon found and
identified by the pilot unprompted; a full orbit pass video: day → terminator → umbra →
sunrise with no pops and the glare dying/reborn through the umbra; gl_compat shader
compile sanity on device for every twin (P3: any failure ⇒ that flag stays off).

---

## 7. Answers to the tasked questions, for the record

1. **(3)** The night-sky artifact is the **Sun**: glare-only blob (disc half-size, washed
   inside the quad), sunset-tinted in vacuum by the elevation-keyed K–Y curve, haloed
   blue by the overbright A6 limb — `cosmos_sky.gd:722-733, 923-927, 199-224`. It moves
   opposite the surface because it is celestial (correct); it stops being an "artifact"
   when it looks like the sun (B0+B1+B2).
2. **(9)** The Moon is never bug-hidden; it is rendered at half size
   (`cosmos_sky.gd:923-927` + SphereMesh 0.5 default), black-on-black at night
   (`ambient 0.02`, `:146-158`), buried by the sky wash by day, and eclipse-dimmed at
   every full moon (`cosmos_ephemeris.gd:84-87` incl = 0) — B1+B2+B4.
3. **(6)** Near blocks are UNSHADED (`block_atlas.gd:243`, `block_materials.gd:165,178,192`)
   — they never read A4's light; the far shell self-shades, hence the near/far split.
   Fix = compose the absolute day factor into the near materials (B3), not "more light
   dimming".
4. **(5)(7)** Correct sun law = transmittance over the viewer→sun **atmospheric path**
   (§3.2/§3.3), with the real solar data in §3.1: white 5772 K in space, ~5400 K pale
   warm at surface noon, 1800–2500 K red at the horizon, reddening through the limb from
   orbit — one continuous m(path).
5. **(4)(8)** No HDR exists on gl_compat/WebGL2 (R10G10B10A2, tonemapped-sRGB, per Godot
   4.4 docs); Compatibility glow exists (simplified) and is used optionally. The
   achievable dynamic range is the §3.5 authored luminance budget + glare-as-bloom +
   thresholded glow; the atmosphere is normalized to ≤ 0.35 so the sun is unambiguously
   the brightest object in every sky.
