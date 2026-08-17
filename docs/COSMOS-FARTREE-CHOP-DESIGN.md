# COSMOS FARTREE-CHOP — chopped NEAR tree still FAR-renders in the fine-map skin (task #137)

**Flag: `FP_FT_SKIN_CHOP` (byte-off). DESIGN ONLY — no code in this commit.**

Status: designed 2026-08-15 (Fable). Companion to docs/COSMOS-FAR-TREES-DESIGN.md (the 3-rung
ladder) and docs/COSMOS-CPP-PARALLEL-SAMPLER-DESIGN.md (patch 0011, `bake_far_tile`).

---

## §1 Verified root cause — with one correction to the brief

The far-tree ladder's rungs 1 (voxel meshes) and 2 (cross/cap cards) ARE chop-filtered and are
NOT the leak:

- `facet_far_trees.gd:753` `_is_chopped(fid,bx,gy,bz)` → `_chop_query.call(fid, Vector3i(bx, gy+1, bz))`
  — "is the trunk-base cell edited". Applied as a `continue`-skip at the card rebuild (:1183) and
  the mesh rebuild (:1299).
- Fed by `world_manager.gd:3673` `far_tree_chopped(fid, cell)` = `_edits.has(FacetAtlas.edit_key(fid, cell))`
  (guarded `_chart == null` — holds in the served FLAT+FACETED build); wired at `world_manager.gd:447`
  (`set_far_trees_chop_query`) and re-armed by the edit revision: `facet_far_trees.gd:1069/:1076`
  compare `_current_edits_rev()` (= `WorldManager.edit_count()`, `world_manager.gd:657`, wired :451)
  against `_last_rebuild_edits_rev`, so a chop triggers a card/mesh rebuild that drops the tree.

**The leak is rung 3 — but the brief's file attribution needs one correction.** The brief named
`facet_skin_tier.gd` (`FacetSkinTier`) as the leaking fine-map skin. Verified against the code, it
is a **non-leaking bystander**:

- `FacetSkinTier._build_tile` (:446) samples via `sample_columns`, not `bake_far_tile` (:130
  `Callable(_sampler_obj, "sample_columns")`; the `deco_far_idx` cfg entry at :591 is consumed by
  the *generator params*, not by a skin-tier tree branch).
