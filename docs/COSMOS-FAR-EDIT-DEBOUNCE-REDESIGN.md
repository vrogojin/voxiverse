# COSMOS — Far-Edit Debounce RE-ADD (FP_STRUCT_EDIT_DEBOUNCE v2): O(1) edit frame, deferred O(1) classifier

Status: DESIGN (Fable). Supersedes the edit-path half of docs/COSMOS-FAR-EDIT-DEBOUNCE-DESIGN.md §3.1/§3.2
after the live incident: v1 (519ecdb + 3b1da52) measured **3547 ms worst frame on block-break near a village
with the flag ON** vs 42-92 ms with it reverted. The publish/gate half of v1 (§3.3/§3.4, the pending map, the
never-drop machinery, all G-SED gates) is sound and is kept verbatim; only the *producer* side (what runs on
the edit input frame) is redesigned.

---

## 1. Root cause (verified in code)

### 1.1 The O(big) call and where it runs

The only unbounded flag-ON call on the edit input frame is the **cache-cold lazy enumeration** added by
3b1da52 as a never-drop robustness fix:

- `struct_gen_index.gd:132-141` — `note_edit(fid, cell)`: on a `_cache` miss under the flag,
  `recs = enumerate_facet(fid)` (line 141) runs **synchronously**, reached from both edit choke tails:
  - `world_manager.gd:2331-2333` — `_write_cell` (every break/place/collapse/snow write), and
  - `world_manager.gd:2389-2391` — `sim_revert_cell` (the only `_edits` erase).
- `struct_gen_index.gd:78-121` — `enumerate_facet(fid)` is a **facet-wide structure enumeration**:
  - line 89: constructs a **fresh** `TerrainConfig.GenCtx` (`pcache == null`), so the FP_STRUCT_GATE_MEMO
    memos (`svmemo`/`shmemo`) start **empty** — the memo flag buys nothing here;
  - lines 96-106: loops every candidate village V-cell of the facet domain (~(772/192+1)² ≈ 16-25 cells)
    calling `StructureGen.has_village` — `structure_gen.gd:129` `_has_village_compute` = salt hash +
    `biome_at` + a **4×4 `column_top` cliff stencil (16 columns)** + a sea-level `column_top`;
  - per live village, **36 `house_info` calls** (`STRUCT_HPV²`) — `structure_gen.gd:186`
    `_house_info_compute` = 4 `column_top` + 4 `slope_run_of` + hashes each;
  - every `column_top` hits a **distinct column against a cold per-ctx memo** — full worldgen stackups.

This is **exactly the has_village/house_info stencil-recompute class of the village-bake-memo**
(FP_STRUCT_GATE_MEMO, cube_sphere.gd:1439-1449) — the class already measured at ~150 ms/pass native during
descent bakes — running un-memoized, on the **web main thread**, inside the break input frame. As a
secondary ripple, the lazy fill's `_store` bumps `_version` (`struct_gen_index.gd:219`) ⇒ a REG_EPOCH drift
⇒ the far-structure prelude re-materializes its snapshot the next step.

**Attribution honesty.** Whether one enumeration alone accounts for the full 3547 ms on web could not be
proven from code (a static estimate is high-tens-to-hundreds of ms of native-class column work; web/WASM +
allocator convoys multiply it; and 3547 is uncomfortably close to the *known* 3555 ms full-band wake-bake
constant at cube_sphere.gd:1428). `wf_st_step_us = 0` during the freeze proves the far tier's step did NOT
run on the freeze frame — consistent with the cost living in the `_write_cell` tail. v2 therefore both
(a) removes the entire enumeration class from the edit frame *by construction*, and (b) ships an edit-tail
worst-frame marker (§6) so the re-add A/B attributes the frame budget instead of inferring it.

### 1.2 Why per-break (what the code actually says)

