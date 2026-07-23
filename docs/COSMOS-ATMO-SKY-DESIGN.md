# COSMOS ATMO-SKY — unified atmosphere + celestial + day/night rendering

**Status: DESIGN (root-cause + staged plan). 2026-07-19. Owner: design-atmo-sky (Fable).**
Audited build: the LIVE deploy at `deploy/perf-plus-sky` **6a4ed23**, flag values read
directly out of the deployed `build/web/index.pck` (headless `get_script_constant_map`
dump — see §1.1), behaviour confirmed against the pilot session's remote-bridge frames
+ telemetry (`tools/remote-bridge/results/`, 2026-07-19 22:5x).

The goal: ONE physically-motivated atmosphere/lighting/celestial model that is
consistent from OUTER SPACE and from the SURFACE — the terminator you see from orbit
and the sunset you stand in on the ground are the SAME curves; the space sky is
star-black; the Sun and Moon are visible, correctly placed, correctly lit; the
atmosphere renders as a blue limb halo around the planet from space and as the sky
gradient from inside, with no pop at the border (SEAMLESS-SCALES), on gl_compat,
under NEVER-OOM.

---

## 1. The deployed build, precisely

### 1.1 Flag fingerprint (read from the deployed pck, not from source)

The repo source has every sky flag `false`; the deploy bakes them. Dumped from
`build/web/index.pck` (2026-07-19 22:43, the build the pilot flew):

| ON | OFF (relevant) |
|---|---|
| FACETED, **FLAT_WORLD**, ORBITAL_SKY, FP_M3_ORBIT, **FP_SCALED_BODY**, FP_SHELL_CAMERA_SET, FP_SHELL_PREWARM, ATMO_VISUAL_RAMP, SN_SUN_OCCLUSION, SKY_MOONSHINE(+LIGHT), **SHELL_TERMINATOR_TINT**, FP_SKY_DSKY_R, SN_DEVNAV, ORBIT_* (attitude/6dof/land), SN_ATMO_BRAKING, FP_SEASONS, FP_CLIMATE_BIOMES, FP_FARRING_FULL_COVER, FP_CPPGEN | **SKY_SCATTER_RAMP**, FP_BODY_LOD, FP_MOON_RING, MULTI_BODY, SOI_SWAP, FP_CLIMATE_GRID, FP_CLOUDS/PRECIP/STORMS |

Two consequences that reframe the bug reports:

* **`SKY_SCATTER_RAMP` is OFF in the live build.** The orbit sky-colour change (bug 3)
  is *not* that flag — it is the base twilight ramp under a too-wide space band (§2.3).
* **`FLAT_WORLD=true` + `FP_SCALED_BODY=true`** interact fatally: the SN3 driver block
  is stranded below the FLAT_WORLD early-return and never runs (§2.0).

### 1.2 Live evidence (pilot session)

* Telemetry: `"cam_far":9000` while `sh_d:166973.6 / sh_h:160602.6` — the camera far
  plane is still the shipped 9000 with the pilot 160 k blocks out. (`cam_far` is read
  live from `player.camera_far()` → the real `Camera3D.far`.)
* Frames 053/011/030 (alt 494/925/1006): terrain **fully lit** under a **black starry
  sky**; **hard terrain/space edge at the limb — no atmosphere halo**; **no Sun or Moon
  disc anywhere among the stars**; thermometer reads 6 000–13 000 °C off-planet
  (separate sim-layer bug, flagged to orchestrator, out of scope here).

---

## 2. Root causes (each with file:line at 6a4ed23)

### 2.0 The enabling defect: the SN3 scaled-body driver is DEAD in production

