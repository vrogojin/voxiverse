# COSMOS — Debounced Far-Structure Edit Re-bake (FP_STRUCT_EDIT_DEBOUNCE)

**Status:** DESIGN (buildable, not implemented)
**Scope:** GDScript only — no engine rebuild. All changes byte-off behind one flag.
**Files touched (planned):** `godot/src/world/struct_gen_index.gd`,
`godot/src/world/structure_tracker.gd`, `godot/src/world/world_manager.gd`,
`godot/src/cosmos/cube_sphere.gd`, `godot/src/tools/verify_structures.gd`.

---

## 1. The two user-visible problems and their shared root

**P1 — far-edit reflection timing.** Breaking/placing blocks in a building updates the
NEAR view instantly (the `_edits` overlay is read by `block_id_at` / `structure_cell_at`,
world_manager.gd:4004-4016), and the FAR model of the building re-bakes to show the hole
"within ~1-2 s" by design (struct_gen_index.gd:116-118). The user wants the far re-bake
**deferred**: only once the player has *stopped editing* that building, *departed* ~16
blocks from its nearest block, and been *idle-from-it* for a short time.

**P2 — freeze on break.** Breaking a block inside any structure bbox freezes the game for
a few seconds.

**Shared root (traced, confirmed by code):** the far tier re-bakes **immediately** on
every in-bbox edit, and that immediate re-bake is a whole-registry O(N) synchronous pass:

1. `WorldManager._write_cell` (the ONE overlay write choke point, world_manager.gd:2234)
   calls `_gen_index.note_edit(fid, cell)` for every edit (world_manager.gd:2291-2293;
   the symmetric erase hook at 2339-2345).
2. `StructGenIndex.note_edit` bumps the per-root damage rev **and `_version += 1`** —
   but only when the cell is inside a cached house bbox (`_bbox_has`,
   struct_gen_index.gd:119-130). Plain-terrain breaks don't bump it, which is exactly
   why the freeze correlates with buildings.
3. That `_version` feeds `WorldManager.structure_registry_version()`
   (world_manager.gd:3995-3998), wired to the far tier at world_manager.gd:508.
4. `FacetFarStructures._prelude_epoch` sees the version drift and **re-materializes the
   whole snapshot**: `_resnapshot(ver)` duplicates the full registry (up to
   `STRUCT_REG_MAX`=256 tracker records + ~600 GEN records for a village-dense band) and
   runs `_structure_centre` + `_precompute_card` (a `house_info` + `lattice_to_world64`
   each) per record (facet_far_structures.gd:626-640, 748-765), then returns `true` →
   a full `_rebuild` the **same step** (facet_far_structures.gd:594-595).
5. Under FP_STRUCT_CARD_STAGE the fill is time-boxed, **but** a FRESH (stable→drift)
   edit-driven fill is deliberately *never delayed* — the §2 coalescing rule
   (facet_far_structures.gd:663-671: "a FRESH fill … is NEVER delayed — the REG_EPOCH
   never-drop contract") — so the one-shot `records()` materialize (`_snap_start_fill`,
   facet_far_structures.gd:690-702) still fires within one `STRUCT_STEP_MS`=250 ms step
   (cube_sphere.gd:1309) of every break.
6. The rebuild then routes the damaged house to the **cube sink** (`rev != 0` ⇒
   `is_card = 0`, facet_far_structures.gd:782-786) and `_ensure_bake` re-decimates it —
   `StructDecimator.decimate` is O(bbox volume) of `structure_cell_at` samples
   (facet_far_structures.gd:1298-1336; measured 38 ms → 6 ms/house with
   FP_STRUCT_GATE_MEMO, memory `voxiverse-village-bake-memo`) — and `_commit_mesh`
   re-appends + re-uploads the whole merged band mesh (up to 80 k tris,
   facet_far_structures.gd:1285-1294).