- The cache is **not** invalidated per edit — nothing erases `_cache` on the edit path, and
  `enumerate_facet` memoizes its result via `_store` (`struct_gen_index.gd:120, 217-227`). A second break
  on the *same warm facet* is the bounded O(records-on-fid) bbox loop.
- Per-break repetition therefore requires `_cache.get(fid)` to **miss at each break**. The shipped design
  gives **no guarantee of warmth at the edit choke**: warmth is an accident of the frame loop —
  `_process → _gen_index.refresh(active_facet)` (world_manager.gd:1005-1006) enumerating the wanted band
  (`struct_gen_index.gd:48-49`), or the REG_EPOCH-gated far-tier `records()` fill (`struct_gen_index.gd:65-73`).
  The edit key's fid is the same `TerrainConfig.active_facet()` (world_manager.gd:1771), so a steady-state
  session *should* be warm — meaning the live repetition mechanism is not fully pinned by static analysis
  (candidates: each measured break was a fresh cache-cold session/facet; or part of the 3.4 s is a second,
  unmarked cost in the same tail). The v1 bug remains real either way: 3b1da52 made a cache miss cost
  **unbounded on the input frame**, and no gate asserted otherwise. v2 makes the question moot (no
  enumeration is *reachable* from the edit path) and the new marker settles the residual empirically.

---

## 2. The load-bearing fact: single-cell classification is O(1) by construction

The facet-wide enumeration was never needed to classify **one edit**. The placement law already guarantees
a per-column O(1) resolution — it is exactly how `claim_at` works:

- A house's footprint **never leaves its own 32×32 H-cell**: jitter ∈ [2, HCELL−dim−2]
  (`structure_gen.gd:34-35`, `_jitter` at :232 — "base+dim−1 ≤ HCELL−3 ⇒ O(1) own-cell claim").
- `claim_at` (`structure_gen.gd:247, 261-273`) resolves any cell with **one** `has_village(vx,vz)` +
  **one** `house_info(hx,hz)` where `vx = ⌊x/192⌋`, `hx = ⌊x/32⌋` — no neighbourhood scan.
- The registry root is **position-pure**: `pack_root(fid, hx, hz)` (`structure_gen.gd:428`) — computable
  without any record.
- The record bbox is a pure function of `house_info`: the `make_record` law (`structure_gen.gd:402-425`)
  `bmin = (base.x, base.y+1, base.z)`, `bmax = (base.x+w−1, base.y+1+rtop, base.z+d−1)`.
- Both stencils are **memoized per (vx,vz)/(hx,hz) in a GenCtx** under FP_STRUCT_GATE_MEMO, and
  WorldManager already owns a **persistent per-fid ctx** — `_struct_gen_ctx_for(fid)`
  (world_manager.gd:4235-4239) — the same ctx the far decimator warms. In the common case (player at a
  village whose houses have baked) classification is pure dict hits.

So the correct classifier is **per-column, not per-facet**: worst-case *cold* cost ≈ one village stencil
(16 `column_top` + biome) + one house stencil (4 `column_top` + slope) ≈ low-ms once, memoized thereafter —
and in v2 even that never runs on the input frame.

## 3. v2 design — enqueue on the edit frame, classify deferred

### 3.1 Edit frame (both chokes): strictly O(1), unconditionally

Under the flag, `note_edit` no longer classifies at all — warm or cold, it enqueues the raw edit and
returns. One uniform path; input-frame cost = two O(1) ops, **worldgen-free**, independent of cache warmth:

```gdscript
# struct_gen_index.gd — replaces the v1 note_edit body under the flag
func note_edit(fid: int, cell: Vector3i) -> Array:
    if CubeSphere.FP_STRUCT_EDIT_DEBOUNCE:
        # O(1): pack + append. NEVER classify, NEVER enumerate here.
        if _uncls.size() >= CubeSphere.STRUCT_EDIT_UNCLS_MAX:
            _uncls_overflow[fid] = true            # NEVER-OOM degrade: whole-facet superset marker (§5.4)
        else:
            _uncls.append(FacetAtlas.edit_key(fid, cell))   # PackedInt64Array — the existing bijection
        return []                                  # pending upsert happens at classification (§3.2)
    # OFF: the SHIPPED pre-519ecdb body verbatim (miss ⇒ [], hit ⇒ immediate _rev + rec + _version bump).
    ...
```

