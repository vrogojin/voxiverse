# COSMOS DE-ORBIT STRUCTURE STAGING — `FP_STRUCT_NEAR_HOLD` + `FP_STRUCT_BAKE_STAGE`

**Status: DESIGN (no code changes in this doc's branch). Companion to
`COSMOS-DEORBIT-SHELL-STAGING-DESIGN.md` / `-SHELL-PREWARM-` / `-SLICE-SMOOTHING-` (the shell arc is done:
2440 ms sustained → median 153 ms / p90 295 ms). This doc attributes and fixes the dominant REMAINING de-orbit
spike — the measured 3555 ms frame at alt ~598 — and the LIVE-confirmed "houses disappear while descending"
coverage hole. Both are the same subsystem: the `FP_STRUCT_*` village far-render handoff.**

---

## 0. Executive summary

- **The 3555 ms frame is NOT a "near-render promotion" and NOT the anchor knee.** It is the
  `FacetFarStructures` **zone-B wake**: `FT_SHELL_HIDE_ALT := 600.0` (cube_sphere.gd:1195). Descending through
  h = 600 (measured at ~598 — two blocks into the band, i.e. the first rebuild after crossing) un-suspends the
  far-structure tier for the first time in the descent, and its first `_rebuild` synchronously bakes **every
  generated village house within the STRUCT_FAR_MAX = 2400 band in one main-thread frame** — hundreds of
  houses × ~1 500 `claim_at` samples each. `vox_gen=0` and bounded shell telemetry in the spike frame are
  consistent: the burst is pure GDScript decimator work, invisible to both counters.
- **`objects` (133→152) is `Performance.OBJECT_NODE_COUNT`** (remote_bridge.gd:764) — scene-tree **nodes**, not
  structures. The far-structure tier owns exactly ONE `MeshInstance3D` created at setup. The +19 nodes are the
  S1 anchor-hysteresis re-grow (knee ≈ 609) adding near facet/LOD mesh nodes in the same window. Coincident
  marker, wrong attribution — the struct cost never shows in `objects`.
- **Systematic verdict: YES** — `VILLAGE_CHANCE = 0.5` per 192-block V-cell on plains ⇒ order 300–900 houses in
  any continental 2 400-block band. Every land de-orbit pays the burst; only an all-ocean/mountain corridor
  escapes. Worth the fix.
- **The disappearing houses (live user report) are a probe-free band floor**: `_cull_emit`
  (facet_far_structures.gd:314-315) drops the far model **unconditionally** at `dist < near_render_radius()`,
  with **no NearPresence probe** — while the near voxel build of those very columns still lags the descent
  (anchor re-grow, credit pacing). The house has no renderer for seconds. This is a confirmed hole, and the
  centerpiece of the fix.
- **The fix is two composing byte-off flags, deployed together:**
  - `FP_STRUCT_NEAR_HOLD` (centerpiece, correctness): inside `r0` the far model is **held until the near build
    actually probes COVERED** (positive probe = fact ⇒ hide immediately, the far-trees streak-1 law). No frame
    ever shows a house-shaped hole.
  - `FP_STRUCT_BAKE_STAGE` (perf): the wake bake is **staged nearest-first**, ≥ `STRUCT_BAKE_STAGE_MIN` houses
    and ≤ `STRUCT_BAKE_STAGE_MS` ms per pass, drained every frame, mesh committed on the shipped
    `STRUCT_STEP_MS` cadence. Invariant: **staging may only delay the ADDITION of a never-yet-shown house; it
    never removes a shown one** — so it cannot recreate the disappearance.

---

## 1. STEP-1 attribution, grounded in the code

### 1.1 What actually happens at alt ~598

`FacetFarStructures.step()` (facet_far_structures.gd:204-244) early-returns while off-surface **unless**
`shell_mode` — and with the deployed `FP_STRUCT_SHELL_BAND` on:

```gdscript
# facet_far_structures.gd:212-218
var h := (_ring as FacetFarRing).shell_cam_alt() if CubeSphere.FP_STRUCT_SHELL_BAND else -1.0
var shell_mode := CubeSphere.FP_STRUCT_SHELL_BAND and offsurf and h < CubeSphere.FT_SHELL_HIDE_ALT
...
if offsurf and not shell_mode:
    return
```

`FT_SHELL_HIDE_ALT = 600.0` (cube_sphere.gd:1195). Above 600 the tier is zone O: hidden, frozen, **never
stepped past this return for the whole orbit**. The descent frame that crosses h = 600 is the tier's first
live step in minutes. `_inputs_changed` (261-276) fires trivially (`not _have_rebuilt` on a fresh session, or
camera drift ≥ 2 blocks otherwise — the camera fell hundreds of blocks since the last on-surface rebuild), and
`_rebuild` (365-397) runs **synchronously on the main thread**:

1. `structure_registry()` (world_manager.gd:3971-3977) = tracker records + **`_gen_index.records()`** — every
   cached wanted-facet GEN house, each `.duplicate()`d.
2. Sort all records nearest-first (369-370).
3. For every record with `dist ≤ STRUCT_FAR_MAX = 2400` that the cull emits: **`_ensure_bake`** (412-450).
   The bake cache is keyed `(root, rev)` — and on this first-ever step the cache is EMPTY. Every house bakes.

### 1.2 Per-house bake cost

`_ensure_bake` → `StructDecimator.decimate(fid, bmin, bmax, sampler)` (struct_decimator.gd:34-73): a full
bbox scan, one `sampler.call` **per cell**. A house bbox is up to 11×13×11 ≈ 1 573 cells (typ. ~7×9×7 ≈ 440).
The sampler is `WorldManager.structure_cell_at` (world_manager.gd:3983-3996): overlay dict miss → 
`StructureGen.claim_at(x, y, z, ctx)` — village hash → `house_info` → template, with `column_top` memoized per
column only inside the shared `GenCtx` (`_struct_gen_ctx_for`, a 1-entry per-fid cache). On WASM this is
~2–6 µs/cell ⇒ **~2–6 ms per house** (footprint column_top misses dominate the first cells).

### 1.3 How many houses

Facet side ≈ (π/2 · 6371)/24 ≈ 417 blocks (facet_atlas.gd:12-13). V-cell pitch 192, `VILLAGE_CHANCE = 0.5`,
≤ 36 house sub-cells × `HOUSE_CHANCE = 0.55` × site/flatness rejection ⇒ ~10 surviving houses per live
village, ~1–2 gated villages per plains facet. The 2 400-block band covers ~90–100 facets (StructGenIndex
`_FACET_CAP = 96` wanted band). **Order 300–900 GEN records** over continental terrain.

**300–900 houses × 2–6 ms ≈ 0.6–5.4 s in ONE frame — the measured 3555 ms sits squarely inside this window.**
Then `_commit_mesh` uploads the merged mesh (tri-capped at `STRUCT_FAR_TRIS_MAX = 80 000` ≈ 240 k verts ≈
6.7 MB) — a further one-shot ~tens-of-ms, plus the dlmalloc convoy pressure from the thousands of
`PackedVector3Array` intermediates on the threaded web heap (the same convoy class the shell staging fixed).

### 1.4 The `objects` field and secondary contributors

- `objects` = `Performance.OBJECT_NODE_COUNT` (remote_bridge.gd:764). `FacetFarStructures` adds **one node
  ever** (setup_instance:149-155). The 133→152 jump is near-field re-grow nodes (facet_smooth_tier.gd:778,
  facet_lod_mesher.gd:589/616/688, facet_block_lod_ring.gd:436) as the plate re-anchors below the 609
  hysteresis knee (`ANCHOR_REL_LO/ANCHOR_HYST` = 700/1.15, cube_sphere.gd:2813-2815). Same window, different
  (cheap, already-paced) subsystem. The user's hypothesis was RIGHT about the subsystem (villages) but the
  telemetry field that seemed to confirm it is unrelated.
- Same-frame secondary: `FacetFarTrees` has the **identical zone O→B wake at the same 600 boundary**
  (facet_far_trees.gd:810-811) and steps immediately before the structures in the ring
  (facet_far_ring.gd:1525-1530). Its card-buffer rebuild is the known ~100–250 ms class — a contributor, not
  the dominator. (If the A/B leaves a residual spike at 600 with both struct flags on, the trees' wake is the
  next candidate — same playbook applies.)
- The `StructGenIndex` crossing enumeration (96-facet re-walk, struct_gen_index.gd:32-40) is a separate,
  smaller burst tied to facet crossings, not to the 600 wake. Out of scope here; noted in §10.

### 1.5 The LIVE hole — why houses disappear during descent (confirmed by the user)

The near-handoff cull has a **probe-free band floor**:

```gdscript
# facet_far_structures.gd:313-317  (_cull_emit)
var r0 := float(TerrainConfig.near_render_radius())
if dist < r0:
    return false                                   # band floor: the near field owns the view (no far model)
if dist > r0 + CULL_ANNULUS:
    return true                                    # beyond near reach — emit, no cull
```

and `_probe_pass` (293-295) never even probes below `r0`. The comment's assumption — "inside
`near_render_radius()` the near field owns the view" — is **false during a descent**: the near voxel field is
still re-growing (anchor view-distance ramp, stream credit, mesh lag), so when the falling camera's r0-sphere
sweeps over a village, every house inside it loses its far model **immediately** (next rebuild) while its near
mesh is still seconds away. The house has NO renderer: the exact "some houses have disappeared nearby while we
have been descending" report. NearPresence (near_presence.gd:35-57) can already answer the right question
tri-state — COVERED is trustworthy at ANY distance ("a positive is_area_meshed is a fact") — the structures
tier just never asks it inside r0. (The far TREES already follow the right law in the annulus: "COVERED ⇒ cull
immediately, HIDE_STREAK 1 — a positive is trustworthy", facet_far_trees.gd:546 — but they too hard-drop below
their floor; trees are visually forgiving, houses are not.)

Note the whole-tier dissolve (`tier_fade` over 520–600, facet_far_structures.gd:179-180) also makes houses
faint right at the wake — intended, and not what the user saw ("nearby" houses at low altitude).

### 1.6 Verdict

**Systematic on both axes.** The wake burst fires on every land de-orbit (villages at 0.5/V-cell make "over a
village" the common case, and the 2 400 band makes "near a village" near-certain over plains). The band-floor
hole fires on every descent/approach that brings a house from the far band into r0 before near meshing catches
up — i.e. every landing at a village. Build the fix. (Over open ocean neither fires — a control corridor for
the A/B.)

---

## 2. Design overview — one handoff law, two flags

```
                    zone O (h≥600)          zone B (520..600)        on-surface descent          landed
house renderer:   fine-map roof pixels →  merged far mesh (fades →  merged far mesh (held) →  near voxel house
                    (FP_STRUCT_LOD)         in, staged bakes)         until COVERED probe        (far culled)
```

- **`FP_STRUCT_NEAR_HOLD`** (correctness, the centerpiece): replace the probe-free `dist < r0 ⇒ drop` with
  *hold-until-covered*: inside r0 the far model keeps emitting until `NearPresence` probes COVERED for its
  bbox — then it hides **immediately** (streak 1; a positive probe is a fact — the trees' law). NOT_COVERED
  while hidden restores after the existing `STRUCT_SHOW_STREAK` (a near unload re-shows the far model).
  UNKNOWABLE never flips (shared invariant). This closes the live hole for the *swap direction* the user hit.
- **`FP_STRUCT_BAKE_STAGE`** (perf): the rebuild's bake work is drained nearest-first under a per-pass budget
  (≥ MIN houses for guaranteed convergence, ≤ MS ms time box), every frame while pending; the merged mesh
  commit (the 80 k-tri upload) stays on the shipped `STRUCT_STEP_MS = 250` cadence. A record without a bake is
  skipped from assembly **only if it was never shown** (`_has_bake` is keyed root+rev, and a shown house's bake
  is cached) — staging can therefore only delay first appearance, never remove.

They are independent (either alone is correct and byte-off), reviewed and deployed together as one handoff
fix. Both compose with the deployed `FP_STRUCT_FAR/DETECT/GEN/LOD/SHELL_BAND/NEAR_GUARD`: the settle gate,
`STRUCT_STEP_MS` rate cap, delta gate, `NEAR_GUARD` credit relaxation, tri/byte caps and the zone-material law
are all untouched; the new logic lives strictly inside `_probe_pass`/`_cull_emit`/`_rebuild`.

### 2.1 New constants (`godot/src/cosmos/cube_sphere.gd`, insert after line 1264, i.e. after `FP_STRUCT_SHELL_BAND`)

```gdscript
## FP_STRUCT_NEAR_HOLD + FP_STRUCT_BAKE_STAGE (docs/COSMOS-DEORBIT-STRUCT-STAGING-DESIGN.md) — the de-orbit
## village handoff, two composing fixes. (1) HOLD: the shipped cull drops a far house model UNCONDITIONALLY at
## dist < near_render_radius() with NO NearPresence probe, so a descending player sees houses VANISH until the
## lagging near build arrives (live-confirmed). Inside r0 the far model now HOLDS until the near build actually
## probes COVERED (positive = fact ⇒ hide immediately, the far-trees streak-1 law; NOT_COVERED while hidden
## restores after STRUCT_SHOW_STREAK; UNKNOWABLE never flips). (2) STAGE: the zone-B wake at FT_SHELL_HIDE_ALT
## first-bakes EVERY GEN house in the STRUCT_FAR_MAX band in ONE frame (measured 3555 ms at alt ~598) — the
## bake now drains nearest-first, ≥ STAGE_MIN houses and ≤ STAGE_MS ms per pass, every frame while pending;
## the merged-mesh commit keeps the shipped STRUCT_STEP_MS cadence. Staging only delays the ADDITION of a
## never-yet-shown house — it NEVER removes a shown one. Both default OFF ⇒ byte-identical (FLAT 6042/0).
## Need FP_STRUCT_FAR. Gates: G-ST-HOLD / G-ST-STAGE (src/tools/verify_structures.gd).
const FP_STRUCT_NEAR_HOLD := false           # far model held inside r0 until the near build probes COVERED (no hole)
const FP_STRUCT_BAKE_STAGE := false          # staged wake-bake drain (no single-frame village bake burst)
const STRUCT_BAKE_STAGE_MS := 8.0            # per-pass bake time box (ms) ≈ half a 60 Hz frame
const STRUCT_BAKE_STAGE_MIN := 2             # min fresh bakes per pass — guaranteed forward progress
const STRUCT_HOLD_PROBE_CAP := 96            # max inside-r0 probes per pass (past ⇒ UNKNOWABLE ⇒ hold; safe degrade)
```

Budget arithmetic: worst wake backlog ≈ 900 houses × ~4 ms ≈ 3.6 s of bake work → at 8 ms/frame × 60 Hz ≈
480 ms of bake per wall second ⇒ **fully drained in ~4–8 s**, nearest-first (the houses you can see appear
first), the earliest seconds of which sit under the 520–600 `tier_fade` dissolve where the tier is near-
invisible anyway. Per-frame overhead while draining ≈ 8 ms bakes + ~2–3 ms probe/sort bookkeeping ≤ ~12 ms —
comfortably under the ~200 ms target and under a vsync frame.

---

## 3. Exact edit sites — `godot/src/world/facet_far_structures.gd`

All line numbers against the current worktree file (as read for this design).

### 3.1 State (insert after line 64, `var _last_step_ms := 0`)

```gdscript
# FP_STRUCT_BAKE_STAGE drain state (inert off-flag: never set, never read on the shipped path)
var _bake_pending := false                    # un-baked in-band records remain — re-dispatch every frame
var _last_commit_ms := 0                      # merged-mesh commit cadence anchor (drain frames skip commits)
var _dbg_stage_passes := 0
var _dbg_stage_baked_last := 0
var _dbg_stage_ms_last := 0.0
```

### 3.2 step() rate cap — drain bypass (lines 226-229)

Before:
```gdscript
	var now := Time.get_ticks_msec()
	if now - _last_step_ms < CubeSphere.STRUCT_STEP_MS:
		return
	_last_step_ms = now
```
After:
```gdscript
	var now := Time.get_ticks_msec()
	# FP_STRUCT_BAKE_STAGE: while a staged drain is pending, step EVERY frame (the per-pass time box bounds the
	# cost); the merged-mesh COMMIT keeps the shipped STRUCT_STEP_MS cadence via _last_commit_ms in _rebuild.
	var draining := CubeSphere.FP_STRUCT_BAKE_STAGE and _bake_pending
	if not draining and now - _last_step_ms < CubeSphere.STRUCT_STEP_MS:
		return
	_last_step_ms = now
```
Off-flag: `draining` is constant false ⇒ the shipped two-line cap verbatim.

### 3.3 `_inputs_changed` — pending drain re-arms (line 268)

Before:
```gdscript
		or cover_fp != _last_cover_fp \
		or _cull_pending
```
After:
```gdscript
		or cover_fp != _last_cover_fp \
		or _cull_pending \
		or (CubeSphere.FP_STRUCT_BAKE_STAGE and _bake_pending)
```
Guarantees convergence for a *stationary* wake (teleport/hover): frozen inputs still rebuild while un-baked
records remain. (During a real descent camera drift ≥ 2 blocks re-arms anyway.)

### 3.4 `_probe_pass` — probe inside r0 too (lines 293-295)

Before:
```gdscript
			var dist := _structure_dist(rec, cam_abs)
			if dist < r0 or dist > r0 + CULL_ANNULUS:
				continue                                   # band floor / beyond near reach — no probe
```
After:
```gdscript
			var dist := _structure_dist(rec, cam_abs)
			# FP_STRUCT_NEAR_HOLD: the band floor is no longer probe-free — inside r0 the far model holds until
			# the near build actually covers it, so it MUST be probed (capped; past the cap ⇒ no cache entry ⇒
			# UNKNOWABLE ⇒ hold — the safe direction). Off ⇒ the shipped skip verbatim.
			var below_floor := dist < r0 and (not CubeSphere.FP_STRUCT_NEAR_HOLD or probes >= CubeSphere.STRUCT_HOLD_PROBE_CAP)
			if below_floor or dist > r0 + CULL_ANNULUS:
				continue
```
with `var probes := 0` initialised at the top of the function and `probes += 1` beside the existing
`_near_query.call` (line 296). The existing fingerprint-XOR and `_cull_pending` lines (298-305) now naturally
include inside-r0 probes — a near mesh landing under a still camera re-arms the rebuild and the pending-hide,
with zero further changes.

### 3.5 `_cull_emit` — hold-until-covered band floor (lines 314-315) — THE HOLE FIX

Before:
```gdscript
	if dist < r0:
		return false                                   # band floor: the near field owns the view (no far model)
```
After:
```gdscript
	if dist < r0:
		# FP_STRUCT_NEAR_HOLD (live defect: houses vanish during descent): the shipped floor drops the far
		# model on DISTANCE ALONE while the near build still lags the descent — a renderer-less house. Inside
		# r0, hide ONLY on an actual COVERED probe (positive = fact ⇒ streak 1, the far-trees law,
		# facet_far_trees.gd:546); NOT_COVERED while hidden restores after STRUCT_SHOW_STREAK (near unloaded ⇒
		# far returns); UNKNOWABLE never flips (shared invariant). Off ⇒ the shipped `return false` verbatim.
		if not CubeSphere.FP_STRUCT_NEAR_HOLD:
			return false
		var st0 := int(_probe_cache.get(root, NearPresence.UNKNOWABLE))
		var cs0: Dictionary = _cull.get(root, {"hidden": false, "cover": 0, "uncover": 0})
		if st0 == NearPresence.COVERED:
			cs0["hidden"] = true
			cs0["cover"] = 0; cs0["uncover"] = 0
		elif st0 == NearPresence.NOT_COVERED and bool(cs0["hidden"]):
			cs0["uncover"] = int(cs0["uncover"]) + 1
			if int(cs0["uncover"]) >= CubeSphere.STRUCT_SHOW_STREAK:
				cs0["hidden"] = false
				cs0["uncover"] = 0
		_cull[root] = cs0
		return not bool(cs0["hidden"])                 # HOLD: emitted until the near build actually covers it
```
The annulus path (316-332) is untouched. Note the asymmetry is deliberate and mirrors the trees: hide is
**instant** on COVERED (kills the double-draw window inside r0 in one pass), restore is streaked (a flickering
probe never strobes the model).

### 3.6 `_rebuild` — staged drain + never-remove assembly (lines 365-397)

Insert after the nearest-first sort (line 370):
```gdscript
	# FP_STRUCT_BAKE_STAGE: drain fresh bakes under the budget FIRST; on a bake-only frame (pending drain,
	# commit cadence not due) stop here — the resident merged mesh keeps drawing untouched (never a removal).
	if CubeSphere.FP_STRUCT_BAKE_STAGE:
		_drain_bakes(ordered, cam_abs)
		if _bake_pending and Time.get_ticks_msec() - _last_commit_ms < CubeSphere.STRUCT_STEP_MS:
			return
```
Inside the assembly loop, before `var bake := _ensure_bake(rec)` (line 382):
```gdscript
		if CubeSphere.FP_STRUCT_BAKE_STAGE and not _has_bake(rec):
			continue        # staged: never-yet-shown house — its addition waits for the drain (removals never wait)
```
After `_commit_mesh(verts, colors)` (line 392):
```gdscript
	if CubeSphere.FP_STRUCT_BAKE_STAGE:
		_last_commit_ms = Time.get_ticks_msec()
```

### 3.7 New helpers (insert after `_ensure_bake`, line 450)

```gdscript
## True iff `rec` has a CURRENT-rev cached bake (i.e. it is, or can instantly be, in the merged mesh).
func _has_bake(rec: Dictionary) -> bool:
	var cached: Variant = _baked.get(int(rec["root"]))
	return cached != null and int((cached as Dictionary)["rev"]) == int(rec["rev"])

## FP_STRUCT_BAKE_STAGE: nearest-first, time-boxed bake drain. Always bakes ≥ STRUCT_BAKE_STAGE_MIN fresh
## records (guaranteed forward progress ⇒ guaranteed convergence), then stops past STRUCT_BAKE_STAGE_MS.
## Sets _bake_pending iff un-baked in-band records remain. Byte-cap {} bakes are skipped without re-arming
## (the shipped NEVER-OOM degrade — they retry next pass at O(1) cost, exactly as today).
func _drain_bakes(ordered: Array, cam_abs: Vector3) -> void:
	_dbg_stage_passes += 1
	var t0 := Time.get_ticks_usec()
	var fresh := 0
	_bake_pending = false
	for rec in ordered:
		if _structure_dist(rec, cam_abs) > CubeSphere.STRUCT_FAR_MAX:
			continue
		if _has_bake(rec):
			continue
		if fresh >= CubeSphere.STRUCT_BAKE_STAGE_MIN \
				and float(Time.get_ticks_usec() - t0) * 0.001 >= CubeSphere.STRUCT_BAKE_STAGE_MS:
			_bake_pending = true
			break
		if _ensure_bake(rec).is_empty():
			continue
		fresh += 1
	_dbg_stage_baked_last = fresh
	_dbg_stage_ms_last = float(Time.get_ticks_usec() - t0) * 0.001

## Telemetry / gate read-back ({} off-flag — confound-free A/B, the shell_band_state() convention).
func bake_stage_state() -> Dictionary:
	if not CubeSphere.FP_STRUCT_BAKE_STAGE:
		return {}
	return {"st_pend": _bake_pending, "st_bk": _dbg_stage_baked_last,
			"st_bms": snappedf(_dbg_stage_ms_last, 0.1), "st_passes": _dbg_stage_passes,
			"st_live": _live_structures}
```

### 3.8 Telemetry plumb (remote_bridge lite dict, flag-gated)

Merge `bake_stage_state()` into the lite telemetry via the existing duck-typed probe pattern
(remote_bridge.gd's unique-method-name merge; the ring exposes the tier). Fields: `st_pend`, `st_bk`,
`st_bms`, `st_live`. Off-flag: `{}` merged ⇒ byte-identical telemetry (the `shell_band_state` precedent).

---

## 4. No-hole and no-double-draw arguments

**No hole, all four phases:**
1. **Zone O (h ≥ 600):** unchanged — the fine-map roof pixels (`FP_STRUCT_LOD`) own the view; the tier is
   hidden exactly as today.
2. **Wake + drain (520 ≤ h < 600 and below):** staged houses that are *missing* from the merged mesh were
   **never on screen** — their cover is the same rung that covered them one frame earlier at h = 601 (roof
   pixels + the tier's own `tier_fade` dissolve, which is ≈ 0 at the wake altitude: today's 3 555 ms frame
   builds a mesh that is ~99 % dithered away). Nearest-first drain means the houses large enough to resolve
   appear first; the backlog drains in ~4–8 s while the tier fades in over the same window.
3. **Descent through r0 (the confirmed live hole):** `FP_STRUCT_NEAR_HOLD` — the far model now keeps emitting
   inside r0 until `NearPresence` returns COVERED **for that structure's bbox** (a positive `is_area_meshed`
   is unconditional fact, near_presence.gd:14-16,45-49). The swap ordering is now: far draws → near mesh lands
   → probe flips COVERED → far hides. There is no frame between "far hidden" and "near present". If the near
   field can never mesh the bbox (outside the meshed slab) the probe answers NOT_COVERED definitively and the
   far model persists — correct.
4. **Staging × hold interaction:** the assembly skip applies only to records failing `_has_bake` — a record
   held inside r0 has necessarily been baked (it has been drawing), so **the hold can never be starved by the
   stage**. Formally: staging delays first-appearance only; the removal paths (COVERED-hide, registry
   eviction) are untouched.

**No double-draw:** inside r0 a COVERED probe hides the far model in ONE pass (streak-1, §3.5) — the overlap
window is ≤ one rebuild cadence (≤ 250 ms), the same accepted class as `FP_STRUCT_NEAR_GUARD`'s fix window,
and the far model is a decimated hull at the same lattice coords (no z-fighting shimmer at cell scale — it
sits at/inside the near voxel surfaces). In the annulus the existing streak law is byte-unchanged. The zone
material law (`_apply_shell_visibility`) is untouched, so the roof-pixel-vs-mesh ownership above 600 is
exactly today's.

---

## 5. Byte-off and flag composition

- Both flags default `false`. Every new branch is guarded: off ⇒ `_probe_pass`/`_cull_emit`/`_rebuild`/step's
  rate cap execute the shipped statements verbatim; the new state vars are written only under a flag; the new
  helpers are unreachable; `bake_stage_state()` returns `{}`. **FLAT verify_feature.gd 6042/0 is unaffected**
  (`FacetFarStructures` isn't even constructed off `FP_STRUCT_FAR`/`FACETED`).
- Composition: needs `FP_STRUCT_FAR` (tier exists). Rides with `FP_STRUCT_GEN` (the GEN records are the
  volume), `FP_STRUCT_SHELL_BAND` (the wake this stages; without it the same burst simply fires later, at the
  on-surface transition — both flags' logic is band-agnostic), `FP_STRUCT_NEAR_GUARD` (credit gate relaxation
  upstream of, and orthogonal to, both changes), `FP_STRUCT_LOD` (the zone-O cover in the no-hole argument;
  without it phase-2 cover degrades to the dissolve alone — still no *regression* vs today). No new
  cross-flag ordering constraints.

---

## 6. Gate plan (`godot/src/tools/verify_structures.gd`, new sections; the existing direct-drive pattern)

The existing gate already drives tier internals directly (`_rebuild`, `_cull_emit`, `_inputs_changed` —
G-ST-HANDOFF/DELTA at :583-630), which is the real code path minus the ring shell hooks. Extend it; both new
gates are **flag-aware** (assert the shipped law when off, the new law when on — the G-ST-GUARD convention),
so the deploy worktree's flipped-flag gate run proves the on-state.

**G-ST-HOLD** — the hold-until-covered floor:
- Synthetic in-band record; camera at `dist = r0 − 20` (inside the floor).
- Flag off: `_cull_emit` returns `false` (shipped floor) — byte-off proof.
- Flag on: probe cache UNKNOWABLE ⇒ emit `true` (HOLD); NOT_COVERED ⇒ still `true` (near said "not here yet");
  COVERED ⇒ next `_cull_emit` returns `false` **immediately** (streak-1); then NOT_COVERED × SHOW_STREAK ⇒
  restored. Swap-ordering assertion: walking a scripted probe sequence UNKNOWABLE→NOT_COVERED→COVERED, the
  model is emitted at every step strictly before the COVERED step — the no-hole ordering pinned as a gate.
- Probe-cap degrade: with `STRUCT_HOLD_PROBE_CAP` forced tiny via > cap records, un-probed records hold
  (emit true), never drop.
- Real-probe leg: wire `_near_query` through a stub world exposing `skin_near_meshed`/`meshed_band_y` (the
  duck-typed NearPresence path, exactly as WorldManager wires it at world_manager.gd:501-505) and flip the
  stub's meshed answer — proves the Callable chain, not just the cache.

**G-ST-STAGE** — the staged drain:
- Synthetic registry of ~8 nearest-first-orderable houses; instrumented sampler that (a) counts calls and
  (b) busy-spins a deterministic ~1 ms per house (so the time box triggers deterministically, no wall-clock
  flake).
- Flag off: ONE `_rebuild` bakes ALL in-band records (`_baked.size() == N` after one call), `_bake_pending`
  never set — byte-off proof.
- Flag on: first `_rebuild` bakes ≥ `STRUCT_BAKE_STAGE_MIN` and < N; `_bake_pending == true`;
  `_inputs_changed(frozen inputs)` returns `true` while pending (re-dispatch law); repeated `_rebuild` calls
  strictly grow `_baked` (nearest-first order asserted via the sampler's per-root first-call sequence) and
  converge: `_baked.size() == N`, `_bake_pending == false`, final merged mesh contains every house's tris
  (compare `live_tris` to the off-flag run — IDENTICAL final mesh).
- **Never-remove invariant:** after house A is baked and committed, force further drain passes (add fresh
  records) and assert A's tris are present in EVERY intermediate commit.
- Cache economy: sampler call count for already-baked houses does not grow across drain passes.
- Budget assertion: with the spin-sampler, each pass's `_dbg_stage_ms_last ≤ STRUCT_BAKE_STAGE_MS + one
  house's spin` (the ≤-budget-per-frame law, allowing the MIN-progress overshoot).

Run: `docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script
res://src/tools/verify_structures.gd` (plus the FLAT `verify_feature.gd` 6042/0 check, both flag states in the
deploy worktree).

---

## 7. Live A/B protocol (the repro NEEDS a village below)

1. **Locate a village first** (the descent must land near one): headless one-shot — walk
   `StructureGen.has_village(vx, vz, GenCtx(0, fid))` over the spawn facet's V-cells (the
   `StructGenIndex.enumerate_facet` loop, struct_gen_index.gd:77-100, is copy-paste) and print the anchor
   column `(vx·192+96, vz·192+96)` + a `house_info` base. Teleport there via the remote bridge / dev-fly,
   confirm houses on screen and `st_live > 0`.
2. **Warm** the session on-surface at the village, then ascend to alt > `ANCHOR_REL_HI` (900) and coast.
3. **Natural de-orbit** back over the same village (retro-burn timed on the ground track; the teleport in
   step 1 pinned the coordinates). Capture 10 Hz telemetry (`frame_ms`, `worst_ms`, `st_pend`, `st_bk`,
   `st_bms`, `st_live`, `objects`, `alt`).
4. **Success criteria:**
   - No descent frame > ~200 ms in the alt 520–600 window (the control run — flags off — reproduces the
     3 555 ms-class wake spike there); `st_bms ≤ ~12 ms` on every drain frame.
   - `st_live` climbs **in steps over several seconds** (staged), not 0 → hundreds in one sample; `st_pend`
     goes true at the wake and false within ~10 s.
   - **The user's repro is fixed:** through the whole approach and touchdown, no house below ever blanks —
     far models persist (`st_live` does not crater to 0 while near meshes are still arriving), then hand off
     house-by-house as near meshing covers them.
   - After landing + settle: near voxel houses present, far models culled (st_live drops as COVERED hides
     them), no lingering far hull inside a near house beyond ~one rebuild step (double-draw check, visual).
   - `objects` may still step at the 609 knee (near re-grow nodes) — expected, not a regression signal.
5. Control corridor: one descent over open ocean (no villages) — both builds should be indistinguishable
   there (the fix must cost nothing where there is nothing to stage).

---

## 8. Out-of-scope follow-ups (noted, not designed)

- `StructGenIndex.records()` duplicates every record dict per step and `_rebuild` re-sorts the full registry
  per step (~600 × lattice_to_world64 × 2 with the probe pass) — a per-step O(N) tax worth a snapshot/epoch
  cache if profiles show it (it is bounded and small next to the bake burst).
- The `FacetFarTrees` zone O→B wake shares the 600 boundary (same-frame ~100–250 ms class); if the A/B shows
  a residual spike there, apply the same drain playbook to its card rebuild.
- `StructGenIndex` crossing enumeration (96-facet walk with column_top stencils) is a separate crossing-tied
  burst — candidate for the same MIN/MS drain if it ever shows in telemetry.
- `STRUCT_BYTES_MAX` (8 MB) can byte-cap the farthest tail of a ~900-house band (pre-existing degrade,
  unchanged by this design; the nearest-first fill keeps it invisible).
