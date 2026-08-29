# COSMOS de-orbit slice smoothing — finer shell sectors + emit-allocation diet

**Status: DESIGN (no code). Flags: `FP_SHELL_SECTOR_FINE` (P1, primary), `FP_FARRING_EMIT_ACCUM`
(P2, recommended composition), `FP_SV2_SHELL_YIELD` (P3, small optional). All default OFF,
byte-off, FLAT `verify_feature.gd` 6042/0.**

Predecessors (read for the arc, not repeated here):
`docs/COSMOS-DEORBIT-SHELL-STAGING-DESIGN.md` (FP_SHELL_STAGE_REEMIT, commit 5c67a20) and
`docs/COSMOS-DEORBIT-SHELL-PREWARM-DESIGN.md` (FP_SHELL_PREWARM_DESCENT, commit 00924db).
Pre-warm is a measured win: the one-frame 927-facet / 2662 ms shell-reopen avalanche is gone and
the shell stays resident down the descent.

---

## 1. The residual, attributed

Pre-warm converted the single 2662 ms avalanche into a **series of ~284–1041 ms hitches** spread
over the descent band (alt ~885→500), one per staged shell sector-slice, every hitch carrying
`sh_stage_emit` = 130–144 (telemetry: `_stage_last_emit_facets`,
`godot/src/world/facet_far_ring.gd:311`, surfaced at `:3839`).

Why 130–144 exactly: `FP_FARRING_SECTORS` partitions the cap into **6 faces × 2×2 = 24 static
sectors** (`const SECTOR_SPLIT := 2`, `facet_far_ring.gd:292`). With `FacetAtlas.K = 24`
(`godot/src/cosmos/facet_atlas.gd:12`) each face-quadrant covers `(K/2)² = 12×12 = 144` fids
(`_sector_of`, `facet_far_ring.gd:2187–2196`). A sector is the **atomic** swap unit — the staging
budget (`_stage_filter_dirty`, `:2319`) takes whole sectors and its progress guarantee
(`kept.is_empty() or taken + fc <= CubeSphere.SHELL_STAGE_FACETS`, `:2378`) **always takes at
least one**, so a full 144-fid sector blows straight through the 112-facet budget
(`SHELL_STAGE_FACETS`, `cube_sphere.gd:364`). The observed slice size is therefore pinned at
one-sector = 130–144 facets, and lowering `SHELL_STAGE_FACETS` alone does **nothing** — the atom
is too big for any budget below 144 to bite.

Why 130–144 facets cost 284–1041 ms: the worker build (`_async_build_worker`, `:2695`) is an
allocation storm under the single wasm dlmalloc lock; the browser main thread allocates too and
convoys on that lock for the whole worker build, so the frame hitch ≈ the worker build wall time.
The measured cost is 2.2–7.2 ms/facet — superlinear vs the staging doc's assumed 2.62 ms/facet
because the convoy worsens with concurrent workers (smooth-V2 merges, env warms) and with the
per-build allocation volume (§4). Concurrently, `smooth_v2_commit_ms` spikes ~72 ms on some
descent frames — the whole-surface `ArrayMesh` apply of `FacetSmoothV2` (`facet_smooth_v2.gd:690`
step / commit at `:769–786`, rate-capped by `SMOOTH_V2_COMMIT_MS = 500`, `cube_sphere.gd:1288`)
landing by chance on the same frames as shell slices.

**Target:** no descent frame > ~150–200 ms. Low fps is acceptable; multi-hundred-ms jerk is not.

---

## 2. Ranked recommendation

| Rank | Change | Flag | Effect | Certainty |
|---|---|---|---|---|
| **P1** | Finer sector grid 6×4×4 = 96 sectors (≤ 36 fids each) + a matching 40-facet staging budget + scaled failsafe | `FP_SHELL_SECTOR_FINE` | Slice atom 144 → ≤ 36 facets ⇒ worst hitch 1041 → ~71–260 ms (linear scaling of the measured 2.2–7.2 ms/facet) | High — pure partition arithmetic; the mechanism is already proven at 24 |
| **P2** | Emit-allocation diet: per-sector accumulator arrays written in place, deleting the per-facet scratch quads + the assemble copy pass | `FP_FARRING_EMIT_ACCUM` | Cuts the per-build malloc count from ~10³ array allocs + full duplicate copy to ~tens; pushes the per-facet cost toward its un-convoyed ~2.2 ms floor ⇒ with P1, expected worst ~60–150 ms | Medium — the convoy share of tp/tc/parts vs `generate_normals` hash-node churn is not separable without instrumentation; composes and can only help |
| **P3** | Smooth-V2 commit yield: defer V2 commits while a staged shell run is active | `FP_SV2_SHELL_YIELD` | Removes the ~72 ms V2 apply from shell-slice frames (a 150 ms slice + 72 ms collision would breach 200) | High mechanism, small magnitude |

