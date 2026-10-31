---
name: voxiverse-atmo2-design
description: "ATMO2 root causes (2026-07-20) — the night \"artifact\" IS the Sun; near blocks are UNSHADED (why A4 light dimming does nothing); A6 shell 6-80x overbright; no HDR on gl_compat; path-length sun model with H_OPT=30"
metadata: 
  node_type: memory
  type: project
---

ATMO2 investigation verdicts (docs/COSMOS-ATMO2-DESIGN.md, live build 5b1d276, pilot frames verified):

- **The pilot's night-sky "artifact" IS the Sun**: glare-only warm blob (frame-1784579719109-040.jpg) — disc renders at HALF its floored size because `_place_impostor` assumes SphereMesh default radius 1 but Godot's default is **0.5** (cosmos_sky.gd:923-927, mesh radius never set); colour is sunset-yellow even in vacuum because disc/glare/light colour key on camera-ELEVATION Kasten-Young air mass (cosmos_sky.gd:722-733, :847), not the viewer→sun atmospheric path.
- **Near voxel blocks are SHADING_MODE_UNSHADED** (block_atlas.gd:243, block_materials.gd:165/178/192, clouds too) — they NEVER read the DirectionalLight or ambient, so A4/FP_LIGHT_ABSOLUTE dims lights nothing listens to. That's the whole "surface bright at night while orbit view is dark" split (far ring A5 self-shades per-vertex, correctly). Fix = compose the absolute day(μ) factor into the unshaded material shaders (per-vertex μ = normalize(world)·ŝ works because Phase 2 fixed-frame makes globals planet-absolute, centre = scene origin — VERIFIED via telemetry |pos| = orbit_r).
- **A6 atmo shell strength = chord·ρ(h_min)/H is 6-80x overbright** (single-sample estimate valid only for exterior grazes) — the blown cyan-white sky/limb in frames 000/050, the daytime sun invisibility, and the artifact's "blue halo".
- **No HDR exists on the web renderer**: Godot 4.4 Compatibility renders 3D to R10G10B10A2, tonemapped-sRGB inline, "no HDR support" (docs); Compatibility glow DOES exist (simplified, since 4.2). Dynamic range must be an authored LDR luminance budget (sun disc = the only 1.0) + glare-quad-as-bloom + optional thresholded glow. Do NOT switch tonemap curve on an LDR-budgeted unshaded scene.
- **H_OPT=30 trick**: game atmosphere (H=128, R=6371) is too thick for real Rayleigh τ⃗=(0.042,0.098,0.245) to give both white noon and red horizon; a separate optical scale height H_OPT=30 yields horizon air mass ≈18, full-limb ≈36 ≈ real Earth's m-range. Smooth path formula: X = H·ρ(h)/sqrt(μ_v² + 2H/(πR)) (plane-parallel↔Chapman blend), fold at tangent for descending rays.
- Also: WeatherFX overwrites fog_density after CosmosSky every frame (weather_fx.gd:173 vs cosmos_sky.gd:860) — altitude fog dead with FP_PRECIP on; fog_depth_end pinned 8820 will paint the planet black from deep space once pilots fly high (A0 ramps camera far but not fog). Ephemeris moon incl=0 ⇒ every full moon is a lunar eclipse (crimson-dim at the brightest phase).
- Staged plan B0-B5 (FP_SUN_PATHLIGHT, FP_SUN_APPARENT, FP_ATMO_PATH_SHELL, FP_NEAR_DAYLIGHT, FP_MOON_PRESENCE, FP_FOG_ARBITER) in [[voxiverse-atmo-sky]] successor doc COSMOS-ATMO2-DESIGN.md.
