---
name: voxiverse-o4c-soi-walk
description: 2026-07-19 O4c SOI-swap + walkable Moon landed on feat/voxiverse-o4c behind SOI_SWAP (default off)
metadata:
  type: project
---

O4c (walkable Moon: SOI hand-off + landing + surface walk) landed on `feat/voxiverse-o4c` off
`deploy/perf-plus-sky`, behind new flag `CubeSphere.SOI_SWAP := false` (requires MULTI_BODY). OFF ⇒ byte-identical.

Architecture: the nav/orbital/gravity/drag kernels were ALREADY per-body generic (every func takes `body`).
The gap was pure WIRING — `player._dominant_body()` was hardcoded "earth". Now it returns `_dom_body`,
refreshed each tick: surface/walk/land ⇒ `FacetAtlas.body_name_of_fid(active_facet())`; coast ⇒
`CosmosNav.soi_dominant()` + `OrbitalState.reexpress_soi()` swap. ~15 "earth" literals in player.gd plumbed
to `_dominant_body()` (byte-identical off-flag since it returns "earth"). Per-body walk feel via
`_apply_body_feel` (gravity=feel_g(body), jump preserves HEIGHT, Moon hang ×2.46). New kernels:
`OrbitalState.reexpress_soi` (helio-routed, physics-preserving), `CosmosNav.soi_dominant` (child-capture/
parent-escape, ±SOI_HYST 2%), `EPH.children_of`, `FacetAtlas.body_name_of_fid`, `CubeSphere.orbit_prewarm_h`
(airless=4096). Gotcha hit: `hover_drift_lattice` is STATIC — derive body from its fid param, not the instance
`_dominant_body()`.

Gates (verify_o4c.gd, NEW): G-SOI-SWAP/MOON-LAND/MOON-WALK/O4C-OFF. 20/0 (MULTI off), 27/0 (MULTI on),
26/0 (both on). Byte-identity-off ALL unmoved: verify_feature 6042/0, verify_faceted 84/0, verify_orbital
32/0, verify_nav 52/0, verify_multibody 8/0-off / 25/0-on.

HEADLESS-PROVEN: SOI math, landing feel/pose, moon-terrain walk queries, byte-off. LIVE-ONLY residue: the
actual coast-to-Moon transfer (lattice `position` re-projection + landing-facet migration across 384k blocks)
is not runtime-wired — ORBIT_PREWARM_H is gate-only, not consumed by streaming. Baking ON = team-lead call
after review + a real fly. See [[voxiverse-sn1-orbital-substrate]] [[voxiverse-spacenav-design]]
[[voxiverse-orbital-o1o4-staging]].
