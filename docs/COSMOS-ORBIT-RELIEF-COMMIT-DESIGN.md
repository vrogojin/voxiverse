# COSMOS — Orbit-Relief Incremental Commit (FP_OR_COMMIT_PARTIAL)

**Problem** (measured, definitively attributed): the surface-entry (alt 256) up-crossing carries a
~111 ms one-time main-thread burst, pinned by the `wf_or_*_us` sub-timing decomposition (commit
361377d) to exactly one term: `wf_or_commit_us = 111,220 µs` — the entire cost is
`FacetOrbitRelief._commit()` (`godot/src/world/facet_orbit_relief.gd:918`). Scan / height / col /
tex / dispatch / reap are all ~0. Two prior fixes (FP_OR_FLIP_STAGE, FP_OR_WORKER_DECODE) targeted
those ~0 terms and each shaved ~0.

**Root cause**: `_commit()` maintains a fixed-size CPU-side slot arena (384 slots × 1089 verts) and
per commit writes only O(≤`ORBIT_RELIEF_COMMIT_TILES`=24 ×5) slots — but then rebuilds and re-uploads
the **whole** arena every time:

```gdscript
var m := ArrayMesh.new()
m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)  # arr = the ENTIRE 384-slot arena
_mi.mesh = m
```

`add_surface_from_arrays` packs 418,176 verts + 2.36 M indices into fresh interleaved buffers
(~22.8 MB packed) and the assign re-uploads all of it — O(MAX_TILES) per commit regardless of how
few slots changed. On the cold ascent the arena fills across several 500 ms-spaced commits, each
paying the full ~111 ms.

**Verdict: approach (1) — partial GPU update via `RenderingServer` region updates — is feasible on
gl_compatibility/WebGL2 and is the chosen design.** Per-commit cost becomes O(changed slots): the
~111 ms burst drops to a few ms typical, ~20-35 ms at the densest 24-tile fill commit, and the
one-time full allocation moves to boot (behind the splash). Approaches (2) and (3) are rejected
below.

---

## 1. Where the 111 ms actually goes (the CPU-pack vs GPU-upload split)

The measured wrap is around the GDScript `_commit()` call, i.e. around `add_surface_from_arrays` +
the `_mi.mesh =` assign. On the threaded web export the actual `glBufferData` executes on the render
side of the command queue, so the measured 111 ms is dominated by the **CPU half**:

1. `mesh_create_surface_data_from_arrays` interleave/quantize of 418k verts (scalar C++ ×WASM):
   pos 12 B copy + color float→RGBA8 quantize + uv/uv2 copies per vertex;
2. **~22.8 MB of fresh allocations per commit** in WASM dlmalloc — the exact allocator-convoy class
   this project has root-caused twice already (walk-perf, gen-convoy);
3. the AABB scan over 418k positions;
4. the 9.4 MB 32-bit index-buffer copy.

The GPU half (a 22.8 MB `glBufferData` on WebGL2) is real but secondary and lands off the measured
wrap. **This split matters for the design choice**: off-threading the pack (approach 3) would only
move term (1), leaving the 22.8 MB/commit allocation churn, the upload, and the double-buffered
transient (old mesh + new mesh) in place. The partial update removes **all four** terms at once —
no per-commit pack, no per-commit 22.8 MB alloc, no full upload, no AABB scan, no mesh churn.

## 2. Chosen design — persistent surface + per-slot region updates

New flag `FP_OR_COMMIT_PARTIAL := false` in `godot/src/cosmos/cube_sphere.gd` (CS_FLAGS family,
deploy_cheats-toggleable). OFF ⇒ every touched function keeps its verbatim body (byte-off, FLAT
6042/0). All of the following is under the flag.

### 2.1 The Godot 4.4 API and gl_compat/WebGL2 feasibility

Godot 4.4's `RenderingServer` exposes:

- `mesh_surface_update_vertex_region(mesh: RID, surface: int, offset: int, data: PackedByteArray)`
- `mesh_surface_update_attribute_region(mesh: RID, surface: int, offset: int, data: PackedByteArray)`
- `mesh_surface_get_format_vertex_stride(format, vertex_count)` /
  `..._attribute_stride(...)` / `..._offset(format, vertex_count, array_index)` — the stride/offset
  oracles, so we never hardcode layout.

The gl_compatibility (GLES3) backend implements both region updates as
`glBindBuffer` + `glBufferSubData` (`drivers/gles3/storage/mesh_storage.cpp`), and `glBufferSubData`
is core WebGL2. In Godot 4's mesh format the surface is split into exactly the two buffers the two
calls address: the **vertex buffer** (positions — and only positions here: WS3 ships no normals, so
stride = 12 B) and the **attribute buffer** (COLOR as RGBA8 u8×4 + UV f32×2 + UV2 f32×2 ⇒ stride =
4+8+8 = 20 B). Feasibility is therefore **yes**, with one gap and one obligation:

