# COSMOS — Far-Ring Shell Vertex Diet (task #129, "the real forest-fps MEDIAN unlock")

**Status: DESIGN ONLY — no code changes.**
Branch `deploy/perf-plus-sky` (deploy worktree); all live values below are **served-pck-verified**
(`load_resource_pack("build/web/index.pck")` + `get_script_constant_map`, run 2026-08-14 against the
pck deployed 2026-08-14 21:44).

---

## 0. Verdict up front — the premise needs one correction

The task frames the 489 k-vert shell as "the FP_FARRING_FULL_COVER **dense backstop**". The
accounting below shows the dense backstop (the ≤ 17 facets emitted at `BACKSTOP_CELLS = 16`,
`cube_sphere.gd:334`) is only **~10–16 %** of the 489 k. The dominant term (~84–90 %) is the
**coarse `CELLS = 4` front *hemisphere*** (`facet_far_ring.gd:19`), wall-expanded ×3.5 by
`FP_BLOCKY_FARRING` (live **true**), emitted in full **while the player stands on the surface**
because of one line:

```
facet_far_ring.gd:1228   theta_emit = maxf(theta_emit, deg_to_rad(90.0))   # surface floor
```

The camera-set shell law (`shell_set_camera_abs`, `facet_far_ring.gd:1217`) already computes an
altitude-correct visible cap θ_emit = θ_h + `SHELL_RELIEF_DEG` + `SHELL_SLACK_DEG`
(`cube_sphere.gd:2548-2550`) — but on the floored surface it is overridden to the full 90°
hemisphere ("keep the shipped hemisphere while near tiers are live", a byte-visual-identity
conservatism from the S1 shell work, not a correctness need). From eye height ~2 blocks on a
planet of R = 6371 the geometric horizon is ~1.4°; even granting max terrain relief
(112 blocks, `terrain_config.gd:275-278`) at both ends, nothing beyond **~23°** angular distance
can ever be visible — yet ~1716 facets (~90°) are emitted, ~89 % of them provably below the
horizon.

**So the correct diet is an emitted-set cap on the surface (P0), with the dense-backstop
decimation as a secondary rung (P1).** A pure `BACKSTOP_CELLS` diet alone would cut ≤ 16 % of
the verts and would NOT move the median.

---

## 1. Root cause of the 489 k — measured + derived

### 1.1 Where the number comes from (it is a REAL vertex count, not an estimate)

- The forest capture's `farring build_ms 1093 / verts 489k` event is an **async** event:
  `_swap_in_arrays` pushes the **actual** `ARRAY_VERTEX` size
  (`facet_far_ring.gd:2317-2349`, `_push_event("async", …, verts)` at `:2349`,
  `verts = (arrays[Mesh.ARRAY_VERTEX] …).size()` at `:2323`). The sync event, by contrast, pushes
  the smooth-path *estimate* `tris*3` (`:3025-3034`) which under-counts blocky walls — trust the
  async number.
- 489 k verts (SurfaceTool tri-soup after `generate_normals`, non-indexed) = **163 k triangles**.

### 1.2 Per-facet triangle budget under the live flag set

Served flags (pck dump): `FP_FARRING_FULL_COVER=true`, `FP_BLOCKY_FARRING=true`,
`FP_MID_DENSE=false`, `FP_FARRING_LIMB_DENSE=false`, `FP_FARRING_CULL_COVERED=false`,
`FP_SMOOTH_V2_EXCL_BLKLOD=false`, `FP_TIER_STICKY_BACKSTOP=true`, `FP_SHELL_CAMERA_SET=true`,
`FP_FACET_TEX=true`, `FP_BLOCKY_TEX=true`.

`_emit_blocky` (`facet_far_ring.gd:4153-4245`) emits per grid cell: a flat top (2 tris), one
wall per internal edge when the corner-radius step exceeds 0.01 (2 tris each,
`_emit_wall :4247-4268`), and unconditional boundary/edge skirts. Worst case:

| facet kind | cells | tops | internal walls | boundary+edge skirts | tris (max) | verts (max) |
|---|---|---|---|---|---|---|
| coarse (`CELLS=4`) | 16 | 32 | 2·(3·4)·2 = 48 | 16 + 16 | **112** | 336 |
| dense backstop (`BACKSTOP_CELLS=16`) | 256 | 512 | 2·(15·16)·2 = 960 | 64 + 64 | **1600** | 4800 |

### 1.3 How many facets of each kind

