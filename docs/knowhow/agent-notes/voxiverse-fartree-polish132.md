---
name: voxiverse-fartree-polish132
description: 2026-08-14
metadata: 
  node_type: memory
  type: project
---

Task #132 (3 far-tree polish bugs) root-caused 2026-08-14, doc COSMOS-FARTREE-POLISH-DESIGN.md.
**SHIPPED+MERGED PR #62 (main 09c69c6, 2026-08-14): FP_FT_NEAR_GUARD + FP_FT_TEXMEAN_COLOR, both byte-off.**
Gates verify_far_trees G-FTG-1..4 + G-FTG-OFF + G-FTM-COLOR two-state: **flags-off 7/0, flags-on 112/0,
FLAT 6042/0.** Deployed live via deploy_cheats (added both flags to CS_FLAGS). LIVE A/B (re-run the 043/044
double-render scenario) STILL PENDING a user reload.

**P1 FP_FT_STALE_REBUILD ALSO SHIPPED+MERGED (PR #63, main bd3ae9a, 2026-08-14) — the CONVERSE fix.** Same credit-0
freeze starves the SHOW paths the cull-only guard can't do (gap-fill / #130 dwell-restores / new-terrain while walking).
Fix = a hard ≤0.5Hz staleness floor: even at credit 0, permit ONE real rebuild when settled ∧ cam moved > FT_STALE_MOVE
(32 blk) since last rebuild ∧ ≥ FT_STALE_MS (2s) since it (250ms rate cap + DELTA gate still apply; still camera never
triggers). step() computes cam_abs once; _note_rebuilt resets the floor ref on every rebuild. Gates G-FTS-1..4/OFF drive
_stale_override directly (off 7/0, on 119/0, FLAT 6042/0). LIVE WALKING PERF A/B (motion isolated via pos-delta, since
telemetry `spd`==space-nav speed==0 on the ground — use POS-delta not spd): floor-ON walking worst_ms LOWER (66 vs 81
median, 143 vs 206 max), spikes continuous ~0.3s not the feared 2s periodic rebuild cadence ⇒ NO hitch regression; median
fps ~4 lower is within two-walk-profile noise (tail p10/min favour ON). Kept in the live deploy flag set. LESSON (repeat,
now bitten TWICE): NEVER `git checkout -- cube_sphere.gd` while an uncommitted FP_ const is pending — the flag-toggle gate
revert dropped FP_FT_STALE_REBUILD and the FLAT run failed to compile; COMMIT the const first, or reverse-sed true→false.

**FAR STRUCTURES guard ALSO SHIPPED+MERGED (PR #64, main 459b77c, 2026-08-14) — FP_STRUCT_NEAR_GUARD.**
FacetFarStructures shares the SAME credit-0 freeze (facet_far_structures.gd `if not settled or not credit_ok: return`)
→ far decimated model over near-built structure (double-render) + missing/dwell-restored structures while walking. But
structures are ONE merged ArrayMesh (per-instance hide impossible), so the cull IS a re-bake — YET the structures step
is ALREADY rate-capped (STRUCT_STEP_MS) + delta-gated (_inputs_changed: move≥STRUCT_DELTA_MOVE / cover-fp drift /
_cull_pending) with per-rev cached bakes, and _cull_emit fixes both hide+show in one pass. So the fix = relax ONLY the
credit gate: `_credit_gate_open(settled,credit_ok) = settled and (credit_ok or FP_STRUCT_NEAR_GUARD)` (settle gate still
holds). Gate G-ST-GUARD two-state (36/0 both), FLAT 6042/0. Byte-off. No live visual A/B (structures are player-built P0
— nothing on a fresh world; gate-proven + mechanically identical to the far-tree guard confirmed live). LESSON APPLIED
THIS TIME: used reverse-sed true→false to revert the flag-toggle gate run, NOT git-checkout (which drops the pending const).

**IMPL GOTCHA (corrects the design's "set_instance_transform"):** `set_instance_transform` is a NO-OP on a
`set_buffer`-backed MultiMesh (the buffer is authoritative — verified in-editor; `--headless` stores NO
MultiMesh data server-side at all, so get/set_instance_transform + get_buffer return defaults). So the guard
ZEROES the 12 transform floats in the CPU buffer snapshot the tier keeps (`_last_mesh_bufs[col]`/`_last_buf`) →
collapsed zero basis renders nothing → one `set_buffer` re-upload per changed rung buffer per pass (cheap: an
already-computed array, not the rebuild recompute). Gate read-back reads `_last_mesh_bufs`, NOT
get_instance_transform. Probe budget FT_GUARD_PROBE_CAP=64, round-robin `_guard_cursor`, hidden-set + metadata
reset in `_nearcull_begin` on every real rebuild.

**Defect 2 (double render, PRIMARY):** `FacetFarTrees.step()` returns before fingerprint+rebuild whenever `not settled or not credit_ok` (facet_far_trees.gd:641-642). StreamLoadController credit is a FRAME-TIME AIMD signal (not streaming-idle) — a ~30fps web client pins credit 0 even at rest; measured **6426/7056 telemetry rows (91%) stream_credit=0**. Instance buffers freeze minutes-stale → player walks into far-emitted trees, near mesh lands, probe never re-runs → persistent flat-twin doubles (frames 043/044: same pos, 21 s apart, doubles persist; some inside FT_CULL_MIN=64 = proof of no rebuild). Pre-existing (#114×#103), NOT a FRAME_WELD regression (#131 just made doubles co-located/crisp). Fix P0 = **FP_FT_NEAR_GUARD**: bounded cull-only guard BEFORE the credit return (hide dist<64 unconditionally; probe+hide COVERED annulus [64,168], ≤64 probes/step, MultiMesh.set_instance_transform zero-scale, never un-hide). P1 = FP_FT_STALE_REBUILD floor for the converse (missing-tree/#130-class) side. Same freeze exists in facet_far_structures.gd:149.

**FALSIFIED:** (a) the "probe AABB needs datum_lift" hypothesis — FS2′ lifts mesh/physics ONLY, voxel CONTENT stays un-lifted (facet_atlas.gd:466), is_area_meshed operates in fid-lattice voxel coords (module_world.gd:2530) ⇒ the un-lifted probe box is the CORRECT frame; lifting it would break it. (b) CULL_PROBE_CAP starvation — measured worst annulus [64,168] count 144 < 256 (latent under FP_FULLRES_256: [64,296] worst 247≈cap).

**Defect 1 (leaves cut in half):** = defect 2's signature (stale flat canopy bisects textured canopy + shows through FP_LEAF_CUTOUT stipple holes). The 448 xfade card/mesh silhouette mis-registration (pad-3 + independent u/v normalization raster, facet_far_trees.gd:1246-1274) is real but sub-visible (~10px trees). No standalone case found.

**Defect 3 (leaf color mismatch):** far trees use flat `BlockCatalog.color_of` (facet_far_trees.gd:1155 mesh, :1272 card atlas) while the far SKIN uses `BlockTextures.mean_color_of` under live FP_SKIN_TEXTURE_MEAN (far_palette.gd:41-44). Fix = **FP_FT_TEXMEAN_COLOR** resolver at both sites (setup-time only, byte-off).

**LESSON (repeat, load-bearing):** the deploy worktree SOURCE ≠ served config — cube_sphere.gd has `FACETED := false` in-tree; the deploy cheat flips it. A worktree headless run gives near_render_radius()=256; the SERVED value is 128. Always dump the served pck constants first ([[voxiverse-fallthrough-loc-bug]]). Headless image cropping works via the custom editor binary + Image.get_region (no PIL/imagemagick on host).
