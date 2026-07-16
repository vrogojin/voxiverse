# COSMOS Render Simplify — full-res-256 + far-ring, no near-LOD

**Status:** design (implementation-ready). **Branch:** `fix/voxiverse-crossing-jerkiness`.
**Supersedes at runtime (under the flags):** the FP-M2 near-LOD stack (`FacetLodMesher`
ℓ1/ℓ2/ℓ3) and the `FP_NEIGHBOUR_SEAM_POLISH` apron. Both stay in the tree as dead code
(flag-gated) — nothing is deleted this pass.

## 0. Directive (locked by the user)

Replace the 3-tier near render stack with:

```
full-res voxels 0..256 blocks  (active facet + ridge-banded neighbour(s))
   → existing FarTerrain / FacetFarRing distant horizon  (UNCHANGED)
   → no fog gap
```

REMOVE the intermediate near-neighbour LOD (`FacetLodMesher`) entirely — the user finds
the ℓ1/ℓ2/ℓ3 coarse tiers ugly and misaligned at the seam. KEEP the far-ring horizon (the
"distant blocky hills into low-res horizon" vista). Full 256 is chosen knowing it costs
~4× generation. **NEVER-OOM outranks all of it** (locked user rule): memory safety > visual
quality.

## 1. Flag strategy — TWO flags (recommended)

The two changes are *separable* and have *opposite* memory risk, so they must be
independently gated and A/B'd. Decomposing them is the single most important safety
decision here.

| flag (new `const` in `cube_sphere.gd`) | what it does | memory effect | requires |
|---|---|---|---|
| `FP_NO_NEAR_LOD := false` | bypass/disable the whole `FacetLodMesher` stack; the far-ring quad becomes the sole cover for every non-live facet | **frees 96 MB** (LOD ledger) — memory-SAFE on its own | `FACETED && FP_M1_POOL` |
| `FP_FULLRES_256 := false` | widen the near render radius 128→256, ridge-band + rescale the neighbour pool, raise the pool ceiling into the freed envelope | **memory-RISKY** (this is the whole budget question) | `FP_NO_NEAR_LOD` (it spends the 96 MB the LOD removal reclaims) |

**Why two, not one.** `FP_NO_NEAR_LOD` alone is a pure win — it removes the ugly seam and
*frees* memory, with zero OOM risk. It can ship first and stand on its own (the far ring
already covers what the LOD covered — see §4). `FP_FULLRES_256` is the part that can OOM;
isolating it behind its own flag means the risky change is toggled (and rolled back)
independently, and the byte budget in §5 is the gate on *that* flag alone. Bundling them
would make a memory regression indistinguishable from a seam regression in the A/B.

**Byte-identity (both OFF).** Neither flag is read anywhere unless
`FACETED && FP_M1_POOL` is already on, so with the shipped faceted flags OFF the world is
byte-identical and the **FLAT byte-identity gate stays at its shipped count** (the
`verify_feature`/`verify_faceted` FLAT tally, 6027/0 in-tree today — re-baseline if the
tree has moved). `FP_NEIGHBOUR_SEAM_POLISH` and `FP_M2_LOD` are forced dead whenever
`FP_NO_NEAR_LOD` is on (§2), so there is exactly one live near-cover path at a time.

**Interaction with `FP_M2_LOD`.** `FP_NO_NEAR_LOD` is the logical inverse of `FP_M2_LOD`.
They are mutually exclusive: if `FP_NO_NEAR_LOD` is on, every `if CubeSphere.FP_M2_LOD`
branch must additionally test `and not FP_NO_NEAR_LOD` (or, cleaner, define a single
private helper `_near_lod_on()` in both `world_manager.gd` and `module_world.gd` that
returns `FP_M2_LOD and not FP_NO_NEAR_LOD`, and route every existing `FP_M2_LOD` read
through it). This keeps the removal to a one-line predicate change at each of the ~6 touch
points rather than a scatter of edits.

## 2. Removing the near-LOD cleanly

The LOD stack is *created* in exactly one place and *consulted* from a short, enumerable
set of sites. `FP_NO_NEAR_LOD` disables it at the creation site (so the mesher never
exists) and neutralises each consulted site (so nothing calls a null mesher). Because the
mesher is null when off, most sites already no-op; the work is making the *policy* sites
choose the FP-M1c (single-live-neighbour) path instead of the Z1-hybrid path.