The 3b1da52 lazy-fill is **deleted** (its never-drop purpose is now met structurally — §5.1). The tracker
half is untouched: `_sed_note_tracker` (world_manager.gd:4082-4089) is already O(1)
(`last_noted_root` + `structure_bbox` + upsert) and stays synchronous — option (d) as shipped.

### 3.2 Deferred classifier: budgeted, position-pure, O(1) per entry

Runs at the head of `_sed_tick` (world_manager.gd:4136) — or extracted as `_sed_classify_step()` so verify
can drive it, mirroring `_sed_gate_publish`:

```gdscript
const STRUCT_EDIT_CLASSIFY_US  := 500   # per-frame time box
const STRUCT_EDIT_CLASSIFY_MIN := 8     # min entries per tick — guaranteed forward progress
const STRUCT_EDIT_UNCLS_MAX    := 4096  # NEVER-OOM queue cap (32 KB of int64)

func _sed_classify_step() -> void:
    var done := 0
    var t0 := Time.get_ticks_usec()
    while not _uncls.is_empty():
        if done >= STRUCT_EDIT_CLASSIFY_MIN and Time.get_ticks_usec() - t0 > STRUCT_EDIT_CLASSIFY_US:
            break
        var u: Array = FacetAtlas.edit_key_unpack(_uncls_pop())
        _classify_edit(int(u[0]), u[1])
        done += 1

func _classify_edit(fid: int, cell: Vector3i) -> void:
    var ctx = _struct_gen_ctx_for(fid)                       # persistent per-fid ctx — GATE_MEMO hits
    var vx := floori(float(cell.x) / float(StructureGen.STRUCT_V))
    var vz := floori(float(cell.z) / float(StructureGen.STRUCT_V))
    if not StructureGen.has_village(vx, vz, ctx):            # ~1 memoized hash — plain digs die here
        return
    var hx := floori(float(cell.x) / float(StructureGen.STRUCT_HCELL))
    var hz := floori(float(cell.z) / float(StructureGen.STRUCT_HCELL))
    var hi := StructureGen.house_info(hx, hz, ctx)           # memoized; own-H-cell law ⇒ no neighbours
    if hi.is_empty():
        return
    var bb := StructureGen.record_bbox(hi)                   # NEW tiny static helper — see below
    if not StructGenIndex._bbox_has(bb[0], bb[1], cell):     # includes the Y band
        return
    var base: Vector3i = hi["base"]
    if not FacetAtlas.in_polygon(fid, base.x, base.z, 0.0):  # mirror enumerate's emission bijection (:109)
        return                                               # non-owning lattice ⇒ shipped semantics (§7)
    var root := StructureGen.pack_root(fid, hx, hz)
    _gen_index.note_damage(root)                             # NEW: `_rev[root] = _rev.get(root,0)+1` — nothing else
    _sed_upsert(root, fid, bb[0], bb[1], Time.get_ticks_msec(), root, false)   # the existing v1 machinery
```

`StructureGen.record_bbox(hi)` is extracted from `make_record` (structure_gen.gd:406-414) and used by
**both** `make_record` and the classifier, so the bbox law is single-source and can never diverge (gate
G-SED-CLASSIFY asserts equality). `note_damage(root)` on StructGenIndex bumps only the truth `_rev`
(persistence class unchanged — survives LRU eviction, struct_gen_index.gd:18); no `_version`, no cache write.

