# COSMOS — Background Whole-Planet Far-Render Prebake + the "ugly facet-in-front" fix

Status: DESIGN (analysis + design only — no production code). Branch `deploy/cheats-eyeball`.
Author: Fable (shell). Adjudicated by live telemetry + code, not eyeball.

Relates to: [[COSMOS-FAR-RENDER-OVERHAUL-DESIGN]], task #77 (whole-planet fine map, SHIPPED),
task #79 (C++ fine-bake fast path), issue #28 (far-render quality overhaul). Memories:
`voxiverse-far-render-overhaul`, `voxiverse-cpp-tile-bake-block-exact`, `voxiverse-never-oom-web`,
`voxiverse-block-lod-design`.

---

## 0′. Quality target (team-lead, from the user) — the far-horizon skin is the FLOOR

The user's baseline is **the clean far-render skin at the TOP of the frame** — the smooth,
consistent distant terrain near the horizon. The whole planet must be prebaked to **at least that
quality**, so no facet ever renders below it. The ugly facet-in-front is *worse than the horizon*
because the near facet is showing a coarse UNBAKED intermediate that is BELOW far-skin quality —
which is backwards (near should be ≥ far).

This is not a compromise — **it IS the bounded case that fits NEVER-OOM.** The far-horizon skin is
exactly the coarse-but-consistent global colour layer that is cheap enough to hold for the whole
planet. So the design target is explicit:

- **The "clean far-horizon skin" = the `FP_PLANET_MAP` FINE tier** — the always-resident,
  whole-planet flat-colour map skin painted on the far-ring shell (§1). At horizon distance a fine
  texel (6.5 blk/texel) is sub-pixel → reads as smooth and consistent. This is the QUALITY FLOOR to
  guarantee planet-wide.
- **The "ugly coarse intermediate" = the BASE tier** (16 texels/facet ≈ 26 blk/texel), which the
  shader falls to ONLY when both fine and band are unbaked (`_f8==0 && _bid==0`). At the horizon,
  base is also sub-pixel so it too looks clean — but on the NEAR facet-in-front its 26-blk/texel
  coarseness fills many pixels → the blur/tone/line. **Baking the FINE tier planet-wide removes the
  base-fallback entirely: every facet renders fine (≥ far-skin floor), near or far.**
- **Not in scope of the whole-planet prebake: the `FP_SMOOTH_V2` relief geometry** — that is a
  view-local hop-2..4 annulus (~35 tiles), regenerated cheaply on facet crossing, NOT a
  whole-planet-resident layer. It composes on top for near relief; it is not what needs prebaking.
  The whole-planet prebake target is the FINE *colour* skin only. (§3′ quantifies why this is the
  cheap layer.)

So §4's `FP_BG_PREBAKE` is precisely "bake the far-skin (FINE tier) for the whole planet in the
background, view-first, so the coarse-base intermediate never shows." Everything below serves that.

---

## 0. TL;DR for the team-lead

- **The ugly facet-in-front is cause (a): the near facet's fine-map AND band tiers are simply
  UNBAKED at that fresh on-surface region, so the shader falls all the way to the COARSE BASE
  page** (16 texels/facet ≈ 26 blocks/texel, linear-mipmap-filtered). The blur, the tone
  mismatch, and the diagonal line are all one artifact: a *resolution* discontinuity between a
  base-only facet (6.5–26 blk/texel) and its neighbours that already have band/fine baked
  (1–6.5 blk/texel). It is **not** a tier-blend seam (b), **not** the smooth-V2 / far-ring / skin
  boundary (c), and **not** a colour-law mismatch (d) — `FP_FAR_COLOR_UNIFIED` is ON and already
  unifies the hue law across tiers.
- **`fm_baked=0` is by design, not a bug: `FP_FINE_BAKE_SURFACE_PAUSE` is ON live and it stops all
  NEW whole-planet fine-tier dispatch while on-surface.** The fine tier therefore only ever holds
  facets you baked while *off*-surface (orbit/descent). Teleport to a spot you never orbited over →
  `fm_baked=0` there. Meanwhile the only on-surface far-filler is the BAND tier, which on web runs
  at **1 worker** (`bm_res=0/want=49` = the 49-facet SSE disc, none baked yet, filling ~1 facet/s).