- `sample_columns`' colour source is `VoxelGeneratorCosmos::far_color`
  (voxel_generator_cosmos.cpp:1930-1948): under `skin_block_exact` it classifies
  `deco_far_idx[top_block_id(...)]` — `top_block_id` is the **terrain** surface block
  (grass/sand/snow/stone), it never consults `tree_top_decoration`. The GDScript oracle
  `gd_sample` (:606) likewise paints only `FarPalette.color_for`. **No sample_columns consumer
  ever paints a tree.** (Also `FP_SKIN_TIER` is not in the served set — task #60 pending.)

**The actual rung-3 skin is `facet_tex_baker.gd` (`FacetTexBaker`) — the L8 far-colour-index maps
the far-ring shaders render:**

- the **BAND map** (`FP_SKIN_FLATCOLOR`, 512²/facet, residency = active ∪ ring-1) — this is what
  underlays the cards at 96-256 blk (tier-depth: cards beat skin, so where the chopped card is
  gone the band speckle shows through), and
- the **whole-planet FINE map** (`FP_PLANET_MAP`, 128²/facet, always resident) — this owns the
  orbit view (zone O: cards+meshes hidden by `FP_FT_SHELL_BAND`, `facet_far_trees.gd:786-792`).

Both bake through `_pbm_compute` (facet_tex_baker.gd:1932), whose **three redundant compute paths
share one texel classification law — `EDIT → TREE → TERRAIN`**:

| path | site | tree branch |
|---|---|---|
| C++ whole-tile (`FP_CPP_TILE_BAKE`, the served path) | :1951-1970 → `bake_far_tile` | voxel_generator_cosmos.cpp:2264 `tree_top_decoration(p, fid, lx, lz)` → `deco_far_idx[deco]` |
| C++ chunked `sample_columns` terrain + GDScript overlay | :2003-2014 | :2009 `TreeGen.top_decoration(lx, lz, ctx)` |
| pure GDScript | :2024-2047 | :2030 `TreeGen.top_decoration(lx, lz, ctx)` |

`tree_top_decoration` / `TreeGen.top_decoration` are **purely procedural** — they re-derive the
tree from the worldgen hashes and never consult `_edits`. So a chopped tree's canopy keeps baking
LEAF/WOOD palette indices into the band and fine tiles: green speckle at the chop site from
96-256 blk (under the now-removed card) and from orbit. The single-worker band path
(`_bm_compute_slice_flat`, :1332, tree branch :1370) has the same law and the same leak.

Rounding out the audit: the base g0 pages bake `sample_columns` colours (no trees — not leaking);
the g1 SHOT pages / close-up / band-shot tiers (`SurfaceShot.surface_shot`, "block_id incl trees")
DO include trees — see scope-outs §6.

## §2 The decisive discovery: the edit override is ALREADY SHIPPED in the engine — and dead

Patch `docker/engine/patches/godot_voxel/0011-cosmos-parallel-tile-bake.patch` did not just port
the tree branch. It shipped, in the binary that serves today:

- `bake_far_tile(fid, lat_corners, nx, ny, tex, edit_cells, edit_far_idx)`
  (voxel_generator_cosmos.cpp:2208, ClassDB-bound :2515) — **two edit-snapshot parameters**;
- an `EditTable` (open-addressed, built once per call from the two arrays — :2143-2196), designed
  explicitly for "frozen main-thread snapshots at dispatch";
- the texel loop order **EDIT first** (:2255-2262): a column present in the table short-circuits
  to its supplied far index — **the tree branch never runs for it** (:2263 `if (fi < 0)`);
- byte-equality of the edit branch across C++/GDScript already gated:
  `godot/src/tools/verify_tile_bake.gd:164` (G-CPB edit case).

And on the GDScript side the consumer variable exists with an explicit IOU:
`facet_tex_baker.gd:124` `_edit_snap` — *"empty until Stage-B wires it"* — and :1959-1963:

> "DEAD PATH TODAY: `_edit_snap` has no writer in the repo (far-skin edits are Stage-B) …
> STAGE-B MUST build this snapshot at the DISPATCH sites into per-slot arrays (not iterate the
> shared Dictionary on the worker) before it wires a writer."

**The fix is therefore not an engine change. It is writing the Stage-B snapshot, scoped to
chopped trees, plus cache invalidation.** No 0011/0012 edits, no 24-minute rebuild.

## §3 Options

### Option A (per the brief): C++ edit-aware bake — REJECTED as specified
Patch `bake_far_tile`'s tree branch (+ 0011/0012) to consult a chopped-tree set. Verified moot:
the engine already applies a per-column edit override *ahead of* the tree branch (§2). A new C++
chopped-set path would duplicate `EditTable`, force an engine rebuild (~24 min, the long pole, plus
the emsdk-pin risk), stall the live A/B loop, and buy nothing — the chopped set is ≤ a few hundred
int64s per facet, trivially marshalled through the existing `edit_cells` parameter. 0012 is a
smooth-**height** bake; trees do not exist in it — untouched either way.

### Option B (per the brief): GDScript no-rebuild recolor of `FacetSkinTier._build_tile` — REJECTED
Targets the wrong subsystem: `FacetSkinTier` never paints trees (§1) and is off in the served set.
Re-aimed at the real baker, a post-hoc recolor of finished tiles would re-derive canopy footprints
per tile per re-bake forever, need its own C++/GDScript byte-equality story *outside* the one
classification law (breaking the G-CPB construction "all three paths compute the same bytes"), and
still need the same cache invalidation. Strictly dominated.

### Option A′ (RECOMMENDED): feed the shipped edit override — the Stage-B writer, chop-scoped
Build, per baked facet, the snapshot `{column (lx,lz) → post-chop top block id}` covering exactly
the chopped trees' canopy footprints; hand it to all three compute paths through the interfaces
they already have; invalidate the affected facet's band+fine tiles on the chop so they re-bake.
GDScript-only, byte-off by construction, ~1 day of work, live-A/B-able the same day.

## §4 Design — `FP_FT_SKIN_CHOP`

### §4.1 Flag
`godot/src/cosmos/cube_sphere.gd` (near `FP_CPP_TILE_BAKE`, :706):
```gdscript
const FP_FT_SKIN_CHOP := false   # task #137: chopped trees recolored out of the band/fine far-skin maps
```
Add to the deploy flag-flip set alongside `FP_SKIN_FLATCOLOR`/`FP_PLANET_MAP`/`FP_CPP_TILE_BAKE`
(the export-time flip lives outside the repo — same list the served flags come from).

### §4.2 WorldManager: the chop snapshot builder (the ONE source of truth)
New, next to `far_tree_chopped` (world_manager.gd:3673):

```gdscript
## FP_FT_SKIN_CHOP (task #137): the far-skin edit snapshot for facet `fid` —
## {Vector2i(lx,lz) -> post-chop TOP BLOCK id} covering every column whose procedural tree is
## chopped (trunk-base cell edited — EXACTLY far_tree_chopped's predicate, so rung 3 agrees with
## rungs 1/2 by construction). Memoized per (fid, edit_count()); {} when the flag is off, the
## overlay is empty, or nothing on `fid` is chopped.
var _skin_chop_memo := {}   # fid -> {rev:int, snap:Dictionary}

func far_skin_edit_snap(fid: int) -> Dictionary:
    if not CubeSphere.FP_FT_SKIN_CHOP or _edits.is_empty() or _chart != null or not CubeSphere.FACETED:
        return {}
    var rev := edit_count()
    var memo: Dictionary = _skin_chop_memo.get(fid, {})
    if not memo.is_empty() and int(memo["rev"]) == rev:
        return memo["snap"]
    var snap := {}
    var ctx := TerrainConfig.GenCtx.new(0, fid)
    var seen := {}                                    # gcell key -> true
    for ek in edits_for_fid(fid).keys():              # R5 per-fid index — O(this facet's edits)
        var cell: Vector3i = FacetAtlas.edit_key_unpack(int(ek))[1]     # facet_atlas.gd:176
        var gx := floori(float(cell.x) / float(TreeGen.G))
        var gz := floori(float(cell.z) / float(TreeGen.G))
        var gk := gx * 1000003 + gz
        if seen.has(gk):
            continue
        seen[gk] = true
        var info := TreeGen.tree_info(gx, gz, ctx)
        if info.is_empty():
            continue
        var base: Vector3i = info["base"]
        if not _edits.has(FacetAtlas.edit_key(fid, Vector3i(base.x, base.y + 1, base.z))):
            continue                                  # not chopped (same cell as _is_chopped :756)
        # Chopped: every column this tree paints (columns only ever carry their OWN gcell's tree —
        # tree_block_at homes on the column's grid cell, so the footprint is gcell-local and exact).
        for lx in range(gx * TreeGen.G, (gx + 1) * TreeGen.G):
            for lz in range(gz * TreeGen.G, (gz + 1) * TreeGen.G):
                if TreeGen.top_decoration(lx, lz, ctx) != BlockCatalog.AIR:
                    var prof := TerrainConfig.facet_profile(fid, lx, lz)
                    snap[Vector2i(lx, lz)] = TerrainConfig.top_block_id(
                        int(prof.x), int(prof.y), prof.w, lx, lz)
    _skin_chop_memo[fid] = {"rev": rev, "snap": snap}
    return snap
```

Notes:
- **Footprint mapping**: the tile's texel→column map is `bilerp(lat_corners) → (lx,lz)` in fid's
  own lattice — the snapshot keys are those very columns, so any band/fine tile covering them
  picks the override up automatically. No canopy-radius math, no tile-boundary case: a canopy
  "straddling two tiles" is just columns landing in both tiles' texel sets.
- **Colour law**: value = `TerrainConfig.top_block_id(g, biome, temp, lx, lz)` — the *identical*
  call the bare-terrain branch classifies under `FP_SKIN_BLOCK_EXACT`
  (facet_tex_baker.gd:2044 / voxel_generator_cosmos.cpp far_index :2012-2014). All consumers map
  it via `FarPalette.far_color_index_of_block` (:1966/:2007/:2028/:1375), so a chopped column's
  baked index is **bit-equal to what a treeless column there would bake**. (`_pbm_tile_ok`
  :1673-1674 already requires `FP_SKIN_BLOCK_EXACT` whenever climate/texture-mean is on, so the
  served C++ path is in the exact regime. Under block-exact OFF the legacy terrain branch uses
  `far_color_index(color_for(...))` — the chopped column may differ by at most the block-LUT vs
  swatch quantisation of the same biome surface; acceptable, noted, not served.)
- **Memo bound**: `_skin_chop_memo` holds ≤ (facets with edits) entries of ≤ (chopped trees ×
  ≤100 Vector2i). NEVER-OOM: bounded by the player's own chop count; cleared per-fid on re-memo.

### §4.3 WorldManager → baker wiring + the invalidation trigger (cache coherence, part 1)
At `_facet_tex` creation (world_manager.gd:545-556), mirroring the far-trees pattern (:447/:451):
```gdscript
_facet_tex.set_edit_snap_query(Callable(self, "far_skin_edit_snap"))   # FP_FT_SKIN_CHOP
```
At the edit choke point `_write_cell` (world_manager.gd:2028) **and** the erase path (:2105) —
after the `_edits`/`_edits_by_fid` update, under the flag and `_facet_tex != null`:
```gdscript
# FP_FT_SKIN_CHOP: if this edit toggles a procedural tree's chopped state (it IS the trunk-base
# cell of its column's gcell tree), the facet's band/fine skin tiles are stale — re-bake them.
if CubeSphere.FP_FT_SKIN_CHOP and _facet_tex != null and _is_trunk_base_edit(fid, cell):
    _facet_tex.invalidate_far_skin(fid)
```
`_is_trunk_base_edit(fid, cell)`: `TreeGen.tree_info(cell.x/G, cell.z/G, ctx)` non-empty and
`cell == base + Vector3i(0,1,0)` — O(1), fires only on the actual chop (or its undo: an erase that
restores the base makes the tree un-chopped; the same invalidation re-bakes it back in — the
memoed snapshot recomputes because `edit_count()` changed). Building a house never invalidates.

This is the precise analogue of the rung-1/2 coherence hook: FacetFarTrees re-arms its rebuild on
`edit_count()` drift (facet_far_trees.gd:1069); the baker cannot poll cheaply per-fid, so the
choke point pushes the exact fid instead.

### §4.4 FacetTexBaker: snapshot consumption (thread-safety) + invalidation (part 2)
New state + API (facet_tex_baker.gd, near `_edit_snap` :124):
```gdscript
var _edit_snap_query: Callable = Callable()   # FP_FT_SKIN_CHOP: (fid) -> {Vector2i -> block_id}
var _pbm_esnap: Array = []                    # slot -> frozen Dictionary (GDScript branches)
var _pbm_ecells: Array = []                   # slot -> PackedInt64Array (C++ tile path)
var _pbm_efar: Array = []                     # slot -> PackedInt32Array (C++ tile path)
func set_edit_snap_query(q: Callable) -> void: _edit_snap_query = q
```
(size the three arrays with the other `_pbm_*` in setup :1679-1687.)

**Dispatch-time snapshot (MAIN thread — the :1959-1963 contract, verbatim).** At every dispatch
site, immediately before `WorkerThreadPool.add_task`:
- fine dispatch (:1892-1916) and band parallel dispatch (`_update_band_parallel` :1836-…):
```gdscript
var esnap: Dictionary = _edit_snap_query.call(fid) if _edit_snap_query.is_valid() else {}
_pbm_esnap[i] = esnap                          # frozen: WorldManager re-memos into a NEW dict on
var ec := PackedInt64Array(); var ef := PackedInt32Array()   # change, never mutates this one
for k in esnap:
    ec.append(_pack_xz(int(k.x), int(k.y)))
    ef.append(FarPalette.far_color_index_of_block(int(esnap[k])))
_pbm_ecells[i] = ec; _pbm_efar[i] = ef
```
- the single-worker band path (`_bm_begin*` for `_bm_compute_slice_flat`): set the existing
  member `_edit_snap = _edit_snap_query.call(fid) …` at facet-begin (no slice in flight — the
  member's documented contract :1330 "main doesn't mutate during a bake" now actually holds,
  because the writer runs only at begin).

**Compute-path reads** (all three, same law, no logic change — only the source of `have_edits`):
- `_pbm_compute` :1941 `have_edits` → `_pbm_ecells[i].size() > 0` (per-slot, not the shared dict);
- :1956-1966 — replace the dead `_edit_snap` iteration with the prebuilt
  `_pbm_ecells[i]/_pbm_efar[i]` passed straight into `bake_far_tile` :1967;
- :2005 and :2026 — read `_pbm_esnap[i]` instead of `_edit_snap`;
- `_bm_compute_slice_flat` :1338/:1367-1368 — unchanged (reads `_edit_snap`, now legitimately set).

**Invalidation (part 2)** — new:
```gdscript
## FP_FT_SKIN_CHOP: facet `fid`'s chop set changed — drop its baked skin so it re-bakes with the
## fresh snapshot. Fine: un-mark → the cursor re-bakes it (nearest-to-emit-axis first, :1708) and
## _fine_commit re-blits + marks the sub-page dirty (:1735-1745; the size-sentinel early-out :1711
## re-opens because size dropped). Band: evict (:1410) — the fid is still wanted, so the next
## want pass re-dispatches it. Never touches an in-flight slot (the commit lands stale ONCE, and
## the un-mark/evict below already guarantees a fresh re-bake follows it).
func invalidate_far_skin(fid: int) -> void:
    if not CubeSphere.FP_FT_SKIN_CHOP: return
    _fine_baked.erase(fid)
    if _bm_slots.has(fid):
        _evict_band(fid)
```
In-flight race: if `_pbm_inflight(fid)` when invalidated, the running bake commits pre-chop bytes;
correctness needs the re-bake to still happen. `_fine_baked.erase` before the commit is LOST
(`_fine_commit` re-sets it :1745). Guard: `invalidate_far_skin` records `_skin_stale[fid] = true`
when `_pbm_inflight(fid)`; the reap (:1805-1828) checks `_skin_stale` after commit and re-erases/
re-evicts. One extra bounded dict; drained on re-bake.

Latency budget: chop → trunk-base detect (O(1)) → single-facet fine re-bake (one `bake_far_tile`,
~1-3 ms on a worker) + band re-bake (512² tile, the normal band unit) + the ~15-frame fine upload
throttle (:1922-1927) → the far map heals in ~1-2 s. Cards already vanish on their own rebuild —
no window where the skin shows a tree UNDER a still-visible card (card wins depth anyway).

### §4.5 Rungs 1/2 stay untouched
`_is_chopped` (:753), the card/mesh filters (:1183/:1299), `far_tree_chopped` (:3673) and the
edits-rev re-arm (:1069) are not modified. Rung 3 adopts the SAME predicate cell
(`base + (0,1,0)`), so all three rungs flip together on the same edit.

### §4.6 Known robustness gap — scoped OUT (documented)
`far_tree_chopped`/`_is_chopped` test only `gy+1`: a mid-trunk chop that leaves a stump does not
register — cards/meshes keep drawing the full tree, and this design's snapshot (same predicate,
deliberately) keeps the skin drawing it too. That is **consistent-wrong across all three rungs**
(strictly no worse than today, and the collapse mechanics make base-cell chops the overwhelmingly
common case). The clean upgrade is a follow-up flag (`FP_FT_CHOP_TRUNK_SPAN`): scan the trunk
column `gy+1 .. gy+trunk_h` (`trunk_h` is in the enum record `recs[o+7]` floor and in
`tree_info["trunk_h"]`) in ONE place each — `_is_chopped` and `_is_trunk_base_edit`/the snapshot
predicate — so all rungs upgrade together. Out of scope here to keep this change single-purpose.