Everything downstream — pending map, idle/depart gate, coalescing publish, `publish_roots`,
`tracker.publish()`, force-publish, `_sed_pub_rev` — is v1 **verbatim** (world_manager.gd:4092-4199,
struct_gen_index.gd:166-179).

### 3.3 Options considered (task Q3) and why this hybrid

- **(a) defer-only against cached records** — better than v1, but classification would still depend on the
  record cache existing at drain time; an eviction ⇒ the same enumeration bomb, merely relocated. Rejected
  as the primary mechanism; the *scheduling* idea (queue + budgeted tick) is kept.
- **(b) synchronous per-column stencil pre-filter** — correct and nearly free warm (`has_village` memo-hit),
  but a cold persistent ctx still puts a 16-column stencil + house stencil on the *input* frame (low-ms —
  acceptable, but it re-couples input-frame cost to worldgen cost). Kept as the *classifier's* test, moved
  off-frame.
- **(c) reuse the GATE_MEMO GenCtx** — adopted: the classifier threads `_struct_gen_ctx_for(fid)` — the
  persistent, decimator-warmed memo — so steady-state classification is dict hits. (v1's failure was
  precisely a *fresh* ctx making the memo flag useless.)
- **(d) tracker-synchronous / GEN-deferred split** — adopted: player builds stay on the O(1) synchronous
  tracker path; only GEN membership (the only test that ever *needed* worldgen) is deferred.

The winner is (d)+(a-scheduling)+(b-as-classifier)+(c-as-accelerator): the input frame is worldgen-free
O(1) **unconditionally**, and the deferred test is itself O(1) per entry — there is no reachable code path
from an edit to `enumerate_facet` at all.

---

## 4. What stays from v1 (unchanged, already gate-proven)

Truth/published rev split (`_rev`/`_rev_pub`, `_version_pub`), the `records()`/`enumerate_facet` published
overlay, `publish_roots` + tracker `publish()` (incl. the 3b1da52 P0 `_reg` re-make + `_rev_pub` prune),
the pending map with cached world AABBs (+ the bmax+ONE fix), idle≥3000 ms + depart≥16 blk gate, coalescing
one-version-bump publish, the §3.4 `struct_edits_rev_pub` rewire, the NEVER-OOM pending cap with
force-publish, and the sed telemetry. G-SED-PUBLISH / NEVERDROP / TRACKER / BOUNDARY gates unchanged.

## 5. NEVER-DROP (task Q4)

Invariant: **every edit that damages a structure eventually reflects in the far model.**

1. **Unconditional capture.** Every flag-ON GEN-side edit is appended to `_uncls` with no early-outs
   (the only alternative is the overflow superset marker, §5.4). Capture no longer depends on cache warmth —
   the lossless property 3b1da52 patched in is now structural.
2. **Classification is position-pure.** `_classify_edit` is a pure function of (fid, cell) and the frozen
   worldgen epoch — it needs no cache, no records, and is immune to crossings, LRU evictions, and
   reclusters occurring between enqueue and drain.
3. **Guaranteed drain.** ≥ STRUCT_EDIT_CLASSIFY_MIN entries per tick regardless of the time box ⇒ a queue
   of N drains in ≤ ⌈N/MIN⌉ ticks; latency ≪ the 3000 ms idle gate, so no user-visible timing change and
   no interaction with the depart/idle gate (which re-evaluates every tick — an entry upserted late simply
   gates at the next tick both conditions hold).
4. **Overflow degrade (NEVER-OOM).** At STRUCT_EDIT_UNCLS_MAX the facet is marked wholesale-dirty; the
   classifier later resolves that flag by enumerating the facet **off the input frame** (budgeted) and
   bumping + upserting *every* record on it — over-invalidation (a bounded extra re-bake per house), never
   a drop. Unreachable in practice (the drain floor is ~480 entries/s at 60 Hz).
5. **Downstream** is the v1 machinery whose never-drop is already asserted by G-SED-NEVERDROP /
   G-SED-TRACKER (publish ⇒ published rev == truth rev; registry serves it; `_ensure_bake` re-keys).

