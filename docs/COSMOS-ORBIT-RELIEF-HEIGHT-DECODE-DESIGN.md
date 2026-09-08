# COSMOS — Orbit-relief height decode off-thread (`FP_OR_WORKER_DECODE`)

**Verdict up front: the proposed main-thread raw-byte slice + worker decode is SAFE and
CORRECT.** The thread-safety argument is stronger than hoped — `bake_facet` runs
exclusively on the **main thread**, so the slice and the bake are strictly serialized and a
torn read is *impossible*, not merely unlikely. One genuine correctness subtlety was found
(the not-set-up/empty corner, §3.2) which a naive implementation would get wrong; the design
below bakes the fix in. `FP_OR_FLIP_STAGE` stays — the two flags remove *disjoint* terms of
the flip peak and compose (§6).

Problem (measured, root-caused upstream): the surface-entry up-crossing's residual ~100 ms
one-time burst is the dispatch loop at `facet_orbit_relief.gd:794` calling
`_relief_data.height_grid(f)` — 1089 main-thread `decode_s16` reads (~33 ms/facet WASM,
cache-cold) — per wanted facet, before each `WorkerThreadPool` tile build. Up to
`OR_FLIP_DISPATCH_MAX`(3) cache-miss snapshots land on the flip frame ⇒ ~100 ms, matching
the live measurement (~99–107 ms; `FP_OR_FLIP_STAGE` alone left it unchanged because it
staged the *scan* term, not this decode term).

## 1. The change (exact hand-off)

Move the decode into the worker; the main thread hands over a raw-byte snapshot instead of
a decoded grid.

**`global_relief_data.gd` — two additions:**

```gdscript
## FP_OR_WORKER_DECODE: the raw i16 byte snapshot of one facet's height region — the CHEAP
## (one ~2178-byte memcpy) main-thread twin of height_grid(); the worker decodes it via
## decode_height_bytes(). MUST be called on the MAIN THREAD (same contract as height_grid:
## _heights is live-written by bake_facet — also main-thread — so a main-thread slice is a
## strictly serialized, torn-free value copy). Empty ⇒ not ready / out of range — the
## decoder degrades that to the SAME all-zero grid height_grid() returns.
func height_bytes(fid: int) -> PackedByteArray:
    if _heights.is_empty() or fid < 0 or fid >= _baked.size():
        return PackedByteArray()
    return _heights.slice(fid * NODES_PER_FACET * 2, (fid + 1) * NODES_PER_FACET * 2)

## PURE + STATIC (worker-safe: reads only its argument, no instance state). Decodes a
## height_bytes() snapshot into the byte-identical grid height_grid() produces. ANY wrong
## size (in particular the empty not-set-up/out-of-range degrade above) ⇒ 1089 zeros —
## exactly height_at()'s guard default, so build_tile still builds the same flat tile the
## status quo builds instead of refusing ({}).
static func decode_height_bytes(raw: PackedByteArray) -> PackedInt32Array:
    var out := PackedInt32Array()
    out.resize(NODES_PER_FACET)          # zero-filled
    if raw.size() == NODES_PER_FACET * 2:
        for k in range(NODES_PER_FACET):
            out[k] = raw.decode_s16(k * 2)
    return out
```

**`facet_orbit_relief.gd` — dispatch loop (`step()`, around :794) + a new worker entry:**

```gdscript
if CubeSphere.FP_OR_WORKER_DECODE:
    var raw := _relief_data.height_bytes(f)          # main-thread ~2178-B memcpy snapshot
    _s_fid[slot] = f
    _s_task[slot] = WorkerThreadPool.add_task(Callable(self, "_build_worker_raw").bind(
        slot, f, raw, coarse_col, vert_base, int(tex[0]), int(tex[1]), int(tex[2]), int(tex[3])), true, "orbitrelieftile")
else:
    var heights := _relief_data.height_grid(f)       # VERBATIM shipped path
    _s_fid[slot] = f
    _s_task[slot] = WorkerThreadPool.add_task(Callable(self, "_build_worker").bind(
        slot, f, heights, coarse_col, vert_base, int(tex[0]), int(tex[1]), int(tex[2]), int(tex[3])), true, "orbitrelieftile")
```

