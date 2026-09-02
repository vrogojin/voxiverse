# COSMOS — Card Altitude-Band Extension + Roof-Skin Handoff (design)

Status: **DESIGN — buildable spec** (no code in this doc).
Scope: `FacetFarStructures` card tier (`FP_STRUCT_CARDS`) altitude-boundary defects.
Floor: the shipped cards build (`godot/src/world/facet_far_structures.gd`).
Companion docs: `COSMOS-STRUCT-IMPOSTOR-DESIGN.md` (cards P0), `COSMOS-DEORBIT-STRUCT-STAGING-DESIGN.md`
(FP_STRUCT_NEAR_HOLD / FP_STRUCT_BAKE_STAGE), `COSMOS-FARTREE-ORBIT-DESIGN.md` (the tree shell band this mirrors).

---

## 0. Executive decisions (what to build)

| # | Decision | Mechanism |
|---|---|---|
| D1 | **Cards render to the full 3D distance envelope, `STRUCT_CARD_HIDE_ALT := 2400.0` (= `STRUCT_FAR_MAX`)**, not 600. | New flag `FP_STRUCT_CARD_ALT_BAND` decouples the card zone law from the cube tier's `FT_SHELL_HIDE_ALT=600`. |
| D2 | **The view above is owned by the far-skin roof texels — by flipping `FP_STRUCT_LOD` ON.** It is *not* unimplemented: every consumer already exists (GDScript band/fine bakers, C++ tile-bake patch 0013, palette fix). Zone-O handoff is a **deploy-arm flag flip, no engine rebuild, no new code**. | §2.3, §3.2 |
| D3 | **Buffers stay resident across every altitude boundary** — crossings toggle `visible` + `tier_fade` only. The one violation (the zone-O freeze → single-frame wake resnapshot) is fixed by D4. | §5 |
| D4 | **Staged snapshot + card emit** (`FP_STRUCT_CARD_STAGE`): `_resnapshot`'s per-record precompute is drained over frames into a double-buffered snapshot (old snapshot keeps rendering), with a time/count box and guaranteed convergence — kills the 1136 ms spike. | §6 |
| D5 | **Kill the hidden O(N log N × alloc) sort tax**: `_rebuild`'s `sort_custom` recomputes `lattice_to_world64` per *comparison*; replace with a precomputed-distance key sort (same flag). | §7 |
| D6 | **Top cross-fade**: card `tier_fade` Bayer ramp over `[2000, 2400]`; the roof-skin texels are present at *all* altitudes underneath (overlap-fade for free), plus a wake fade-in ramp on large set entry. | §8 |
| D7 | **Per-instance screen-size cull: REJECTED.** At the 2400 cap a 10-blk house still projects ≈ 3 px (§3.1) — nothing in-band is sub-pixel, so the cull would add complexity for zero benefit. The 3D distance envelope *is* the cull. | §3.1 |

Everything is GDScript + shader. **No stage needs an engine rebuild** (§11).

---

## 1. The two defects (measured / observed)

**Defect A — hard vanish at 600.** `_apply_shell_visibility`
(facet_far_structures.gd:401-437) classifies altitude `h` (= `FacetFarRing.shell_cam_alt()`,
facet_far_ring.gd:3769) into zones at facet_far_structures.gd:409:
S (on-surface), B (`offsurf ∧ h < FT_SHELL_HIDE_ALT`), O (`h ≥ 600`). Zone O sets
`_card_mmi.visible = false` (facet_far_structures.gd:434-435) with the comment "skin owns the
view" — but the served arm never enabled the skin's roof texels (`FP_STRUCT_LOD := false`,
cube_sphere.gd:1298), so villages simply disappear above 600 and pop back on descent.
A 10-blk house at 600 blocks projects ~12 px (§3.1) — very visible when it cuts.

**Defect B — the crossing spike.** Measured `worst_ms ≈ 1136` at alt ≈ 577 with `st_live`
0→603. Root chain:

1. In zone O, `step()` early-returns at facet_far_structures.gd:486-487 (`if offsurf and not
   shell_mode: return`) **before** the REG_EPOCH prelude — the tier is frozen while
   `StructGenIndex._version` (struct_gen_index.gd:28) keeps drifting (orbit crossings →
   `refresh`/`set_active`/`_store` bumps, struct_gen_index.gd:43,51,173).