- **Gap: there is no `mesh_surface_update_index_region`.** Handled by making the index buffer
  *static* (§2.3) — it never needs updating again after creation.
- **Obligation: a persistent surface's AABB does not track region updates.** Handled by a one-time
  conservative `custom_aabb` (§2.5).

Because layout assumptions must never be trusted silently on an exotic driver, §2.7 adds a boot-time
self-check with a graceful fallback to the verbatim path.

### 2.2 One-time full allocation at setup (boot, behind the splash)

In `setup_instance()` (after `_ensure_arena()`), under the flag:

1. Fill `_arena_idx` with the **static** per-slot grid pattern for *all 384 slots*:
   `_grid_indices(...)` + `slot * VERTS_PER_TILE` per slot (deterministic, fid-independent — it is
   byte-for-byte what `build_tile` bakes for whatever tile later lands in that slot).
2. One verbatim `add_surface_from_arrays` of the (all-zero-vertex) arena into the persistent
   `ArrayMesh` already assigned to `_mi.mesh`. This is the **only** full-arena pack the tier ever
   performs, and it runs at world boot — inside the branded splash's bake/prewarm window, never on
   the flip path. (~111 ms once, off the gameplay clock; if splash telemetry shows it, fold it into
   the existing prewarm progress.)
3. Set `custom_aabb` (§2.5), cache `_or_mesh_rid := _mi.mesh.get_rid()`, cache
   `_or_vstride/_or_astride` from the `mesh_surface_get_format_*` oracles, and run the pack
   self-check (§2.7).

The GPU cost is one 22.8 MB resident surface, allocated once. Today's path allocates the same
22.8 MB **per commit** into a *new* ArrayMesh (transiently 2× while the old mesh is still assigned),
so steady-state GPU/heap behaviour strictly improves. CPU-side, the typed arena arrays are already
allocated at full cap — no change to the NEVER-OOM ledger (`arena_bytes()` unchanged; add the two
packed mirrors of §2.4, +13.4 MB, to the ledger and doc — still far below the far-tier budget, and
it *removes* the recurring 22.8 MB/commit transient).

### 2.3 Static index law + vertex-collapse degeneration

With no index-region API, the index buffer must never change after creation — and it doesn't have
to:

- **Committed slot**: `tile["idx"]` (grid pattern + baked `vert_base`, worker-side) is *identical*
  to the static pattern already in the buffer. `_write_arena_slot` under the flag skips the
  6144-iteration index copy entirely (the CPU `_arena_idx` is already correct and immutable).
- **Free/evicted slot**: today `_free_arena_slot → _degenerate_slot` collapses the slot's *indices*.
  Under the flag it instead collapses the slot's *vertices*: write all 1089 `_arena_pos` entries of
  the slot to `Vector3.ZERO` and mark the slot GPU-dirty (§2.6). All the slot's triangles become
  zero-area → rasterize nothing, exactly like index-degeneration. Indices stay untouched.

### 2.4 Packed CPU mirrors — pack once per slot-write, upload as a memcpy slice

Two new flag-gated byte mirrors, allocated in `_ensure_arena`:

```gdscript
var _arena_vbytes: PackedByteArray   # cap × 1089 × 12  (5.0 MB)  — positions, f32×3
var _arena_abytes: PackedByteArray   # cap × 1089 × 20  (8.4 MB)  — RGBA8 color + f32 uv + f32 uv2, interleaved
```

`_write_arena_slot` (flag ON) writes the slot's data into the typed arrays **as today** (they remain
the canonical state the gates and any reader compare against) *and* packs the same 1089 verts into
the mirrors in the same loop — positions and uv/uv2 are verbatim little-endian f32 (no quantization
risk), color is quantized float→u8 with the **exact formula from
`RenderingServer::mesh_create_surface_data_from_arrays`'s ARRAY_COLOR case in the pinned 4.4.1
source** (copy it verbatim at implementation time; §2.7/§4 verify byte-equality rather than trusting
it). `_degenerate_slot` (flag ON) zeroes the slot's `_arena_pos` region and its `_arena_vbytes`
region.

A region upload is then `PackedByteArray.slice(off, off + len)` — a memcpy, zero per-vertex work at
commit beyond what `_write_arena_slot` already does.

Per-slot regions (asserted against the stride oracles at setup, never assumed):

| buffer | offset | size |
|---|---|---|
| vertex   | `slot × 1089 × 12` = `slot × 13,068` | 13,068 B |
| attribute| `slot × 1089 × 20` = `slot × 21,780` | 21,780 B |

### 2.5 AABB

