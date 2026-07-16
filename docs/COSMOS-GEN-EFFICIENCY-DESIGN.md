# COSMOS Generation-Efficiency Design (crossing jerkiness / fall-through)

Status: DESIGN (2026-07-16). Branch `fix/voxiverse-crossing-jerkiness`.
Scope: make the faceted voxel-worker generator (`module_world.gd::_generate_block`)
dramatically cheaper so the 2 web workers keep up with the player, so mid-facet
walking is smooth, crossings do not freeze, and running fast does not outrun
generation (fall-through).

> **Headline (measured, not assumed):** the bottleneck is **not** the per-column
> noise profile the task brief suspected. It is the sheer **number of per-cell
> `resolve_cell` calls underground** — ~40–84 per land column. The column profile
> is ~2 % of a land column's cost, and a 2D profile costs almost exactly the same
> as the 3D one (`get_noise_2d` ≈ `get_noise_3d`). So: **Fix A (bulk underground
> fill) is the actual speedup (~27× per underground block); Fix C (2D face-local
> noise, USER-DECIDED) is essentially perf-neutral (~3 % of the profile) and is
> adopted for the per-face terrain model + reduced allocations, not for throughput;
> Fix B is mooted by C.** A and C land together behind separate flags.

---

## 0. Measured cost model (headless microbench, custom editor, N=40 000)

Two throwaway `--script` benchmarks (scratchpad, not committed) timed the real
functions on the shipped binary. Flat default mode; `resolve_cell` is the SAME
function on both render paths and its cost is dominated by per-cell hashing +
`TreeGen` gate (identical flat vs faceted), so the numbers transfer to faceted.
`profile_at_dir` (faceted) was timed separately at 2.29 µs vs 1.96 µs flat — same
order.

| Component | Cost | When paid |
|---|---|---|
| `column_profile` (flat 2D, memo miss) | **1.96 µs / column** | once per column per block |
| `profile_at_dir` (faceted, 6× `get_noise_3d` + `cell_dir` fold) | **2.29 µs / column** | once per column per block (faceted) |
| `slope_run_of` (9× `col_h` + corner predicate) | **5.02 µs / column** | once per column per block (hoisted) |
| `resolve_cell` deep stone, **hoisted** slope_run≥0 + pcache | **2.90 µs / cell** | every underground cell |
| `resolve_cell` shallow dirt (depth 2) | 1.87 µs / cell | every near-surface cell |
| `resolve_cell` deep stone, **analytic** (slope_run=−1, pcache=null) | 16.0 µs / cell | analytic/collider path only |
| 1× `get_noise_3d` | 0.153 µs | — |
| 1× `get_noise_2d` | 0.129 µs | — |
| 2D height stand-in (`_height_c` + 1× noise2d) | 1.04 µs / column | Fix-C hypothetical |
| **FULL land column emit** (1 profile + 1 slope_run + 84 underground `resolve_cell`) | **~319 µs / column** | — |

### What a land column actually spends (the 319 µs breakdown)

```
per-column overhead (profile 2.0 + slope_run 5.0)   ~7 µs    ~2 %
underground resolve_cell  (84 cells x 2.9 µs)      ~244 µs   ~76 %
surface / above-surface cells (snow/cap/tree/slope)  ~68 µs  ~22 %
```

Two facts drop out immediately:

1. **`column_profile` is 0.6 % of a land column.** `slope_run_of` (the other
   per-column term) is 1.6 %. Together the entire per-column overhead the brief
   worried about is ~2 %. Killing the ~11× (really ~5×, see below) vertical
   recompute of it saves at most ~35 µs/column — and Fix A removes it for free.
2. **Per-cell `resolve_cell` underground is ~76 %** and scales with the number
   of streamed underground cells. This is the lever.

### Why it manifests as "crossings freeze for seconds" and fall-through

A fully-underground 16³ data block runs 4096 `resolve_cell` calls:

```
4096 cells x 2.90 µs         = 11 878 µs
+ profile pass (256 col x 2) =    512 µs
+ slope_run pass (256 x 5)   =  1 285 µs
--------------------------------------------
~13.7 ms per fully-underground data block
```