### §4.7 Other scope-outs
- **SHOT tiers** (g1 base pages / close-up / band-shot via `SurfaceShot.surface_shot`
  surface_shot.gd:61 — trees included): base-page pitch ≈ 26 blk makes a chopped canopy sub-texel
  (box-averaged ×4) — invisible; close-up (3-blk pitch) can show it if `FP_FACET_TEX_CLOSEUP` is
  served. Follow-up P2: pass the same snapshot into `surface_shot` (one optional param) + reuse
  `invalidate_far_skin` to drop `_shot_baked[fid]`/close-up residency. Not needed for the
  reported defect (band+fine own the two observed views).
- **Cross-border chop of a neighbour facet's tree**: the edit is keyed to the active fid; a tree
  owned by the neighbour fid is not detected. Rungs 1/2 have the identical limitation today.
- **General terrain edits in the far skin** (dug pits / placed blocks recoloring the map): the
  full Stage-B. This design deliberately builds Stage-B's *entire* transport (query → dispatch
  snapshot → per-slot arrays → EditTable) so full Stage-B later is only a bigger snapshot writer.
- **Persistence**: `_edits` is session-local; so is the snapshot. Nothing to do.

### §4.8 Byte-off proof sketch
Flag off ⇒ `far_skin_edit_snap` returns `{}` before touching anything; the wiring calls
(`set_edit_snap_query`, `_is_trunk_base_edit`, `invalidate_far_skin`) are flag-gated no-ops;
`_pbm_ecells[i]`/`_pbm_esnap[i]` stay empty ⇒ `have_edits` false in all four compute sites ⇒
`bake_far_tile` receives empty arrays (`have_edits` false at cpp :2240) ⇒ every baked byte
identical to today. Flag ON with zero chops: snapshot `{}` ⇒ same bytes (gated below).