**Recommendation: ship P1 + P2 together; P3 as a third small flag in the same PR.**
The numeric case: P1 alone projects 71–260 ms worst (linear) — the top end brushes the 200 ms
target if the convoy stays at 7.2 ms/facet at small sizes. P2 attacks exactly that per-facet
convoy coefficient (and the per-build `generate_normals` input shrinks 4× under P1 anyway, since
it runs per emitted sector). Together the projection is ~60–150 ms worst-case slice — inside the
target with margin. P2 alone (24 sectors kept) would shrink each 144-facet convoy but the atom
stays 144 facets × ≥2.2 ms ≈ 320 ms floor-ish — **not sufficient alone**, which is why the finer
grid is primary.

Alternatives evaluated and rejected:
- **6×3×3 = 54 sectors** (≤ 64 fids): projects 126–460 ms worst — fails the target without P2,
  and with P2 has no advantage over 96 beyond ~24 fewer draws. Rejected as the primary size.
- **Sub-facet sectors**: no — the facet is the emit atom (`_emit_cached` takes a fid); splitting
  below it breaks the welded-cache seam law (§5).
- **Skip `generate_normals` for the shell** (largest single alloc source: a vertex-hash node per
  vertex, ~500 k per 144-facet build): deferred. The shell shader does read `NORMAL` for
  `COLOR.a < 0.5` vertices under `FP_SMOOTH_NORMAL_LIT` (`facet_far_ring.gd:5888`), so proving
  the far-ring sector meshes never carry such vertices needs a dedicated audit; not required to
  hit the target.
- **Lower `SHELL_STAGE_FACETS` only**: no-op — the 144-fid atom defeats any smaller budget (§1).

---

## 3. P1 — `FP_SHELL_SECTOR_FINE`: 96 sectors + fine staging budget

### 3.1 Grid-size math

- `K = 24` is exactly divisible by 4 → `half = K/4 = 6`; the clamp `mini(int(a / half),
  SECTOR_SPLIT - 1)` (`facet_far_ring.gd:2194–2195`) never binds; the partition is exact — every
  fid in exactly one sector, no ragged edge (same law as the shipped split-2).
- Max sector membership = `6² = 36` fids. Observed cap ≈ 900–930 facets ⇒ ~48 of 96 sectors
  populated (vs ~12 of 24 today).
- Per-slice cost at the measured 2.2–7.2 ms/facet: **36 × (2.2–7.2) ≈ 79–260 ms**, vs 284–1041 ms
  today. With P2 pulling the coefficient toward its floor: **~60–150 ms**.

### 3.2 The budget must shrink with the atom — and the failsafe must scale

Two consequences discovered in `_stage_filter_dirty` that the flag MUST handle or the win
evaporates:

1. **Budget**: with 36-fid sectors and the shipped `SHELL_STAGE_FACETS = 112`, the packer
   (`:2378`) would take **three** sectors per dispatch (~108 facets) — restoring today's slice
   size. The fine flag therefore pairs the grid with `SHELL_STAGE_FACETS_FINE := 40` (one full
   sector + headroom; a second 36-fid sector exceeds 40 and defers) and
   `SHELL_STAGE_TRIGGER_FINE := 48` (1.2× budget — the shipped 1.5× slack existed because a
   single sector could be 144; fine sectors don't need it, and an unstaged ≤48-facet burst is
   ~110–350 ms worst, borderline, so keep the trigger tight).
