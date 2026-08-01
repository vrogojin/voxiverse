# COSMOS — PLANET VIEW DESIGN (seamless good-looking planet at all distances)

Status: design (READ-ONLY analysis; no engine code changed). Branch `feat/voxiverse-orbit-space-temp`.
Author: rendering-architect pass. Builds on — does NOT re-derive — the locked decisions in
`COSMOS-SEAMLESS-SCALES-DESIGN.md`, `COSMOS-ATMO2-DESIGN.md`, `COSMOS-ATMO-SKY-DESIGN.md`,
`COSMOS-BLOCK-LOD-DESIGN.md`, `COSMOS-TEXTURED-LOD-DESIGN.md`, `COSMOS-ORBITAL-SHELL-DESIGN.md`,
`COSMOS-TIER-DEPTH-PRIORITY-DESIGN.md`.

Goal: the PLANET reads as a smooth, honest, Earth-from-orbit body AND stays playable (no orbit freeze) at
every viewing distance, as ONE continuum: surface → in-atmosphere → near orbit → far orbit → deep space.

Hard constraints carried in (from the user): **playability first** (smooth fps beats fidelity — never a
freeze), **NEVER-OOM** (every memory-costly upgrade flag-gated OFF behind a MEASURED A/B gate with a byte
ceiling; a measured +10–20 MB is allowed but caps must bind on real bytes), a **thin physically-proportioned
atmosphere rim** honestly tied to `ATMO_TOP`, a **seamless continuum** (no pops at facet crossings or the
atmosphere↔space border), and **flag discipline** (`const FP_* := false`, OFF ⇒ byte-identical, FLAT gate
`verify_feature.gd` = 6042/0).

The engine numbers that anchor everything below:
`R_BLOCKS = 6371`, `K = 24` ⇒ `6·K² = 3456` facets, facet edge ≈ 417 blocks
(`cosmos/facet_atlas.gd:12-14`); far ring `CELLS = 4`, `CAMERA_FAR = 9000`
(`world/facet_far_ring.gd:19,22`); `ATMO_TOP = 384` ≈ **6.03 % of R** (`cosmos/cube_sphere.gd:991`);
atmosphere shell `r_outer = R + SHELL_ATMO_MULT·ATMO_TOP = 6371 + 2·384 = 7139 = 1.121·R`
(`cosmos/cosmos_sky.gd:456,552-553,959`); scaled-body engage `H_ENGAGE = 12500`, `d_engage = R + 12500 =
18871` (`cosmos/cosmos_scale.gd:31,49-56`).

---

## 1. Regime map (what renders the planet, camera planes, current defect)

| # | Regime | Altitude h (blocks) | Camera dist d = R+h | What renders the planet | Camera near / far | Scale s (SN3) | Current defect |
|---|--------|--------------------|--------------------|------------------------|-------------------|--------------|----------------|
| 1 | **Surface** | ~0 | ~6371 | near voxels (module world / fallback) + block-LOD to horizon; far-ring cap sits below the horizon | 0.05 / 9000 | 1 | (shipped-good) |
| 2 | **In-atmosphere** | 0 … 384 (ATMO_TOP) | 6371 … 6755 | near voxels thinning + block-LOD rings L1–L5 + far-ring cap; sky ramps to black via `atmo_vis` | ramp near→ / 9000 | 1 | near-field stream/mesh work still runs (freeze source until `FP_ALT_REGIME`) |
| 3 | **Near orbit** | ~500 … 3000 | 6871 … 9371 | far-ring globe cap (camera-set law) + block-LOD L5 + §2V far skin + atmosphere shell | ramp / `max(9000, 1.2·√(d²−R²))` | 1 | jagged limb appears; blotchy skin; **shell rim already 3–4° OUTSIDE the disc with a gap** |
| 4 | **Far orbit** | ~3000 … 12500 | 9371 … 18871 | far-ring globe (full cap) + skin + shell | ramp / tangent | 1 (until 12500) | **jagged polygonal limb dominant; shell oversize+gap most visible; ~1 s rebuild hitch on teleport/drift** |
| 5 | **Deep space** | ≫ 12500 | > 18871 | far-ring scaled about camera to render at `d·s = D_ENGAGE`, rendered radius `s·R`; skin; shell | ramp / tangent | `18871/d < 1` | **shell NOT scaled → detaches/balloons vs the shrunk disc**; limb still polygonal |