The all-degenerate initial surface would auto-compute a point AABB at the origin — region updates
never recompute it, so tiles would be **culled invisibly**. Fix: at setup, set
`_mi.mesh.custom_aabb` once to the conservative constant enclosing the origin and the whole shell —
centre `-(R)…(R)` per axis with `R = max facet r_datum + max relief` (derivable from
`FacetAtlas`/`FacetFarRing.RELIEF` bounds; origin is inside it, matching the full-rebuild AABB which
always includes the zeroed free-slot verts anyway). Culling becomes identical-or-more-conservative
⇒ rendered output unchanged (this mesh is planet-scale and effectively never fully culled from
orbit regardless).

### 2.6 The changed-slot set and the `_commit()` rewrite

The changed-slot set is **exactly the union the code already computes**, plus degenerations:

- `to_write` = newly-admitted tiles ∪ their already-committed seam neighbours whose
  `edge_sink_mask` may have flipped (`_commit` :934-940 — the WS4 correctness requirement is
  preserved verbatim: a mask-flip rewrites that neighbour's positions via `sunk_positions`, and
  under the flag that rewrite is what makes the slot GPU-dirty);
- `_gpu_dirty_slots: Dictionary` (slot → true), new, flag-gated: populated by
  `_write_arena_slot` (every slot it writes) and `_degenerate_slot` (evictions/refusals — which can
  land while on-surface commits are suspended; the dirt persists until the next off-surface commit,
  matching today's semantics where the CPU-degenerated slot also only reaches the GPU at the next
  commit).

Rewritten tail of `_commit()` (steps (1)–(3) — eviction sync, admission, `edge_sink_mask` recompute,
`_write_arena_slot` loop — are **unchanged**):

```gdscript
    # ... steps (1)-(3) verbatim: _committed_tiles sync, newly_added admission,
    #     to_write = newly_added ∪ committed seam neighbours, per-slot _write_arena_slot ...
    if not CubeSphere.FP_OR_COMMIT_PARTIAL or not _or_partial_ok:
        # verbatim whole-arena rebuild (the byte-off path, and the §2.7 fallback)
        var arr := []; arr.resize(Mesh.ARRAY_MAX)
        arr[Mesh.ARRAY_VERTEX] = _arena_pos; arr[Mesh.ARRAY_COLOR] = _arena_col
        arr[Mesh.ARRAY_TEX_UV] = _arena_uv;  arr[Mesh.ARRAY_TEX_UV2] = _arena_uv2
        arr[Mesh.ARRAY_INDEX] = _arena_idx
        var m := ArrayMesh.new()
        m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
        _mi.mesh = m
    else:
        # O(changed slots): flush every GPU-dirty slot as two glBufferSubData-backed region updates
        for slot in _gpu_dirty_slots.keys():
            var s := int(slot)
            var voff := s * VERTS_PER_TILE * _or_vstride
            var aoff := s * VERTS_PER_TILE * _or_astride
            RenderingServer.mesh_surface_update_vertex_region(
                _or_mesh_rid, 0, voff, _arena_vbytes.slice(voff, voff + VERTS_PER_TILE * _or_vstride))
            RenderingServer.mesh_surface_update_attribute_region(
                _or_mesh_rid, 0, aoff, _arena_abytes.slice(aoff, aoff + VERTS_PER_TILE * _or_astride))
        _gpu_dirty_slots.clear()
    _commit_dirty = _committed_tiles.size() != _tiles.size()
```

All RenderingServer calls stay on `_commit()`'s thread — main — same as today's mesh assign (they
are queued to the render side identically). Workers still only produce tile dicts; the single-writer
discipline is untouched.

First-ever commit needs no special case: the persistent surface already exists from setup, so the
very first commit is already incremental.

### 2.7 Boot self-check + graceful fallback (`_or_partial_ok`)

At setup (flag ON), pack one synthetic slot's worth of data by hand (§2.4), build a scratch
1089-vert `ArrayMesh` from the same typed arrays via `add_surface_from_arrays`, read back
`RenderingServer.mesh_get_surface(scratch_rid, 0)` and byte-compare its `vertex_data` /
`attribute_data` against the hand-pack; also assert `_or_vstride == 12`, `_or_astride == 20` and the
attribute offsets against `mesh_surface_get_format_offset`. Any mismatch (a future engine bump
changing the packed format, an unexpected driver) ⇒ `_or_partial_ok = false`, log once, and every
commit takes the verbatim full-rebuild branch — behaviour degrades to today's, never to corruption.

## 3. Byte-identical-render argument

- **Committed slots**: the typed CPU arena (`_arena_pos/col/uv/uv2`) is written by the *unchanged*
  steps (1)–(3) — same admission order, same `edge_sink_mask` law, same `sunk_positions` — so its
  contents are byte-identical to the OFF path's at every commit boundary. The uploaded region bytes
  are that data through the same packing law the full path uses (verified §2.7/§4), at the same
  vertex offsets (`vert_base = slot × VERTS_PER_TILE`, baked worker-side, unchanged). Index data for
  a committed slot is the static grid pattern — byte-identical to `tile["idx"]`.
