---
name: voxiverse-two-gravity-systems
description: "VOXIVERSE gravity — orbit uses cosmos_gravity.gm_dyn (=ephemeris gm_game); after the natural 1:1000 retune gm_game EQUALS cube_sphere.gm_for, so orbit g == walk g == 9.8"
metadata: 
  node_type: memory
  type: project
---

VOXIVERSE has two gravity accessors; know which feeds what:

1. **cube_sphere.gm_for = SURFACE_GRAVITY(9.81)·R²** — the near-field feel anchor, used by `per_voxel_environment` (HUD gravity vector). At R=6371 = 3.982e8.

2. **cosmos_gravity.gm_dyn = EPH.gm_game·(R_vox/R_eph)³** — feeds ALL orbital motion: OrbitalState (Verlet coast), the O-key `_coast_step`, cosmos_nav/dev_flight, HUD `orbit_v_circ`. Since the Earth/1000 rescale R_vox==R_eph, gm_dyn == gm_game exactly.

**THE NATURAL 1:1000 RETUNE (user-locked 2026-07-18, feat/voxiverse-rescale):** the clock was changed from the old 72× time compression to STRICT 1:1000 spacetime — time ÷√1000 (acceleration invariant: s_T²=s_L). Three coupled ephemeris constants (cosmos_ephemeris.gd), now DERIVED: TIME_COMPRESSION=√1000≈31.62, DAY_GAME=86400/√1000≈2732 s (~45.5-min day), GM_SCALE=(1e-3)³·(√1000)²=1e-6. Result: **gm_game(earth)=3.986e8 = SURFACE_GRAVITY·R² (== gm_for)** — the two fields COINCIDE. So orbit datum gravity == walk gravity == **9.8**, surface **v_circ=250 b/s, low-orbit period≈160 s, escape≈354**, day ≈45.5 min. The sky (sun/moon/eclipses) runs the same clock → no desync. Dimensionless ratios (year=365 days, month=27.3, angular sizes, r_geo≈42241) are model-INVARIANT (only the clock rate changed).

**Why this matters:** the OLD 72× model gave v_circ≈569/70s and a datum g of 50.9 (≠ walk 9.8) — a split. The retune erased the split. If you see 569/70s anywhere it's the pre-retune state.

**How to apply:** orbital speeds = √(gm_dyn/r) = √(gm_for/r) now (they're equal). Deploy note: far plane fixed 9000 clips the far-ring limb above alt ~4656 unless FP_SCALED_BODY ramps it. Braking (RESOLVED 4c120eb): natural drag is ~5× weaker so re-entry needed a retune — ATMO_BRAKE_TERMINAL lowered 25→20 (ATMO_TOP stays user-locked 384, drag-only). A steep 250-orbit dive now arrives 25.3 b/s, even a 350 escape-dive 27.8, all under the 30 b/s streaming floor. No descent-column pre-gen needed. See [[voxiverse-sn1-orbital-substrate]], [[voxiverse-spacenav-design]].