```gdscript
## FP_OR_WORKER_DECODE worker entry: identical to _build_worker except the 1089-node s16
## decode runs HERE (off main) on its own private byte snapshot. Touches ONLY its bound
## value args + the static pure decoder — NEVER _relief_data (single-writer discipline
## unchanged; writes only _s_result[slot] under the mutex).
func _build_worker_raw(slot: int, fid: int, raw: PackedByteArray, coarse_col: PackedColorArray, vert_base: int, face: int, a: int, b: int, k: int) -> void:
    var tile := build_tile(fid, GlobalReliefData.decode_height_bytes(raw), coarse_col, vert_base, face, a, b, k)
    _s_mutex.lock()
    _s_result[slot] = tile
    _s_mutex.unlock()
```

Nothing else moves: want-set, admission, refusal, arena slots, reap, sink, commit — all
untouched. Only *where* the 1089 decodes execute changes.

Update the stale contract comments to match: `global_relief_data.gd:122-132` (height_grid's
"MUST be main-thread, decoded before dispatch" — still true for height_grid itself, but no
longer the only safe hand-off) and `facet_orbit_relief.gd:14-19` (the class-doc §0
thread-safety note: add "…or a raw `height_bytes` snapshot decoded worker-side by the pure
static `decode_height_bytes` (FP_OR_WORKER_DECODE)").

## 2. Thread-safety (the crux): `bake_facet` is main-thread-only — proven, not assumed

**Where `bake_facet` runs.** Its only live callers are `GlobalReliefData.step()`
(`global_relief_data.gd:355`) and `_step_deferred` (`:377`), and `step()`'s only live call
site is `WorldManager.update_streaming` (`world_manager.gd:1598`, inside
`update_streaming` at `:1394`). `update_streaming` is called from
`player/player.gd:921`/`:2677` (the Player's process/physics tick — main thread) and from
headless verify/soak tools (single-threaded SceneTree scripts). `global_relief_data.gd`
contains **no** `WorkerThreadPool`/`Thread` usage at all, and its own class doc (`:39-41`)
pins the design: the G2 pacer bakes *synchronously on main* under the frame-budget gate.
The dispatch loop likewise runs on main: `FacetOrbitRelief.step()` ←
`FacetFarRing._process` (`facet_far_ring.gd:1545` → `:1586`/`:1589`).

**Consequence.** Slice and bake execute on the *same* thread — strictly serialized. A torn
read of facet F's region (or any region) is impossible: at the moment `height_bytes(f)`
runs, no `bake_facet` is in progress anywhere. The team-lead's framing is confirmed and
strengthened: the current code *already* reads `_heights` on the main thread
(`height_grid`'s `decode_s16` loop via `height_at`, `global_relief_data.gd:119`/`:141`),
so the slice is not merely "no less safe" — both are trivially race-free main-thread reads
of main-thread-written data.

**The snapshot contract holds for the raw slice exactly as for the decoded grid.**
`PackedByteArray.slice()` allocates a *fresh* buffer and copies the range (established
codebase precedent: `facet_atlas.gd:607` does the identical per-fid slice hand-off) — no
aliasing with `_heights` afterwards, so later `bake_facet` writes to *other* facets can
never reach the worker's copy. `Callable.bind` stores the array by Godot's thread-safe
(atomic-refcount) CoW; both sides are read-only after the bind — the *identical* mechanism
the shipped `PackedInt32Array` hand-off already relies on. Both are main-thread-produced
value-type snapshots; neither can observe a mid-write state.

**Worker audit.** `_build_worker` (`facet_orbit_relief.gd:834-838`) → `build_tile` (`:227`)
touches only bound value args, write-once `FacetAtlas` statics, and constants
(`TerrainConfig.SEA_LEVEL`, `FacetFarRing.CELLS`/`RELIEF`) — never `_relief_data` or
`_heights`. `_build_worker_raw` upholds the same by construction: `decode_height_bytes` is
`static` and reads only its argument. Gate G-OR-WDEC-4 (§7) pins this structurally.

**Invariant to pin forward.** The whole argument rests on "`bake_facet` never moves off
main". That is currently doc'd (`global_relief_data.gd:39-41`) and now also *gated*: the
G-OR-WDEC source scan asserts `global_relief_data.gd` contains no `WorkerThreadPool` token
(§7 item 4). If a future change ever moves G2 baking to a worker, both this slice AND the
shipped `height_grid` decode become racy together — the gate makes that change trip loudly
instead of silently.

**Pre-existing side finding (out of scope — report, don't fix here).** The far-ring env
async worker `_async_build_worker` (`facet_far_ring.gd:2801`) → `_env_build_one` (`:2752`)
→ `_ensure_cached` (`:4093`) can, on its PLANAR branch only (reached when both
`env_on` is false and `FP_SHELL_WELD` is false), read `_relief_shade.is_baked`/`shade_at`
(`:4127`/`:4158`) and even *write* `_relief_shade.request(fid)` (a Dictionary `_want`
mutation, `global_relief_data.gd:279`) from a worker — while main-thread
`bake_facet`/`_next_wanted` mutate `_shade`/`_baked`/`_want`. Under served flag combos
(weld/env on) the planar branch appears unreachable from the worker, but it is the one
place the "workers never touch GlobalReliefData" contract is textually violated today.
Worth its own small follow-up (e.g. hoist the shade reads to a main-thread snapshot like
everything else in that worker); nothing in *this* design touches or worsens it.

## 3. Correctness: byte-identical decode

### 3.1 The main case
For any in-range `fid` with `_heights` non-empty:
`height_bytes(fid)` copies bytes `[fid·1089·2, (fid+1)·1089·2)` verbatim. For
`k = j·NODES_PER_EDGE + i`:

```
raw.decode_s16(k*2) == _heights.decode_s16((fid*NODES_PER_FACET + k)*2) == height_at(fid, i, j)
```

Same bytes, same offsets modulo the slice base, same `decode_s16` API (little-endian signed
16-bit — Godot's `encode_s16`/`decode_s16` pair is the codec on *both* paths, `bake_facet`
`:214` writes with the same endianness it is read with, on every platform). Negative
heights round-trip identically (`decode_s16` sign-extends the same on both paths). There is
**no** endianness or offset subtlety in the main case. Dispatch fids come from
`_want_order` ⊆ `[0, facet_count)` (`want_set` filters to real atlas fids), so
`height_at`'s bound guards never fire differently between the two paths there.

### 3.2 THE subtlety: the empty/not-set-up corner (naive slice gets this WRONG)
If `_heights` is empty (`FP_GLOBAL_RELIEF_DATA` off while `FP_ORBIT_RELIEF` on, or setup
not yet run — `FacetOrbitRelief.step()` guards only `_relief_data == null`, not
`is_ready()`), the shipped `height_grid` returns a **correct-size 1089-zero grid** (via
`height_at`'s empty-guard, `global_relief_data.gd:117-118`) and `build_tile` builds a flat
tile at datum. A naive `_heights.slice(...)` returns an **empty** array; decoding it
naively yields a wrong-size grid and `build_tile` **refuses** (`{}`, `:231-232`) — a real
behavioral divergence (no tile vs flat tile). `decode_height_bytes`'s wrong-size ⇒
1089-zeros degrade (§1) restores exact equivalence. Gate G-OR-WDEC-2 pins it.

### 3.3 Un-baked facets — no partial states exist (Q4)
Un-baked facet bytes are zero-filled at `setup()` (`:85`) and `bake_facet` writes all 1089
nodes then flips `_baked[fid]` in one synchronous main-thread call (`:212-221`). Since bake
and slice are serialized on one thread (§2), a snapshot only ever observes **all-zeros or
fully-baked — never partial**. Same-frame ordering (bake of F before vs after the dispatch
loop) just selects which consistent state is captured — exactly as with `height_grid`
today. **Do not gate dispatch on `is_baked`**: the status quo deliberately builds a flat
coverage tile for un-baked facets (silhouette coverage, never a hole); gating would defer
coverage and change behavior — keep verbatim. (Known pre-existing quirk, unchanged by this
design: a tile built pre-bake persists flat — there is no G3 rebuild on late bake;
`relief_baked` feeds only the shell colour cache, `facet_far_ring.gd:6498`. `height_grid`'s
"uncached until baked" WS1d note anticipates a re-call that the `_tiles.has(f)` dispatch
skip mostly prevents. Same before and after this change.)

## 4. The WS1d cache (Q3)

`height_grid` callers: the dispatch (`facet_orbit_relief.gd:794`) and
`tools/verify_orbit_relief.gd` only (plus nothing else in live code). With the flag ON the
`_height_grid_cache` is therefore **dead on the hot path** — and that is fine:

- **No warm-ascent regression**: the slice is a ~2178-byte memcpy (~µs) — cheaper than even
  a cache *hit*'s Dictionary lookup + CoW-share is meaningful about; and tiles persist in
  `_tiles` across the on-surface freeze anyway ("warm for next ascent", WS1a), so a 2nd
  ascent barely re-dispatches at all.
- **Small bonus**: the cache never grows under the flag (up to 384 × 1089 × 4 B ≈ 1.7 MB
  avoided).
- **Leave `height_grid` + cache untouched**: the OFF arm uses them verbatim (byte-off), and
  the gates use `height_grid` as the equivalence oracle.
- The worker must **not** seed the cache (a worker-side Dictionary write into
  `_relief_data` would be exactly the race this whole file's discipline forbids). It
  doesn't — `decode_height_bytes` is static/pure.

## 5. Convergence / no-hole

Unchanged by construction: admission (`_tiles.has`/`_inflight`/slot checks), refusal
handling (reap frees slot on `{}`), arena, dwell-eviction, commit rate-cap — all verbatim.
The flag changes only which Callable is bound and where 1089 integers get decoded. A
refusal under the flag can occur in exactly the same cases as before (§3.2 makes the
empty-corner behavior identical rather than introducing a new refusal class).

## 6. Flag structure — keep `FP_OR_FLIP_STAGE` (Q5)

The flip peak has (at least) two independent terms; the flags attack them disjointly:

| Term | Size (WASM) | Removed by |
|---|---|---|
| `height_grid` cache-miss decodes at dispatch (≤ `OR_FLIP_DISPATCH_MAX`=3 × ~33 ms) | ~100 ms | **FP_OR_WORKER_DECODE** (this design) |
| `_recompute_want` full-planet scan+sort on the up-crossing | ~15–35 ms | **FP_OR_FLIP_STAGE** (shipped, measured-neutral only because the decode term dominated) |

Recommendation: **keep both, as independent flags, both default false; the served arm turns
both ON.** After WORKER_DECODE removes the decode term, FLIP_STAGE's scan amortization is
exactly what caps the residual. `OR_FLIP_DISPATCH_MAX` becomes nearly moot (snapshots are
now ~µs) but stays harmless — it still bounds per-step `add_task` + `col_cache` duplication
churn. Do not fold the flags together: separate A/B attribution is the whole point of this
pipeline, and FLIP_STAGE is already live-tested.

`FP_OR_WORKER_DECODE := false` lives in `cube_sphere.gd` adjacent to the
`FP_OR_FLIP_STAGE` block (`:1093+`), same doc-comment discipline; `deploy_cheats.sh`'s
CS_FLAGS sed picks it up like every other flag. GDScript-only — no engine rebuild.

Expected: main-thread dispatch cost/tile 33 ms → ~0.05–0.3 ms; flip peak ~185 →
~110 ms (scan/commit residual), with FLIP_STAGE shaving the scan term on top.

## 7. Byte-off + gates (Q6)

OFF ⇒ the `else` branch is the shipped `:794-800` lines **verbatim** (textually separate
branch, the codebase's standard byte-off discipline); `height_bytes`/`decode_height_bytes`/
`_build_worker_raw` are dead code. FLAT `verify_feature.gd` 6042/0 unchanged.

`verify_orbit_relief.gd` — new gate **G-OR-WDEC** (self-describing convention, mirrors
G-OR-LIGHT's static source checks):

1. **Round-trip equality** — for a real *baked* fid:
   `GlobalReliefData.decode_height_bytes(rd.height_bytes(fid)) == rd.height_grid(fid)`
   at all 1089 nodes (and each equals `height_at(fid, i, j)`). *Falsifier*: perturb one
   byte of the snapshot ⇒ divergence at exactly that node, nowhere else.
2. **Degrade equality** — (a) an *un-baked* fid: both paths all-zero; (b) a fresh
   `GlobalReliefData.new()` (no `setup()`): `height_bytes` is empty and
   `decode_height_bytes` of it == `height_grid` (1089 zeros) — the §3.2 corner; (c) an
   out-of-range fid likewise.
3. **Tile equality** — `build_tile(fid, decoded, col, vb, …)` byte-equal
   (`g`/`pos`/`idx`/`uv`/`uv2`/`col`) to `build_tile(fid, rd.height_grid(fid), col, vb, …)`
   at the same `vert_base`, for a baked and an un-baked fid.
4. **No off-thread `_heights` read (structural)** — source scans:
   `_build_worker_raw`'s body contains no `_relief_data`/`height_grid` token;
   `decode_height_bytes` is declared `static`; `global_relief_data.gd` contains no
   `WorkerThreadPool` token (pins the §2 main-thread-bake invariant this design's safety
   rests on).
5. **Byte-off** — flag off: the dispatch source's else-branch is the verbatim
   `height_grid` call (token check), and FLAT `verify_feature.gd` 6042/0.

Existing G-OR-* gates (DATA-EQ/WELD/SEAM/COMMIT-COST/SUSPEND) run unchanged and must stay
green in both flag states.
