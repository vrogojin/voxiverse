# COSMOS-NO-PROTRUSION-FIDELITY-DESIGN

Companion to `COSMOS-LOD-TEXTURE-DESIGN.md` and `COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md`. Fable design, 2026-07-23.
Priority **(0) no-protrusion is the gated prerequisite**; (1) fidelity and (2) overexposure follow. File:line cites are the live merged tree (~163b2b9 / current deploy line).

**USER HARD INVARIANT (top, gated):** "ensure correct terrain fidelity gets rendered, and NOT seeing any low-fidelity terrain PROTRUSION through the terrain." The coarse/far tier must never poke UP through the fine near terrain. Must be GUARANTEED (provable + headless-gated), not just reduced — a sharper texture over poke-through geometry makes it worse.

---

## 0. THE INVARIANT

### 0.1 Live flag fingerprint (dumped from deployed build/web/index.pck via headless get_script_constant_map)
`FP_FARRING_FULL_COVER=T, FP_TIER_ENVELOPE=T, FP_TIER_STICKY_BACKSTOP=T, FP_TIER_WARM_CONVERGE=T, FP_TIER_DEPTH_BIAS=F, FP_SKIN_TIER=F ⟵!, FP_FACET_TEX=T, FP_SHELL_ABSOLUTE/CAMERA_SET/PREWARM=T, FP_SHELL_WELD=T, FP_ATMO_SHELL=T, FP_ATMO_PATH_SHELL=T, FP_FARRING_FAST/ASYNC_REBUILD=T, FP_ATLAS_MATERIAL=T, FP_CPPGEN=T; BACKSTOP_CELLS=16, BACKSTOP_SINK_FRAC=0.5, STICKY_HOLD=2, STICKY_RING1_MAX=12; SHELL_LIMB_GAIN=1.6, SHELL_ATMO_MULT=2.0, SHELL_PEAK_L=0.95, SHELL_SAT=15.`
Headline: **skin tier is NOT live** (96-256 band renders envelope-backstop directly); envelope protection is live but only covers backstop facets.

### 0.2 Root cause — where the coarse tier exceeds the fine surface
Chord math: a linear chord over span L exceeds a concave profile by up to `L²·max|h''|/8`. Hills amp ~30 / wavelength ~250 → `|h''|≈0.019/blk` → horizon facets (`CELLS=4`, ~104-block chords, `facet_far_ring.gd:19`) over-estimate up to **≈26 blocks**; backstop (26-block cells) ≈1.6 + detail noise.
- **Backstop facets** (active ∪ pool ∪ ring-1 sticky, `_is_backstop` `facet_far_ring.gd:687-694`): dense grid + min-envelope (`_ensure_backstop_cached_env` :1093, weld twin :1162) + ε sink (`TierPlace.backstop_sink` `tier_place.gd:64-68`: max(1.5, 0.2·cell) ≈5.2). Provable lower bound — but only for ~13+pool facets, against GENERATED field.
- **Residual protrusion classes:**
  - **R-A — horizon facets are UN-SUNK exact-height chords** (`_ensure_cached` :980, weld placement `_weld_place` :1424: `d·(R+relief)`, no sink, no envelope). Concave 104-block span → up to ~26 blocks ABOVE true surface = the "fake ridge" silhouette (+26-block phantom ridge at 1-2 km = 18-35 px at K_px=1407). THE main visible protrusion.
  - **R-B — orbit/descent disables ALL protection**: `_shell_orbit()` (:494) makes `_is_backstop` return false → every facet emits the coarse un-sunk cache at true chord heights. On DESCENT the `floored` flip (`shell_set_camera_abs` :266-292) only SCHEDULES a deferred re-emit → arriving near meshes coexist with un-sunk over-estimating chords. A protrusion window on every landing.
  - **R-C — STICKY_HOLD=2 is a heuristic, not a proof** (`cube_sphere.gd:365`).
  - **R-D — edits**: envelope min is over generated `profile_at_dir` only — a dug pit deeper than ε shows the coarse tier through the excavation floor.
  - **R-E — skin (when re-enabled) samples worldgen, not edits** (`facet_skin_tier.gd:585-608`) — same class as R-D.