2. The first zone-B step after the crossing sees `ver != _last_version` and runs
   `_resnapshot(ver)` (facet_far_structures.gd:551-552 → 563-580) **for the whole set in one
   frame**: `records()` materialization (with possible cold `enumerate_facet` village scans on
   cache miss, struct_gen_index.gd:64-66) + per-record `_structure_centre` →
   `lattice_to_world64` + `_precompute_card` (house_info + frame_basis + a second
   `lattice_to_world64`; facet_far_structures.gd:574-579, 589-642).
3. The same frame then runs `_rebuild` (facet_far_structures.gd:517): the `sort_custom`
   lambda (facet_far_structures.gd:863-864) calls `_structure_dist` → `_structure_centre` →
   `lattice_to_world64` (a fresh 3-Variant Array **per comparison** — ~11k calls for N=603),
   then per-record `_cull_emit` (which recomputes `_structure_dist` *again*,
   facet_far_structures.gd:740), 603 × `_write_card_inst`, `set_buffer`, `_commit_mesh`.
4. Descending re-triggers because ascent through 600 re-enters zone O (freeze) and the next
   descent repeats the wake. The cube tier got `FP_STRUCT_BAKE_STAGE` for its analogous
   3555 ms burst (cube_sphere.gd:1361-1375, `_drain_bakes` facet_far_structures.gd:1043-1064);
   **the card path has no staging** — `_drain_bakes` explicitly skips card records
   (facet_far_structures.gd:1052-1053).

**How the trees handle the same boundary** (the pattern to match): `FacetFarTrees` has the
identical three-zone law (facet_far_trees.gd:766-800) and *also* hides at 600
(facet_far_trees.gd:786-792) — but its replacement layer, the fine-map **canopy speckle**, is
live (the un-gated `TreeGen.top_decoration` consult in every skin baker,
facet_tex_baker.gd:1390, 2139, 2167), so trees dissolve into green specks instead of
vanishing. Trees additionally re-arm exactly one rebuild on a zone flip
(facet_far_trees.gd:1072) and slow their zone-B cadence to `FT_SHELL_REBUILD_MS`
(facet_far_trees.gd:845-848). Structures must reach parity — and go further, because cards
are ~4 tris/house (≤ 8k tris worst case): they can afford the whole envelope.

---

## 2. Inventory of existing machinery (read before implementing)

### 2.1 The card tier (all in facet_far_structures.gd)
- Card MMI + material + atlas: `setup_instance` :370-391; `STRUCT_CARD_INST_MAX = 2048`
  instances pre-allocated (cube_sphere.gd:1446), persistent `_card_cbuf` (:59, resized once
  :882-885). Whole-buffer `set_buffer` upload (:921-924).
- Card shader: billboard-on-sphere + azimuth atlas select (:210-262); `tier_fade` Bayer
  dissolve spliced under `FP_STRUCT_SHELL_BAND` (:283-290, Bayer :265-272); per-instance
  `v_fade` = `INSTANCE_CUSTOM.w`, currently constant 1.0 (:979).
- Zone law: `_apply_shell_visibility` :401-437 (card branch :424-435); driven every `step()`
  *before* any early return (:483) — visibility/fade updates are unconditional. Gate hook
  `debug_apply_shell_visibility` :1164-1165.
- REG_EPOCH prelude: `_prelude_epoch` :548-558, `_resnapshot` :563-580, `_precompute_card`
  :589-642 (keyed by root, sort-safe, rebuilt whole per version), O(1)-stationary skip
  :553-555 (version + camera-still `STRUCT_EPOCH_STILL=0.5` + cull-quiet + annulus-empty).
- Delta gate: `_inputs_changed` :654-680 — camera ≥ `STRUCT_DELTA_MOVE=2` (WALK_CALM-gated by
  `_capped/_card_capped`), band-fingerprint drift, reg-count/rev-sum/edits/cover-fp,
  `_cull_pending`, `_bake_pending`.
- Band codes + Schmitt hysteresis: `_band_code` :819-852 (card sub-band code 4 split at
  `STRUCT_CARD_MIN=320`, `STRUCT_HYST_W=8` dead-bands); `_card_split_lo` :952-959.
- Emit: `_rebuild` :859-934 (sort :863-864; card write :892-901; cube cap continue-scan
  :902-915; commit :920-927), `_commit_mesh` :981-990.