### 2.1 Creation — kill the mesher + its builder thread
- `module_world.gd:1459 _lod_setup()` — gate: return early when `_near_lod_on()` is false.
  `_lod_mesher` stays null; `FacetLodBuilder`'s Thread is never started. This is the whole
  96 MB reclaim — with `_lod_mesher == null` the ledger (`facet_lod_mesher.gd:61-62
  _ledger_bytes`, cap `LOD_MAX_BYTES_MB=96`) never allocates.
- `module_world.gd:1479 _exit_tree()` — already null-guards; no change (shutdown is a no-op
  when `_lod_mesher` is null).

### 2.2 Policy — take the FP-M1c pool path, not Z1-hybrid
- `world_manager.gd:1837-1841 _manage_facet_pool()` — the `if CubeSphere.FP_M2_LOD` branch
  selects `_manage_pool_z1hybrid` + `_lod_promote_pass`. Route the predicate through
  `_near_lod_on()` so with `FP_NO_NEAR_LOD` on it falls to `_manage_pool_fp1c(want)`
  (the shipped single-live-neighbour policy). **BUT** the FP-M1c policy caps live
  neighbours at `POOL_MAX_NEIGHBOURS=4` and has no imminent/prefill notion — for the 256
  crossing we still want the Z1-hybrid *imminent-commit* machinery (it is what makes the
  crossing seamless and is memory-bounded at `FP2_LIVE_CAP=2`). **Recommendation:** keep
  running `_manage_pool_z1hybrid` even under `FP_NO_NEAR_LOD`, and make ONLY its
  LOD-touching calls conditional (see below). i.e. `_near_lod_on()` gates the *mesher
  side-effects*, not the *pool policy*. Concretely, in `_manage_pool_z1hybrid`:
  - `world_manager.gd:1839 _lod_promote_pass(player_pos)` — skip when `_near_lod_on()` is
    false (there is no held LOD cover to evict; the far-ring quad is the cover).
  - `pool_spawn` at `module_world.gd:1657-1658` already null-guards `_lod_mesher`
    (`if _lod_mesher != null: … on_promote`), so the promote-hold handshake self-disables.
    No change needed there — but the WorldManager `_promote_pending` bookkeeping
    (`world_manager.gd:1911`) becomes vestigial; guard the `_promote_pending[t] = now`
    write behind `_near_lod_on()` so the map stays empty and `_lod_promote_pass`'s
    early-out (`if _promote_pending.is_empty(): return`, line 2013) is free.
- `world_manager.gd:2012 _lod_promote_pass` / `module_world.gd lod_evict / lod_end_promote /
  on_promote / end_promote` — all become unreachable (empty `_promote_pending`, null
  `_lod_mesher`). No deletion; they are dead under the flag.
- `demote_pressure_relief` (`facet_lod_mesher.gd:201`) — belongs to the mesher; dead when
  `_lod_mesher` is null.

### 2.3 StreamLoadController surfaces 1–2 (LOD build grants + apply-ms) go idle
The controller (`stream_load_controller.gd`) has three surfaces:
surface 1 = LOD build grants, surface 2 = LOD apply-ms, surface 3 = the pool view-ramp
pace. With `_lod_mesher` null, surfaces 1–2 have no consumer (the mesher's `_run_budgeter`
never runs). **Surface 3 (the ramp pace floor) must stay** — the crossing-jerkiness fix
(`CTRL_IMMINENT_COMMIT_PACE`, `module_world.gd:432/439`) rides on it and is orthogonal to
the LOD. No controller code change is required (it already tolerates a null mesher: the
`relief_only`/`apply_budget_ms`/`grant_count` outputs are simply unread). Leave the
controller wired (`world_manager.gd:290`) so the imminent view-ramp stays paced.

### 2.4 Far-ring exclusion set collapses to pool-neighbours-only
`world_manager.gd:2039 _facet_ring_sync_exclusion()` merges live-pool fids ∪
`lod_covered_fids()`. With `_near_lod_on()` false, `lod_covered_fids()` returns `[]`
(`module_world.gd:1484`), so the merge reduces to the shipped pool-neighbour exclusion —
which is exactly what we want (the far ring draws every facet that is neither active nor a
live pool neighbour). Route the `if CubeSphere.FP_M2_LOD` at `world_manager.gd:2048`
through `_near_lod_on()`; no other change.

