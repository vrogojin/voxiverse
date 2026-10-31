---
name: voxiverse-atmo-sky-design
description: 2026-07-19 atmo-sky root causes — deployed flags readable from pck via get_script_constant_map; SN3 scaled-body driver DEAD below FLAT_WORLD return; sun invisible = 8px no-glare salience; night side lit by through-planet light (authority lerp bug); design doc COSMOS-ATMO-SKY-DESIGN.md A0-A6
metadata: 
  node_type: memory
  type: project
---

2026-07-19, design-atmo-sky (Fable), branch `docs/voxiverse-atmo-sky-design` (fc609e2 off deployed 6a4ed23), doc `docs/COSMOS-ATMO-SKY-DESIGN.md`.

Durable facts:
- **Deployed flag values are readable from `build/web/index.pck`**: run the custom editor headless with `--main-pack build/web/index.pck --script <probe>.gd` and call `get_script_constant_map()` on `res://src/cosmos/cube_sphere.gd` (source greps lie — repo defaults are all false; the deploy bakes ON: ORBITAL_SKY, FP_SCALED_BODY, ATMO_VISUAL_RAMP, SN_SUN_OCCLUSION, SHELL_TERMINATOR_TINT, FP_SKY_DSKY_R, SKY_MOONSHINE(+LIGHT), FLAT_WORLD; OFF: SKY_SCATTER_RAMP, FP_BODY_LOD, MULTI_BODY).
- **Stranded-driver bug class in main._process is recurring**: anything placed below the `FLAT_WORLD` early-return (main.gd:206 at 6a4ed23) is dead in production — killed the shell driver (fixed 0b2a934) and STILL kills the SN3 scaled-body/camera-far block (main.gd:228-232) ⇒ cam_far pinned 9000 at d=167k (telemetry-proven), planet far-clipped from space.
- Sun/moon "invisible" = physically-exact 0.53° discs ≈ 8px at 1080p with no gl_compat bloom — a salience problem; NOT clipping/fog.
- Night side "lights up on arrival" = occlusion_light's `lerp(1, occ, space_mix(h))` authority hands light_energy back to 1.0 near the surface while shadow-less DirectionalLight shines through the planet. Key identity: occlusion_factor degenerates to the sun-below-horizon test at |p|→R — it IS the universal day/night dimmer; the authority blend is the bug.
- Space sky tinted = space_mix band 192..960 vs ATMO_TOP=384 (residual camera-keyed twilight ramp at LEO altitudes); SKY_SCATTER_RAMP was OFF and innocent.
- No space-side atmosphere existed at all; design adds ONE closed-form additive shell (limb halo from outside == horizon-band sky from inside, same curves as ground sunset).

**Why:** future agents keep mis-attributing live behaviour to source defaults and re-deriving these root causes. **How to apply:** when debugging the live build, dump flags from the pck first; when adding per-frame drivers to main.gd, put them ABOVE the FLAT_WORLD return. See [[voxiverse-seamless-scales]], [[voxiverse-never-oom-web]].
