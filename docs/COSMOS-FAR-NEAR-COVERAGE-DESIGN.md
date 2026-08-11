# COSMOS FAR/NEAR COVERAGE — far-over-near mountain protrusion: root cause + fix design (task #110)

**Symptom (live, user-reported):** on a snowy mountain the FAR smooth grey relief surface draws
OVER the near full-res blocks — the smooth tile wins the depth test across a broad blob and the
real blocks poke through only in dendritic fingers where they rise above it. Repro: facet 578,
NAV `13034,110,8153` (alt 109, backlog 0 — settled) and `13034,73,8153` (alt 71, backlog 1139 —
streaming). Screenshots `fpro-0.jpg` / `fpro-1.jpg`. `smooth_v2_res = 40` (hop 0..4 annulus ⇒
`FP_SMOOTH_V2_NEARFILL` live, as expected post-#107).

**Verdict up front:** the protruding grey surface is the **`FacetOrbitRelief` (G3,
`FP_ORBIT_RELIEF`) mesh — a frozen, still-visible, UN-SUNK on-surface draw** of exact
`profile_at_dir` chords at the DEM's 13-block pitch. It is **pre-existing (PR #39,
2026-08-10), NOT a #107 regression**: the #107 `FP_SMOOTH_V2_NEARFILL` tile was measured
(headless, exact tile law) to sit **strictly below** the fine surface everywhere on the repro
window (worst −4.76 blocks), while the un-sunk G3 chords sit **above** it over 35 % of the same
window — and above the *realized* near block tops (a further 0.6–3.6 blocks lower than the
profile) over roughly half of it. The recommended fix is **not** the user-proposed
near-coverage residency gate on the near-fill tile (wrong target — it would remove the #107
streaming cover and leave the blob untouched); it is **hiding the G3 mesh while on-surface**
(`FP_ORBIT_RELIEF_SURFACE_HIDE`), where by G3's own design contract "the near field + V2 own
that view" (`facet_orbit_relief.gd:613-615`).

---

## 1. Measured facts (headless probes, custom editor; law-level, byte-equal to the live bakes)

Probes (kept in-tree, untracked, the `probe_*.gd` investigator pattern):
`src/tools/probe_nearfill_protrude.gd`, `probe_nearfill_vs_near.gd`, `probe_nearfill_dirmap.gd`,
`probe_orelief_protrude.gd`.

1. **The near-fill interpolation-error hypothesis is FALSIFIED.** The SmoothV2 tile's node law
   (`FarDensity.node_at` ≡ native `bake_smooth_tile`, patch 0012 — point samples of
   `profile_at_dir` at `V2_CELLS = 52` ⇒ 417/52 ≈ 8.02-block pitch, triangle-interpolated per
   `facet_smooth_v2.gd:117-118`) was rebuilt exactly and compared against the fine analytic
   surface at ~1-block pitch across all of facet 578 **and** a dense ±72 window at the repro
   spot: chord-over-fine worst **+1.25 blk facet-wide, +1.38 in the window** — the terrain
   profile is smooth at 8-block pitch. With the `V2_NEARFILL_SINK = 6` uniform radial drop
   (`facet_smooth_v2.gd:92-93`, dispatch wiring `:537`, worker `:586` — wiring verified sound),
   the near-fill surface is **−4.76 blk worst-case below** the fine surface: `0.0 %` of 21 025
   window samples protrude. **The #107 tile cannot be the protruder over resident near mesh.**

2. **The realized near surface sits *below* the analytic profile,** widening G3's margin and
   narrowing (but never closing) V2's:
   - top-face/datum convention: `|lattice_to_world64(578, x, y, z)|` at the repro column maps
     lattice y → radius y − 1.64, so the surface block's top face (lattice g+1) is at radial
     ≈ g − 0.64;
   - SHARP-SLOPE carve caps steep mountain columns in a run with targets `Tw − g ∈ [−3, 4]`
     (`terrain_config.gd:1345-1385`) — carved flank columns realize up to ~3 blocks below g.
   Net: near tops ∈ [g − 3.6, g + ~4] radial. V2-near-fill (≤ g + 1.4 − 6 = g − 4.6) stays
   below even the deepest carve. An **un-sunk** profile-chord surface (≈ g ± 1.4) sits **above**
   the carved/top-face near surface over broad areas.

3. **The direction mappings agree** (`probe_nearfill_dirmap.gd`): `FacetAtlas.cell_dir` (what
   the near gen samples) vs the render placement dir (`lattice_to_world64`) differ by 0.000°
   (≤ 0.1 blk) at centre, repro column, and edge probes; `g(cell_dir) == g(render-dir)`
   (62/62, 98/98). No horizontal warp; near and far sample the same planet. (An earlier −4 vs
   62 anomaly was this worktree's `FACETED := false` default routing `column_profile` to the
   FLAT branch — a headless artifact, not a live effect.)