7. Player-BUILT structures have the same coupling on the other producer:
   `StructureTracker.version() = _rev_counter*1024 + _reg.size()`
   (structure_tracker.gd:331-332), and `_rev_counter` bumps on **every** cluster
   mutation — `note_cell`/`note_removed`/`_union`/recluster (structure_tracker.gd:87,
   105, 169, 214) — so every single place/break on your own build drifts the composite
   version and triggers the same O(N) resnapshot at the 250 ms cadence.

Because the NEAR view never reads any of this (it reads `_edits` directly), deferring
the **far-visible** rev/version until the player departs fixes both problems at once:
no synchronous far re-materialize on break (P2), and the far model updates exactly when
the user wants it to (P1).

---

## 2. Design overview — split "truth rev" from "published rev"

The producers keep tracking damage **immediately and losslessly** (truth), but what the
far tier can *see* — the version token and the `rev` fields inside registry records —
is a **published** copy that only advances when the per-structure debounce gate opens:

```
                 truth (instant, lossless)        published (far-visible, debounced)
GEN houses       StructGenIndex._rev[root]   →    StructGenIndex._rev_pub[root]
player builds    StructureTracker._rev_counter →  StructureTracker._version_pub
                 + per-cluster cl["rev"]          + StructureTracker._rev_pub[root]
composite        structure_registry_version()  =  f(published halves only)
```

**Gate (per pending structure):** publish when
`now − last_edit_ms ≥ STRUCT_EDIT_IDLE_MS` **AND**
`dist(player, structure world-AABB) ≥ STRUCT_EDIT_DEPART_BLK` (distance to the AABB =
distance to the nearest block of the building, the user's "~16 blocks" ask).

**Publish = atomic:** copy truth revs → published revs for the gated roots, latch the
tracker's published version, and bump the GEN `_version` **once** (all structures whose
gates open the same tick coalesce into ONE version drift ⇒ one resnapshot ⇒ one
rebuild). The far model therefore *does* eventually reflect every edit — deferred,
never dropped.

While pending, the far tier sees a quiescent version + unchanged record revs ⇒ the
REG_EPOCH prelude takes its O(1)/probe-only paths (facet_far_structures.gd:634-640),
`_ensure_bake` keeps returning the cached pre-edit bake (keyed `(root, rev)`,
facet_far_structures.gd:1300-1303), and the merged mesh is not touched. The stale far
model is invisible anyway: the player is inside `near_render_radius()` of the building,
where the band floor / NEAR_HOLD cull suppresses or holds the far model
(facet_far_structures.gd:899-949) and the near view owns the pixels.

---

## 3. Mechanism, concretely

### 3.1 Pending accumulator (WorldManager-owned — ONE map for both producers)

New state in WorldManager (all under `FP_STRUCT_EDIT_DEBOUNCE`, else never allocated):

```
_sed_pending: Dictionary   # key:int → {last_edit_ms:int, wmin:Vector3, wmax:Vector3,
                           #            gen_roots:Dictionary(root→true), trk:bool}
_sed_pub_count / _sed_publishes: int          # telemetry
```

Key = the structure's root when known (GEN: the negative packed root; tracker: the
post-`note_cell` `_find(ek)` representative). The entry caches the structure's
**world-space AABB**: at entry creation, take the record's `bmin/bmax` (GEN: from the
cached facet records; tracker: from `_clusters[root]`), map the 8 lattice corners
through `FacetAtlas.lattice_to_world64` (the same law the far tier's `_structure_centre`
uses, facet_far_structures.gd:976-987) and store the enclosing world AABB; later notes
to the same key **union** into it. Caching world coords at note time makes the gate
crossing-safe (no per-tick lattice reframing) and O(1) per tick per entry. Root-identity
churn (a tracker `_union`/recluster renames the root) is harmless: the key is only an
aggregation handle — the cached AABB still covers where the player edited, and unioned
AABBs only *over*-cover, so the gate can open late but never wrongly early.

**Hook sites** (both already exist — we extend the tails, no new choke points):

