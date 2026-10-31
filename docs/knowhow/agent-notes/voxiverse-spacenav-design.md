---
name: voxiverse-spacenav-design
description: "2026-07-18 space-nav architecture landed on feat/voxiverse-spacenav — five nav-frame modes as pure re-expressions over one BCI f64 state, GM_dyn interim scale fix, SN1-SN6 phase plan"
metadata: 
  node_type: memory
  type: project
---

2026-07-18: docs/COSMOS-SPACE-NAV-DESIGN.md committed (feat/voxiverse-spacenav @ 8035945, worktree
.claude/worktrees/spacenav). Keystones future sessions must not re-derive:

- **Two machines**: O1O4 locomotion {SURFACE,FLY,ORBITAL} + a NEW nav-frame classifier
  {PLANETARY, LOW_ORBIT, HIGH_ORBIT, DEEP_SPACE, INTERSTELLAR}. Nav modes are RE-EXPRESSIONS of
  one deepest-SOI BCI f64 state — they never touch the scene graph, so mode flips cannot pop
  (rule SN-R1: controllers re-express, never reset, reference velocity on flips).
- **GM_dyn = GM_game·(R_vox/R_eph)³** (D-SN-2): resolves the ephemeris-6371 vs voxel-3072
  mismatch for local dynamics (datum g 24.6 not 219; geo inside HIGH_ORBIT); identity after the
  D1/O3 resize; sky/calendar untouched; Moon already exact.
- **Geo amendment**: HIGH_ORBIT rule gains `r ≤ 1.2·r_geo` (user's raw 1%-gravity rule alone
  excludes geostationary pre-resize). Moon has NO stationary orbit (r_geo 88.5k > SOI 66.1k).
- Phases: SN1 FP_M3_ORBIT → SN2 SN_NAV_MODES → SN3 FP_SCALED_BODY → SN4 atmo/sun
  (SN_ATMO_SHELL = the only visual risk, live-gated) → SN5 SN_DEVNAV → SN6 MULTI_BODY Moon LAST
  (O3 resize ideally before SN6c). Moon nav band h=256 classification-only, no drag/fog.
- Related: [[voxiverse-seamless-scales]] (H_FARSWAP stays rejected), [[voxiverse-orbital-o1o4-staging]].