`godot/src/main.gd:206` — `if CubeSphere.FLAT_WORLD or _player == null: return`
sits ABOVE the SN3 block at `main.gd:228-232`
(`CosmosScale.on()` → `player.apply_scaled_camera_planes(h, d)` +
`world.apply_scaled_body(cam)`). The faceted production game ships `FLAT_WORLD=true`,
so with `FP_SCALED_BODY` baked ON **the block never executes**: camera near/far never
ramp (far pinned at `FacetFarRing.CAMERA_FAR = 9000`, `facet_far_ring.gd:22`), and the
far ring never gets the distance clamp. This is the *same stranded-driver class* as the
shell-driver bug already fixed in 0b2a934 — and the comment at `main.gd:198` even
records it: "*the SN3 scaled-body ramp (also stranded below the return) …*". It was
never moved.

Consequences: above h ≈ 3–6 k the planet's far side/limb exceeds the 9000 far plane and
is progressively **clipped away**; from deep space (the pilot's d = 167 k) the planet is
entirely gone. Telemetry (`cam_far:9000` at `sh_d:166973`) is the conviction.

### 2.1 Bug 1 — Sun and Moon invisible

**They are not clipped and not fogged.** With `FP_SKY_DSKY_R` on,
`_dsky = CAMERA_FAR·0.95/1.05 ≈ 8143` (`cosmos_sky.gd:41-42, 285`); the star dome edge
is 8550; both are inside the (stuck) far plane 9000. `disable_fog = true` on both
impostors (`cosmos_sky.gd:305, 339`) handles the 8820-opaque depth fog.

**Root cause = physically-exact angular size with zero perceptual support.**
`EPH.angular_diameter` (`cosmos_ephemeris.gd:254-258`) gives the real 0.53° for both
Sun and Moon; the impostor is sized to that exactly (`cosmos_sky.gd:414-422`):
radius ≈ 38 blocks at 8143 → **≈ 8 px at 1080p / 70° FOV (4 px on the pilot's 540p
stream)**. gl_compat has no bloom/HDR glare, so the Sun is a 8-px pale dot — by day
invisible against the bright sky, at night/in space **indistinguishable from the
procedural star-dome points**; the Moon is an 8-px dim lit disc, likewise lost. The
real sky's sun dominates through glare, which we do not render. (This also explains why
the O0-era sunset screenshot passed at R = 3072: same tiny disc, but bright-dot-on-dark
was findable when someone knew to look.)

**Latent occlusion-order hazard (must be fixed WITH 2.0):** once the far plane really
ramps, the planet renders at distances ≫ D_SKY. The opaque impostors at 8143 would then
draw **in front of the Earth disc**, and the star dome (additive, `depth_draw_never`,
depth-tested at 8550 — `cosmos_sky.gd:88, 344-374`) would pass the depth test against a
planet at 18 k+ and sprinkle **stars over the planet**. Sky-vs-planet occlusion must
become analytic (§3 C5): D_SKY is a *sky sphere*, not a distance.

### 2.2 Bug 2 — day/night follows the camera; the dark side "lights up"

Four stacked causes; the common disease is **global, camera-keyed scalars where the
model needs absolute per-point functions of the ephemeris sun**:

1. **The occlusion dimmer surrenders authority exactly where it matters.**
   `cosmos_sky.gd:191-193` (`occlusion_light`):
   `light_energy = lerp(1.0, occlusion_factor, space_mix(h))` — `space_mix` is 0 below
   h = 192 (`cosmos_sky.gd:151-152`). Shadows are OFF (D11), so a `DirectionalLight`
   with energy 1.0 **shines through the planet**: on the night side every slope/wall
   whose normal faces the through-planet sun direction is fully lit. Descending toward
   the dark side ramps `light_energy` *up* from ~0 (orbital umbra) to 1.0 (surface) —
   the pilot's "**reach the dark side and it suddenly lights up**", frame-confirmed
   (fully-lit terrain at alt 494–1006 under a black sky).
2. **The surface regime never dims the light at night.** The elevation ramp
   (`_ramp_environment`, `cosmos_sky.gd:463-506`) dims only ambient/background — it was
   authored for the pre-sky flat game, which had *no* DirectionalLight at all.