Conclusion: a bigger constant sink CANNOT fix R-A/R-B/R-C (26-block sink = visibly sunken world, still disproven by edits); coverage-exclusion cannot (the backstop's job is to show where near ISN'T meshed). The only mechanism provable everywhere: make **every far-ring vertex height a lower bound of the true surface**, everywhere, permanently.

### 0.3 The guarantee — GLOBAL ENVELOPE HEIGHT LAW (`FP_ENV_ALL`)
**Rule: every vertex of every far-ring cache — coarse 5×5 horizon AND dense backstop, weld and non-weld paths — stores height `env(v) = min(fine g over v's dilated footprint)`; the emit-time ε sink is retained. Rendered chord = convex combination of vertex bounds covering the triangle ⇒ rendered surface ≤ true surface − ε EVERYWHERE, every facet, every regime (surface/orbit/descent), independent of roles/sticky/coverage.** R-A/R-B/R-C die by construction (the CACHE HEIGHT LAW changes, not the emit-time role): `_shell_orbit`'s un-sunk emission then draws lower-bound heights too; sticky expiry reverts to a still-safe coarse quad.

**Economics — the fine pass already exists:** `FacetTexBaker.sample_fine` (`facet_tex_baker.gd:77-101`) fetches a 32² grid per facet whose `heights` come back in the same `sample_columns` result as the colors (currently DISCARDED). One facet visit yields texture texels AND the 5×5 envelope minima (footprint = ±1 coarse cell = ±8 fine samples + skew dilation, per `ENV_DILATE_BLOCKS` `tier_place.gd:25`). The Phase-2 progressive bake driver serves BOTH. Coarse-cache builders (`_ensure_cached` :980 / `_weld_node` :1429) consume envelope heights when `FP_ENV_ALL` on, textually separate so OFF is byte-identical (`FP_SHELL_WELD` pattern). Fine pitch 417/32≈13 → between-sample residual ≈`13²·0.019/8≈0.4`+detail — covered by ε=5.2; the gate measures the true residual and pins ε.

**Edge exactness under One-Surface Law (EDGE-CANON):** shared-edge vertices must weld bit-identically (`_weld_snap_edges` :1440). Independent per-facet 2-D minima would differ across the edge → gap. Rule: an edge vertex's envelope min is computed from a sample set derivable ONLY from the SHARED edge data — the 1-D fine line along the shared corner-dir bilerp (bit-identical both sides) + a symmetric perpendicular band via `±normalize(cross(edge_dir, radial))` (sign-symmetric ⇒ same set either side). Corner vertices: min over incident canonical edge lines. Interior: plain 2-D footprint. Every bound's footprint still covers its incident triangles ⇒ proof holds AND weld preserved.

**Edit-aware extension (`FP_ENV_EDITS`, kills R-D/R-E):** fold the fid-keyed edit overlay into the min — for every edited column in a vertex's footprint, `env(v)=min(env_gen, exposed_top(edit_column))`, using the FP_FACET_TEX_EDITS choke points (`world_manager.gd:1242`, `:1264`) to invalidate + re-envelope (bounded, debounced, shares the texture re-bake visit). Skin gets the same per-column override.

**Honest fidelity cost:** env flattens far valleys DOWNWARD by up to the local relief over the footprint (former over-estimate inverted into a safe under-estimate). Correct trade (no-protrusion ranks above fidelity); §1 F2 denser cells shrink the footprint where the player looks.