One-liner per distance:
- **Surface** — near voxels + horizon block-LOD; fine.
- **In-atmosphere** — voxels fade into block-LOD under a blackening sky; near-field work is the only cost.
- **Near orbit** — the faceted globe + far skin + a fat detached blue ring; limb starts looking polygonal.
- **Far orbit** — polygonal limb + oversize offset halo + ~1 s rebuild freezes on any big camera move.
- **Deep space** — the SN3 clamp shrinks the disc but the shell stays full-size → halo flies off the planet.

Key mechanisms (cite): far-ring placement/centre `world/facet_far_ring.gd:372-383`; SN3 clamp on the ring
`world/facet_far_ring.gd:391-409`; camera-set emitted cap `world/facet_far_ring.gd:420-478`; shell build
`cosmos/cosmos_sky.gd:957-992`; shell shader `cosmos/cosmos_sky.gd:233-289`; shell per-frame uniforms +
`FP_SKY_PLANET_CENTRE` node move `cosmos/cosmos_sky.gd:1238-1264`; SN3 driver order in
`main.gd:281-282,311-343,366-378`; the "~1 s SYNC rebuild" note `cosmos/cube_sphere.gd:624`.

---

## 2. Atmosphere model — ROOT CAUSE of the offset / oversize / gap

The shell is ONE additive `cull_front, blend_add, depth_draw_never` sphere (`cosmos/cosmos_sky.gd:233-235`)
of radius `r_outer`, planet-centred, whose per-fragment shader analytically integrates a Rayleigh chord.
Three independent, compounding faults make it read as an offset, oversized, detached ring:

### 2.1 OVERSIZE + GAP (dominant, geometric) — `SHELL_ATMO_MULT = 2` and an honest-ceiling that is itself 6 % of R
`r_outer = R + 2·ATMO_TOP = 7139 = 1.121·R` (`cosmos/cosmos_sky.gd:456,552`). The rim's angular radius from
the camera is `asin(r_outer/d)`; the planet disc edge is `asin(R/d)`. At alt 8000 (d = 14371): disc = 26.3°,
**rim = 29.8° → a 3.5° blue annulus sitting OUTSIDE the limb with a gap between them.** The shader lights
every view direction whose impact parameter `b < r_outer` (`cosmos/cosmos_sky.gd:262`), so blue is emitted all
the way out to 29.8°. The physical falloff `exp(−h_min/H_SCALE)`, `H_SCALE = 128` (`:280,376`) does thin it,
but with the shell top 768 blocks above the surface the outer reaches still glow.

Two things are wrong at once: (a) the **2× multiplier** is arbitrary (design comment even calls the +52-block
edge-on the intended look, not +768); (b) even `SHELL_ATMO_MULT = 1` gives `R + ATMO_TOP = 6755 = 1.06·R`,
because **`ATMO_TOP = 384` is already ≈ 6 % of R** — a gameplay ceiling, not the visible rim. Real Earth's
bright limb is ~1–1.5 % of R. So the honest rim must (i) cap the shell sphere at the true ceiling
`R + ATMO_TOP` AND (ii) concentrate the *brightness* into a short scale height so the visibly-bright band
hugs the limb at ~1.5 % of R even though the geometry extends to 6 %.

### 2.2 OFFSET / "doesn't follow proportions moving away" (frame + scale mismatch)
Even with the just-landed `FP_SKY_PLANET_CENTRE` (`cosmos/cosmos_sky.gd:1256-1263`) the offset persists because
the fix moved the **node** to `planet_render_centre()` but fed the **shader** a *planet-relative* camera:

```
_atmo_shell.position = planet_c            # = planet_render_centre()   (RENDER frame)
_atmo_shell_mat.set_shader_parameter("cam", cam_rel)   # = cam − planet_render_centre()  (PLANET-relative)
# centre uniform stays Vector3.ZERO  (cosmos_sky.gd:973)
```

The mesh fragment world position `wp = INV_VIEW_MATRIX·VERTEX` is in the **render frame**
(`= planet_render_centre() + r_outer·n̂`), but `dir = normalize(wp − cam)` subtracts a **planet-relative**
`cam`, and `oc = centre − cam` uses `centre = 0`. The two frames only coincide when
`planet_render_centre() ≈ 0` — i.e. **below the first floating-origin re-anchor** (`REANCHOR_TRIGGER_BLOCKS =
8192`, `cube_sphere.gd:819`). Above it (deep flights, orbit drift) the analytic limb desyncs from the mesh
coverage by the anchor offset → the rim visibly slides off the disc. **Fix:** feed the shell shader the
render-frame camera and the render-frame centre — `cam = cam_origin`, `centre = planet_render_centre()` — so
`wp`, `cam`, `centre` are all one frame (place the node at `planet_render_centre()` unchanged).