3. **The shell tint band is WHITE on the night side.** `facet_far_ring.gd:1047`:
   `up = smoothstep(-0.10, 0.0, mu)` → for μ < −0.10 the band weight is 0 and the tint
   returns to `vec3(1.0)` — the deep-night hemisphere of the globe carries **no
   darkening from the shader**. The "terminator" the pilot sees is partly the band
   itself (T(0) ≈ (0.20, 0.02, ~0) — a near-black crimson arc) plus the
   DirectionalLight Lambert on the ring's real normals — and that Lambert contrast
   **dies whenever the player's own umbra state dims the global light**, so the globe's
   look tracks the camera, not the sun.
4. **Under a working scaled body the tint centre is wrong.** The shader assumes planet
   centre = scene origin (`facet_far_ring.gd:1040, 1049-1050`:
   `mu = dot(normalize(wp), sun_dir)`), but scale-about-camera moves the rendered
   centre to `(1−s)·cam` (`cosmos_scale.gd:67-68`) — after fixing 2.0, the terminator
   would literally follow the camera above D_ENGAGE.

**The unifying insight for the fix:** at the surface, `occlusion_factor`
(`cosmos_sky.gd:178-186`) *already degenerates into the sun-below-horizon test* —
as |p| → R, `ang_radius = asin(R/|p|) → 90°`, so "the planet's disc covers the sun" ≡
"the sun is below the tangent horizon". The umbra dimmer and the sunset dimmer are the
SAME function; the `space_mix` authority blend that switches it off near the ground is
the bug, not the physics. Delete the blend; widen the penumbra near the ground
(twilight), keep it sharp in vacuum.

### 2.3 Bug 3 — sky colour changes at orbit

`SKY_SCATTER_RAMP` is OFF in the deployed pck — it is innocent *in this build* (though
it shares the same missing altitude gate for when it is baked on, `cosmos_sky.gd:517-523`).

**Root cause:** `_ramp_environment` composes
`background = NIGHT.lerp(DAY, twilight(camera elev))` then blackens it by
`sm = space_mix(h)` with the band **192..960** (`SPACE_MIX_LO/HI`,
`cosmos_sky.gd:151-152`) — but the atmosphere ceiling is **ATMO_TOP = 384**
(user-locked, `cube_sphere.gd:546`). Full black needs h > 960 = 2.5·ATMO_TOP, so at
LEO-ish altitudes (400–900) the space sky still carries 20–60 % of the camera-keyed
day/night ramp: crossing the terminator in orbit visibly re-hues the "space" sky, and
`star_fade = max(night_fade, sm)` (`cosmos_sky.gd:487-488`) half-fades the stars on the
day side. Physics check: ρ(384) = e⁻³ ≈ 5 % — the tint should be ~0 *at* ATMO_TOP,
with the whole fade INSIDE the atmosphere.

### 2.4 Bug 4 — no atmosphere limb around the planet from space

**Nothing renders it — missing feature, not a broken one.** `ATMO_VISUAL_RAMP` is
Environment-property writes only (`cosmos_sky.gd:500-504`: background/fog/ambient at
the *camera*); `SHELL_TERMINATOR_TINT` multiplies terrain albedo. No geometry, shader,
or pass produces scattering seen from outside; the frames show a hard one-pixel
terrain→space edge at the limb.

---

## 3. The unified model — one atmosphere, one set of curves, five consumers

All curve math lives as PURE STATICS (engine-free, headless-gated, GLSL twins pinned to
the GDScript by gates — the established CosmosSky pattern). Parameters (all existing or
derived, no new tunables beyond three):