- **`cpp_on=False` is a red herring.** That telemetry field tracks `FP_CPP_FINE_BAKE` (a *shelved*
  flag, NOT in the live deploy set) AND is `_offsurface`-gated. On-surface it is always false. The
  SHIPPED C++ fast path is `FP_CPP_TILE_BAKE` (patch 0011) — which is *also* `_offsurface`-gated in
  dispatch, so it too is dark on-surface. **That gate is the real lever.**
- **Memory verdict — the critical number: the whole-planet fine tier is ALREADY BUILT and ALREADY
  bounded at ~27 MB fixed-size (`FP_PLANET_MAP`, 24 L8 sub-pages of 768², 6.5 blk/texel).** This is
  a *flat-colour skin*, not the infeasible ~158 MB full-res L5 *mesh*. It costs ~1.3% of the 2048 MB
  WASM ceiling and is a fraction of the measured 412–495 MB live heap. **A background whole-planet
  prebake needs ZERO new resident memory — it re-uses this tier. NEVER-OOM is not the constraint;
  fill-pacing on 2 cores is.**
- The fix is therefore a **scheduler change, not a data-structure change**: a bounded background
  pacer (`FP_BG_PREBAKE`) that (1) lifts the on-surface fine pause under a strict per-frame governor,
  (2) fills **view-cone-first** so the facet you are looking at sharpens in ~1–2 s, and (3) routes
  through the C++ tile bake on-surface behind a contention budget. Progressive, off-main,
  imperceptible.

---

## 1. The tier stack as it renders today (file:line)

The far surface is a flat-colour "map skin" painted onto the faceted shell by
`facet_far_ring.gd`'s `_apply_flatcolor` shader. Under the live flag set the fragment shader is
`_FLAT_ALBEDO_META_FINE` (`facet_far_ring.gd:4482`), whose fallback order per texel is:

```
FINE (fine_map)  →  BAND (band_map)  →  BASE (base_map, coarse)
```

- **FINE** — `FP_PLANET_MAP`, always-resident whole-planet tier. 24-layer L8 `Texture2DArray`
  (`fine_map`), 6 faces × 2×2 quadrants. `_f8 = texelFetch(fine_map…)`; if `_f8>0` use
  `far_lut[_f8-1]`, else fall through to `col` (base). `facet_far_ring.gd:4485-4487`.
- **BAND** — `FP_BAND_BLOCK_MAP`/`FP_SKIN_FLATCOLOR`, 180-layer 512² L8 LRU (`band_map`), the
  close-approach 1-blk/texel sharpener. A baked texel (`_bid>0`) overrides fine; an unbaked
  (`_bid==0`) or evicted (`band_meta` sentinel `_m.x<-0.5`) texel falls to fine.
  `facet_far_ring.gd:4488-4502`. The fine sample is deliberately hoisted ABOVE the band branch so a
  mid-bake band texel shows fine, not base (`facet_far_ring.gd:4477-4481`).
- **BASE** — `base_map`, 6 face pages at 16 texels/facet (`_base_all = 6*K*K` facets;
  `facet_tex_baker.gd:235`). `source_color, filter_linear_mipmap` (`facet_far_ring.gd:4208`) — so
  when both fine and band are absent, `col` is a *linearly-blurred* ~26-blk/texel average. This is
  the coarse fallback the user is looking at.

So a facet with `fm_baked=0` (fine empty) AND not in `_bm_slots` (band empty) renders **base only**
= blurry + tone-averaged. That is the ugly facet.

---

## 2. Root cause of the ugly facet-in-front — cause (a), proven

**Live telemetry at facet 1716, alt 195, looking down: `fm_baked=0`, `bm_res=0/want=49`,
`cpp_on=False`.** Decoding each against the code:

### 2.1 `fm_baked=0` — the fine tier is paused on-surface