The near field is ~2 600 blocks (module_world.gd:88). A large fraction under any
land surface is fully-underground. If ~500 of them are fully underground, a
crossing restream is `500 × 13.7 ms / 2 workers ≈ 3.4 s` of pure underground
generation — exactly the multi-second crossing freeze, and exactly why a fast
runner outruns the 2 workers and falls through un-generated ground. **The
underground the player never sees is eating the entire generation budget.**

---

## 1. The three fixes, re-evaluated against the measurement

### Fix A — Bulk underground fill (THE lever)  ✅ do first

**Idea.** A data block whose entire y-range is provably interior stone/deepslate
(below the dirt layer, above bedrock) is filled with a single material via
`VoxelBuffer.fill()` instead of 4096 `resolve_cell` calls.

**What `resolve_cell` returns underground (cited).** For `y < g` and depth
`g − y > _filler_depth(biome)` (max filler = 12, badlands; `terrain_config.gd:1937`):
`_surface_rule` returns `STONE` (`:1894-1903`); then for `y < g`
`_deep_family` (`:1975`) applies the deepslate gradient (stone above −16, dithered
−24..−16, deepslate below −24) **plus** `_strata_at` blobs (25 % of a 16³ lattice,
radius 3–7 — granite/diorite/andesite/tuff/calcite/dripstone, and sulfur/cinnabar
below −32); then `_ore_at` (`:2023`) stamps 8 ore types on a 6³ lattice in
depth-banded blobs. **Underground is therefore NEVER uniform** — strata and ore
blobs exist at every depth. A byte-identical bulk fill is impossible.

**What a uniform bulk fill loses:** all strata variants, all ores,
sulfur/cinnabar pockets, and (in the −24..−16 band) the deepslate dither. Below
−24 the base is uniform deepslate (bulk-fill deepslate loses only the strata/ore
*inside* it); in [−16, surface−12] the base is uniform stone.

**Why the loss is acceptable and near-invisible (the user has already accepted
this — see memory `voxiverse-neighbour-underground-direction`):** underground
cells are unseen until dug. `WorldManager.block_id_at → resolve_cell` (the
CLAUDE.md §1 analytic authority) reads `TerrainConfig` **directly, not the mesh
buffer**, so the true ore/strata is always the ground truth for physics and for
the *broken/dropped* block. The only thing the bulk fill changes is the
**appearance of an unexposed underground cell**, which is behind stone. On
exposure, truth must be restored (see "lazy regen" below).

**Qualification gate (correct + conservative).** During the existing per-column
profile pass (`module_world.gd:2623-2651`), also track `min_h` (we already track
`max_h`). A block bulk-qualifies when, after the pass:

```
s == 1                                        # LOD0 only (probe path untouched)
gen_facet < 0  OR  block is fully ridge-interior   # faceted: no junction straddle (see below)
oy + size.y <= min_h - MAX_FILLER_DEPTH(12)   # even the shallowest column is interior stone here
AND one of:
  oy >= DEEPSLATE_TOP_Y (-16)                 # -> bulk-fill STONE
  oy + size.y <= DEEPSLATE_FULL_Y (-24)       # -> bulk-fill DEEPSLATE
# blocks straddling the -24..-16 dither band, the dirt layer, or bedrock (-59) fall back to per-cell
```

`min_h ≥ oy + size.y + 12` guarantees every cell is `depth > filler` for every
column → `_surface_rule` = STONE for all, and no biome-top/dirt is skipped.
`oy ≥ −16` (or `oy+16 ≤ −24`) guarantees no bedrock/dither. So the block is a
pure interior slab and the fill material is well-defined.

**Faceted junction correctness (must-flag).** On a facet, cells beyond a ridge
are masked to AIR per-cell by `junction_modify` (`module_world.gd:2704`). A naïve
`buffer.fill(stone)` would wrongly fill beyond-ridge cells. Gate the bulk-fill on
the block being **fully interior to all four ridges** — reuse the existing
`FacetAtlas.cell_interior_scaled` / the inverse of `block_all_air` to prove no
straddle. Edge blocks fall back to per-cell (they are a minority, and already
partly caught by `block_all_air`).

**Expected speedup.** A qualifying fully-underground block: **13.7 ms → ~0.5 ms**
(the profile pass to get `min_h`, then `fill`; slope_run pass skipped, all 4096
`resolve_cell` skipped) — **~27×** on that block. Across the near field, if
underground blocks are ~30–50 % of the ~2 600 near blocks and each drops ~13 ms,
the crossing restream and steady-state worker load fall by roughly the
underground share — the multi-second freeze collapses to sub-second. This is the
fix that stops fall-through: the workers stop burning their budget on unseen
stone and keep up with the surface the player actually walks on.