2. **Failsafe**: `:2365` dumps the FULL remaining dirty set unbudgeted past
   `SHELL_STAGE_MAX_MS = 2500`. A fine-grained pre-warm run is ~900 dirty / 40 ≈ 23 dispatches ≈
   3–4 s wall — it **would trip the failsafe mid-descent and re-create the avalanche**. Two-part
   fix, both inside the flag:
   - `SHELL_STAGE_MAX_MS_FINE := 7000` (the shipped 2500 × budget ratio 112/40 ≈ 2.8).
   - A **pre-warm-voluntary run never dumps**: when `_async_prewarm` is true (frozen at `:2574`,
     before `_stage_filter_dirty` runs at `:2583`) the emit is voluntary by construction — the
     resident cap + FALL_HOLD margin still cover every pixel (the exact argument of the
     `pwd_growth_ok` comment, `:2344–2352`) — so past the cap the run simply keeps chaining
     budgeted slices instead of dumping. The regime-forced (knee, non-prewarm) failsafe keeps its
     dump semantics at the scaled cap — a hole there is real.

   Total pre-warm work is unchanged (same facets, smaller slices), so wall-clock to full
   residency stays ≈ today's observed 885→500 band; if a live A/B shows the knee arriving before
   residency completes, the tuning lever is `SHELL_PWD_ALT_HI` (engage earlier), not the budget.

### 3.3 Draw-call and heap cost (NEVER-OOM check)

- **Draws**: populated sector MeshInstances ~12 → ~48 ⇒ **+~36 draws**, all sharing the ONE shell
  material instance (`_sectors_ensure_mi` copies `_mi.material_override`, `:2217–2225` — no state
  change between draws beyond the mesh bind). The shipped flag doc calls +12 "trivial at
  draws≈36" (`cube_sphere.gd:337`); +36 on a shared-material bind is the same class — total scene
  draws stay well under a hundred, no GL-compat concern.
- **Resident heap**: total cap vertices UNCHANGED (same cap, partitioned — the shipped
  NEVER-OOM argument, `cube_sphere.gd:345`). +72 MeshInstance3D + ArrayMesh objects ≈ tens of KB.
  Per-sector bookkeeping (`_sector_sig/_drawn/_bstop/_sunk_built`, sized by `_sector_count()` at
  `:2199–2213`) holds the same total fid entries, just spread over more dicts — noise.
- **Transient heap** (the convoy input): per-build surface shrinks 4× (a 144-facet dense sector
  is ~500 k verts ≈ 3.5 MB pos + 8 MB col+uv through 4 copy generations; a 36-facet build is ~¼
  of that). Peak transient DROPS.
- **Dirty-tracking overhead**: `_sectors_compute_dirty` (`:2269`) loops the frozen fid set once
  (unchanged) + `ns` sectors (24→96, trivial); one extra pass per extra dispatch (~23 vs ~7 per
  run) ≈ sub-ms each. Bounded.

### 3.4 Edit sites (minimal, reversible, byte-off)

**`godot/src/cosmos/cube_sphere.gd`** — new const block after the pre-warm block (after `:387`):

```gdscript
## COSMOS DE-ORBIT SLICE SMOOTHING (docs/COSMOS-DEORBIT-SLICE-SMOOTHING-DESIGN.md) — bound the
## staged shell slice. FP_FARRING_SECTORS' 2×2 face-quadrant sector (≤ (K/2)²=144 fids) is the
## ATOMIC swap unit, so every staged slice carries 130–144 facets and convoys the wasm dlmalloc
## lock 284–1041 ms/frame down the descent. When true, the partition refines to 4×4 (96 sectors,
## ≤ 36 fids each), the staging budget/trigger/failsafe scale to match (one sector per dispatch),
## and a pre-warm-voluntary run past the wall-clock cap keeps chaining budgeted slices instead of
## dumping the remainder unbudgeted (voluntary emit ⇒ deferral is never a hole). Same welded-cache
## seam law, same per-sector machinery (all arrays sized by _sector_count()). Requires
## FP_FARRING_SECTORS (+ STAGE_REEMIT/PREWARM_DESCENT for the descent path). Default OFF → the
## shipped 24-sector partition + 112/168/2500 staging consts verbatim (byte-identical, FLAT 6042/0).
const FP_SHELL_SECTOR_FINE := false
const SHELL_SECTOR_SPLIT_FINE := 4    # 4×4 per face → 96 sectors, ≤ (24/4)²=36 fids each
const SHELL_STAGE_FACETS_FINE := 40   # per-dispatch budget: one full fine sector + headroom
const SHELL_STAGE_TRIGGER_FINE := 48  # 1.2× budget (the 1.5× slack was the 144-fid atom's)
const SHELL_STAGE_MAX_MS_FINE := 7000 # 2500 × (112/40) — forced-run failsafe only (see §3.2)
```