### 2.3 SCALE mismatch above D_ENGAGE (regime 5) — the shell is never scaled
`apply_scaled_placement` scales the far ring about the camera by `s = min(1, D_ENGAGE/d)`
(`world/facet_far_ring.gd:391-409`), but **nothing scales the shell** — `apply_scaled_body`
(`world_manager.gd:2729-2731`) touches only the ring. Above alt 12500 the disc shrinks to `s·R` at render
distance `D_ENGAGE` while the shell keeps full `r_outer` at the (unscaled) `planet_render_centre()` → the halo
detaches entirely. **Fix:** apply the SAME `scale_about_camera(cam, s)` to the shell node and feed the shader a
`centre`/`r_outer` consistent with the scaled ring (`r_solid → s·R`, `r_outer → s·r_outer`, `centre →`
scaled render centre), so rim and disc scale together. Below engage `s = 1` ⇒ byte-identical.

### 2.4 Target look (thin, concentric, honest, fades in deep space)
- **Geometry ceiling honest:** shell sphere `r_outer = R + ATMO_TOP` (1.06·R) — the shell truly ends where the
  atmosphere ends. Tunable `SHELL_ATMO_MULT → 1.0`.
- **Bright band physical:** brightness `∝ exp(−h_min / H_RIM)` with a SHORT `H_RIM` (≈ 40–64 blocks, in the
  spirit of the existing extinction-colour `H_OPT = 30`, `cosmos_sky.gd:662`) so the visibly-bright rim decays
  to ~5 % by ~1.5 % of R above the limb — an Earth-like hairline that *thickens toward the surface* (the chord
  through the dense layer lengthens as `b → R`) and is essentially gone by the geometric top.
- **Concentric at every distance:** frame-correct (2.2) + scale-tracked (2.3) ⇒ rim centre ≡ disc centre and
  rim/disc angular ratio = `r_outer/R = 1.06` at all d, so the rim hugs the limb (1.06·disc-radius, no 3.5°
  gap) and shrinks WITH the disc moving away.
- **Fades in deep space:** the day-gate `day_factor(μ)` and the `atmo_vis`/`space_mix` authority already zero
  the tint by `ATMO_TOP`; with the geometry capped at `R + ATMO_TOP` the deep-space planet shows only a
  vanishing hairline, never a fat ring. Keep it cheap: still ONE additive `cull_front depth_draw_never` draw;
  the only new per-frame work is 2–3 uniform writes (`cam`, `centre`, `r_solid`, `r_outer`, `s`). Screen
  coverage DROPS (thinner rim ⇒ fewer lit fragments), so this is a perf win too.

---

## 3. Limb fidelity — make the silhouette read ROUND

The far ring meshes each facet at `CELLS = 4` (`facet_far_ring.gd:19`): a 417-block facet → 4×4 quads,
~104-block silhouette segments. From orbit the great-circle limb is a chain of ~a few-hundred short chords
plus ±relief jitter — polygonal, the #1 "unfinished" tell. Options, cheapest-first:

- **(A) Lean on the (now-thin, concentric) atmosphere rim to MASK it.** After §2, the additive blue hairline
  overlays the exact silhouette; a bright rim over a ±0.1° stair-step hides most of the polygonal edge for
  **zero extra geometry**. This is why the atmosphere phases (P1/P2) are ordered BEFORE limb densification —
  they cut the residual limb work.
- **(B) Limb-ring densification (`FP_FARRING_LIMB_DENSE`).** Only the ~1-facet-thick ring of facets straddling
  the visible silhouette angle (`|centre·ĉ − cos θ_h|` small) emits at `CELLS = 8` (or 16) instead of 4; the
  interior stays at 4. The silhouette ring is ~`O(√facets_in_cap)` ≈ 40–60 facets, not the whole cap, so the
  vertex cost is bounded. Cost estimate: a facet at CELLS=4 = 32 tris = 96 verts × (12 B pos + 16 B col) ≈
  2.7 KB; going to CELLS=8 (128 tris/384 verts) adds ~8 KB/facet. 60 limb facets ⇒ **≈ +0.5 MB** peak, a
  MEASURED A/B ceiling bump well inside the +10–20 MB the user OK'd. Reuses the existing per-facet cache/warm/
  emit path (the CELLS value becomes per-facet). Playability guard: densify ONLY the emitted-cap limb ring,
  and only when `_offsurface` (orbit) — never on the surface hot path.