4. **The G3 orbit-relief mesh is the protruder** (`probe_orelief_protrude.gd`):
   - height law: exact `profile_at_dir` point samples at `GlobalReliefData.CELLS = 32`
     (13.03-block pitch, `global_relief_data.gd:10-47`), interior **accepted at face value —
     un-sunk**; only edges bordering not-yet-committed G3 tiles sink
     (`facet_orbit_relief.gd:276-290` — the file's own comment names this "the SAME class of
     bug FP_ENV_ALL fixed", "bounded-not-eliminated");
   - on-surface behaviour: `step()` returns right after the reap when
     `ring.shell_offsurface()` is false (`facet_orbit_relief.gd:644-645`) — "the resident mesh
     is a frozen, static draw" (`:620`). `shell_offsurface()` = camera radial altitude >
     `OFFSURFACE_Y = 256` (`facet_far_ring.gd:2933`, `cube_sphere.gd:1955`); the repro alts
     109/71 are far below it, so whatever G3 committed on the way in **stays visible,
     un-sunk, forever**;
   - measured over the repro window: chord-over-fine **> 0 for 35.4 %** of samples (mean-over
     +0.50, worst +2.03). Shifted by fact 2 (+0.6 top-face, up to +3.6 on carve columns), the
     G3 surface rides **~0.5–5.6 blocks above the real near block tops over ~half the window**
     — a broad field whose zero-crossing contour is dendritic along ridges: exactly the
     screenshots' blob-with-fingers morphology;
   - colour fingerprint: the blob is FLAT featureless grey. A SmoothV2 tile paints per-8-block
     -cell flat colours from its own bake; a G3 tile whose facet fine-map isn't baked yet falls
     back to the coarse shell vertex colour (`facet_orbit_relief.gd:60, :378, :609`) — a
     uniform grey. Post-teleport (fine map never baked for 578), that is the expected G3 look.

5. **Regression verdict: PRE-EXISTING, exposed — not introduced — by recent work.**
   `FP_ORBIT_RELIEF` shipped live 2026-08-10 (PR #39), before #107/#109. #107 did not touch G3.
   What changed is *exposure*: #109 `FP_SUMMIT_STREAM` made steep snowy summits properly
   streamable/visitable, and the #110 repro is exactly such a summit. (Shot 2's grey underfoot
   with `backlog gen 1139` additionally contains the **designed** #107 near-fill covering
   still-streaming columns — that part is intended and self-heals as blocks land; the settled
   shot 1, backlog 0, isolates the G3 protrusion.)

Caveat, disclosed: this is law-level proof by measurement + elimination (smooth-family tiers:
V2 measured never-above; G3 measured above; old `FP_FAR_SMOOTH` tier off live; far-ring/M2 are
blocky, ruled out by the smooth silhouette). The one live discriminator worth capturing before
implementation: from the repro spot, fly above alt 256 for ≥ 2 s (G3 resumes recompute/commit —
`ORBIT_RELIEF_COMMIT_MS = 500`) and return — the blob geometry should visibly change/heal at
the commit cadence if (and only if) it is G3.

## 2. Why the user-proposed near-coverage gate is the wrong primary fix

"Disable FAR rendering at facets reporting full coverage of NEAR blocks":

- **Granularity:** every far tier here is one mesh per facet (V2: one merged annulus mesh;
  G3: one arena mesh). A facet is ~417 blocks; the near field covers a ≤ 128-block disc plus
  64–112-block pool seam bands (`near_render_radius()`, `cube_sphere.gd:2098`) — **"full facet
  coverage" is structurally never true**, so a whole-facet gate would never fire; a per-region
  mask inside one merged mesh is a per-vertex/per-commit rebuild — cost without benefit.
- **The right per-pixel arbitration already exists: the depth test over a sunk tile.** The
  #107 near-fill is sunk 6 and measured never-above — near blocks win wherever they exist,
  the tile shows only through gaps. That is the user's intent, achieved continuously, with no
  signal, no residency churn, and no re-introduced see-through.
- **Gating the near-fill off on `near_column_meshed()` (world_manager.gd:769-772 →
  `player_column_meshed`, a tight player-column probe) would be both wrong-target** (the
  near-fill is not the protruder) **and unsafe** (it is a player-column signal, not area
  coverage; flapping it would strip the #107 streaming cover exactly when summit streaming
  drops/lags — the #109 failure mode — reopening see-through).
- **For G3 the sound "near coverage" signal at mesh granularity is the regime itself:**
  on-surface (`shell_offsurface() == false`) *is* the state in which the near field + V2 own
  the view — G3's own doc says so (`facet_orbit_relief.gd:613-615`). It is already computed,
  already hysteresis-protected (`OFFSURFACE_Y` crossing), and already consulted by G3 every
  step.

## 3. Fix design

### 3.1 `FP_ORBIT_RELIEF_SURFACE_HIDE` (primary — kills the protrusion)

`const FP_ORBIT_RELIEF_SURFACE_HIDE := false` in `cube_sphere.gd` beside the G3 block
(`:857-862`).

In `FacetOrbitRelief.step()` (`facet_orbit_relief.gd:622`), after the reap loop where `ring`
is already in hand (`:643-645`):

```
var offsurf := ring.shell_offsurface()
if CubeSphere.FP_ORBIT_RELIEF_SURFACE_HIDE and _mi != null:
    _mi.visible = offsurf          # on-surface: hidden; off-surface: shown (frozen tiles intact)
if not offsurf:
    return
```

- **No see-through risk:** the G3 mesh is *redundant* on-surface by construction — underneath
  it the far-ring `FP_FARRING_FULL_COVER` backstop still emits every facet, the V2 annulus
  (hop 2..4) still draws, and post-#107 the V2 near-fill covers hop 0/1. Hiding G3 removes an
  overdrawn duplicate, never coverage. Off-surface (ascent/orbit/descent above 256) G3
  reappears exactly as shipped — its actual job.
- **Frozen-tile warmth preserved:** only `visible` toggles; `_tiles`/arena/bytes untouched
  ("warm for next ascent" contract intact).
- **Byte-off:** flag false ⇒ `_mi.visible` never written, `step()` control flow verbatim.
- Bytes 0; on-surface draws/prims strictly fewer (the arena mesh drops out of the frame).

### 3.2 Optional secondary flag — the user's gate, correctly targeted
`FP_V2_NEARFILL_COVER_YIELD` (design only, NOT recommended to ship first): suppress the hop-0
near-fill tile's *residency* once `near_column_meshed(player_pos)` has been continuously true
for a dwell (≥ EVICT_DWELL_STEPS), re-admitting it the moment the probe drops. Injection:
`FacetSmoothV2._recompute_want` (drop `active` from `_want` under the latch) + a per-step latch
fed from `WorldManager._process` (the `near_column_meshed` route already exists,
`world_manager.gd:769`). Measured basis says this changes nothing visually (the tile is already
below the near mesh) while adding residency churn on a player-column signal; it exists as a
documented fallback should a live A/B ever show the near-fill above near blocks somewhere the
law analysis missed.

### 3.3 Phase 2 hardening (defence in depth, behind its own eyeball)
Apply the `FP_ENV_ALL` min-envelope law to the G3 DEM bake (bake at 64 cells, min-pool 2×2 to
32, −ε) so G3 obeys "rendered ≤ true" in *every* regime including the 256+ descent band. Cost:
×4 bake samples on the already-deferred DEM job (`FP_DEM_DEFER`); zero resident bytes (same
33² i16 grid). Not needed for #110 (at >256 alt the +2-block chord excess is sub-pixel), so
deferred.

## 4. Gate plan (`src/tools/verify_far_near_coverage.gd`, headless)

- **G-FNC-OFF (byte-identity):** flag false ⇒ FLAT `verify_feature.gd` 6042/0 unchanged;
  `FacetOrbitRelief.step()` never writes `visible` (assert the property is untouched across a
  simulated on/off-surface cycle with the flag off).
- **G-FNC-HIDE (ON discriminates):** drive the ring latch across
  on-surface → off-surface → on-surface; assert `_mi.visible` tracks `shell_offsurface()`
  exactly, and `resident_bytes()` / `_tiles.size()` are invariant across the hide (frozen
  warmth kept).
- **G-FNC-LAW (the protrusion pin, from the probes):** on facet 578: (a) every V2
  `build_tile(sink=6)` vertex radius ≤ its column's fine `profile_at_dir` radius (asserts the
  near-fill stays sunk — worst measured −4.76, assert < 0); (b) the un-sunk 32-cell chord
  field has > 25 % of window samples above fine (asserts the G3 discriminator stays
  reproducible, so a future change that silently re-exposes an un-sunk on-surface G3 fails
  loudly).
- **LIVE-EYEBALL-REQUIRED:** repro-spot capture A/B (flag on): blob gone at alt 109/71; snow
  blocks continuous; streaming still covered grey-smooth by the near-fill while
  `backlog > 0` (that cover must remain — it is #107's feature); one ascent past 256 shows G3
  relief return.

## 5. Injection points (exact)

| File | Change |
|---|---|
| `godot/src/cosmos/cube_sphere.gd` | `+ const FP_ORBIT_RELIEF_SURFACE_HIDE := false` (beside `:857-862`) |
| `godot/src/world/facet_orbit_relief.gd` | `step()` visibility gate on `ring.shell_offsurface()` (`:643-645`, §3.1 snippet) |
| `godot/src/tools/verify_far_near_coverage.gd` | new gate (§4) |
| *(optional §3.2)* `facet_smooth_v2.gd` / `world_manager.gd` | near-fill cover-yield latch — design documented, not scheduled |

Residual risks disclosed: (i) `FP_FARRING_UNCOVERED_TRUE` backstop cells emit blocky 27-block
slabs at TRUE height where near-cover detection lags streaming — a *blocky* protrusion class,
visually distinct, out of #110's smooth-grey scope (watch on summits post-fix); (ii) the live
G3-identity discriminator (§1 caveat) should be captured before implementation lands.