## §5 Gate plan

**New headless gate `godot/src/tools/verify_ft_skin_chop.gd`** (pattern: verify_tile_bake.gd;
FLAT-gate gotcha: fresh worktree needs `godot --import` first):
1. **G-FTSC-OFF** (inertness): flag compiled off — seed a trunk-base edit
   (`seed_edit_for_test`, world_manager.gd:678), bake a tree-bearing facet through BOTH the C++
   `bake_far_tile` path and the GDScript `_pbm_compute` path ⇒ bytes identical to an un-edited
   bake. Also `far_skin_edit_snap` returns `{}`.
2. **G-FTSC-SNAP** (flag on): seed the chop ⇒ snapshot contains exactly the columns where
   `TreeGen.top_decoration != AIR` in the tree's gcell, each valued `top_block_id(...)`; an
   UN-chopped neighbouring tree's gcell contributes nothing; erasing the edit ⇒ `{}` again
   (memo re-computes on `edit_count()` change).
3. **G-FTSC-BAKE** (the defect): flag on + chop ⇒ in the baked tile, every chopped-footprint
   texel reads the **terrain** index (== the index the bare-terrain branch computes for that
   column), every un-chopped tree's texel still reads its **tree** index; C++ and GDScript paths
   byte-equal (extends G-CPB-EDIT :164 with a real chopped snapshot).