`_fm_on = FP_PLANET_MAP and _pbm_on` (`facet_tex_baker.gd:1687`). Fine dispatch happens in
`_update_band_parallel` step 3 (`facet_tex_baker.gd:1834-1863`), guarded by:

```gdscript
# facet_tex_baker.gd:1844
if not fine_pause_on or _offsurface:   # fine_pause_on = CubeSphere.FP_FINE_BAKE_SURFACE_PAUSE (:1770)
    for i in range(active): ... _next_fine_fid(emit_axis) ...
```

`FP_FINE_BAKE_SURFACE_PAUSE` is **ON in the live deploy** (confirmed in the deploy flag set). At
alt 195 the regime is on-surface (`_offsurface == false`), so the whole condition is false → **no
new fine bakes are ever dispatched on-surface.** The fine tier only accumulates facets baked while
off-surface (the reap at `:1786-1798` still commits already-in-flight tasks after landing, but none
are dispatched fresh). Teleporting to a region you never orbited over → its facets were never
fine-baked → `_fine_baked` has nothing there → `fm_baked=0`. This is *intended* (REV5 killed the
"perpetual on-surface per-texel GDScript bake + WASM-allocator convoy", `facet_tex_baker.gd:1836-1843`)
— but it is exactly why the coarse base shows through on a fresh surface teleport.

### 2.2 `bm_res=0 / want=49` — the band is the only on-surface filler, and it is 1-worker-slow

The band residency want is the SSE disc (active ∪ nearest, capped to `BAND_LAYERS=180`),
`_recompute_band_want_sse` (`facet_tex_baker.gd:1164-1178`). `want=49` = the 49 facets the disc
wants at alt 195; `res=0` = a fresh teleport where none are baked yet. The on-surface parallelism:

```gdscript
# facet_tex_baker.gd:1776
var active: int = _pbm_n if (_pbm_tile_ok and _offsurface) else (1 if OS.has_feature("web") else _pbm_n)
```

On-surface web ⇒ **`active = 1`**. One GDScript `SurfaceShot` worker fills the band at ~1 facet/s
(the measured WASM optimum; more workers convoy). So the 49-facet disc takes ~40–50 s to sharpen —
this is the "wait for the bake, then it looks good" the user has confirmed before. In the first
second after teleport, `bm_res=0` and every facet in view shows base.

### 2.3 `cpp_on=False` — a red herring, and the real C++ gate that IS relevant

`"cpp_on": (CubeSphere.FP_CPP_FINE_BAKE and _offsurface and _sampler_obj != null)`
(`facet_tex_baker.gd:2054`). `FP_CPP_FINE_BAKE` is **not** in the live deploy set (it is the shelved
serialize-on-the-shared-lock loser), so `cpp_on` is *always* false live — it tells us nothing about
the shipped fast path. The shipped fast path is **`FP_CPP_TILE_BAKE`** (patch 0011, ON live), routed
via `_pbm_tile`:

```gdscript
# facet_tex_baker.gd:1828 (band) and :1860 (fine)
_pbm_tile[i] = 1 if (_pbm_tile_ok and _offsurface) else 0
```

`_pbm_tile` is **also `_offsurface`-gated**. So on-surface, even the ~12×-faster C++ tile bake is
off, and the band falls to the 1-worker GDScript path. On-surface, *nothing fast is running.* That
gate is the central lever for the fix (§4.3).

### 2.4 Why it reads as a *diagonal line + blur + tone jump* specifically

- **Blur** = the base tier is `filter_linear_mipmap` at ~26 blk/texel; averaging 26 blocks
  desaturates and smears.
- **Tone jump** = neighbouring facets already in `_bm_slots` (the disc fills nearest-first) show
  sharp, saturated 1-blk/texel colour; the fresh facet shows the washed base average. Same hue law
  (`FP_FAR_COLOR_UNIFIED`), different *resolution* → looks like a tone mismatch.
- **Diagonal line** = the boundary is a facet polygon edge (every tier is fid-keyed), and the fine
  sub-page is quadrant-split (`_q = floor(v_uv*2)`, `facet_far_ring.gd:4482-4483`), so a half-baked
  facet can even step mid-facet. The line is the frontier between "base-only" and "band-baked".