**Even cheaper gate (optional).** We can skip even the profile pass for a
qualifying block if a cheap conservative lower bound on surface height over the
block's columns is available, but the profile pass is only ~0.5 ms vs the ~13 ms
saved, so it is not worth the complexity in v1.

**Lazy exposure-driven regen (the one real implementation subtlety).** Because
the bulk-filled buffer holds uniform stone, a dig that exposes a neighbour wall
would show stone where ore should be *until the buffer is regenerated*. Options,
cheapest-correct first:
  - **A-lazy (recommended):** when an edit first touches (or exposes a face of) a
    bulk-filled block, re-run the block per-cell (mark it "detailed") so the
    revealed walls carry true ore/strata. This is the "lazy regen on exposure"
    the user accepted; it pays the ~13 ms once, only for blocks the player
    actually mines into.
  - **A-eager-face:** only regenerate the 1-cell shell adjacent to the dug cell.
  - **A-accept:** ship uniform-stone walls underground and let the analytic break
    path color only the *dropped* block correctly (simplest; flag to user).

Coordinate with the in-flight `underground` work-stream — this fix is the
generation half of the same "stone-fill + lazy regen" direction.

**Risk:** medium. Byte-identity: **NOT byte-identical** (loses unexposed
underground ore/strata; user-accepted). Gate: a single `FP_BULK_UNDERGROUND`
flag defaulting **on** once the lazy-regen path lands; with it off the generator
is byte-identical (per-cell). Verify with a new `verify_*` assert that (a) a
bulk-filled block's *exposed* cells equal `resolve_cell` after a dig, and (b)
`block_id_at` is unchanged everywhere (physics ground truth intact).

---

### Fix B — Persistent per-worker column-profile memo  ⚠️ verdict: skip

**One-line verdict:** feasible cheaply (`OS.get_thread_caller_id()` + a `Mutex`-guarded
per-thread `GenCtx`, locked once per `_generate_block`, capped + facet-keyed like the
analytic memo), but it buys < 1 % (the per-column overhead is ~2 % of a land column and
Fix A removes it for the deep blocks), and it is **mooted by Fix C** — a 2D profile is
already cheap and both fixes land together. **Do not implement.** Details retained below
for the record.

<details><summary>Fix B (retained detail)</summary>

**What it would fix.** The brief's concern: `column_profile` is recomputed for
each vertically-stacked data block a tall column passes through. A ~180-block
column spans ~11 blocks, but the all-air early-out (`module_world.gd:2586`) and
all-bedrock early-out cull the blocks above terrain and below bedrock, so the
*real* redundancy is over the **solid + near-surface** stack — roughly 3–5 blocks
under the downward-reach clamp (`VIEWER_DOWNWARD_REACH_BLOCKS = 40`). So the
profile is recomputed ~3–5×, not ~11×.

**Measured value.** Per-column overhead (profile + slope_run) is ~7 µs, ~2 % of a
319 µs land column. Killing 4× of it saves ~28 µs/column, < 1 % of the total. And
**Fix A removes it entirely for the deep blocks** (a bulk block skips the
slope_run pass and pays the profile pass exactly once). After Fix A, the only
blocks that recompute the profile are the 1–2 surface blocks per column — nothing
left to memo across.