**`godot/src/world/facet_far_ring.gd`**:

1. After `:292` (`const SECTOR_SPLIT := 2` stays untouched) add the resolver:

```gdscript
## FP_SHELL_SECTOR_FINE: the effective per-face split. Off ⇒ the shipped SECTOR_SPLIT (2) — every
## caller below computes byte-identical sector ids/counts.
func _sector_split() -> int:
	return CubeSphere.SHELL_SECTOR_SPLIT_FINE if CubeSphere.FP_SHELL_SECTOR_FINE else SECTOR_SPLIT
```

2. `_sector_count` (`:2181–2182`) — before:

```gdscript
func _sector_count() -> int:
	return 6 * SECTOR_SPLIT * SECTOR_SPLIT
```

after:

```gdscript
func _sector_count() -> int:
	var sp := _sector_split()
	return 6 * sp * sp
```

3. `_sector_of` (`:2187–2196`) — replace the four `SECTOR_SPLIT` reads with a local
   `var sp := _sector_split()`:

```gdscript
	var sp := _sector_split()
	var half := int(k / sp)
	var qa := mini(int(a / half), sp - 1)
	var qb := mini(int(b / half), sp - 1)
	return (face * sp + qa) * sp + qb
```

4. `_stage_filter_dirty` — three const reads become flag-resolved locals at the top of the
   function (`var budget := ...FACETS_FINE if fine else ...FACETS`, same for trigger; keeps the
   diff to three token swaps at `:2361`, `:2365`, `:2378`), plus the failsafe branch (`:2365–2369`)
   gains the pre-warm-voluntary no-dump:

```gdscript
	var fine := CubeSphere.FP_SHELL_SECTOR_FINE
	var b_facets: int = CubeSphere.SHELL_STAGE_FACETS_FINE if fine else CubeSphere.SHELL_STAGE_FACETS
	var b_trigger: int = CubeSphere.SHELL_STAGE_TRIGGER_FINE if fine else CubeSphere.SHELL_STAGE_TRIGGER
	var b_max_ms: int = CubeSphere.SHELL_STAGE_MAX_MS_FINE if fine else CubeSphere.SHELL_STAGE_MAX_MS
	...
	if _stage_active and Time.get_ticks_msec() - _stage_start_ms > b_max_ms:
		if not (fine and _async_prewarm):   # §3.2: a voluntary pre-warm run never dumps
			_stage_active = false
			_stage_hold = []
			_stage_deferred_n = 0
			return
```

Everything else — `_sectors_ensure_arrays`/`_ensure_mi`/`_compute_dirty`/`_record_frozen`/
`_reset`/`_swap_in_sectors` (`:2199–2487`) — is already sized by `_sector_count()` and indexed by
`s`; **zero code change**, which is the strongest correctness argument for the finer grid: the 96
case exercises the identical machinery the 24 case ships.

Byte-off: with the flag off, `_sector_split()` returns 2 and the three staging locals resolve to
the shipped consts — every computed value is identical to today (the function-call indirection is
the established FP pattern, e.g. `_stage_filter_dirty`'s own `stage_on` default args). FLAT never
constructs the ring with `FP_FARRING_SECTORS` on, so 6042/0 is untouched either way.

---

## 4. P2 — `FP_FARRING_EMIT_ACCUM`: per-build allocation reuse

### 4.1 The shipped allocation profile (the convoy's fuel)

Per dirty-sector worker build with `FP_FARRING_BULK_EMIT` on (the deployed path), **per facet**:

- `_emit_blocky_bulk` (`:4789`): `top_r` (`:4792`, 256 floats), `dirs` (`:4793`, 289 Vector3),
  `tp`/`tc` freshly sized to the facet's vertex count (`:4834–4835`, up to ~4–6 k verts ≈
  50–200 KB each), `tu`/`tu2` when textured (`:4836–4839`), the `[tp, tc, tu, tu2]` wrapper Array
  + `parts.append` (`:4957`). Same shape in `_emit_smooth_bulk` (`:4988–4993`, `:5019`).