- **(C) Screen-space limb smoothing** — rejected for now: gl_compat has no cheap post pass we control, and
  (A)+(B) already deliver a round read.

Recommended: **(A) first (free, via the atmosphere phases), then (B) as a gated fidelity phase.** Do NOT tank
fps — (B) is orbit-only and bounded to the limb ring.

---

## 4. Playability / orbit jerkiness — the #1 priority

Hitch sources, ranked:

1. **The ~1 s SYNCHRONOUS far-ring rebuild** (`cube_sphere.gd:624`: "expensive (~1 s SYNC when
   `FP_FARRING_ASYNC_REBUILD` is off)"). It fires on teleport, on cap drift past slack, on the floor/regime
   crossing, and on facet crossings. This is the "proc up to ~1 s right after a teleport" the pilot saw. The
   machinery to move it off-thread already EXISTS but ships OFF: `FP_FARRING_ASYNC_REBUILD` (double-buffered
   worker build + main-thread swap, `facet_far_ring.gd:138-153`) and `FP_FARRING_FAST_REBUILD` (pre-triangulated
   memcpy assembler, `:265,67-81`).
2. **Per-frame orbit re-scan.** The orbit branch re-ran the full 6·K² warm/dot scan every airborne frame
   (~67 ms baseline). `FP_SHELL_ORBIT_IDLE` (`:1061`) + `FP_WARM_TRUE_BUDGET` + `FP_TIER_WARM_CONVERGE` idle it
   once the cap is warmed+emitted — all exist, all OFF.
3. **Redundant re-emits from radial/axis churn** during climbs/falls: `FP_SHELL_FALL_HOLD`,
   `FP_SHELL_CLIMB_NO_CHURN`, `FP_FALL_RING_HOLD`, `FP_FALL_SCALE_FREEZE`, `FP_FALL_ATMO_THROTTLE`,
   `FP_FALL_SHELL_OFF` — a whole family of throttles, all OFF.
4. **Near-field stream/mesh work above the atmosphere** that is invisible from orbit but still runs:
   `FP_ALT_REGIME` (`:1148`) freezes it above `ATMO_TOP`.
5. **Skin/texture bake spikes** (§2V): already worker-paced (`FP_FACET_TEX` async, `MID_DENSE` batch), but a
   fresh teleport can burst — pace via the existing `SHELL_REEMIT_GROWTH` cadence.

The playability-first move is therefore **not new code but baking on + hardening the async/paced far-ring
path** — which is exactly what these OFF-by-default flags target. That is P0.

---

## 5. Seamlessness (no pop across the 5 regimes)

- **Surface ↔ in-atmosphere ↔ near orbit:** the far-ring mesh is ABSOLUTE-coord and always present; the
  camera-set cap grows `θ_emit` continuously with `θ_h = acos(R/d)` (`facet_far_ring.gd:444-457`). Block-LOD
  L1–L5 already cross-fade/overlap (`COSMOS-BLOCK-LOD-DESIGN`). No hard swap.
- **Atmosphere ↔ space border:** `atmo_vis(h)` fades sky/tint/fog to 0 at `ATMO_TOP` (`cosmos_sky.gd:461-464`,
  C¹ smoothstep); the honest rim (§2.4) is geometry-capped at the SAME `ATMO_TOP`, so the blue and the black
  cross at one radius — the rim thins to nothing exactly as the sky goes star-black. No border seam.
- **D_ENGAGE (near→far→deep space):** `scale_for` is C0 at engage (`s = 1` from both sides,
  `cosmos_scale.gd:52-56`) and `angular_size` is INVARIANT to `s` (`:73-76`) — the disc's screen size does not
  jump. The §2.3 fix makes the shell ride the SAME `s`, so the rim's screen size is invariant across the
  border too. `camera_far` is a continuous tangent ramp (`:86-90`). The one remaining requirement: the shell's
  scaled `r_outer` and the ring's scaled radius must use the SAME `s` and SAME render centre each frame (drive
  both from one `apply_scaled_body(cam)` call — see P1/P5).