- Cube staging precedent: `FP_STRUCT_BAKE_STAGE` drain (`_drain_bakes` :1043-1064, drain
  re-dispatch in `step()` :497-501, commit cadence :867-870, budget consts
  cube_sphere.gd:1373-1375).
- Telemetry: `step_us()` :464, `card_state()` :1121-1124 (`st_ci/st_cq/st_crb_us`),
  `shell_band_state()` :1152-1161, `bake_stage_state()` :1067-1072.

### 2.2 Constants (cosmos/cube_sphere.gd)
`FT_SHELL_HIDE_ALT := 600.0` :1254, `FT_SHELL_FADE_ALT := 520.0` :1255,
`FP_STRUCT_SHELL_BAND` :1359, `STRUCT_FAR_MAX := 2400.0` :1305, `STRUCT_STEP_MS := 250`
:1306, `FP_STRUCT_CARDS` :1444, `STRUCT_CARD_MIN := 320.0` :1445, `OFFSURFACE_Y := 256.0`
:2695, `FP_STRUCT_LOD := false` :1298 (its :1280 comment "declared, unused in P0" is **stale**
— see 2.3), `PLANET_MAP_TEXELS = 64` → **6.5 blocks/texel** whole-planet fine map :902.

### 2.3 The roof-skin (FP_STRUCT_LOD) is ALREADY IMPLEMENTED end-to-end
This is the load-bearing discovery; the flag comment misled the P0 assessment.

| Consumer | Where | Status |
|---|---|---|
| Band-map bake (1 blk/texel, active+ring-1) | facet_tex_baker.gd:1383-1388 — `StructureGen.top_decoration` wins over tree canopy (edit > house > tree > terrain) | **wired, gated on the flag** |
| Fine-map GDScript bake (chunked worker) | facet_tex_baker.gd:2133-2137 | wired |
| Fine-map GDScript bake (untiled) | facet_tex_baker.gd:2161-2165 (with `FP_SKIN_BLOCK_EXACT` texture-mean branch) | wired |
| C++ tile bake (`FP_CPP_TILE_BAKE` path) | `struct_lod` mirrored into the generator config at terrain_config.gd:553-556; the consult + `struct_top_decoration` live in the **already-built** engine — patch `docker/engine/patches/godot_voxel/0013-cosmos-struct-gen.patch` lines 54-56 (config key), 351 (function), 476-478 (roof-pixel consult beside the tree branch) | **in the served binary** (same patch that generates the villages) |
| Palette | far_palette.gd:215-222 — `dark_oak_log` roof steered to BROWN (away from the near-black grey swatch), gated on the flag | wired |
| The oracle | `StructureGen.top_decoration` structure_gen.gd:285-292 — pure, deterministic, ~one hash early-out on non-house columns | shipped |

So "implement the zone-O roof-skin handoff" **costs zero code**: ship `FP_STRUCT_LOD=true` in
the deploy arm (deploy_cheats CS_FLAGS/CLITE_FLAGS, per the byte-off idiom — source default
stays `false`). At 6.5 blk/texel a 10-blk house is a ~2-texel brown speck and a village a
~10-15-texel cluster — the exact analogue of the tree canopy speckle that already owns the
tree view above 600. Residual risk is *bake cost*, not correctness: one extra
`has_village`-hash early-out per skin texel (C++ tile path pays it in the worker; GDScript
band bake on main). Measure with the existing fine-bake timing telemetry in the A/B arm; the
per-texel consult is O(1)-hash-gated by construction (structure_gen.gd:278-285).

---

## 3. D1/D2 — how high do cards render, and what owns the view above

### 3.1 The altitude math
Projected height of an H-blk-tall card at distance d, 1080-px viewport, 75° vfov:
`px ≈ H · 540 / (d · tan 37.5°) ≈ 704·H / d`. For a typical H ≈ 10 house:

| d (blocks) | px | note |
|---|---|---|
| 600 | ~12 | the current hard cut — clearly visible (defect A) |
| 1200 | ~6 | |
| 2000 | ~3.5 | proposed fade start |
| 2400 | ~3 | `STRUCT_FAR_MAX` — the existing 3D distance cap |
| ~7000 | 1 | true sub-pixel — unreachable in-band |