- **Free slots**: the two paths differ in *representation* (OFF: degenerate indices + stale
  positions; ON: real indices + all-vertices-collapsed-to-origin) but both are zero-area triangle
  soup that rasterizes no fragment on any conformant GL — rendered-identical. (The material casts no
  shadows and gl_compat runs no depth prepass that zero-area geometry could touch.)
- **AABB/culling**: §2.5 — conservative superset, render-identical.
- **Commit cadence and admission**: `should_commit`, `ORBIT_RELIEF_COMMIT_MS/_TILES`, WS1a suspend,
  WS4 self-heal sequencing all untouched — the same tiles become visible on the same frames.

## 4. Gate plan (`verify_orbit_relief.gd` additions)

- **G-OR-PART-PACK** — the §2.7 check as a headless gate (dummy rasterizer retains `SurfaceData`, so
  `mesh_get_surface` readback works): hand-pack of a synthetic slot (non-trivial colors exercising
  the u8 quantization, incl. exact-0.5×255 boundaries) byte-equals Godot's own
  `add_surface_from_arrays` packing; stride/offset oracles agree with the §2.4 table. Falsifier:
  perturb one packed byte ⇒ compare fails at that byte only.
- **G-OR-PART-EQ** — drive one scripted commit *sequence* (commit A alone → commit B adjacent, the
  existing G-OR-SEAM choreography, plus an eviction and a re-admission) through two instances: arm
  OFF (verbatim rebuild) and arm ON. After every commit boundary, for **every committed fid**,
  assert (a) the typed arena slot regions are byte-equal across arms, and (b) arm ON's
  mirror-derived region bytes equal arm OFF's `mesh_get_surface` `vertex_data`/`attribute_data` at
  the same slot offsets (a pure byte compare, independent of whether the dummy backend applies
  region updates). Assert ON's static `_arena_idx` at each committed slot equals OFF's.
- **G-OR-PART-DEGEN** — after eviction under ON: the slot's mirror position region is all-zero
  (collapsed) and the slot is in no committed fid's mapping; assert every triangle of the slot is
  zero-area.
- **G-OR-COMMIT-COST extension** — under ON, one `_commit()` performs region updates for
  ≤ `|to_write ∪ dirty|` slots and *never* calls `add_surface_from_arrays` (source-token falsifier,
  mirroring the existing merge_tiles token check).
- **FLAT 6042/0** — flag default-off; every touched function's OFF body verbatim.
- Live A/B via the deploy_cheats pipeline: expect `wf_or_commit_us` 111 k → single-digit-thousands
  µs typical; flip worst-frame ~185 ms → well under 100 ms.

## 5. Rejected alternatives

- **(2) Grow-the-arena / size-to-committed-count**: resizing re-bases every slot above the change
  point, invalidating the worker-baked `vert_base` contract — either committed tiles' baked indices
  go stale (corruption) or every commit re-remaps indices O(committed), which is precisely the
  O(resident-set) work WS1b was built to eliminate. It also only cheapens *early* commits; the
  steady-state 384-tile commits (axis drift, sink-mask heals) stay ~111 ms. Strictly dominated by (1).
- **(3) Off-thread the ArrayMesh build**: building the ArrayMesh on a worker is technically legal
  (server resources may be created off-thread) but only moves the pack term; the 22.8 MB/commit
  dlmalloc churn (a known convoy driver on this heap), the full 22.8 MB GPU re-upload, and the
  2×22.8 MB transient all remain, plus a new cross-thread mesh-lifetime hazard. Keep as a fallback
  only if (1)'s API were unavailable — it isn't.

## 6. Expected outcome

| term | today | with FP_OR_COMMIT_PARTIAL |
|---|---|---|
| per-commit CPU pack + alloc | ~22.8 MB, O(384 tiles), ~111 ms | 0 (mirrors pre-packed at slot-write) |
| per-commit GPU upload | 22.8 MB `glBufferData` | ≤ ~35 KB × changed slots (`glBufferSubData`) |
| densest fill commit (24 new + neighbours, ~60–120 slots) | ~111 ms | ~2–4 MB upload + slice/RS-call overhead ⇒ ~est. 20–35 ms; typical commits low-single-digit ms |
| one-time cost | ~111 ms × every fill commit | ~111 ms once, at boot behind the splash |
| flip worst frame | ~185 ms | well under 100 ms (commit term removed from the flip) |

Follow-up tunable (byte-off, only meaningful once partial commits are cheap): drop
`ORBIT_RELIEF_COMMIT_TILES` 24→8 and `ORBIT_RELIEF_COMMIT_MS` 500→150 under the flag family — same
fill rate, ~⅓ the worst per-commit burst, smoother cold ascent.