4. **G-FTSC-INVAL** (coherence): bake fid → assert `_fine_baked.has(fid)`; chop ⇒
   `invalidate_far_skin` ⇒ `_fine_baked` lost fid + band evicted; drive one update cycle ⇒ re-baked
   bytes now terrain-coloured at the footprint. Include the in-flight-race case (`_skin_stale`).
5. **Regression**: FLAT `verify_feature` **6042/0** with the flag off; the faceted suite
   (verify_tile_bake, verify_far_trees, verify_structures) unchanged.

**Live A/B (deploy worktree, flag flipped in the deploy set):**
- Chop a near tree (base cell). Walk out to 96-256 blk: the card is gone (existing behaviour) AND
  no green/leaf speckle shows on the ground where it stood (band map healed; before the fix the
  speckle shows exactly under the removed card).
- Fly to orbit over the site: no canopy dot at the chop location in the fine map (before: dot
  persists indefinitely).
- Negative control: neighbouring un-chopped trees still speckle at orbit; chop-undo (place a
  block back at the trunk base) restores the far tree in ~1-2 s.
- Perf guard: chop 20 trees while walking — no frame spike (each chop = one O(1) detect + at most
  one fine + one band re-bake, worker-side).

## §6 Cost ledger

- Snapshot build: per chop per fid — O(fid's edits) unpacks + O(touched gcells) `tree_info` +
  ≤100 `top_decoration` + ≤~50 `facet_profile`/`top_block_id` per chopped tree; memoized on
  `edit_count()`. Main-thread ≤ ~0.5 ms native; amortised to once per chop.
- Dispatch marshal: ≤ a few hundred int64/int32 per slot per bake — noise vs the 128²/512² bake.
- `EditTable` build in C++: O(chopped columns), per call — designed for exactly this.
- Memory: `_skin_chop_memo` + `_pbm_esnap/ecells/efar` (≤ 4 slots) + `_skin_stale` — all bounded
  by chop count / slot count. NEVER-OOM holds.

## §7 Fix-site table

| # | file:site | change |
|---|---|---|
| 1 | `godot/src/cosmos/cube_sphere.gd` (~:706) | `const FP_FT_SKIN_CHOP := false` (+ deploy flip list) |
| 2 | `godot/src/world/world_manager.gd` :3673 area | `far_skin_edit_snap(fid)` + `_skin_chop_memo` + `_is_trunk_base_edit` |
| 3 | `godot/src/world/world_manager.gd` :545-556 | `_facet_tex.set_edit_snap_query(...)` |
| 4 | `godot/src/world/world_manager.gd` :2028 (`_write_cell`) + :2105 (erase) | chop-toggle detect → `_facet_tex.invalidate_far_skin(fid)` |
| 5 | `godot/src/world/facet_tex_baker.gd` :124 area | `_edit_snap_query` + `set_edit_snap_query` + `_pbm_esnap/_pbm_ecells/_pbm_efar` (+ setup sizing :1679) |
| 6 | `godot/src/world/facet_tex_baker.gd` :1892-1916 (fine) + `_update_band_parallel` :1836-… (band) + `_bm_begin` (single-worker band) | MAIN-thread per-slot snapshot at dispatch |
| 7 | `godot/src/world/facet_tex_baker.gd` :1941/:1956-1967/:2005/:2026 | compute paths consume the per-slot snapshot (C++ path passes arrays into `bake_far_tile`) |
| 8 | `godot/src/world/facet_tex_baker.gd` new | `invalidate_far_skin(fid)` + `_skin_stale` in-flight guard (reap :1805-1828) |
| 9 | `godot/src/tools/verify_ft_skin_chop.gd` new | G-FTSC-OFF/SNAP/BAKE/INVAL |
| — | `voxel_generator_cosmos.cpp` / patches 0011/0012 | **NO CHANGE** (edit override + EditTable already shipped) |

## §8 Executive summary

- **Flag**: `FP_FT_SKIN_CHOP`, byte-off.
- **Correction to the brief**: rung-3 is NOT `facet_skin_tier.gd` (its `sample_columns` colours
  are terrain-only — verified in `far_color`, cpp:1930-1948). The leaking skin is
  `facet_tex_baker.gd`'s band (`FP_SKIN_FLATCOLOR`) + whole-planet fine (`FP_PLANET_MAP`) L8
  maps, whose three compute paths all paint procedural `top_decoration` trees ignoring `_edits`.
- **Recommendation**: neither the brief's A (C++ patch — unnecessary: patch 0011 already ships an
  edit override that runs BEFORE the tree branch, with `edit_cells/edit_far_idx` snapshot
  parameters and a G-CPB-EDIT byte gate) nor B (post-hoc tile recolor — wrong tier, breaks the
  one-classification-law construction). Instead **A′**: write the already-anticipated Stage-B
  `_edit_snap` writer, scoped to chopped trees — `WorldManager.far_skin_edit_snap(fid)` maps each
  chopped tree's exact footprint columns (its G×G gcell where `top_decoration != AIR`) to the
  bare-terrain `top_block_id`, so the edit branch bakes bit-equal terrain texels. GDScript-only;
  **no engine rebuild**.
