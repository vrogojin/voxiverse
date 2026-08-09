# COSMOS — Far-render "day-lit at night" terminator: root-cause + fix design

Status: DESIGN / root-cause (analysis only — no production code). Branch `deploy/cheats-eyeball`.
Author: Fable (shell). Task #98. Adjudicated by code + geometry; a live A/B pins the residual runtime tier.

Symptom (user, screenshot-confirmed): at local night the NEAR blocky terrain darkens correctly, but
the FAR-render shows a bright DAY-lit green strip/border — the far tier appears to ignore the
day/night terminator. Reported at facet 435, local night. Suspected exposed by the whole-planet
prebake (the far-skin is now baked/visible everywhere).

Related: [[voxiverse-night-terrain-centre]] (FP_NIGHT_TERRAIN_CENTRE, near-only), [[COSMOS-BACKGROUND-PREBAKE-DESIGN]],
COSMOS-TEXTURED-LOD-DESIGN §2V.3 (FP_SHADE_UNIFIED), COSMOS-ATMO-SKY §A5 (FP_SHELL_ABSOLUTE).

---

## 0. TL;DR — report which it is

**It is NONE of the three suspected causes. The far terminator IS implemented, IS correct
(centre-relative, not the near-bug's origin-relative normal), IS live-fed, and IS unified near==far
by construction — across EVERY far tier.** Verified in code:

- **Not "missing"** — every far material multiplies albedo by `voxi_shade(n, sun_dir)`:
  the shell/fine-skin/blocky-far-ring (`facet_far_ring.gd` `_SHELL_ABS_TEX_LIGHT:4218-4226` +
  `_apply_shade_unified:4562`), the smooth-V2 annulus (`facet_smooth_v2.gd:258-262`), and the
  TierPlace biased tier (`tier_place.gd:258-264`, unified variant under FP_SHADE_UNIFIED).
- **Not "wrong (origin-relative) normal like the near bug"** — every far tier uses
  `n = normalize(wp − centre)` with `centre = MODEL_MATRIX·0`, the TRUE planet radial. The shell's
  own transform is `Transform3D(Basis.IDENTITY, −_anchor_offset)` (`facet_far_ring.gd:1027`), so
  `wp − centre = VERTEX` = the exact body-fixed radial. The near path was fixed to the SAME law
  (`block_atlas.gd:93/118`, `n = normalize(v_wp − planet_centre)`, planet_centre = the shell's
  render centre). `voxi_light.gd:50-55` is the ONE shared law.
- **Not "solved-then-rolled-back / exists-but-off"** — the terminator path is ACTIVE in the live
  flag set (FP_SHELL_ABSOLUTE + FP_SHADE_UNIFIED + FP_NIGHT_TERRAIN_CENTRE all ON; `main.gd:307-322`
  pushes `current_sun_dir()` to shell, near, and smooth-V2 every frame). What WAS rolled back is
  `FP_SMOOTH_V2_LIT` — but that is RELIEF slope-shading (a per-cell face normal), a DIFFERENT axis
  from the terminator; correctly kept off (§4).

**Therefore the live symptom is NOT a shading-law error. It is a RUNTIME condition** — a `sun_dir`
uniform not reaching one specific far material at that moment, or a per-tier gap — which static code
cannot reproduce (all pushes fire under the live flags). §3 gives the decisive one-capture
disambiguation; §4 a robust flag-gated fix that makes the far terminator bulletproof regardless of
which push is intermittently failing, plus a gate that would have caught it.

**Physical explanation RULED OUT:** at alt 195 the horizon is only ~√(2·R·h) ≈ 1576 blocks ≈ 14° of
arc away (R=6371). The terminator moves ~15°/hr; at local midnight the visible far terrain is <14°
from the observer → still deep night. So bright-green far at midnight cannot be genuine day terrain
across the terminator — it is a bug, not physics.

---

## 1. The shared lighting law (all tiers, one law) — file:line

`VoxiLight.SHADE_GLSL` (`voxi_light.gd:42-56`) is string-included into every material shader under
FP_SHADE_UNIFIED:

```glsl
vec3 voxi_shade(vec3 n, vec3 sd) {
    float mu = dot(n, normalize(sd));
    float shade = max(night_floor + (1.0 - night_floor) * _day(mu), moonshine);  // night_floor=0.06, moonshine=0
    vec3 tint = mix(vec3(1.0), _scatter_tint(mu), _scatter_band(mu));
    return vec3(shade) * tint;
}
```

At night `mu < 0` ⇒ `_day(mu)=0` ⇒ `shade → 0.06` (6%). Every tier's ALBEDO = surface_colour × this,
so every tier darkens to ~6% at night. Consumers, all with `n = normalize(wp − centre)` and live
`sun_dir`:

| Tier | Material | Terminator site | sun_dir push |
|---|---|---|---|
| Near blocks (module atlas) | `block_atlas.gd` daylight twin | `:93/:118` `voxi_shade` | `main.gd:313`→`set_near_daylight_sun_dir` |
| Near per-id (slopes/water/debris) | `BlockMaterials` twins | shared `voxi_shade` | same site (`world_manager.gd:3174`) |
| Far shell + FINE skin + blocky far-ring | `sm2` (`_SHELL_ABS_TEX_SHADER`+`_apply_flatcolor`+`_apply_shade_unified`) | `:4226`→`voxi_shade` | `main.gd:308`→`set_shell_absolute_sun_dir` (`:4816`) |
| Smooth-V2 relief annulus | own `ShaderMaterial` | `facet_smooth_v2.gd:259` | `main.gd:322`→`set_smooth_v2_sun_dir`→`:485` |
| TierPlace biased tier | `_TIER_UNIFIED` | `tier_place.gd:259` | `set_shell_absolute_sun_dir` (relaxed guard) |

All read `current_sun_dir()` (`cosmos_sky.gd:101`, Earth's BODY-FIXED frame) — the SAME frame the
shell/near vertices live in (the planet is pinned to identity, `cosmos_sky.gd:6/1102`). So near and
far compute the identical `mu` at the same world point → identical shade. **Near dark ⇒ far must be
dark, by construction.** The observed far-bright therefore means one material's `sun_dir` (or its
being drawn at all with `voxi_shade`) is not what the code says at that instant.

---

## 2. Which tier is the bright strip? (the runtime unknown)

Static code cannot tell — all tiers are terminated. The candidates, by likelihood given "prebake
exposed it" + "border/strip":

1. **Smooth-V2 annulus (`facet_smooth_v2.gd`)** — HIGHEST suspicion. It is a SEPARATE material from
   the shell, rebuilt on facet crossings; `_make_material()` (`:296-301`) seeds `sun_dir=(1,0,0)`
   (day, +X). If the instance is recreated on a re-anchor and its `set_sun_dir` does not land that
   frame (or the push guard `_smooth_v2 != null` briefly fails during the rebuild), the annulus
   renders against a FIXED +X day-sun → a bright day-lit MID-RING band (a "strip/border" at hop
   2–4) while the shell + near track live time. This is exactly the FP_BLOCK_LOD "frozen at default
   sun (1,0,0)" failure `main.gd:300-306` documents for another tier — the smooth-V2 push has no
   such unconditional-write backstop.
2. **Shell fine-skin** — the prebake fills it everywhere; but it shares the shell `sm2` whose
   `sun_dir` is pushed unconditionally every frame (`main.gd:307-308`), so a persistent gap here is
   less likely (would need a material rebuild dropping the uniform for >1 frame).
3. **A tier drawn but not in the wired set** — e.g. a backstop/overlay. Lower likelihood (all far
   emission rides `sm2`).

**The disambiguation is a ONE-capture live A/B** (§3) — do not guess.

---

## 3. Decisive disambiguation (one live capture)

Add per-tier `sun_dir` echo telemetry (temporary, byte-off): each far material reports the `sun_dir`
its shader currently holds (`ShaderMaterial.get_shader_parameter("sun_dir")`) — `sd_shell`,
`sd_v2`, `sd_near`. Then at facet 435, local night:

- **If `sd_v2 ≈ (1,0,0)` while `sd_shell`/`sd_near` = the live night sun** → the bright strip is
  Smooth-V2 with a stale/default sun_dir (candidate 1 confirmed) → fix = the unconditional push
  backstop (§4.1).
- **If all three `sd_*` = the live night sun** yet a strip is still bright → the bright surface is
  a tier outside the echo set (candidate 3) → identify by A/B toggling `FP_SMOOTH_V2` off, then
  `FP_PLANET_MAP` off, and see which strip vanishes.
- **A/B toggles** (deploy CS_FLAGS): drop `FP_SMOOTH_V2` → if the strip disappears, it is the
  annulus; drop `FP_PLANET_MAP` → if it disappears, it is the fine skin.

This turns "which tier" from a guess into a measured fact in one reload.

---

## 4. Fix design — `FP_FAR_TERMINATOR_WELD` (robust, tier-agnostic)

Make the far terminator correct regardless of which push intermittently fails, WITHOUT touching
relief lighting.

### 4.1 Unconditional, single-authority sun_dir re-assert

Mirror the `main.gd:300-306` block-LOD lesson: from ONE authoritative WorldManager site called every
frame, push `current_sun_dir()` to EVERY far material unconditionally (shell, smooth-V2, block-LOD,
TierPlace), and — critically — **re-assert it immediately after any material/instance rebuild**
(hook the smooth-V2 `setup_instance` / shell `_make_material` to pull the last-known sun_dir at
creation, so a freshly-built material is never left at the `(1,0,0)` default for even one frame).
`FacetSmoothV2._make_material` seeds `sun_dir` from a cached `_last_sun_dir` instead of the hardcoded
`(1,0,0)`. Byte-off: flag false ⇒ the current push sites verbatim.

### 4.2 Keep terminator ≠ relief

The terminator (day/night darkening, `_day(mu)`, radial normal) is INDEPENDENT of relief
slope-shading (`FP_SMOOTH_V2_LIT` / `FP_SMOOTH_NORMAL_LIT`, per-cell face normal). This fix touches
ONLY the sun_dir delivery + the radial-normal terminator — `FP_SMOOTH_V2_LIT` stays OFF (its wrong
slope shadows are a separate, correctly-shelved concern). No relief normal is introduced.

### 4.3 Gate — `verify_far_terminator.gd` (would have caught this)

- **G-FT-EQ**: for a sampled set of world points across the near/far boundary at a night `sun_dir`,
  assert `VoxiLight.shade_tint(near_normal, sun)` == `shade_tint(far_normal, sun)` to ≤1e-6 (the
  unified-normal invariant — already the spirit of `verify_shade_unified` G-VL-EQ; extend it to the
  smooth-V2 and TierPlace normals explicitly).
- **G-FT-FRESH**: after simulating a facet-crossing material rebuild, assert every far material's
  `sun_dir` parameter equals the last pushed value (NOT the `(1,0,0)` default) — the runtime-staleness
  guard the current code lacks. Falsify: a rebuild without the re-assert leaves `(1,0,0)` → night
  facet renders `_day(mu)` for a +X sun → bright.
- **G-FT-NIGHT**: at a night sun, assert every far tier's computed shade ≤ `night_floor + ε`
  (no tier stuck day-lit).
- **G-FT-OFF**: `FP_FAR_TERMINATOR_WELD=false` ⇒ push sites byte-identical; FLAT `verify_feature` 6042/0.
- **Live A/B (arbiter)**: facet 435 local night — the far strip darkens to match near; `sd_*`
  telemetry all show the live night sun; heap/fps flat.

---

## 5. Bottom line for the team-lead

- **Report: it is none of missing / wrong-normal / rolled-back.** The far terminator is present,
  centre-relative (correct radial, not the near-bug), live-fed, and unified near==far across the
  shell, fine-skin, blocky far-ring, smooth-V2, and TierPlace tiers. Physical (across-terminator)
  ruled out by the 14° horizon.
- **The live bug is a RUNTIME sun_dir delivery gap**, most probably the Smooth-V2 annulus reverting
  to its `(1,0,0)` default sun on a facet-crossing material rebuild (candidate 1) — the one far tier
  whose sun_dir push has no unconditional/rebuild-safe backstop, unlike the shell.
- **Fix = `FP_FAR_TERMINATOR_WELD`**: single-authority, unconditional, rebuild-safe sun_dir re-assert
  to all far materials + a freshness gate; terminator only, relief untouched (`FP_SMOOTH_V2_LIT`
  stays off).
- **One live capture with per-tier `sun_dir` echo telemetry pins the exact tier** before
  implementation — recommended first step (cheap, decisive).