**Thread-safety cost (why the risk isn't worth ~1 %).** `_generate_block` runs on
2 godot_voxel worker threads. A shared `static` memo races. The safe mechanism is
`OS.get_thread_caller_id()` (confirmed available; the analytic memo already uses
`_on_main_thread()` via `OS.get_thread_caller_id()`/`get_main_thread_id()` at
`terrain_config.gd:1554`) → a `Mutex`-guarded `Dictionary[thread_id → GenCtx]`,
locking **once per `_generate_block`** to fetch the per-thread ctx, then lock-free
(each thread touches only its own ctx). Plus a cap + a facet-key like the analytic
memo (`_ANALYTIC_MEMO_CAP`, `terrain_config.gd:874`) to avoid unbounded growth
across facet crossings. This is *feasible cheaply* — but it buys < 1 % after Fix
A, so the added static-state + locking + cap-eviction surface is not justified.

Retained mechanism above in case profiling after Fix A ever shows surface-block
profile recompute as hot.

</details>

---

### Fix C — Cheap 2D face-local noise  ✅ USER-DECIDED — implementation-ready below

The user has **decided** to adopt the 2D face-local approach and **explicitly
accepts** (a) cube-edge seams at the 12 cube edges and (b) per-face terrain
(continents no longer span faces). This section is the implementation plan.

> **Honest perf note (measured, do not skip).** A full 2D face-local profile costs
> **1.82 µs/col** vs the faceted 3D `profile_at_dir` **1.87 µs/col** — a **0.06 µs
> (~3 %) saving on the profile**, because `get_noise_2d` (0.129 µs) ≈
> `get_noise_3d` (0.153 µs) and the `cell_dir` fold+normalize is only ~0.1 µs.
> The premise that "sphere math is expensive" does **not** hold: it is ~2 % of a
> land column. **Fix C is essentially perf-neutral on its own** (~0.02 % of a
> 319 µs land column). Its realized benefits are: (1) with Fix A, a
> profile-bound bulk-underground block gets ~3 % cheaper; (2) it drops the two
> `CubeSphere.DVec3` allocations `cell_dir` makes per column → less GC churn on
> the memory-constrained web workers (a mild NEVER-OOM benefit); (3) the per-face
> terrain the user wants. **The generation speedup that fixes crossing-freeze and
> fall-through is Fix A, not Fix C.** Ship C for the terrain model + allocation
> reduction, and rely on A for the throughput.

#### C.1 The 2D scheme (`facet_profile_2d`)

Replace `facet_profile(fid, x, z)`'s body under the flag. Instead of
`cell_dir → profile_at_dir` (6× `get_noise_3d` on the f64 direction), compute a
**face-global 2D block coordinate** `(FI, FJ)` for the facet cell and run the
verbatim flat 2D pipeline (`column_profile`'s FLAT else-branch, `terrain_config.gd:594-601`)
on it: `_continent/_temperature/_humidity.get_noise_2d(FI,FJ)`, `_height_c(c, FI, FJ)`
(which already folds hills + detail + the 2D `_mountain_factor` uplift, `:473-492`),
`_mountain_factor(c, FI, FJ)`, `_biome(...)` → `Vector4(g, biome, c, t)`. **No new
noise objects, no f64 fold, no `DVec3` allocation.** `resolve_cell` is UNCHANGED —
it consumes the scalars, so the stackup / strata / ore / smoothing pipeline is
untouched; only the `(g, biome, c, t)` source changes.

#### C.2 The face-global coordinate (continuity by construction)

Decode the facet's face + grid position from `fid` (free — the atlas builds
`fid = (face·K + a)·K + b`, `facet_atlas.gd:95`):
```
face = fid / (K*K)      a = (fid / K) % K      b = fid % K        # K = 24
```
`cell_dir` already measures the cell's planar lattice position from the facet
corner `c0'`: `fx = x − _off[fid·2] + 0.5`, `fz = z − _off[fid·2+1] + 0.5`
(`facet_atlas.gd:248-249`), with `fx, fz ∈ [0, EDGE]` over the facet
(`EDGE = (π/2·R)/K ≈ 201` cells). Compose the **face-continuous** coordinate:
```
FI = a*EDGE + fx + FACE_OFF_X[face]
FJ = b*EDGE + fz + FACE_OFF_Z[face]
```
`FACE_OFF_*[face]` are 6 large fixed per-face constants (e.g. `face*100000`) that
push each face into a disjoint region of the shared 2D noise domain, so faces are
independent (no accidental mirroring).

**Within-face continuity (proof).** Across the shared ridge between facet `(a,b)`
and `(a+1,b)`: the first facet's `+a` edge has `fx = EDGE ⇒ FI = (a+1)·EDGE`; the
second's `−a` edge has `fx = 0 ⇒ FI = (a+1)·EDGE` — same `FI`. Along that shared
edge `FJ = b·EDGE + fz` runs identically for both (shared physical edge, same
corner ordering). So the 2D field is C0 across every facet ridge within a face, to
the precision of the rigid planarization (sub-block; both facets sample the SAME
`get_noise_2d(FI,FJ)`). **Cube edges:** two faces have different `(a,b)` origins
and different `FACE_OFF` → independent fields → a raw seam. Accepted.

> If a sub-block micro-seam is ever visible *within* a face (planarization
> rounding), the exact fallback is to derive `(FI,FJ)` by bilinear interpolation
> of the facet's four `facet_planar_corner` positions by `(fx/EDGE, fz/EDGE)` —
> identical to what `facet_far_ring._ensure_cached` already does (`:178-191`) —
> which forces exact agreement at shared corners/edges. Not expected to be needed.

#### C.3 Latitude climate (keep it — nearly free)

The 3D path derives temperature from latitude via `_latitude_temperature(d.z, noise)`
(`:826`), which the 2D coordinate loses. Poles-cold / equator-warm is real
gameplay (frozen biomes, snow caps). Preserve it cheaply: at `warm_up`, precompute
per-facet a **linear `dz` fit** `dz ≈ dz0 + dzu·(fx/EDGE) + dzv·(fz/EDGE)` from the
four corner directions' `z` (corners already computed in `_build_facet`; store 3
floats/facet or derive from `facet_planar_corner`). Then
`t = _latitude_temperature(dz_fit, _temperature.get_noise_2d(FI,FJ))`. This keeps
the latitude bands with one extra mul-add. (Simpler alternative, if the user
prefers: drop latitude entirely → pure 2D per-face climate. Recommendation: keep
the cheap `dz` fit — the pole/equator gameplay is worth ~0 µs.)