- **Coarse:** on the floored surface `_cull_params()` returns cos(θ_emit) with the `:1228` 90°
  floor ⇒ `visible_fids()` (`:3051`) passes the whole front hemisphere — "~1716 dirs"
  (comment `:615`). Smooth-tile emit-exclusion is dead live: `_smooth_covered` (`:3049`) reads
  the legacy `_smooth` (null; FP_FAR_SMOOTH lineage), and `FP_SMOOTH_V2_EXCL_BLKLOD` is false —
  so facets under resident SmoothV2 tiles are STILL in the shell (by design: no-black backstop).
- **Dense:** `_is_backstop` (`:2466-2473`) = active ∪ `_excluded` ∪ `_sticky`. Live,
  `_excluded` = pool neighbours ≤ `POOL_MAX_NEIGHBOURS=4` (`world_manager.gd:3372-3399`;
  the `lod_covered_fids` merge is short-circuited by `FP_NO_NEAR_LOD=true`), and the sticky set
  is ring-1 + `STICKY_HOLD=2` recently-active, hard-capped at `STICKY_RING1_MAX=12`
  (`_recompute_sticky :2968-2987`, `cube_sphere.gd:424-425`). So **9–17 dense facets**.

### 1.4 The books balance

Worst-case model: 1716·112 + 17·(1600−112) = **217 k tris = 652 k verts**. Measured 489 k = 75 %
of worst case — the gap is exactly the `|Δr| ≤ 0.01` wall skip on flat cells (ocean/plains).
Decomposition of the measured 489 k:

| component | verts | share |
|---|---|---|
| coarse blocky front hemisphere (~1700 facets) | ~410–445 k | **~84–90 %** |
| dense backstop (9–17 facets @ 16²) | ~40–78 k | ~10–16 % |

### 1.5 Steady-state, not rebuild — this is what sets the MEDIAN