### 2.5 What the far ring must do to cover the gap the LOD leaves
**Confirmed:** the `FacetFarRing` already renders behind everything and is the universal
fallback. It is a whole-planet coarse mesh (`CELLS=4` heightmap cells per facet edge,
`facet_far_ring.gd:19`) parented under `PlanetRoot`; `_front_visible(fid)`
(`facet_far_ring.gd:130-136`) draws a flat terrain-coloured quad for **every
front-hemisphere facet except the active facet and the excluded set** (live pool neighbours
∪ — today — LOD-covered). Removing the LOD simply shrinks the excluded set back to
live-pool-neighbours; every facet the LOD used to mesh now shows its far-ring quad instead.
**No horizon gap is created** by the removal — the far ring was always behind the LOD
(`world_manager.gd:1740-1743` re-places it every crossing).

**The one real coverage question is the active facet's own outer region.** The far ring
*excludes* the active facet entirely (`facet_far_ring.gd:131-132` — "the near voxel world
already covers the active facet"). A facet edge is ≈417 blocks (BODY_N 10016 ÷ K 24), so
its centre-to-corner is ≈295 blocks. The near field at radius R covers a disk of radius R
about the *player*; standing mid-facet, the four corners (≥208, up to 295) fall outside
even R=256. Today at R=128 that outer annulus is covered by nothing on the active facet —
it works only because those columns sit below the fogged horizon / are back-faced by the
facet tilt. Widening to 256 shrinks the uncovered annulus but does not eliminate it.

**Recommendation (no-hole guarantee, ~0 memory):** under `FP_FULLRES_256`, stop excluding
the active facet in `_front_visible` and draw its coarse quad as a **backstop**, sunk
`ACTIVE_BACKSTOP_SINK` blocks radially inward (e.g. 1.5 blocks) so it sits strictly *behind*
the opaque near voxels and can never z-fight them. Cost: one extra quad in an
already-built whole-planet mesh (negligible bytes, no per-frame cost). This guarantees no
hole for *any* near radius and is validated by the no-hole gate (§6). If field testing
shows R=256 already covers the reachable active facet (player never stands far enough from
every edge to expose a corner), the backstop is harmless.

## 3. The 256 widening

### 3.1 Constants
- `terrain_config.gd:129 CURVED_RENDER_RADIUS_BLOCKS := 128 → 256` **only under
  `FP_FULLRES_256`.** Do NOT change the const literally (that would move the curved/faceted
  radius unconditionally and break byte-identity when the faceted flags flip on without
  `FP_FULLRES_256`). Instead make `near_render_radius()` (`terrain_config.gd:138`)
  flag-aware:
  ```gdscript
  static func near_render_radius() -> int:
      if CubeSphere.FLAT_WORLD and not CubeSphere.FACETED:
          return RENDER_RADIUS_BLOCKS                       # 256, byte-identical flat
      if CubeSphere.FP_FULLRES_256:
          return FULLRES_256_RADIUS_BLOCKS                  # new const = 256
      return CURVED_RENDER_RADIUS_BLOCKS                    # 128, shipped faceted
  ```
  Every consumer already routes through `near_render_radius()` (the active init
  `module_world.gd:1619`, the crossing target `:1705`, `pool_spawn` prefill `:1652`, the
  viewer `attach_viewer`), so this one function is the single widening lever.
- `POOL_IMMINENT_PREFILL_BLOCKS` (`cube_sphere.gd:197`) is already `minf(…,
  near_render_radius())`-clamped at the spend sites, so it auto-tracks to 256. **But** a
  full-256 imminent prefill is a budget breach (§5) — cap the imminent prefill at a band
  (see §3.3), not the full radius.
- `POOL_D_WARM` (`cube_sphere.gd:71`, 96) and `POOL_D_WARM2` (48) — rescale up under the
  flag (see §3.2).

### 3.2 Pool policy rescale (D_WARM / spawn / retire)
At R=128 a neighbour spawned at ridge-distance 96 was live full-res before the player could
see coarse quads across the seam. At R=256 the player sees ~256−d blocks *into* the
neighbour when standing d from the ridge, so the coarse far-ring quad would appear much
closer (ugly up close). Raise the warm shell so the neighbour's full-res band is up before
the coarse quad is visible at close range:
- `POOL_D_WARM`: 96 → **160** under `FP_FULLRES_256` (spawn the neighbour ≈160 blocks out).
- `POOL_D_COMMIT` (`cube_sphere.gd:156`, 64): keep — the commit band is a crossing property,
  not a view-radius property; 64 blocks of geometric commit is still ~6 s of lead at walk
  speed. (Optionally bump to 96 for extra prefill lead; not required.)
- `POOL_D_RETIRE` (128) → **192** (keep the 32-block hysteresis above the new D_WARM).
- `POOL_D_WARM2` (48, corner-second) → **80**.
- `FP2_LIVE_CAP=2` stays (1 imminent + 1 corner-second). **This cap is the NEVER-OOM
  backstop** — never raise it under this flag.
- `POOL_MAX_NEIGHBOURS=4` stays as the FP-M1c hard cap (only relevant on the flag-off path).

Spawn/retire cadence (`POOL_SPAWN_INTERVAL_S=1`, `POOL_MIN_LIVE_S=10`) unchanged — still
≤1 spawn + ≤1 retire per second, anti-thrash preserved.

### 3.3 Far-ring inner radius / fog re-tune (no seam, no double-draw)
The faceted `FacetFarRing` has **no near "inner hole" radius** — it draws whole-facet
quads and relies on exclusion, so widening the near field needs **no inner-radius change**
on the ring itself (unlike the non-faceted `FarTerrain.INNER_HOLE_CURVED=112`, which is not
used in faceted mode). The seam is handled purely by exclusion + the backstop sink:
- Active facet: near-256 voxels in front, coarse backstop quad behind (§2.5) — no gap.
- Neighbour (live): ridge-banded full-res in front (out to the band edge), far-ring quad
  behind it from the band edge outward. The band edge is ≥128 blocks into the neighbour
  (§3.4), so the coarse quad first appears ≥128 away — reads as "distant", matching the
  user's intended horizon.
- Fog: `FacetFarRing.FOG_BEGIN=2200`, `CAMERA_FAR=9000` (`facet_far_ring.gd:22-23`) are
  planet-scale and already far beyond 256 — **no fog re-tune needed**; there is no fog in
  the 0..256 near band, hence "no fog gap" by construction. Do NOT import the non-faceted
  `FarTerrain.FOG_BEGIN=115` (that path is inactive in faceted mode).

## 4. NEVER-OOM byte budget (load-bearing)

### 4.1 Envelope reclaimed
Today's live memory envelope: pool `POOL_MEM_BUDGET_MB=128` + LOD ledger
`LOD_MAX_BYTES_MB=96` = **224 MB**. `FP_NO_NEAR_LOD` frees the 96 MB LOD ledger, so the
whole 224 MB can back the full-res pool. **Raise `POOL_MEM_BUDGET_MB` to 224 under
`FP_FULLRES_256`** (the reclaimed envelope), and add per-terrain geometric caps below.

### 4.2 Byte density anchor (measured, in-tree)
From the §10 ledger anchors (`module_world.gd:82-84`): active = 40 MB @ view128
(bounds-clamped); neighbour = 18–20 MB @ view96. Bytes scale with **horizontal disk area
only** (vertical is slab-clamped y∈[−64,116] ≈184 blocks; at ±64 the reach already hits
bedrock, so widening horizontal adds nothing vertically). Density ≈ 40 MB / (π·128²) ≈
**0.81 KB per horizontal column**. This is the multiplier used below; every figure is the
*unclamped disk* worst case (facet + ridge-band clamping strictly reduces it).

### 4.3 Whole-facet 256 does NOT fit — the verdict

| live terrain | region (unclamped) | columns | bytes | notes |
|---|---|---|---|---|
| active @256 disk | π·256² | 205,887 | **160 MB** | 4× the shipped 40 MB @128 — matches the ground-truth 4× |
| imminent @256 disk | π·256² | 205,887 | **160 MB** | if prefilled whole-facet |
| corner-second @256 | π·256² | 205,887 | 160 MB | — |

Worst-case whole-facet sum (active + imminent + corner) = **480 MB ≫ 224 MB**. Even active
+ imminent alone = 320 MB. **Whole-facet 256 on the neighbours overflows the envelope by
>2×. Ridge-banding the neighbours is REQUIRED.**

### 4.4 Ridge-banded neighbour scheme (what makes it fit)

A neighbour never needs a full 256 disk — the player only sees the band near the shared
ridge, and the far part of the neighbour is horizon (far-ring quad). So the neighbour
terrain's `bounds` is clamped to **(its facet slab) ∩ (a band of width `W_BAND` measured
from the shared ridge)**, extending the existing `_apply_bounds` (`module_world.gd:1446`,
the exact hook — it already writes the facet-slab AABB; intersect it with the ridge band
for a non-active pool member). The band spans the full ridge length (417) × `W_BAND` deep ×
slab (184):