- **Facet crossings:** the ring is absolute + rigid-replaced (`set_active` is O(1), `:356-366`); off-surface
  the emitted set is camera-axis-driven so a crossing does NOT force a rebuild (`:365`). Keep that invariant
  when async is enabled.

---

## 6. Phased plan (P0…P5) — ordered by impact ÷ risk, playability first

Each phase = one flag, one measurable win, headless-gate-able where possible, deploy + live-orbit-snapshot
verifiable. All `const FP_* := false` in `cosmos/cube_sphere.gd`; OFF ⇒ FLAT 6042/0.

### ★ P0 — KILL THE ORBIT FREEZE (highest value, playability-first)
**Flag(s):** bake ON the existing `FP_FARRING_ASYNC_REBUILD` + `FP_FARRING_FAST_REBUILD` + `FP_SHELL_ORBIT_IDLE`
+ `FP_WARM_TRUE_BUDGET` + `FP_TIER_WARM_CONVERGE` (+ `FP_ALT_REGIME` to freeze invisible near-field work above
ATMO_TOP). No new mechanism — harden + tune the async/idle path for the orbit case.
**Files:** `world/facet_far_ring.gd` (async build/swap, orbit-idle scan), `world/world_manager.gd` (driver),
`main.gd:311-343` (driver order), `cosmos/cube_sphere.gd` (flag bake).
**Memory:** ~0 (double-buffer holds one extra ArrayMesh transiently; bounded, NEVER-OOM — the caches already
exist). No ceiling change.
**Gate:** `verify_shell.gd` async-equivalence gate (worker mesh == sync mesh, bit-identical arrays) + FLAT
6042/0. Assert `_begin_rebuild` stays off the crossing frame and the orbit scan idles (`sh_wfail` flatlines).
**Live check:** teleport to alt 4000 and to alt 8000; drift the camera; watch `farring`/`shell` telemetry —
**no proc spike > ~50 ms on teleport**, fps holds ~30+, the far side fills progressively without a freeze.
**Why first:** the freeze is the one thing the user said outranks all fidelity. This is a bake-on of machinery
built exactly for it.

### P1 — ATMOSPHERE CONCENTRIC (frame + scale correctness)
**Flag:** `FP_ATMO_SHELL_CONCENTRIC` (new). Feed the shell shader the RENDER-frame camera + centre
(`cam = cam_origin`, `centre = planet_render_centre()`, node at `planet_render_centre()`), and apply
`CosmosScale.scale_about_camera(cam, s)` to the shell node + scale `r_solid/r_outer/centre` by `s` — driven
from the same `apply_scaled_body(cam)` that scales the ring (extend `world_manager.gd:2729-2731`).
**Files:** `cosmos/cosmos_sky.gd:1238-1264` (uniform feed), `cosmos/cosmos_sky.gd:957-992` (build), `world/
world_manager.gd:2726-2739`, `world/facet_far_ring.gd:391-409` (share `s`).
**Memory:** 0 (uniform/transform writes only).
**Gate:** extend `verify_atmo_sky.gd` G-AS-LIMB — assert `shell_geom`/`shell_view_mu` twins agree with a
render-frame cam/centre above a synthetic re-anchor offset, and that rim angular radius = `asin(s·r_outer /
(s·d))` tracks disc `asin(s·R/(s·d))` at D_ENGAGE±. FLAT 6042/0 with the flag off.
**Live check:** teleport alt 8000 then alt 14000 (past a re-anchor); the rim stays CENTRED on the disc and
shrinks with it — no slide-off, no detachment past engage.

### P2 — ATMOSPHERE HONEST THIN RIM (proportion)
**Flag:** `FP_ATMO_RIM_THIN` (new). `SHELL_ATMO_MULT → 1.0` (geometry ceiling `R + ATMO_TOP = 1.06·R`) and a
short brightness scale height `H_RIM ≈ 48` so the bright band decays to ~5 % by ~1.5 % of R above the limb;
retune `SHELL_LIMB_GAIN`/`SHELL_PEAK_L` so the surface horizon band lands in the existing §3.5 budget
(peak-luminance ≤ 0.35). Update BOTH the GLSL shell shaders and their GDScript twins
(`shell_limb_color*`/`shell_geom`) so the gate stays flag-independent.
**Files:** `cosmos/cosmos_sky.gd:233-358` (shaders), `:456,552-624` (consts + twins).
**Memory:** 0 (also a perf win — thinner rim ⇒ fewer additive fragments; smaller `r_outer` ⇒ smaller
screen-coverage bound on the `depth_draw_never` shell).
**Gate:** `verify_atmo_sky.gd` — new assertion: rim brightness at `h_min = 0.015·R` ≤ 5 % of peak; twin ==
shader budget. FLAT 6042/0 off.
**Live check:** alt 3000 / 8000 — a THIN blue hairline hugging the limb, thickening toward the surface,
fading to nothing by deep space; no fat detached ring, no gap.

