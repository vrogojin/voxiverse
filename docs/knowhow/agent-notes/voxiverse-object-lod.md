---
name: voxiverse-object-lod
description: 2026-08-17 physical-object far-render + LOD ladder (FP_OBJ_LOD) — VoxelBody debris/ships/stations/asteroids get a size-derived mesh→decimated→cards→beacon-dot ladder; P0 law SHIPPED byte-off, P1-P3 renderer pending
metadata:
  type: project
---

2026-08-17 user initiative (after chop_tree shipped): detached VoxelBodies (chopped-tree canopies, dropped
blocks) have NO far representation — they vanish past near-render range (confirmed: far-structure baker only
does planet-attached villages; body_lod.gd is whole-celestial-body LOD; nothing bakes/draws loose bodies).
Build a GENERAL physical-object far-render + LOD framework (VoxelBodies now; ships/stations/asteroids later
— space travel is a big part of the game, want distant stations visible as a speck). Auto LOD-step count by
object block-size; auto "when to stop rendering" by angular view-size.

USER DECISIONS (locked): (1) general framework now, validated on VoxelBodies; (2) sub-pixel → fade to a dot
(space objects NEVER hard-cull, clamp to a 2px beacon); (3) auto-scaling VRAM budget small→large; (4) dynamic
per-frame transform (movers + tumblers).

PROCESS: Fable deep-research (docs/RESEARCH-OBJECT-LOD.md) → Fable adversarial review (docs/RESEARCH-OBJECT-
LOD-REVIEW.md) → my synthesis (docs/COSMOS-OBJECT-LOD-DESIGN.md). Both Fable + my spot-check agree: REUSE the
shipped BodyLod angular law verbatim (body_lod.gd:96-113 K_px=H/(2tan(fov/2)), ang_px=2r/d·K, relief=e/d·K,
P_POINT=2/TAU_POP=1/HYST=0.25 one-sided) — don't invent a metric. Ladder built from shipped machinery: L0 full
VoxelBody mesh (e=0) → L1..Lk StructDecimator pitch-2^k (e≈pitch) → C camera-facing cross+cap cards (e≈r/2,
far-tree pattern) → D beacon dot (e=r). Coarsest rung with sse≤1px; switch d=e·K/τ. Step count = floor(log2
(extent))-2 capped 8 (chip→0, 10-30blk→2, 512blk→7). MUST use LIVE Camera3D.fov not BodyLod's 70° const (zoom).