### 0.4 The gate — G-NPT (`verify_no_protrusion.gd`), extends verify_tier_depth.gd machinery
- **G-NPT-SURF**: for M≥12 facets across biomes INCLUDING mountain/concave terrain (select by scanning `profile_at_dir` curvature): reconstruct as-rendered triangle surface from emitted caches (horizon coarse + backstop dense, sink applied), probe N≥10,000 random dirs/facet vs pitch-1 truth (`sample_columns`): assert `rendered ≤ true − 0`, ZERO violations. Falsify: ε=0 + envelope off → violations appear (R-A).
- **G-NPT-ORBIT**: same assertion with shell in `_shell_orbit` (via `shell_set_camera_abs(dir,d,floored=false)`). Today FAILS (R-B); FP_ENV_ALL turns green.
- **G-NPT-DESCENT**: `floored`=true with near meshes simulated present; assert invariant holds through the deferred-rebuild window.
- **G-NPT-EDIT** (FP_ENV_EDITS): dig 8×8×10 pit via `break_block`, re-envelope, assert rendered ≤ pit floor − ε; revert → baseline bit-exact.
- **G-NPT-BOUND**: measured between-fine-sample residual < ε across M facets (pins ε empirically).
Every later fidelity tier MUST join G-NPT-SURF's reconstruction — the gate is the standing contract.

---

## 1. FIDELITY PLAN (each joins G-NPT reconstruction before shipping; gl_compat/NEVER-OOM)
- **F1 — re-enable SKIN (`FP_SKIN_TIER`, already implemented, live-OFF).** Biggest lever: pitch-1 exact-silhouette heightfield over 96-256 (`facet_skin_tier.gd:55-71`), sunk 1.5, 8 MB cap, one draw/facet, covered-tile overdraw fix + reap built (:73-118, :236-311). Trivially G-NPT-compliant vs generated (pitch-1, sunk); edit blindness (R-E) closed by FP_ENV_EDITS. Action: live A/B (standing-fps history turned it off; reap fix answers it — re-measure), then sed-ON.
- **F2 — mid-ring DENSE promotion (`FP_MID_DENSE`).** Promote facets within ring-2 (≈2 facet-edges of sub-camera point) to emit their DENSE envelope grid (16 cells, 26-block) instead of 5×5 coarse — reuse `_bpos_cache`/`_ensure_backstop_cached_env` (:1038/:1093); only the promotion predicate in `_emit_cached`'s caller changes. 4× finer geometry + ~16× smaller chord error (26→1.6) in the 400-1200 band. Cost ≈+130 KB, +8k tris — negligible, bounded by ring-2 count.
- **F3 — texture ladder (COSMOS-LOD-TEXTURE-DESIGN):** Phase 2 progressive bake (ALSO fixes the black far hemisphere — un-baked facets render black from orbit) + Phase 4 close-up 128²/3.3-blk-per-texel cap cells. With F1 live, `TEX_D0` 600→~400.
- **F4 — global CELLS 4→8: REJECTED for now.** Tri caches scale ×4 → ≈+20 MB front-hemisphere, over NEVER-OOM comfort for a band F2 already fixes. Backlog behind measured A/B only.

## 2. DAY-SIDE OVEREXPOSURE (white washout from orbit) — root cause + fixes without HDR
Far-ring surface shader cannot overexpose (albedo≤1 × shade≤1 × tint≤1). Washout = ADDITIVE atmosphere shell over the lit disc (`_ATMO_SHELL_SHADER` `cosmos_sky.gd:223-283`, built :836-866): `blend_add`, `l_path=0.95·(1−exp(−strength/15))`, `strength=chord·exp(−max(h_min,0)/128)/128`. At alt 1323:
- Nadir ray: chord≈768 → strength=6 → l≈**+0.31** blue haze over the whole lit disc.
- Grazing ground-hit ray (outer day-disc annulus): slant chord≈3218 → strength≈25 → l→**+0.77** additive → clips toward white-cyan. THIS is the washout: `SHELL_PEAK_L=0.95` was tuned for the LIMB (sky-only rays), but ground-terminated rays reuse the same budget while the surface behind is NOT extinguished → additive in-scatter without paired extinction double-counts energy. Tonemap is Godot default LINEAR (no setup in main.gd) → hard-clips.
- **O1 `FP_ATMO_GROUND_BUDGET`** — second budget for ground-hit rays: when `b<r_solid && t_hit>0` use `peak_l_ground≈0.30` vs 0.95 (one uniform + one select). Limb untouched; annulus +0.77→≤+0.26. Gate: extend G-AS-LIMB twin with the ground-ray branch.
- **O2 `FP_SURF_EXTINCT`** — pair in-scatter with extinction: in the far-ring textured shader (per-vertex, closed-form) multiply albedo by `exp(−k·strength)` so slanted paths dim the surface they veil — restores contrast. Twin + gate pin the curve; OFF byte-identical. (k needs one live calibration screenshot.)
- **O3 — tonemap: leave LINEAR.** Global tonemap change re-grades every shipped look for one local symptom; rejected as primary. Re-evaluate only if Phase-5 sweep still clips after O1+O2.

