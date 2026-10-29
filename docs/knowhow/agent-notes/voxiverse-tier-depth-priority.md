---
name: voxiverse-tier-depth-priority
description: Far-ring-over-blocks poke root-caused (2026-07-17) — NOT depth precision; skew+staleness; envelope+bias+ordering design in docs/COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md
metadata: 
  node_type: memory
  type: project
---

User bug "far LOD terrain sometimes renders OVER the blocks" root-caused 2026-07-17
(docs/COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md, commit db6864f on deploy/perf-plus-sky):

- RC-A steady: constant BACKSTOP_SINK=6 violated by ~10-block worst-case overshoot; dominant
  omitted term = radial-vs-normal relief skew (far ring pushes relief along d̂, near lattice
  along facet normal n̂; up to relief·sin2.65°·slope ≈ 5–8 bl at facet corners on steep tall
  terrain). Raising BACKSTOP_CELLS cannot fix it (resolution-independent).
- RC-B transient (loudest): facet entering pool keeps UNSUNK CELLS=4 quad (15–25 bl chord
  overshoot) for the deferred-rebuild window (~0.1–1 s) while near meshes arrive. Departing is
  benign (dip) → asymmetric make-before-break fix is cheap.
- RC-C exculpated near-field: 24-bit depth @ near=0.05 gives quantum ≤0.43 bl where blocks
  exist; but sink-6 = 1 quantum at z≈2.24k, skin sink-1.5 at z≈1.12k → range cliff for any
  tier extension past ~1 km. near 0.05→0.25 = free 5×.
- Design: I1 min-envelope vertices (per-footprint minima, 3×3 dilated — convexity proof) +
  I2 per-tier constant window-space depth bias via ShaderMaterial POSITION.z (k quanta;
  BaseMaterial3D has no polygon offset) + sticky/make-before-break backstop roles. One
  swappable TierPlace site shared with [[voxiverse-faceted-planet]] skin tier. Endgame:
  range-partition dual-viewport composite — WORKS in gl_compat (only depth-aware merge needs
  Forward+), gated on skin coverage, +12–16 MB RT ledger.
- Plan P0–P6 w/ flags FP_TIER_STICKY_BACKSTOP / FP_TIER_ENVELOPE / FP_TIER_DEPTH_BIAS;
  kill metric = poke_px magenta-recolour probe inside near-coverage mask, 0 required.

**IMPLEMENTED P1+P2+P3 (correctness core) — SHIPPED to deploy/perf-plus-sky, commit 9df834d (+ merge 27cb9a1), 2026-07-17 PM. Opus impl, I verified+falsified every gate myself.** New `godot/src/world/tier_place.gd` = the ONE policy site (pure statics; every accessor returns the shipped value when its flag is off). P1 sticky: far-ring backstop role grown eagerly to active∪ring-1 seam-neighbours (cap STICKY_RING1_MAX=12; +96kB dense-cache ceiling, bounded/asserted) + held late on exit → a facet is drawn SUNK before it enters the pool, never pairs a live near mesh with an unsunk CELLS=4 quad. P2 envelope: each backstop vertex height = min near-g over its dilated footprint (ENV_FINE_MULT=4× coarse, sampled via far ring's own `profile_at_dir` = byte-equal to sample_columns by the one-sampler law — a documented deviation from the design's sample_columns, correctness-equivalent, distant CELLS=4 facets keep the constant path as a follow-up); constant sink 6→ε=1.5 guard. P3 depth bias: far/skin StandardMaterial3D→a LIT vertex-colour ShaderMaterial writing `POSITION.z += 2k·2⁻²⁴·w` (k=8 far, k=4 skin; near blocks NEVER routed here) + faceted camera near 0.05→0.25. GATES (my independent run): verify_tier_depth 20/0 (envelope proof: margin −1.50 with vs +3.46 poke without), FLAT 6035/0, verify_farring_cover 14/0, verify_skin 19/0. FALSIFIED all three: ENVELOPE off→+3.46 poke returns; STICKY off→3 assertions red (B not pre-sunk/not sunk-at-spawn/doesn't survive rebuild window); DEPTH_BIAS off→2 red (materials revert to StandardMaterial3D). **NOT yet deployed live** — P3 is a visual change (ShaderMaterial appearance parity + near-plane raise clipping) that needs the user's eyes on a live A/B before default-on; live build stays the skin-OFF freeze-fix state until then. P4 skin-integration / P5 bubble-mask / P6 composite still unbuilt.

**⚠️ COMBINED P1+P2+P3 DEPLOYED LIVE 2026-07-17 ~21:08 → USER REJECTED (clear regress): (1) far-LOD still poked over blocks in some places, (2) "terrain did not look right", (3) lots of walking hitches. REVERTED immediately to the good build (21:16Z). Root-caused (impl-p1-sticky agent, verified by me):** the "wrong look" = P3's hand-written LIT vertex-colour ShaderMaterial does NOT render like the StandardMaterial3D it replaced on gl_compatibility (SAME class of failure to avoid going forward — prefer built-in materials/nodes, any bespoke lit spatial shader is a VISUAL RISK needing a live screenshot gate). The hitches = P2's envelope warm (4225 fine-grid samples/facet ≈ 15× the plain path → blows the 3ms WARM_BUDGET on one facet). The residual poke-in-places = P2 covers only BACKSTOP facets; distant CELLS=4 facets keep the constant sink (unhandled) + P1's sticky set is only active∪ring-1.

**P1 STICKY ISOLATED — SHIPPABLE, verified (feat/voxiverse-p1-sticky→merged to deploy/perf-plus-sky 7f0248e, 2026-07-18).** Per user "isolate P1 sticky alone, drop the shader swap." Finding: **sticky-alone does NOT hitch** (FALSIFIES "more sticky facets=hitch") — its only runtime delta is a bigger backstop set in the far-ring rebuild, which runs OFF the main thread under FP_FARRING_ASYNC_REBUILD; the only main-thread cost is +0.23ms bigger swap (183k vs 173k verts). ZERO runtime code change was needed (sticky was already correct with envelope+bias off: backstop_sink→BACKSTOP_SINK=6, material stays StandardMaterial3D). Agent only split verify_tier_depth by flag (STICKY-only=10/0, combined=23/0) + added probe_sticky_perf.gd. I verified: STICKY-only 10/0, runtime byte-identical (only tools/ changed), FALSIFIED (ring1→[active] only ⇒ 4 asserts red incl. the diagonal-ring proof that ring-1 MUST include diagonals: after A→B, B's neighbour was pre-sunk as A's diagonal so the crossing never flashes — do NOT shrink to active+4-seam). **VERDICT: P1-sticky-alone kills RC-B (the crossing FLASH) via make-before-break without the combined build's regressions — worth shipping. Honest limitation: it does NOT fix the STEADY distant-facet poke (that needs P2 done right + distant-facet coverage). Deploy it for the user to A/B the flash in the morning. Caveat: no-hitch verdict ASSUMES async rebuild is ON in deploy (it is; sync crossings are the ~300-700ms re-emit bomb).**

**⚠️ PRE-EXISTING NEVER-OOM LEAK flagged by the agent (NOT sticky's fault — happens sticky-OFF too, in the SHIPPED far-ring path): `facet_far_ring.gd` `_bpos_cache` never evicts → grows unbounded with crossing count (measured 5→26→44 entries over 8 crossings). Slow, but unbounded = violates NEVER-OOM. Follow-up: add eviction (risk the shipped path carefully). Track for a dedicated fix.**