- ⇒ ~6–8 heap objects **per facet** × 130–144 facets ≈ **~10³ allocations**, all retained until
  assemble (peak = the whole sector surface in per-facet fragments).

Then **per sector** in `_bulk_assemble` (`:5028`): the `append_array` merge (`:5035–5040`) — a
full second copy of the sector surface plus the accumulator realloc ladder — then
`SurfaceTool.create_from_arrays` (third copy), `generate_normals` (a vertex-hash node **per
vertex** — ~500 k allocations for a 144-facet dense sector, the largest single alloc-count
source), `commit_to_arrays` (fourth copy) (`:5050–5053`).

All of it runs under the one wasm dlmalloc lock while the browser main thread allocates
normally — the convoy.

### 4.2 The accumulator design

Under `FP_FARRING_EMIT_ACCUM` (worker-thread-local, requires `FP_FARRING_BULK_EMIT` +
`FP_FARRING_SECTORS`):

1. `_worker_emit_one` (`:2759–2768`): the per-sector `sink` becomes an **accumulator quad**
   `[PackedVector3Array, PackedColorArray, PackedVector2Array, PackedVector2Array]` created once
   per dirty sector (stored in `_async_sector_parts[s]` exactly as the parts Array is today —
   same lifecycle, same clearing at `_poll_async_rebuild` `:2802`).