Deferred truth-rev note: under v2 the truth `_rev` bump lands a few frames after the edit (at
classification) instead of on the edit frame. This is observably identical — nothing far-visible reads the
truth rev before publish, and publish is ≥ 3000 ms away by the idle gate.

## 6. Telemetry (P0 — ship in the same commit, before any live A/B)

The 3547 ms lived in a tail with no marker; that is itself a defect. Add to `worst_frame_markers()` →
remote_bridge (flag-gated, absent-off like the sed keys):

- `wf_sed_note_us` — µs accumulated across both edit-choke tails this frame (the enqueue; should read ~0);
- `wf_sed_cls_us` — the classifier tick's µs (bounded by the box);
- `sed_uncls` — queue depth (with the existing `sed_pend/pub/oldest_ms/forced`).

Re-add acceptance on live: break near a village with the flag ON ⇒ worst frame ≈ the OFF arm (42-92 ms),
`wf_sed_note_us` ≈ 0, and the hole appears far after depart+idle (the original feature ask).

## 7. Byte-off + gates (task Q5)

- FP_STRUCT_EDIT_DEBOUNCE stays default **false**. OFF ⇒ `note_edit` is the shipped pre-519ecdb body
  verbatim (miss ⇒ `[]`, hit ⇒ immediate `_rev` + `rec["rev"]` + `_version` bump); the queue, classifier,
  `note_damage`, and markers are never constructed/called. FLAT 6042/0 (FLAT never builds `_gen_index`).
- Gate changes in verify_structures.gd:
  - **G-SED-HOLD** — re-point "truth rev bumped instantly" to "after one driven `_sed_classify_step()`"
    (the verify driver calls it directly, exactly as it drives `_sed_gate_publish`).
  - **NEW G-SED-COLD** — the regression guard for this incident: with a COLD `_cache`, an in-bbox edit ⇒
    `idx.enum_count()` UNCHANGED across the edit call (no facet enumeration on the input path); after a
    driven classify + gate publish, published rev == truth (never-drop from cold).
  - **NEW G-SED-CLASSIFY** — mixed batch (in-house / plain-terrain / in-footprint-wrong-Y / non-owning-seam
    lattice) ⇒ exactly the in-house edits bump; roots equal `pack_root`; `record_bbox(hi)` equals the
    enumerated record's bmin/bmax for the same house (the single-source-law guard).
  - **NEW G-SED-BUDGET** — 100 queued ⇒ drained in ≤ ⌈100/MIN⌉ driven ticks, queue empty, all classified.
  - G-SED-PUBLISH / NEVERDROP / TRACKER / BOUNDARY unchanged; verify_fartier_walk 37/0 OFF, 41/0 all-on.
- Known unchanged limitation (documented, not worsened): a seam-straddling house edited from the
  *non-owning* facet's lattice is missed by both v1's record loop (records are emitted per owning fid,
  struct_gen_index.gd:109) and v2's `in_polygon` mirror of the same bijection — pre-existing §12.5
  semantics, out of scope.
- Follow-up F1 (out of scope, flag-independent): `refresh()`'s crossing-time band enumeration
  (struct_gen_index.gd:48-49) is the same stencil class run for the whole band in one frame — it should
  thread a persistent memoized ctx and/or stage across frames; and the residual 3547-vs-enumerate
  attribution question (§1.1) is settled by the §6 markers in the first ON-arm run.

## 8. Build order

S1 (GDScript-only, no engine rebuild): note_edit rewrite + queue + `_sed_classify_step` + `note_damage` +
`record_bbox` extraction + gate updates. S2: §6 markers. S3: FLAT + verify_structures (three arms) +
verify_fartier_walk. S4: deploy_cheats ON-arm live A/B — assert wf parity with OFF on breaks *first*, then
the feature acceptance (far hole after depart+idle).