5 MUST-FIXES from the adversarial pass (folded into design): (1) VoxelBody _rebuild() (voxel_body.gd:633-663)
queue_frees+recreates its MeshInstance visible=true → a latched L0-hide is undone by any break/place; need
flag-gated _rev bump + re-apply hide on rev change; id=get_instance_id(); is_awake() exists(:407). (2) FRAME
mapping: body transforms are ActiveFrame-lattice (voxel_body.gd:130-137), far tier is FacetFarRing/SN3 space —
raw transform→MultiMesh copy misplaces cards (#131 frame-weld class); explicit map + facet-fold gate. (3)
BUDGET: fixed 4MB REJECTED → boot proxy-pick {2,4,8,16}MB from WEBGL_debug_renderer_info GPU string+navigator.
deviceMemory+hardwareConcurrency, hard 16MB ceiling gate proves worst-state, DEMOTE-ONLY mid-session (WebGL2
can't read VRAM + over-alloc = GL context loss → NEVER probe-grow). (4) space beacon needs analytic ray-sphere
planet occlusion (cosmos_sky.gd:415-433 precedent). (5) worker bake: snapshot cells on main, CellCodec mat-
decode in sampler (cells store PACKED values, voxel_body.gd:89). Also: whole-buffer set_buffer ONLY (the
set_instance_transform-after-set_buffer no-op trap, facet_far_trees.gd:704-706); cap unique card tiles ~256
(per-rev atlas at 2048 = 8MB); card basis = camera-facing NOT body rotation (tumbling <20px unreadable).

STAGING (all default-OFF, byte-off, FLAT 6042/0): P0 FP_OBJ_LOD (pure law + gate, NO renderer) → P1 FP_OBJ_LOD
_DEBRIS (registry + card/dot MultiMesh tiers + VoxelBody rev/hide hook + dormant-snapshot/awake-lazy-rewrite +
frame map) → P2 FP_OBJ_LOD_MESH (StructDecimator rung extent≥16, worker-baked LRU (id,rev,pitch)) → P3 FP_OBJ_
LOD_SPACE (CLASS_SPACE no-cull beacons + ray-sphere occlusion + clamped-distance placement + ship/station API)
→ P4 deferred (offline octahedral atlas, hero ships only).

SHIPPED P0 2026-08-17: commit 03c7050 on feat/voxiverse-object-lod (off main 02740d4). object_lod.gd (pure
static ObjectLod: k_px/proj_px/sse_px, mesh_pitches/step_count, rep_error, rung_raw/_select_nondot/rung_hyst,
cull/beacon_brightness, budget_bytes proxy pick) + verify_object_lod.gd 37/0 + FP_OBJ_LOD const + design/research
docs. FLAT 6042/0 byte-off (nothing reads the flag yet). GOTCHA caught while gate-writing: rung_raw's hard
proj<P_POINT dot-floor defeated rung_hyst's sticky band → extracted _select_nondot so the dot decision isn't
double-applied. P1 SHIPPED 2026-08-17 (commit 1a9f1d5, worktree agent + my review/merge): object_registry.gd + facet_far_objects.gd
(DOT+CARD MultiMesh tier childed to FacetFarRing) + VoxelBody flag-gated _obj_rev/set_far_hidden hook + ActiveFrame→
ring frame-weld + dormant-snapshot/awake-lazy-rewrite. Gate verify_object_far 24/0. LIVE: no regression (orbit render
intact). LESSON: debris cards are INHERENTLY sub-pixel — a ~5-blk canopy only reaches card/dot at ≥~1400 blocks = orbit,
where it's a speck; there's NO distance where a small-object card is both selected AND resolvable. So debris far-render
is gate-certified but not visually demonstrable; the visible payoff is BIG objects (P3).

P3 SHIPPED-CODE 2026-08-18 (commit c418f5d, worktree agent p3 + my review/merge, PR #76): FP_OBJ_LOD_SPACE — CLASS_SPACE
never-cull beacon (2px floor, brightness ∝p²), analytic ray-sphere planet occlusion (ObjectLod.beacon_occluded mirrors
cosmos_sky.gd:418-426), clamped-distance placement (ObjectLod.beacon_placement, BEACON_CLAMP_DIST=8000=D_SKY), +
dev_space_object.gd (DevSpaceObject ~40³ grey box, full duck API) spawned +2500 radial above spawn. Gate verify_object_
space 34/0. All gates green (37/24/34) + FLAT 6042/0 byte-off. Deployed with FP_OBJ_LOD/DEBRIS/SPACE on.

LIVE A/B BLOCKER (unresolved 2026-08-18): the DevSpaceObject does NOT render where expected — looking straight up
(look pitch_deg 85, the RELIABLE aim; aim_cell returns no_hit on a non-terrain mesh + doesn't reorient) from BOTH the
ground (alt 15, surface regime, scale≈1) AND orbit (alt 1007) shows empty sky, no grey box. Since it's absent even at
surface scale≈1, it's NOT (only) the orbit occluder-scale issue — the spawn/placement itself is wrong. TOP HYPOTHESIS:
`planet_render_centre()` (facet ring _placement_xform().origin) in FIXED_FRAME faceted mode may NOT be the geometric
planet centre in the player-global frame, so `radial_up = (player - centre).normalized()` points wrong → object placed
off-axis (not straight up), OR the spawn one-shot never fires (_have_player_pos gate). NEXT STEP: instrument — emit the
DevSpaceObject world pos + its projected screen pos to the telemetry stream (print() goes to the browser JS console,
invisible to the relay), OR add a temporary HUD marker; then correct the radial_up frame (use the true planet centre in
the same frame as VoxelBody.global_transform). LESSON: for a live visual A/B of a placed object, wire a telemetry/HUD
readout of its world+screen pos FIRST — don't rely on print() (browser-console only) or aim_cell (needs a terrain hit).
Tooling: `look {pitch_deg,yaw_deg}` is the reliable camera aim; freeze_player holds altitude; set_alt makes the player
free-fall + transitions LOW_ORBIT ~alt 1400.

FIX ATTEMPT 1 (commit e73d445, deployed): re-anchored the spawn to cam.global_transform.origin (scene-global) instead
of _last_player_pos (lattice) so up=(cam−render_centre) is single-frame. Gates still 34/0 + FLAT 6042/0. STILL NOT
VISIBLE straight-up from the ground → the residual is DEEPER than the one lattice/scene error: this codebase has ~5
coexisting frames (lattice; scene-global-near-origin under FIXED_FRAME ActiveFrame anchor; planet-absolute; SN3-scaled;
ring-local) and the DevSpaceObject is landing OR being distance-classified by the tier in the wrong one (candidate:
facet_far_objects.step reads cam_world / object center in mismatched frames → wrong `dist` → wrong rung + misplaced
frame-weld, so the near mesh is hidden AND the card/dot is placed off-screen). PROVEN-NEEDED next step: INSTRUMENT before
more redeploys — emit DevSpaceObject world pos + the tier's computed dist/proj/rep + its projected screen px to the
TELEMETRY stream (not print(), which is browser-console-only), fly to it, and align spawn + tier distance + frame-weld
to ONE frame (the frame VoxelBody.global_transform / the far-tree tier already use, since P1 debris DID render at orbit
without misplacement — so the debris path's frame is the correct reference). DO NOT keep eyeballing 9px specks.
INSTRUMENT-AND-FIX PASS RESOLVED IT 2026-08-18 (commits 930c8f3 debug HUD, 2897b27 ring-parent fix; PR #76 tip 2897b27):
Added a flag-gated PerfHUD "OBJLOD" readout (FacetFarObjects.dbg static → perf_hud, byte-off) showing the CLASS_SPACE
object's c(enter)/cam/d(ist)/proj/rep — READABLE IN A SCREENSHOT (the key unblocker; print() is browser-only). It
revealed TWO frame bugs in sequence: (1) FIXED e73d445 — spawn mixed lattice (_last_player_pos) with scene
(planet_render_centre) → re-anchored to cam.global_transform.origin (scene-global). (2) FIXED 2897b27 THE REAL ONE —
the DevSpaceObject was parented under world_manager, so when the player ascends and the FLOATING ORIGIN recenters the
camera to ~origin (scaled/orbit regime), the object stayed at its ABSOLUTE coords → dbg showed cam=(1,-1,-1) d=8878
(should be ~700). A CLASS_SPACE object is FIXED in planet-absolute space and must RIDE the planet render transform:
parent it under FacetFarRing (folds T_active + floating-origin anchor + SN3 scale, like the planet + the debris tier),
then set global_position (captures ring-local). AFTER: dbg c=(421,-400,-296) cam=(1,-1,-1) d=650 proj=28.9 rep=FULL and
the ~40-blk grey box RENDERS VISIBLY in space; at alt 307 d=2200 rep=MESH — the rung ladder + frame-tracking both work.
VERIFIED LIVE: object renders as FULL 3D mesh close-up, demotes FULL→MESH→(card/dot) by distance, tracks the scaled
frame at every altitude. Gates 37/24/34 + FLAT 6042/0 byte-off throughout.
LESSONS: (a) for a live visual debug of a placed object, a flag-gated HUD readout of its world/cam/dist/rep is the
fastest unblocker — 2 bugs pinned in 2 iterations vs endless blind screenshots. (b) ANY object that must hold a fixed
planet-absolute position across the surface↔orbit floating-origin/SN3 transition MUST be parented under FacetFarRing,
not world_manager (VoxelBody debris already are, via the ActiveFrame). (c) `look {pitch_deg,yaw_deg}` reliably aims;
the object is straight up (pitch ~90) from spawn so pitch 85 frames it.
RESIDUAL/POLISH (not blocking, follow-ons): the MESH rung routes to a CARD (P2 real StructDecimator mesh deferred) and
the card/dot use a faint brownish debris_tint (a whiter KIND_DOT tint would make the far beacon pop). Far beacon (dot,
proj<2px) not yet screenshot-confirmed (2px speck). Also the temporary OBJLOD HUD line (930c8f3) can be pruned or kept
as dev tooling. STATE: P0+P1+P3 all working + gate-certified + byte-off, PR #76.

POLISH + MERGED 2026-08-18 (PR #76 → main merge d4c9046): shipped kind-aware billboard tints (commit 90553e7,
facet_far_objects _SHADER reads INSTANCE_CUSTOM.w: DOT = bright warm-white beacon (1.0,0.96,0.86) so a distant space
object reads star-like; CARD = lighter neutral hull grey, was muddy brown). Live-confirmed the full ladder from orbit:
FULL grey box close-up (daylight) → MESH/CARD mid (proj~7.5px) → persists to d=9500 proj=2.0 rep=CARD i.e. right at the
2px dot floor, NEVER culled → beacon below that is a 2px point by design. Near reps use the object's LIT box material so
in the planet's shadow (night) the object is correctly dark; the far beacon is self-luminous (unshaded warm-white) so it
stays visible — a sensible "close=real hull / far=beacon light" model. Gates 37/24/34 + FLAT 6042/0 byte-off. 7 commits
(P0 03c7050 → P1 1a9f1d5 → P3 c418f5d + 2 frame fixes e73d445/2897b27 + debug 930c8f3 + tint 90553e7) merged d4c9046.
DELIBERATELY DEFERRED P2 (FP_OBJ_LOD_MESH real StructDecimator decimated-mesh rung): NO live-verifiable target today —
StructDecimator needs voxel `cells`, but the dev test-object is a plain BoxMesh (no cells) and real VoxelBody debris are
sub-pixel; shipping it blind would repeat the claim-without-verification trap. MESH→CARD seam is in place; P2 is a clean
follow-on once a voxel-celled ship/station exists to verify it on. Also open follow-ons: prune/keep the OBJLOD dev HUD;
brighter/whiter card; a bright-beacon-against-black-space screenshot (the 2px dot is hard to resolve against the planet
disc). The framework (physical objects far-rendered with a size-driven LOD ladder + angular cull + frame tracking) is
SHIPPED on main behind FP_OBJ_LOD/_DEBRIS/_SPACE (all default-off, byte-off).
Related: [[voxiverse-far-trees-design]] [[voxiverse-fartree-frame]] (frame-weld class) [[voxiverse-agent-autonomy]]