- `_write_cell` tail (world_manager.gd:2287-2293): after `note_cell` / `note_edit`,
  under the flag ask each producer "did this edit land in a tracked structure, and
  which root?" — `StructGenIndex.note_edit` gets a return value (`Array` of damaged
  roots; today it returns void) and `StructureTracker` a
  `last_noted_root() -> int` (−1 if the cell didn't qualify). For each hit, upsert
  `_sed_pending`.
- `sim_revert_cell` (world_manager.gd:2339-2345): same, symmetric.

NEVER-OOM: cap `_sed_pending` at `STRUCT_EDIT_PENDING_MAX` (64). On overflow,
**force-publish the oldest entry** (one bounded resnapshot; still never-drop). The map
is naturally tiny — a player can only edit structures they are standing next to.

### 3.2 Producer changes

**StructGenIndex** (struct_gen_index.gd):

- `note_edit` (line 119): under the flag, bump `_rev[root]` and mutate nothing else —
  **skip** the `_version += 1` (line 130) and **do not** write the pending rev into the
  cached record (line 129). Return the damaged roots.
- New `_rev_pub: Dictionary` (same persistence class as `_rev` — survives LRU eviction,
  line 18). The overlay in `enumerate_facet` (lines 109-110) and any record the far
  tier can see serve `_rev_pub.get(root, 0)`, not `_rev`. This closes the leak where a
  crossing-driven cache refill (`_store` bumps `_version`, line 173) would otherwise
  materialize truth revs into `records()` and re-bake the damaged house mid-edit.
- New `publish_roots(roots: Array) -> void`: for each root copy
  `_rev_pub[root] = _rev[root]`, patch any cached record in `_cache`, then
  `_version += 1` **once**.
- Off-flag: `_rev_pub` never written, overlay reads `_rev` verbatim ⇒ byte-identical.

**StructureTracker** (structure_tracker.gd):

- New `_version_pub := 0` and `_rev_pub: Dictionary root→rev`.
- `version()` (line 331): under the flag return `_version_pub`; off, the shipped
  `_rev_counter * 1024 + _reg.size()` verbatim.
- `_make_record` (line 267): under the flag serve
  `"rev": _rev_pub.get(root, 0)` (truth `cl["rev"]` off-flag). Masking **rev only** is
  sufficient and deliberate: if a GEN-side legitimate version bump (a crossing)
  resnapshots mid-build, the tracker records materialize with current bbox/count but
  the *published* rev — so `_ensure_bake` (keyed `(root, rev)`,
  facet_far_structures.gd:1300) keeps the cached pre-edit bake and no re-decimate
  fires. The far model may over/under-cover by the stale bake for the hold duration —
  cosmetically safe (the same "over-covers only" argument as the tracker's own
  debounced recluster, structure_tracker.gd:17-19), and hidden under the near view
  anyway.
- New `publish() -> void`: `_version_pub = _rev_counter * 1024 + _reg.size()`; copy
  `cl["rev"]` → `_rev_pub[root]` for every live cluster root.
  (Whole-tracker granularity is a deliberate simplification — see §6 R3.)

**WorldManager composite** (world_manager.gd:3995-3998): unchanged code — it already
composes `tracker.version() ^ (gen.version() * 2654435761)`; both halves are now the
published values under the flag.

### 3.3 The debounce tick

`_sed_tick()` called from `WorldManager._process`, beside the existing
`_structure_tracker.tick` / `_gen_index.refresh` (world_manager.gd:964-972). Per frame:

1. No pending ⇒ one `is_empty()` check (the tracker-tick idiom).
2. Else: compute the player's world position once —
   `FacetAtlas.lattice_to_world64(active_fid, _last_player_pos)` (`_last_player_pos`
   is maintained by `update_streaming`, world_manager.gd:242, 961-963; skip the tick
   until `_have_player_pos`).
3. For each entry: if `now − last_edit_ms ≥ STRUCT_EDIT_IDLE_MS` and the point-to-AABB
   distance ≥ `STRUCT_EDIT_DEPART_BLK` ⇒ collect for publish.
4. If any collected: ONE combined publish —
   `_gen_index.publish_roots(all gen roots)` (one `_version` bump),
   `_structure_tracker.publish()` if any tracker entry gated, erase the entries.
   The far tier then sees ONE version drift → one (staged, under FP_STRUCT_CARD_STAGE)
   resnapshot → one rebuild in which `rev != 0` flips the damaged GEN house card→cube
   (facet_far_structures.gd:782-786) and `_ensure_bake` re-decimates just the changed
   structures.

Cost: O(pending) ≈ O(1); one `lattice_to_world64` per frame only while pending.

### 3.4 The far tier's edits-rev term

`_inputs_changed` also re-arms on `_current_edits_rev() != _last_edits_rev`
(facet_far_structures.gd:853), wired to raw `WorldManager.edit_count`
(world_manager.gd:504, 715-716) — so even with the version held, **every first-write
edit anywhere** (including plain terrain digs) forces a full `_rebuild` (sort + probes
+ 80 k-tri merged-mesh re-append + upload) at the 250 ms cadence. For the structures
tier this term is redundant churn: every far-visible structure change is already
carried by rev/version/count/cover-fp. Under the flag, wire
`set_far_structures_edits_rev_query` to a new `struct_edits_rev_pub()` that bumps only
at publish (off-flag: `edit_count` verbatim). The far-TREES wiring
(world_manager.gd:492) is untouched — chop re-arm keeps its own contract.

---

## 4. Interaction with the FP_STRUCT_REG_EPOCH never-drop contract

The contract (facet_far_structures.gd:623-625): "the version bumps on every registry
mutation, so a real change forces a resnapshot + rebuild the same step". The debounce
**redefines when the mutation becomes far-visible**, not whether it does:

- Truth is never lost: `_rev` / `_rev_counter` advance instantly; publish copies truth
  → published and bumps the version, so every edit reaches the far tier exactly once.
- Every *non-edit* version source still passes through immediately: GEN
  `refresh`/`set_active`/`_store` (crossings, band re-selection, cache refills —
  struct_gen_index.gd:43, 51, 173) are genuine far-set membership changes and keep
  their synchronous bumps. Only the two edit-driven bumps
  (struct_gen_index.gd:130; the tracker's whole version) are deferred.
- The Stage-3 "fresh fill never delayed" rule (facet_far_structures.gd:663-671) is
  untouched — it now simply fires at publish time instead of at break time, which is
  exactly the intent: the never-delayed fill IS the one resnapshot the user's departure
  earns.
- No far-tier code changes are strictly required for the core mechanism (the tier
  already does the right thing for a quiescent version); the only far-tier edit is the
  §3.4 query rewiring, which happens in WorldManager.

Composes with FP_STRUCT_REG_EPOCH **off** too (the shipped per-step prelude,
facet_far_structures.gd:598-610): `records()` serve published revs ⇒ `rev_sum` and the
delta gate stay quiescent while pending; the per-step registry materialize is that
arm's pre-existing cost, not a regression.

---

## 5. Freeze breakdown — what the debounce fixes, and what it doesn't

Estimated contributions to the multi-second break freeze (web ≈ 10-25× native, memory
`voxiverse-gen-class-costs`):

| # | Stage | Cost basis | Est. (web) | Fixed by debounce? |
|---|-------|-----------|------------|--------------------|
| 1 | Registry re-materialize (`records()` dup ~600 recs + tracker) | `st_mat_us` telemetry (facet_far_structures.gd:694) | 10-50 ms/burst | **Yes** |
| 2 | Per-record precompute (`house_info` + `lattice_to_world64` × ~600) | `st_prec_us`; amortized under CARD_STAGE, synchronous under bare REG_EPOCH (facet_far_structures.gd:748-765) | 50-600 ms | **Yes** |
| 3 | Damaged-house cube re-bake (`_ensure_bake` → decimate O(volume)) | 6 ms/house memoized, 38 ms un-memoized (memory: bench_struct_bake); the 3555 ms full-band burst (cube_sphere.gd:1370) bounds the worst case | 6-40 ms/house | **Deferred** to publish |
| 4 | Merged-mesh re-append + upload (≤ 80 k tris) + card buffer + `set_buffer` | facet_far_structures.gd:1072-1126 | 20-100 ms | **Yes** (no rebuild while held) |
| 5 | Repeat of 1-4 every 250 ms while the player keeps editing | STRUCT_STEP_MS cadence | sustains the jerk | **Yes** |
| 6 | `_structural_update` → `StructuralSolver.solve`: 11×11 col region scan (~5 k `cell_solid`) + Dinic ≤ 4096 nodes when pass 1 flags (structural_solver.gd:22-23, 41-141) | bounded by MAX_FLOW_CELLS | 20-300 ms | **No — separate follow-up** |
| 7 | Near repaint + `_ground.rebuild_now()` (world_manager.gd:2173-2179) | local | < 10 ms | No (small) |
| 8 | Tracker `_recluster_all` 1 s after a removal: BFS over ALL tracked cells ≤ 65 536 (structure_tracker.gd:180-222) | O(tracked) | up to 100s ms for big builds | No — follow-up; but its rev storm no longer cascades into a far resnapshot (held) |

Rows 1-5 are the far-tier share — the dominant, repeating part, and the part that
scales with village density (matches "freeze correlates with buildings"). Rows 6 and 8
are bounded one-offs; **measure before optimizing**: extend the existing worst-frame
attribution (FP_WORST_FRAME_ATTR arm, memory `voxiverse-ground-walk-perf`) with two
tags — `wf_solve_ms` around `_structural_update` and `wf_reclust_ms` around
`_recluster_all` — in the same deploy arm that A/Bs this flag. If row 6 shows > 100 ms
spikes, the follow-up is a time-boxed/staged solver pass (out of scope here).

---

## 6. Risks / edge cases

- **R1 — player never departs** (builds a base and lives in it): the far model stays
  stale indefinitely. Correct by construction — below `near_render_radius()` the far
  model isn't shown (band floor / NEAR_HOLD, facet_far_structures.gd:930-949). The
  idle-timer alone never publishes without the distance gate; that is intended.
- **R2 — snowfall sim writes inside a house bbox** keep `last_edit_ms` fresh through a
  storm (the sim writes through the same choke, world_manager.gd:2304-2306) ⇒ the far
  model of a snowed-on house updates only after the storm. Acceptable (today this same
  storm causes a *resnapshot storm* — the debounce strictly improves it). Optional
  refinement: skip pending-refresh for snow-family materials (the tracker's
  `_qualifies_mat` filter already exists, structure_tracker.gd:56-57).
- **R3 — whole-tracker publish granularity**: if the player edits build A, departs,
  and is mid-edit on build B when A's gate opens, the single `publish()` exposes B's
  current rev too ⇒ one mid-edit re-bake of B (one structure, one decimate). Bounded,
  rare; per-root tracker granularity is possible later (publish only gated roots'
  `_rev_pub`) at the cost of root-identity bookkeeping across unions/reclusters.
- **R4 — crossing while pending**: GEN crossings still bump the version (legitimate);
  the `_rev_pub` overlay guarantees the refilled records carry published revs, so no
  mid-edit re-bake leaks through (§3.2). Gate-check distance uses cached world AABBs,
  so a post-edit facet crossing cannot mis-measure.
- **R5 — never-OOM**: `_sed_pending` ≤ 64 entries × ~100 B; `_rev_pub` mirrors `_rev`
  (already ledgered, struct_gen_index.gd:213-218 — add `_rev_pub.size() * 48`).
- **R6 — byte-off identity**: every new field/branch sits under
  `if CubeSphere.FP_STRUCT_EDIT_DEBOUNCE` (the house FP idiom: off ⇒ verbatim shipped
  lines, no new allocation/read — the FP_STRUCT_WALK_CALM precedent,
  facet_far_structures.gd:843-849). `note_edit`'s new return value is ignored off-flag
  (GDScript discards it free).

---

## 7. Flags, consts, telemetry, verify gates

In `cube_sphere.gd` beside the FP_STRUCT family (cube_sphere.gd:1287-1482):

```
const FP_STRUCT_EDIT_DEBOUNCE := false   # defer far-visible structure revs until the player departs + idles
const STRUCT_EDIT_DEPART_BLK := 16.0     # publish gate: min distance (blocks) from the structure's world AABB
const STRUCT_EDIT_IDLE_MS := 3000        # publish gate: min ms since the last edit to that structure
const STRUCT_EDIT_PENDING_MAX := 64      # NEVER-OOM: pending-entry cap (overflow force-publishes the oldest)
```

Telemetry (`{}` off-flag, the `bake_stage_state()` convention,
facet_far_structures.gd:1371-1376): `struct_debounce_state()` on WorldManager →
`{sed_pend, sed_pub (total publishes), sed_oldest_ms (age of oldest pending),
sed_forced (overflow publishes)}` — merged into the remote-bridge telemetry ring.

**Verify gates** (extend `verify_structures.gd`; drive `step()`/tick directly, the
G-ST-* pattern; needs `--import` first on a fresh worktree — memory
`voxiverse-flat-gate-import`):

- **G-SED-HOLD** (P2 proof): flag on, seed a GEN village + a qualifying player build;
  place the "player" adjacent; edit both; assert over many ticks/steps:
  `structure_registry_version()` unchanged, far tier `_dbg_rebuild_count` unchanged,
  `records()` revs still published (0), no `_ensure_bake` at a new rev.
- **G-SED-PUBLISH** (P1 proof): move the player `STRUCT_EDIT_DEPART_BLK + ε` away,
  advance the clock past `STRUCT_EDIT_IDLE_MS`, tick ⇒ assert exactly ONE version
  drift for N edits across M structures (coalescing), the far snapshot's record revs
  == truth, the damaged GEN record now routes cube (`is_card` 0) and its bake rev
  advanced — the far model shows the hole.
- **G-SED-NEVERDROP**: randomized edit/depart/return sequences ⇒ after final publish,
  every published rev == truth rev (no edit lost).
- **G-SED-TRACKER**: the same hold/publish pair through `place_block`/`break_terrain`
  on a player build (tracker half), including a mid-hold `_recluster_all` (assert the
  recluster's rev storm does not leak a version drift).
- **Byte-off**: full existing suite + the FLAT gate byte-identical with the flag off
  (the non-negotiable; all G-ST-*/G-NP-* stay green).

---

## 8. Staged build order + effort

| Stage | Content | Effort |
|-------|---------|--------|
| S1 | GEN half: `note_edit` split + `_rev_pub` overlay + `publish_roots`; WorldManager pending map + `_sed_tick` + consts + flag | ~1 day (fixes the reported village break freeze) |
| S2 | Tracker half: `_version_pub`/`_rev_pub` + `publish()`; choke-tail root capture | ~0.5 day |
| S3 | `struct_edits_rev_pub` rewiring (§3.4) | ~0.25 day |
| S4 | Gates G-SED-* + telemetry + FLAT byte-off run | ~0.5 day |
| S5 | Live A/B via deploy-cheats arm (flag ON via CLITE_FLAGS): break blocks in a village house → no freeze; walk 20 blocks away, wait 3 s → far model shows the hole. Instrument rows 6/8 of §5 in the same arm | ~0.5 day |

Deploy-arm note: ship with FP_STRUCT_CARD_STAGE + FP_STRUCT_GATE_MEMO ON (as in the
current arm) so the publish-time refill is time-boxed and the single re-decimate is the
6 ms memoized path — the publish then costs one staged fill + one house bake + one
merged commit, imperceptible at 16+ blocks away.

No engine (C++) work needed anywhere — every touched surface is GDScript.