#### C.4 Flag strategy

New flag `CubeSphere.GEN_2D_FACELOCAL` (a `const bool`, default **OFF**). Off ⇒
`facet_profile` takes the current 3D branch → **byte-identical** to today; the
FLAT non-faceted path is never touched (verify pin **6035/0** stays). On ⇒ the 2D
face-local branch. A `const` (compile-time) flag means no runtime flip, so the
`_shape_memo` / `_analytic_ctx` memos never hold mixed-mode entries. (If it must
be runtime-settable for A/B, its setter MUST clear `_shape_memo` and
`_analytic_ctx.memo` and re-warm the far ring — same discipline as
`set_active_facet`, `:642`.)

#### C.5 Every consumer — and why only TWO edit sites are needed

**The funnel does the work.** Both the worker generator AND the analytic path reach
the faceted profile through the SAME `column_profile → facet_profile`:
- **Worker:** `_generate_block` → `column_profile(x,z, GenCtx.facet)` → `facet_profile`
  (`module_world.gd:2625,2649`); plus `slope_run_of → _corner_targets → _col_h →
  column_profile → facet_profile`; plus `TreeGen.block_at(pcache) → column_profile`.
- **Analytic (collision/player/HUD/far/spawn):** `height_at → analytic_column_profile
  → _acquire_facet_ctx → column_profile → facet_profile` (`:508,904-911`); the shape
  memo (`_shape_entry`), `PerVoxelEnvironment`, `SnowfallSystem`, `structural_solver`,
  the spawn scan, and `far/far_mesh_builder.gd` (`analytic_column_profile`, `:25`) all
  read through it.

So **swapping `facet_profile` under the flag makes the worker and the analytic
path change together, by construction** — the exact property that prevents
analytic≠worker fall-through/floating. This is the single most important
correctness fact of Fix C: there is no way for physics height and rendered height
to disagree, because they are the same function call.

**The one bypass that must ALSO be edited:** `facet_far_ring.gd:194` calls
`TerrainConfig.profile_at_dir(dx,dy,dz, R)` **directly** on a bilinear-interpolated
facet direction, NOT through `facet_profile`. Under the flag this would leave the
FACETED far ring on the 3D field while the near field is 2D → a visible near/far
height seam at the LOD boundary. **Fix:** route it through the flag too. It already
has `fid` and `(s,t)` (`:186-188`), so it can call a shared
`facet_profile_at_st(fid, s, t)` that, when `GEN_2D_FACELOCAL`, maps `(s,t)→(FI,FJ)`
with the SAME `FACE_OFF`/`EDGE` construction (`FI = a*EDGE + s*EDGE + FACE_OFF_X`,
etc.) so near and far agree exactly, and otherwise keeps `profile_at_dir`. (The
other `profile_at_dir` callers — `facet_profile` itself and `_curved_profile_base`,
the non-faceted curved path, and the M5C pillar helpers — are not on the faceted
near path and need no change.)