* Density `ρ(h) = exp(−h/H)`, `H = H_SCALE = 128` (shared with SN1 drag).
* Ceiling `ATMO_TOP = 384 = 3·H` (user-locked; ρ = 5 % there).
* Rayleigh vertical optical depths `τ⃗ = (0.042, 0.098, 0.245)` RGB (existing, real).
* Air mass `m(μ)` Kasten–Young (existing `air_mass`), generalized `m(μ,h) = m(μ)·ρ(h)`.
* Transmittance `T(μ,h) = exp(−τ⃗·m(μ,h))` — `T(μ,0)` IS the existing `scatter_tint`.
* **`atmo_vis(h) = 1 − smoothstep(0.5·ATMO_TOP, ATMO_TOP, h)`** — the in-atmosphere
  authority; exactly 0 in space. (Replaces `space_mix`'s 192..960 band; C¹.)
* **`day(x̂) = smoothstep(−μ_t, +μ_t, x̂·ŝ)`**, `μ_t ≈ 0.12` — the ABSOLUTE terminator
  factor at surface direction x̂; the terminator is the great circle ⊥ ŝ by construction.
* `occ(p)` = existing `occlusion_factor(ŝ, p, R_vox)` — sun visibility from point p,
  **promoted to the universal dimmer** (it is the horizon test at the surface, §2.2),
  with altitude-varying penumbra `pen(h) = lerp(0.10, 0.005, min(h/ATMO_TOP, 1))`
  (long twilight at the ground ≈ 1.5 min of the 45.5-min day; sharp in vacuum).

ŝ is always `EPH.dir_to_bodyfixed(observer, "sun", t)` — ephemeris-absolute, already
correct (`cosmos_sky.gd:403`). Nothing below introduces any camera-relative sun.

### The five consumers

**C1 — the DirectionalLight (near-field: blocks, skin, player).**
`light_energy = occ(cam, pen(h))` — always, no authority lerp (deletes the §2.2 bug).
`light_color = T(μ_cam, 0)` — the sun's light itself reddens through sunset, so lit
geometry agrees with the sky. Ambient: night floor + moonshine as today, with the
umbra factor kept but its authority also removed (ambient = floor·lerp(AMBIENT_UMBRA,
1, occ) — continuous, absolute). Night at the surface = ambient-only — which is
exactly the pre-ORBITAL_SKY night look, restored.

**C2 — the globe (far-ring shell shader v2).**
UNSHADED (immune to the global light/ambient — the fix for "the globe's look tracks
the camera"), per-vertex:
`v_col = COLOR.rgb · (NIGHT_FLOOR + (1−NIGHT_FLOOR)·day(n̂)) · mix(1, T(μ,0), band(μ))`
where `n̂ = normalize(wp − planet_centre)` with **`planet_centre` a uniform** fed the
scaled render centre (fixes §2.2-4), μ = n̂·ŝ. `band(μ)` is the existing terminator
band (kept — it is the space-side sunset arc); `NIGHT_FLOOR ≈ 0.06` keeps the night
hemisphere faintly earthshine-readable, absolutely dark from every vantage point.
StandardMaterial fallback retained permanently (P3 shader-failure class).

**C3 — the camera sky (Environment writes).**
Exactly today's ramp, with `atmo_vis(h)` replacing `space_mix` everywhere:
`background = ramp(elev)·T-recolour·atmo_vis(h)` (black above ATMO_TOP — bug 3 fix);
`star_fade = max(night_fade, 1 − atmo_vis(h))`; fog density `ρ(h)` (unchanged shape).
`SKY_SCATTER_RAMP`'s weight gains the same factor: `w = sunset_weight(μ)·atmo_vis(h)`
— then it can finally be baked ON.

**C4 — the atmosphere shell (NEW: the limb halo AND the in-atmo sky, one object).**
ONE inverted SphereMesh, radius `R + 2·ATMO_TOP`, planet-centred, riding the same
scaled placement as the far ring; `cull_front + blend_add + depth_draw_never` (never
occludes; the planet's own depth correctly kills it behind the disc, exactly the star
dome discipline). Fragment shader, closed-form per pixel (uniforms: cam, centre, ŝ,
R, H — a handful of dots/sqrts, gl_compat-safe, no loops/volumetrics):

* view-ray closest-approach altitude to the centre: `h_min = |x_ca − centre| − R`;
* path strength `L ∝ chord length through the shell · ρ(max(h_min, 0))`;
* colour `= τ⃗-weighted Rayleigh blue · day(x̂_ca) · mix(1, T(μ_ca, 0), band(μ_ca))`
  — the SAME `day/T/band` as C2, so the limb reddens through the terminator and goes
  dark on the night side **by the same curves the ground sunset uses**;
* out `= colour · L · gain`, additive.

Seen from space: a blue limb halo, reddening across the terminator, black on the night
side (bug 4). Seen from inside (the same mesh surrounds the camera): near-horizon rays
have long chords → a bright horizon band; overhead short → thin blue — the sky
gradient. One formula, both vantage points, continuous in camera altitude by
construction — the SEAMLESS-SCALES atmosphere-border requirement is met structurally,
not by tuning. C3's background remains the base layer; C4 composes additively; their
sum at h = 0 is tuned once against the current surface look (live screenshot gate).

**C5 — Sun + Moon impostors (placement kept; presence and correctness added).**

* *Analytic planet occlusion:* impostor hidden (alpha→0 over the limb) when the planet
  disc covers its direction — `occ(dir_to_body)` reused; star dome gets
  `planet_dir/planet_cos_ang` uniforms and discards fragments inside the disc. This is
  MANDATORY the moment §2.0 is fixed (see §2.1 hazard). D_SKY stays 8143 — the sky is
  angular; we do NOT chase the far plane with D_SKY (rejected: depth precision + dome
  would swallow the scaled planet; analytic occlusion is exact and free).
* *Perceptual presence:* an angular-size FLOOR (`SUN_MIN_ANG ≈ 2.0°`, `MOON_MIN_ANG ≈
  1.5°` — consts, taste-tunable) applied to the impostor radius, plus an additive
  radial-falloff glare quad on the Sun (~5× disc radius, brightness × occ(cam) so it
  dies at sunset/eclipse/umbra) — the perceptual job real glare does. Sun disc colour
  × `T(μ_cam,0)` — it reddens at sunset with everything else.
* *Moon self-phase:* replace the Moon's lit StandardMaterial with a small unshaded
  shader computing Lambert phase analytically from a `sun_dir` uniform. REQUIRED with
  C1 — otherwise dimming the global light at night blacks out the Moon exactly when it
  should shine. (Phase geometry is already exact from the ephemeris; eclipse-redden
  albedo write kept.)

Day/night absolutes, restated as the invariant the gates pin: **every rendered
day/night quantity is a function of (surface point or camera position, ephemeris t)
only** — never of camera orientation, and the only camera-*position*-dependent terms
are genuinely local ones (the camera's own sky, fog, its light/occlusion state).

---

## 4. Staged plan (flags; every stage default OFF ⇒ byte-identical; independent bake order noted)

| Stage | Flag | Content | Depends on |
|---|---|---|---|
| **A0** | `FP_SN3_MAIN_LIVE` | Move the SN3 block (`main.gd:228-232`) ABOVE the FLAT_WORLD return at `main.gd:206` (the 0b2a934 shell-fix precedent). Un-clips the planet from space; camera far ramps `max(9000, 1.2·√(d²−R²))`. | — |
| **A1** | `FP_SKY_PLANET_OCCLUDE` | Analytic sun/moon impostor hide behind the planet disc + star-dome disc-mask uniforms. | must bake WITH A0 |
| **A2** | `FP_SUN_PRESENCE` | Angular floors + Sun glare quad + sunset-reddened disc. | none (better after A1) |
| **A3** | `FP_ATMO_SPACE_ZERO` | `atmo_vis(h)` replaces `space_mix` (band 192..384, zero above ATMO_TOP); star_fade fix; `SKY_SCATTER_RAMP` gains ·atmo_vis then bakes ON. | — |
| **A4** | `FP_LIGHT_ABSOLUTE` | C1: occ-always dimmer + pen(h) twilight + light colour T(μ); ambient authority removed; **Moon self-phase shader lands here** (regression guard). | — |
| **A5** | `FP_SHELL_ABSOLUTE` | C2 shell shader v2: unshaded + `planet_centre` uniform + NIGHT_FLOOR·day(n̂) + kept band tint. Supersedes SHELL_TERMINATOR_TINT v1. | A0 (for centre feed) |
| **A6** | `FP_ATMO_SHELL` | C4 atmosphere shell mesh + shader — the limb/beauty stage. | A3 (no double tint), A5 (matching curves) |

Recommended bake order: **A0+A1 → A3+A4 → A5 → A2 → A6.** A0+A1 restore "the planet
exists from space"; A3+A4 kill the pilot's lighting/space-sky complaints; A5 makes the
terminator absolute; A6 is the payoff.

### Existing pieces: keep / fix / supersede

| Piece | Verdict |
|---|---|
| CosmosEphemeris, body-fixed ŝ, impostor placement, star dome, D_SKY derivation (`FP_SKY_DSKY_R`) | **KEEP** (D_SKY stays const 8143; occlusion is analytic, not distance-based) |
| `occlusion_factor` | **KEEP + PROMOTE** to the universal dimmer (pen(h) added) |
| `occlusion_light` / `occlusion_ambient` authority lerps (`cosmos_sky.gd:191-200`) | **SUPERSEDED by A4** (delete the `space_mix` authority) |
| `space_mix` 192..960 band | **SUPERSEDED by A3** `atmo_vis` |
| `ATMO_VISUAL_RAMP` | **KEEP flag**, its blackening/fog/ambient re-driven through `atmo_vis` |
| `SKY_SCATTER_RAMP` | **FIX (·atmo_vis) in A3, then bake ON** |
| `SHELL_TERMINATOR_TINT` v1 shader | **SUPERSEDED by A5** (band tint retained inside v2; StandardMaterial fallback retained permanently) |
| `SKY_MOONSHINE`(+LIGHT), eclipse redden | **KEEP** (compose under A4's absolute ambient) |
| `FP_BODY_LOD` / `FP_MOON_RING` handover | **UNAFFECTED** (placement unchanged) |

Known live check (not a stage): the skin tier (retires at h ≈ 4 k) stays lit by C1's
global light while the shell (C2) is self-shaded; in the 0–4 k overlap the camera is
low enough that C1's local state ≈ the local day factor, so no visible seam is
expected — verify on the A5 screenshot pass.

---

## 5. Gates

**HEADLESS-PROVABLE** (extend `verify_orbital_sky.gd` / new `src/tools/verify_atmo_sky.gd`;
all curves have GDScript twins pinned to the GLSL by construction, the existing
G-SHELL-TINT discipline):

* `G-AS-FARRAMP` (A0): with the flag on, a scene-tree run asserts `player.camera_far()`
  ramps with injected altitude (9000 at h=0; 1.2·√(d²−R²) beyond) and near ramps
  0.05→8; flag off ⇒ shipped values (FLAT identity).
* `G-AS-OCC` (A1): impostor visibility over a case grid (sun in front / behind disc /
  grazing the limb); star-mask maths twin; C¹ across the limb.
* `G-AS-ZERO` (A3): `atmo_vis(ATMO_TOP) == 0` exactly; C¹; h=0 endpoints byte-equal to
  shipped; scatter weight ≡ 0 above ATMO_TOP at every μ.
* `G-AS-ABSLIGHT` (A4): at fixed t, `light_energy` is a function of camera POSITION
  only (orientation sweep invariant); night-side positions ≈ 0 at every altitude
  (kills the through-planet lighting by assertion); noon = 1; dusk monotone through
  pen(h); Moon phase twin = ephemeris illuminated fraction.
* `G-AS-TERM` (A5): terminator geometry — day(x̂) = 0.5 exactly on the great circle
  x̂·ŝ = 0, symmetric, monotone along ŝ; tint twin equality on a μ grid; camera-position
  sweep leaves per-vertex values unchanged (absoluteness); fallback = shipped material
  byte-identical with the flag off; scaled-centre case: tint under s < 1 equals the
  unscaled tint of the same surface point.
* `G-AS-LIMB` (A6): closed-form twins (chord length, h_min) vs reference; limb
  intensity → 0 on the night side and above the shell; inside/outside continuity at the
  ATMO_TOP crossing (value + derivative at a camera path through the border); C2/C4
  curve agreement on a shared μ grid.
* Byte-off identity for EVERY stage: all-flags-off run of the full existing suite
  (FLAT 6035/0 class).

**LIVE-ONLY** (remote-bridge screenshots, the established loop): the LOOK — limb halo
blueness/thickness, terminator reddening from orbit vs the ground sunset (same-frame
pair), night-side darkness from every camera azimuth, Sun glare presence at day/dusk,
Moon phase at night, no-pop video of an atmosphere-border crossing and of a
day→terminator→night orbit pass, gl_compat shader compile sanity on device (P3 class:
any failure ⇒ flag stays off, fallback ships).

---

## 6. NEVER-OOM ledger

All additions are fixed-size, built once at setup, freed never, zero per-frame
allocation, no per-voxel storage. Bounds:

| Stage | Objects | Bytes (upper bound) |
|---|---|---|
| A0 | none (property writes) | 0 |
| A1 | 2 uniforms on the star-dome material; 2 visibility writes/frame | ~0 |
| A2 | 1 QuadMesh + 1 ShaderMaterial (glare) | < 4 KB |
| A3 | none (curve swap) | 0 |
| A4 | Moon ShaderMaterial replaces StandardMaterial | < 2 KB net |
| A5 | shell shader v2 replaces v1 + 1 vec3 uniform | ~0 net |
| A6 | 1 SphereMesh 48×24 (~1.2 k verts) + 1 shader + ~8 uniforms | < 100 KB GPU total |
| **Total** | ≤ 3 new nodes, 3 new materials | **< 110 KB, constant** |

Per-frame cost: O(10) uniform/property writes (the existing CosmosSky discipline);
one extra draw call each for glare (A2) and the atmosphere shell (A6) — +2 draws
against the ~30-draw live baseline; the A6 fragment shader is a handful of dots/sqrts
(no loops, no textures) on mostly-limb pixels.

---

## 7. Answers to the tasked suspicions (for the record)

1. *"D_SKY placement / far-plane clips the impostors"* — **No.** Impostors (8143) and
   dome (8550) sit inside even the stuck 9000 far plane; the invisibility is 8-px
   physical angular size with no glare (§2.1). The far plane DOES clip **the planet**
   from altitude, because the SN3 driver is dead (§2.0) — that is the FP_SCALED_BODY
   connection, and fixing it makes analytic sky occlusion (A1) mandatory.
2. *"Lit hemisphere follows the camera"* — the light/ambient are global camera-keyed
   scalars and the through-planet DirectionalLight lights the night side at low
   altitude (§2.2); the fix is the promoted absolute dimmer + self-shaded globe.
3. *"SKY_SCATTER_RAMP tints the space sky"* — that flag is OFF in the deployed build;
   the tint is the base twilight ramp under the 192..960 `space_mix` band vs the
   384-block atmosphere (§2.3). The ramp DOES need the same `atmo_vis` gate before it
   is ever baked on.
4. *"No atmosphere from space"* — confirmed missing entirely; C4 adds it as one
   closed-form shell consistent with the surface sky by shared curves (§2.4, §3).
