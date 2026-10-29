---
name: voxiverse-tasks-72-73-state
description: 2026-08-15 tasks
metadata: 
  node_type: memory
  type: project
---

2026-08-15, reconciled with fable-far-height's code+pck audit ([[voxiverse-far-height-verdict]],
docs/COSMOS-FAR-HEIGHT-DESIGN.md carries the merged maps in §2.2, served-pck flag set in §0):

**#72 "far-terrain too low"**: never tighten ε-sink (ENV_EPS_G / ENV_ALL_EPS_FRAC are measured
no-protrusion bounds); territory-not-magnitude root cause fixed by the applied-cover chain.
On any re-observation read `sh_applied_r` FIRST. Refinement from the audit: the "residual ≲2
blocks" bound holds on FLAT ground only — on RELIEF the visible skin is the V2 near-fill tile
at TRUE−6.0 (`V2_NEARFILL_SINK`, cube_sphere.gd:1722, applied facet_smooth_v2.gd:537). Cheap
interim fix designed: `FP_V2_NEARFILL_UNSINK` — vertex-shader recovers p_true and applies the
three-zone law via 4 uniforms; zero rebuild churn, geometry byte-identical, no ε touched.

**#73 "orbit/de-orbit facet misalignment"** — triage after audit:
- C4 (frame-basis omission) DISPROVED for ground tiers: far-ring `_weld_place`, V2 native
  bake, and orbit-relief all emit radially in absolute sphere coords; near lift agrees
  ≤0.03 blk. The class only bites lattice_to_world64-anchored tiers (trees/structures),
  already welded — FP_FT_FRAME_WELD confirmed live in the served pck.
- C1 narrowed: relief mesh + shell share ONE ring transform (relief is a placement-sharing
  child, facet_orbit_relief.gd:495) — no static desync. Only remaining C1 window =
  RE-ANCHOR TIMING: PlanetRoot re-anchors frame N, ring's (identity − _anchor_offset) pin
  (facet_far_ring.gd:52-53) frame N+1 ⇒ whole-far-stack vs NEAR one-frame skew at re-anchor
  events, never facet-vs-facet inside the far stack.
- C2 (V2 annulus lag on descent), C3 (stale active-fid far consumer), C5 (f32 at altitude)
  stand as ranked.
- Gate MUST be a verify_spacefly-style scripted flight logging re-anchor timestamps against
  the misalignment frame — verify_facet_seams (static welds) cannot catch any pose-desync
  class. Repro drive (flight.mjs, pull frames via relay) flagged to team-lead; awaiting a
  live-session owner.

**How to apply:** picking up #73 → run the scripted flight, correlate re-anchor events with
the bad frame; #72-class report → `sh_applied_r` telemetry, then relief-vs-flat discrimination
(flat = zone-B ≲2 blk designed; relief 6-blk skirt = ship FP_V2_NEARFILL_UNSINK).