| live terrain | region | columns | bytes | cap const |
|---|---|---|---|---|
| active @256, **facet-clamped** to the 417 edge | disk ∩ 417² square | ≈150,000 | **≈122 MB** | `POOL_ACTIVE_MEM_BUDGET_MB_256 := 160` (unclamped ceiling) |
| imminent, ridge-band `W_BAND=128` | 417 × 128 (∩ 256 half-disk) | ≈53,000 | **≈43 MB** | `POOL_NB_BAND_MEM_BUDGET_MB := 48` |
| corner-second, ridge-band `W_BAND2=64` | 417 × 64 | ≈27,000 | **≈22 MB** | `POOL_NB_BAND2_MEM_BUDGET_MB := 24` |

**Two regimes bound the real total (they never co-peak):**
- **Mid-facet (player >D_WARM from every ridge):** active = up to the full 160 MB (the
  unclamped-disk ceiling), and **zero neighbours are live** (nothing within D_WARM). Total
  ≤ **160 MB ≤ 224.** ✓
- **At a ridge (crossing / corner):** the active disk is clamped to *its* side of the ridge
  (bounds stop at the shared edge) → active ≈ half-disk ≈ **≤122 MB**; imminent band ≤48;
  corner-second band ≤24. Total ≤ **122 + 48 + 24 = 194 MB ≤ 224.** ✓