- **Thread-safety**: snapshot fetched + frozen MAIN-thread at each dispatch into per-slot arrays
  (the exact contract facet_tex_baker.gd:1959-1963 prescribes); workers never touch live `_edits`.
- **Cache coherence**: `_write_cell`/erase detect a trunk-base toggle (O(1)) →
  `invalidate_far_skin(fid)` → `_fine_baked.erase` (cursor re-bakes) + `_evict_band` (want
  re-bakes) + an in-flight staleness guard — the rung-3 analogue of FacetFarTrees' edits-rev
  re-arm (:1069). Heals in ~1-2 s.
- **Gates**: verify_ft_skin_chop (OFF-inertness, snapshot exactness, chopped-texel==terrain +
  C++/GDScript byte-equality, invalidation incl. in-flight race), FLAT verify_feature 6042/0
  byte-off, live A/B (chop → 96-256 no speckle under removed card → orbit no dot; un-chop
  restores; 20-chop perf guard).
- **Scoped out** (documented): mid-trunk stump chops (gy+1-only predicate — kept consistent with
  rungs 1/2; follow-up `FP_FT_CHOP_TRUNK_SPAN` upgrades all rungs in two sites), SHOT tiers
  (close-up P2 via the same snapshot), cross-border chops, general terrain edits (full Stage-B —
  this design builds its entire transport).