`_rebuild` already drops any record with 3D `dist > STRUCT_FAR_MAX`
(facet_far_structures.gd:887-889), and `_wanted_facets` bounds the registry to the same reach
(struct_gen_index.gd:140-161). So **above alt 2400 the emitted set is empty by construction**
— directly-below houses (dist = alt) are the last to leave, exactly at the cap. Setting the
card hide altitude *equal to* `STRUCT_FAR_MAX` therefore:
- never cuts a card that the distance envelope would still admit (no premature vanish), and
- never renders a card the envelope would cull (no wasted band) —
the altitude law and the distance law coincide, and the in-band card count **shrinks
naturally with altitude** (only the ⌀-2400 sphere cap of ground is in reach), so the tier
gets *cheaper* toward orbit, not dearer.

### 3.2 Decision: hybrid (c), weighted to (a)
- **Cards**: extend the card band to `STRUCT_CARD_HIDE_ALT := 2400.0` with a dissolve over
  `[STRUCT_CARD_FADE_ALT := 2000.0, 2400.0]` (§8). No per-instance screen cull (D7): at the
  cap everything still projects ≈ 3 px, and a Bayer-dithered 2-px card would only shimmer —
  the distance envelope already is a sharper cull than a 1-px test.
- **Above / underneath**: `FP_STRUCT_LOD=true` (roof-skin). The skin texels exist at *every*
  altitude once baked (they're part of the far skin, not an altitude-gated tier), so the
  handoff is an overlap-fade, not a swap (§8).
- **The cube tier is unchanged**: `_mi` keeps the shipped S/B/O law at `FT_SHELL_HIDE_ALT=600`
  (facet_far_structures.gd:410-421). Above ~600 every GEN house is beyond
  `STRUCT_CARD_MIN=320` 3D dist ⇒ card-eligible; the cube sink above 600 would hold only
  player-built + damaged records, and those are represented in the skin via the edit overlay
  (facet_tex_baker.gd:1381-1382) — hiding the cube mesh at 600 stays correct.

---

## 4. The revised zone law (spec)

New flag `FP_STRUCT_CARD_ALT_BAND` (default `false`, byte-off). Requires
`FP_STRUCT_CARDS ∧ FP_STRUCT_SHELL_BAND ∧ FP_STRUCT_REG_EPOCH`; warn at `setup_instance` if
violated (the facet_far_structures.gd:372-374 precedent).

**`_apply_shell_visibility(offsurf, h)`** (facet_far_structures.gd:401-437) — under the new
flag the *card* branch (:424-435) reclassifies independently of the cube zone:

```
card_zone := S  if not offsurf                          # shipped
             B  if h < STRUCT_CARD_HIDE_ALT             # was FT_SHELL_HIDE_ALT
             O  otherwise
zone S: _card_mmi.visible = true,  tier_fade = wake_fade (§8; 1.0 steady)
zone B: _card_mmi.visible = true,  tier_fade = wake_fade · (1 − smoothstep(STRUCT_CARD_FADE_ALT, STRUCT_CARD_HIDE_ALT, h))
zone O: _card_mmi.visible = false                       # true orbit: > 2400, set empty anyway
```
The cube `_mi` branch (:410-421) is untouched (S/B/O at 520/600, shell material swap intact).
Return value: keep returning the cube zone (gates depend on it); expose the card zone via
telemetry (§10) as `st_czone`.

**`step()`** (facet_far_structures.gd:473-501) — the freeze boundary moves with the cards:

- :482 `shell_mode := FP_STRUCT_SHELL_BAND and offsurf and h < _card_live_ceiling()` where
  `_card_live_ceiling()` = `STRUCT_CARD_HIDE_ALT` under the new flag, else
  `FT_SHELL_HIDE_ALT` (byte-identical off). The :486-487 early return then freezes the tier
  only above 2400.
- New cadence const `STRUCT_SHELL_STEP_MS := 500` (the trees' `FT_SHELL_REBUILD_MS`
  precedent, facet_far_trees.gd:845-848): in the extended band (`h ≥ FT_SHELL_HIDE_ALT`) the
  :499 rate cap uses 500 ms instead of `STRUCT_STEP_MS=250` — the view changes slowly up
  there, halve the prelude cadence. (Drain frames still bypass, :498-499.)

**Cost of keeping the tier live to 2400**: the per-step prelude in the extended band is a
probe pass over the cached snapshot with precomputed `_centres`
(facet_far_structures.gd:556, 705-733) — N distance compares, no allocation, µs-scale; the
annulus is empty at altitude so most stationary steps hit the O(1) skip. Rebuilds fire only
on band-fp/version/camera drift and are cheap after §6-§7.

---

## 5. D3 — residency across every boundary (audit + guarantees)

What must be true: **crossing any altitude line toggles `visible`/`tier_fade` only; the
MultiMesh buffer, `_snapshot`, `_centres`, `_card_prec`, `_baked` all survive.**

Audit of the current code (these already hold — preserve them):
- `_apply_shell_visibility` writes only `visible`, `material_override`, `tier_fade`
  (facet_far_structures.gd:410-435). It never clears buffers. ✔
- Zone O never runs `_rebuild` (early return :486-487) and `_card_mm` retains its last
  `set_buffer` + `visible_instance_count` — the descent re-appearance uses the resident
  buffer the moment `visible` flips, *before* any rebuild lands. ✔
- The zone crossing itself is **not** an `_inputs_changed` term (:654-680 — unlike the trees'
  :1072 zone re-arm), so a boundary hover cannot force rebuild churn. ✔ (Do **not** add a
  zone-flip re-arm term; the trees needed it for their card-only band swap — structures keep
  one sink layout across zones.)

The violation and its fix:
- **Wake debt** (defect B): the zone-O freeze accrues version drift that is repaid in one
  frame. Fixed structurally by §4 (the freeze line moves to 2400, where the set is empty ⇒
  near-zero debt accrues below it) **and** by §6 (whatever debt still lands — first entry,
  long orbit, teleport — is drained staged, with the *old* snapshot rendering meanwhile).
- **Guarantee to encode in a gate** (§10 G-ST-RES): drive
  `debug_apply_shell_visibility(true, h)` across 599→601→2399→2401→599; assert
  `rebuild_count()` delta 0, `_card_mm.visible_instance_count` unchanged, and
  `debug_card_buffer()` bytes identical.

---

## 6. D4 — FP_STRUCT_CARD_STAGE: staged snapshot + emit (kills the 1136 ms spike)

New flag `FP_STRUCT_CARD_STAGE` (default `false`). Consts:
`STRUCT_SNAP_STAGE_MS := 2.0` (per-pass time box), `STRUCT_SNAP_STAGE_MIN := 32`
(min records/pass — guaranteed forward progress ⇒ guaranteed convergence; the
`STRUCT_BAKE_STAGE_MIN` law, cube_sphere.gd:1375).

### 6.1 Double-buffered incremental `_resnapshot`
Replace the one-shot `_resnapshot(ver)` (facet_far_structures.gd:563-580) internals, under
the flag, with a drain:

- State: `_snap_next: Array`, `_centres_next: PackedVector3Array`, `_card_prec_next:
  Dictionary`, `_snap_next_rev_sum: int`, `_snap_fill: int` (cursor, −1 = idle),
  `_snap_fill_ver: int`, `_snap_pending := false`.
- **Start** (version drifted, :551-552): materialize `_snap_next = _registry_query.call()`
  in one go (dict duplicates; time it — `st_mat_us`), size `_centres_next`, clear
  `_card_prec_next`, set `_snap_fill = 0`, `_snap_fill_ver = ver`, `_snap_pending = true`.
  Do **not** touch the live `_snapshot/_centres/_card_prec` — they keep rendering.
- **Drain pass** (each step while pending; also every *frame* via the :498 `draining` term —
  extend it to `… or (FP_STRUCT_CARD_STAGE and _snap_pending)`): process records from
  `_snap_fill` forward — `_snap_next_rev_sum += rev`, `_centres_next[i]`,
  `_card_prec_next[root] = _precompute_card(rec, ctx_cache)` (ctx_cache persists across
  passes for the GATE_MEMO hits) — at least `STRUCT_SNAP_STAGE_MIN` records, then stop past
  `STRUCT_SNAP_STAGE_MS`.
- **Swap** (cursor reaches end): `_snapshot/_centres/_card_prec/_snap_rev_sum ←` the `_next`
  buffers, `_last_version = _snap_fill_ver`, `_snap_pending = false`, and force one
  `_rebuild` (return `true` from the prelude). N=603 converges in ⌈603/32⌉ ≤ 19 passes,
  frame-paced ⇒ ~0.3 s; in practice the 2 ms box admits far more than 32/pass.
- **Version re-drift mid-fill**: restart the fill at the new version (drop `_snap_next`);
  the live snapshot still renders. A pathological bump-every-frame source cannot starve the
  swap worse than the shipped path (which would pay the full resnapshot every step).
- **First-ever fill** (`_snapshot` empty): identical flow — the tier simply shows nothing
  until the first swap, then §8's wake fade ramps it in.
- **`_prelude_epoch` interaction** (facet_far_structures.gd:548-558): while
  `_snap_pending`, skip the O(1) short-circuit (like `draining` at :553) and return
  `false` (no rebuild off a half-filled snapshot) *except* on the swap step. The
  O(1)-stationary property for a quiescent registry is untouched — staging engages only when
  the version drifts, which is exactly when the shipped path pays the full cost.

### 6.2 What is NOT staged (and why)
- The `records()` materialization stays one-shot (dict duplicates; typically warm because
  `StructGenIndex.refresh` runs on the WorldManager path each frame,
  struct_gen_index.gd:37-46). It is *timed* (`st_mat_us`); if the A/B shows it hot (cold
  `enumerate_facet` pulls, struct_gen_index.gd:64-66), a follow-up chunks materialization
  per wanted facet — do not build that speculatively.
- The card *write loop* + `set_buffer` (603 × 16 floats + one 128 KB upload,
  facet_far_structures.gd:892-901, 921-924) is µs-to-low-ms — not worth splitting. The spike
  is precompute + sort, not the write.

---

## 7. D5 — the sort/dist fix (same flag, `FP_STRUCT_CARD_STAGE`)

`_rebuild`'s ordering (facet_far_structures.gd:863-864) calls
`_structure_dist → _structure_centre → lattice_to_world64` **per comparison** (~N·log N × a
3-Variant Array alloc — the WASM dlmalloc convoy pattern), and `_cull_emit` (:740) and
`_drain_bakes` (:1049) each recompute it per record. Under the flag:

- In `_rebuild`, when `reg` is the epoch snapshot (`reg.size() == _centres.size()`), build
  `dists: PackedFloat32Array` once from `_centres` (N distance ops, no alloc), argsort an
  index array (`sort_custom` over int indices comparing `dists[i]` — float compares only),
  and thread `dists[i]` into the `dist >` check (:887), `_cull_emit` (add an optional
  pre-computed-dist parameter defaulting to NAN ⇒ shipped self-compute), `_card_eligible`
  (:892), and `_drain_bakes`.
- Ordering may differ from the shipped sort only for exactly-equal keys ⇒ the gate asserts
  **set equality + cap behaviour**, not byte order (§10 G-ST-SORT). Off-flag the shipped
  lambda runs verbatim.

Expected effect: the emit half of the spike drops from O(N log N) lattice evaluations to
O(N) float ops — for N=603 this alone removes several hundred ms on WASM.

---

## 8. D6 — the cross-fade at the top (and the wake fade-in)

- **Top fade**: §4's card zone B drives the existing `tier_fade` uniform
  (facet_far_structures.gd:431-433; shader splice :283-290) with the smoothstep re-anchored
  to `[STRUCT_CARD_FADE_ALT=2000, STRUCT_CARD_HIDE_ALT=2400]`. No shader change — the Bayer
  dissolve, `v_fade × tier_fade` composition, and `FP_STRUCT_SHADER_LITE` guard all apply
  as-is.
- **Overlap**: the roof-skin texels render whenever the far skin renders — under the cards
  throughout the band and alone above it. Card and speck share the same block colour
  (`dark_oak_log` roof via far_palette.gd:215-222), so the dither-out lands *on* a
  same-coloured speck: no colour pop, no gap frame, both directions.
- **Wake fade-in** (paces the *appearance*, complementing §6 which paces the *cost*): when a
  swap (§6.1) raises `_live_cards` by more than `STRUCT_WAKE_JUMP := 64` from a
  previously-empty-or-frozen state, latch `_wake_t0` and let `wake_fade :=
  clamp((now − _wake_t0)/STRUCT_WAKE_FADE_S, 0, 1)` (const `:= 0.7`) multiply the altitude
  term in §4's tier_fade. Driven from `_apply_shell_visibility` (runs every step, :483) —
  no rebuild, no per-instance writes. Descent re-entries with a resident buffer (§5) never
  trip it (`_live_cards` doesn't jump).

---

## 9. Flags, consts, byte-off contract

| Name | Default | Home | Gates |
|---|---|---|---|
| `FP_STRUCT_LOD` | `false` (unchanged; **ship `true` in the deploy arm**) | cube_sphere.gd:1298 — fix the stale ":1280 declared-unused" comment | roof texels in all four bakers (§2.3) |
| `FP_STRUCT_CARD_ALT_BAND` | `false` | new, beside `FP_STRUCT_CARDS` cube_sphere.gd:1444 | §4 zone law + freeze line + cadence |
| `STRUCT_CARD_HIDE_ALT := 2400.0` | — | new const (assert `== STRUCT_FAR_MAX` in the gate; keep them equal by law §3.1) | |
| `STRUCT_CARD_FADE_ALT := 2000.0` | — | new const | |
| `STRUCT_SHELL_STEP_MS := 500` | — | new const | extended-band prelude cadence |
| `FP_STRUCT_CARD_STAGE` | `false` | new | §6 staged snapshot + §7 sort fix |
| `STRUCT_SNAP_STAGE_MS := 2.0`, `STRUCT_SNAP_STAGE_MIN := 32` | — | new consts | |
| `STRUCT_WAKE_FADE_S := 0.7`, `STRUCT_WAKE_JUMP := 64` | — | new consts | §8 |

**Byte-off contract** (the FP idiom): every new const is read only under its flag; with all
new flags `false` the shipped lines run verbatim (`_card_live_ceiling()` returns
`FT_SHELL_HIDE_ALT`; the one-shot `_resnapshot` body and the `sort_custom` lambda are the
untouched code paths). FLAT gate discipline: `verify_feature.gd` flags-off must stay
**6042/0**. `FP_STRUCT_LOD=true` is a *deploy-arm* setting (deploy_cheats CS_FLAGS /
CLITE_FLAGS per [[voxiverse-deploy-cheats-pipeline]]) — the source default does not change.
Interlock: `FP_STRUCT_CARD_ALT_BAND` warns without CARDS+SHELL_BAND+REG_EPOCH;
`FP_STRUCT_CARD_STAGE` warns without REG_EPOCH (staging lives inside the epoch prelude).

---

## 10. Gates + telemetry

Extend `godot/src/tools/verify_structures.gd` (conventions at :93-105 — flag-aware: shipped
law asserted OFF, new law ON):

- **G-ST-CALT** (zone law): with ALT_BAND on, sweep `debug_apply_shell_visibility(true, h)`
  for h ∈ {300, 599, 601, 1500, 2100, 2399, 2401}: `card_mmi_visible()` true through 2399,
  false at 2401; cube `mi_visible()` false from 601 (unchanged law); `tier_fade` read-back
  (add an accessor) equals the §4 formula at 2100/2399. Flag off: card hidden at 601 (the
  shipped cut) — byte-identity.
- **G-ST-RES** (residency, §5): populate via the G-ST-EPOCH fake registry (:32), rebuild
  once, then boundary round-trip 599↔601↔2399↔2401: `rebuild_count()` delta 0,
  `visible_instance_count` unchanged, `debug_card_buffer()` byte-equal, `step_us()` of the
  crossing steps below a small bound (no hidden resnapshot).
- **G-ST-SNAPSTAGE** (§6): seed N≈600 synthetic GEN records, bump the version, drive
  `step()` frames: assert (a) every pass's prelude self-time ≤ box + slack, (b) the live
  snapshot/card buffer is unchanged until the swap step, (c) convergence within
  ⌈N/STRUCT_SNAP_STAGE_MIN⌉ passes, (d) the post-swap buffer is byte-equal to a one-shot
  (flag-off) resnapshot+rebuild of the same registry, (e) a mid-fill version bump restarts
  and still converges.
- **G-ST-SORT** (§7): same set, both flag states: emitted root *set* identical, cap
  (`_card_capped`/`_capped`) identical, nearest-first property holds (every emitted dist ≤
  every skipped-by-cap dist).
- **G-ST-LODSKIN** (roof-skin arm): with FP_STRUCT_LOD on, bake a band/fine tile over a
  known village (the G-SG-SITE locator) and assert ≥1 texel carries the
  `dark_oak_log`-derived palette index; off ⇒ byte-identical tile (the terrain_config.gd:556
  sentinel law). Mirror in `verify_cppgen` if not already covered by G-SG-SKIN-CPP (patch
  0013:350 names it — check before writing a duplicate).
- **verify_fartier_walk.gd**: add an altitude leg (ground → 2500 → ground scripted profile)
  asserting no single step's `step_us()` exceeds the box while st_live goes 0→N→0→N.
- **FLAT**: `verify_feature.gd` flags-off 6042/0 unchanged.

Telemetry (merge into `card_state()` / `shell_band_state()`, {} off-flag as today):
`st_czone` (card zone), `st_cfade` (current tier_fade), `st_snap_pend`, `st_snap_fill`
(cursor), `st_mat_us` (materialize), `st_prec_us` (last drain pass), `st_sort_us` (rebuild
ordering time). These break the "285 ms unattributed" ceiling for this tier and prove the
spike's components in the live A/B.

---

## 11. Build order (cheapest-testable-first) — all GDScript+shader, NO engine rebuild

The only stage that touches C++ semantics (roof-skin) rides patch 0013 already in the served
binary (§2.3); flipping `struct_lod` is config, not compilation.

| Stage | What | Effort | Proves |
|---|---|---|---|
| S1 | Deploy A/B arm with `FP_STRUCT_LOD=true` (zero code; fix the stale cube_sphere.gd:1280/1298 comment) + G-ST-LODSKIN | ~2 h | roof specks own the orbit view; skin-bake cost delta measured |
| S2 | Telemetry split (`st_mat_us/st_prec_us/st_sort_us`) + §7 sort fix under `FP_STRUCT_CARD_STAGE` | ~0.5 d | spike attribution confirmed; emit half of the spike gone |
| S3 | `FP_STRUCT_CARD_ALT_BAND` (§4 zone law + freeze line + `STRUCT_SHELL_STEP_MS`) + G-ST-CALT/G-ST-RES | ~0.5 d | no vanish to 2400; residency proven |
| S4 | §6 staged snapshot + §8 wake fade + G-ST-SNAPSTAGE | ~1–1.5 d | worst_ms at the crossing ≤ ~1 frame budget; ~1 s fade-in |
| S5 | verify_fartier_walk altitude leg + live A/B (ascend/descend profile, worst_ms + st_* counters) | ~0.5 d | the user contract, end to end |

S1 is independently shippable and already removes the *worst* of defect A (vanish-to-nothing
becomes vanish-to-speck at 600); S3 removes the vanish entirely; S2+S4 remove the spike.

---

## 12. Risks / open items

1. **Skin-bake cost of FP_STRUCT_LOD** — one hash-gated consult per texel across all bakers;
   the C++ tile path absorbs it in workers, the GDScript band bake is main-thread. S1's A/B
   measures before anything else builds on it. Mitigation if hot: the consult already
   early-outs on `has_village` (structure_gen.gd:278-285) and GATE_MEMO memoizes the village
   gate per GenCtx [[voxiverse-village-bake-memo]].
2. **`records()` cold-enumeration spike** inside a staged fill (§6.2) — timed, not chunked in
   this design; chunk-per-facet is the named follow-up if `st_mat_us` shows it.
3. **Extended-band rebuild churn**: vertical motion drifts every dist ⇒ band-fp changes near
   the 2400 edge ⇒ rebuilds at up to 1/`STRUCT_SHELL_STEP_MS`. Post-§7 a rebuild is O(N)
   float work + a 128 KB upload — budget ~1-3 ms at 2 Hz. If the live A/B still shows churn,
   widen `STRUCT_HYST_W` for the FAR_MAX edge only (the :838-839 pattern gives it a per-edge
   hook).
4. **`STRUCT_CARD_INST_MAX=2048` headroom**: the widening footprint at alt ~2000 could exceed
   603 — worst case is the ⌀-4800 ground disc's village density. The cap degrades
   nearest-first (:893-895) and `st_cq` reports it; raise to 4096 (adds 128 KB buffer) only
   on evidence.
5. **Fog vs the 2400 edge from altitude**: on-surface the far edge hides in the shared fog
   line (cube_sphere.gd:1305 comment); from 2000+ looking down the fade band (§8) is the
   edge treatment. If the live A/B shows in/out pop at the rim, add a shader-side
   `dist_fade` on `v_fade` — the per-instance slot (:979) is reserved and currently
   constant, so it's a write-only change.