**Crossing seamlessness at 256 without a full-256 prefill.** The imminent is prefilled only
to its `W_BAND=128` band, not to 256. After the crossing, the new active ramps
128→256 at **full pace** during the settling window — this is exactly the
`CTRL_IMMINENT_COMMIT_PACE=1.0` full-pace ramp the crossing-jerkiness fix (commit 7efcea0)
already installed; the residual 128→256 annulus is *spread* across ~1.5 s (RAMP_SECONDS),
never a seam burst. So banding the imminent costs no crossing hitch.

### 4.5 The hard NEVER-OOM ceiling (asserted on REAL bytes, not geometry)
The regime argument above justifies *why* the ceiling is rarely approached; it does not by
itself *guarantee* it (a pathological camera / edit could inflate a mesh). The guarantee is
a **real-bytes pool ceiling checked at spend**, mirroring the existing
`_gate_cap_real_spend` / `_enforce_caps_after_spend` pattern the LOD mesher uses
(`verify_fp_m2.gd:414`, `facet_lod_mesher.gd:425` — evict non-wanted LRU until the *actual*
ledger is back under the cap):
- Sum the live terrains' **measured** bytes (`pool_bytes` per slot; the honest ramp value,
  not the target — `module_world.gd:1841` already exposes the honest live bounds/view).
- On any spawn/ramp step, if `Σ measured > POOL_MEM_BUDGET_MB(224)`, **deny the newest
  neighbour promote and hold it as a far-ring quad** (never grow it live). A denied
  neighbour is drawn by the far ring (already its fallback) → **no hole, no OOM.**
- Assert headless: after a spawn storm at R=256, `Σ measured ≤ 224 MB` AND every denied
  facet is absent from the live set but present in the far-ring draw set (the exact
  "no-hole on denial" invariant `verify_fp_m2.gd:363-370` already checks for the LOD caps).

This makes memory safety a *materialized-bytes* invariant, not a hand-wave.

## 5. Gate + validation plan

Extend the faceted verify suite (a new `verify_render_simplify.gd`, sed-toggling
`FP_NO_NEAR_LOD`+`FP_FULLRES_256` true like `verify_fp_m2` toggles `FP_M2_LOD`):

- **G-RS-IDENTITY (flag-off byte-identity):** with both new flags OFF, the FLAT gate tally
  is unchanged from shipped (`verify_feature`/`verify_faceted`), and the faceted pool gate
  count is unchanged. Proves the default build is byte-identical.