**Verdict: (a) unbaked fine+band at a fresh on-surface region → coarse-base fallback.** Not (b)/(c)/(d).
The fix is to *get high-quality coverage to that facet fast and everywhere* — i.e. the background
prebake — not to re-blend or re-colour tiers.

---

## 3′. Why the far-skin is the CHEAP layer to bake globally (the bounded case)

The lead asked to quantify baking JUST the far-skin layer globally, and confirm it is far cheaper
than full-res. It is — by construction the far-skin stores **one L8 byte (a palette index) per
texel at ~6.5 blocks/texel**, versus the alternatives:

| Whole-planet layer | Storage/facet | Whole planet | vs far-skin |
|---|---|---|---|
| **Far-skin FINE tier (FP_PLANET_MAP, the target)** | L8 @ 6.5 blk/texel | **~27 MB** | 1× |
| Band-quality everywhere (1 blk/texel L8) | L8 @ 1 blk/texel | ~1.1 GB* | ~40× |
| Full-res blocky L5 GEOMETRY globe | meshed cubes | ~158 MB (infeasible) | ~6× |

*and blocked by GPU array-layer / uniform-vec caps anyway (`voxiverse-block-lod-design` 2026-08-01).
So the far-skin FINE tier is the ONLY whole-planet layer that is both memory-bounded AND
GPU-representable. That is exactly why it is the right quality FLOOR: coarse enough to hold globally,
sharp enough (sub-pixel at horizon, 6.5 blk/texel up close) to read as clean everywhere. Near
facets still refine to band (1 blk/texel) and real blocks on top — the fine tier is the floor, not
the ceiling.

## 3. Memory budget — the make-or-break number (QUANTIFIED)

The whole-planet high-quality tier already exists: **`FP_PLANET_MAP`, the FINE tier.** Its exact
resident footprint (`facet_tex_baker.gd:2106-2110`, live const values):

```
PLANET_MAP_TEXELS = 64            (cube_sphere.gd:658)   → 6.5 blocks/texel over a ~417-block facet edge
PLANET_MAP_QUAD   = 12            (K/2, K=24)
_fm_page          = 12 × 64 = 768
one L8 sub-page   = 768 × 768 × 1 = 589,824 B  = 0.5625 MB
layers            = 6 faces × 4 quadrants = 24
CPU staging (_fm_pages) = 24 × 0.5625 MB = 13.5 MB
GPU array   (_fm_tex, L8, no mips) = 24 × 0.5625 MB = 13.5 MB
------------------------------------------------------------
FINE tier total = ~27 MB, FIXED-SIZE, allocated once at setup.
```

Context for NEVER-OOM (`voxiverse-never-oom-web`, measured in `voxiverse-cpp-tile-bake-block-exact`):