The shell is ONE `MeshInstance3D` (`_mi`, created `:561`) with ONE surface; the mesh persists
between rebuilds and is **submitted every frame**. The forest capture had **zero**
`type:"farring"` rebuild events in the whole window (COSMOS-FOREST-FPS-DESIGN.md §2 table,
line 130) yet the ~709 k prims/frame — including this 489 k-vert shell — were constant
(§3 table, line 148). CALM (#123) removed the re-emit churn (the swap/upload spikes); the median
is set by the steady-state per-frame cost of the standing geometry: GPU vertex processing of
489 k verts through the vertex-color+tex material with `cull_mode = CULL_DISABLED`
(`:5267-5268`, double-sided rasterization). CPU submit is one draw call — cheap; the diet's
per-frame win is GPU-side, which is why §8 gates the fps claim on the visibility probe.

Secondary (spike-side) costs that also scale with the vert count and that the diet cuts ~4-5×:
the async worker build (1093 ms of worker occupancy per re-emit), the main-thread
`add_surface_from_arrays` upload at swap (~27 MB: 489 k × ~56 B/vert with pos+normal+col+uv+uv2
under FP_FACET_TEX/FP_BLOCKY_TEX), and every `visible_fids()`/warm scan (~1716 iterations).

---

## 2. The diet — P0: FP_SHELL_SURF_CAP (surface horizon-cap emitted set)

### 2.1 Design

Replace the 90° surface floor with a **horizon-derived surface cap**, behind a new flag:

```gdscript
# cube_sphere.gd (new)
const FP_SHELL_SURF_CAP := false   # surface emitted-set cap: horizon + relief instead of the 90° hemisphere
const SHELL_SURF_CAP_DEG := 29.0   # √(2·116/R)≈11° max-relief limb poke + 15° slack + ~3° facet-centre slop
```

```gdscript
# facet_far_ring.gd:1227-1228 (the only functional change)
if floored:
    if CubeSphere.FP_SHELL_SURF_CAP:
        theta_emit = maxf(theta_emit, theta_h + deg_to_rad(CubeSphere.SHELL_SURF_CAP_DEG))
    else:
        theta_emit = maxf(theta_emit, deg_to_rad(90.0))       # shipped surface floor (byte-identical)
```

Everything else — the drift/Δθ_h re-emit triggers, `_shell_snapshot`, the async pipeline, warm
ordering, `_front_visible`'s facet-centre test — is untouched; the cap simply flows through the
existing `_cull_params()` → `visible_fids()` machinery (`:1912-1915`, `:3051-3084`).

### 2.2 Why the cap is sound (no-see-through invariant, analytically)

A surface point at height H is visible from a camera at distance d from the centre iff its
angular separation ≤ acos(R/d) + acos(R/(R+H)). The law already carries acos(R/d) = θ_h
exactly (`:1218`); the worst H = 112 (+4 margin) blocks (`terrain_config.gd:275-278`) gives
acos(R/(R+116)) ≈ 10.9°. The cap adds 11° + 15° slack + ~3° half-facet slop = 29° on top of
θ_h, so **every geometrically visible facet is inside the cap with ≥ 15° to spare** — at every
standing altitude (climbing a 112-block peak raises θ_h to 10.7° and the cap follows), and the
existing |Δθ_h| > 5° trigger (`:1238`/`:1265`) re-emits on large standing-height changes exactly as it
does off-surface today. Facets beyond the cap are below the planet's own limb from every
sight-line — removing them exposes nothing (the horizon silhouette line is unchanged; behind it
was already sky).

Consistency check: the far-tree card band reaches 2400 blocks ≈ 21.6° — the peak-to-peak
visibility bound (2·√(2·112/R)·R ≈ 2400 blocks) that band already assumes. The cap (θ_h + 29°)
strictly contains it.

### 2.3 What it saves

Cap at sea level ≈ 30°: (1−cos 30°)/2 · 3456 ≈ **~230 facets** (vs ~1716). On a 112-block
summit ≈ 40° ⇒ ~400 facets.

| regime | tris | verts | vs live 489 k |
|---|---|---|---|
| sea-level forest (230 coarse·~85 avg + 17 dense·~1500) | ~45 k | **~135 k** | **−72 %** |
| 112-block summit (~400 coarse) | ~60 k | ~180 k | −63 % |
| off-surface / orbit | unchanged (cap law already active there) | | 0 |

Re-emit build: 1093 ms worker → ~250 ms; swap upload ~27 MB → ~7 MB; warm/scan loops ~1716 →
~230 iterations.

### 2.4 Considered alternatives from the task brief

- **(a) distance-LOD the backstop grid / (b) coverage-gated resolution / (c) one merged coarse
  shell:** all attack the dense 10–16 % share first — wrong lever for the median (§1.4). (c)
  additionally re-opens the per-facet weld problem (`_env_weld_grid :3819`) for no draw-call win
  (it is already one surface/draw).
- **(d) emit backstop only on the uncovered annulus:** this per-cell machinery **already
  exists** — U2 `FP_FARRING_CULL_COVERED` (`:2648-2726`, `_cull_mask`/`_committed_cull`
  `:398-400`), served **false**. It is the natural P1, not P0 (below).
- **Smooth-instead-of-blocky beyond ring-N** (drop walls, 112→32 tris/facet): valid, but after
  P0 the coarse share is ~45 k verts — not worth a second emit mode + weld seam risk. Rejected.

## 3. P1 (optional second rung, dense side): turn on the existing U2 cull

After P0 the dense backstop (~50–80 k verts) is the largest single term.
`FP_FARRING_CULL_COVERED` culls confirmed-covered dense cells at emit (`_emit_blocky :4183`,
`_append_backstop_tris :4116`) with a streak/verdict state machine that CALM (#123) already
hardened on the sink side (COSMOS-APPLIED-PROBE-CALM-DESIGN.md; the `_cull_streak`
COVERED-confirmation is the same coverage probe family). In a settled forest most of the active
facet's 256 cells are near-mesh-covered ⇒ expected dense share ~70 k → ~15–25 k verts. **Own
A/B, own decision** — the historical caution stands (the 2026-08-13 CALM R2 finding was that an
earlier cull-blaming verdict was a served-flag mis-pin; and a wrong COVERED verdict here is a
see-through hole, exactly what FULL_COVER exists to prevent). Do not couple it to P0. A
`BACKSTOP_CELLS` 16→8 demotion for **sticky-only** facets is the fallback if U2 misbehaves
(saves ~2/3 of the sticky facets' 1600 tris; the sunk mesh is hidden under applied near meshes
for the whole `STICKY_HOLD` window anyway).

---

## 4. Interactions

- **CALM (#123):** composes. CALM bounds re-emit *frequency*; the diet bounds re-emit *size* and
  the steady-state submission. CALM's ladder/pending sources (`_arm_pending`) are untouched.
- **STICKY_HOLD make-before-break / crossings:** the backstop ROLE sets (`_is_backstop`,
  `_sticky`, `_async_backstop` freeze contract) are not touched by P0; all role facets are
  ring-1 ⊂ cap (3.75°/facet-edge ≪ 29°). During a crossing the axis drifts ≪ `SHELL_SLACK_DEG`;
  the committed set still contains the visible cap until the next build lands — the same slack
  argument as shipped (`cube_sphere.gd:2549`). No new see-through frame is possible at a
  crossing.
- **FP_MID_DENSE (off live):** if ever enabled, its ring-2 disc (`MID_DENSE_RINGS=2`) ⊂ cap. ✓
- **FP_SHELL_CLIMB_NO_CHURN:** still correct — it suppresses re-emits only when `new_cos`
  equals the committed cap (`:1245-1247`); under the cap law a real θ_h change alters `new_cos`,
  so climbs re-emit (correctly, and 4-5× cheaper). Walking on flat ground keeps θ_h constant ⇒
  no extra churn.
- **SmoothV2 / far trees / structures:** unaffected (they are separate instances; the shell
  keeps backstopping under them inside the cap).
- **NEVER-OOM:** strictly negative delta: ~−10 MB steady mesh (489 k→~135 k × ~28 B GPU-side),
  −20 MB transient upload per re-emit, zero new allocations or caches. Ledger entry is a
  one-line reduction note.

## 5. Gates (headless; extend the far-ring verify family)

Caveat first (memory lesson, re-verified this session): the worktree source has
`FACETED := false` — the deploy cheat seds `cube_sphere.gd`. Gates must drive
`shell_set_camera_abs(dir, d, floored)` directly (it was split out for exactly this,
`:1211-1216`) and use the gate-forcing override-param convention, not rely on baked flags; the
LIVE truth check is always the served-pck dump (§0).

- **G-DIET-OFF** — flag off: `visible_fids()` and the built mesh byte-identical (pck compare +
  vertex-array compare after one `_rebuild_full`).
- **G-DIET-VERTS** — flag on, camera floored at d=R+2: rebuilt mesh `ARRAY_VERTEX` size ≤ 180 k
  AND ≤ 0.35 × the flag-off count from the same pose.
- **G-DIET-SOUND** (the no-see-through invariant, exhaustive) — for every facet excluded by the
  cap at each of d−R ∈ {2, 64, 112, 255}: assert angular_dist(centre) − half_diagonal >
  θ_h + acos(R/(R+116)). Pure math over 3456 facets; failure = a facet that could poke above
  the horizon was culled.
- **G-DIET-ROLES** — flag on: active ∪ `_excluded` ∪ `_sticky` ⊆ `visible_fids()` at all times,
  including through a simulated `set_active` crossing sequence (make-before-break: the union of
  pre- and post-crossing role sets stays emitted for the STICKY_HOLD window).
- Existing far-ring/fp_m2 suites green flag-off (standard).

## 6. Live A/B (forest facet 1754, remote session — same protocol as forest doc §6)

1. **Run the §6.4(a) probe FIRST** (10 s remote `_mi.visible=false` toggle at the baseline
   spot): this measures the shell's true per-frame GPU share *s* and is the go/no-go for the
   median claim (cost: minutes; no deploy).
2. Deploy flag-on. Assert: `farring … verts` telemetry ≤ 180 k; fps p50 / floor_p10 vs the
   #119/#123 baseline; expected median gain ≈ 0.6–0.8 · *s* (bounded honestly: the shell is one
   draw call, so the win is GPU vertex + upload, not submit; plausible *s* = 2–6 ms on the
   target integrated-GPU class ⇒ **+2–6 fps on the p50-30 baseline**, more on weaker GPUs).
3. Look checks while walking the forest, crossing a facet border, and climbing a peak:
   horizon silhouette pixel-identical (screenshot pair), **no sky-gap at the horizon**, no
   see-through at the crossing, no pop climbing through Δθ_h > 5°, fly-up through
   OFFSURFACE_Y=256 smooth (floor_changed re-emit, shipped path).
4. Keep 24 h, then decide P1 (U2 cull) on its own A/B.

## 7. Honest bottom line

The steady-state 489 k-vert shell submission is real and is the largest single standing
geometry in the forest frame — but it is one draw call, so the median-fps upside is **bounded
by the GPU-side share the §6.4(a) probe measures**; +2–6 fps p50 is the defensible expectation,
NOT a doubling. The diet is worth shipping even at the low end: it also cuts every remaining
re-emit (crossings, climbs, CALM ladder arms) ~4-5× in worker time and GL upload, which is
where the residual worst-frame spikes live. And the fix is one line behind one flag, riding
machinery (`shell_set_camera_abs`) that already does the correct thing everywhere except the
floored surface.
