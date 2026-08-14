# COSMOS FARTREE-POLISH — task #132: double-render / cut-leaves / leaf-colour (design)

**Status: DESIGN ONLY — no code changed.** Root-causes for the three live far-tree defects reported
after FP_FT_FRAME_WELD (#131) merged, verified against the SERVED pck + live telemetry + the report
session's frames. Priority order per task: Defect 2 > 1 > 3.

Served-pck facts (dumped via `ProjectSettings.load_resource_pack(build/web/index.pck)` +
`get_script_constant_map` — grep-on-pck does not work, scripts are tokenized):
`FP_FAR_TREES/_CARDS/_MESH/_FADE/_SNOW/_COLORFIX/_ALIGN/_NEARCULL/_DELTA`, `FP_FT_XFADE_COMPL`,
`FP_FT_FRAME_WELD`, `FP_LEAF_CUTOUT`, `FP_DATUM_BAKE`, `FP_LOAD_DEFER`, `FP_NB_FULLRES`,
`FP_SKIN_TEXTURE_MEAN` all **true**; `FACETED=true` (deploy-cheat flip — the worktree source has
`FACETED := false`, cube_sphere.gd:47, so **never** reason from a worktree headless run's
`near_render_radius()`: it returns 256 there, the SERVED value is **128**). Key consts:
`FT_CULL_MIN=64`, `FT_CULL_DWELL=2`, `FT_SINK_MAX=0.15` over `[208,288]`, `FAR_TREES_MESH_MAX=448`,
`FAR_TREES_CARD_MAX=2400`, `FAR_TREES_STEP_MS=250`, `LEAF_HOLE_P=0.3`, `LEAF_SCISSOR=0.5`.
Live probe annulus = `[FT_CULL_MIN, near_render_radius()+40] = [64, 168]`
(facet_far_trees.gd:507-511).

Evidence frames (report session, `tools/remote-bridge/results/frames/`):
`frame-1786631388688-043.jpg` and `frame-1786631409187-044.jpg` — **same standing position
(pos 21952, 9, 23405, spd 0), 21 s apart, defects persist in both** (that persistence-at-rest is
load-bearing for the Defect-2 verdict below). FPS 31, worst 40-44 ms, hitches 1895→2010 (+115 in
21 s).

---

## §1 Defect 2 (HIGHEST): near blocky tree AND far impostor render simultaneously

### 1.1 Still reproduces?
YES — frames 043/044: flat far-mesh trees (uniform dark-green canopy + uniform tan/white trunk,
no texture) standing co-located with / beside textured near trees, inside the near field
(estimated 40-90 blocks; some inside `FT_CULL_MIN=64`, where `_nearcull_emit` would *never* emit
at rebuild time — facet_far_trees.gd:507-508). Persistent across the 21 s at-rest window.

### 1.2 The prime suspect (probe AABB missing datum_lift) is FALSE — verified
The task's hypothesis was that the NearPresence probe AABB targets the un-lifted facet-plane y
while the near mesh sits at the datum-LIFTED y. Verified against the code:

- FS2′ datum bake **lifts only render/physics/input; the voxel CONTENT stays byte-identical**
  ("play y = cell y + s … while the voxel CONTENT stays byte-identical (no re-index, no generator
  change)") — facet_atlas.gd:464-471 (`datum_lift`), and the near-mesh lift is a per-vertex
  mesher-side `y += s` (datum_bake_params, facet_atlas.gd:488-504, C++ patch 0010).
- `skin_near_meshed` → godot_voxel `is_area_meshed` "operates in its OWN voxel (= fid-lattice)
  coordinates regardless of the slot's Node3D transform" — module_world.gd:2529-2544.

The probe box `AABB(Vector3(bx, gy+1, bz), ONE)` (facet_far_trees.gd:517) is built from the RAW
lattice base cell (`recs[o+8..10]` = `base.x/y/z`, written un-lifted at facet_far_trees.gd:780) —
i.e. **the probe is already in the correct (un-lifted, voxel-data) frame**. Lifting it by
`datum_lift` would make it WRONG (it would probe air ±5.5 blocks off the data). No fix needed
here; do not "fix" it.

### 1.3 Probe-budget starvation is FALSIFIED as the live cause (latent risk only)
`CULL_PROBE_CAP=256` per rebuild pass (facet_far_trees.gd:55); over-cap trees degrade to
UNKNOWABLE → emitted if not already hidden (:515-518). Measured with a headless TreeGen scan over
6 sampled facets (density 4.2-14.0 trees/100×100 blk): the WORST tree count inside the live
annulus [64,168], sliding the camera over every tree position, is **144 < 256**. Not the live
cause. Latent: under `FP_FULLRES_256` the annulus becomes [64,296] and the measured worst is
**247 ≈ 256** — flip that flag and starvation becomes real (see §5.3).

### 1.4 ROOT CAUSE: the FP_LOAD_DEFER credit gate freezes the tier on a chronically overloaded client
`FacetFarTrees.step()` returns **before dispatch, fingerprint, and both rebuilds** whenever
stream credit is 0:

- facet_far_trees.gd:641-642 — `if not settled or not credit_ok: return` (every step, forever —
  the comment at :639-640 and the wiring intent at facet_far_ring.gd:450-452 say the credit was
  meant to gate the FIRST post-settle commit, but the implementation gates ALL of them).
- Wiring: facet_far_ring.gd:1419-1420 (`_far_trees.step(_load_settled, _stream_credit_ok, _ft_cam)`)
  ← world_manager.gd:1343-1344 (`set_stream_credit_ok(stream_load_credit() > 0.0)`) ←
  stream_load_controller.gd:139-147 — AIMD credit that multiplicatively collapses to **0 whenever
  the frame-worst p90 EMA exceeds the adaptive setpoint** (clamped ≤45 ms). It is a FRAME-TIME
  overload signal, not a streaming-idle signal: a client that runs ~30 fps sits at credit 0 even
  standing still.

**Live measurement (today's session telemetry, `results/telemetry.jsonl`): 6426 of 7056 rows
(91%) have `stream_credit: 0`** (`frame_worst_ema` 100 ms vs `setpoint_ms` 45 in the tail row).
The report-session frames show the same regime (FPS 31, worst 40-44 ms, +115 hitches/21 s).

Consequence chain: the far-tree instance buffers rebuild only inside the rare credit>0 windows →
the emit/cull set is minutes stale → the player walks INTO trees that were legitimately far-emitted
when the buffer was last built; the near voxel mesh streams in underneath; nothing ever re-runs the
NEARCULL probe or the `dist < FT_CULL_MIN` drop → **far impostor + near blocky tree render
together, persistently, even at rest** (a still camera also never heals: `_compute_nearcull_fp`
at :665-666 sits behind the same early return, so a near-mesh landing cannot re-arm the DELTA
gate while frozen). The same freeze also produces the CONVERSE defect (missing far trees /
dwell-restore stalls of the #130 family — `FT_CULL_DWELL=2` "consecutive rebuilds" take minutes
when rebuilds are starved) and is shared verbatim by far STRUCTURES (facet_far_structures.gd:149).

**FP_FT_FRAME_WELD regression? NO — pre-existing** since the FP_FAR_TREES × FP_LOAD_DEFER wiring
(P0, task #114/#103). #120/#131 made it *visible*: the far tree now welds exactly onto the near
tree's position, so a stale double reads as a crisp flat twin instead of a vaguely misplaced blob.

### 1.5 Fix design — `FP_FT_NEAR_GUARD` (P0, byte-off, bounded, credit-independent)
Principle: keep the credit gate's purpose (no heavy rebuild work on an overloaded main thread) but
restore the correctness invariant *no far-over-near* with a bounded per-step guard that runs even
at credit 0. Cull-only (never shows), so it can never regress #130.

1. **Instance metadata** (flag-gated): while writing instances in `_rebuild_meshes`
   (facet_far_trees.gd:1076) — and in `_rebuild_cards` (:957) only when `FP_FAR_TREES_MESH` is
   off (cards then own the near frontier; with meshes on, cards live ≥416 and are never
   guard-relevant) — append per live instance: `(fid, bx, gy, bz, sx, sy, sz, rung, slot_index)`.
   PackedFloat32Array, ≤ `FAR_TREES_MESH_TOTAL_MAX`(1024)×9×4 ≈ **36 KB** (cards-own-frontier
   mode: bound by the annulus emit count, ≤ a few hundred). Added to `total_bytes()` (:1308) —
   NEVER-OOM ledger stays far under `FAR_TREES_BYTES_MAX` 4 MB.
2. **Guard pass in `step()`** — placed after `_apply_visibility` (:636) and BEFORE the
   settled/credit return (:641), own 250 ms rate cap, only when `FP_FT_NEAR_GUARD ∧
   FP_FAR_TREES_NEARCULL ∧ not offsurf`:
   - for each live metadata row, `dist = |cam_abs − s|`;
   - `dist < FT_CULL_MIN` → **hide unconditionally** (no probe — the near field owns it; this is
     exactly the rebuild-time rule at :507-508 applied live);
   - `FT_CULL_MIN ≤ dist ≤ near_render_radius()+40` → probe `_near_query` with the SAME un-lifted
     box (:517); `COVERED` → hide. Probes capped `FT_GUARD_PROBE_CAP := 64`/step (annulus worst
     144 → full sweep ≤ 3 steps ≈ 0.75 s).
   - hide = zero the instance's 12 transform floats in the CPU buffer snapshot the tier already
     keeps (`_last_mesh_bufs[col]` / `_last_buf`) → a collapsed zero basis renders no geometry,
     then upload once per pass via `set_buffer` (`_guard_flush`). **IMPLEMENTATION NOTE (deviates
     from the design's "set_instance_transform, no set_buffer"):** on a `set_buffer`-backed
     MultiMesh `set_instance_transform` is a no-op — the buffer is authoritative (verified in the
     editor: after `set_buffer`, `set_instance_transform` never lands; and `--headless` stores no
     MultiMesh data server-side at all). So the guard zeroes the CPU array and re-uploads it. This
     is still cheap: a single `set_buffer` of an ALREADY-computed array (the upload, not the
     expensive rebuild recompute that scans facets/TreeGen), bounded to ≤ N_SPECIES+1 uploads per
     pass and only when something was actually hidden; colours/custom in the buffer are untouched.
     Track hidden slots in a small dict cleared by every REAL rebuild (which rewrites the full
     buffer anyway, so guard state cannot leak across rebuilds).
   - never un-hide (restore remains rebuild-owned — no new show-path, no #130 re-entry surface).
   Cost: ≤1024 float distance checks + ≤64 probes + a handful of transform writes ≈ well under
   0.5 ms — safe to run at credit 0 by construction.
3. **Byte-off:** metadata arrays never allocated, guard never entered, `set_buffer` outputs and
   every existing gate byte-identical (all new state is written/read only under the flag).

This fixes the visible double-render (both the <64 stale class and the annulus COVERED class) in
the exact frozen regime the client actually runs in, and by removing the flat co-located canopy it
also removes most of Defect 1 (§2).

### 1.6 Gates
Extend `verify_far_trees.gd` (FakeWorld pattern, :55-61):
- **G-FTG-1** stale-inside-64: seed cache, `debug_rebuild` with a far camera, move the camera so a
  tree lands at dist<64, run the guard hook (new `debug_guard(cam)`) → instance transform zeroed,
  `rebuild_count()` unchanged.
- **G-FTG-2** annulus COVERED: FakeWorld.meshed=true → guard hides; meshed=false → untouched.
- **G-FTG-3** probe cap: >64 annulus trees → ≤64 probes issued, remainder untouched, next guard
  call continues (round-robin cursor).
- **G-FTG-4** real rebuild after guard → buffer fully rewritten, hidden-set cleared.
- **G-FTG-OFF** flag off → no metadata allocation, `debug_buffer()` bytes identical to shipped.
- **Live A/B:** deploy flag-on; remote-bridge walk 200 blk into forest, stand 30 s; assert no
  flat-twin trees in frames (the 043/044 scenario re-run); export a `ft_guard_hides` counter into
  the shell telemetry for the bridge.

---

## §2 Defect 1: "leaves cut in half" (partial canopy)

### 2.1 Still reproduces? What it actually is
YES in the same frames — and in every case reviewed it is **Defect 2's visual signature, not an
xfade bug**: a stale flat far canopy co-located (±sub-block, post-#131 weld) with a textured near
canopy. Two interleaving effects produce the "cut" look:
- the far canopy sits marginally lower/offset (sub-pixel residuals of #120: `FT_SINK` is 0 below
  208 so no sink, but trunk-floor/half-block residue remains), so its flat top face shows as a
  horizontal shelf bisecting the textured canopy (clear on frame 044 at the left tree, crop
  ~(940-1180, 330-480));
- `FP_LEAF_CUTOUT` punches ~30% (`LEAF_HOLE_P=0.3`) of near-leaf texels (block_atlas.gd:293-296),
  and the co-located flat far canopy shows through the punched holes — the canopy reads
  half-flat/half-textured, i.e. "cut".
No standalone cut-canopy was found that is not explained by (a) this double-render interleaving or
(b) plain terrain occlusion of a distant tree's lower half by a ridge (frame 043, mid-ground).

### 2.2 The 448 mesh↔card cross-fade: real mis-registration, but NOT the reported defect
`FP_FT_XFADE_COMPL` is correct per-pixel (card keep-set = complement of mesh keep-set:
facet_far_trees.gd:223-225 vs :1050-1051; fades complementary by :373-379). But complementarity
only sums to full coverage where BOTH silhouettes cover the same pixels, and they don't quite:
the card is a `CANOPY_DIAM=5 × (trunk_h+3)` quad (:986-987) textured by a 32² ortho raster that
normalizes u over `du` and v over `dv` INDEPENDENTLY with a 3-texel pad (:1246-1274) — aspect
distortion + ~19% shrink vs the true voxel-mesh silhouette. Mesh-only pixels in the 448±32 band
therefore dissolve to ~50% with no card behind them ("moth-eaten" outer canopy ring). At 448+
blocks a whole tree is ~10 px, so this is sub-visible — it cannot be the user's "cut in half"
trees, which are near-band-sized. **Verdict: document; fix only if it survives P0** (optional P2
`FP_FT_CARD_COREG`: raster with one shared blocks-per-texel scale on both axes and both views, so
the card silhouette is the mesh silhouette to within a texel).

`FP_LEAF_CUTOUT` leaking to far rungs: ruled out — the discard is spliced only into the shared
NEAR atlas shader (block_atlas.gd:135-151); the far card/mesh shaders (facet_far_trees.gd:159-320)
never sample that atlas. A FRAME_WELD basis/frustum clip: ruled out — the huge pinned
`custom_aabb` (:428, :459) makes frustum mis-cull impossible, and the welded basis is orthonormal.

### 2.3 Fix
None of its own. P0 = §1.5 (removes the co-located flat canopy). Re-shoot the 043/044 scenario
after P0 ships; only if a cut canopy survives, implement §2.2's `FP_FT_CARD_COREG`.

---

## §3 Defect 3: far vs near leaf colours don't match

### 3.1 Still reproduces + root cause
YES — flagrant in both frames (near leaves yellow-green textured; far tree canopies saturated flat
dark green; the far TERRAIN around them matches near well). Two colour sites in the far-tree tier
resolve the FLAT catalog swatch:
- `_build_archetype_mesh` (rung-1 mesh vertex colours): `BlockCatalog.color_of(id)` —
  facet_far_trees.gd:1155;
- `_raster_tile` (rung-2 card atlas texels): `BlockCatalog.color_of(cv.w)` — facet_far_trees.gd:1272.

The NEAR leaf blocks render the actual leaf TEXTURE tiles (block_atlas.gd:224-258 — leaf ids own
namespaced `leaftile:` cells), whose eye-average is the texture MEAN, not the swatch. The far
TERRAIN skin already solved exactly this: under the live `FP_SKIN_TEXTURE_MEAN=true`,
`FarPalette._top_color` resolves `BlockTextures.mean_color_of(id)` "(what the near textured block
averages to) instead of the flat catalog swatch, so the far skin's land colours match the near
field" — far_palette.gd:38-44; `mean_color_of` at block_textures.gd:64-76 (cached, falls back to
the swatch for tile-less ids). The far-tree tier simply never adopted that law. Pre-existing
(P0/P1 of #114); not a FRAME_WELD regression.

### 3.2 Fix design — `FP_FT_TEXMEAN_COLOR` (P0, byte-off)
One resolver in FacetFarTrees:

```gdscript
static func _ft_color_of(id: int) -> Color:
    if CubeSphere.FP_FT_TEXMEAN_COLOR:
        return BlockTextures.mean_color_of(id)   # the far-skin FP_SKIN_TEXTURE_MEAN law
    return BlockCatalog.color_of(id)
```

used at BOTH sites (:1155, :1272) — trunk and leaf cells alike (uniform: the trunk swatch/texture
mismatch is visible on the tan far trunks too). Both run once at setup (archetype meshes + card
atlas), so `mean_color_of`'s png load/cache cost is boot-only; the snow tint (:247, :334) stays on
the swatch (it already matches the far-skin snow). Off ⇒ both sites resolve the shipped swatch —
mesh arrays and atlas bytes byte-identical. Never-OOM: no new allocations (mean cache is
`BlockTextures`' existing static).

### 3.3 Gates
- **G-FTM-COLOR** (verify_far_trees.gd): under the flag, every leaf-cell vertex colour in
  `_build_archetype_mesh(SP_OAK)` equals `BlockTextures.mean_color_of(BlockCatalog.LEAF)`; with
  the flag off, the surface arrays are byte-identical to shipped (existing byte-off pattern).
- **Live A/B:** screenshot a forest handoff band; sample mean canopy RGB near vs far — should
  land within the JPEG-noise floor of each other (the #106-style quantitative screenshot check).

---

## §4 Follow-ups surfaced by this investigation (not P0)

1. **P1 `FP_FT_STALE_REBUILD` — staleness floor for the credit gate.** The §1.4 freeze also
   starves the CONVERSE paths the guard deliberately does not touch: gap-fill of a ramped-down
   view, dwell restores (#130), and new-terrain card fill while walking. Design: permit a real
   rebuild despite credit 0 when `settled ∧ cam moved > 32 blk since last rebuild ∧ ≥ 2 s since
   last rebuild` (≤ 0.5 Hz hard floor). This re-admits full rebuild cost (~tens of ms pre-#119
   scale) on an overloaded client — needs a live perf A/B before default-on; ship byte-off.
2. **Far STRUCTURES share the freeze** (facet_far_structures.gd:149, same
   `not settled or not credit_ok` return): apply the §1.5 guard pattern there (its NearPresence
   consumer policy per COSMOS-STRUCTURES-DESIGN §7.3) once trees prove out.
3. **Latent probe-cap starvation under FP_FULLRES_256** (§1.3): worst measured annulus 247 vs
   `CULL_PROBE_CAP` 256 with the [64,296] annulus. If FULLRES ships, either raise the cap
   proportionally to the annulus area or probe nearest-first (the current order is facet-then-
   grid-scan, deterministic — the same trees would starve every pass).
4. **Deploy-cheat trap (repeat of [[voxiverse-fallthrough-loc-bug]]):** the worktree source is NOT
   the served config (`FACETED := false` in-tree vs `true` served). Every future far-tree analysis
   must dump the served pck first.

## §5 Byte-off / never-OOM summary

| Flag | Default | Off-behaviour | Memory delta on |
|---|---|---|---|
| FP_FT_NEAR_GUARD | false | no metadata alloc, no guard pass, buffers byte-identical | +≤36 KB metadata + small hidden-set dict (ledgered in `total_bytes()`) |
| FP_FT_TEXMEAN_COLOR | false | both colour sites resolve the shipped swatch; mesh/atlas bytes identical | 0 (reuses BlockTextures mean cache) |
| FP_FT_STALE_REBUILD (P1) | false | credit gate exactly as shipped | 0 |
| FP_FT_CARD_COREG (P2, only if needed) | false | shipped raster verbatim | 0 |

All shader strings untouched by P0 (guard is CPU-side; colours are baked data) — gl_compat-safe by
construction.

## §6 Rollout
1. Implement FP_FT_NEAR_GUARD + FP_FT_TEXMEAN_COLOR together (both tiny, independent), gates
   G-FTG-1..OFF + G-FTM-COLOR in verify_far_trees.gd, full suite green in both flag states.
2. Deploy flags-on; re-run the 043/044 live scenario (walk into forest, stand 30 s, snapshot);
   check `ft_guard_hides` telemetry is non-zero and doubles are gone.
3. Re-assess Defect 1 on the new frames; only then decide on FP_FT_CARD_COREG.
4. Schedule the P1 staleness-floor A/B (it is the real cure for the missing-tree side of the
   freeze; the guard is the cure for the double-render side).