| Item | Bytes | % of 2048 MB WASM ceiling |
|---|---|---|
| **FINE whole-planet tier (this design's target)** | **~27 MB** | **~1.3%** |
| BASE 6-page tier + closeup | ~8.2 / ~17.8 MB | <1% |
| BAND 180-layer LRU | ~48 MB | ~2.3% |
| Measured live PEAK heap (everything, orbit fill) | 412–495 MB | 20–24% |

**The critical finding: the background prebake requires ZERO new resident memory.** It fills a tier
that is *already allocated and already on the NEVER-OOM ledger*. There is 1.5 GB of headroom. The
~158 MB "infeasible" figure from `voxiverse-block-lod-design` was a fully-meshed L5 *geometry* globe
— a different thing entirely; the fine tier is a flat *colour* skin, ~6× cheaper and already shipped.

**So there is no bounded-compromise to make on memory.** The only reason the whole planet is not
already high-quality everywhere is *fill pacing on 2 cores*, addressed below. (Optional quality
sweetener — bump `PLANET_MAP_TEXELS` 64→96 for ~3× sharper base coverage — would cost 27→60 MB, still
<3% of ceiling, but is out of scope and gated separately; the coarse-base blur is fixed by *filling
the existing tier*, not by enlarging it.)

---

## 4. Design — `FP_BG_PREBAKE`: bounded background whole-planet prebake

**Thesis: keep the data structure (the ~27 MB fine tier); replace the binary on-surface pause with a
governed background pacer that fills the whole planet progressively, off-main, view-cone-first.**

### 4.1 What data — the existing fine tier, unchanged

No new resident structure. The pacer writes into `_fm_pages` / `_fm_tex` via the existing
`_fine_commit` (`facet_tex_baker.gd:1731-1741`) and the throttled GPU upload
(`_fm_dirty` → `_fm_tex.update_layer`, `:1871`). Byte footprint unchanged (§3).

### 4.2 Where it is driven — the `_pbm_*` parallel bake, un-paused under a governor

Replace the on-surface pause (`facet_tex_baker.gd:1844`) with a **frame-time governor** rather than
a hard regime gate. Under `FP_BG_PREBAKE`:

```gdscript
# proposed, replacing the `if not fine_pause_on or _offsurface:` gate
var bg_ok := _offsurface \
    or (CubeSphere.FP_BG_PREBAKE \
        and _bg_frame_healthy \                       # last main-frame proc_ms < BG_FRAME_BUDGET_MS (e.g. 22ms)
        and _bg_inflight() < BG_MAX_INFLIGHT_SURFACE)  # e.g. 1 fine task in flight on-surface
if not fine_pause_on or bg_ok:
    ... dispatch _next_fine_fid ...
```

- **`_bg_frame_healthy`** is set each `update()` from the same frame-time signal the smooth pacer
  reads; when the main thread is under load (streaming a crossing, chopping, phys settle) the pacer
  *skips dispatch entirely that frame*. This is what makes it imperceptible — it only spends idle
  main-thread headroom, never competes during a hitch.
- **`BG_MAX_INFLIGHT_SURFACE = 1`** on web: one background fine task at a time on-surface (the
  measured non-convoy optimum), so the pacer never thrashes the WASM allocator the way REV5 found.
- Off-surface behaviour is **byte-identical to today** (the `_offsurface` branch is unchanged).

### 4.3 Which path — C++ tile bake on-surface, behind a contention budget

The on-surface `_offsurface`-gate on `_pbm_tile` (`:1828`, `:1860`) exists because on-surface the
near-field VoxelTerrain C++ gen is running hot and F3 chose to "leave cores for the near-field gen"
(`voxiverse-cpp-tile-bake-block-exact`). But the *tile* baker (patch 0011) holds its **own generator
instance** with a per-instance `RWLockRead` (reader-parallel) — unlike the shelved *fine* baker which
serialised on the shared lock and froze the game at 1.5 fps. So the tile path *can* run on-surface if
rate-limited.

Under `FP_BG_PREBAKE`, allow `_pbm_tile` on-surface **only for the single background slot** and
**only when `_bg_frame_healthy`**:

```gdscript
_pbm_tile[i] = 1 if (_pbm_tile_ok and (_offsurface or (CubeSphere.FP_BG_PREBAKE and _bg_frame_healthy))) else 0
```

This gives the background sweep the ~12× C++ throughput (~one facet's 4096 columns in native per
task) instead of the ~1/s GDScript path — turning "whole planet in ~1 hr" into minutes, at a cadence
the governor keeps invisible. If the tile bake is measured to contend with near-gen even at 1 slot
(live A/B), the flag falls back to the GDScript path automatically (the `_pbm_tile_ok` refusal latch
already exists) — a graceful degrade, not a crash.

### 4.4 Priority — VIEW-CONE-FIRST (this is what kills the symptom)

Today `_next_fine_fid` sweeps by a cursor near the emit axis (`facet_tex_baker.gd:1704-1729`). Change
the on-surface background order to **facets in the player's view frustum, nearest-first**, then radiate
outward to the rest of the planet:

1. the active facet + its ring (the facet-in-front) — fills in ~1–2 s via the C++ tile path;
2. the rest of the visible disc (the `_bm_want` set already computes this);
3. the remaining planet, cursor-swept, at the lowest governor priority (the "prebake the whole
   planet in the background" goal — so a later look-around or teleport-nearby is already covered).

Because the fine tier is whole-planet-resident, once a facet is baked it *stays* baked (no LRU on
fine) — so the second time you look at a region it is instant. The band still sharpens close approach
on top (1 blk/texel), but the *coarse-base blur is gone the moment the fine texel lands* (6.5
blk/texel), which is a 4× sharpness jump and removes the tone/line artifact.

### 4.5 Pacing budget so it is imperceptible on 2 cores

- **1 background bake slot on-surface** (`BG_MAX_INFLIGHT_SURFACE=1`), C++ tile path, off the main
  thread via `WorkerThreadPool.add_task`.
- **Frame governor**: dispatch only when `last_proc_ms < BG_FRAME_BUDGET_MS` (~22 ms ≈ 45 fps floor).
  On a hitch (crossing/chop/phys) the pacer goes silent that frame. This is the same discipline the
  smooth pacer uses and the reason it can run during play.
- **GPU upload throttle**: reuse the existing `_fm_dirty` throttled `update_layer` (`:1871`) —
  ≤N sub-page uploads/frame — so the ~0.56 MB layer writes never spike a frame.
- **Result**: the visible disc sharpens in a few seconds (C++ tile, view-first); the whole planet
  fills over a couple of minutes of idle-headroom nibbling, never dropping below the fps floor.

### 4.6 How it eliminates the coarse-fallback ugliness

- The facet-in-front gets a fine texel within ~1–2 s of teleport (view-first + C++ tile) → 4×
  sharper than base, tone matches neighbours (same `far_lut`), no resolution line.
- The rest of the planet becomes uniformly fine-covered in the background → *no* fresh-teleport
  location can show base-only again once prebake has swept it → "consistent quality everywhere," the
  user's actual ask.
- Off-surface behaviour and the band close-up sharpener are unchanged.

### 4.7 Proposed flags (all `const FP_* := false`, byte-off, FLAT 6042/0)

| Flag | Role |
|---|---|
| `FP_BG_PREBAKE` | master: lift the on-surface fine pause under the governor + view-cone-first order |
| `FP_BG_PREBAKE_CPP` | (sub-flag) allow the C++ tile path in the single on-surface background slot; off ⇒ GDScript fallback path (safe degrade) |

Constants: `BG_FRAME_BUDGET_MS := 22.0`, `BG_MAX_INFLIGHT_SURFACE := 1`, `BG_VIEWFIRST := true`.
`FP_BG_PREBAKE` OFF ⇒ the exact shipped `FP_FINE_BAKE_SURFACE_PAUSE` behaviour (byte-identical).

---

## 5. Should `FP_CPP_TILE_BAKE` be part of the answer? (lead's explicit question)

Yes — as the on-surface *throughput* lever, but it is currently **enabled-but-not-engaging** on
surface by design, not a gap. `FP_CPP_TILE_BAKE` is ON live, but every dispatch site gates
`_pbm_tile` on `_offsurface` (`:1828`, `:1860`) and the worker count collapses to 1 on-surface
(`:1776`). So on-surface the fast path is dark and the band falls to GDScript-1-worker. The fix
(§4.3) is to let the tile path run in the single governed background slot on-surface. The `cpp_on`
telemetry does NOT report this (it reports the shelved `FP_CPP_FINE_BAKE`); the new gate must add a
`bg_cpp_on` / `bg_inflight` field so the live A/B can confirm the tile path is engaging on-surface.

---

## 6. Gate spec — `verify_bg_prebake.gd` (headless, FACETED sed-toggled)

- **G-BGP-OFF (byte-off)**: `FP_BG_PREBAKE=false` ⇒ dispatch decisions bit-identical to the shipped
  `FP_FINE_BAKE_SURFACE_PAUSE` path; FLAT `verify_feature` 6042/0.
- **G-BGP-COVERAGE**: after simulating N governed on-surface ticks at a fixed active_fid, assert
  `_fine_baked` grows to cover the view-cone set *before* the far cursor set (view-first ordering),
  and eventually reaches `_base_all` (whole-planet completeness). Falsify: shuffled order fails the
  view-first assertion.
- **G-BGP-BUDGET (memory)**: `total_bytes()` with `FP_BG_PREBAKE` on == `FP_BG_PREBAKE` off (the
  pacer adds ZERO resident bytes — it fills the existing fine tier) AND stays < `FACET_TEX_BYTES_MAX`.
  Assert fine tier == ~27 MB at the live consts.
- **G-BGP-PACING**: inject a "hot frame" (`last_proc_ms > BG_FRAME_BUDGET_MS`) and assert the pacer
  dispatches ZERO new background tasks that frame; inject a healthy frame and assert ≤
  `BG_MAX_INFLIGHT_SURFACE` new tasks. Falsify: a governor-less dispatch fires during the hot frame.
- **G-BGP-CPP-DEGRADE**: with `_pbm_tile_ok=false` (module absent / refusal), assert the background
  slot still dispatches via the GDScript path (no dead slot, no crash).
- **Live A/B (adjudicator)**: teleport to a never-orbited surface facet; confirm `fm_baked` climbs
  from 0 with view-first order, the facet-in-front loses the coarse blur within ~1–2 s, `bg_inflight`
  ≤1, main-frame fps floor held ≥45, heap flat (no OOM). This is the real sign-off — headless cannot
  see the blur.

---

## 7. Risks / open items

- **On-surface C++ tile contention**: the F3 finding that motivated the off-surface gate was about
  the *fine* baker's shared lock; the *tile* baker's own-instance RWLockRead should be safe, but this
  is the one thing the live A/B must confirm. `FP_BG_PREBAKE_CPP` isolates it so a bad result rolls
  back to GDScript-1-worker (slower fill, still correct) without touching the master flag.
- **View-cone plumbing**: the baker needs the camera facet + look direction on-surface. `_bm_want`
  already encodes the SSE disc (nearest-first); the view-cone order can piggyback that set for phase
  1–2, and only phase 3 (whole-planet) needs the cursor sweep. No new cross-thread state.
- **`filter_linear_mipmap` on base vs `filter_nearest` on fine**: once fine covers a facet the blur
  is gone, but during the ~1 s before the first tile lands the base still shows. If that first second
  is still objectionable, a cheap follow-up is to bias the base tier toward the *band-want* facets at
  boot (already partly true) — not needed for the core fix.
- This is a **pacing** change; it does not touch the smooth-V2 relief, the far-ring backstop, or the
  colour law. It composes with all of them (all fid-keyed, all read the same `far_lut`).

---

## 8. Bottom line

- **Ugly facet-in-front = cause (a)**: fine+band unbaked at a fresh on-surface region → coarse-base
  fallback (blur + tone + diagonal line are one resolution artifact). File-proven at
  `facet_tex_baker.gd:1844` (surface pause), `:1776` (1-worker on-surface), `:1828/1860` (C++ tile
  off-surface-gated), shader `facet_far_ring.gd:4482-4506`.
- **`fm_baked=0`/`cpp_on=False`**: both expected on-surface, not bugs — `FP_FINE_BAKE_SURFACE_PAUSE`
  ON + `cpp_on` tracks a shelved flag.
- **Quality floor = the far-horizon skin = the `FP_PLANET_MAP` FINE tier.** The prebake bakes THAT
  layer for the whole planet so every facet is ≥ far-skin quality; the coarse BASE intermediate
  (the ugly fallback) never shows again. Near facets still refine to band + real blocks on top.
- **Prebake design = `FP_BG_PREBAKE`**: governed, view-cone-first background fill of the *existing*
  ~27 MB fine tier via the C++ tile path in one on-surface slot, frame-time-gated to be imperceptible.
- **NEVER-OOM: the far-skin is the CHEAP bounded layer (~27 MB, ~40× cheaper than band-everywhere,
  ~6× cheaper than a meshed L5 globe) — fits with 1.5 GB to spare, ZERO new resident memory (already
  on the ledger).** The bounded case IS the answer, not a compromise; the only real constraint was
  fill-pacing on 2 cores, which the pacer solves.
