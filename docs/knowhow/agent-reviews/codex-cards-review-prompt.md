ADVERSARIAL CODE REVIEW. A new render tier `FP_STRUCT_CARDS` (far-village impostor cards) was just implemented
in this Godot 4.4.1 voxel-planet game (Web/WASM, WebGL2 gl_compatibility). Your job is to TRY TO BREAK IT before
it ships to a live A/B — find correctness bugs, gl_compatibility shader hazards, byte-off violations, and
control-plane regressions. Be ruthless and specific (file:line). This is READ-ONLY — do not modify code.

## What to review
- The commit: run `git show d5d3620` (or `git show HEAD`) in the repo — the whole FP_STRUCT_CARDS implementation.
- The design it must conform to: `docs/COSMOS-STRUCT-IMPOSTOR-DESIGN.md`.
- New/changed source:
  - `godot/src/world/struct_card_kit.gd` (NEW — pure statics: archetype table, atlas rasterizer)
  - `godot/src/world/facet_far_structures.gd` (the tier — card mesh/material/shader, _resnapshot precompute, _rebuild two-sink, _band_code split, _apply_shell_visibility)
  - `godot/src/world/structure_gen.gd` (`unpack_root`)
  - `godot/src/cosmos/cube_sphere.gd` (`FP_STRUCT_CARDS` + STRUCT_CARD_* consts)
  - `godot/src/tools/verify_structures.gd` / `verify_fartier_walk.gd` (the new gates)
- Context to compare against: `godot/src/world/facet_far_trees.gd` (the far-tree card tier this copies — verify the copy is faithful where it matters: MultiMesh COLOR trap avoidance, set_buffer, custom_aabb, billboard math).

## Focus — the implementer's own flagged risks (verify or refute each), plus anything else
1. **gl_compatibility shader compile.** The card VERTEX shader uses `world_vertex_coords`, `CAMERA_POSITION_WORLD`, and in-shader `atan`/`mod` sector-selection. Headless can't compile it (dummy renderer). Is this actually gl_compatibility/WebGL2-SAFE? Check every builtin/function against GLES3/WebGL2 limits (precision, `atan(y,x)` range, `mod` on floats, const arrays, integer ops, varying limits). Name anything that won't compile or will misbehave on WebGL2.
2. **The Bayer dissolve** uses a local `float m[16] = float[](...)` const array (under FP_STRUCT_SHELL_BAND). Is a const float array indexable by a computed int legal + correct in gl_compatibility? 
3. **Anchor equality / vertical pop.** Card base origin uses `datum_lift` at the footprint CENTRE; the cube mesh uses per-vertex `datum_lift`. Can this cause a visible vertical jump at the cube→card handoff (only under FP_DATUM_BAKE)? Bound the error.
4. **Billboard frame math on a SPHERE.** Verify the camera-facing quad math: radial-up = house vertical axis, horizontal axis faces camera, roof cap tangent to the planet. Does the in-shader sector selection (from camera_pos + instance origin + house axes) actually pick the right atlas view? Check the atan/±π wrap and the frame_basis handedness (door↔sector-0 mapping).
5. **Byte-off.** With FP_STRUCT_CARDS=false, is EVERY new branch bypassed so behavior is verbatim the merged-cube tier? Grep for any unguarded new code. (FLAT gate passed 6042/0 — but confirm no runtime-only path escapes the guard.)
6. **Control-plane preservation.** `_card_prec` is a Dictionary keyed by ROOT (not index-parallel with `_centres`) because `_rebuild` sorts nearest-first. Is that sort-safe and staleness-free across a version bump? Does the split-edge band code 4 correctly re-arm the WALK_CALM fingerprint so the parked-camera zero-rebuild property survives? Does the near-handoff cull still gate both sinks identically?
7. **Player-built guard.** Confirm root≥0 (tracker/SOURCE) structures NEVER route to cards at any distance — trace `_card_eligible`/`_precompute_card` and prove it.
8. **NEVER-OOM.** The card instance cap (STRUCT_CARD_INST_MAX=2048) + atlas bytes — is the ledger correct and bounded?

## Deliverable
A ranked list of findings: each with file:line, severity (P0 ships-broken / P1 wrong-under-some-input / P2 cosmetic), a concrete failure scenario, and a suggested fix. Then an overall verdict: is this SAFE to deploy to a live A/B (where the shader finally compiles on real WebGL2), or are there P0/P1 issues to fix first? Distinguish "will crash/not-compile/regress" from "might look slightly off." Return the full review as your final message.