- **G-RS-NOLOD (removal):** with `FP_NO_NEAR_LOD` on, `_lod_mesher` is null,
  `FacetLodBuilder` thread not started, `lod_covered_fids()==[]`, and the far-ring excluded
  set == live-pool-neighbours only. `_promote_pending` stays empty over a walk.
- **G-RS-MEM256 (the memory ceiling — the load-bearing gate):** with `FP_FULLRES_256` on,
  drive the pool through the mid-facet regime (active alone) and the at-ridge regime
  (active + imminent + corner-second), and assert `Σ measured bytes ≤ POOL_MEM_BUDGET_MB
  (224)` at every step; then a spawn-storm and assert the real-bytes ceiling binds
  (deny→far-quad, no hole). Assert each neighbour's `bounds` ⊆ (facet slab ∩ ridge band)
  and its measured bytes ≤ its band cap.
- **G-RS-NOHOLE (far-ring covers the gap):** every non-active, non-live-pool facet is in
  the far-ring draw set; the active-facet backstop quad is drawn and sunk (no z-fight:
  assert its radial offset < 0 vs the near surface). Sample a ring of directions across the
  active↔neighbour seam and across the neighbour band edge → every direction hits either
  near voxels, a live-neighbour mesh, or a far-ring quad (no empty direction).
- **G-RS-CROSS256 (seamless crossing at 256):** cross a ridge; assert `redesignate` is a
  pool HIT (no restream), the post-crossing new-active view ramps 128→256 at full pace
  (`CTRL_IMMINENT_COMMIT_PACE`), and the crossing frame requests zero *new* generation
  beyond the spread annulus.

**A/B live.** Ship in two independent flips (the established sed-at-export pattern):
1. `FP_NO_NEAR_LOD` on first (frees 96 MB, removes the ugly seam) — validate browser-heap
   ↓ and the seam gone via the remote-telemetry loop.
2. Then `FP_FULLRES_256` on — validate browser-heap stays ≤ the 224 MB envelope and the
   worst-frame is acceptable, over the live real-GPU remote session.

## 6. Sequencing + risk (ordered, each flag-gated + independently testable)

1. **Add both flags** (`cube_sphere.gd`, default false) + the `_near_lod_on()` helper +
   the flag-aware `near_render_radius()` and new radius/cap consts. No behaviour change
   (both off) → G-RS-IDENTITY green. *Risk: none.*
2. **`FP_NO_NEAR_LOD` removal wiring** (§2): gate `_lod_setup`, the policy LOD side-effects,
   the far-ring merge. Ship-able alone. → G-RS-NOLOD green; frees 96 MB. *Risk: low —
   memory only decreases; far ring already covers.*
3. **Widen to 256** (§3.1): flag-aware `near_render_radius()=256`. → active facet renders to
   256; neighbours still whole-facet (temporarily over budget — DO NOT flip on live yet).
   *Risk: memory — contained by step 4 before any live flip.*
4. **Ridge-band + rescale + real-bytes ceiling** (§3.2, §4.4, §4.5): extend `_apply_bounds`
   for the band, rescale D_WARM/D_RETIRE/D_WARM2, raise `POOL_MEM_BUDGET_MB=224`, add the
   spend-time ceiling + deny-to-quad. → **G-RS-MEM256** is the gate that unblocks the live
   flip. *Risk: HIGH (memory) — isolated here, gated by the materialized-bytes assert.*
5. **No-hole backstop** (§2.5): draw the sunk active-facet quad. → G-RS-NOHOLE green.
   *Risk: low (z-fight — controlled by the sink; asserted).*
6. **Crossing at 256** (§4.4): confirm the imminent band + full-pace post-crossing ramp is
   seamless. → G-RS-CROSS256 green. *Risk: low — rides the landed jerkiness fix.*

**Superseded/retired under the flags:** the FP-M2 near-LOD (`FacetLodMesher`,
`FacetLodBuilder`, the promote/demote/apron handshake) and `FP_NEIGHBOUR_SEAM_POLISH` are
dead code while `FP_NO_NEAR_LOD` is on — kept in-tree, deleted only after the two-flip A/B
proves the new stack in production. The just-merged seam polish and FP-M2 LOD are both
retired by design here, not by deletion.