## 3. FLAG TABLE (all default-false, sed-ON after their gates)
| Flag | Gates | OFF ⇒ |
|---|---|---|
| `FP_ENV_ALL` | global envelope height law in ALL far-ring cache builders (+EDGE-CANON); requires FP_FARRING_FULL_COVER+FP_SHELL_WELD | all builders textually shipped — byte-identical (FLAT 6042/0; verify_faceted/tier_depth unmoved) |
| `FP_ENV_EDITS` | edit-min fold + skin column override; hooks `world_manager.gd:1242/:1264` | if-guarded no-ops |
| `FP_MID_DENSE` | ring-2 dense-emission promotion predicate | `_is_backstop`-driven emission verbatim |
| `FP_ATMO_GROUND_BUDGET` / `FP_SURF_EXTINCT` | O1 / O2 shader branches + uniforms | shipped shader strings verbatim |
| (existing) `FP_SKIN_TIER` | F1 re-enable — export-flag decision after A/B | today's live config |

## 4. PHASED PLAN (each headless-gated; (0) before (1))
- **N0 — G-NPT harness FIRST (gate-before-fix):** build `verify_no_protrusion.gd` against TODAY's build; document failing sub-gates (G-NPT-SURF concave, G-NPT-ORBIT) as pinned baseline. No engine change.
- **N1 — `FP_ENV_ALL`:** envelope heights into `_ensure_cached`/`_weld_node` + EDGE-CANON; wire shared fine pass with FacetTexBaker. Exit: G-NPT-SURF/ORBIT/DESCENT/BOUND green with falsification; G-SHELL-WELD still green; FLAT 6042/0.
- **N2 — `FP_ENV_EDITS`:** edit fold + re-envelope sharing the texture re-bake driver. Exit: G-NPT-EDIT green.
- **F — fidelity:** F1 skin A/B → sed-ON; F2 `FP_MID_DENSE` (+ its rows in G-NPT-SURF); F3 texture Phases 2/4 (progressive bake unblocks black hemisphere first). Exit: G-NPT stays green with every new tier; skin 8 MB ledger; live worst-frame A/B.
- **O — overexposure:** O1 then O2, screenshot-swept (day nadir + annulus + limb + night); G-AS-LIMB extended.

## 5. RISKS
- EDGE-CANON f64→f32 cast mismatch → sample SET identical by construction, only final Vector3 cast is f32 (FS1 weld argument); G-SHELL-WELD asserts bit-equality.
- Envelope prewarm cost → IS the texture bake pass (one visit both); G-FT-BUDGET bounds it.
- Under-estimate reads as "sunken far terrain" → disclosed trade, bounded by footprint relief; F2 shrinks in visible band; screenshot sweep judges.
- Skin re-enable regresses standing fps → covered-tile reap built for exactly that (`facet_skin_tier.gd:281-304`); A/B with remote-bridge worst-frame before sed-ON.
- O1/O2 shader on gl_compat/ANGLE → GDScript twin gates + deployed-export smoke before dependent phases.
- STICKY/roles left as-is → under FP_ENV_ALL roles become a density/sink choice, not a safety mechanism (safety no longer depends on them).

**Open questions:** (a) confirm why FP_SKIN_TIER was left off at export (assumed pre-reap standing-fps hit) before F1 A/B; (b) ε=5.2 vs fine-pitch-13 residual asserted by G-NPT-BOUND — if thin on mountain facets, take the envelope fine grid at 64² for backstop-promoted facets only (bounded); (c) O2's extinction constant k needs one live calibration screenshot.