### P3 — LIMB DENSIFICATION AT THE SILHOUETTE
**Flag:** `FP_FARRING_LIMB_DENSE` (new). Emit the ~1-facet-thick emitted-cap limb ring at `CELLS = 8`; interior
stays 4; orbit-only (`_offsurface`). Reuses the per-facet cache/warm/emit; the CELLS value becomes per-facet.
**Files:** `world/facet_far_ring.gd` (per-facet CELLS in `_ensure_emit_cached`/`_emit_cached`), `cosmos/
cube_sphere.gd` (flag + `LIMB_DENSE_CELLS`).
**Memory:** ≈ +0.5 MB peak (≈ 60 limb facets × ~8 KB). MEASURED A/B ceiling bump (< the +10–20 MB budget);
cap binds on the resident dense-facet count (bounded to the limb ring).
**Gate:** `verify_shell.gd` — assert only limb-ring facets densify, resident dense count ≤ cap, no protrusion/
hole (One-Surface Law), FLAT 6042/0 off.
**Live check:** alt 8000 — the silhouette reads as a smooth circle (helped by the P1/P2 rim overlay); vmem
delta ≤ the declared ceiling; fps unchanged (orbit-only, bounded).

### P4 — FAR SKIN FIDELITY (coastlines)
**Flag:** bake/extend `FP_FACET_TEX` + `FP_MID_DENSE` + the §2V band-map (`FP_BAND_BLOCK_MAP`) so the sub-camera
disc gets a finer real-shot skin (sharper coastlines vs the current CELLS=4 blob). Worker-paced; no new tier.
**Files:** `world/facet_tex_baker.gd`, `world/surface_shot.gd`, `world/far/far_palette.gd`, `world/
facet_far_ring.gd` (band slots).
**Memory:** bounded to the existing baker ledger (~+2 MB over base, combined ceiling < 40 MB — see
`COSMOS-TEXTURED-LOD-DESIGN`). MEASURED A/B.
**Gate:** `verify_*tex*.gd` coverage/byte-ledger gates; FLAT 6042/0 off.
**Live check:** alt 5000 over a coastline — the shoreline sharpens near the sub-camera point, no OOM, no bake
hitch (worker-paced).

### P5 — DEEP-SPACE / >D_ENGAGE POLISH
**Flag:** `FP_SCALED_BODY` + `FP_SN3_MAIN_LIVE` bake-on verification (they already ramp camera near/far + scale
the ring, `main.gd:311-343`), plus confirm the P1 shell-scale rides the same `s`. Tune `camera_far` tangent
headroom + far-skin retire so the tiny deep-space ball has clean depth and the rim is a sub-pixel hairline.
**Files:** `cosmos/cosmos_scale.gd`, `main.gd:311-343`, `cosmos/cosmos_sky.gd` (shell scale from P1).
**Memory:** 0.
**Gate:** `verify` SN3 border gate — `angular_size` C0 across engage, shell rim/disc ratio invariant across
engage; FLAT 6042/0 off.
**Live check:** teleport alt 20000+ — a small round ball far away with a hairline rim concentric with it, no
detached halo, smooth as you recede.

---

## 7. Ordering rationale
P0 buys the non-negotiable (no freeze) by baking on machinery already built for it — highest impact, lowest
risk. P1+P2 are near-zero-memory correctness/look fixes that make the atmosphere honest AND (by overlaying the
silhouette) cut the limb problem for free, so they precede P3. P3 is the only real memory spend and is bounded
+ orbit-gated. P4 is memory-gated fidelity behind a measured ceiling. P5 finishes the deep-space border. Every
phase is OFF-by-default, FLAT-gated, and deploy+snapshot verifiable at a named altitude.