2. `_emit_blocky_bulk` / `_emit_smooth_bulk` gain an accumulator write mode: the COUNT pass
   (already exact, `:4811–4832` / `:4979–4986`) yields `nv`; then
   `var base := acc_pos.size(); acc_pos.resize(base + nv)` and the fill loop writes at
   `base + w`. Godot `CowData` allocates power-of-two capacity, so the repeated grow-resize
   reallocs only on capacity crossings — **~log₂ reallocs per sector** instead of one alloc per
   facet. The per-facet `tp/tc/tu/tu2` + wrapper + `parts.append` disappear entirely, and with
   them the whole `_bulk_assemble` merge pass (copy #2).
3. `top_r`/`dirs` come from a worker-run-local scratch dictionary keyed `(cells, stride)`,
   `resize`d once and reused across facets (single-writer: one worker task at a time —
   `_async_building` gates dispatch, `:2586`).
4. Finalize per sector: a new `_accum_finalize(acc)` wraps the accumulator arrays into the
   ARRAY_MAX block and runs the **identical** `create_from_arrays → generate_normals →
   commit_to_arrays` tail (`:5050–5053`) — the byte-equality contract with the shipped path is
   preserved because vertex ORDER is identical (same facet iteration order `:2713`, same
   per-facet fill order) and the ST round trip is bit-exact (the G-FR-BULK precedent).

Expected effect: per-sector-build allocation count drops from ~10³ array allocs + ~n_verts
hash-nodes to ~tens + ~n_verts hash-nodes; transient volume drops one full surface copy; under
P1, `n_verts` per build is itself 4× smaller. The un-convoyed floor measured live is ~2.2
ms/facet; P2's claim is convergence toward that floor, **verified by the live A/B, not assumed**
(instrument `_async_build_us` per slice — it is already recorded, `:2753`, and pushed via the
`async-sect` event, `:2487`).

Byte-off: `FP_FARRING_EMIT_ACCUM := false` ⇒ `sink` stays the parts Array, the emit functions
never see the accum mode, `_bulk_assemble` runs verbatim — byte-identical, FLAT 6042/0.

Thread-safety: unchanged model — everything above runs inside `_async_build_worker` on the ONE
worker task; main touches `_async_sector_parts/_arrays` only after `is_task_completed`
(`:2781–2787`). No new shared state.

---

## 5. Seam-weld correctness at the finer grid (the #1 visual risk)

Three independent layers, none of which changes at split 4:

1. **Partition exactness.** `_sector_of` is a pure function of fid (`:2184–2186` — membership
   never churns with the emit axis). `K = 24` divides exactly by 4 (`half = 6`), so the
   `mini(..., sp-1)` clamps never engage and the face is tiled by exactly 4×4 equal quadrant
   blocks: every fid maps to exactly one sector — **no gap, no overlap, by arithmetic** (gate
   G-FR-FINE asserts it exhaustively, §6). This is the same property the shipped 24-grid relies
   on (`cube_sphere.gd:342–343`: "A facet emits into exactly ONE sector (partition — no
   double-emit, no gap)").
2. **Geometry welds are facet-level, not sector-level.** Sector borders always coincide with
   facet borders (the partition splits the fid lattice, never a facet). A facet's emitted
   geometry is a function of fid + the frozen caches ONLY — `_worker_emit_one` uses the sector id
   purely as a routing key for which collector receives the arrays (`:2759–2768`); nothing in
   `_emit_cached`/`_emit_*_bulk` reads sector geometry. Adjacent facets on either side of a
   sector border emit their shared-edge vertices from the same welded per-facet caches
   (`_pos_cache`/`_bpos_cache` — the shipped weld law, `cube_sphere.gd:343–344`: "shared facet
   edges come from the same welded caches, so sector borders weld exactly like facet welds"), so
   border vertex positions are **bitwise identical** across the two sector meshes regardless of
   how many sectors exist. More sectors ⇒ more borders of the same already-proven kind, zero new
   border classes.
3. **Staged coherence across a run.** The cross-sector sunk/slot mismatch protections are
   per-sector machinery that scales automatically: the §4.2a stage-hold overrides the five
   continuous inputs from ONE frozen snapshot for every staged dispatch (`:2530–2534`), and the
   §4.2b per-sector sunk record (`_sector_sunk_built`, sized by `_sector_count()` at `:2324`,
   written at `:2417–2418`) compares each sector against the state IT was built from. 96 rows
   instead of 24 — same law, no code change.

The one intentional per-sector difference — normals smoothed per sector rather than across the
whole cap — grows from 24 to 96 smoothing domains. The shipped flag accepts this as visually dead
because far-ring vertices emit `COLOR.a ≥ 0.5` and the shell shader shades those **radially,
never from NORMAL** (`cube_sphere.gd:347–349`; the `NORMAL` branch at `facet_far_ring.gd:5888`
serves only `COLOR.a < 0.5` smooth-tile vertices). The finer grid changes the count of these
invisible borders, not their kind.

---

## 6. Gate plan (real-path drivers — the C-lite/staging lesson)

All gates drive the REAL functions with forced params (the `stage_on`/`sectored_on` default-arg
pattern already used by `verify_shell_staging.gd:325+`), never a reimplementation. Fine-split
runs sed the flag on per the `verify_shell_prewarm.gd:15–17` RUN-header precedent.

**Extend `godot/src/tools/verify_farring_emit.gd` (G-FR-SECT → add G-FR-FINE):**
- Partition law at split 4: over the full 6·K² fid space, every fid maps to exactly one sector
  (`_sector_of` real call), sector ids ∈ [0, 96), and **max membership per sector == 36** (the
  per-slice facet bound; also asserts no clamp-induced fat edge sector).
- Union law: drive the real sectored dispatch/worker/swap (`_sectors_compute_dirty` →
  `_async_build_worker` → `_swap_in_sectors`) at split 4 and assert the union of sector meshes is
  vertex-for-vertex the single-cap mesh (the existing G-FR-SECT assertion, re-run at 96).
- Seam continuity: for a sample of sector-border facet pairs, assert shared-edge vertex positions
  in the two sector meshes are bitwise equal (mechanises §5.2).
- **G-FR-ACCUM**: build the same frozen set twice — parts path vs accum path — and assert the
  committed surface arrays are bit-identical (the G-FR-BULK equality precedent, one flag deeper).

**Extend `godot/src/tools/verify_shell_staging.gd`:**
- Budget law under fine consts: a >48-facet dirty burst stages at ≤ 40 emitted facets per
  dispatch (`_stage_last_emit_facets`), progress guarantee still emits exactly one full sector
  when a single sector exceeds nothing (36 ≤ 40 — no overshoot case remains).
- Failsafe law: a forced (non-prewarm) run past `SHELL_STAGE_MAX_MS_FINE` dumps (shipped
  semantics, scaled cap); an `_async_prewarm` run past the cap does NOT dump — it keeps chaining
  budgeted slices (assert `_stage_active` stays true and the next dispatch is still ≤ 40).
- Convergence: the staged fine run drains to the identical final shell as an unstaged build
  (the existing staging convergence assertion at 96 sectors).

**Extend `verify_shell_prewarm.gd`:** re-run the descent-latch → staged-growth sequence with the
fine flag on; assert `pwd_growth_ok` class-0 budgeting still holds at ≤ 40/dispatch and residency
converges.

**SV2 yield (P3):** in whichever gate drives `FacetSmoothV2.step` (or a small new
`verify_sv2_yield` section in verify_shell_staging), assert: with the yield arg true a dirty tile
does NOT commit; dirty is retained; the first step with yield false commits it (deferral is
lossless — the FP_SMOOTH_V2_PACE accumulation law).

**Byte-off:** all three flags off → FLAT `verify_feature.gd` **6042/0** and the existing
verify_farring_emit / verify_shell_staging / verify_shell_prewarm suites pass unchanged (no
sector count, budget, emit path, or V2 commit timing differs — §3.4/§4.2 off-paths).

---

## 7. P3 — `FP_SV2_SHELL_YIELD` (secondary, include)

`FacetSmoothV2.step()` (`facet_smooth_v2.gd:690`) commits a whole-surface ArrayMesh apply on main
(~72 ms observed on descent frames), rate-capped by FP_SMOOTH_V2_PACE (`:769–786`) but blind to
the shell's staged run — so it lands on slice frames by chance and stacks (150 + 72 > 200).

Design: `step()` gains a third arg `shell_yield := false`. In the far-ring `_process` call site
(`facet_far_ring.gd:1503–1506`):

```gdscript
		_smooth_v2.step(_load_settled, _stream_credit_ok,
			CubeSphere.FP_SV2_SHELL_YIELD and (_stage_active or (_async_building and _async_sectored)))
```

Inside `step()`, immediately before the commit branch (the `should_commit` gate, `:769–773`):
`if shell_yield: return` **after** reap/evict/dispatch have run (so tile workers never stall) —
only the main-thread apply defers; `_dirty` accumulates exactly as the PACE law already
guarantees (one later commit folds all ready tiles, `cube_sphere.gd:1283`). The staged run is
bounded (≤ `SHELL_STAGE_MAX_MS_FINE` forced / prewarm-band-limited voluntary), so the deferral is
bounded too. Off ⇒ the arg is `false` at the only call site ⇒ byte-identical.

---

## 8. Live A/B (the acceptance test)

Warm session → steady orbit → natural de-orbit to landing, remote-bridge telemetry at 10 Hz.
Flags on: the deployed set (`FARRING_SECTORS`, `BULK_EMIT`, `STAGE_REEMIT`, `PREWARM_DESCENT`, …)
+ `FP_SHELL_SECTOR_FINE` + `FP_FARRING_EMIT_ACCUM` + `FP_SV2_SHELL_YIELD`.

Success criteria:
1. **NO descent frame > ~150–200 ms** from engage (alt ~1300) through landing — vs the current
   284–1041 ms per-slice hitches. (Primary; "absolutely smooth" — low fps OK.)
2. `sh_stage_emit` **≤ 40** on every staged dispatch (vs 130–144).
3. `_async_build_us` per slice bounded ≈ proportionally (attributes P2's convoy reduction:
   compare ms/facet vs the 2.2–7.2 baseline).
4. No visual seam/crack/hole at any point of the descent (sector borders, staged-run coherence),
   including the knee release.
5. `smooth_v2_commit_ms` spikes never coincide with a staged-slice frame (P3).
6. Steady orbit and on-foot behaviour unchanged (axis-drift re-emits still small/sector-bounded;
   idle frame profile identical).
7. Heap peak within the NEVER-OOM ceiling (expected: unchanged resident, LOWER transient).

Fallback ladder if the A/B shows residual >200 ms frames: (a) confirm via `_async_build_us`
whether the slice build or something else owns the frame; (b) if slice-owned and P2 landed, drop
`SHELL_STAGE_FACETS_FINE` 40 → 36 has no effect (atom-bound) — instead raise
`SHELL_SECTOR_SPLIT_FINE` 4 → 6 (half = 4, ≤ 16 fids/sector, 216 sectors, ~+96 draws) — the
same consts, no new code; (c) if normals-hash-bound, revive the skip-`generate_normals` audit
(§2).