Edit sites: **(1)** `TerrainConfig.facet_profile` (+ the `warm_up` `dz`-fit precompute
+ `FACE_OFF`/`EDGE` consts); **(2)** `facet_far_ring._ensure_cached`. That is the
whole blast radius.

#### C.6 Composition with Fix A

A and C are orthogonal and land together:
- Fix A bulk-fills deep interior blocks (the ~76 % underground `resolve_cell` term).
- Fix C cheapens the per-column profile (the residual term A leaves behind).
- On a **bulk-underground block** (A skips `resolve_cell`, so its cost is the
  256-column profile pass to get `min_h` + the `fill`), C trims the profile pass
  by ~3 % (586 µs → ~510 µs for K=24). Small, but free once C is in.
- The `min_h` gate Fix A needs is produced by the SAME profile pass, now 2D. No
  interaction hazard: A reads `g = int(profile.x)`, unchanged contract.
- Order: implement Fix A first (the real speedup), add Fix C's `facet_profile`
  swap + far-ring edit under its own flag; A/B each independently.

## 2. Gate plan

1. **Flag-off byte-identity.** With `GEN_2D_FACELOCAL` off (and
   `FP_BULK_UNDERGROUND` off) the generator is bit-for-bit today's; the FLAT verify
   pin stays **6035/0**. Assert in `verify_faceted`/`verify_fp_*`.
2. **Analytic == worker under the flag (the fall-through gate).** A `verify_*` that,
   for a sample of faceted cells, asserts
   `CellCodec.mat(generated_cell_global(...)) == the module-worker buffer value` and
   `height_at(x,z) == int(column_profile(x,z, workerctx).x)` — i.e. the analytic
   surface the player/collider stands on equals the worker-meshed surface. Passes
   *by construction* (same `facet_profile`), but pin it so a future direct
   `profile_at_dir` caller can't silently reintroduce a mismatch.
3. **No-fall-through invariant.** Assert that for every near column the analytic
   `floor_under` / `surface_y` (which drive the player collider) equals the top
   solid cell the worker emits — the concrete "you can stand on what you see" check.
   Same-function guarantee, pinned.
4. **Near == far.** After the far-ring edit, assert
   `far_ring_height(fid, s, t) == facet_profile_2d height` at shared sample points so
   the LOD boundary has no step under the flag.
5. **Within-face continuity smoke test.** Sample columns straddling a facet ridge
   within a face; assert `|g(ridge−) − g(ridge+)| ≤ 1`. (Cube edges exempt —
   seams accepted.)
6. **Fix A truth gate** (see §1 Fix A): exposed cells + `block_id_at` stay truthful
   after a dig into a bulk-filled block.

## 3. Sequenced recommendation

1. **Fix A — bulk underground fill (do first; it is the actual speedup):** ~27× per
   fully-underground block, collapsing the multi-second crossing freeze and stopping
   fall-through. Behind `FP_BULK_UNDERGROUND`, with A-lazy exposure regen, the
   faceted ridge-interior guard, and the truth gate.
2. **Fix C — 2D face-local (user-decided; perf-neutral, terrain model + GC):** the
   `facet_profile` swap + `facet_far_ring` edit + cheap `dz`-fit, behind
   `GEN_2D_FACELOCAL`. Ship for the per-face terrain the user chose and the dropped
   f64 allocations; do NOT expect it to move the frame budget (~3 % of the profile,
   ~0.02 % of a land column).
3. **Fix B — skip** (mooted by C).

### The terrain-tradeoff decisions
- **Fix C (confirmed by user):** per-face continents + raw cube-edge seams accepted.
  Remaining sub-choice: keep the cheap latitude `dz`-fit (recommended — preserves
  cold poles at ~0 cost) vs pure-2D per-face climate.
- **Fix A (still needs confirming the exposure model):** unexposed underground shows
  as uniform stone/deepslate, losing the initial look of ore/strata until mined
  (physics/broken-block truth never affected — `block_id_at` reads the analytic
  field directly). User previously accepted "stone-fill + lazy regen"
  (memory `voxiverse-neighbour-underground-direction`). Recommendation: **A-lazy**
  (regen a block per-cell on first dig) vs A-eager-face vs A-accept.
