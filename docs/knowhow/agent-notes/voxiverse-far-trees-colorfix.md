---
name: voxiverse-far-trees-colorfix
description: "2026-08-12 SHIPPED+MERGED PR #55 (main 8ca78bf) — far-trees mesh-band black/cyan/green ROOT = GLES3 MultiMesh color-slot aliasing (custom-only MM + COLOR-reading shader), NOT snow/planet_centre; fix FP_FAR_TREES_COLORFIX (use_colors+white quad, stride 16→20); LIVE-VERIFIED clean green to horizon"
metadata: 
  node_type: memory
  type: project
---

Far-trees mesh band [128, 448+32) rendered black/cyan/oversaturated-green/blue squares (task #115).
ROOT (verified in engine source + pixel probe): **GL-compatibility MultiMesh with
`use_custom_data=true, use_colors=false` + a shader that reads `COLOR`** — the GLES3 backend
always allocates+binds the color slot with custom data (mesh_storage.cpp:1542, rasterizer_scene_gles3.cpp:3607),
`_multimesh_set_buffer`'s in-place repack leaves raw float bits of custom.x/.y in floats 12–13
(mesh_storage.cpp:1955-2001), and scene.glsl:545-551 multiplies COLOR by that slot UNGATED.
Result: r×=f16(lo(bits(delta)))=0, g×=f16(hi(bits(delta)))∈{0,1.875,2}, b×=f16(lo(bits(hue)))=random
→ exactly the observed red-less black/green/cyan/blue mix. Only the rung-1 MESH shader reads COLOR
→ only the mesh band; cards (atlas, no COLOR) + near voxel trees correct. INSTANCE_CUSTOM itself
decodes CORRECTLY (and as f16!). Snow pack/decode was consistent; planet_centre was pushed
before first rebuild — both leads refuted by pixel arithmetic (no tree albedo has b>0.2 → cyan
(38,255,255) unreachable multiplicatively).

**Why:** correct on Forward+/desktop and invisible to headless gates — web-only runtime defect;
only quantitative screenshot sampling caught it (see [[voxiverse-border-shade-weld]] lesson).

**How to apply:** any MultiMesh here must enable BOTH use_colors+use_custom_data (writing white
(1,1,1,1) to the color quad) OR its shader must never read COLOR. INSTANCE_CUSTOM on gl_compat is
HALF-FLOAT — ≤11 mantissa bits per component. Fix = FP_FAR_TREES_COLORFIX (stride 16→20, white
color quad, + hide-until-first-rebuild on de-orbit); design in docs/COSMOS-FAR-TREES-COLORFIX-DESIGN.md.
Slow descent bake ≈ FP_LOAD_DEFER settle latch + 1 facet/250ms enum pacing (~16s full reach, ~2.5s
visible band) — acceptable, optional cold-cache burst designed. Related [[voxiverse-far-trees-design]].

**SHIPPED+MERGED PR #55 (main 8ca78bf, 2026-08-12), bundled with [[voxiverse-near-leaf-cutout]] V2.**
Impl: 6 rung-1 mesh MultiMeshes get use_colors=CubeSphere.FP_FAR_TREES_COLORFIX + white (1,1,1,1)
color quad; RS packs [0..11] xform, [12..15] COLOR, [16..19] CUSTOM (color BEFORE custom) so custom
decode parity-identical; +48KB (6×512×4×4B) under FAR_TREES_BYTES_MAX; de-orbit hide = _stale latch
(visibility = not offsurf and not _stale; first rebuild clears). Gates verify_far_trees 49/0 all-on,
47/0 colorfix-off, FLAT 6042/0. LIVE A/B: far trees clean green to horizon (aerial alt 87), no black/cyan.
